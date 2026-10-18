# Troubleshooting

Symptoms first, then the cause, then the fix. All seen for real on the reference server unless marked.

### `wg-quick up wg0` fails: *iptables (legacy): can't initialize iptables table `nat`*

The wg-easy image uses legacy iptables; the host kernel has not loaded the legacy table modules (modern hosts only load nftables ones).

```sh
for m in ip_tables iptable_nat iptable_filter ip6_tables ip6table_nat ip6table_filter nf_nat xt_MASQUERADE; do modprobe $m; done
printf '%s\n' wireguard ip_tables iptable_nat iptable_filter ip6_tables ip6table_nat ip6table_filter nf_nat xt_MASQUERADE > /etc/modules-load.d/proxy.conf
docker compose -f /opt/proxy/compose.yml restart wg-easy
```

### Published ports do nothing; `ss -tulpn` shows no `docker-proxy`

`/etc/docker/daemon.json` contains `"iptables": false`. Remove it and `systemctl restart docker`. Containers with `restart: unless-stopped` come back on their own.

### `dnf`/`apt` killed, SSH "timed out during banner exchange"

Out of memory on a small VPS. `dmesg | grep -i oom`. Add swap, then retry: `fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`. Check `swapon --show` afterwards — an existing but inactive `/swapfile` is a classic.

### Thousands of SSH failures although fail2ban is "active"

`fail2ban-client status` → *Number of jail: 0*. The service runs, the jail does not exist. Drop `config/fail2ban/proxy-sshd.local` into `/etc/fail2ban/jail.d/` and restart fail2ban.

### Caddy: *will retry … HTTP 504* or *no such host*

No DNS yet, or Let's Encrypt hiccup. Check `dig +short A <domain> @1.1.1.1`; if it returns your IP, just wait — Caddy backs off and retries for up to 30 days. Do not restart it repeatedly (rate limits).

### Browser: "connection refused" on `http://<domain>`

Intentional: there is no port 80. Type `https://`.

### Browser: certificate error on `https://<domain>`

Certificate not obtained yet (see Caddy above), or you reached the box via the raw IP — the cert is for the domain only.

### `/setup` is gone, I never created an account

Someone else got there first, or you did and forgot. If you did not create it, treat the box as compromised: check `docker exec wg-easy wg show` for peers you do not know, then reset. Reset = remove **only** the wg-easy volume so Caddy keeps its certificate and ACME account: `cd /opt/proxy && docker compose stop wg-easy && docker compose rm -f wg-easy && docker volume rm proxy_etc_wireguard && docker compose up -d` (`down -v` would also delete Caddy's state). With `install.sh` ≥ 1.1.0 this cannot happen on a fresh install: the admin account is created unattended before 443 is reachable.

### I changed the Caddyfile and Caddy says "config is unchanged"

The Caddyfile is a single-file bind mount. `sed -i`, `mv` and most editors write a new inode; the container keeps the old one. Write in place (`cp newfile Caddyfile`, or `cat > Caddyfile`), or `docker compose restart caddy`. `proxy-lockdown` does this correctly.

### `proxy-lockdown enable` refuses: userland-proxy

VPN-only mode needs Docker's `"userland-proxy": false` so tunnel traffic reaches Caddy as `10.42.42.42`. Re-run `install.sh` (it merges the setting into `daemon.json`), or add it by hand, `systemctl restart docker`, `docker compose up -d --force-recreate`.

### Connected to the VPN but no internet

1. `docker exec wg-easy wg show` — is there a recent handshake for your peer?
2. Inside wg-easy, NAT is `iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE` (set in *Admin → Hooks*). If you changed the interface name or CIDR, fix the hook.
3. Host: `sysctl net.ipv4.ip_forward` must be 1; `firewall-cmd --get-policies` must list `docker-forwarding`.
4. MTU stalls (web pages half-load): make sure the ICMP allow-list is in place; try MTU 1280 on the client.

### I locked myself out of SSH

Provider rescue console / KVM. Mount the disk, remove `/etc/ssh/sshd_config.d/00-proxy-hardening.conf` or add your key to `/root/.ssh/authorized_keys`, reboot. This is why `install.sh` will not disable passwords until a key is present.

### Verifying open ports from outside

Do it from a machine on a normal network: `nmap -sS -sU -p 22,80,443,51820,51821 <ip>`. Expected: 22 open, 443 open, 51820 `open|filtered` (WireGuard is silent), 80 and 51821 filtered. Sandboxes behind a transparent egress proxy report every TCP port as open — not a valid test.
