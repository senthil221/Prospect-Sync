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
psql_as() { pg psql -X -v ON_ERROR_STOP=1 -U postgres -h 127.0.0.1 "$@"; }
psql_admin() { pg psql -X -v ON_ERROR_STOP=1 -U supabase_admin -h 127.0.0.1 "$@"; }

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
  VERIFY_SQL="$(pwd)/scripts/restore-verify.sql"
  [[ -f "$VERIFY_SQL" ]] || { echo "Missing restore verification checks: ${VERIFY_SQL}" >&2; exit 1; }

  # The image intentionally makes postgres a non-superuser. A full Supabase
  # archive includes Vault ACLs and database-local event triggers, so a drill as
  # postgres gives a false negative. supabase_admin is the image's existing
  # container-local superuser and is also used by the bootstrap script.
  admin_preflight="$(psql_admin -d postgres -tAq -c \
    "select current_user || '|' || rolsuper from pg_roles where rolname = current_user")"
  [[ "$admin_preflight" == "supabase_admin|true" ]] || {
    echo "Restore verification requires the existing supabase_admin superuser; got ${admin_preflight:-no result}." >&2
    exit 1
  }
  server_version="$(psql_admin -d postgres -tAq -c "show server_version")"
  echo "Preflight: supabase_admin is a superuser; PostgreSQL ${server_version}."

  # Refuse a same-cluster drill if an archive contains pg_cron. pg_cron can be
  # installed in only cron.database_name on one cluster; skipping that archive
  # entry would no longer prove a full restore.
  if grep -Eq ' EXTENSION - pg_cron([[:space:]]|$)' "${BACKUP}/manifest.txt"; then
    echo "This archive contains pg_cron; a full same-cluster restore drill cannot recreate it safely." >&2
    echo "Verify this backup in a separate PostgreSQL cluster instead." >&2
    exit 1
  fi
  while IFS= read -r extension; do
    [[ -n "$extension" ]] || continue
    [[ "$extension" =~ ^[A-Za-z0-9_-]+$ ]] || {
      echo "Archive contains an unsafe extension name." >&2
      exit 1
    }
    available="$(psql_admin -d postgres -tAq -c \
      "select exists(select 1 from pg_available_extensions where name = '${extension}')")"
    [[ "$available" == "t" ]] || {
      echo "Archive extension ${extension} is unavailable in PostgreSQL ${server_version}." >&2
      exit 1
    }
  done < <(sed -nE 's/.* EXTENSION - ([^[:space:]]+).*/\1/p' "${BACKUP}/manifest.txt" | sort -u)

  SCRATCH="restore_check_$(date +%s)_$$_${RANDOM}"
  [[ "$SCRATCH" =~ ^restore_check_[0-9]+_[0-9]+_[0-9]+$ ]] || {
    echo "Generated scratch database name is unsafe." >&2
    exit 1
  }
  case "$SCRATCH" in
    "$POSTGRES_DB"|postgres|template0|template1)
      echo "Refusing unsafe restore verification target: ${SCRATCH}" >&2
      exit 1
      ;;
  esac

  scratch_cleanup() {
    local original_status=$? cleanup_status=0 still_present=""
    trap - EXIT
    set +e
    if [[ -n "${SCRATCH:-}" ]]; then
      psql_admin -d postgres -q -c "drop database if exists ${SCRATCH} with (force);" >/dev/null 2>&1 || cleanup_status=$?
      still_present="$(psql_admin -d postgres -tAq -c \
        "select exists(select 1 from pg_database where datname = '${SCRATCH}')" 2>/dev/null)" || cleanup_status=$?
      if [[ "$still_present" != "f" ]]; then cleanup_status=1; fi
    fi
    if (( original_status == 0 && cleanup_status != 0 )); then
      echo "Restore verification could not prove scratch database cleanup." >&2
      original_status=$cleanup_status
    fi
    exit "$original_status"
  }
  trap scratch_cleanup EXIT

  echo "Restoring into isolated scratch database ${SCRATCH} (template0)."
  psql_admin -d postgres -q -c "create database ${SCRATCH} with template template0;"

  # This is intentionally a full archive restore: ownership and ACLs are part
  # of recoverability. No selective list, --no-owner, --no-acl, warning filter,
  # or globals/bootstrap replay is allowed in verification mode.
  zstd -dc "${BACKUP}/database.dump.zst" \
    | pg pg_restore -U supabase_admin -h 127.0.0.1 -d "$SCRATCH" --exit-on-error

  echo
  echo "Running restored data and security checks."
  pg sh -c 'exec psql -X -v ON_ERROR_STOP=1 -U supabase_admin -h 127.0.0.1 -d "$1" -f -' sh "$SCRATCH" < "$VERIFY_SQL"

  echo "Dropping scratch database ${SCRATCH}."
  psql_admin -d postgres -q -c "drop database ${SCRATCH} with (force);"
  scratch_present="$(psql_admin -d postgres -tAq -c \
    "select exists(select 1 from pg_database where datname = '${SCRATCH}')")"
  [[ "$scratch_present" == "f" ]] || { echo "Scratch database still exists after drop." >&2; exit 1; }
  SCRATCH=""

  echo
  echo "Restore drill passed. Full archive, ownership, ACLs, data checks, and scratch cleanup verified."
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

Restore complete. The previous database is kept as "${POSTGRES_DB}_old" -
verify the application, then reclaim the disk space with:

  docker compose exec db psql -U postgres -d postgres -c 'drop database ${POSTGRES_DB}_old;'

EOF
