#!/usr/bin/env bash
# Weekly offsite retention. A slow or failed prune cannot change the nightly
# backup's upload result.
set -euo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
source "$(dirname "$0")/backup-status.sh"
load_env .env

BACKUP_DIR="${BACKUP_DIR:-/var/backups/prospect}"
RESTIC_VERIFIED_MAX_AGE_SECONDS="${RESTIC_VERIFIED_MAX_AGE_SECONDS:-172800}"
RESTIC_KEEP_DAILY="${RESTIC_KEEP_DAILY:-7}"
RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-5}"
RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-12}"
[[ -n "${RESTIC_REPOSITORY:-}" ]] || { echo "RESTIC_REPOSITORY is required for offsite retention." >&2; exit 1; }
[[ "$BACKUP_DIR" == /* ]] || { echo "BACKUP_DIR must be absolute." >&2; exit 1; }
for numeric_setting in RESTIC_VERIFIED_MAX_AGE_SECONDS RESTIC_KEEP_DAILY RESTIC_KEEP_WEEKLY RESTIC_KEEP_MONTHLY; do
  [[ "${!numeric_setting}" =~ ^[0-9]+$ ]] || { echo "${numeric_setting} must be a non-negative integer." >&2; exit 1; }
done
mkdir -p "$BACKUP_DIR"
BACKUP_DIR="$(realpath -- "$BACKUP_DIR")"
case "$BACKUP_DIR" in
  /|/var|/var/backups|/home|/root)
    echo "Refusing to use broad backup directory: ${BACKUP_DIR}" >&2
    exit 1
    ;;
esac
exec 9>"${BACKUP_DIR}/.backup.lock"
flock -n 9 || { echo "Another backup or retention job is already running." >&2; exit 1; }

retention_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
RETENTION_PHASE="preflight"
write_backup_attempt running "$RETENTION_PHASE" "$retention_stamp" "" retention
record_retention_exit() {
  local status=$?
  trap - EXIT
  if (( status == 0 )); then
    write_backup_attempt complete complete "$retention_stamp" "" retention
  else
    write_backup_attempt failed "$RETENTION_PHASE" "$retention_stamp" "" retention || true
  fi
  exit "$status"
}
trap record_retention_exit EXIT

offsite_receipt="${BACKUP_DIR}/.status/offsite.json"
[[ -f "$offsite_receipt" ]] || { echo "Refusing retention without a verified offsite receipt." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required to validate the offsite receipt." >&2; exit 1; }
jq -e '.stage == "offsite" and .state == "verified" and (.snapshot_id | type == "string" and test("^[A-Fa-f0-9]+$"))' \
  "$offsite_receipt" >/dev/null || { echo "Refusing retention: latest offsite receipt is not verified." >&2; exit 1; }
receipt_age=$(( $(date +%s) - $(stat -c %Y "$offsite_receipt") ))
(( receipt_age >= 0 && receipt_age <= RESTIC_VERIFIED_MAX_AGE_SECONDS )) || {
  echo "Refusing retention: verified offsite receipt is stale." >&2
  exit 1
}

export RCLONE_TPSLIMIT="${RCLONE_TPSLIMIT:-8}"
export RCLONE_TPSLIMIT_BURST="${RCLONE_TPSLIMIT_BURST:-8}"
export RCLONE_DRIVE_PACER_MIN_SLEEP="${RCLONE_DRIVE_PACER_MIN_SLEEP:-200ms}"
export RCLONE_DRIVE_PACER_BURST="${RCLONE_DRIVE_PACER_BURST:-50}"
export RCLONE_LOW_LEVEL_RETRIES="${RCLONE_LOW_LEVEL_RETRIES:-20}"

# Locks are an operator decision. An automated job cannot prove another host or
# process is not still using one, so it never calls `restic unlock`.
RETENTION_PHASE="remote_prune"
write_backup_attempt running "$RETENTION_PHASE" "$retention_stamp" "" retention
restic forget --tag prospect-db --group-by host,tags \
  --keep-daily "$RESTIC_KEEP_DAILY" \
  --keep-weekly "$RESTIC_KEEP_WEEKLY" \
  --keep-monthly "$RESTIC_KEEP_MONTHLY" --prune
write_backup_stage retention complete "$retention_stamp"
printf '[%s] Offsite retention complete\n' "$(date -u +%H:%M:%S)"
