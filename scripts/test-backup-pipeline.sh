#!/usr/bin/env bash
# Bounded synthetic regression; no database, backup files or credentials needed.
set -euo pipefail
producer() { head -c 1048576 /dev/zero; }
early_reader() { head -c 64 >/dev/null; }
checked_reader() {
  local result=0
  "$@" || result=$?
  cat >/dev/null
  return "$result"
}
if producer | early_reader; then
  echo 'Fixture did not reproduce early-consumer pipe failure' >&2
  exit 1
fi
producer | checked_reader early_reader
bad_reader() { head -c 64 >/dev/null; return 7; }
if producer | checked_reader bad_reader; then
  echo 'Reader failure was swallowed' >&2
  exit 1
fi
bad_producer() { producer; return 9; }
if bad_producer | checked_reader early_reader; then
  echo 'Producer/checksum failure was swallowed' >&2
  exit 1
fi
status_root="$(mktemp -d)"
trap 'rm -rf -- "$status_root"' EXIT
BACKUP_DIR="$status_root"
source deploy/scripts/backup-status.sh
write_backup_stage offsite uploaded 20261004T000000Z safe-backup 60 1024
grep -q '"state":"uploaded"' "$status_root/.status/offsite.json"
write_backup_stage offsite verified 20261004T000000Z safe-backup 60 1024 a1b2c3
verified_before="$(cat "$status_root/.status/offsite.json")"
write_backup_attempt failed offsite_verify 20261005T000000Z next-backup
[[ "$(cat "$status_root/.status/offsite.json")" == "$verified_before" ]]
write_backup_stage retention complete 20261004T010000Z
grep -q '"state":"verified"' "$status_root/.status/offsite.json"
grep -q '"state":"complete"' "$status_root/.status/retention.json"
retention_before="$(cat "$status_root/.status/retention.json")"
write_backup_attempt failed remote_prune 20261005T010000Z "" retention
[[ "$(cat "$status_root/.status/retention.json")" == "$retention_before" ]]
echo 'PASS: pipeline failures propagate and a failed next attempt preserves the verified receipt'
exit 0
