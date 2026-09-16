#!/usr/bin/env bash
# Nightly backup: globals + full database, verified, pruned, pushed offsite.
#
#   ./scripts/backup.sh
#
# Installed as a systemd timer by scripts/install-cron.sh.
#
# A backup you have never restored is a hypothesis, not a backup. Run
# ./scripts/restore.sh --verify-only once a month; it is in the runbook for a
# reason.
set -euo pipefail

cd "$(dirname "$0")/.."
source "$(dirname "$0")/_env.sh"
load_env .env

BACKUP_DIR="${BACKUP_DIR:-/var/backups/prospect}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RETENTION="${BACKUP_RETENTION_DAYS:-7}"

[[ "$BACKUP_DIR" == /* ]] || { echo "BACKUP_DIR must be an absolute path." >&2; exit 1; }
[[ "$RETENTION" =~ ^[0-9]+$ ]] || { echo "BACKUP_RETENTION_DAYS must be a non-negative integer." >&2; exit 1; }
mkdir -p "$BACKUP_DIR"
BACKUP_DIR="$(realpath -- "$BACKUP_DIR")"
case "$BACKUP_DIR" in
  /|/var|/var/backups|/home|/root)
    echo "Refusing to use broad backup directory: ${BACKUP_DIR}" >&2
    exit 1
    ;;
esac
DEST="${BACKUP_DIR}/${STAMP}"
mkdir -p "$DEST"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

pg() { docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" db "$@"; }

log "Dumping roles and grants"
pg pg_dumpall -U postgres -h 127.0.0.1 --globals-only \
  | zstd -q -3 -o "${DEST}/globals.sql.zst"

log "Dumping ${POSTGRES_DB}"
# Custom format: parallel restore, selective restore, and built-in compression
# metadata. -Z0 because zstd outside does a better job than pg_dump's gzip.
pg pg_dump -U postgres -h 127.0.0.1 -d "$POSTGRES_DB" -Fc -Z0 \
  | zstd -q -3 -o "${DEST}/database.dump.zst"

log "Verifying the dump is readable"
# Catches truncation and a half-written file now, rather than during an outage.
zstd -dc "${DEST}/database.dump.zst" | {
  # pg_restore --list only needs the archive header and exits early. Keep the
  # pipe open and drain the remaining stream, otherwise zstd gets SIGPIPE and
  # pipefail aborts every successful backup BEFORE its offsite copy/pruning.
  # Preserve pg_restore's error, and consume the entire zstd stream so checksum
  # or truncation errors still fail the outer pipeline. This is not a restore drill.
  manifest_status=0
  pg pg_restore --list > "${DEST}/manifest.txt" || manifest_status=$?
  cat >/dev/null
  exit "$manifest_status"
}
objects="$(wc -l < "${DEST}/manifest.txt")"
(( objects > 50 )) || { log "FAILED: dump manifest has only ${objects} entries"; exit 1; }

cat > "${DEST}/meta.json" <<EOF
{
  "created_at": "${STAMP}",
  "database": "${POSTGRES_DB}",
  "objects": ${objects},
  "postgres_image": "supabase/postgres:${POSTGRES_IMAGE_TAG}",
  "app_image": "${APP_IMAGE}",
  "bytes": $(du -sb "$DEST" | cut -f1)
}
EOF

log "Local backup complete: ${DEST} ($(du -sh "$DEST" | cut -f1), ${objects} objects)"

# ── Offsite ────────────────────────────────────────────────────────────────
# Backups that live only on the machine they protect are not backups. Point
# RESTIC_REPOSITORY at Cloudflare R2 or Backblaze B2.
if [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
  log "Pushing to ${RESTIC_REPOSITORY}"

  # PACE THE REMOTE, BECAUSE GOOGLE DRIVE IS THE BINDING CONSTRAINT. 140 quota
  # rejections across five nights in the last fortnight, all of them
  # "Quota exceeded for quota metric 'Queries' and limit 'Requests per minute'".
  # The 2026-09-16 run got through by retrying for 28 minutes; 2026-09-10 did
  # not get through at all, dying on a Drive 500. restic runs rclone as a
  # subprocess, so its flags are set the only way they can be here - through
  # RCLONE_* environment variables, which rclone reads for any flag. Each is
  # overridable from .env so a different remote can be tuned without editing
  # this file.
  export RCLONE_TPSLIMIT="${RCLONE_TPSLIMIT:-8}"
  export RCLONE_TPSLIMIT_BURST="${RCLONE_TPSLIMIT_BURST:-8}"
  export RCLONE_DRIVE_PACER_MIN_SLEEP="${RCLONE_DRIVE_PACER_MIN_SLEEP:-200ms}"
  export RCLONE_DRIVE_PACER_BURST="${RCLONE_DRIVE_PACER_BURST:-50}"
  # Drive answers 500 as well as 403 under load, and both are transient. Ten
  # retries was not enough on 2026-09-10.
  export RCLONE_LOW_LEVEL_RETRIES="${RCLONE_LOW_LEVEL_RETRIES:-20}"

  # A TRANSIENT READ MUST NOT BE MISTAKEN FOR AN ABSENT REPOSITORY. This was
  # `restic snapshots >/dev/null 2>&1 || restic init`, and it silently destroyed
  # two nights of offsite backup: on 13 and 15 September the listing failed for
  # its own reasons, the fallback ran `restic init` against a repository that
  # already existed, and the whole script died on
  # "Fatal: create repository ... failed: config file already exists" - with
  # set -e taking the upload down with it. A convenience for first-run setup
  # became the single most common cause of a missing offsite copy.
  #
  # `cat config` is also the right probe: one small object rather than a full
  # snapshot listing, so it is both cheaper and less likely to be the thing that
  # trips over a quota.
  if ! restic cat config >/dev/null 2>&1; then
    if init_output="$(restic init 2>&1)"; then
      log "Initialised a new restic repository."
    elif grep -q 'config file already exists' <<<"$init_output"; then
      # The repository IS there; the probe above failed for another reason.
      # Carrying on is correct - the backup below will surface a real problem
      # on its own, and refusing here would abandon a backup over a hiccup.
      log "Repository exists; the probe failed transiently. Continuing."
    else
      echo "$init_output" >&2
      exit 1
    fi
  fi

  restic backup "$DEST" --tag prospect-db --host prospect-vps

  # A STALE LOCK MUST NOT MAKE A GOOD BACKUP LOOK LIKE A FAILED ONE. A run
  # killed part-way through leaves a lock nothing clears, and every night after
  # it the upload succeeded and then forget died on the lock - so the service
  # exited 1 and the backup read as failed. Measured on 2026-09-16: five
  # snapshots were sitting safely offsite while the job had reported failure
  # every night since 8 September. `unlock` removes only locks whose process is
  # gone, so it cannot interrupt a run that is genuinely in progress.
  restic unlock

  # --group-by IS LOAD-BEARING. restic groups snapshots by host+paths by
  # default, and every backup here has a unique path
  # (/var/backups/prospect/<TIMESTAMP>). So each snapshot landed in a group of
  # its own, the policy kept "1 of 1" in each, and NOTHING was ever removed -
  # retention was a no-op dressed up as a policy, and the repository grew by
  # about a gigabyte a night forever. Grouping by tag puts every prospect-db
  # snapshot in one group, which is what the daily/weekly/monthly counts were
  # always meant to apply to. Verified with --dry-run against the live
  # repository before this change: default grouping printed five groups of one,
  # this grouping prints one group of five.
  restic forget --tag prospect-db --group-by host,tags \
    --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
  log "Offsite copy complete"
else
  log "WARNING: RESTIC_REPOSITORY is unset - this backup exists only on this VPS."
fi

log "Pruning local backups older than ${RETENTION} days"
find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d \
  -name '20[0-9][0-9][01][0-9][0-3][0-9]T[0-2][0-9][0-5][0-9][0-5][0-9]Z' \
  -mtime "+${RETENTION}" -exec rm -rf -- {} +

df -h /var | tail -1 | awk '{print "Disk after backup: " $3 " used, " $4 " available (" $5 ")"}'
