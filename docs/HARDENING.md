# Hardening: what is in place, why, and the VPN-only mode

The threat model is simple: one person, one box, a public IP that gets scanned around the clock. The reference server had logged **76,073 failed SSH logins** in the 25 days before this project touched it, with fail2ban running and doing nothing (no jails). That is the baseline you start from on any VPS.

## Phase 1 — applied by `install.sh`

### Network: three doors, everything else DROP

```
public zone (firewalld, nftables backend) — bound to the default-route interface
  target: DROP                       ← no REJECT, scanners see a black hole
  tcp/22     SSH         key-only, fail2ban
  udp/51820  WireGuard   silent to anything that is not a valid handshake
  tcp/443    Caddy → wg-easy UI (login page, or a redirect in VPN-only mode)
  icmp       echo-request, destination-unreachable, time-exceeded, packet-too-big
             (icmp-block-inversion: this list is the allow-list; replies to our own
              pings come back through conntrack, fragmentation-needed is a subtype
              of destination-unreachable)
```

No tcp/80. Caddy gets certificates with TLS-ALPN-01 on 443; you must type `https://`. The ICMP allow-list keeps ping working and, more importantly, keeps path-MTU discovery working — WireGuard adds 60–80 bytes of overhead and a box that drops "fragmentation needed" produces mysterious stalls.

`install.sh` checks that the interface carrying the default route is actually in the `public` zone (and moves it there if not), treats any `firewall-cmd` result other than success/already-there as fatal, and opens the SSH port **before** sshd is restarted, so a custom `PROXY_SSH_PORT` cannot strand you.

`firewall-cmd --list-all --zone=public` is the authoritative view; `nft list chain inet firewalld filter_IN_public_allow` shows the compiled rules. Verify from a real outside vantage point (`nmap -sS -sU -p 22,80,443,51820,51821 <ip>`), never from a sandbox behind an egress proxy.

### Docker and the firewall

Docker integrates with firewalld through a `docker-forwarding` policy: *any* published port is reachable from *any* zone. That is why the compose file publishes only `${PROXY_WG_PORT}/udp` and `443/tcp`. The wg-easy UI (`51821`) is reachable solely on the internal bridge `10.42.42.0/24`, where Caddy proxies to it. Never add `51821:51821` back "for debugging".

`install.sh` **merges** `/etc/docker/daemon.json` (always backing it up) rather than overwriting it. It removes `"iptables": false` if present (the reference image shipped with it: Docker publishes nothing and prints no warning), and sets log rotation, `live-restore`, `no-new-privileges` and `"userland-proxy": false`. The last one matters for VPN-only mode (below) and also removes the `docker-proxy` processes; the ports stay bound by dockerd.

### Containers

wg-easy runs with **`NET_ADMIN` only**. It needs that to create `wg0` and its NAT rules; it does not need `SYS_MODULE` because the host loads and persists every required module (`/etc/modules-load.d/proxy.conf`). The `/lib/modules` mount is gone for the same reason. Verified on the reference server: `wg0` comes up and peers keep working after the change. `mem_limit` on both containers (256 m / 128 m) so a leak cannot take the host down. Caddy strips the `Server` header and sends HSTS (apex-safe, no `includeSubDomains`), `nosniff`, `DENY` framing, `no-referrer`.

Images are pinned to major tags (`wg-easy:15`, `caddy:2-alpine`). For strict reproducibility set `WG_EASY_IMAGE`/`CADDY_IMAGE` to `image@sha256:…` digests; re-running `install.sh` then never pulls something you did not choose.

### The admin account exists before 443 is reachable

wg-easy's first-run wizard is unauthenticated and first-come-first-served. `install.sh` therefore uses wg-easy's unattended setup by default: `INIT_USERNAME`/`INIT_PASSWORD`/`INIT_HOST`/`INIT_PORT` are passed on the first start only, through a root-only `wg-easy.env`; once the container is healthy the `INIT_*` lines are removed and the container recreated, so the password is no longer in any process environment. The generated 32-character password is written to `/root/proxy-admin-credentials` (0600) for you to move into a password manager and shred. `PROXY_UNATTENDED=0` brings the wizard back if you prefer it — then finish it immediately.

After the first login: enable **two-factor authentication** (wg-easy ≥ 15.4, under your account page). That is the single most valuable thing you can do for an admin UI on the public internet.

### SSH

Drop-in `/etc/ssh/sshd_config.d/00-proxy-hardening.conf` (included first; first match wins): no X11/agent/TCP forwarding, `MaxAuthTries 3`, `LoginGraceTime 20`, `AllowUsers root`. Distro drop-ins that re-enable passwords are commented out.

The lock-out guard: passwords are disabled **and** `PermitRootLogin` set to `prohibit-password` only when `/root/.ssh/authorized_keys` contains a key (`PROXY_LOCK_SSH=auto`). Without a key the box stays password-reachable and the script says so loudly; `PROXY_LOCK_SSH=yes` without a key refuses to run. The guard checks presence, not a successful login — the installer prints the effective `sshd -T` values and tells you to test a *new* connection before closing your session. v1.0.0 wrote `prohibit-password` unconditionally and would have locked a key-less box; the three-model audit caught it.

fail2ban `sshd` jail, aggressive mode, systemd backend: 3 failures in 10 minutes → 24 h ban, doubling up to 30 days. The installer verifies the jail actually loaded.

### Kernel

`/etc/sysctl.d/99-proxy-hardening.conf`: reverse-path filtering, no ICMP redirects in or out, no source routing, SYN cookies, `kptr_restrict=2`, `dmesg_restrict=1`, unprivileged BPF off, `swappiness=10`. `ip_forward=1` is required (the host forwards for the container network). `accept_ra=0` was dropped after the audit: it breaks SLAAC on providers that hand out IPv6 that way.

### Updates and memory

`dnf-automatic` (or `unattended-upgrades`) applies security updates daily. 1 GB swap when RAM < 2 GB, with a `blkid` check so a provider's pre-allocated but never-formatted `/swapfile` gets `mkswap`'d instead of aborting the run. The 1 GB Hostkey plan exposes 699 MB to the guest; `dnf update` was OOM-killed before swap existed.

## Phase 2 — VPN-only admin UI (`proxy-lockdown`)

Goal: `https://<domain>/` serves the admin UI **only** to devices connected through the tunnel; everyone else is redirected to a URL of your choice. Public 443 stays open (Let's Encrypt renews through it), but the public sees nothing except a `302`.

### How it was verified

Where does a VPN client's request come from, as Caddy sees it? The client sends to the public IP through the tunnel: `wg0` (inside the wg-easy container) → wg-easy's `MASQUERADE` to its own address `10.42.42.42` → the host → Docker's hairpin DNAT to the Caddy container. On the reference server, with Caddy access logging switched on temporarily:

| Request path | Docker `userland-proxy` | `client_ip` Caddy logged |
|---|---|---|
| from inside wg-easy (= VPN client) | on (default) | `10.42.42.1` (bridge gateway, via `docker-proxy`) |
| from the public internet | on | real public IP |
| from inside wg-easy | **off** | **`10.42.42.42`** (wg-easy itself) |
| from the public internet | off | real public IP |

With the userland proxy on, VPN traffic is indistinguishable from "anything that went through docker-proxy" — the audit models rightly flagged a `10.42.42.0/24` matcher as a footgun. With it off, the hairpin keeps the real source and the matcher can be pinned to one address. That is why `install.sh` sets `"userland-proxy": false` and `proxy-lockdown enable` refuses to run without it.

### The resulting Caddyfile

```caddyfile
vpn.example.com {
	header { … }
	@vpn remote_ip 10.42.42.42 10.8.0.0/24
	handle @vpn {
		encode zstd gzip
		reverse_proxy wg-easy:51821
	}
	handle {
		redir https://example.com 302
	}
}
```

`10.8.0.0/24` is included for setups where wg-easy runs with host networking (then Caddy would see the client address directly); it can never appear from the public side (`rp_filter` and RFC 1918). `proxy-lockdown render vpn-only https://example.com` prints exactly this and validates it with the running Caddy image without applying anything.

### Using it

```sh
proxy-lockdown status
proxy-lockdown enable https://example.com     # refuses if there are no peers yet, or userland-proxy is on
proxy-lockdown disable
```

`enable` validates the generated Caddyfile, writes it **in place** (the Caddyfile is a single-file bind mount — `sed -i` or `mv` would create a new inode the running container never sees, which is how "config is unchanged" bit the author), reloads Caddy, and checks the tunnel-side path answers. Then test from a device *off* the VPN: `curl -sI https://vpn.example.com/ | grep -i location` should show your redirect. Devices with split tunneling (AllowedIPs not `0.0.0.0/0`) reach the domain over the plain internet and are treated as outsiders — that is the intended meaning of "only on the VPN".

The reference server runs in this mode since 2026-10-18: outsiders are sent to `https://paulfleury.com`, the UI is reachable only through the tunnel.

## Not done, and why

- **SSH only from inside the VPN.** v1.0.0 documented a firewalld rich rule for `source address=10.8.0.0/24` on the public zone. It would never match: VPN traffic reaches the host from `10.42.42.42` on the Docker bridge (zone `docker`), not from `10.8.0.0/24` on the public interface, and following the recipe would have locked the operator out. Doing this properly means a rule in the `docker` zone for `10.42.42.42` only, a tested recovery path through the provider console, and a confirm-or-rollback timer. It is on the roadmap; until then SSH stays public, key-only, behind fail2ban.
- **Port knocking / changing the SSH port by default.** Key-only + fail2ban already reduces SSH to noise in the logs. `PROXY_SSH_PORT` exists if you want it.
- **A second firewall layer on top of firewalld.** Two managers of one ruleset is how you get rules nobody understands. If you prefer a hand-written nftables policy, see [xnftables](https://github.com/paulfxyz/xnftables) and replace firewalld entirely.
- **`network_mode: host` for wg-easy.** Avoids the Docker NAT layer, but gives the container's `iptables` calls free rein over the host firewall.
- **IPv6 for clients.** The reference VPS has only link-local v6. The compose file keeps the ULA ranges wg-easy expects; set `DISABLE_IPV6=true` in `wg-easy.env` if your kernel has v6 off.
