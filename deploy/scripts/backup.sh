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
zstd -dc "${DEST}/database.dump.zst" | pg pg_restore --list > "${DEST}/manifest.txt"
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
  restic snapshots >/dev/null 2>&1 || restic init
  restic backup "$DEST" --tag prospect-db --host prospect-vps
  restic forget --tag prospect-db \
    --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
  log "Offsite copy complete"
else
  log "WARNING: RESTIC_REPOSITORY is unset — this backup exists only on this VPS."
fi

log "Pruning local backups older than ${RETENTION} days"
find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d \
  -name '20[0-9][0-9][01][0-9][0-3][0-9]T[0-2][0-9][0-5][0-9][0-5][0-9]Z' \
  -mtime "+${RETENTION}" -exec rm -rf -- {} +

df -h /var | tail -1 | awk '{print "Disk after backup: " $3 " used, " $4 " available (" $5 ")"}'
