#!/usr/bin/env bash
# megamesh — the exact firewalld policy behind the "three doors", as standalone commands.
# Idempotent. Adjust SSH_PORT / WG_PORT if you changed them in megamesh.sh.
set -euo pipefail
SSH_PORT="${SSH_PORT:-22}"; WG_PORT="${WG_PORT:-51820}"
fw() { # "already there" is fine, anything else is fatal
  local out; if out=$(firewall-cmd --permanent --zone=public "$@" 2>&1); then return 0; fi
  [[ "$out" =~ ALREADY_ENABLED|NOT_ENABLED|ALREADY_SET ]] && return 0
  echo "firewall-cmd $* failed: ${out}" >&2; exit 1
}
wan_if=$(ip -4 route show default | awk '{print $5; exit}')
[[ "$(firewall-cmd --get-zone-of-interface="$wan_if" 2>/dev/null)" == public ]] || firewall-cmd -q --permanent --zone=public --change-interface="$wan_if"

fw --set-target=DROP                           # unmatched traffic is dropped silently (no RST / ICMP unreachable)
for s in cockpit dhcpv6-client ssh; do fw --remove-service="$s"; done
fw --add-port="${SSH_PORT}/tcp"                # SSH — key-only, fail2ban
fw --add-port="${WG_PORT}/udp"                 # WireGuard — silent to non-handshakes
fw --add-port=443/tcp                          # Caddy → wg-easy admin UI (TLS-ALPN-01 for certificates)
fw --add-icmp-block-inversion                  # the icmp-blocks below become the ALLOW list
# ping in, plus what path-MTU discovery needs. destination-unreachable includes fragmentation-needed (type 3 code 4);
# packet-too-big is the ICMPv6 equivalent. echo-reply is not needed inbound: conntrack matches replies to our pings.
for t in echo-request destination-unreachable time-exceeded packet-too-big; do fw --add-icmp-block="$t"; done
firewall-cmd -q --permanent --set-log-denied=off 2>/dev/null || true   # a public IP is scanned nonstop; keep the journal usable
firewall-cmd -q --reload
firewall-cmd --list-all --zone=public
