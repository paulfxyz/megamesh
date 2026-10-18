#!/usr/bin/env bash
# megamesh — scheduled upgrade run: topgrade (system packages + container images) with a health check
# and automatic image rollback, then a reboot if the kernel asked for one.
#
#   megamesh-upgrade            # what the timer runs (journalctl -u megamesh-upgrade)
#   megamesh-upgrade --dry-run  # show what topgrade would do, touch nothing
#   megamesh-upgrade --no-reboot
#
# Order of operations
#   1. remember the image ID each container runs right now (old images stay on disk until a healthy run prunes)
#   2. topgrade --only system containers   (dnf/apt upgrade, docker pull of every local image)
#   3. docker compose up -d                (recreates only containers whose image changed)
#   4. health: wg-easy healthy + wg0 up, Caddy answers on 443 — within 2 minutes
#      ✗ → retag the previous images back and recreate: the VPN is back on the old images, exit 1
#      ✓ → drop the backup tags, prune dangling images
#   5. if the kernel/libc needs it and MEGAMESH_AUTO_REBOOT=1: reboot (containers restart on their own)
set -uo pipefail
[[ -z "${MEGAMESH_DIR:-}" && -f /etc/megamesh.conf ]] && . /etc/megamesh.conf
MEGAMESH_DIR="${MEGAMESH_DIR:-/opt/megamesh}"
MEGAMESH_DOMAIN="${MEGAMESH_DOMAIN:-$(hostname)}"
MEGAMESH_AUTO_REBOOT="${MEGAMESH_AUTO_REBOOT:-1}"
TOPGRADE_CONFIG="${TOPGRADE_CONFIG:-/etc/megamesh/topgrade.toml}"
DRY=0; REBOOT_OK="$MEGAMESH_AUTO_REBOOT"
for a in "$@"; do case "$a" in --dry-run) DRY=1 ;; --no-reboot) REBOOT_OK=0 ;; *) echo "usage: $0 [--dry-run] [--no-reboot]"; exit 2 ;; esac; done
log() { printf '%s megamesh-upgrade: %s\n' "$(date '+%F %T')" "$*"; }
cd "$MEGAMESH_DIR" || { log "✖ ${MEGAMESH_DIR} not found"; exit 1; }
command -v topgrade >/dev/null || { log "✖ topgrade not installed (re-run install.sh with MEGAMESH_TOPGRADE=1)"; exit 1; }

services=(wg-easy caddy)
declare -A prev_img prev_ref
for svc in "${services[@]}"; do
  prev_img[$svc]=$(docker inspect "$svc" --format '{{.Image}}' 2>/dev/null || true)          # sha256:…
  prev_ref[$svc]=$(docker inspect "$svc" --format '{{.Config.Image}}' 2>/dev/null || true)   # e.g. ghcr.io/wg-easy/wg-easy:15
done

if (( DRY )); then
  log "dry run — topgrade plan:"
  topgrade --config "$TOPGRADE_CONFIG" --allow-root --dry-run --only system containers -y 2>&1 | sed 's/^/    /'
  exit 0
fi

# 2. topgrade
log "▶ topgrade (system + containers)"
if topgrade --config "$TOPGRADE_CONFIG" --allow-root --only system containers -y --no-retry --skip-notify --no-self-update 2>&1 | sed 's/^/    /'; then
  log "topgrade finished"
else
  log "⚠ topgrade reported a failed step (continuing to health check)"
fi

# 3. recreate what changed
docker compose up -d --remove-orphans 2>&1 | sed 's/^/    /'

# 4. health
healthy=0
for _ in $(seq 1 40); do
  st=$(docker inspect wg-easy --format '{{.State.Health.Status}}' 2>/dev/null || echo missing)
  if [[ "$st" == healthy ]] && docker exec wg-easy wg show wg0 >/dev/null 2>&1 \
     && [[ "$(curl -s -o /dev/null -w '%{http_code}' --resolve "${MEGAMESH_DOMAIN}:443:127.0.0.1" "https://${MEGAMESH_DOMAIN}/" 2>/dev/null)" =~ ^(200|302)$ ]]; then
    healthy=1; break
  fi
  sleep 3
done

changed=()
for svc in "${services[@]}"; do
  now=$(docker inspect "$svc" --format '{{.Image}}' 2>/dev/null || true)
  [[ -n "${prev_img[$svc]}" && "$now" != "${prev_img[$svc]}" ]] && changed+=("$svc")
done

if (( healthy )); then
  log "✔ healthy after upgrade (images changed: ${changed[*]:-none})"
  docker image prune -f >/dev/null 2>&1 || true   # only now do the previous images go
else
  log "✖ NOT healthy after upgrade — rolling back images for: ${changed[*]:-(none changed; failure is elsewhere)}"
  for svc in "${changed[@]}"; do
    docker tag "${prev_img[$svc]}" "${prev_ref[$svc]}" && log "  restored ${prev_ref[$svc]} → ${prev_img[$svc]:0:19}"
  done
  (( ${#changed[@]} )) && docker compose up -d --force-recreate 2>&1 | sed 's/^/    /'
  sleep 15
  st=$(docker inspect wg-easy --format '{{.State.Health.Status}}' 2>/dev/null || echo missing)
  log "after rollback: wg-easy=${st}. The tag now points at the previous image again; the next run will re-pull. Investigate: docker logs wg-easy caddy"
  exit 1
fi

# 5. reboot if the kernel asked for it
needs_reboot=0
if command -v dnf >/dev/null; then dnf needs-restarting -r >/dev/null 2>&1 || needs_reboot=1
elif [[ -f /var/run/reboot-required ]]; then needs_reboot=1; fi
if (( needs_reboot )); then
  if (( REBOOT_OK )); then
    log "↻ reboot required (new kernel/libc) — rebooting in 1 minute; containers restart on their own"
    shutdown -r +1 "megamesh-upgrade: rebooting into the updated kernel" >/dev/null 2>&1
  else
    log "⚠ reboot required but MEGAMESH_AUTO_REBOOT=0 / --no-reboot — reboot manually"
  fi
else
  log "no reboot needed"
fi
exit 0
