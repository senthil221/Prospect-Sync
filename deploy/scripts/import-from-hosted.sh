#!/usr/bin/env bash
# One-time copy of your hosted Supabase project into this self-hosted stack.
#
#   ./scripts/import-from-hosted.sh 'postgresql://postgres.<ref>:<pw>@aws-0-<region>.pooler.supabase.com:5432/postgres'
#
# Get that string from the Supabase dashboard: Project Settings → Database →
# Connection string → URI, using the *session pooler* (port 5432). The direct
# connection is IPv6-only on the free tier and will usually just hang.
#
# What moves:  the `public` schema (all tables, functions, indexes, data) and
#              your applied-migration history.
# What does not: `auth` - GoTrue's own tables belong to whatever GoTrue version
#              wrote them, and forcing one version's schema onto another is a
#              reliable way to end up unable to log in. Your user list is two
#              people; recreate them with scripts/create-user.sh afterwards.
#
# Run this against a stack that is already up but has never been migrated.
set -euo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
load_env .env

HOSTED_URL="${1:-}"
[[ -n "$HOSTED_URL" ]] || { echo "Usage: $0 '<hosted postgres URI>'" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pg() { docker compose exec -T db "$@"; }
psql_local() {
  docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db \
    psql -v ON_ERROR_STOP=1 -U postgres -d "$POSTGRES_DB" -h 127.0.0.1 "$@"
}

echo "==> Checking the local database is empty"
existing="$(psql_local -tAc "select count(*) from information_schema.tables where table_schema = 'public';")"
if [[ "$existing" != "0" ]]; then
  echo "The local public schema already has ${existing} tables." >&2
  echo "Importing on top of that will conflict. Start from a clean volume:" >&2
  echo "  docker compose down && docker volume rm prospect_db-data && docker compose up -d db" >&2
  exit 1
fi

echo "==> Dumping the hosted project"
# pg_dump runs inside the db container so its version always matches the server
# it will restore into. A newer server refuses an older client's dump.
pg pg_dump "$HOSTED_URL" \
  --schema=public \
  --schema=supabase_migrations \
  --no-owner --no-acl \
  --no-publications --no-subscriptions \
  --quote-all-identifiers \
  -Fc -Z0 > "${WORK}/hosted.dump"

size=$(du -h "${WORK}/hosted.dump" | cut -f1)
echo "    ${size} dumped"

echo "==> Restoring"
pg pg_restore -U postgres -h 127.0.0.1 -d "$POSTGRES_DB" \
  --no-owner --no-acl --jobs 2 < "${WORK}/hosted.dump" 2>&1 \
  | grep -vi 'warning\|already exists' || true

echo "==> Re-granting to service_role"
# --no-acl dropped the grants; the migrations are the source of truth for them,
# and re-running the grant statements is cheaper and safer than trusting a
# dumped ACL that references a role graph from another cluster.
psql_local -q <<SQL
do \$\$
declare
  fn record;
begin
  for fn in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', fn.sig);
    execute format('grant execute on function %s to service_role', fn.sig);
  end loop;
end
\$\$;

revoke all on all tables in schema public from anon, authenticated;
grant all on all tables in schema public to service_role;
grant usage on schema public to service_role;
SQL

echo "==> Reconciling migration history"
./scripts/migrate.sh

echo "==> Rebuilding statistics"
psql_local -q -c "analyze;"

echo
echo "=== Imported ==="
psql_local -c "
  select 'clients' as table, count(*) from public.clients
  union all select 'companies', count(*) from public.companies
  union all select 'prospects', count(*) from public.prospects
  union all select 'lists', count(*) from public.lists
  union all select 'list_rows', count(*) from public.list_rows
  union all select 'imports', count(*) from public.imports
  order by 1;"

cat <<'EOF'

Next: create your users. They do not come across from the hosted project.

  ./scripts/create-user.sh owner@example.com
  ./scripts/create-user.sh boss@example.com

Then confirm those addresses match ALLOWED_USER_EMAILS in .env.
EOF
