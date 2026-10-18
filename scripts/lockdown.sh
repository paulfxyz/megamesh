#!/usr/bin/env bash
# megamesh — VPN-only admin UI switch.
#
#   megamesh-lockdown enable [https://where-outsiders-go]   # UI reachable only through the tunnel; everyone else is redirected
#   megamesh-lockdown disable                               # UI reachable from the public internet again (login page)
#   megamesh-lockdown status
#   megamesh-lockdown render vpn-only https://example.com      # print + validate the Caddyfile that `enable` would apply; changes nothing
#
# How it works: Caddy keeps listening on public 443 (so Let's Encrypt renewals keep working), but the site
# block gets a `remote_ip` matcher. A VPN client's request travels wg0 → wg-easy (MASQUERADE to the container
# address 10.42.42.42) → Docker hairpin DNAT → Caddy, so Caddy sees client_ip 10.42.42.42 exactly. Public
# traffic is DNATed with its real source preserved. Verified on the reference server with Docker's
# userland-proxy OFF (install.sh sets it); with the userland proxy ON the hairpin would show the bridge
# gateway 10.42.42.1 instead, and public traffic could too in some setups — so this script refuses to enable
# unless userland-proxy is off. The Caddyfile is a single-file bind mount and is rewritten IN PLACE
# (cp, not mv/sed -i): a new inode would never be seen by the running container.
#
# Caveat: a client with split tunneling (AllowedIPs not 0.0.0.0/0) reaches the domain over the plain internet
# and is treated as an outsider. That is the intended semantics of "only if you are on the VPN".
set -euo pipefail
[[ -z "${MEGAMESH_DIR:-}" && -f /etc/megamesh.conf ]] && . /etc/megamesh.conf   # installer-recorded settings; env vars still win
MEGAMESH_DIR="${MEGAMESH_DIR:-/opt/megamesh}"
MEGAMESH_WG_EASY_IP="${MEGAMESH_WG_EASY_IP:-10.42.42.42}"   # wg-easy's fixed address on the compose network
cd "$MEGAMESH_DIR" 2>/dev/null || { echo "✖ ${MEGAMESH_DIR} not found (set MEGAMESH_DIR)"; exit 1; }
[[ -f Caddyfile ]] || { echo "✖ no Caddyfile in ${MEGAMESH_DIR}"; exit 1; }

domain=$(awk 'NR>1 && /^[a-zA-Z0-9.-]+ \{$/ {print $1; exit}' Caddyfile)
email=$(awk '/^\temail / {print $2; exit}' Caddyfile)
current_redirect=$(awk '/^\t\tredir / {print $2; exit}' Caddyfile || true)
[[ -n "$domain" && -n "$email" ]] || { echo "✖ could not parse domain/email from Caddyfile"; exit 1; }

mode() { grep -q '@vpn remote_ip' Caddyfile && echo vpn-only || echo open; }

render_caddyfile() { # $1 = open|vpn-only, $2 = redirect url, $3 = output path
  {
    printf '{\n\temail %s\n\tservers {\n\t\tprotocols h1 h2\n\t}\n}\n\n' "$email"
    printf '%s {\n' "$domain"
    printf '\theader {\n\t\tStrict-Transport-Security "max-age=31536000"\n\t\tX-Content-Type-Options "nosniff"\n\t\tX-Frame-Options "DENY"\n\t\tReferrer-Policy "no-referrer"\n\t\t-Server\n\t}\n'
    if [[ "$1" == vpn-only ]]; then
      printf '\t@vpn remote_ip %s\n' "$MEGAMESH_WG_EASY_IP"
      printf '\thandle @vpn {\n\t\tencode zstd gzip\n\t\treverse_proxy wg-easy:51821\n\t}\n'
      printf '\thandle {\n\t\tredir %s 302\n\t}\n' "$2"
    else
      printf '\tencode zstd gzip\n\treverse_proxy wg-easy:51821\n'
    fi
    printf '}\n'
  } > "$3"
}

validate_caddyfile() { # $1 = path
  docker run --rm -v "$1":/etc/caddy/Caddyfile:ro "$(docker inspect caddy --format '{{.Config.Image}}')" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1
}

write_caddyfile() { # $1 = open|vpn-only, $2 = redirect url (vpn-only)
  local tmp; tmp=$(mktemp)
  render_caddyfile "$1" "${2:-}" "$tmp"
  validate_caddyfile "$tmp" || { echo "✖ generated Caddyfile failed validation:"; cat "$tmp"; rm -f "$tmp"; exit 1; }
  cp "$tmp" Caddyfile && rm -f "$tmp"            # cp = same inode, the container sees it
  docker exec caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || docker compose restart caddy >/dev/null
}

verify_inside() { # $1 = redirect url to NOT see (vpn-only) or "" (open). Returns 1 on failure.
  local hdrs first_loc
  hdrs=$(docker exec wg-easy wget -S -O /dev/null "https://${domain}/" 2>&1 || true)
  first_loc=$(printf '%s\n' "$hdrs" | awk '/^ *Location:/{print $2; exit}')
  if [[ -z "$hdrs" || "$hdrs" != *"HTTP/"* ]]; then echo "⚠ tunnel-path check: no HTTP answer (certificate not issued yet? docker logs caddy)"; return 1; fi
  if [[ -n "$1" && "$first_loc" == "$1"* ]]; then echo "✖ tunnel-path check: the tunnel side is being redirected to ${1} — matcher did not match"; return 1; fi
  echo "✔ through the tunnel path: first response → ${first_loc:-200/UI} (admin UI reachable)"; return 0
}

case "${1:-status}" in
  enable)
    url="${2:-${MEGAMESH_REDIRECT_URL:-}}"
    [[ -n "$url" ]] || { echo "✖ give a redirect URL: megamesh-lockdown enable https://example.com"; exit 1; }
    url_re='^https?://[^[:space:]"'"'"'{};]+$'
    [[ "$url" =~ $url_re ]] || { echo "✖ redirect URL must be a plain http(s) URL (no spaces, quotes, braces or semicolons)"; exit 1; }
    docker inspect wg-easy >/dev/null 2>&1 || { echo "✖ wg-easy container not found"; exit 1; }
    if python3 -c 'import json,sys; sys.exit(0 if json.load(open("/etc/docker/daemon.json")).get("userland-proxy") is False else 1)' 2>/dev/null; then :; else
      echo "✖ refusing: Docker userland-proxy is not disabled, so VPN traffic would not be identifiable as ${MEGAMESH_WG_EASY_IP}. Re-run install.sh (it sets \"userland-proxy\": false) and recreate the stack."; exit 1
    fi
    peers=$({ docker exec wg-easy wg show wg0 peers 2>/dev/null || true; } | wc -l)
    (( peers > 0 )) || { echo "✖ refusing: WireGuard has no peers yet. Create a device first or you lock yourself out of the UI."; exit 1; }
    write_caddyfile vpn-only "$url"
    echo "✔ vpn-only: ${domain} serves the admin UI to ${MEGAMESH_WG_EASY_IP} (the tunnel hairpin address); everyone else → 302 ${url}"
    if ! verify_inside "$url"; then
      echo "↩ rolling back to open mode so you are not locked out"; write_caddyfile open; exit 1
    fi
    echo "  Test from a device OFF the VPN: curl -sI https://${domain}/ | grep -i location   → should show ${url}"
    echo "  Undo: megamesh-lockdown disable" ;;
  disable)
    write_caddyfile open
    echo "✔ open: ${domain} serves the admin UI (login page) to everyone"; verify_inside "" || true ;;
  status)
    m=$(mode); echo "mode: ${m}  domain: ${domain}"
    [[ "$m" == vpn-only ]] && echo "outsiders → ${current_redirect}"; exit 0 ;;
  render)
    kind="${2:-vpn-only}"; url="${3:-${MEGAMESH_REDIRECT_URL:-https://example.com}}"
    tmp=$(mktemp); render_caddyfile "$kind" "$url" "$tmp"; cat "$tmp"
    if validate_caddyfile "$tmp"; then echo "# ✔ validates with $(docker inspect caddy --format '{{.Config.Image}}')"; else echo "# ✖ does NOT validate"; rm -f "$tmp"; exit 1; fi
    rm -f "$tmp" ;;
  *) echo "usage: $0 enable <redirect-url> | disable | status | render [open|vpn-only] [url]"; exit 2 ;;
esac
