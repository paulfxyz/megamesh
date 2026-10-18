# Troubleshooting

Symptoms first, then the cause, then the fix. All seen for real on the reference server unless marked.

### `wg-quick up wg0` fails: *iptables (legacy): can't initialize iptables table `nat`*

The wg-easy image uses legacy iptables; the host kernel has not loaded the legacy table modules (modern hosts only load nftables ones).

```sh
for m in ip_tables iptable_nat iptable_filter ip6_tables ip6table_nat ip6table_filter nf_nat xt_MASQUERADE; do modprobe $m; done
printf '%s\n' wireguard ip_tables iptable_nat iptable_filter ip6_tables ip6table_nat ip6table_filter nf_nat xt_MASQUERADE > /etc/modules-load.d/megamesh.conf
docker compose -f /opt/megamesh/compose.yml restart wg-easy
```

### Published ports do nothing; `nft list ruleset` has no Docker DNAT rules

`/etc/docker/daemon.json` contains `"iptables": false`. Remove it and `systemctl restart docker`. Containers with `restart: unless-stopped` come back on their own. (Do not look for `docker-proxy` processes: megamesh turns the userland proxy off on purpose, so their absence is normal.)

### `dnf`/`apt` killed, SSH "timed out during banner exchange"

Out of memory on a small VPS. `dmesg | grep -i oom`. Add swap, then retry: `fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`. Check `swapon --show` afterwards — an existing but inactive `/swapfile` is a classic.

### Thousands of SSH failures although fail2ban is "active"

`fail2ban-client status` → *Number of jail: 0*. The service runs, the jail does not exist. Drop `config/fail2ban/megamesh-sshd.local` into `/etc/fail2ban/jail.d/` and restart fail2ban.

### Caddy: *will retry … HTTP 504* or *no such host*

No DNS yet, or Let's Encrypt hiccup. Check `dig +short A <domain> @1.1.1.1`; if it returns your IP, just wait — Caddy backs off and retries for up to 30 days. Do not restart it repeatedly (rate limits).

### Browser: "connection refused" on `http://<domain>`

Intentional: there is no port 80. Type `https://`.

### Browser: certificate error on `https://<domain>`

Certificate not obtained yet (see Caddy above), or you reached the box via the raw IP — the cert is for the domain only.

### `/setup` is gone, I never created an account

Someone else got there first, or you did and forgot. If you did not create it, treat the box as compromised: check `docker exec wg-easy wg show` for peers you do not know, then reset. First check `/root/megamesh-admin-credentials` — with `megamesh.sh` ≥ 1.1.0 the account is created unattended before 443 is reachable, so on a fresh install the wizard never shows. If you must reset: stop Caddy first (`docker compose stop caddy`) so the wizard is not public, remove **only** the wg-easy volume (`docker compose rm -sf wg-easy && docker volume rm <project>_etc_wireguard` — the project is the directory name, `wireguard_…` on the reference server, `megamesh_…` by default), then re-run `megamesh.sh`, which re-creates the account unattended. `down -v` would also delete Caddy's certificate and ACME account.

### I changed the Caddyfile and Caddy says "config is unchanged"

The Caddyfile is a single-file bind mount. `sed -i`, `mv` and most editors write a new inode; the container keeps the old one. Write in place (`cp newfile Caddyfile`, or `cat > Caddyfile`), or `docker compose restart caddy`. `megamesh-lockdown` does this correctly.

### `megamesh-lockdown enable` refuses: userland-proxy

VPN-only mode needs Docker's `"userland-proxy": false` so tunnel traffic reaches Caddy as `10.42.42.42`. Re-run `megamesh.sh` (it merges the setting into `daemon.json`), or add it by hand, `systemctl restart docker`, `docker compose up -d --force-recreate`.

### Connected to the VPN but no internet

1. `docker exec wg-easy wg show` — is there a recent handshake for your peer?
2. Inside wg-easy, NAT is `iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE` (set in *Admin → Hooks*). If you changed the interface name or CIDR, fix the hook.
3. Host: `sysctl net.ipv4.ip_forward` must be 1; `firewall-cmd --get-policies` must list `docker-forwarding`.
4. MTU stalls (web pages half-load): make sure the ICMP allow-list is in place; try MTU 1280 on the client.

### I locked myself out of SSH

Provider rescue console / KVM. Mount the disk, remove `/etc/ssh/sshd_config.d/00-megamesh-hardening.conf` or add your key to `/root/.ssh/authorized_keys`, reboot. This is why `megamesh.sh` will not disable passwords until a key is present.

### Verifying open ports from outside

Do it from a machine on a normal network: `nmap -sS -sU -p 22,80,443,51820,51821 <ip>`. Expected: 22 open, 443 open, 51820 `open|filtered` (WireGuard is silent), 80 and 51821 filtered. Sandboxes behind a transparent egress proxy report every TCP port as open — not a valid test.

### `megamesh-upgrade` says "NOT healthy after upgrade — rolling back"

A pulled image broke something. The wrapper re-tagged the previous image IDs and recreated the containers, so the VPN should be back; `journalctl -u megamesh-upgrade` has the topgrade output and the health status after rollback. `docker logs wg-easy` / `docker logs caddy` tell you why the new image failed. The next weekly run will pull again; to skip a known-bad version, pin the image to a digest: `WG_EASY_IMAGE=ghcr.io/wg-easy/wg-easy@sha256:… bash megamesh.sh`.

### topgrade: "Containers: FAILED" but the images are up to date

topgrade stops its containers step at the first pull error, so one unpullable local image (a locally built one, a tag that only exists on this box) silences the rest. Add it to `ignored_containers` in `/etc/megamesh/topgrade.toml` (wildcards allowed), then `megamesh-upgrade --dry-run` to confirm the plan lists every image you expect.

### The server rebooted on a Monday morning

That is `megamesh-upgrade` after a kernel update, with `MEGAMESH_AUTO_REBOOT=1` (default). `journalctl -u megamesh-upgrade -b -1` shows the "reboot required" line from the previous boot. Set `MEGAMESH_AUTO_REBOOT=0` in `/etc/megamesh.conf` (or re-run `megamesh.sh` with it) to be told instead of rebooted; move the window with `MEGAMESH_UPGRADE_SCHEDULE`.

### Upgrading from the `proxy` days (≤ 1.1.0)

File names changed in 1.2.0. After re-running `megamesh.sh` from the new checkout, remove the old ones so there is one source of truth:

```sh
rm -f /etc/ssh/sshd_config.d/00-proxy-hardening.conf /etc/sysctl.d/99-proxy-hardening.conf \
      /etc/fail2ban/jail.d/proxy-sshd.local /etc/modules-load.d/proxy.conf /etc/proxy.conf \
      /usr/local/bin/proxy-status /usr/local/bin/proxy-lockdown
sshd -t && systemctl restart sshd && systemctl restart fail2ban
```
