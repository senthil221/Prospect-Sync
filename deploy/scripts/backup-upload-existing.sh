#!/usr/bin/env bash
# Retry only the offsite stage for an already verified local backup. This never
# creates a dump, initializes/unlocks a repository, prunes, or deletes files.
set -eEuo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
source "$(dirname "$0")/backup-status.sh"
source "$(dirname "$0")/backup-offsite.sh"
load_env .env

BACKUP_DIR="${BACKUP_DIR:-/var/backups/prospect}"
[[ "$BACKUP_DIR" == /* ]] || { echo "BACKUP_DIR must be absolute." >&2; exit 1; }
[[ $# -eq 1 ]] || { echo "Usage: ./scripts/backup-upload-existing.sh <timestamp-backup-directory>" >&2; exit 1; }
BACKUP_DIR="$(realpath -- "$BACKUP_DIR")"
exec 9>"${BACKUP_DIR}/.backup.lock"
flock -n 9 || { echo "Another backup or retention job is already running." >&2; exit 1; }
DEST="$(resolve_backup_within_root "$BACKUP_DIR" "$1")"
validate_local_backup_for_upload "$DEST"

STAMP="$(basename "$DEST")"
objects="$(wc -l < "${DEST}/manifest.txt")"
backup_bytes="$(du -sb "$DEST" | cut -f1)"
BACKUP_PHASE="offsite_probe"
write_backup_attempt running "$BACKUP_PHASE" "$STAMP" "$STAMP" offsite_retry
record_retry_exit() {
  local status=$?
  trap - EXIT
  if (( status == 0 )); then
    write_backup_attempt complete complete "$STAMP" "$STAMP" offsite_retry
  else
    write_backup_attempt failed "$BACKUP_PHASE" "$STAMP" "$STAMP" offsite_retry || true
  fi
  exit "$status"
}
trap record_retry_exit EXIT

upload_backup_offsite "$DEST" "$STAMP" "$objects" "$backup_bytes" 0 offsite_retry
echo "Existing backup uploaded and verified offsite: ${STAMP}"
