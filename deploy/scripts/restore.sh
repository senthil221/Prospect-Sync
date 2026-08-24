#!/usr/bin/env bash
# Restore a backup, or prove one is restorable without touching production.
#
#   ./scripts/restore.sh --verify-only                  # monthly drill, safe
#   ./scripts/restore.sh --verify-only /var/backups/prospect/2026...
#   ./scripts/restore.sh --into-production <backup-dir>  # real recovery
#
# --verify-only restores into a scratch database inside the same PostgreSQL
# container, counts rows in the core tables, and drops it again. Production is
# untouched. This is the drill; do it monthly.
set -euo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
load_env .env

MODE=""
BACKUP=""
for arg in "$@"; do
  case "$arg" in
    --verify-only)      MODE=verify ;;
    --into-production)  MODE=production ;;
    *)                  BACKUP="$arg" ;;
  esac
done

[[ -n "$MODE" ]] || { echo "Pass --verify-only or --into-production" >&2; exit 1; }

BACKUP_DIR="${BACKUP_DIR:-/var/backups/prospect}"
if [[ -z "$BACKUP" ]]; then
  BACKUP="$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort | tail -1)"
  echo "Using most recent backup: $BACKUP"
fi
[[ -f "${BACKUP}/database.dump.zst" ]] || { echo "No database.dump.zst in ${BACKUP}" >&2; exit 1; }

pg() { docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db "$@"; }
psql_as() { pg psql -v ON_ERROR_STOP=1 -U postgres -h 127.0.0.1 "$@"; }

if [[ "$MODE" == "verify" ]]; then
  SCRATCH="restore_check_$(date +%s)"
  echo "Restoring into scratch database ${SCRATCH}"
  psql_as -d postgres -q -c "create database ${SCRATCH};"
  trap 'psql_as -d postgres -q -c "drop database if exists '"${SCRATCH}"' with (force);" >/dev/null 2>&1 || true' EXIT

  # --no-owner / --no-acl: the scratch db does not need Supabase's role graph to
  # prove the data survived the round trip.
  zstd -dc "${BACKUP}/database.dump.zst" \
    | pg pg_restore -U postgres -h 127.0.0.1 -d "$SCRATCH" --no-owner --no-acl --jobs 2 2>&1 \
    | grep -vi 'warning\|already exists' || true

  echo
  echo "Row counts in the restored copy:"
  psql_as -d "$SCRATCH" -c "
    select 'clients' as table, count(*) from public.clients
    union all select 'companies', count(*) from public.companies
    union all select 'prospects', count(*) from public.prospects
    union all select 'lists', count(*) from public.lists
    union all select 'list_rows', count(*) from public.list_rows
    union all select 'imports', count(*) from public.imports
    union all select 'auth.users', count(*) from auth.users
    order by 1;"

  echo
  echo "Restore drill passed. Scratch database dropped."
  exit 0
fi

# ── Real recovery ──────────────────────────────────────────────────────────
cat <<EOF

  This REPLACES the live "${POSTGRES_DB}" database with:
    ${BACKUP}
  $(cat "${BACKUP}/meta.json" 2>/dev/null || true)

  Everything written since that backup will be lost.

EOF
read -rp "Type the word RESTORE to continue: " confirm
[[ "$confirm" == "RESTORE" ]] || { echo "Aborted."; exit 1; }

echo "Stopping everything that writes to the database"
docker compose stop app rest auth studio meta storage realtime functions 2>/dev/null || true

echo "Restoring globals"
zstd -dc "${BACKUP}/globals.sql.zst" | psql_as -d postgres -q 2>&1 | grep -vi 'already exists' || true

echo "Recreating ${POSTGRES_DB}"
psql_as -d postgres -q -c "drop database if exists ${POSTGRES_DB}_old;"
psql_as -d postgres -q -c "alter database ${POSTGRES_DB} rename to ${POSTGRES_DB}_old;"
psql_as -d postgres -q -c "create database ${POSTGRES_DB};"

echo "Restoring data"
zstd -dc "${BACKUP}/database.dump.zst" \
  | pg pg_restore -U postgres -h 127.0.0.1 -d "$POSTGRES_DB" --jobs 2 2>&1 \
  | grep -vi 'warning\|already exists' || true

echo "Re-applying role passwords and settings"
docker compose exec -T db bash -s < postgres/init/00-prospect-bootstrap.sh

echo "Restarting services"
docker compose up -d

cat <<EOF

Restore complete. The previous database is kept as "${POSTGRES_DB}_old" —
verify the application, then reclaim the disk space with:

  docker compose exec db psql -U postgres -d postgres -c 'drop database ${POSTGRES_DB}_old;'

EOF
