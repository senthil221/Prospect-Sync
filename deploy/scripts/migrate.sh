#!/usr/bin/env bash
# Apply supabase/migrations in filename order, exactly once each.
#
#   ./scripts/migrate.sh            # apply everything pending
#   ./scripts/migrate.sh --dry-run  # list what would run
#
# State is tracked in supabase_migrations.schema_migrations — the same table the
# Supabase CLI uses. That is deliberate: history dumped from your hosted project
# carries over, already-applied migrations are correctly skipped, and you can
# still fall back to `supabase db push` at any point.
#
# Every migration in this repo is transaction-safe (no CREATE INDEX
# CONCURRENTLY), so each file runs inside BEGIN/COMMIT. A failure rolls that
# file back completely and stops — the database is never left half-migrated.
set -euo pipefail

cd "$(dirname "$0")/.."
MIGRATIONS_DIR="../supabase/migrations"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

source "$(dirname "$0")/_env.sh"
load_env .env

psql_run() {
  docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -v ON_ERROR_STOP=1 -U postgres -d "$POSTGRES_DB" -h 127.0.0.1 "$@"
}

docker compose ps db --status running --quiet | grep -q . \
  || { echo "The db service is not running. Start it first: docker compose up -d db" >&2; exit 1; }

psql_run -q <<'SQL'
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text primary key,
  statements text[],
  name text
);
SQL

applied="$(psql_run -tAq -c "select version from supabase_migrations.schema_migrations")"

pending=()
for file in "$MIGRATIONS_DIR"/*.sql; do
  [[ -e "$file" ]] || continue
  base="$(basename "$file")"
  version="${base%%_*}"
  if grep -qxF "$version" <<<"$applied"; then continue; fi
  pending+=("$file")
done

if (( ${#pending[@]} == 0 )); then
  echo "Up to date — nothing to apply."
  exit 0
fi

echo "${#pending[@]} migration(s) pending:"
printf '  %s\n' "${pending[@]##*/}"

if (( DRY_RUN )); then exit 0; fi
echo

for file in "${pending[@]}"; do
  base="$(basename "$file")"
  version="${base%%_*}"
  name="${base#*_}"; name="${name%.sql}"
  printf '  applying %s ... ' "$base"

  {
    echo "begin;"
    cat "$file"
    echo ";"
    printf "insert into supabase_migrations.schema_migrations (version, name) values ('%s', '%s') on conflict (version) do nothing;\n" \
      "$version" "$name"
    echo "commit;"
  } | psql_run -q

  echo "ok"
done

echo
echo "Refreshing planner statistics on the tables that just changed."
# Scoped to public on purpose. A bare `analyze` also walks shared catalogs that
# `postgres` does not own, emitting ~45 "only superuser can analyze it" warnings
# that bury whatever actually mattered in the output.
#
# Quoted heredoc: the $$ dollar-quoting must reach psql intact, and inside a
# double-quoted shell string bash would substitute it with its own PID.
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
echo "Done."
