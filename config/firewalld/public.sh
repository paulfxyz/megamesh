#!/usr/bin/env bash
# proxy — the exact firewalld commands behind the "three doors" policy.
# Idempotent. Adjust SSH_PORT / WG_PORT if you changed them in install.sh.
set -euo pipefail
SSH_PORT="${SSH_PORT:-22}"; WG_PORT="${WG_PORT:-51820}"
fw() { firewall-cmd -q --permanent --zone=public "$@" || true; }

fw --set-target=DROP                           # unmatched traffic is dropped silently (no RST / ICMP unreachable)
for s in cockpit dhcpv6-client ssh; do fw --remove-service="$s"; done
fw --add-port="${SSH_PORT}/tcp"                # SSH — key-only, fail2ban
fw --add-port="${WG_PORT}/udp"                 # WireGuard — silent to non-handshakes
fw --add-port=443/tcp                          # Caddy → wg-easy admin UI (TLS-ALPN-01 for certificates)
fw --add-icmp-block-inversion                  # the icmp-blocks below become the ALLOW list
for t in echo-request echo-reply destination-unreachable time-exceeded fragmentation-needed packet-too-big; do
  fw --add-icmp-block="$t"                     # ping + everything path-MTU discovery needs
done
firewall-cmd -q --permanent --set-log-denied=off 2>/dev/null || true   # a public IP is scanned nonstop; keep the journal usable
firewall-cmd -q --reload
firewall-cmd --list-all --zone=public
