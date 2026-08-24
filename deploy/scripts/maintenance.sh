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
echo "=== Reindexing prospect_index ==="
# This table is fully rewritten by reindex_all and every import. Its GIN/btree
# indexes bloat faster than autovacuum reclaims. REINDEX takes an ACCESS
# EXCLUSIVE lock, which is why this runs at 04:30 on a Sunday.
psql_run -c "reindex table concurrently public.prospect_index;" \
  || psql_run -c "reindex table public.prospect_index;"

echo
echo "=== Refreshing planner statistics ==="
psql_run -c "analyze;"

echo
echo "=== Slowest statements this week ==="
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
psql_run -q -c "select pg_stat_statements_reset();" >/dev/null 2>&1 || true

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
