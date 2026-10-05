#!/usr/bin/env bash
# Restore a backup, or prove one is restorable without touching production.
#
#   ./scripts/restore.sh --verify-only                  # monthly drill, safe
#   ./scripts/restore.sh --verify-only /var/backups/prospect/2026...
#   ./scripts/restore.sh --into-production <backup-dir>  # real recovery
#
# --verify-only restores into a scratch database inside the same PostgreSQL
# cluster, counts rows in the core tables, and drops it again. Production rows
# are untouched, but this is not an isolated-cluster drill; restore-isolated.sh
# supplies that stronger proof.
set -eEuo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
source "$(dirname "$0")/restore-orchestration.sh"
source "$(dirname "$0")/restore-platform.sh"
load_env .env
if [[ -z "${VERIFICATION_WORKER_DB_PASSWORD:-}" ]]; then
  echo "VERIFICATION_WORKER_DB_PASSWORD is required. Generate a dedicated value; do not reuse POSTGRES_PASSWORD." >&2
  exit 1
fi

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
psql_as() { pg psql -X -v ON_ERROR_STOP=1 -U supabase_admin -h 127.0.0.1 "$@"; }
psql_admin() { pg psql -X -v ON_ERROR_STOP=1 -U supabase_admin -h 127.0.0.1 "$@"; }

# The whole archive into a fresh database, in two passes (restore-platform.sh
# says why one pass cannot work on this image). Both pipelines that may end on
# SIGPIPE run in subshells with the ERR trap cleared, so an expected 141 never
# reaches restore_failed; a real failure returns 1 to the caller, which does.
restore_archive_into() {
  local target="$1" work
  work="$(mktemp -d)"
  if ! ( trap - ERR; set +eo pipefail
         zstd -dc "${BACKUP}/database.dump.zst" | pg pg_restore -l >"${work}/toc" 2>/dev/null
         exit "${PIPESTATUS[1]}" ) \
     || ! restore_platform_split "${work}/toc" "${work}/main.list" "${work}/late.list"; then
    rm -rf -- "$work"
    echo "Could not read the archive's table of contents." >&2
    return 1
  fi
  pg sh -c 'cat > /tmp/restore-main.list' <"${work}/main.list"
  pg sh -c 'cat > /tmp/restore-late.list' <"${work}/late.list"
  zstd -dc "${BACKUP}/database.dump.zst" \
    | pg pg_restore -U supabase_admin -h 127.0.0.1 -d "$target" --exit-on-error -L /tmp/restore-main.list
  if [[ -s "${work}/late.list" ]]; then
    psql_admin -d "$target" -q -c "$RESTORE_PLATFORM_REBUILD_SQL" >/dev/null
    if ! ( trap - ERR; set +eo pipefail
           zstd -dc "${BACKUP}/database.dump.zst" \
             | pg pg_restore -U supabase_admin -h 127.0.0.1 -d "$target" --exit-on-error --no-owner -L /tmp/restore-late.list
           statuses=("${PIPESTATUS[@]}")
           (( statuses[1] == 0 && (statuses[0] == 0 || statuses[0] == 141) )) ); then
      rm -rf -- "$work"
      echo "Restoring the held-back Supabase platform entries failed." >&2
      return 1
    fi
  fi
  pg rm -f /tmp/restore-main.list /tmp/restore-late.list >/dev/null 2>&1 || true
  rm -rf -- "$work"
}

restore_globals() {
  local output unexpected
  local -a pipeline_status
  output="$(mktemp)"

  # Existing Supabase roles legitimately produce duplicate_object (42710).
  # Continue past those so every global is considered, but reject any other
  # SQL error and any decompression/connection failure.
  set +e
  # Credentials in a historical archive must never rotate the password used by
  # the still-running recovery session. Roles, memberships and settings are
  # restored; current deployment passwords are reasserted by bootstrap below.
  zstd -dc "${BACKUP}/globals.sql.zst" \
    | sed -E "s/[[:space:]]+PASSWORD[[:space:]]+('[^']*'|NULL)//Ig" \
    | pg psql -U supabase_admin -h 127.0.0.1 -d template1 -q -v ON_ERROR_STOP=0 --set=VERBOSITY=verbose \
      >"$output" 2>&1
  pipeline_status=("${PIPESTATUS[@]}")
  set -e

  if (( pipeline_status[0] != 0 || pipeline_status[1] != 0 || pipeline_status[2] != 0 )); then
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

  echo "Restoring into same-cluster scratch database ${SCRATCH} (template0)."
  psql_admin -d postgres -q -c "create database ${SCRATCH} with template template0;"

  # This is intentionally a full archive restore: ownership and ACLs are part
  # of recoverability. Every entry is restored; the only exceptions are the two
  # Supabase platform entries restore_archive_into applies in a second pass
  # (no --no-acl, no warning filter, no globals/bootstrap replay here).
  restore_archive_into "$SCRATCH"

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
  echo "Same-cluster restore check passed. Full archive, ownership, ACLs, data checks, and scratch cleanup verified."
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
RESTORE_VALIDATED=0
production_admin_preflight="$(psql_admin -d template1 -tAq -c \
  "select current_user || '|' || rolsuper from pg_roles where rolname = current_user")"
[[ "$production_admin_preflight" == "supabase_admin|true" ]] || {
  echo "Production restore requires the existing supabase_admin superuser; got ${production_admin_preflight:-no result}." >&2
  exit 1
}
capture_running_services

# Never destroy an earlier recovery copy. Resolve this before stopping a single
# writer so an operator can inspect or remove it without an outage.
old_exists="$(psql_as -d template1 -tAq -c "select exists(select 1 from pg_database where datname = '${POSTGRES_DB}_old')")"
[[ "$old_exists" == "f" ]] || {
  echo "Refusing restore: ${POSTGRES_DB}_old already exists. Verify or remove it manually first." >&2
  exit 1
}
database_owner="$(psql_admin -d template1 -tAq -c \
  "select pg_get_userbyid(datdba) from pg_database where datname = '${POSTGRES_DB}'")"
[[ "$database_owner" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
  echo "Refusing restore: current database owner is missing or not a simple PostgreSQL role identifier." >&2
  exit 1
}
database_owner_sql="\"${database_owner}\""

restore_failed() {
  status=$? rollback_ok=1 original_present=""
  trap - ERR
  set +e
  echo "Restore failed (exit ${status}). Recovering the previous database." >&2
  if [[ "$RESTORE_VALIDATED" == "1" ]]; then
    # The replacement database has passed its data/security checks. A partial
    # container startup is an orchestration failure, not grounds to delete the
    # validated restore. Quiesce writers again and retain both databases.
    if stop_database_writers; then
      echo "Validated database retained, but service startup failed. Writers are stopped; inspect services before retrying startup." >&2
    else
      echo "Validated database retained, but service startup failed and writer shutdown could not be proven. Stop writers manually." >&2
    fi
    exit 1
  fi
  if [[ "$RECOVERY_ACTIVE" == "1" ]]; then
    psql_as -d template1 -q -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '${POSTGRES_DB}' and pid <> pg_backend_pid();" >/dev/null || rollback_ok=0
    psql_as -d template1 -q -c "drop database if exists ${POSTGRES_DB} with (force);" || rollback_ok=0
    psql_as -d template1 -q -c "alter database ${POSTGRES_DB}_old rename to ${POSTGRES_DB};" || rollback_ok=0
  fi
  original_present="$(psql_as -d template1 -tAq -c "select exists(select 1 from pg_database where datname = '${POSTGRES_DB}') and not exists(select 1 from pg_database where datname = '${POSTGRES_DB}_old')" 2>/dev/null)" || rollback_ok=0
  [[ "$original_present" == "t" ]] || rollback_ok=0
  if [[ "$rollback_ok" == "1" ]]; then
    docker compose exec -T -e VERIFICATION_WORKER_DB_PASSWORD db bash -s < postgres/init/00-prospect-bootstrap.sh || rollback_ok=0
  fi
  if [[ "$SERVICES_STOPPED" == "1" && "$rollback_ok" == "1" ]]; then
    restart_previous_services_fail_closed || rollback_ok=0
  fi
  if [[ "$rollback_ok" != "1" ]]; then
    echo "Automatic rollback or writer restart could not be proven. A fail-closed shutdown was attempted; confirm every writer is stopped before manual recovery." >&2
    exit 1
  fi
  exit "$status"
}
trap restore_failed ERR

echo "Stopping everything that writes to the database"
stop_database_writers

echo "Restoring globals"
restore_globals

echo "Recreating ${POSTGRES_DB}"
psql_as -d template1 -q -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '${POSTGRES_DB}' and pid <> pg_backend_pid();" >/dev/null
psql_as -d template1 -q -c "alter database ${POSTGRES_DB} rename to ${POSTGRES_DB}_old;"
RECOVERY_ACTIVE=1
psql_as -d template1 -q -c "create database ${POSTGRES_DB} with template template0 owner ${database_owner_sql};"

echo "Restoring data"
restore_archive_into "$POSTGRES_DB"

echo "Re-applying role passwords and settings"
docker compose exec -T -e VERIFICATION_WORKER_DB_PASSWORD db bash -s < postgres/init/00-prospect-bootstrap.sh

echo "Validating restored data, ownership and grants before writers resume"
pg sh -c 'exec psql -X -v ON_ERROR_STOP=1 -U supabase_admin -h 127.0.0.1 -d "$1" -f -' sh "$POSTGRES_DB" < scripts/restore-verify.sql
restored_owner="$(psql_admin -d template1 -tAq -c \
  "select pg_get_userbyid(datdba) from pg_database where datname = '${POSTGRES_DB}'")"
[[ "$restored_owner" == "$database_owner" ]] || {
  echo "Restored database owner changed from ${database_owner} to ${restored_owner:-unknown}." >&2
  false
}

echo "Restarting services"
RESTORE_VALIDATED=1
RECOVERY_ACTIVE=0
restart_previous_services
SERVICES_STOPPED=0
trap - ERR

cat <<EOF

Restore complete. The previous database is kept as "${POSTGRES_DB}_old" -
verify the application, then reclaim the disk space with:

  docker compose exec db psql -U postgres -d postgres -c 'drop database ${POSTGRES_DB}_old;'

EOF
