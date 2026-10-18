# Logbook — the reference server

Everything below happened on 2026-10-18 on a Hostkey "VPS 1 vCore / 1 GB / 40 GB SSD" in France, CentOS Stream 9, running as `paulfleury.network`. It is the raw material `megamesh.sh` and `PROMPT.md` were distilled from. Secrets are omitted; the public IP is in DNS anyway.

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

16. **Installer validation.** `megamesh.sh` (this repository) was run over the live deployment with `MEGAMESH_SKIP_UPDATE=1 MEGAMESH_DIR=/opt/wireguard`. First attempt died silently at `firewall-cmd --set-log-denied=off`, which exits 2 when the value is already set — fixed with `|| true`. Second run completed end-to-end; containers reported `Running`, not recreated. The hand-made drop-ins from steps 2–7 were then removed in favour of the installer's files (`00-megamesh-hardening.conf`, `megamesh-sshd.local`, `99-megamesh-hardening.conf`, `megamesh.conf`).
17. **Note.** The reference server keeps the stack in `/opt/wireguard` (its Compose project name, and therefore its volume names, derive from the directory). A fresh install uses `/opt/megamesh`; `/etc/megamesh.conf` tells the helper commands where to look.
18. **Admin account and first device.** The owner completed the wizard himself (wg-easy 15.4.0), created a peer, connected from his laptop and confirmed traffic through the tunnel, then disconnected. From this point the UI answers `302 /login`.
19. **Three-model audit** of the repository at v1.0.0 (Claude Opus 5.5, GPT-6.1 Sol Pro, Gemini 4 Argon via OpenRouter; reports in [docs/audit/](audit/)). Grades C / D / B+. Converging findings: an SSH lock-out when no key is present (`PermitRootLogin prohibit-password` written unconditionally), SSH port moved before the firewall opened it, phase-2 recipes that ignored the container network namespace, `SYS_MODULE` not needed, `curl | sh` on Debian, `daemon.json` clobbered, stale docs. All fixed in 1.1.0 — see [AUDIT.md](AUDIT.md).
20. **Live tests for 1.1.0.** Dropped `SYS_MODULE` and the `/lib/modules` mount: `wg0` up, same keys, peer intact. Set Docker `"userland-proxy": false` and recreated the stack: tunnel-origin requests now reach Caddy as `10.42.42.42` (were `10.42.42.1`), public requests keep their real IP. Re-ran the rewritten `megamesh.sh` over the live server: idempotent, admin check reports "login page", helpers installed. `megamesh-lockdown render vpn-only https://paulfleury.com` validates; **not enabled** — the owner will say when.

21. **PTR set** via the Hostkey panel (Network → IP settings and DNS PTR management → `paulfleury.network`, "IP PTR data updated"); `ns1.hostkey.com` answered immediately, public resolvers within the hour.
22. **2FA enabled** by the owner on the wg-easy account. **`megamesh-lockdown enable https://paulfleury.com`** run on request: from the public internet `/`, `/login` and `/api/*` all answer `302 https://paulfleury.com/`; through the tunnel path the UI answers `200`.
23. **Renamed** from `proxy` to **megamesh** (a nod to the owner's consultancy, [megastack.sh](https://megastack.sh)): repository, env-var prefix (`MEGAMESH_*`), helper commands (`megamesh-status`, `megamesh-lockdown`), config file names on the server, `/etc/megamesh.conf`. The stack directory on the reference server stays `/opt/wireguard`.
24. **Second audit round** on the renamed tree (same three models). New findings: re-running `megamesh.sh` reopened a locked-down UI (observed live, fixed: mode is detected and kept, the open Caddyfile is never written in between); unattended first start could scrub `INIT_*` before setup ran (fixed: wg-easy starts alone, `/login` is proven, then Caddy); CentOS Stream has no errata metadata so `upgrade_type=security` applied nothing (fixed: all updates on Stream); `set -e` pipeline traps in `lockdown.sh`; password/URL sanitising; firewall reports non-owned exposure and retires the previous WireGuard port; allow-list caveats. Reports in [audit/](audit/) (`round2-*`).

25. **topgrade.** The owner asked for the box to keep itself updated, containers included. Installed topgrade 17.13.1 (pinned, checksum-verified) with `megamesh-upgrade` as the wrapper and a weekly timer. Three live runs through transient systemd units: run 1 — topgrade refused to run as root (`allow_root = true` added); run 2 — `Containers: FAILED` because topgrade tried to pull the local `*:megamesh-prev` rollback tags and aborted the step before wg-easy was pulled (backups became image IDs, tags dropped); run 3 — `System update: OK`, `Containers: OK`, both images "up to date", healthy, no reboot needed. Timer armed for Monday 04:42 CEST (04:30 + jitter).

## End state

```
public zone: target DROP · ports: 22/tcp 51820/udp 443/tcp · services: (none)
icmp allow:  echo-request destination-unreachable time-exceeded packet-too-big
containers:  wg-easy (healthy, NET_ADMIN only)   caddy (up)
docker:      userland-proxy off · live-restore · log rotation · no-new-privileges
wg0:         listening :51820, 1 peer (owner's laptop)
admin UI:    https://paulfleury.network/ → 302 https://paulfleury.com/ for outsiders, /login through the tunnel · Let's Encrypt until 2027-01-16
sshd:        passwordauthentication no · permitrootlogin without-password · maxauthtries 3
fail2ban:    sshd jail active
updates:     dnf-automatic daily (all updates: CentOS Stream has no errata metadata)
             megamesh-upgrade weekly (topgrade 17.13.1: system + containers, health check, rollback, reboot if needed)
vpn-only:    ENABLED — outsiders → 302 https://paulfleury.com, tunnel path → UI
```

## Things that would have been faster to know

- Check `swapon --show`, not `ls /swapfile`.
- Re-run your own installer on your own locked-down box before telling anyone re-runs are safe.
- Check `fail2ban-client status`, not `systemctl is-active fail2ban`.
- Read `/etc/docker/daemon.json` before trusting a published port.
- Load the legacy iptables modules before the first `docker compose up`.
- Do not probe your own open ports from a sandbox behind an egress proxy — every port shows "open". Verify from the host's ruleset or a real external vantage point.
- Let's Encrypt returns the odd 504; Caddy's retry handles it. Do not restart Caddy in a loop.

## Still open

Nothing. The reference server is complete.

## 26. megamesh.sh becomes the Construct (2026-10-18, evening)

The first site borrowed megastack.sh's black-and-red. It was replaced the same day with its own direction: a white loading room, graphite engravings generated in the calliope.agency house style, Matrix references with the pills recoloured (blue vs glass — no red anywhere, no green anywhere). Light/dark switch, a 50-language picker (English only behind it for now), and the deployer renamed the Operator.

## 27. The Operator changes root's password (2026-10-18, evening)

Door 03 users arrive with a root password that has been in an email. The Operator now takes an optional new one, applies it with `chpasswd` as its own `passwd` action before anything else, and uses it for every call after — so the next SSH login is the proof. It still will not disable password login without a key: the rule from the first audit (never lock a door you cannot prove you can open) applies to the web form too.

