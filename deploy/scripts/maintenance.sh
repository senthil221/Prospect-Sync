#!/usr/bin/env bash
# Weekly database maintenance and a capacity report.
#
#   ./scripts/maintenance.sh
#
# Autovacuum handles the routine work. This exists for the parts it does not:
# index bloat on the heavily-rewritten prospect_index table, planner statistics
# after bulk imports, and telling you about disk pressure before it bites.
set -euo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
load_env .env

psql_run() {
  docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -v ON_ERROR_STOP=1 -U postgres -d "$POSTGRES_DB" -h 127.0.0.1 "$@"
}

echo "=== Table sizes and dead-tuple ratio ==="
psql_run -c "
  select
    relname as table,
    pg_size_pretty(pg_total_relation_size(relid)) as total,
    n_live_tup as live,
    n_dead_tup as dead,
    case when n_live_tup > 0
      then round(100.0 * n_dead_tup / n_live_tup, 1)
      else 0 end as dead_pct,
    coalesce(to_char(last_autovacuum, 'YYYY-MM-DD HH24:MI'), 'never') as last_autovacuum
  from pg_stat_user_tables
  order by pg_total_relation_size(relid) desc
  limit 15;"

echo
echo "=== Draining the re-index backlog ==="
# A write whose index update failed queues the affected ids rather than losing
# them. Drain in bounded slices until the queue empties or stops making
# progress, so the search index converges without anyone opening the app.
for _ in $(seq 1 40); do
  drained="$(psql_run -tAq -c "select processed || ' ' || remaining from public.drain_reindex_backlog(2000);" 2>/dev/null || echo "")"
  [[ -n "$drained" ]] || { echo "  drain function not present - skipping (apply migrations)"; break; }
  processed="${drained%% *}"
  remaining="${drained##* }"
  echo "  re-indexed ${processed}, ${remaining} remaining"
  # No progress means the queue is empty, or every row left in it is failing.
  [[ "$processed" == "0" || "$remaining" == "0" ]] && break
done

echo
echo "=== Retiring company import staging ==="
# company_import_rows is the raw spreadsheet behind each company import. Nothing
# reads it once the import lands, but it was the third-largest object in the
# database. Three days is enough to re-run or audit an import; past that it is
# ballast in a 2 GB shared_buffers.
#
# Rows belonging to an import still in 'processing' are never eligible, whatever
# their age: staging is the resume point, so removing it would turn a stalled
# import into an unrecoverable one. Those rows are reported rather than removed.
purged="$(psql_run -tAq -c "select public.purge_company_import_rows_v1(3);" 2>/dev/null || echo "")"
if [[ -z "$purged" ]]; then
  echo "  purge function not present - skipping (apply migrations)"
else
  echo "  removed ${purged} staged rows from finished imports older than 3 days"
  stuck="$(psql_run -tAq -c "select count(*) from public.company_imports where status = 'processing' and created_at < now() - interval '2 days';" 2>/dev/null || echo "0")"
  [[ "$stuck" != "0" ]] && echo "  NOTE: ${stuck} import(s) still 'processing' after 2+ days - their staging is retained, and they are worth investigating"
  # Almost every eligible row goes, so the trailing pages are empty and a plain
  # VACUUM returns them to the filesystem. No exclusive lock, unlike VACUUM FULL.
  psql_run -q -c "vacuum (analyze) public.company_import_rows;" >/dev/null 2>&1 \
    && echo "  vacuumed - trailing empty pages returned to disk" \
    || echo "  vacuum skipped"
fi

echo
echo "=== Search index drift ==="
# A denormalized index you cannot verify is one you cannot trust.
psql_run -c "select jsonb_pretty(public.prospect_index_drift());" 2>/dev/null \
  || echo "  drift check not present - apply migrations"

echo
echo "=== Optional concurrent index maintenance ==="
# Rebuilding every index weekly is not routine vacuuming. Require an explicit
# decision after bloat/disk review. Never retry with a blocking table reindex.
if [[ "${MAINTENANCE_REINDEX:-0}" == "1" ]]; then
  psql_run -c "set lock_timeout = '5s';" -c "reindex table concurrently public.prospect_index;" \
    || { echo "Concurrent reindex failed; inspect invalid indexes before retrying." >&2; exit 1; }
else
  echo "  skipped; set MAINTENANCE_REINDEX=1 only after reviewing bloat and free disk"
fi

echo
echo "=== Refreshing planner statistics ==="
# Scoped to public - see the note in migrate.sh about the shared-catalog warnings.
psql_run -q <<'SQL'
do $$
declare
  t record;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('analyze public.%I', t.tablename);
  end loop;
end $$;
SQL

echo
echo "=== Slowest statements since statistics reset ==="
psql_run -c "
  select
    round(mean_exec_time::numeric, 1) as avg_ms,
    calls,
    round(total_exec_time::numeric / 1000, 1) as total_s,
    left(regexp_replace(query, '\s+', ' ', 'g'), 90) as query
  from pg_stat_statements
  where calls > 5 and mean_exec_time > 250
  order by total_exec_time desc
  limit 10;" 2>/dev/null || echo "(pg_stat_statements not available)"
# Keep cumulative counters for before/after deltas and incident investigation.

echo
echo "=== Company filter suggestions ==="
# Keyword/technology autocomplete reads a summary of 2.3M distinct values
# rather than unnesting them out of 418k companies on every keystroke, which
# used to take 6-15s and time out. The summary is rebuilt here rather than by a
# trigger: company imports write in bulk, and a per-row trigger on that table is
# how a slow import becomes a failed one. Suggestions are allowed to lag -- the
# filter itself never reads this table, so an unlisted keyword still works.
psql_run -tAc "select 'Refreshed ' || public.refresh_company_value_suggestions_v1() || ' company filter suggestions.';"

echo
echo "=== Capacity ==="
psql_run -tAc "select 'Database: ' || pg_size_pretty(pg_database_size('${POSTGRES_DB}'));"
df -h / | tail -1 | awk '{print "Disk:     " $3 " used of " $2 " (" $5 "), " $4 " free"}'
free -h | awk '/^Mem:/ {print "Memory:   " $3 " used of " $2 ", " $6 " cache"}'

USED_PCT="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
if (( USED_PCT > 75 )); then
  echo
  echo "!! Disk is ${USED_PCT}% full."
  echo "   PostgreSQL needs free space to VACUUM and to rewrite indexes; past"
  echo "   ~85% you risk a database that cannot reclaim space at all."
  echo "   Options: prune old backups, attach a Hostinger volume, or upgrade the plan."
fi
