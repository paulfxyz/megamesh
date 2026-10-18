# proxy

<div align="center">

![Version](https://img.shields.io/badge/version-1.1.0-e3120b?style=for-the-badge)
![WireGuard](https://img.shields.io/badge/WireGuard-wg--easy_v15-88171A?style=for-the-badge&logo=wireguard&logoColor=white)
![Caddy](https://img.shields.io/badge/TLS-Caddy_2_%2B_Let%27s_Encrypt-1f88c0?style=for-the-badge)
![Firewall](https://img.shields.io/badge/default_policy-DROP-critical?style=for-the-badge)
![Tested on](https://img.shields.io/badge/tested_on-CentOS_Stream_9_·_1_vCPU_·_1_GB-23382f?style=for-the-badge)
![Audited](https://img.shields.io/badge/audited_by-3_frontier_models-5b4b8a?style=for-the-badge)
![License](https://img.shields.io/badge/license-MIT-286348?style=for-the-badge)

<img src="docs/hero.svg" width="100%" alt="proxy: the public internet sees three doors — SSH, WireGuard and HTTPS — everything else is dropped. Behind them, a WireGuard tunnel, wg-easy and Caddy on a 1 GB VPS.">

<p><strong>A personal WireGuard VPN with a web admin UI, hardened by default, on the cheapest VPS you can find.</strong></p>
<p>Two ways in: a script if you are a sysop, a prompt if you have an AI agent. Both start from the same two facts — an IP and a root password.</p>
<p><a href="#quick-start-sysop">Script</a> · <a href="#quick-start-ai-agent">Prompt</a> · <a href="#what-you-get">What you get</a> · <a href="#vpn-only-mode">VPN-only mode</a> · <a href="docs/HARDENING.md">Hardening</a> · <a href="docs/AUDIT.md">Audit</a> · <a href="docs/DNS.md">DNS</a> · <a href="docs/TROUBLESHOOTING.md">Troubleshooting</a> · <a href="docs/LOGBOOK.md">Logbook</a></p>

</div>

## The idea

Commercial VPNs ask you to trust a company you cannot audit, with servers you share with strangers. Rolling your own is cheap and well documented, yet most guides stop at "WireGuard is up" and leave the box with password SSH, a wide-open firewall and no updates — the reference server for this project had logged **76,073 failed SSH logins** in 25 days, with fail2ban "running" and zero jails.

`proxy` is the opinionated remainder: one VPS, one domain, one admin. WireGuard for the tunnel, [wg-easy](https://github.com/wg-easy/wg-easy) for the profiles and QR codes, [Caddy](https://caddyserver.com) for the certificate, firewalld for a deny-by-default policy with exactly three doors, and the small set of host hardening you would want anyway. It is written down twice — as a script that does it, and as a prompt that teaches an agent to do it — because the second form survives distributions and providers the first one has never seen. Before going public it was audited by three frontier models and every real finding was fixed and re-verified on the live server ([docs/AUDIT.md](docs/AUDIT.md)).

## What you get

```
public internet ──▶ tcp/22    SSH, key-only, fail2ban
                ──▶ udp/51820 WireGuard (silent to anything but a valid handshake)
                ──▶ tcp/443   Caddy ──▶ wg-easy admin UI (internal bridge only;
                              optionally VPN-only, outsiders get a redirect)
                ──▶ icmp      ping + path-MTU types
                ──▶ *         DROP
```

| Layer | What | Why |
|---|---|---|
| Tunnel | WireGuard via `ghcr.io/wg-easy/wg-easy:15`, UDP 51820 | In-kernel, ~4k lines, modern crypto; wg-easy adds peers, QR codes, stats |
| Admin UI | `https://<domain>/` only, through Caddy on the Docker bridge | The UI port is never published; the single admin account is created unattended before 443 is reachable, so there is no public first-run wizard to race for |
| TLS | Caddy 2, Let's Encrypt via TLS-ALPN-01, HSTS, h1/h2, no port 80 | Zero-config certificates and renewals without opening HTTP |
| Firewall | firewalld public zone, target `DROP`, ICMP allow-list, opened before SSH moves | Three doors, everything else is a black hole; `firewall-cmd --list-all` is the audit |
| SSH | Key-only, `prohibit-password`, no forwarding, `MaxAuthTries 3` | Passwords and root-password login stay on until a key is present; `yes` without a key refuses to run |
| Brute force | fail2ban `sshd`, aggressive, 3 tries → 24 h, escalating to 30 d | Turns 76k attempts into a handful of banned IPs |
| Host | sysctl hardening, swap guard, `dnf-automatic`/`unattended-upgrades`, Docker log rotation, `mem_limit`s | A 1 GB VPS that stays up and patched |
| Containers | wg-easy with `NET_ADMIN` only (no `SYS_MODULE`, no `/lib/modules`), Docker userland proxy off | Smaller blast radius; the host loads the kernel modules |

Footprint on the reference server after install: ~400 MB RAM used including both containers, ~4 GB disk.

## Quick start (sysop)

A fresh VPS, root, a domain whose A record you can set. CentOS Stream 9 is verified end to end; Rocky / Alma 9 take the same code path but have not been run; Debian 12 / Ubuntu 22.04+ have a best-effort branch that is not yet verified.

```sh
git clone https://github.com/paulfxyz/proxy && cd proxy
PROXY_DOMAIN=vpn.example.com PROXY_EMAIL=you@example.com bash install.sh
```

Then:

1. Create the DNS A record `vpn.example.com → <server IP>` ([docs/DNS.md](docs/DNS.md)). Caddy is already retrying and will pick up the certificate within minutes.
2. `cat /root/proxy-admin-credentials` — the admin account was created during the install, before the UI was reachable. Move the password into your password manager, `shred -u` the file, log in at `https://vpn.example.com/`, and enable two-factor authentication under your account.
3. Add a device, scan the QR code, connect. `proxy-status` shows handshakes, firewall, bans, certificate and mode on one screen.

All settings are environment variables — see the top of [`install.sh`](install.sh): SSH port, WireGuard port, a public key to install, whether to lock passwords (`auto` = only if a key exists), admin username/password or let it generate one, skip the slow system update, install directory, VPN-only mode and its redirect.

Re-running is safe; the script has been run four times on the reference server, the last two over the live deployment with a connected peer, keeping keys, peers and certificate intact.

## Quick start (AI agent)

Open [`PROMPT.md`](PROMPT.md), fill in four values (IP, root password, OS, domain), paste it into any agent that can run shell commands over SSH. The prompt carries the goal, the rules (change the root password first, never disable passwords before a key login works, never print secrets, verify by reading state) and the traps we hit so the agent does not have to find them again:

- the 1 GB VPS whose first `dnf update` gets OOM-killed because the image's `/swapfile` was never activated
- the provider image shipping `/etc/docker/daemon.json` with `"iptables": false`, so Docker silently publishes nothing
- the wg-easy container's legacy `iptables` needing nine kernel modules on the host or `wg0` never comes up
- fail2ban installed and active with zero jails
- Docker's `docker-forwarding` firewalld policy letting *any* published port through, which is why only two are published
- the unauthenticated first-run wizard that whoever opens the URL first gets to complete

The reference deployment was done exactly this way, by [Perplexity Computer](https://www.perplexity.ai/computer) over SSH, with the owner supplying only the server details and a logged-in browser tab for the DNS change. The full account is in [docs/LOGBOOK.md](docs/LOGBOOK.md).

## VPN-only mode

Once a device is connected, the admin UI can be made reachable **only through the tunnel**; anyone else opening `https://vpn.example.com/` is redirected to a URL of your choice.

```sh
proxy-lockdown render vpn-only https://example.com   # show + validate what would be applied, change nothing
proxy-lockdown enable https://example.com            # refuses without a peer or without Docker userland-proxy off
proxy-lockdown status
proxy-lockdown disable
```

Public 443 stays open so Let's Encrypt keeps renewing, but the public sees a `302` and nothing else. The mechanism is a Caddy `remote_ip` matcher on the wg-easy container address — which only works because the installer turns Docker's userland proxy off; the measurements that led there are in [docs/HARDENING.md](docs/HARDENING.md#phase-2--vpn-only-admin-ui-proxy-lockdown). Devices with split tunneling count as outsiders, by design.

Restricting SSH to the VPN as well is deliberately not offered yet: the obvious firewalld recipe does not match the traffic the host actually sees, and a wrong rule locks you out. The docs explain why and what a correct version needs. If you want to go further than firewalld, [xnftables](https://github.com/paulfxyz/xnftables) is the hand-written, deny-all nftables policy this project is the gentle cousin of.

## Repository layout

```
install.sh                    ← the installer: idempotent, non-interactive, env-var driven
PROMPT.md                     ← the agent prompt, with the known traps and the credential rules
scripts/status.sh             ← one-screen health check (installed as proxy-status)
scripts/lockdown.sh           ← VPN-only mode switch (installed as proxy-lockdown)
config/                       ← the exact files running on the reference server
  compose.yml                 ← wg-easy (NET_ADMIN only) + caddy, two published ports, mem limits
  Caddyfile                   ← TLS-ALPN, HSTS, h1/h2, Server header stripped
  wg-easy.env                 ← container env (INIT_* lines are removed after first start)
  proxy.conf                  ← /etc/proxy.conf, settings the helpers read
  firewalld/public.sh         ← the three-door policy as firewall-cmd commands
  sshd/00-proxy-hardening.conf
  fail2ban/proxy-sshd.local
  sysctl/99-proxy-hardening.conf
  modules-load/proxy.conf
  docker/daemon.json
docs/
  HARDENING.md                ← what is in place and why; VPN-only mode and how it was measured
  AUDIT.md                    ← the three-model audit: findings, fixes, what was declined
  audit/                      ← the three raw reports
  DNS.md                      ← A record, PTR (incl. Hostkey), and why not to self-host ns1/ns2
  TROUBLESHOOTING.md          ← symptom → cause → fix
  LOGBOOK.md                  ← the reference deployment, hour by hour
```

## What this is not

- **Not a privacy service.** Your VPS provider sees your traffic exit their network; this hides you from the café Wi-Fi and your ISP, not from a subpoena.
- **Not multi-tenant.** One admin, your devices. wg-easy supports many peers, but the hardening assumes a single trusted operator.
- **Not tested everywhere.** One distribution, one provider, one VPS size are verified. The Debian/Ubuntu branch, non-default ports and the fresh-install unattended path are reasoned and partially exercised, not run end to end. Issues and PRs with a logbook of what you hit are the most useful contribution.
- **Not a replacement for reading.** `install.sh` is 400 lines of plain bash with comments. Read it before you run it as root on a machine you care about.

## Status and roadmap

v1.1.0 is the state of the reference server on 2026-10-18 after the audit ([CHANGELOG.md](CHANGELOG.md)). Planned: a fresh-VPS run of the unattended path, verifying the Debian/Ubuntu branch on a second provider, SSH-via-VPN with a confirm-or-rollback window, and a short domain for the project. Not planned: supporting OpenVPN, multi-user auth, or turning this into a product.

## The story

I wanted a VPN that is mine, on a cheap VPS, with a QR code for my phone and nothing else listening. I also wanted to know whether I could hand an AI agent an IP and a root password and get a hardened box back without touching a terminal. The answer to both was yes, after the agent and I tripped over five things that were not in any guide. Then I asked three other models to tear the result apart before publishing it, and they found a sixth — a lock-out bug in the very guard that was supposed to prevent lock-outs. This repository is those six things, plus the script, so the next person — or the next agent — starts at the end.

**Paul Fleury** — French internet entrepreneur in Lisbon. Designed and operated with [Perplexity Computer](https://www.perplexity.ai/computer). Companion projects: [xnftables](https://github.com/paulfxyz/xnftables), [cup-of-news](https://github.com/paulfxyz/cup-of-news), [pplx-cost-transparency](https://github.com/paulfxyz/pplx-cost-transparency).

## License

[MIT](LICENSE). wg-easy is AGPL-3.0 and Caddy is Apache-2.0; both are used as unmodified container images. "WireGuard" is a registered trademark of Jason A. Donenfeld; this project is not affiliated with WireGuard, wg-easy or Caddy.
