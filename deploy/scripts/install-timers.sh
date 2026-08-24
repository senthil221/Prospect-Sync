#!/usr/bin/env bash
# Install systemd timers for backups and weekly maintenance.
# systemd rather than cron: it survives reboots cleanly, catches up on missed
# runs, and `systemctl status` tells you why the last one failed.
#
#   sudo ./scripts/install-timers.sh
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_AS="${SUDO_USER:-deploy}"

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

write_unit() {
  cat > "/etc/systemd/system/$1"
  echo "  wrote /etc/systemd/system/$1"
}

write_unit prospect-backup.service <<EOF
[Unit]
Description=Prospect Sync database backup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=${RUN_AS}
WorkingDirectory=${DEPLOY_DIR}
ExecStart=${DEPLOY_DIR}/scripts/backup.sh
TimeoutStartSec=3600
EOF

write_unit prospect-backup.timer <<'EOF'
[Unit]
Description=Nightly Prospect Sync backup

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF

write_unit prospect-maintenance.service <<EOF
[Unit]
Description=Prospect Sync weekly database maintenance
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
User=${RUN_AS}
WorkingDirectory=${DEPLOY_DIR}
ExecStart=${DEPLOY_DIR}/scripts/maintenance.sh
TimeoutStartSec=7200
EOF

write_unit prospect-maintenance.timer <<'EOF'
[Unit]
Description=Weekly Prospect Sync database maintenance

[Timer]
OnCalendar=Sun *-*-* 04:30:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now prospect-backup.timer prospect-maintenance.timer

echo
systemctl list-timers 'prospect-*' --no-pager
cat <<'EOF'

Run one now to confirm it works end to end:
  sudo systemctl start prospect-backup.service
  journalctl -u prospect-backup.service -n 50 --no-pager
EOF
