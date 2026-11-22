#!/usr/bin/env bash
# Prepares a clean Ubuntu 24.04 server for the Faclab stack (S8.1). Run it once, as root, on the new
# server (README, "Aprovisionar el servidor"):
#
#   provision-vps.sh <deploy user> <SSH public key, the line itself or a file>
#
# - the deploy user, with that key, sudo without password and the docker group (which is root's
#   equivalent: the key is the server's key);
# - SSH only with keys, without root;
# - ufw: incoming 22, 80, 443 and 443/udp, outgoing everything. Docker writes its own iptables
#   rules for published ports, before ufw's: what keeps the rest closed is that only caddy
#   publishes ports (nmap checks it);
# - automatic security updates (unattended-upgrades), without automatic reboots;
# - Docker Engine and the compose plugin from Docker's apt repository, with rotated logs;
# - UDP buffers for HTTP/3 (quic-go asks for 7.5 MB);
# - /opt/faclab for the checkout of faclab-infra, owned by the deploy user, and /etc/faclab for
#   the secrets, root's.
#
# It is idempotent: running it again only changes what differs.
set -euo pipefail

DEPLOY_USER="${1:?usage: provision-vps.sh <deploy user> <SSH public key or file>}"
KEY_ARG="${2:?usage: provision-vps.sh <deploy user> <SSH public key or file>}"

die() {
  echo "provision-vps.sh: $*" >&2
  exit 1
}

[ "$(id -u)" = 0 ] || die "run it as root"
# shellcheck source=/dev/null
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "it is written for Ubuntu (found ${ID:-unknown})"

if [ -f "$KEY_ARG" ]; then
  PUBLIC_KEY="$(cat "$KEY_ARG")"
else
  PUBLIC_KEY="$KEY_ARG"
fi
case "$PUBLIC_KEY" in
  ssh-ed25519\ * | ssh-rsa\ * | ecdsa-sha2-*\ * | sk-*\ *) ;;
  *) die "the second argument isn't an SSH public key" ;;
esac

export DEBIAN_FRONTEND=noninteractive

echo "== Packages"
apt-get update -q
apt-get upgrade -yq
apt-get install -yq ca-certificates curl gnupg git openssh-server ufw unattended-upgrades

echo "== Deploy user: $DEPLOY_USER"
if ! id "$DEPLOY_USER" > /dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEPLOY_USER"
fi
# Without a password it can't log in by password anyway; sudo without one for the same reason
passwd --lock "$DEPLOY_USER" > /dev/null
install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
AUTHORIZED="/home/$DEPLOY_USER/.ssh/authorized_keys"
touch "$AUTHORIZED"
grep -qxF "$PUBLIC_KEY" "$AUTHORIZED" || printf '%s\n' "$PUBLIC_KEY" >> "$AUTHORIZED"
chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTHORIZED"
chmod 0600 "$AUTHORIZED"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEPLOY_USER" > /etc/sudoers.d/90-faclab-deploy
chmod 0440 /etc/sudoers.d/90-faclab-deploy
visudo -cf /etc/sudoers.d/90-faclab-deploy > /dev/null

echo "== SSH: keys only, no root"
cat > /etc/ssh/sshd_config.d/10-faclab.conf << 'EOF'
# Faclab (deploy/production/scripts/provision-vps.sh)
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
EOF
# sshd -t needs it, and only a running ssh service creates it (a machine reached by console)
install -d -m 0755 /run/sshd
sshd -t
systemctl enable --now ssh > /dev/null 2>&1 || true
systemctl reload ssh 2> /dev/null || systemctl restart ssh

echo "== Firewall (ufw)"
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow 22/tcp > /dev/null
ufw allow 80/tcp > /dev/null
ufw allow 443/tcp > /dev/null
ufw allow 443/udp > /dev/null
ufw --force enable > /dev/null
ufw status verbose

echo "== Automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades > /dev/null 2>&1 || true

echo "== Docker Engine"
if ! command -v docker > /dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "${VERSION_CODENAME:?}" > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
# Rotated logs for every container; live-restore keeps them running while the daemon updates
if [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "live-restore": true
}
EOF
  systemctl restart docker
fi
systemctl enable --now docker > /dev/null 2>&1
usermod -aG docker "$DEPLOY_USER"

echo "== UDP buffers for HTTP/3"
cat > /etc/sysctl.d/90-faclab.conf << 'EOF'
# Caddy's HTTP/3 (quic-go) asks for 7.5 MB of UDP buffers
net.core.rmem_max = 7500000
net.core.wmem_max = 7500000
EOF
sysctl --system > /dev/null

echo "== Directories"
install -d -m 0755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/faclab
install -d -m 0700 -o root -g root /etc/faclab

echo
echo "Done. Next, as $DEPLOY_USER (README, \"Primera instalación\"):"
echo "  git clone https://github.com/faclab-ec/faclab-infra.git /opt/faclab/faclab-infra"
docker --version
docker compose version
