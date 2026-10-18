#!/usr/bin/env bash
# proxy — a hardened, self-hosted WireGuard VPN with a web admin UI, from one IP and root.
# https://github.com/paulfxyz/proxy
#
# Usage (as root, on a fresh VPS, from a checkout of this repository):
#   PROXY_DOMAIN=vpn.example.com PROXY_EMAIL=you@example.com bash install.sh
#
# Every setting is an environment variable. Nothing is interactive. Re-running is safe.
# Verified on CentOS Stream 9 (Hostkey "VPS 1 vCore / 1 GB"). Rocky/Alma 9 take the same code path
# but have not been run. Debian 12 / Ubuntu 22.04+ follow a best-effort branch that has NOT been verified.

set -euo pipefail

# ─── Settings ────────────────────────────────────────────────────────────────
PROXY_DOMAIN="${PROXY_DOMAIN:?Set PROXY_DOMAIN (e.g. vpn.example.com) — the FQDN that points to this server}"
PROXY_EMAIL="${PROXY_EMAIL:?Set PROXY_EMAIL — the ACME (Let’s Encrypt) contact address}"
PROXY_WG_PORT="${PROXY_WG_PORT:-51820}"        # WireGuard UDP port: public endpoint AND listen port (wg-easy uses one value)
PROXY_SSH_PORT="${PROXY_SSH_PORT:-22}"         # SSH port kept open (public, key-only)
PROXY_SSH_PUBKEY="${PROXY_SSH_PUBKEY:-}"       # optional: public key to add to root's authorized_keys
PROXY_LOCK_SSH="${PROXY_LOCK_SSH:-auto}"       # auto|yes|no — disable password login (auto: only if a key is present; yes: refuse without a key)
PROXY_SKIP_UPDATE="${PROXY_SKIP_UPDATE:-0}"    # 1 = skip the full system upgrade (slow on 1 vCPU); package indexes are still refreshed
PROXY_DIR="${PROXY_DIR:-/opt/proxy}"           # where compose.yml, Caddyfile and env files live
PROXY_SET_HOSTNAME="${PROXY_SET_HOSTNAME:-1}"  # 1 = set the system hostname to PROXY_DOMAIN
PROXY_SWAP_MB="${PROXY_SWAP_MB:-1024}"         # swap to create when RAM < 2 GB and no swap exists (0 = never)
PROXY_UNATTENDED="${PROXY_UNATTENDED:-1}"      # 1 = create the admin account before 443 is reachable (no public wizard); 0 = use the wizard
PROXY_ADMIN_USER="${PROXY_ADMIN_USER:-admin}"  # admin username for unattended setup
PROXY_ADMIN_PASSWORD="${PROXY_ADMIN_PASSWORD:-}" # admin password for unattended setup; generated (32 chars) when empty
PROXY_VPN_CIDR="${PROXY_VPN_CIDR:-10.8.0.0/24}" # WireGuard client range (wg-easy default)
PROXY_VPN_ONLY="${PROXY_VPN_ONLY:-0}"          # 1 = admin UI only reachable through the tunnel (needs >=1 peer; see scripts/lockdown.sh)
PROXY_REDIRECT_URL="${PROXY_REDIRECT_URL:-}"   # where outsiders are sent when PROXY_VPN_ONLY=1, e.g. https://example.com
WG_EASY_IMAGE="${WG_EASY_IMAGE:-ghcr.io/wg-easy/wg-easy:15}"   # pin a digest (image@sha256:…) for strict reproducibility
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ "$PROXY_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] || die "PROXY_DOMAIN is not a valid FQDN: ${PROXY_DOMAIN}"
[[ "$PROXY_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[a-zA-Z]{2,}$ ]] || die "PROXY_EMAIL is not an email address: ${PROXY_EMAIL}"
[[ "$PROXY_WG_PORT" =~ ^[0-9]+$ && "$PROXY_SSH_PORT" =~ ^[0-9]+$ ]] || die "Ports must be numeric"
[[ "$PROXY_WG_PORT" != "$PROXY_SSH_PORT" ]] || die "WireGuard and SSH ports must differ"
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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
  fi
  chmod 600 /swapfile
  blkid -t TYPE=swap /swapfile >/dev/null 2>&1 || mkswap /swapfile >/dev/null   # provider images ship unformatted swap files
  swapon /swapfile
  grep -qF '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap active"
fi

# ─── 1. Packages ─────────────────────────────────────────────────────────────
if [[ "$FAMILY" == el ]]; then
  if [[ "$PROXY_SKIP_UPDATE" != 1 ]]; then log "dnf update (this is the slow part on 1 vCPU)"; dnf -y -q update; fi
  dnf -y -q install epel-release
  dnf -y -q install curl wireguard-tools firewalld fail2ban fail2ban-systemd dnf-automatic policycoreutils-python-utils python3
  if ! command -v docker >/dev/null; then
    log "Installing Docker CE from download.docker.com (signed repository)"
    dnf -y -q install dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf -y -q install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update
  if [[ "$PROXY_SKIP_UPDATE" != 1 ]]; then log "apt upgrade"; apt-get -qq -y upgrade; fi
  apt-get -qq -y install curl wireguard-tools firewalld fail2ban python3 python3-systemd unattended-upgrades ca-certificates gnupg
  if ! command -v docker >/dev/null; then
    log "Installing Docker CE from download.docker.com (signed apt repository)"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
    apt-get -qq update
    apt-get -qq -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
fi
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
systemctl enable --now firewalld >/dev/null 2>&1 || die "firewalld could not be started"
systemctl enable fail2ban >/dev/null 2>&1 || true
ok "Packages present"

# ─── 2. Kernel modules (WireGuard + legacy iptables tables used inside the container) ──
log "Kernel modules"
MODS=(wireguard ip_tables iptable_nat iptable_filter ip6_tables ip6table_nat ip6table_filter nf_nat xt_MASQUERADE)
for m in "${MODS[@]}"; do modprobe "$m" 2>/dev/null || warn "modprobe $m failed (may be built-in)"; done
printf '%s\n' "${MODS[@]}" > /etc/modules-load.d/proxy.conf
ok "Modules loaded and persisted (/etc/modules-load.d/proxy.conf) — the container does not need SYS_MODULE"

# ─── 3. sysctl ───────────────────────────────────────────────────────────────
cat > /etc/sysctl.d/99-proxy-hardening.conf <<'EOF'
# proxy — host hardening. ip_forward is required: the host forwards for the container network.
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.tcp_syncookies = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
vm.swappiness = 10
# Not set on purpose: net.ipv6.conf.all.accept_ra=0 breaks SLAAC on providers that hand out IPv6 that way.
EOF
sysctl -q --system >/dev/null
ok "sysctl applied"

# ─── 4. Firewall FIRST: deny by default, three doors (opened before SSH moves) ─
log "firewalld public zone"
fw() { # permanent public-zone change; "already there" is fine, anything else is fatal
  local out; if out=$(firewall-cmd --permanent --zone=public "$@" 2>&1); then return 0; fi
  [[ "$out" =~ ALREADY_ENABLED|NOT_ENABLED|ALREADY_SET ]] && return 0
  die "firewall-cmd $* failed: ${out}"
}
wan_if=$(ip -4 route show default | awk '{print $5; exit}')
if [[ -n "$wan_if" ]]; then
  cur_zone=$(firewall-cmd --get-zone-of-interface="$wan_if" 2>/dev/null || true)
  if [[ "$cur_zone" != public ]]; then
    warn "Interface ${wan_if} was in zone '${cur_zone:-none}' — moving it to public"
    firewall-cmd -q --permanent --zone=public --change-interface="$wan_if" >/dev/null
  fi
fi
fw --set-target=DROP
for s in cockpit dhcpv6-client ssh; do fw --remove-service="$s"; done
fw --add-port="${PROXY_SSH_PORT}/tcp"
fw --add-port="${PROXY_WG_PORT}/udp"
fw --add-port=443/tcp
fw --add-icmp-block-inversion   # the ICMP types below are the ALLOWED ones
for t in echo-request destination-unreachable time-exceeded packet-too-big; do fw --add-icmp-block="$t"; done
firewall-cmd -q --permanent --set-log-denied=off >/dev/null 2>&1 || true   # exit 2 when already set
firewall-cmd -q --reload || die "firewalld reload failed — inspect: firewall-cmd --permanent --zone=public --list-all"
ok "Public zone (${wan_if:-?}): DROP everything except tcp/${PROXY_SSH_PORT}, udp/${PROXY_WG_PORT}, tcp/443 (+ ping and PMTU ICMP)"

# ─── 5. SSH: key-only when a key exists; never lock a key-less box ───────────
log "SSH hardening"
mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
if [[ -n "$PROXY_SSH_PUBKEY" ]] && ! grep -qF "$PROXY_SSH_PUBKEY" /root/.ssh/authorized_keys; then
  echo "$PROXY_SSH_PUBKEY" >> /root/.ssh/authorized_keys; ok "Public key added to root"
fi
[[ "$FAMILY" == el ]] && command -v restorecon >/dev/null && restorecon -R /root/.ssh >/dev/null 2>&1 || true
have_key=$(grep -cE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || true)
lock=no
case "$PROXY_LOCK_SSH" in
  yes)  (( have_key > 0 )) || die "PROXY_LOCK_SSH=yes but /root/.ssh/authorized_keys has no key — that would lock you out. Set PROXY_SSH_PUBKEY."
        lock=yes ;;
  auto) if (( have_key > 0 )); then lock=yes; else warn "No authorized key for root — keeping password login ON. Add a key and re-run, or set PROXY_SSH_PUBKEY."; fi ;;
  no)   ;;
  *)    die "PROXY_LOCK_SSH must be auto, yes or no" ;;
esac
if [[ $lock == yes ]]; then pw=no; rootlogin=prohibit-password; else pw=yes; rootlogin=yes; fi
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-proxy-hardening.conf <<EOF
# proxy — included first, first match wins. Password login: ${pw}.
Port ${PROXY_SSH_PORT}
PermitRootLogin ${rootlogin}
PasswordAuthentication ${pw}
KbdInteractiveAuthentication ${pw}
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
# Distro drop-ins re-enabling passwords must not win. Ours is included first, but be explicit.
for f in /etc/ssh/sshd_config.d/*.conf; do
  [[ "$f" == */00-proxy-hardening.conf ]] && continue
  sed -i -E 's/^(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)[[:space:]]+.*/# &  (overridden by 00-proxy-hardening.conf)/' "$f"
done
if [[ "$FAMILY" == el && "$PROXY_SSH_PORT" != 22 ]]; then
  semanage port -a -t ssh_port_t -p tcp "$PROXY_SSH_PORT" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$PROXY_SSH_PORT" 2>/dev/null || warn "semanage could not label port ${PROXY_SSH_PORT}"
fi
if [[ "$FAMILY" == deb && "$PROXY_SSH_PORT" != 22 ]] && systemctl is-enabled ssh.socket >/dev/null 2>&1; then
  warn "Ubuntu uses ssh.socket, which ignores Port in sshd_config — switching to ssh.service"
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true; systemctl enable ssh.service >/dev/null 2>&1 || true
fi
sshd -t || die "sshd config invalid — not restarting. Fix /etc/ssh/sshd_config.d/00-proxy-hardening.conf"
systemctl restart sshd 2>/dev/null || systemctl restart ssh
eff=$(sshd -T 2>/dev/null | awk '$1=="passwordauthentication"||$1=="permitrootlogin"||$1=="port"{printf "%s=%s ", $1, $2}')
ok "sshd restarted — effective: ${eff}(keep this session open and test a NEW login before you log out)"

# ─── 6. fail2ban ─────────────────────────────────────────────────────────────
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
sleep 2; fail2ban-client status sshd >/dev/null 2>&1 && ok "fail2ban sshd jail active" || die "fail2ban sshd jail did not load — fail2ban-client -d"

# ─── 7. Docker daemon (merge, never clobber) ─────────────────────────────────
mkdir -p /etc/docker
[[ -f /etc/docker/daemon.json ]] && cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
python3 - <<'EOF'
import json, os
p = "/etc/docker/daemon.json"
try: d = json.load(open(p))
except Exception: d = {}
if d.get("iptables") is False:
    print("⚠ daemon.json had \"iptables\": false — Docker would publish no ports. Removing it.")
    d.pop("iptables")
d.update({
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "no-new-privileges": True,
  "live-restore": True,
  "userland-proxy": False,   # hairpin traffic keeps its real source (needed by the VPN-only matcher); no docker-proxy processes
})
json.dump(d, open(p, "w"), indent=2); open(p, "a").write("\n")
EOF
dockerd --validate --config-file /etc/docker/daemon.json >/dev/null 2>&1 || die "daemon.json does not validate"
systemctl enable docker >/dev/null 2>&1; systemctl restart docker
ok "Docker: log rotation, live-restore, no-new-privileges, userland-proxy off"

# ─── 8. The stack: wg-easy + Caddy ───────────────────────────────────────────
log "Writing ${PROXY_DIR}/compose.yml, Caddyfile, wg-easy.env"
mkdir -p "$PROXY_DIR"; chmod 750 "$PROXY_DIR"
cat > "${PROXY_DIR}/compose.yml" <<EOF
volumes:
  etc_wireguard:
  caddy_data:
  caddy_config:

services:
  wg-easy:
    image: ${WG_EASY_IMAGE}
    container_name: wg-easy
    env_file:
      - ./wg-easy.env
    networks:
      wg:
        ipv4_address: 10.42.42.42
        ipv6_address: fdcc:ad94:bacf:61a3::2a
    volumes:
      - etc_wireguard:/etc/wireguard
    ports:
      - "${PROXY_WG_PORT}:${PROXY_WG_PORT}/udp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
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
	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
		-Server
	}
	encode zstd gzip
	reverse_proxy wg-easy:51821
}
EOF

# Admin account before 443 is reachable: wg-easy's unattended setup (INIT_* are read on the first start only).
first_start=0; docker volume inspect "$(basename "$PROXY_DIR")_etc_wireguard" >/dev/null 2>&1 || first_start=1
cred_file=/root/proxy-admin-credentials
{
  echo "PORT=51821"; echo "HOST=0.0.0.0"; echo "INSECURE=false"
  if [[ "$PROXY_UNATTENDED" == 1 && $first_start == 1 ]]; then
    [[ -n "$PROXY_ADMIN_PASSWORD" ]] || PROXY_ADMIN_PASSWORD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32)
    (( ${#PROXY_ADMIN_PASSWORD} >= 12 )) || die "PROXY_ADMIN_PASSWORD must be at least 12 characters"
    echo "INIT_ENABLED=true"; echo "INIT_USERNAME=${PROXY_ADMIN_USER}"; echo "INIT_PASSWORD=${PROXY_ADMIN_PASSWORD}"
    echo "INIT_HOST=${PROXY_DOMAIN}"; echo "INIT_PORT=${PROXY_WG_PORT}"
    umask 077; printf 'URL:      https://%s/\nUsername: %s\nPassword: %s\n\nStore this in your password manager, then: shred -u %s\n' \
      "$PROXY_DOMAIN" "$PROXY_ADMIN_USER" "$PROXY_ADMIN_PASSWORD" "$cred_file" > "$cred_file"
  fi
} > "${PROXY_DIR}/wg-easy.env"; chmod 600 "${PROXY_DIR}/wg-easy.env"

( cd "$PROXY_DIR" && docker compose pull -q && docker compose up -d --remove-orphans )
docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true   # pick up a changed Caddyfile on re-runs
for _ in $(seq 1 30); do
  [[ "$(docker inspect wg-easy --format '{{.State.Health.Status}}' 2>/dev/null)" == healthy ]] && break; sleep 3
done
if grep -q '^INIT_ENABLED=true' "${PROXY_DIR}/wg-easy.env"; then
  # Setup consumed; remove the INIT_* lines and recreate so the password is no longer in the container's environment.
  sed -i '/^INIT_/d' "${PROXY_DIR}/wg-easy.env"
  ( cd "$PROXY_DIR" && docker compose up -d >/dev/null 2>&1 )
  ok "Admin account '${PROXY_ADMIN_USER}' created unattended; credentials in ${cred_file} (root-only, delete after saving)"
fi
ok "Containers up"

# ─── 9. Hostname + automatic security updates ────────────────────────────────
if [[ "$PROXY_SET_HOSTNAME" == 1 ]]; then
  hostnamectl set-hostname "$PROXY_DOMAIN"
  grep -qwF "$PROXY_DOMAIN" /etc/hosts || echo "127.0.1.1 ${PROXY_DOMAIN}" >> /etc/hosts
fi
if [[ "$FAMILY" == el ]]; then
  sed -i 's/^upgrade_type = .*/upgrade_type = security/; s/^apply_updates = .*/apply_updates = yes/; s/^download_updates = .*/download_updates = yes/' /etc/dnf/automatic.conf
  systemctl enable --now dnf-automatic.timer >/dev/null 2>&1
else
  dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
fi
ok "Hostname and unattended security updates configured"

# ─── 10. Helper commands + optional VPN-only mode ────────────────────────────
cat > /etc/proxy.conf <<EOF
# written by proxy install.sh — read by proxy-status and proxy-lockdown (nothing secret here)
PROXY_DIR=${PROXY_DIR}
PROXY_DOMAIN=${PROXY_DOMAIN}
PROXY_VPN_CIDR=${PROXY_VPN_CIDR}
PROXY_WG_PORT=${PROXY_WG_PORT}
EOF
if [[ -f "${SELF_DIR}/scripts/status.sh" ]]; then
  install -m 0755 "${SELF_DIR}/scripts/status.sh"   /usr/local/bin/proxy-status
  install -m 0755 "${SELF_DIR}/scripts/lockdown.sh" /usr/local/bin/proxy-lockdown
  ok "Installed proxy-status and proxy-lockdown"
else
  warn "scripts/ not found next to install.sh — proxy-status / proxy-lockdown not installed"
fi
if [[ "$PROXY_VPN_ONLY" == 1 ]]; then
  if PROXY_DIR="$PROXY_DIR" PROXY_VPN_CIDR="$PROXY_VPN_CIDR" /usr/local/bin/proxy-lockdown enable "$PROXY_REDIRECT_URL"; then :; else
    warn "VPN-only mode not enabled (see message above). Run later: proxy-lockdown enable ${PROXY_REDIRECT_URL:-https://your-site}"
  fi
fi

# ─── 11. Verify ──────────────────────────────────────────────────────────────
log "Verification"
docker ps --format '  {{.Names}}: {{.Status}}'
if docker exec wg-easy wg show wg0 >/dev/null 2>&1; then ok "wg0 is up inside wg-easy"; else warn "wg0 not up yet — check: docker logs wg-easy"; fi
redir=$(curl -s -o /dev/null -w '%{redirect_url}' "http://10.42.42.42:51821/" || true)
case "$redir" in
  */login*) ok "wg-easy UI answers internally and the admin account exists (login page)" ;;
  */setup*) warn "wg-easy UI is at the SETUP WIZARD — nobody has created the admin account. Do it now at https://${PROXY_DOMAIN}/ before anyone else does." ;;
  *)        warn "wg-easy UI returned redirect '${redir:-none}'" ;;
esac
echo
cat <<EOF
────────────────────────────────────────────────────────────────────────
  proxy is installed.

  1. DNS:  create an A record   ${PROXY_DOMAIN} → $(curl -s -4 --max-time 5 https://ifconfig.me || echo '<this server IP>')
           (Caddy is already polling Let's Encrypt and will get a certificate on its own.)
  2. rDNS: set the PTR of this IP to ${PROXY_DOMAIN} in your provider's panel.
  3. Log in at https://${PROXY_DOMAIN}/ $( [[ -f $cred_file ]] && echo "— credentials: cat ${cred_file}" || echo "(wizard: Host = ${PROXY_DOMAIN}, Port = ${PROXY_WG_PORT})" )
     Enable two-factor authentication under your account, add a device, scan the QR code.
  4. Later: proxy-status for a health check; proxy-lockdown enable https://your-site to make the UI
           VPN-only (outsiders get redirected). docs/HARDENING.md explains both.
────────────────────────────────────────────────────────────────────────
EOF
