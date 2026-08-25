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
set -eEuo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
load_env .env

[[ "$POSTGRES_DB" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
  || { echo "POSTGRES_DB is not a safe PostgreSQL identifier." >&2; exit 1; }

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

restore_globals() {
  local output unexpected
  local -a pipeline_status
  output="$(mktemp)"

  # Existing Supabase roles legitimately produce duplicate_object (42710).
  # Continue past those so every global is considered, but reject any other
  # SQL error and any decompression/connection failure.
  set +e
  zstd -dc "${BACKUP}/globals.sql.zst" \
    | pg psql -U postgres -h 127.0.0.1 -d template1 -q -v ON_ERROR_STOP=0 --set=VERBOSITY=verbose \
      >"$output" 2>&1
  pipeline_status=("${PIPESTATUS[@]}")
  set -e

  if (( pipeline_status[0] != 0 || pipeline_status[1] != 0 )); then
    cat "$output" >&2
    rm -f -- "$output"
    return 1
  fi

  unexpected="$(grep -E 'ERROR:[[:space:]]+[0-9A-Z]{5}:' "$output" | grep -Ev 'ERROR:[[:space:]]+42710:' || true)"
  if [[ -n "$unexpected" ]]; then
    cat "$output" >&2
    rm -f -- "$output"
    return 1
  fi
  rm -f -- "$output"
}

if [[ "$MODE" == "verify" ]]; then
  SCRATCH="restore_check_$(date +%s)"
  echo "Restoring into scratch database ${SCRATCH}"
  psql_as -d postgres -q -c "create database ${SCRATCH};"
  trap 'psql_as -d postgres -q -c "drop database if exists '"${SCRATCH}"' with (force);" >/dev/null 2>&1 || true' EXIT

  # --no-owner / --no-acl: the scratch db does not need Supabase's role graph to
  # prove the data survived the round trip.
  zstd -dc "${BACKUP}/database.dump.zst" \
    | pg pg_restore -U postgres -h 127.0.0.1 -d "$SCRATCH" --no-owner --no-acl 2>&1 \
    | sed '/warning\|already exists/Id'

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

SERVICES_STOPPED=0
RECOVERY_ACTIVE=0
RUNNING_APP_CONTAINERS=()
for container in prospect-app prospect-app-blue prospect-app-green; do
  if [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true)" == "true" ]]; then
    RUNNING_APP_CONTAINERS+=("$container")
  fi
done

restart_application_containers() {
  if (( ${#RUNNING_APP_CONTAINERS[@]} > 0 )); then
    docker start "${RUNNING_APP_CONTAINERS[@]}" >/dev/null
  fi
}

restore_failed() {
  status=$?
  trap - ERR
  set +e
  echo "Restore failed (exit ${status}). Recovering the previous database." >&2
  if [[ "$RECOVERY_ACTIVE" == "1" ]]; then
    psql_as -d template1 -q -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '${POSTGRES_DB}' and pid <> pg_backend_pid();" >/dev/null
    psql_as -d template1 -q -c "drop database if exists ${POSTGRES_DB} with (force);"
    psql_as -d template1 -q -c "alter database ${POSTGRES_DB}_old rename to ${POSTGRES_DB};"
  fi
  if [[ "$SERVICES_STOPPED" == "1" ]]; then
    docker compose up -d
    restart_application_containers
  fi
  exit "$status"
}
trap restore_failed ERR

echo "Stopping everything that writes to the database"
if (( ${#RUNNING_APP_CONTAINERS[@]} > 0 )); then
  docker stop "${RUNNING_APP_CONTAINERS[@]}" >/dev/null
fi
docker compose stop rest auth studio meta storage realtime functions 2>/dev/null || true
SERVICES_STOPPED=1

echo "Restoring globals"
restore_globals

echo "Recreating ${POSTGRES_DB}"
psql_as -d template1 -q -c "drop database if exists ${POSTGRES_DB}_old with (force);"
psql_as -d template1 -q -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '${POSTGRES_DB}' and pid <> pg_backend_pid();" >/dev/null
psql_as -d template1 -q -c "alter database ${POSTGRES_DB} rename to ${POSTGRES_DB}_old;"
RECOVERY_ACTIVE=1
psql_as -d template1 -q -c "create database ${POSTGRES_DB};"

echo "Restoring data"
zstd -dc "${BACKUP}/database.dump.zst" \
  | pg pg_restore -U postgres -h 127.0.0.1 -d "$POSTGRES_DB" 2>&1 \
  | sed '/warning\|already exists/Id'

echo "Re-applying role passwords and settings"
docker compose exec -T db bash -s < postgres/init/00-prospect-bootstrap.sh

echo "Restarting services"
docker compose up -d
restart_application_containers
SERVICES_STOPPED=0
RECOVERY_ACTIVE=0
trap - ERR

cat <<EOF

Restore complete. The previous database is kept as "${POSTGRES_DB}_old" —
verify the application, then reclaim the disk space with:

  docker compose exec db psql -U postgres -d postgres -c 'drop database ${POSTGRES_DB}_old;'

EOF
