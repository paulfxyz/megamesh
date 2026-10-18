# The prompt

Paste this into any AI agent that can run shell commands over SSH (Perplexity Computer, Claude Code, Codex, OpenHands, Devin, aider, your own agent…). Replace the values in the first block. That is all the context it needs; the rest of the prompt is the know-how so the agent does not have to rediscover the traps.

If you want the agent to follow this repository exactly, add one line: *"Clone `https://github.com/paulfxyz/megamesh`, read `install.sh` and `docs/` before acting, then run `install.sh`."* The prompt below also works standalone.

**Before you paste it:** generate your own SSH key pair on your laptop (`ssh-keygen -t ed25519`) and put the *public* key in the prompt. The agent must never be the only holder of a credential to your server. Give it the initial root password — you will rotate it right after — and have your provider's rescue console bookmarked.

---

```text
You are setting up my personal, self-hosted WireGuard VPN with a web admin UI on a fresh VPS.
Work autonomously on the server, but STOP and ask me before any change to SSH access or firewall rules
is made effective (restart of sshd, firewall reload). Report at the end.

SERVER
  IP:              <SERVER_IP>
  root login:      root / <ROOT_PASSWORD>   (SSH, port 22) — I will rotate this password after you are done
  SSH host key:    <optional: fingerprint from the provider panel, so you can verify you are talking to my box>
  OS:              <OS, e.g. CentOS Stream 9 | Debian 12 | Ubuntu 24.04>
  Domain:          <vpn.example.com>        (I control DNS; tell me what records to create)
  My email:        <you@example.com>        (for Let's Encrypt only)
  MY public key:   ssh-ed25519 AAAA... me@laptop   ← install this for root. This is my way in.

GOAL
  1. WireGuard server with the wg-easy v15 web UI (ghcr.io/wg-easy/wg-easy:15), reachable only at
     https://<domain>/ behind Caddy with a Let's Encrypt certificate. The UI port itself must not be public.
  2. A deny-by-default firewall. Public internet may reach exactly: SSH (tcp/22), WireGuard (udp/51820),
     HTTPS (tcp/443). Allow ping and the ICMP types needed for path-MTU. Nothing else, no port 80.
  3. The box hardened for one personal user: key-only SSH, fail2ban on SSH, automatic security updates,
     docker log rotation, sane sysctl, swap if RAM < 2 GB.
  4. The admin account must exist BEFORE the UI is reachable from the internet (see wg-easy unattended setup).

RULES
  - FIRST ACTIONS, in this order: (1) install MY public key for root; (2) open a second SSH session with
    it and confirm it works; (3) generate a long random root password, change it, and write it to a
    root-only file on the server (/root/.megamesh-root-password, mode 0600) — tell me the path, not the value;
    (4) only then disable password authentication, and set PermitRootLogin to prohibit-password. Never disable
    passwords before a key login has succeeded. Keep MaxAuthTries low.
  - If you need your own key for the session, add it as a SECOND key and tell me to remove it afterwards.
    You must never end the session as the only holder of a credential to this server.
  - Never print the root password, private keys, WireGuard private keys or the admin password in your
    output or in any file you leave in your own workspace. Tell me where on the server you stored them.
  - Make every change idempotent and leave config in files (sshd_config.d drop-in, fail2ban jail.d,
    sysctl.d, modules-load.d, /opt/megamesh/compose.yml, /opt/megamesh/Caddyfile) so it survives reboots.
  - Open a new firewall port BEFORE moving a service onto it. Reload the firewall and restart sshd only
    with a second session open, and verify with a NEW connection afterwards.
  - Verify after each step by reading state (sshd -T, firewall-cmd --list-all, docker ps, wg show, curl),
    not by assuming the command worked.
  - Reboot at the end and confirm everything comes back by itself.

KNOWN TRAPS (these cost real time; check them up front)
  - Small VPS (≤1 GB): the first full package update can be OOM-killed. Create and activate swap before
    updating. Some images ship a /swapfile that is NOT enabled or NOT formatted — check `swapon --show`
    and `blkid /swapfile`, not just `ls`.
  - Provider images may ship /etc/docker/daemon.json with "iptables": false. Docker then publishes no
    ports at all and nothing tells you. Merge the file (keep other keys, back it up), remove that key.
  - wg-easy's container uses legacy iptables. On EL9/recent kernels the host must have these modules
    loaded or `wg-quick up` fails with "can't initialize iptables table nat":
    wireguard ip_tables iptable_nat iptable_filter ip6_tables ip6table_nat ip6table_filter nf_nat xt_MASQUERADE
    modprobe them, persist in /etc/modules-load.d/, and then run the container with cap NET_ADMIN only —
    it does not need SYS_MODULE or a /lib/modules mount.
  - fail2ban may be installed and running with ZERO jails. `fail2ban-client status` must list sshd.
  - firewalld + Docker: Docker adds a "docker-forwarding" policy that lets ANY published port through,
    regardless of the public zone. So publish only udp/51820 and tcp/443; keep wg-easy's UI port unpublished
    and reachable only via Caddy on the internal docker network. Check the default-route interface is
    actually in the public zone.
  - wg-easy's first-run wizard is unauthenticated: whoever opens https://<domain>/ first owns the VPN.
    Use unattended setup on the FIRST start only: INIT_ENABLED=true, INIT_USERNAME, INIT_PASSWORD (plaintext,
    generate 32 chars), INIT_HOST=<domain>, INIT_PORT=51820 (this is both the endpoint and the listen port).
    Pass them via an env_file (mode 0600), wait for the container to be healthy, remove the INIT_* lines,
    recreate the container. Store the admin credentials in /root/megamesh-admin-credentials (0600).
  - Caddy needs the DNS A record before it can get a certificate. Deploy anyway; it retries on its own.
    A transient "HTTP 504 fetching nonce" from Let's Encrypt is normal — do not restart Caddy in a loop.
  - The Caddyfile is a single-file bind mount: edit it IN PLACE (cp over it), never `sed -i`/`mv`, or the
    running container keeps the old inode and reports "config is unchanged".
  - Do not open tcp/80. Caddy will use the TLS-ALPN-01 challenge on 443. Tell me to always type https://.

CADDYFILE (/opt/megamesh/Caddyfile — use exactly this, replace the two placeholders)
  {
  	email <email>
  	servers {
  		protocols h1 h2
  	}
  }

  <domain> {
  	header {
  		Strict-Transport-Security "max-age=31536000"
  		X-Content-Type-Options "nosniff"
  		X-Frame-Options "DENY"
  		Referrer-Policy "no-referrer"
  		-Server
  	}
  	encode zstd gzip
  	reverse_proxy wg-easy:51821
  }
  Validate with `docker run --rm -v /opt/megamesh/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2-alpine caddy validate`.

DELIVER
  - What to put in DNS (A record; recommend keeping the registrar's DNS, not self-hosting nameservers)
    and where to set reverse DNS (PTR) at the provider.
  - The login URL, the admin username, and the server path of the credentials file. Tell me to enable
    two-factor authentication in the UI after the first login.
  - A summary of the firewall rules, SSH policy, which keys are in /root/.ssh/authorized_keys, and anything
    you could not verify.
  - Optional phase 2 I can ask for later: make the admin UI reachable only through the VPN and redirect
    everyone else to a URL of my choice (Caddy remote_ip matcher on the wg-easy container address; requires
    Docker "userland-proxy": false so the hairpin keeps its source address).
```

---

## Why a prompt and not only a script

`install.sh` is deterministic and fast, but it assumes a known distribution and a known starting state. A real VPS arrives with surprises — a disabled swap file, a Docker daemon that was told not to touch the firewall, a fail2ban with no jails. An agent reading the state and adapting handles those; a script can only guard against the ones it knows. The prompt carries the ones we know, so the agent starts where this project finished rather than where it started.

## Why the rules about keys and confirmation

The first version of this prompt said "work autonomously; do not ask me" and let the agent generate the only SSH key. Three independent model audits flagged that: the owner could end a session with no access of their own, and a single wrong sshd restart would have no human in the loop. The current rules cost two confirmations and one `ssh-keygen` on your laptop. Worth it.
