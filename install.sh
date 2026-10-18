#!/usr/bin/env bash
# proxy — a hardened, self-hosted WireGuard VPN with a web admin UI, from one IP and root.
# https://github.com/paulfxyz/proxy
#
# Usage (as root, on a fresh VPS):
#   PROXY_DOMAIN=vpn.example.com PROXY_EMAIL=you@example.com bash install.sh
#
# Every setting is an environment variable. Nothing is interactive. Re-running is safe.
# Tested on CentOS Stream 9 (Hostkey "VPS 1 vCore / 1 GB"). Rocky/Alma 9 use the same path.
# Debian 12 / Ubuntu 22.04+ follow a best-effort branch that has NOT been verified yet.

set -euo pipefail

# ─── Settings ────────────────────────────────────────────────────────────────
PROXY_DOMAIN="${PROXY_DOMAIN:?Set PROXY_DOMAIN (e.g. vpn.example.com) — the FQDN that points to this server}"
PROXY_EMAIL="${PROXY_EMAIL:?Set PROXY_EMAIL — the ACME (Let’s Encrypt) contact address}"
PROXY_WG_PORT="${PROXY_WG_PORT:-51820}"        # WireGuard UDP port (public)
PROXY_SSH_PORT="${PROXY_SSH_PORT:-22}"         # SSH port kept open (public, key-only)
PROXY_SSH_PUBKEY="${PROXY_SSH_PUBKEY:-}"       # optional: public key to add to root's authorized_keys
PROXY_LOCK_SSH="${PROXY_LOCK_SSH:-auto}"       # auto|yes|no — disable password login (auto: only if a key is present)
PROXY_SKIP_UPDATE="${PROXY_SKIP_UPDATE:-0}"    # 1 = skip the full system update (slow on 1 vCPU)
PROXY_DIR="${PROXY_DIR:-/opt/proxy}"           # where compose.yml and Caddyfile live
PROXY_SET_HOSTNAME="${PROXY_SET_HOSTNAME:-1}"  # 1 = set the system hostname to PROXY_DOMAIN
PROXY_SWAP_MB="${PROXY_SWAP_MB:-1024}"         # swap to create when RAM < 2 GB and no swap exists (0 = never)
WG_EASY_IMAGE="${WG_EASY_IMAGE:-ghcr.io/wg-easy/wg-easy:15}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
. /etc/os-release
case "${ID}:${ID_LIKE:-}" in
  centos:*|rocky:*|almalinux:*|rhel:*|*:*rhel*|*:*fedora*) FAMILY=el ;;
  debian:*|ubuntu:*|*:*debian*)                           FAMILY=deb; warn "Debian/Ubuntu path is best-effort and not yet verified." ;;
  *) die "Unsupported distribution: ${PRETTY_NAME}" ;;
esac
log "Detected ${PRETTY_NAME} (${FAMILY})"

# ─── 0. Memory safety: swap before anything heavy ────────────────────────────
mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if (( PROXY_SWAP_MB > 0 )) && (( mem_mb < 2048 )) && [[ -z "$(swapon --noheadings --show 2>/dev/null)" ]]; then
  log "RAM is ${mem_mb} MB with no swap — creating ${PROXY_SWAP_MB} MB swap (package updates OOM on small VPS otherwise)"
  if [[ ! -f /swapfile ]]; then
    fallocate -l "${PROXY_SWAP_MB}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="${PROXY_SWAP_MB}" status=none
    chmod 600 /swapfile && mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap active"
fi

# ─── 1. Packages ─────────────────────────────────────────────────────────────
if [[ "$FAMILY" == el ]]; then
  if [[ "$PROXY_SKIP_UPDATE" != 1 ]]; then log "dnf update (this is the slow part on 1 vCPU)"; dnf -y -q update; fi
  dnf -y -q install epel-release
  dnf -y -q install curl wireguard-tools firewalld fail2ban fail2ban-systemd dnf-automatic policycoreutils-python-utils
  if ! command -v docker >/dev/null; then
    log "Installing Docker CE"
    dnf -y -q install dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf -y -q install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
else
  export DEBIAN_FRONTEND=noninteractive
  if [[ "$PROXY_SKIP_UPDATE" != 1 ]]; then log "apt upgrade"; apt-get -qq update && apt-get -qq -y upgrade; fi
  apt-get -qq -y install curl wireguard-tools firewalld fail2ban unattended-upgrades ca-certificates
  if ! command -v docker >/dev/null; then
    log "Installing Docker CE via get.docker.com"
    curl -fsSL https://get.docker.com | sh
  fi
fi
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
systemctl enable --now firewalld fail2ban >/dev/null 2>&1 || true
ok "Packages present"

# ─── 2. Kernel modules (WireGuard + legacy iptables tables used inside the container) ──
log "Kernel modules"
MODS=(wireguard ip_tables iptable_nat iptable_filter ip6_tables ip6table_nat ip6table_filter nf_nat xt_MASQUERADE)
for m in "${MODS[@]}"; do modprobe "$m" 2>/dev/null || warn "modprobe $m failed (may be built-in)"; done
printf '%s\n' "${MODS[@]}" > /etc/modules-load.d/proxy.conf
ok "Modules loaded and persisted (/etc/modules-load.d/proxy.conf)"

# ─── 3. sysctl ───────────────────────────────────────────────────────────────
cat > /etc/sysctl.d/99-proxy-hardening.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
vm.swappiness = 10
EOF
sysctl -q --system >/dev/null
ok "sysctl applied"

# ─── 4. SSH: key-only, root allowed with keys only ───────────────────────────
log "SSH hardening"
mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
if [[ -n "$PROXY_SSH_PUBKEY" ]] && ! grep -qF "$PROXY_SSH_PUBKEY" /root/.ssh/authorized_keys; then
  echo "$PROXY_SSH_PUBKEY" >> /root/.ssh/authorized_keys; ok "Public key added to root"
fi
have_key=$(grep -cE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || true)
lock=no
case "$PROXY_LOCK_SSH" in
  yes)  lock=yes ;;
  auto) (( have_key > 0 )) && lock=yes || warn "No authorized key for root — keeping password login ON. Add a key and re-run, or set PROXY_SSH_PUBKEY." ;;
esac
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-proxy-hardening.conf <<EOF
Port ${PROXY_SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication $([[ $lock == yes ]] && echo no || echo yes)
KbdInteractiveAuthentication $([[ $lock == yes ]] && echo no || echo yes)
ChallengeResponseAuthentication no
PubkeyAuthentication yes
GSSAPIAuthentication no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitEmptyPasswords no
MaxAuthTries 3
MaxSessions 4
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers root
EOF
# Distro drop-ins that re-enable passwords must not win (they are included after ours alphabetically, first match wins — but be explicit).
for f in /etc/ssh/sshd_config.d/50-redhat.conf /etc/ssh/sshd_config.d/50-cloud-init.conf; do
  [[ -f $f ]] && sed -i -E 's/^(PasswordAuthentication|PermitRootLogin)\s+.*/# \0  (overridden by 00-proxy-hardening.conf)/' "$f"
done
if [[ "$FAMILY" == el && "$PROXY_SSH_PORT" != 22 ]]; then semanage port -a -t ssh_port_t -p tcp "$PROXY_SSH_PORT" 2>/dev/null || true; fi
sshd -t || die "sshd config invalid — not restarting. Fix /etc/ssh/sshd_config.d/00-proxy-hardening.conf"
systemctl restart sshd 2>/dev/null || systemctl restart ssh
ok "sshd restarted (password login: $([[ $lock == yes ]] && echo OFF || echo still ON))"

# ─── 5. fail2ban ─────────────────────────────────────────────────────────────
cat > /etc/fail2ban/jail.d/proxy-sshd.local <<EOF
[sshd]
enabled = true
mode = aggressive
port = ${PROXY_SSH_PORT}
backend = systemd
maxretry = 3
findtime = 10m
bantime = 24h
bantime.increment = true
bantime.maxtime = 30d
EOF
systemctl restart fail2ban
ok "fail2ban sshd jail active"

# ─── 6. Firewall: deny by default, three doors ───────────────────────────────
log "firewalld public zone"
fw() { firewall-cmd -q --permanent --zone=public "$@" >/dev/null 2>&1 || true; }
fw --set-target=DROP
for s in cockpit dhcpv6-client ssh; do fw --remove-service="$s"; done
fw --add-port="${PROXY_SSH_PORT}/tcp"
fw --add-port="${PROXY_WG_PORT}/udp"
fw --add-port=443/tcp
fw --add-icmp-block-inversion   # listed ICMP types below are the ALLOWED ones
for t in echo-request echo-reply destination-unreachable time-exceeded fragmentation-needed packet-too-big; do fw --add-icmp-block="$t"; done
firewall-cmd -q --permanent --set-log-denied=off >/dev/null 2>&1 || true   # exit 2 when already set
firewall-cmd -q --reload || die "firewalld reload failed — inspect: firewall-cmd --permanent --zone=public --list-all"
ok "Public zone: DROP everything except tcp/${PROXY_SSH_PORT}, udp/${PROXY_WG_PORT}, tcp/443 (+ ping and PMTU ICMP)"

# ─── 7. Docker daemon ────────────────────────────────────────────────────────
if [[ -f /etc/docker/daemon.json ]] && grep -q '"iptables"[[:space:]]*:[[:space:]]*false' /etc/docker/daemon.json; then
  warn "daemon.json had \"iptables\": false — published ports would silently not work. Backing up and replacing."
  cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
fi
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "no-new-privileges": true,
  "live-restore": true
}
EOF
systemctl enable docker >/dev/null 2>&1; systemctl restart docker
ok "Docker running with log rotation, live-restore, no-new-privileges"

# ─── 8. The stack: wg-easy + Caddy ───────────────────────────────────────────
log "Writing ${PROXY_DIR}/compose.yml and Caddyfile"
mkdir -p "$PROXY_DIR"
cat > "${PROXY_DIR}/compose.yml" <<EOF
volumes:
  etc_wireguard:
  caddy_data:
  caddy_config:

services:
  wg-easy:
    image: ${WG_EASY_IMAGE}
    container_name: wg-easy
    environment:
      - PORT=51821
      - HOST=0.0.0.0
      - INSECURE=false
    networks:
      wg:
        ipv4_address: 10.42.42.42
        ipv6_address: fdcc:ad94:bacf:61a3::2a
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "${PROXY_WG_PORT}:51820/udp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1
    mem_limit: 256m

  caddy:
    image: ${CADDY_IMAGE}
    container_name: caddy
    networks:
      - wg
    ports:
      - "443:443/tcp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    restart: unless-stopped
    depends_on:
      - wg-easy
    mem_limit: 128m

networks:
  wg:
    driver: bridge
    enable_ipv6: true
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
        - subnet: fdcc:ad94:bacf:61a3::/64
EOF
cat > "${PROXY_DIR}/Caddyfile" <<EOF
{
	email ${PROXY_EMAIL}
	servers {
		protocols h1 h2
	}
}

${PROXY_DOMAIN} {
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
		-Server
	}
	reverse_proxy wg-easy:51821
}
EOF
( cd "$PROXY_DIR" && docker compose pull -q && docker compose up -d --remove-orphans )
ok "Containers up"

# ─── 9. Hostname + automatic security updates ────────────────────────────────
if [[ "$PROXY_SET_HOSTNAME" == 1 ]]; then
  hostnamectl set-hostname "$PROXY_DOMAIN"
  grep -q "$PROXY_DOMAIN" /etc/hosts || echo "127.0.1.1 ${PROXY_DOMAIN}" >> /etc/hosts
fi
if [[ "$FAMILY" == el ]]; then
  sed -i 's/^upgrade_type = .*/upgrade_type = security/; s/^apply_updates = .*/apply_updates = yes/; s/^download_updates = .*/download_updates = yes/' /etc/dnf/automatic.conf
  systemctl enable --now dnf-automatic.timer >/dev/null 2>&1
else
  dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
fi
ok "Hostname and unattended security updates configured"

# ─── 10. Verify ──────────────────────────────────────────────────────────────
sleep 5
log "Verification"
docker ps --format '  {{.Names}}: {{.Status}}'
if docker exec wg-easy wg show wg0 >/dev/null 2>&1; then ok "wg0 is up inside wg-easy"; else warn "wg0 not up yet — check: docker logs wg-easy"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' "http://10.42.42.42:51821/" || true)
[[ "$code" == 302 || "$code" == 200 ]] && ok "wg-easy UI answers internally (HTTP ${code})" || warn "wg-easy UI returned HTTP ${code:-none}"
echo
cat <<EOF
────────────────────────────────────────────────────────────────────────
  proxy is installed.

  1. DNS:  create an A record   ${PROXY_DOMAIN} → $(curl -s -4 --max-time 5 https://ifconfig.me || echo '<this server IP>')
           (Caddy is already polling Let's Encrypt and will get a certificate on its own.)
  2. rDNS: set the PTR of this IP to ${PROXY_DOMAIN} in your provider's panel.
  3. Open  https://${PROXY_DOMAIN}/  → the one-time wizard creates the single admin account.
           Host = ${PROXY_DOMAIN}, Port = ${PROXY_WG_PORT}. Then add a device, scan the QR code.
  4. Later: run scripts/status.sh for a health check; read docs/HARDENING.md for phase 2.
────────────────────────────────────────────────────────────────────────
EOF
