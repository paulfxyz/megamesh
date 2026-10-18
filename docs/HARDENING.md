# Hardening: what is in place, why, and phase 2

The threat model is simple: one person, one box, a public IP that gets scanned around the clock. The reference server had logged **76,073 failed SSH logins** in the 25 days before this project touched it, with fail2ban running and doing nothing (no jails). That is the baseline you start from on any VPS.

## Phase 1 — applied by `install.sh`

### Network: three doors, everything else DROP

```
public zone (firewalld, nftables backend)
  target: DROP                       ← no REJECT, scanners see a black hole
  tcp/22     SSH         key-only, fail2ban
  udp/51820  WireGuard   silent to anything that is not a valid handshake
  tcp/443    Caddy → wg-easy UI (admin login)
  icmp       echo-request, echo-reply, destination-unreachable,
             time-exceeded, fragmentation-needed, packet-too-big
             (icmp-block-inversion: this list is the allow-list)
```

No tcp/80. Caddy gets certificates with TLS-ALPN-01 on 443; you must type `https://`. The ICMP allow-list keeps ping working and, more importantly, keeps path-MTU discovery working — WireGuard adds 60–80 bytes of overhead and a box that drops "fragmentation needed" produces mysterious stalls.

`firewall-cmd --list-all --zone=public` is the authoritative view; `nft list chain inet firewalld filter_IN_public_allow` shows the compiled rules.

### Docker and the firewall

Docker 29 integrates with firewalld through a `docker-forwarding` policy: *any* published port is reachable from *any* zone. That is why the compose file publishes only `51820/udp` and `443/tcp`. The wg-easy UI (`51821`) is reachable solely on the internal bridge `10.42.42.0/24`, where Caddy proxies to it. Never add `51821:51821` back "for debugging".

The reference image shipped `/etc/docker/daemon.json` with `"iptables": false`. With that, Docker publishes nothing and prints no warning. The installer backs the file up and replaces it (log rotation, `live-restore`, `no-new-privileges`).

### SSH

Drop-in `/etc/ssh/sshd_config.d/00-proxy-hardening.conf`: `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, no X11/agent/TCP forwarding, `MaxAuthTries 3`, `LoginGraceTime 20`, `AllowUsers root`. Distro drop-ins that re-enable passwords (`50-redhat.conf`, `50-cloud-init.conf`) are commented out.

The installer refuses to turn passwords off unless `/root/.ssh/authorized_keys` already contains a key (`PROXY_LOCK_SSH=auto`). Lock yourself out of a VPS once and you will appreciate that line.

fail2ban `sshd` jail, aggressive mode, systemd backend: 3 failures in 10 minutes → 24 h ban, doubling up to 30 days. It banned four hosts within two seconds of starting on the reference server.

### Kernel

`/etc/sysctl.d/99-proxy-hardening.conf`: reverse-path filtering, no ICMP redirects in or out, no source routing, no router advertisements, SYN cookies, `kptr_restrict=2`, `dmesg_restrict=1`, unprivileged BPF off, `swappiness=10`. `ip_forward=1` is required (the host forwards for the container network).

`/etc/modules-load.d/proxy.conf` persists `wireguard` plus the legacy iptables modules the wg-easy container needs (`iptable_nat`, `iptable_filter`, their v6 twins, `nf_nat`, `xt_MASQUERADE`). Without them `wg-quick up wg0` dies with *"can't initialize iptables table nat"* on every boot.

### Updates and memory

`dnf-automatic` (or `unattended-upgrades`) applies security updates daily. Containers are pinned to major tags (`wg-easy:15`, `caddy:2-alpine`); update them deliberately with `docker compose pull && docker compose up -d`.

1 GB swap when RAM < 2 GB. The 1 GB Hostkey plan exposes 699 MB to the guest; `dnf update` was OOM-killed before swap existed.

### Containers

`mem_limit` on both containers (256 m / 128 m) so a leak cannot take the host down. wg-easy runs with `NET_ADMIN` and `SYS_MODULE` — it needs them to create `wg0` and load the module; nothing else is privileged. Caddy strips the `Server` header and sends HSTS, `nosniff`, `DENY` framing, `no-referrer`.

## Phase 2 — after your first device is connected

Not applied by default, because each step can lock you out if WireGuard itself is broken. Do them one at a time, with a second SSH session open.

### 2a. Admin UI only from inside the VPN

Stop publishing 443 to the world and let VPN clients reach the UI through the WireGuard address of the server (`10.8.0.1` by default in wg-easy).

```sh
cd /opt/proxy
# 1. bind Caddy to the WireGuard side only: in compose.yml change
#      - "443:443/tcp"      →      - "10.8.0.1:443:443/tcp"   (fails if wg0 is down — expected)
#    or simply remove the ports: entry and add a Caddyfile site for http://10.8.0.1 with tls internal.
# 2. close the public door
firewall-cmd --permanent --zone=public --remove-port=443/tcp && firewall-cmd --reload
docker compose up -d
```

Caveat: Let's Encrypt renewals need 443 reachable from the internet. Either keep 443 open but add Caddy `@vpn remote_ip 10.8.0.0/24` matcher + `abort` for everything else (public sees an immediate close, no login page), or switch to the DNS-01 challenge with your registrar's API. The matcher approach is the lighter one:

```caddyfile
vpn.example.com {
	@outside not remote_ip 10.8.0.0/24 10.42.42.0/24
	abort @outside
	reverse_proxy wg-easy:51821
}
```

Note Caddy sees the Docker bridge IP as `remote_ip` for traffic that came through the published port — so test from a VPN client *and* from outside before trusting it, and consider `trusted_proxies` carefully. This is the step the author has **not yet applied** on the reference server; it is written down so it can be done deliberately.

### 2b. SSH only from inside the VPN

```sh
firewall-cmd --permanent --zone=public --remove-port=22/tcp
firewall-cmd --permanent --zone=public --add-rich-rule='rule family=ipv4 source address=10.8.0.0/24 port port=22 protocol=tcp accept'
firewall-cmd --reload        # keep your current session open; test a NEW login over the VPN first
```

Recovery if WireGuard dies afterwards: the provider's rescue console/KVM. Make sure you know where it is before doing 2b.

### 2c. Things deliberately not done

- **Port knocking / changing the SSH port.** Key-only + fail2ban already reduces SSH to noise in the logs; obscurity adds friction, not security.
- **A second firewall layer (ufw/raw nftables) on top of firewalld.** Two managers of one ruleset is how you get rules nobody understands. If you prefer a hand-written nftables policy, see [xnftables](https://github.com/paulfxyz/xnftables) and replace firewalld entirely.
- **Running wg-easy with `network_mode: host`.** Avoids the Docker NAT layer and the legacy-iptables module trap, but gives the container's `iptables` calls free rein over the host firewall. The bridge setup keeps blast radius smaller.
- **IPv6 for clients.** The reference VPS has only link-local v6. The compose file keeps the ULA ranges wg-easy expects; remove them if your kernel has `disable_ipv6=1` baked in.
