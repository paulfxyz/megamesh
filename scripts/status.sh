#!/usr/bin/env bash
# proxy — one-screen health check. Run as root on the server.
set -uo pipefail
[[ -z "${PROXY_DIR:-}" && -f /etc/proxy.conf ]] && . /etc/proxy.conf   # installer-recorded settings; env vars still win
PROXY_DIR="${PROXY_DIR:-/opt/proxy}"
DOMAIN=$(grep -m1 -oE '^[a-zA-Z0-9.-]+\.[a-z]{2,}' "${PROXY_DIR}/Caddyfile" 2>/dev/null || hostname)
b() { printf '\n\033[1m%s\033[0m\n' "$*"; }

b "Host";            echo "  $(hostname) · $(uname -r) · up $(uptime -p | sed 's/up //')"
                     free -m | awk 'NR==2{printf "  RAM %d/%d MB used", $3, $2} NR==3{printf " · swap %d/%d MB\n", $3, $2}'
b "Containers";      docker ps --format '  {{.Names}}: {{.Status}}' 2>/dev/null || echo "  docker not running"
b "WireGuard";       docker exec wg-easy wg show wg0 2>/dev/null | sed 's/^/  /' | grep -vE 'private key' || echo "  wg0 not up"
b "Listening (host)"; ss -tulnH | awk '{print "  "$1" "$5}' | sort -u
b "Firewall (public zone)"
  firewall-cmd --zone=public --list-all 2>/dev/null | grep -E 'target|services|ports|icmp-block' | sed 's/^/  /'
b "fail2ban";        fail2ban-client status sshd 2>/dev/null | grep -E 'Currently banned|Total banned|Total failed' | sed -E 's/^[ |`-]+/  /'
b "TLS certificate"
  if out=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -enddate 2>/dev/null); then
    echo "$out" | sed 's/^/  /'
  else
    echo "  no certificate yet — docker logs caddy | grep -i obtain"
  fi
b "Admin UI";        curl -s -o /dev/null -w "  https://${DOMAIN}/ → HTTP %{http_code} %{redirect_url}\n" --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" 2>/dev/null || echo "  not reachable locally"
b "Pending security updates"
  if command -v dnf >/dev/null; then dnf -q updateinfo list --security --available 2>/dev/null | grep -cE '^[A-Za-z0-9]' | sed 's/^/  /'; else apt list --upgradable 2>/dev/null | grep -c -- '-security' | sed 's/^/  /'; fi
b "VPN-only mode"
  if command -v proxy-lockdown >/dev/null; then PROXY_DIR="$PROXY_DIR" proxy-lockdown status 2>&1 | sed 's/^/  /'; else echo "  proxy-lockdown not installed"; fi
echo
