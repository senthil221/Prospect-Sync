#!/usr/bin/env bash
# Ban repeated failed Studio logins at the firewall.
#
# fail2ban (installed by bootstrap-vps.sh) only watches sshd out of the box.
# That's fine while Studio is locked to Tailscale/loopback - but once
# STUDIO_ALLOWED_CIDRS is widened (e.g. "0.0.0.0/0 ::/0" for access from
# arbitrary IPs), basic auth becomes the only gate on the full database admin
# UI, with no rate limit on guesses. Run this once after that change.
#
#   ./scripts/setup-studio-fail2ban.sh
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="$(docker compose config --format json | jq -r .name)"
LOGDIR="$(docker volume inspect "${PROJECT}_caddy-data" --format '{{.Mountpoint}}')/logs"
LOGPATH="${LOGDIR}/studio.log"

# The volume is root-owned (Caddy runs as root in its container), so check as
# root rather than as the deploy user, which can't even stat it.
sudo test -d "$LOGDIR" || { echo "No $LOGDIR yet - start the stack (docker compose up -d) first." >&2; exit 1; }

sudo tee /etc/fail2ban/filter.d/caddy-studio.conf >/dev/null <<'EOF'
# Matches Caddy's JSON access log for the Studio site: a failed basic-auth
# attempt logs "status":401 on the same line as the client's "client_ip".
[Definition]
failregex = "client_ip":"<HOST>".*"status":401
ignoreregex =
datepattern = EPOCH
EOF

sudo tee /etc/fail2ban/jail.d/studio.local >/dev/null <<EOF
[caddy-studio]
enabled = true
filter = caddy-studio
logpath = ${LOGPATH}
maxretry = 5
findtime = 10m
bantime = 1h
EOF

sudo systemctl restart fail2ban
echo "fail2ban is now watching ${LOGPATH} for repeated Studio 401s."
sudo fail2ban-client status caddy-studio
