#!/usr/bin/env bash
# megamesh — a hardened, self-hosted WireGuard VPN with a web admin UI, from one IP and root.
# https://github.com/paulfxyz/megamesh
#
# Usage (as root, on a fresh VPS, from a checkout of this repository):
#   MEGAMESH_DOMAIN=vpn.example.com MEGAMESH_EMAIL=you@example.com bash install.sh
#
# Every setting is an environment variable. Nothing is interactive. Re-running is safe.
# Verified on CentOS Stream 9 (Hostkey "VPS 1 vCore / 1 GB"). Rocky/Alma 9 take the same code path
# but have not been run. Debian 12 / Ubuntu 22.04+ follow a best-effort branch that has NOT been verified.

set -euo pipefail

# ─── Settings ────────────────────────────────────────────────────────────────
MEGAMESH_DOMAIN="${MEGAMESH_DOMAIN:?Set MEGAMESH_DOMAIN (e.g. vpn.example.com) — the FQDN that points to this server}"
MEGAMESH_EMAIL="${MEGAMESH_EMAIL:?Set MEGAMESH_EMAIL — the ACME contact address for certificate notices}"
MEGAMESH_WG_PORT="${MEGAMESH_WG_PORT:-51820}"        # WireGuard UDP port: public endpoint AND listen port (wg-easy uses one value)
MEGAMESH_SSH_PORT="${MEGAMESH_SSH_PORT:-22}"         # SSH port kept open (public, key-only)
MEGAMESH_SSH_PUBKEY="${MEGAMESH_SSH_PUBKEY:-}"       # optional: public key to add to root's authorized_keys
MEGAMESH_LOCK_SSH="${MEGAMESH_LOCK_SSH:-auto}"       # auto|yes|no — disable password login (auto: only if a key is present; yes: refuse without a key)
MEGAMESH_SKIP_UPDATE="${MEGAMESH_SKIP_UPDATE:-0}"    # 1 = skip the full system upgrade (slow on 1 vCPU); package indexes are still refreshed
MEGAMESH_DIR="${MEGAMESH_DIR:-/opt/megamesh}"           # where compose.yml, Caddyfile and env files live
MEGAMESH_SET_HOSTNAME="${MEGAMESH_SET_HOSTNAME:-1}"  # 1 = set the system hostname to MEGAMESH_DOMAIN
MEGAMESH_SWAP_MB="${MEGAMESH_SWAP_MB:-1024}"         # swap to create when RAM < 2 GB and no swap exists (0 = never)
MEGAMESH_UNATTENDED="${MEGAMESH_UNATTENDED:-1}"      # 1 = create the admin account before 443 is reachable (no public wizard); 0 = use the wizard
MEGAMESH_ADMIN_USER="${MEGAMESH_ADMIN_USER:-admin}"  # admin username for unattended setup
MEGAMESH_ADMIN_PASSWORD="${MEGAMESH_ADMIN_PASSWORD:-}" # admin password for unattended setup; generated (32 chars) when empty
MEGAMESH_VPN_ONLY_SET="${MEGAMESH_VPN_ONLY+x}"       # remembers whether the caller set MEGAMESH_VPN_ONLY explicitly
MEGAMESH_VPN_ONLY="${MEGAMESH_VPN_ONLY:-0}"          # 1 = admin UI only reachable through the tunnel (needs >=1 peer; see scripts/lockdown.sh). Re-runs keep an existing VPN-only mode.
MEGAMESH_REDIRECT_URL="${MEGAMESH_REDIRECT_URL:-}"   # where outsiders are sent when MEGAMESH_VPN_ONLY=1, e.g. https://example.com
WG_EASY_IMAGE="${WG_EASY_IMAGE:-ghcr.io/wg-easy/wg-easy:15}"   # pin a digest (image@sha256:…) for strict reproducibility
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2-alpine}"

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root."
[[ "$MEGAMESH_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]] || die "MEGAMESH_DOMAIN is not a valid FQDN: ${MEGAMESH_DOMAIN}"
[[ "$MEGAMESH_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[a-zA-Z]{2,}$ ]] || die "MEGAMESH_EMAIL is not an email address: ${MEGAMESH_EMAIL}"
for v in MEGAMESH_WG_PORT MEGAMESH_SSH_PORT; do
  [[ "${!v}" =~ ^[0-9]+$ ]] && (( ${!v} >= 1 && ${!v} <= 65535 )) || die "$v must be a port number (1–65535)"
  [[ "${!v}" != 443 && "${!v}" != 51821 ]] || die "$v must not be 443 (Caddy) or 51821 (wg-easy UI)"
done
[[ "$MEGAMESH_WG_PORT" != "$MEGAMESH_SSH_PORT" ]] || die "WireGuard and SSH ports must differ"
[[ -z "$MEGAMESH_ADMIN_PASSWORD" || "$MEGAMESH_ADMIN_PASSWORD" =~ ^[A-Za-z0-9._%+-]{12,}$ ]] || die "MEGAMESH_ADMIN_PASSWORD: 12+ chars from A-Za-z0-9._%+- (env-file safe; no quotes, spaces, \$ or #)"
url_re='^https?://[^[:space:]"'"'"'{};]+$'
[[ -z "$MEGAMESH_REDIRECT_URL" || "$MEGAMESH_REDIRECT_URL" =~ $url_re ]] || die "MEGAMESH_REDIRECT_URL must be a plain http(s) URL"
# previous run's settings (to retire ports we opened earlier, and to keep VPN-only mode)
PREV_SSH_PORT=""; PREV_WG_PORT=""
if [[ -f /etc/megamesh.conf ]]; then
  PREV_SSH_PORT=$(awk -F= '$1=="MEGAMESH_SSH_PORT"{print $2}' /etc/megamesh.conf); PREV_WG_PORT=$(awk -F= '$1=="MEGAMESH_WG_PORT"{print $2}' /etc/megamesh.conf)
fi
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
if (( MEGAMESH_SWAP_MB > 0 )) && (( mem_mb < 2048 )) && [[ -z "$(swapon --noheadings --show 2>/dev/null)" ]]; then
  log "RAM is ${mem_mb} MB with no swap — creating ${MEGAMESH_SWAP_MB} MB swap (package updates OOM on small VPS otherwise)"
  if [[ ! -f /swapfile ]]; then
    fallocate -l "${MEGAMESH_SWAP_MB}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="${MEGAMESH_SWAP_MB}" status=none
  fi
  chmod 600 /swapfile
  blkid -t TYPE=swap /swapfile >/dev/null 2>&1 || mkswap /swapfile >/dev/null   # provider images ship unformatted swap files
  swapon /swapfile
  grep -qF '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap active"
fi

# ─── 1. Packages ─────────────────────────────────────────────────────────────
if [[ "$FAMILY" == el ]]; then
  if [[ "$MEGAMESH_SKIP_UPDATE" != 1 ]]; then log "dnf update (this is the slow part on 1 vCPU)"; dnf -y -q update; fi
  dnf -y -q install epel-release
  dnf -y -q install curl openssl wireguard-tools firewalld fail2ban fail2ban-systemd dnf-automatic policycoreutils-python-utils python3
  if ! command -v docker >/dev/null; then
    log "Installing Docker CE from download.docker.com (signed repository)"
    dnf -y -q install dnf-plugins-core
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf -y -q install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update
  if [[ "$MEGAMESH_SKIP_UPDATE" != 1 ]]; then log "apt upgrade"; apt-get -qq -y upgrade; fi
  apt-get -qq -y install curl openssl wireguard-tools firewalld fail2ban python3 python3-systemd unattended-upgrades ca-certificates gnupg
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
printf '%s\n' "${MODS[@]}" > /etc/modules-load.d/megamesh.conf
ok "Modules loaded and persisted (/etc/modules-load.d/megamesh.conf) — the container does not need SYS_MODULE"

# ─── 3. sysctl ───────────────────────────────────────────────────────────────
cat > /etc/sysctl.d/99-megamesh-hardening.conf <<'EOF'
# megamesh — host hardening. ip_forward is required: the host forwards for the container network.
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
fw --add-port="${MEGAMESH_SSH_PORT}/tcp"
fw --add-port="${MEGAMESH_WG_PORT}/udp"
fw --add-port=443/tcp
if [[ -n "$PREV_WG_PORT" && "$PREV_WG_PORT" != "$MEGAMESH_WG_PORT" ]]; then fw --remove-port="${PREV_WG_PORT}/udp"; warn "Retired previous WireGuard port udp/${PREV_WG_PORT}"; fi
if [[ -n "$PREV_SSH_PORT" && "$PREV_SSH_PORT" != "$MEGAMESH_SSH_PORT" ]]; then
  warn "SSH port changes ${PREV_SSH_PORT} → ${MEGAMESH_SSH_PORT}. BOTH stay open until you verify a login on the new port, then run:"
  warn "  firewall-cmd --permanent --zone=public --remove-port=${PREV_SSH_PORT}/tcp && firewall-cmd --reload"
fi
fw --add-icmp-block-inversion   # the ICMP types below are the ALLOWED ones
for t in echo-request destination-unreachable time-exceeded packet-too-big; do fw --add-icmp-block="$t"; done
firewall-cmd -q --permanent --set-log-denied=off >/dev/null 2>&1 || true   # exit 2 when already set
firewall-cmd -q --reload || die "firewalld reload failed — inspect: firewall-cmd --permanent --zone=public --list-all"
ok "Public zone (${wan_if:-?}): DROP everything except tcp/${MEGAMESH_SSH_PORT}, udp/${MEGAMESH_WG_PORT}, tcp/443 (+ ping and PMTU ICMP)"
extra=$({ firewall-cmd --zone=public --list-ports | tr ' ' '\n' | grep -vxE "${MEGAMESH_SSH_PORT}/tcp|${MEGAMESH_WG_PORT}/udp|443/tcp|${PREV_SSH_PORT:-x}/tcp" || true; } | tr '\n' ' ')
extra_s=$(firewall-cmd --zone=public --list-services); extra_r=$({ firewall-cmd --zone=public --list-rich-rules | grep -v ' reject' || true; } | wc -l)   # fail2ban bans are reject rich rules
[[ -z "${extra// }" && -z "$extra_s" && "$extra_r" == 0 ]] || warn "Public zone also has: ports [${extra}] services [${extra_s}] rich rules [${extra_r}] — not installer-owned, review them"

# ─── 5. SSH: key-only when a key exists; never lock a key-less box ───────────
log "SSH hardening"
mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
if [[ -n "$MEGAMESH_SSH_PUBKEY" ]] && ! grep -qF "$MEGAMESH_SSH_PUBKEY" /root/.ssh/authorized_keys; then
  echo "$MEGAMESH_SSH_PUBKEY" >> /root/.ssh/authorized_keys; ok "Public key added to root"
fi
[[ "$FAMILY" == el ]] && command -v restorecon >/dev/null && restorecon -R /root/.ssh >/dev/null 2>&1 || true
have_key=$(grep -cE '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys || true)
lock=no
case "$MEGAMESH_LOCK_SSH" in
  yes)  (( have_key > 0 )) || die "MEGAMESH_LOCK_SSH=yes but /root/.ssh/authorized_keys has no key — that would lock you out. Set MEGAMESH_SSH_PUBKEY."
        lock=yes ;;
  auto) if (( have_key > 0 )); then lock=yes; else warn "No authorized key for root — keeping password login ON. Add a key and re-run, or set MEGAMESH_SSH_PUBKEY."; fi ;;
  no)   ;;
  *)    die "MEGAMESH_LOCK_SSH must be auto, yes or no" ;;
esac
if [[ $lock == yes ]]; then pw=no; rootlogin=prohibit-password; else pw=yes; rootlogin=yes; fi
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-megamesh-hardening.conf <<EOF
# megamesh — included first, first match wins. Password login: ${pw}.
Port ${MEGAMESH_SSH_PORT}
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
  [[ "$f" == */00-megamesh-hardening.conf ]] && continue
  sed -i -E 's/^(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)[[:space:]]+.*/# &  (overridden by 00-megamesh-hardening.conf)/' "$f"
done
if [[ "$FAMILY" == el && "$MEGAMESH_SSH_PORT" != 22 ]]; then
  semanage port -a -t ssh_port_t -p tcp "$MEGAMESH_SSH_PORT" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$MEGAMESH_SSH_PORT" 2>/dev/null \
    || { [[ "$(getenforce 2>/dev/null)" == Enforcing ]] && die "SELinux is enforcing and port ${MEGAMESH_SSH_PORT} could not be labelled ssh_port_t — sshd would fail to bind"; warn "semanage could not label port ${MEGAMESH_SSH_PORT}"; }
fi
if [[ "$FAMILY" == deb && "$MEGAMESH_SSH_PORT" != 22 ]] && systemctl is-enabled ssh.socket >/dev/null 2>&1; then
  warn "Ubuntu uses ssh.socket, which ignores Port in sshd_config — switching to ssh.service"
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true; systemctl enable ssh.service >/dev/null 2>&1 || true
fi
sshd -t || die "sshd config invalid — not restarting. Fix /etc/ssh/sshd_config.d/00-megamesh-hardening.conf"
systemctl restart sshd 2>/dev/null || systemctl restart ssh
eff=$(sshd -T 2>/dev/null | awk '($1=="passwordauthentication"||$1=="permitrootlogin"||$1=="port") && !seen[$1]++ {printf "%s=%s ", $1, $2}')
ok "sshd restarted — effective: ${eff}(keep this session open and test a NEW login before you log out)"

# ─── 6. fail2ban ─────────────────────────────────────────────────────────────
cat > /etc/fail2ban/jail.d/megamesh-sshd.local <<EOF
[sshd]
enabled = true
mode = aggressive
port = ${MEGAMESH_SSH_PORT}
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
try:
    d = json.load(open(p)) if os.path.exists(p) else {}
except Exception as e:
    raise SystemExit(f"✖ {p} exists but is not valid JSON ({e}) — fix or move it, then re-run")
if not isinstance(d, dict): raise SystemExit(f"✖ {p} root is not an object")
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
[[ $? -eq 0 ]] || exit 1
dockerd --validate --config-file /etc/docker/daemon.json >/dev/null 2>&1 || die "daemon.json does not validate"
systemctl enable docker >/dev/null 2>&1; systemctl restart docker
ok "Docker: log rotation, live-restore, no-new-privileges, userland-proxy off"

# ─── 8. The stack: wg-easy + Caddy ───────────────────────────────────────────
log "Writing ${MEGAMESH_DIR}/compose.yml, Caddyfile, wg-easy.env"
mkdir -p "$MEGAMESH_DIR"; chmod 750 "$MEGAMESH_DIR"
# Re-run on a box already in VPN-only mode: keep it, unless the caller said otherwise.
if [[ -z "${MEGAMESH_VPN_ONLY_SET:-}" && -f "${MEGAMESH_DIR}/Caddyfile" ]] && grep -q '@vpn remote_ip' "${MEGAMESH_DIR}/Caddyfile"; then
  prev_redirect=$(awk '/^\t\tredir / {print $2; exit}' "${MEGAMESH_DIR}/Caddyfile")
  if [[ -n "$prev_redirect" ]]; then
    MEGAMESH_VPN_ONLY=1; MEGAMESH_REDIRECT_URL="${MEGAMESH_REDIRECT_URL:-$prev_redirect}"
    log "Existing VPN-only mode detected (→ ${MEGAMESH_REDIRECT_URL}); it will be re-applied after the stack is up"
  fi
fi
cat > "${MEGAMESH_DIR}/compose.yml" <<EOF
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
      - "${MEGAMESH_WG_PORT}:${MEGAMESH_WG_PORT}/udp"
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
if [[ "$MEGAMESH_VPN_ONLY" == 1 && -f "${MEGAMESH_DIR}/Caddyfile" ]] && grep -q '@vpn remote_ip' "${MEGAMESH_DIR}/Caddyfile"; then
  log "Keeping the existing VPN-only Caddyfile (it is re-rendered by megamesh-lockdown below) — the UI is never exposed in between"
else
cat > "${MEGAMESH_DIR}/Caddyfile" <<EOF
{
	email ${MEGAMESH_EMAIL}
	servers {
		protocols h1 h2
	}
}

${MEGAMESH_DOMAIN} {
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
fi

# Admin account before 443 is reachable: wg-easy's unattended setup (INIT_* are read on the first start only).
proj=$(cd "$MEGAMESH_DIR" && docker compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' 2>/dev/null || basename "$MEGAMESH_DIR")
first_start=0; docker volume inspect "${proj}_etc_wireguard" >/dev/null 2>&1 || first_start=1
cred_file=/root/megamesh-admin-credentials
env_tmp=$(mktemp "${MEGAMESH_DIR}/.wg-easy.env.XXXXXX"); chmod 600 "$env_tmp"
{
  echo "PORT=51821"; echo "HOST=0.0.0.0"; echo "INSECURE=false"
  if [[ "$MEGAMESH_UNATTENDED" == 1 && $first_start == 1 ]]; then
    [[ -n "$MEGAMESH_ADMIN_PASSWORD" ]] || MEGAMESH_ADMIN_PASSWORD=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32)
    echo "INIT_ENABLED=true"; echo "INIT_USERNAME=${MEGAMESH_ADMIN_USER}"; echo "INIT_PASSWORD=${MEGAMESH_ADMIN_PASSWORD}"
    echo "INIT_HOST=${MEGAMESH_DOMAIN}"; echo "INIT_PORT=${MEGAMESH_WG_PORT}"
    ( umask 077; printf 'URL:      https://%s/\nUsername: %s\nPassword: %s\n\nStore this in your password manager, then: shred -u %s\n' \
      "$MEGAMESH_DOMAIN" "$MEGAMESH_ADMIN_USER" "$MEGAMESH_ADMIN_PASSWORD" "$cred_file" > "$cred_file" )
  fi
} > "$env_tmp"; mv -f "$env_tmp" "${MEGAMESH_DIR}/wg-easy.env"

( cd "$MEGAMESH_DIR" && docker compose pull -q )
wait_healthy() { for _ in $(seq 1 40); do [[ "$(docker inspect wg-easy --format '{{.State.Health.Status}}' 2>/dev/null)" == healthy ]] && return 0; sleep 3; done; return 1; }
ui_redirect() { curl -s -o /dev/null -w '%{redirect_url}' "http://10.42.42.42:51821/" 2>/dev/null || true; }
if grep -q '^INIT_ENABLED=true' "${MEGAMESH_DIR}/wg-easy.env"; then
  # First start: bring up ONLY wg-easy, prove the admin account exists, then scrub INIT_* and start Caddy. Fail closed.
  ( cd "$MEGAMESH_DIR" && docker compose up -d --remove-orphans wg-easy )
  if wait_healthy && [[ "$(ui_redirect)" == */login* ]]; then
    sed -i '/^INIT_/d' "${MEGAMESH_DIR}/wg-easy.env"
    ( cd "$MEGAMESH_DIR" && docker compose up -d --remove-orphans )   # recreates wg-easy without INIT_*, starts caddy
    ok "Admin account '${MEGAMESH_ADMIN_USER}' created unattended; credentials in ${cred_file} (root-only, delete after saving)"
  else
    die "wg-easy did not come up with the admin account (redirect: '$(ui_redirect)'). Caddy was NOT started, so nothing is public. Check: docker logs wg-easy — INIT_* and ${cred_file} were kept for a re-run."
  fi
else
  ( cd "$MEGAMESH_DIR" && docker compose up -d --remove-orphans )
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true   # pick up a changed Caddyfile on re-runs
  wait_healthy || warn "wg-easy not healthy yet — check: docker logs wg-easy"
fi
ok "Containers up"

# ─── 9. Hostname + automatic security updates ────────────────────────────────
if [[ "$MEGAMESH_SET_HOSTNAME" == 1 ]]; then
  hostnamectl set-hostname "$MEGAMESH_DOMAIN"
  grep -qwF "$MEGAMESH_DOMAIN" /etc/hosts || echo "127.0.1.1 ${MEGAMESH_DOMAIN}" >> /etc/hosts
fi
if [[ "$FAMILY" == el ]]; then
  # CentOS Stream publishes no errata (updateinfo) metadata, so "security" would apply nothing there — use all updates.
  utype=security; [[ "$ID" == centos ]] && utype=default
  sed -i "s/^upgrade_type = .*/upgrade_type = ${utype}/; s/^apply_updates = .*/apply_updates = yes/; s/^download_updates = .*/download_updates = yes/" /etc/dnf/automatic.conf
  systemctl enable --now dnf-automatic.timer >/dev/null 2>&1
else
  dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true
fi
ok "Hostname and unattended updates configured ($([[ "${utype:-}" == default ]] && echo 'all updates: CentOS Stream has no errata metadata' || echo 'security updates'))"

# ─── 10. Helper commands + optional VPN-only mode ────────────────────────────
cat > /etc/megamesh.conf <<EOF
# written by megamesh install.sh — read by megamesh-status and megamesh-lockdown (nothing secret here)
MEGAMESH_DIR=${MEGAMESH_DIR}
MEGAMESH_DOMAIN=${MEGAMESH_DOMAIN}
MEGAMESH_WG_PORT=${MEGAMESH_WG_PORT}
MEGAMESH_SSH_PORT=${MEGAMESH_SSH_PORT}
EOF
if [[ -f "${SELF_DIR}/scripts/status.sh" ]]; then
  install -m 0755 "${SELF_DIR}/scripts/status.sh"   /usr/local/bin/megamesh-status
  install -m 0755 "${SELF_DIR}/scripts/lockdown.sh" /usr/local/bin/megamesh-lockdown
  ok "Installed megamesh-status and megamesh-lockdown"
else
  warn "scripts/ not found next to install.sh — megamesh-status / megamesh-lockdown not installed"
fi
if [[ "$MEGAMESH_VPN_ONLY" == 1 ]]; then
  if MEGAMESH_DIR="$MEGAMESH_DIR" /usr/local/bin/megamesh-lockdown enable "$MEGAMESH_REDIRECT_URL"; then :; else
    warn "VPN-only mode not enabled (see message above). Run later: megamesh-lockdown enable ${MEGAMESH_REDIRECT_URL:-https://your-site}"
  fi
fi

# ─── 11. Verify ──────────────────────────────────────────────────────────────
log "Verification"
docker ps --format '  {{.Names}}: {{.Status}}'
if docker exec wg-easy wg show wg0 >/dev/null 2>&1; then ok "wg0 is up inside wg-easy"; else warn "wg0 not up yet — check: docker logs wg-easy"; fi
redir=$(ui_redirect)
case "$redir" in
  */login*) ok "wg-easy UI answers internally and the admin account exists (login page)" ;;
  */setup*) warn "wg-easy UI is at the SETUP WIZARD — nobody has created the admin account. Do it now at https://${MEGAMESH_DOMAIN}/ before anyone else does." ;;
  *)        warn "wg-easy UI returned redirect '${redir:-none}'" ;;
esac
echo
cat <<EOF
────────────────────────────────────────────────────────────────────────
  megamesh is installed.

  1. DNS:  create an A record   ${MEGAMESH_DOMAIN} → $(curl -s -4 --max-time 5 https://ifconfig.me || echo '<this server IP>')
           (Caddy is already polling Let's Encrypt and will get a certificate on its own.)
  2. rDNS: set the PTR of this IP to ${MEGAMESH_DOMAIN} in your provider's panel.
  3. Log in at https://${MEGAMESH_DOMAIN}/ $( [[ -f $cred_file ]] && echo "— credentials: cat ${cred_file}" || echo "(wizard: Host = ${MEGAMESH_DOMAIN}, Port = ${MEGAMESH_WG_PORT})" )
     Enable two-factor authentication under your account, add a device, scan the QR code.
  4. Later: megamesh-status for a health check; megamesh-lockdown enable https://your-site to make the UI
           VPN-only (outsiders get redirected). docs/HARDENING.md explains both.
────────────────────────────────────────────────────────────────────────
EOF
