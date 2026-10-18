# The prompt

Paste this into any AI agent that can run shell commands over SSH (Perplexity Computer, Claude Code, Codex, OpenHands, Devin, aider, your own agent…). Replace the four values in the first block. That is all the context it needs; the rest of the prompt is the know-how so the agent does not have to rediscover the traps.

If you want the agent to follow this repository exactly, add one line: *"Use `https://github.com/paulfxyz/proxy` — read `install.sh` and `docs/` before acting, then run `install.sh`."* The prompt below also works standalone.

---

```text
You are setting up my personal, self-hosted WireGuard VPN with a web admin UI on a fresh VPS.
Work autonomously; do not ask me to run commands. Report at the end.

SERVER
  IP:          <SERVER_IP>
  root login:  root / <ROOT_PASSWORD>   (SSH, port 22)
  OS:          <OS, e.g. CentOS Stream 9 | Debian 12 | Ubuntu 24.04>
  Domain:      <vpn.example.com>        (I control DNS; tell me what records to create)
  My email:    <you@example.com>        (for Let's Encrypt only)

GOAL
  1. WireGuard server with the wg-easy v15 web UI (ghcr.io/wg-easy/wg-easy:15), reachable only at
     https://<domain>/ behind Caddy with a Let's Encrypt certificate. The UI port itself must not be public.
  2. A deny-by-default firewall. Public internet may reach exactly: SSH (tcp/22), WireGuard (udp/51820),
     HTTPS (tcp/443). Allow ping and the ICMP types needed for path-MTU. Nothing else, no port 80.
  3. The box hardened for one personal user: key-only SSH, fail2ban on SSH, automatic security updates,
     docker log rotation, sane sysctl, swap if RAM < 2 GB.

RULES
  - FIRST ACTION: generate a long random root password and change it. Generate an ed25519 SSH key, install
    the public key for root, verify you can log in with the key, THEN disable password authentication.
    Never disable passwords before a key login has succeeded. Keep MaxAuthTries low.
  - Never print the root password, private keys, or WireGuard private keys in your output. Tell me where
    you stored them; I may ask for them later.
  - Make every change idempotent and leave config in files (sshd_config.d drop-in, fail2ban jail.d,
    sysctl.d, modules-load.d, /opt/proxy/compose.yml, /opt/proxy/Caddyfile) so it survives reboots.
  - Verify after each step by reading state (sshd -T, firewall-cmd --list-all, docker ps, wg show), not
    by assuming the command worked.
  - Reboot at the end and confirm everything comes back by itself.

KNOWN TRAPS (these cost real time; check them up front)
  - Small VPS (≤1 GB): the first full package update can be OOM-killed. Create and activate swap before
    updating. Some images ship a /swapfile that is NOT enabled — check `swapon --show`, not just `ls`.
  - Hostkey/other provider images may ship /etc/docker/daemon.json with "iptables": false. Docker then
    publishes no ports at all and nothing tells you. Remove that key (or use host networking).
  - wg-easy's container uses legacy iptables. On EL9/recent kernels the host must have these modules
    loaded or `wg-quick up` fails with "can't initialize iptables table nat":
    wireguard ip_tables iptable_nat iptable_filter ip6_tables ip6table_nat ip6table_filter nf_nat xt_MASQUERADE
    modprobe them and persist in /etc/modules-load.d/.
  - fail2ban may be installed and running with ZERO jails. `fail2ban-client status` must list sshd.
  - firewalld + Docker: Docker adds a "docker-forwarding" policy that lets ANY published port through,
    regardless of the public zone. So publish only udp/51820 and tcp/443; keep wg-easy's UI port unpublished
    and reachable only via Caddy on the internal docker network.
  - Caddy needs the DNS A record before it can get a certificate. Deploy anyway; it retries on its own.
    A transient "HTTP 504 fetching nonce" from Let's Encrypt is normal — just wait.
  - Do not open tcp/80. Caddy will use the TLS-ALPN-01 challenge on 443. Tell me to always type https://.

CADDYFILE (use exactly this shape)
  { email <email>  servers { protocols h1 h2 } }
  <domain> { encode zstd gzip
             header { Strict-Transport-Security "max-age=31536000; includeSubDomains"
                      X-Content-Type-Options nosniff  X-Frame-Options DENY  Referrer-Policy no-referrer  -Server }
             reverse_proxy wg-easy:51821 }

DELIVER
  - What to put in DNS (A record; recommend keeping the registrar's DNS, not self-hosting nameservers)
    and where to set reverse DNS (PTR) at the provider.
  - The URL of the one-time wg-easy setup wizard where I create the single admin account, and what to
    enter for Host/Port there.
  - A summary of the firewall rules, SSH policy, and anything you could not verify.
  - Optional phase 2 I can ask for later: restrict the admin UI and SSH to VPN-only once my first device works.
```

---

## Why a prompt and not only a script

`install.sh` is deterministic and fast, but it assumes a known distribution and a known starting state. A real VPS arrives with surprises — a disabled swap file, a Docker daemon that was told not to touch the firewall, a fail2ban with no jails. An agent reading the state and adapting handles those; a script can only guard against the ones it knows. The prompt carries the ones we know, so the agent starts where this project finished rather than where it started.
