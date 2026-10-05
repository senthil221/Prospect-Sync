#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null || {
  echo "jq is required for the snapshot receipt regression." >&2
  exit 1
}

source deploy/scripts/backup-status.sh
source deploy/scripts/backup-offsite.sh
fixture_root="$(mktemp -d)"
trap 'rm -rf -- "$fixture_root"' EXIT
target="/var/backups/prospect/20261004T000000Z"

printf '%s\n' '[{"id":"a1b2c3","hostname":"prospect-vps","tags":["prospect-db"],"paths":["/var/backups/prospect/20261004T000000Z"]}]' >"$fixture_root/valid.json"
[[ "$(select_offsite_snapshot_id "$fixture_root/valid.json" "$target")" == "a1b2c3" ]]

printf '%s\n' '[]' >"$fixture_root/empty.json"
if select_offsite_snapshot_id "$fixture_root/empty.json" "$target" >/dev/null 2>&1; then
  echo "empty snapshot listing was accepted" >&2
  exit 1
fi

printf '%s\n' '[{"id":"a1b2c3","hostname":"other-host","tags":["prospect-db"],"paths":["/var/backups/prospect/20261004T000000Z"]}]' >"$fixture_root/mismatch.json"
if select_offsite_snapshot_id "$fixture_root/mismatch.json" "$target" >/dev/null 2>&1; then
  echo "mismatched snapshot was accepted" >&2
  exit 1
fi

printf '%s\n' '[{"id":"not-a-snapshot-id","hostname":"prospect-vps","tags":["prospect-db"],"paths":["/var/backups/prospect/20261004T000000Z"]}]' >"$fixture_root/nonhex.json"
if select_offsite_snapshot_id "$fixture_root/nonhex.json" "$target" >/dev/null 2>&1; then
  echo "invalid snapshot id was accepted" >&2
  exit 1
fi

printf '%s\n' '{not-json' >"$fixture_root/invalid.json"
if select_offsite_snapshot_id "$fixture_root/invalid.json" "$target" >/dev/null 2>&1; then
  echo "invalid JSON was accepted" >&2
  exit 1
fi

printf 'PASS: offsite snapshot receipt rejects empty, mismatched and malformed listings\n'

printf '%s\n' 'Fatal: quota exceeded for quota metric requests' >"$fixture_root/quota.log"
[[ "$(restic_failure_class "$fixture_root/quota.log")" == "terminal" ]]
printf '%s\n' 'server returned HTTP 500' >"$fixture_root/transient.log"
[[ "$(restic_failure_class "$fixture_root/transient.log")" == "transient" ]]
printf '%s\n' 'authentication failed' >"$fixture_root/auth.log"
[[ "$(restic_failure_class "$fixture_root/auth.log")" == "terminal" ]]
printf '%s\n' '403 forbidden: quota exceeded; is there a repository at the following location?' >"$fixture_root/combined-terminal.log"
if restic_repository_missing "$fixture_root/combined-terminal.log"; then
  echo "a terminal provider failure was mistaken for a missing repository" >&2
  exit 1
fi
printf '%s\n' 'repository does not exist' >"$fixture_root/missing-repository.log"
restic_repository_missing "$fixture_root/missing-repository.log"

mkdir -p "$fixture_root/mock-bin"
cat >"$fixture_root/mock-bin/restic" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$RESTIC_MOCK_LOG"
if [[ "${RESTIC_MOCK_MODE:-}" == combined ]]; then
  printf '%s\n' '403 forbidden: quota exceeded; is there a repository at the following location?' >&2
  exit 1
fi
if [[ "${RESTIC_MOCK_MODE:-}" == timeout ]]; then sleep 10; exit 1; fi
if [[ "$1" == init ]]; then exit 0; fi
printf '%s\n' 'repository does not exist' >&2
exit 1
EOF
chmod +x "$fixture_root/mock-bin/restic"
export RESTIC_MOCK_LOG="$fixture_root/restic-invocations.log"
old_path="$PATH"
PATH="$fixture_root/mock-bin:$PATH"
RESTIC_MOCK_MODE=combined
export RESTIC_MOCK_MODE
if probe_restic_repository 1 >/dev/null 2>&1; then
  echo "combined quota/403 probe unexpectedly succeeded" >&2
  exit 1
fi
! grep -q '^init$' "$RESTIC_MOCK_LOG"
: >"$RESTIC_MOCK_LOG"
RESTIC_COMMAND_TIMEOUT_SECONDS=1
RESTIC_MOCK_MODE=timeout
export RESTIC_COMMAND_TIMEOUT_SECONDS RESTIC_MOCK_MODE
if probe_restic_repository 1 >/dev/null 2>&1; then
  echo "timed-out repository probe unexpectedly succeeded" >&2
  exit 1
fi
! grep -q '^init$' "$RESTIC_MOCK_LOG"
unset RESTIC_COMMAND_TIMEOUT_SECONDS RESTIC_MOCK_MODE
PATH="$old_path"

backup_root="$fixture_root/backups"
mkdir -p "$backup_root/20261005T032631Z" "$backup_root/not-a-backup"
resolved="$(resolve_backup_within_root "$backup_root" "$backup_root/20261005T032631Z")"
[[ "$resolved" == "$backup_root/20261005T032631Z" ]]
if resolve_backup_within_root "$backup_root" "$backup_root/not-a-backup" >/dev/null 2>&1; then
  echo "unsafe backup directory was accepted" >&2
  exit 1
fi
if resolve_backup_within_root "$backup_root" "$fixture_root" >/dev/null 2>&1; then
  echo "backup path outside the configured root was accepted" >&2
  exit 1
fi
corrupt="$backup_root/20261005T032632Z"
mkdir -p "$corrupt"
printf 'not-zstd' >"$corrupt/database.dump.zst"
printf 'not-zstd' >"$corrupt/globals.sql.zst"
seq 1 51 >"$corrupt/manifest.txt"
printf '%s\n' '{"created_at":"20261005T032632Z","database":"postgres","objects":51,"postgres_image":"supabase/postgres:test"}' >"$corrupt/meta.json"
if validate_local_backup_for_upload "$corrupt" >/dev/null 2>&1; then
  echo "corrupt backup archive was accepted" >&2
  exit 1
fi

upload_script="$(cat deploy/scripts/backup-upload-existing.sh)"
[[ "$upload_script" == *'validate_local_backup_for_upload'* ]]
[[ "$upload_script" == *'flock -n 9'* ]]
[[ "$upload_script" != *'pg_dump'* ]]
[[ "$upload_script" != *'restic init'* ]]
[[ "$upload_script" != *'restic unlock'* ]]
[[ "$upload_script" != *'find "$BACKUP_DIR"'* ]]

drill_script="$(cat deploy/scripts/restore-isolated.sh)"
[[ "$drill_script" == *'--network none'* ]]
[[ "$drill_script" == *'DRILL_CPUS="${RESTORE_DRILL_CPUS:-1}"'* ]]
[[ "$drill_script" == *'DRILL_MEMORY="${RESTORE_DRILL_MEMORY:-2g}"'* ]]
[[ "$drill_script" == *'--memory-swap "$DRILL_MEMORY"'* ]]
[[ "$drill_script" == *'--jobs=1 --exit-on-error'* ]]
[[ "$drill_script" == *'cron.launch_active_jobs=off'* ]]
[[ "$drill_script" == *'pg_net.database_name=restore_drill_disabled'* ]]
[[ "$drill_script" == *'RESTORE_DRILL_MAX_DATA_BYTES'* ]]
[[ "$drill_script" == *'RESTORE_DRILL_TIMEOUT_SECONDS'* ]]
[[ "$drill_script" == *'com.clearroad.restore-drill'* ]]
[[ "$drill_script" == *'write_backup_stage restore_drill verified'* ]]
[[ "$drill_script" != *'docker compose exec'* ]]
[[ "$drill_script" != *'prospect-db'* ]]

printf 'PASS: offsite retry and isolated restore stay bounded, path-safe and fail closed\n'
