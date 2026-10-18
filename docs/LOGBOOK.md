# Logbook — the reference server

Everything below happened on 2026-10-18 on a Hostkey "VPS 1 vCore / 1 GB / 40 GB SSD" in France, CentOS Stream 9, running as `paulfleury.network`. It is the raw material `install.sh` and `PROMPT.md` were distilled from. Secrets are omitted; the public IP is in DNS anyway.

The whole session was driven by [Perplexity Computer](https://www.perplexity.ai/computer) over SSH from a sandbox, with the owner providing only the IP, the initial root password, the domain, and — for the DNS step — a logged-in Namecheap tab in his own browser.

## Starting state

| Item | Found |
|---|---|
| Kernel | 5.14.0-496.el9 (updates pending) |
| RAM | 699 MB visible to the guest, **no swap active** (a 1 GB `/swapfile` from the 2024 image existed but was never `swapon`'d) |
| SSH | `PermitRootLogin yes`, `PasswordAuthentication yes`, 76,073 failed logins since last success |
| fail2ban | running, **0 jails** |
| firewalld | running; public zone allowed `cockpit dhcpv6-client ssh` |
| Docker | 29.8.1 installed, `/etc/docker/daemon.json` had `"iptables": false` |
| Listening | tcp/22 only |
| Hostname | `vm-pico` |

## Timeline

1. **Access.** Logged in with the provider password, installed a fresh ed25519 key, changed root to a 28-char random password. Re-logged with the key only.
2. **SSH hardening.** Drop-in `00-hardening.conf` (key-only, prohibit-password, no forwarding, MaxAuthTries 3). `sshd -t`, restart, verified a new connection. The `50-redhat.conf` drop-in had `PasswordAuthentication yes` and was patched.
3. **fail2ban.** Added the `sshd` jail (aggressive, systemd backend, 3/10m → 24 h, incremental). Four IPs banned within two seconds.
4. **Hostname, sysctl, swap (attempt 1).** `hostnamectl set-hostname paulfleury.network`; sysctl hardening file. The swap step skipped itself because `/swapfile` already existed — but it was not enabled. Noted later.
5. **`dnf update`.** Took ~25 minutes on 1 vCPU. Kernel → 5.14.0-757. The follow-up `dnf install wireguard-tools dnf-automatic` was **OOM-killed** (dnf RSS 403 MB on a 699 MB box, no swap). SSH banner exchange timed out while the box thrashed.
6. **Swap fixed.** `swapon /swapfile` + fstab. Re-ran the install; fine.
7. **Modules.** `modprobe wireguard`, persisted.
8. **Docker daemon.** Replaced `daemon.json` (removed `iptables: false`; added log rotation, `live-restore`, `no-new-privileges`). Restarted; Docker created its `docker` zone and `docker-forwarding` policy in firewalld.
9. **Firewall.** Public zone → target DROP; removed cockpit/dhcpv6-client; allowed `ssh`, `51820/udp`, `443/tcp`; ICMP allow-list via block inversion. `set-log-denied=off` (a public IP under constant scan fills the journal otherwise).
10. **Stack.** `/opt/wireguard/compose.yml` (wg-easy v15 + caddy:2-alpine on bridge `10.42.42.0/24`, only `51820/udp` and `443/tcp` published) and Caddyfile (TLS-ALPN, HSTS, h1/h2 only). `docker compose up -d`.
11. **Bug: `wg-quick up wg0` failed** — *"iptables v1.8.13 (legacy): can't initialize iptables table `nat`"*. The container's legacy iptables needed `iptable_nat` & co. on the host. Loaded nine modules, persisted them in `/etc/modules-load.d/wireguard.conf`, restarted wg-easy → `wg0` up, listening on 51820.
12. **Internal check.** `curl http://10.42.42.42:51821/` → `302 /setup/1`. Caddy registered an ACME account and started retrying (no DNS yet).
13. **Reboot** into the new kernel. Everything came back: swap, modules, firewalld, fail2ban, Docker, both containers, `wg0`, key-only SSH. (Reboot took ~3 minutes on this VM.)
14. **DNS.** In the owner's Namecheap tab: removed the parking CNAME and the URL redirect, added `A @ → 151.243.225.214`. Resolvable on 1.1.1.1 ~3 minutes later.
15. **Certificate.** Caddy logged one `HTTP 504` fetching a nonce from Let's Encrypt (their side), then `certificate obtained successfully`. `https://paulfleury.network/` → `302 /setup/1`.

16. **Installer validation.** `install.sh` (this repository) was run over the live deployment with `PROXY_SKIP_UPDATE=1 PROXY_DIR=/opt/wireguard`. First attempt died silently at `firewall-cmd --set-log-denied=off`, which exits 2 when the value is already set — fixed with `|| true`. Second run completed end-to-end; containers reported `Running`, not recreated. The hand-made drop-ins from steps 2–7 were then removed in favour of the installer's files (`00-proxy-hardening.conf`, `proxy-sshd.local`, `99-proxy-hardening.conf`, `proxy.conf`).
17. **Note.** The reference server keeps the stack in `/opt/wireguard` (its Compose project name, and therefore its volume names, derive from the directory). A fresh install uses `/opt/proxy`.

## End state

```
public zone: target DROP · services: ssh · ports: 51820/udp 443/tcp
icmp allow: echo-request echo-reply destination-unreachable time-exceeded fragmentation-needed packet-too-big
containers:  wg-easy (healthy)   caddy (up)
wg0:         listening :51820, 0 peers (admin account not yet created)
sshd:        passwordauthentication no · permitrootlogin without-password · maxauthtries 3
fail2ban:    sshd jail active
updates:     dnf-automatic security, daily
```

## Things that would have been faster to know

- Check `swapon --show`, not `ls /swapfile`.
- Check `fail2ban-client status`, not `systemctl is-active fail2ban`.
- Read `/etc/docker/daemon.json` before trusting a published port.
- Load the legacy iptables modules before the first `docker compose up`.
- Do not probe your own open ports from a sandbox behind an egress proxy — every port shows "open". Verify from the host's ruleset or a real external vantage point.
- Let's Encrypt returns the odd 504; Caddy's retry handles it. Do not restart Caddy in a loop.

## Still open

- PTR record (owner, Hostkey panel).
- Admin account creation at `/setup/1` (owner, in browser).
- Phase 2 (VPN-only admin UI / SSH) — see [HARDENING.md](HARDENING.md), once a device is connected.
