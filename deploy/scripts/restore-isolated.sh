#!/usr/bin/env bash
# Restore one verified archive into a disposable PostgreSQL container and named
# volume. No production container, network, volume, port or credential is used.
set -eEuo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
source "$(dirname "$0")/backup-status.sh"
source "$(dirname "$0")/backup-offsite.sh"
load_env .env

BACKUP_DIR="${BACKUP_DIR:-/var/backups/prospect}"
[[ "$BACKUP_DIR" == /* ]] || { echo "BACKUP_DIR must be absolute." >&2; exit 1; }
[[ $# -eq 1 ]] || { echo "Usage: ./scripts/restore-isolated.sh <timestamp-backup-directory>" >&2; exit 1; }
BACKUP_DIR="$(realpath -- "$BACKUP_DIR")"
command -v docker >/dev/null || { echo "docker is required for the isolated restore drill." >&2; exit 1; }
exec 9>"${BACKUP_DIR}/.backup.lock"
flock -n 9 || { echo "Another backup, retention, upload or restore drill is running." >&2; exit 1; }
BACKUP="$(resolve_backup_within_root "$BACKUP_DIR" "$1")"
validate_local_backup_for_upload "$BACKUP"

STAMP="$(basename "$BACKUP")"
IMAGE="$(jq -er '.postgres_image' "$BACKUP/meta.json")"
EXPECTED_IMAGE="supabase/postgres:${POSTGRES_IMAGE_TAG}"
[[ "$IMAGE" == "$EXPECTED_IMAGE" ]] || {
  echo "Backup image ${IMAGE} differs from the configured reviewed image ${EXPECTED_IMAGE}." >&2
  exit 1
}
jq -e '.database | type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*$")' "$BACKUP/meta.json" >/dev/null || {
  echo "Backup database name is unsafe." >&2; exit 1;
}
OBJECTS="$(wc -l < "$BACKUP/manifest.txt")"
BACKUP_BYTES="$(du -sb "$BACKUP" | cut -f1)"
MIN_FREE_BYTES="${RESTORE_DRILL_MIN_FREE_BYTES:-21474836480}"
MAX_DATA_BYTES="${RESTORE_DRILL_MAX_DATA_BYTES:-21474836480}"
HOST_RESERVE_BYTES="${RESTORE_DRILL_HOST_RESERVE_BYTES:-8589934592}"
DEADLINE_SECONDS="${RESTORE_DRILL_TIMEOUT_SECONDS:-7200}"
for value in "$MIN_FREE_BYTES" "$MAX_DATA_BYTES" "$HOST_RESERVE_BYTES" "$DEADLINE_SECONDS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "Restore drill limits must be positive integers." >&2; exit 1; }
done
(( DEADLINE_SECONDS <= 14400 )) || { echo "Restore drill deadline cannot exceed four hours." >&2; exit 1; }
DRILL_CPUS="${RESTORE_DRILL_CPUS:-1}"
DRILL_MEMORY="${RESTORE_DRILL_MEMORY:-2g}"
[[ "$DRILL_CPUS" =~ ^(0\.[1-9][0-9]?|1(\.0)?)$ ]] || { echo "Restore drill CPU limit must be between 0.1 and 1." >&2; exit 1; }
if [[ "$DRILL_MEMORY" =~ ^([1-9][0-9]*)[mM]$ ]]; then
  DRILL_MEMORY_MIB="${BASH_REMATCH[1]}"
elif [[ "$DRILL_MEMORY" =~ ^([12])[gG]$ ]]; then
  DRILL_MEMORY_MIB="$(( BASH_REMATCH[1] * 1024 ))"
else
  echo "Restore drill memory limit must be expressed in MiB or GiB and be at most 2 GiB." >&2
  exit 1
fi
(( DRILL_MEMORY_MIB <= 2048 )) || { echo "Restore drill memory limit cannot exceed 2 GiB." >&2; exit 1; }
FREE_BYTES="$(df --output=avail -B1 "$BACKUP_DIR" | tail -1 | tr -d ' ')"
(( FREE_BYTES >= MIN_FREE_BYTES )) || {
  echo "Restore drill needs at least ${MIN_FREE_BYTES} free bytes; only ${FREE_BYTES} are available." >&2
  exit 1
}

TOKEN="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}"
[[ "$TOKEN" =~ ^[0-9TZ-]+$ ]] || exit 1
CONTAINER="prospect-restore-drill-${TOKEN}"
VOLUME="prospect-restore-drill-${TOKEN}"
LABEL="com.clearroad.restore-drill=${TOKEN}"
DRILL_DB="restore_drill"
DRILL_PASSWORD="drill-${TOKEN}-${RANDOM}"
WORK_DIR="$(mktemp -d)"
chmod 700 "$WORK_DIR"
CREATED_CONTAINER=0
CREATED_VOLUME=0
MONITOR_PID=""
MAIN_PID="$$"
DRILL_PHASE="preflight"
DRILL_VERIFIED=0
START_EPOCH="$(date +%s)"

remaining_deadline() {
  local elapsed remaining
  elapsed="$(( $(date +%s) - START_EPOCH ))"
  remaining="$(( DEADLINE_SECONDS - elapsed ))"
  (( remaining > 0 )) || { echo "Isolated restore exceeded its overall deadline." >&2; return 1; }
  printf '%s\n' "$remaining"
}

bounded_deadline() {
  local cap="$1" remaining
  remaining="$(remaining_deadline)" || return 1
  if (( remaining < cap )); then printf '%s\n' "$remaining"; else printf '%s\n' "$cap"; fi
}

restore_failure_category() {
  local log_file="$1" decompressor_status="$2" pg_restore_status="$3" oom_state="$4"
  if [[ "$oom_state" == "true" ]]; then printf 'out_of_memory\n'
  elif (( pg_restore_status == 124 || pg_restore_status == 137 )); then printf 'deadline\n'
  elif grep -Eqi '(^|[^0-9A-Z])57014([^0-9A-Z]|$)|statement timeout|canceling statement due to statement timeout' "$log_file"; then printf 'statement_timeout\n'
  elif grep -Eqi '(^|[^0-9A-Z])42501([^0-9A-Z]|$)|permission denied|must be owner|not permitted' "$log_file"; then printf 'permission_denied\n'
  elif grep -Eqi '(^|[^0-9A-Z])(23505|23P01)([^0-9A-Z]|$)|duplicate key|violates .* constraint|could not create unique index' "$log_file"; then printf 'constraint_violation\n'
  elif grep -Eqi '(^|[^0-9A-Z])(42704|58P01)([^0-9A-Z]|$)|does not exist|could not open extension control file|extension .* is not available|no such file' "$log_file"; then printf 'missing_dependency\n'
  elif grep -Eqi 'input file is too short|did not find magic string|unsupported version|could not read from input file|invalid archive' "$log_file"; then printf 'archive\n'
  # pg_restore can stop reading as soon as it finds an error. The resulting
  # upstream SIGPIPE is secondary evidence, not proof that the archive is bad.
  elif (( decompressor_status != 0 && decompressor_status != 141 )); then printf 'archive\n'
  else printf 'unknown\n'
  fi
}

restore_failure_toc_entry() {
  local log_file="$1" line
  while IFS= read -r line; do
    if [[ "$line" =~ from[[:space:]]+TOC[[:space:]]+entry[[:space:]]+([0-9]+)\; ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"$log_file"
  printf 'unknown\n'
}

write_backup_attempt running "$DRILL_PHASE" "$STAMP" "$STAMP" restore_drill

cleanup_drill() {
  local status=$? cleanup_failed=0 actual
  trap - EXIT INT TERM
  [[ -z "$MONITOR_PID" ]] || { kill "$MONITOR_PID" >/dev/null 2>&1 || true; wait "$MONITOR_PID" 2>/dev/null || true; }
  if (( CREATED_CONTAINER )); then
    actual="$(timeout 10 docker inspect --format '{{ index .Config.Labels "com.clearroad.restore-drill" }}' "$CONTAINER" 2>/dev/null)" || cleanup_failed=1
    if [[ "$actual" == "$TOKEN" ]]; then timeout 60 docker rm -f "$CONTAINER" >/dev/null 2>&1 || cleanup_failed=1
    elif [[ -n "$actual" ]]; then cleanup_failed=1
    fi
  fi
  if (( CREATED_VOLUME )); then
    actual="$(timeout 10 docker volume inspect --format '{{ index .Labels "com.clearroad.restore-drill" }}' "$VOLUME" 2>/dev/null)" || cleanup_failed=1
    if [[ "$actual" == "$TOKEN" ]]; then timeout 60 docker volume rm "$VOLUME" >/dev/null 2>&1 || cleanup_failed=1; else cleanup_failed=1; fi
  fi
  if (( status == 0 && cleanup_failed != 0 )); then
    echo "Restore passed, but cleanup could not be proven; labelled drill resources were retained." >&2
    status=1
  fi
  if (( status == 0 && DRILL_VERIFIED == 1 )); then
    write_backup_attempt complete complete "$STAMP" "$STAMP" restore_drill
    write_backup_stage restore_drill verified "$STAMP" "$STAMP" "$OBJECTS" "$BACKUP_BYTES"
    echo "Isolated restore drill passed for ${STAMP}: archive, ownership, ACLs, invariants and scheduler suppression verified; labelled resources were removed."
  else
    (( status != 0 )) || status=1
    write_backup_attempt failed "$DRILL_PHASE" "$STAMP" "$STAMP" restore_drill || true
  fi
  [[ -z "${WORK_DIR:-}" || ! -d "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
  exit "$status"
}
trap cleanup_drill EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CREATED_VOLUME=1
timeout "$(bounded_deadline 60)" docker volume create --label "$LABEL" "$VOLUME" >/dev/null
DRILL_PHASE="container_start"
write_backup_attempt running "$DRILL_PHASE" "$STAMP" "$STAMP" restore_drill
CREATED_CONTAINER=1
timeout "$(bounded_deadline 180)" docker run --detach --name "$CONTAINER" --label "$LABEL" \
  --network none --cpus "$DRILL_CPUS" --memory "$DRILL_MEMORY" --memory-swap "$DRILL_MEMORY" --pids-limit 256 \
  --mount "type=volume,source=${VOLUME},target=/var/lib/postgresql/data" \
  --env "POSTGRES_PASSWORD=${DRILL_PASSWORD}" --env POSTGRES_DB=postgres \
  "$IMAGE" postgres -c config_file=/etc/postgresql/postgresql.conf \
    -c shared_buffers=256MB -c work_mem=4MB -c maintenance_work_mem=128MB \
    -c max_connections=20 -c max_worker_processes=4 -c max_parallel_workers=1 \
    -c max_parallel_workers_per_gather=1 -c max_parallel_maintenance_workers=1 \
    -c "cron.database_name=${DRILL_DB}" -c cron.launch_active_jobs=off \
    -c pg_net.database_name=restore_drill_disabled >/dev/null

ready=0
for _ in $(seq 1 90); do
  if timeout "$(bounded_deadline 10)" docker exec -e "PGPASSWORD=${DRILL_PASSWORD}" "$CONTAINER" pg_isready -U supabase_admin -h 127.0.0.1 -d postgres >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
(( ready == 1 )) || { echo "Isolated PostgreSQL did not become ready." >&2; exit 1; }

# Enforce the temporary-data ceiling during the restore. Command-line scheduler
# settings were applied before startup, so restored cron/net queues cannot run.
(
  probe_failures=0
  while true; do
    actual="$(timeout 10 docker inspect --format '{{ index .Config.Labels "com.clearroad.restore-drill" }}' "$CONTAINER" 2>/dev/null || true)"
    if [[ "$actual" != "$TOKEN" ]]; then
      echo "Isolated restore ownership monitoring failed closed." >&2
      kill -TERM "$MAIN_PID" >/dev/null 2>&1 || true
      exit 92
    fi
    size="$(timeout 10 docker exec "$CONTAINER" du -sb /var/lib/postgresql/data 2>/dev/null | awk '{print $1}' || true)"
    host_free="$(timeout 10 df --output=avail -B1 "$BACKUP_DIR" 2>/dev/null | tail -1 | tr -d ' ' || true)"
    if [[ ! "$size" =~ ^[0-9]+$ || ! "$host_free" =~ ^[0-9]+$ ]]; then
      probe_failures="$(( probe_failures + 1 ))"
      if (( probe_failures >= 3 )); then
        echo "Isolated restore resource monitoring failed closed." >&2
        timeout 20 docker stop --time 10 "$CONTAINER" >/dev/null 2>&1 || true
        kill -TERM "$MAIN_PID" >/dev/null 2>&1 || true
        exit 92
      fi
      sleep 10
      continue
    fi
    probe_failures=0
    if (( size > MAX_DATA_BYTES || host_free < HOST_RESERVE_BYTES )); then
      echo "Isolated restore exceeded its ${MAX_DATA_BYTES}-byte data ceiling." >&2
      timeout 20 docker stop --time 10 "$CONTAINER" >/dev/null 2>&1 || true
      kill -TERM "$MAIN_PID" >/dev/null 2>&1 || true
      exit 91
    fi
    sleep 30
  done
) &
MONITOR_PID=$!

DRILL_PHASE="globals_restore"
write_backup_attempt running "$DRILL_PHASE" "$STAMP" "$STAMP" restore_drill
globals_log="${WORK_DIR}/globals.log"
: >"$globals_log"
chmod 600 "$globals_log"
set +e
zstd -dc "$BACKUP/globals.sql.zst" \
  | sed -E "s/[[:space:]]+PASSWORD[[:space:]]+('[^']*'|NULL)//Ig" \
  | timeout --signal=TERM --kill-after=30 "$(remaining_deadline)s" docker exec -i -e "PGPASSWORD=${DRILL_PASSWORD}" "$CONTAINER" \
      psql -X -U supabase_admin -h 127.0.0.1 -d template1 -q -v ON_ERROR_STOP=0 --set=VERBOSITY=verbose \
      >"$globals_log" 2>&1
statuses=("${PIPESTATUS[@]}")
set -e
unexpected="$(grep -E 'ERROR:[[:space:]]+[0-9A-Z]{5}:' "$globals_log" | grep -Ev 'ERROR:[[:space:]]+42710:' || true)"
rm -f -- "$globals_log"
if (( statuses[0] != 0 || statuses[1] != 0 || statuses[2] != 0 )) || [[ -n "$unexpected" ]]; then
  echo "Isolated global-role restore failed." >&2
  exit 1
fi

timeout --signal=TERM --kill-after=30 "$(bounded_deadline 60)s" docker exec -e "PGPASSWORD=${DRILL_PASSWORD}" "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -h 127.0.0.1 -d postgres \
  -c "create database ${DRILL_DB} with template template0 owner supabase_admin;" >/dev/null

DRILL_PHASE="database_restore"
write_backup_attempt running "$DRILL_PHASE" "$STAMP" "$STAMP" restore_drill
restore_log="${WORK_DIR}/restore.log"
: >"$restore_log"
chmod 600 "$restore_log"
restore_started_epoch="$(date +%s)"
set +e
zstd -dc "$BACKUP/database.dump.zst" \
  | timeout --signal=TERM --kill-after=60 "$(remaining_deadline)s" docker exec -i -e "PGPASSWORD=${DRILL_PASSWORD}" "$CONTAINER" \
      pg_restore -U supabase_admin -h 127.0.0.1 -d "$DRILL_DB" --jobs=1 --exit-on-error \
      >"$restore_log" 2>&1
restore_statuses=("${PIPESTATUS[@]}")
set -e
decompressor_status="${restore_statuses[0]:-125}"
pg_restore_status="${restore_statuses[1]:-125}"
if (( decompressor_status != 0 || pg_restore_status != 0 )); then
  oom_state="$(timeout 10 docker inspect --format '{{.State.OOMKilled}}' "$CONTAINER" 2>/dev/null || true)"
  [[ "$oom_state" == "true" || "$oom_state" == "false" ]] || oom_state="unknown"
  failure_category="$(restore_failure_category "$restore_log" "$decompressor_status" "$pg_restore_status" "$oom_state")"
  failure_toc_entry="$(restore_failure_toc_entry "$restore_log")"
  restore_elapsed="$(( $(date +%s) - restore_started_epoch ))"
  printf 'Isolated database restore failed: category=%s decompressor_status=%s pg_restore_status=%s elapsed_seconds=%s oom=%s toc_entry=%s. Raw restore output was suppressed.\n' \
    "$failure_category" "$decompressor_status" "$pg_restore_status" "$restore_elapsed" "$oom_state" "$failure_toc_entry" >&2
  rm -f -- "$restore_log"
  if (( pg_restore_status != 0 )); then exit "$pg_restore_status"; else exit "$decompressor_status"; fi
fi
rm -f -- "$restore_log"

DRILL_PHASE="verify"
write_backup_attempt running "$DRILL_PHASE" "$STAMP" "$STAMP" restore_drill
verify_log="${WORK_DIR}/verify.log"
: >"$verify_log"
chmod 600 "$verify_log"
if ! timeout --signal=TERM --kill-after=30 "$(remaining_deadline)s" docker exec -i -e "PGPASSWORD=${DRILL_PASSWORD}" "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -h 127.0.0.1 -d "$DRILL_DB" \
  < scripts/restore-verify.sql >"$verify_log" 2>&1; then
  echo "Isolated restored-data, ownership or ACL verification failed." >&2
  exit 1
fi
scheduler_settings="$(timeout --signal=TERM --kill-after=5 "$(bounded_deadline 30)" docker exec -e "PGPASSWORD=${DRILL_PASSWORD}" "$CONTAINER" psql -XAtq -U supabase_admin -h 127.0.0.1 -d "$DRILL_DB" -c \
  "select current_setting('cron.launch_active_jobs', true) || '|' || current_setting('cron.database_name', true) || '|' || current_setting('pg_net.database_name', true);")"
[[ "$scheduler_settings" == "off|${DRILL_DB}|restore_drill_disabled" ]] || {
  echo "Isolated scheduler suppression could not be proven." >&2; exit 1;
}
DRILL_VERIFIED=1
