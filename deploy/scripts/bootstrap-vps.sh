#!/usr/bin/env bash
# One-time provisioning for a fresh Hostinger KVM 2 (Ubuntu 24.04 LTS).
# Idempotent - re-running it is safe and is the fastest way to re-assert the
# hardening after any manual poking.
#
# Run as root on the VPS:
#   bash bootstrap-vps.sh 'ssh-ed25519 AAAA... you@laptop'
set -euo pipefail

SSH_PUBLIC_KEY="${1:-}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
SWAP_SIZE="${SWAP_SIZE:-4G}"

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -n "$SSH_PUBLIC_KEY" ]] || { echo "Usage: bash bootstrap-vps.sh '<your ssh public key>'" >&2; exit 1; }

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  ca-certificates curl gnupg git ufw fail2ban unattended-upgrades \
  restic jq htop ncdu postgresql-client-16 zstd

log "Deploy user: ${DEPLOY_USER}"
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG sudo "$DEPLOY_USER"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/${DEPLOY_USER}/.ssh"
touch "/home/${DEPLOY_USER}/.ssh/authorized_keys"
grep -qxF "$SSH_PUBLIC_KEY" "/home/${DEPLOY_USER}/.ssh/authorized_keys" \
  || echo "$SSH_PUBLIC_KEY" >> "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chown "$DEPLOY_USER:$DEPLOY_USER" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
# Passwordless sudo so the GitHub Actions deploy does not need a TTY.
echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${DEPLOY_USER}"
chmod 440 "/etc/sudoers.d/90-${DEPLOY_USER}"

log "SSH hardening"
# The 00- prefix is load-bearing. sshd takes the FIRST occurrence of each
# keyword, and drop-ins load in lexical order, so Ubuntu cloud images silently
# win with /etc/ssh/sshd_config.d/50-cloud-init.conf containing
# "PasswordAuthentication yes". A 99- file is read but never applied - the box
# looks hardened and still accepts passwords.
rm -f /etc/ssh/sshd_config.d/99-prospect.conf
cat > /etc/ssh/sshd_config.d/00-prospect.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

# cloud-init rewrites its own drop-in on boot, so also tell it to stop asking
# for password auth in the first place.
cat > /etc/cloud/cloud.cfg.d/99-disable-password-auth.cfg <<'EOF'
ssh_pwauth: false
EOF

# Verify before restarting - a bad config here locks you out permanently.
sshd -t
systemctl restart ssh

# Assert the settings actually took effect. Writing a config file is not the
# same as it winning, and a silent failure here is the difference between a
# hardened box and one that still accepts passwords on a public port.
for setting in "permitrootlogin no" "passwordauthentication no"; do
  key="${setting%% *}"
  want="${setting##* }"
  got="$(sshd -T | grep -i "^${key} " | awk '{print $2}')"
  if [[ "$got" != "$want" ]]; then
    echo "FATAL: sshd ${key} is '${got}', expected '${want}'." >&2
    echo "Something else in /etc/ssh/sshd_config.d/ is taking precedence." >&2
    exit 1
  fi
done

log "Firewall"
# IMPORTANT: Docker inserts its own iptables rules ahead of ufw's, so a
# container that publishes 0.0.0.0:5432 is reachable from the internet even
# with ufw denying it. The compose file therefore binds every non-Caddy port to
# 127.0.0.1. Do not change those bindings without also installing ufw-docker.
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'ssh'
ufw allow 80/tcp comment 'http (acme + redirect)'
ufw allow 443/tcp comment 'https'
ufw allow 443/udp comment 'http3'
ufw --force enable

log "fail2ban"
cat > /etc/fail2ban/jail.d/prospect.local <<'EOF'
[sshd]
enabled = true
maxretry = 4
findtime = 10m
bantime = 24h
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

log "Unattended security upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
# Security patches apply automatically; reboots stay manual so a kernel update
# never restarts the box mid-import.
sed -i 's|^//\s*Unattended-Upgrade::Automatic-Reboot .*|Unattended-Upgrade::Automatic-Reboot "false";|' \
  /etc/apt/apt.conf.d/50unattended-upgrades || true

log "Swap (${SWAP_SIZE})"
# 8 GB is enough until a big import spikes. Swap is the difference between a
# slow minute and the OOM killer taking out PostgreSQL mid-write.
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "Kernel tuning"
cat > /etc/sysctl.d/99-prospect.conf <<'EOF'
# Swap only under real pressure - never to reclaim PostgreSQL's page cache.
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
fs.file-max = 200000
EOF
sysctl --quiet --system

# Transparent hugepages cause latency spikes in PostgreSQL.
cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable transparent hugepages
After=sysinit.target local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now disable-thp.service

log "Docker"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "$DEPLOY_USER"

# Global log cap. Without this a chatty container fills 100 GB of NVMe and the
# first symptom is PostgreSQL refusing to write.
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
systemctl restart docker

log "Application directory"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/prospect
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" /var/backups/prospect

cat <<EOF

Done.

  Next steps, as ${DEPLOY_USER}:
    ssh ${DEPLOY_USER}@<vps-ip>
    git clone https://github.com/senthil221/Prospect-Sync.git /opt/prospect
    cd /opt/prospect/deploy
    cp .env.example .env && \$EDITOR .env
    ./scripts/gen-secrets.sh

  Strongly recommended before exposing Studio:
    curl -fsSL https://tailscale.com/install.sh | sh && tailscale up
    ...then point studio.<domain> at the tailnet IP instead of the public one.

EOF
