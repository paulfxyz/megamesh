## Verdict

**Not safe to publish as-is. Grade: C.** The architecture is sound and well documented: deny-by-default, only two ports published, an unpublished UI port, and TLS-ALPN with no port 80. Two problems block release, though:

- **SSH lock-out.** The installer's default path can lock the operator out over SSH, which contradicts the repo's main safety claim.
- **Unclaimed live admin.** The repo tells the world that the live reference server's one-time admin wizard has not been claimed yet.

The Phase 2 instructions would also fail or lock people out as written, because WireGuard addresses live inside the container's network namespace, not on the host. Some smaller doc and config inconsistencies need cleanup too.

## Findings

| # | Severity | File:line | Issue | Concrete fix |
|---|---|---|---|---|
| 1 | Critical | install.sh:123, 118, 138 | `PermitRootLogin prohibit-password` is written unconditionally. In `auto` mode with no key, line 118 warns *"keeping password login ON"*, but root password login is refused anyway. `AllowUsers root` (138) then blocks every other account, so a fresh box run without `PROXY_SSH_PUBKEY` locks the user out after `systemctl restart sshd`. | Emit `PermitRootLogin $([[ $lock == yes ]] && echo prohibit-password \|\| echo yes)`. Better: `die` when no key is present unless `PROXY_LOCK_SSH=no` is set explicitly. |
| 2 | Critical | docs/LOGBOOK.md:47, 65; docs/DNS.md:45 | The repo states that `https://paulfleury.network/` → `302 /setup/1` and that admin creation is still open. The wizard is first-come-first-served (TROUBLESHOOTING.md:41: "Someone else got there first"). Publishing this invites a takeover of the live VPN admin. | Claim the admin account (or close 443) **before** pushing. Reword the logbook to past tense. |
| 3 | High | install.sh:280, README.md:60 | Every fresh install exposes an unauthenticated setup wizard on public 443 from the moment DNS resolves. | Use wg-easy v15 unattended setup (`INIT_ENABLED=true`, `INIT_USERNAME`, `INIT_PASSWORD`, `INIT_HOST`, `INIT_PORT`) with a generated password written to a root-only file. Alternatively, keep 443 closed until the operator confirms. |
| 4 | High | install.sh:117 | `PROXY_LOCK_SSH=yes` disables passwords even when `have_key=0`. Separately, `have_key` only counts lines in the file; it never verifies the key works or belongs to the operator. The README's "refuses to disable passwords until a key is present" claim does not hold for `yes`. | `yes` should still `die` if `have_key == 0`. Document that the guard checks presence, not a successful login. |
| 5 | High | docs/HARDENING.md:65 | `"10.8.0.1:443:443/tcp"`: 10.8.0.1 exists only inside wg-easy's netns, not on the host, so Docker can never bind it. Line 68 also removes 443 publicly while Caddy still needs it for ACME. | Rewrite 2a around the Caddy `remote_ip` matcher or DNS-01. Delete the bind instruction. |
| 6 | High | docs/HARDENING.md:87-88 | 2b allows `source address=10.8.0.0/24` in the public zone. VPN client traffic is MASQUERADEd by wg-easy and reaches the host from 10.42.42.42 on the Docker bridge (docker zone), so the rule never matches. Following this step causes an SSH lock-out. | Test which source and zone the host actually sees (likely 10.42.42.0/24 via the docker zone) and document that. Ship it only together with the planned confirm-or-rollback `lockdown.sh`. |
| 7 | Medium | docs/HARDENING.md:76 | `not remote_ip 10.8.0.0/24 10.42.42.0/24`: any traffic that appears as the bridge gateway (e.g. docker-proxy for IPv6, since `enable_ipv6: true`) bypasses the matcher. Line 82 half-acknowledges this. | Drop 10.42.42.0/24 except the specific wg-easy IP 10.42.42.42. Mark the section experimental. |
| 8 | Medium | install.sh:146 vs 170 | With a non-22 `PROXY_SSH_PORT`, sshd moves ports before firewalld opens the new one (step 6). Any failure in between leaves no reachable SSH port. On Ubuntu ≥22.10, `ssh.socket` ignores `Port` in a drop-in. | Do the firewall step before the sshd restart. On Debian, handle `ssh.socket`. |
| 9 | Medium | install.sh:221, 312 | With a non-default `PROXY_WG_PORT`, the mapping is `PORT:51820/udp`, but the user enters `Port = ${PROXY_WG_PORT}` in the wizard. In v15 that value is likely also the container listen port, which would break the tunnel. *Unverified.* | Map `${PROXY_WG_PORT}:${PROXY_WG_PORT}/udp`, or tell the user to enter 51820 for the listen port. |
| 10 | Medium | install.sh:73 | `curl -fsSL https://get.docker.com \| sh` runs as root, unpinned (Debian branch). | Use Docker's apt repo with key fingerprint verification. |
| 11 | Medium | install.sh:25-26, config/compose.yml:8,36 | Major-only tags (`:15`, `caddy:2-alpine`) are not pinned by digest. | Pin `@sha256:` digests in the release and document the update procedure. |
| 12 | Medium | PROMPT.md:15, 29-33 | The root password goes to a third-party agent in cleartext. The agent generates the only SSH private key and the new root password inside its own sandbox ("Tell me where you stored them"). The owner can end up with no access of their own. "Work autonomously; do not ask me" also removes confirmation before risky steps. | Require the owner to supply their **own** public key. Never leave the agent holding the only credential. Rotate the root password after the session. Require confirmation before SSH and firewall changes. |
| 13 | Low | PROMPT.md:58-62 | The "exact shape" Caddyfile on single lines with inline braces is not valid Caddyfile syntax. | Paste the real multi-line Caddyfile. |
| 14 | Low | config/docker/daemon.json:2 vs install.sh:185-191 | The repo file has `exec-opts` but the installer omits it. That contradicts README.md:85 "the exact files running". The installer also overwrites any other daemon.json keys. | Make them identical. Merge with `jq` instead of overwriting. |
| 15 | Low | docs/TROUBLESHOOTING.md:25 | References `config/fail2ban/sshd.local`, but the file is `proxy-sshd.local`. | Fix the filename. |
| 16 | Low | docs/LOGBOOK.md:30, 44 | "allowed `ssh`" and "services: ssh". The installer removes the `ssh` service and adds port 22/tcp (install.sh:169-170), so the end state no longer matches. | Update the end state, or note that it predates the installer. |
| 17 | Low | install.sh:47-51 | If a stale non-swap `/swapfile` exists, `swapon` fails and `set -e` aborts the install. | `swapon /swapfile \|\| { mkswap /swapfile && swapon /swapfile; }` |
| 18 | Low | install.sh:286 | `grep -q "$PROXY_DOMAIN"` is an unanchored regex (dots match any character). `127.0.1.1` is a Debian convention, not EL. | Use `grep -qwF`. |
| 19 | Low | config/Caddyfile:11 | HSTS `includeSubDomains` on an apex domain forces HTTPS on every future subdomain. | Document this, or drop `includeSubDomains` when the domain is an apex. |
| 20 | Low | config/Caddyfile:2 | A personal email address (`hello@paulfleury.com`) is in the repo. | Replace with a placeholder if it is unintended. |
| 21 | Low | install.sh:96-97 | `accept_ra=0` on `all` breaks SLAAC IPv6 on hosts that rely on it. It is also not set on `default`. | Note this, or make it conditional. |
| 22 | Info | install.sh:142 | `\0` in a `sed -E` replacement works in GNU sed, but `&` is the portable form. | Use `&`. |
| 23 | Info | docs/TROUBLESHOOTING.md:15, PROMPT.md:44 | "Publishes no ports at all" with `iptables:false`: docker-proxy may still bind, depending on the version. *Unsure.* | Soften the claim to "ports are not forwarded correctly". |
| 24 | Info | install.sh:174 | Inbound `echo-reply` is unnecessary because conntrack handles replies. IPv6 NDP relies on firewalld's built-in accept rules. | Optionally drop `echo-reply`. |
| 25 | Info | docs/LOGBOOK.md:3, CHANGELOG.md:3 | Dates are 2026-10-18 and versions are "Docker 29.8.1" and "iptables 1.8.13". Verify these are not typos, or the logbook looks fabricated. | Double-check them. |

## What is good

- Only `51820/udp` and `443/tcp` are published, and the UI port stays on an internal bridge. This shows a correct understanding of how Docker bypasses firewalld.
- No port 80; TLS-ALPN-01 works and is explained.
- The ICMP allow-list keeps PMTU working, and the reason is documented.
- `sshd -t` runs before the restart, and the `00-` drop-in precedence is reasoned correctly.
- The fail2ban jail is explicit and uses the systemd backend with incremental bans.
- The swap guard checks `swapon --show`, which addresses a real trap.
- The legacy iptables module trap is documented and persisted.
- The honest "not tested / not a privacy service" section, and the logbook giving provenance.
- `mem_limit`s, log rotation and `no-new-privileges` are in place.

## Top 5 changes before publishing

1. **Claim the admin account on paulfleury.network now**, then scrub "setup still open" from LOGBOOK.md and DNS.md.
2. **Fix the SSH lock-out:**
   - make `PermitRootLogin` follow `$lock`;
   - make `PROXY_LOCK_SSH=yes` refuse to run without a key;
   - open the new SSH port in firewalld *before* restarting sshd.
3. **Eliminate the public setup-wizard race** by using v15 `INIT_*` unattended setup with a generated password stored in a root-only (0600) file.
4. **Rewrite or remove Phase 2 (2a/2b)** until it has been tested. Account for wg-easy's netns and MASQUERADE, and ship it via `lockdown.sh` with an automatic rollback timer.
5. **Tighten supply chain and consistency:**
   - pin images by digest and replace `curl | sh`;
   - make `config/` byte-identical to what the installer writes;
   - fix the fail2ban filename and the logbook end-state mismatches;
   - harden PROMPT.md so the owner supplies their own SSH key and the agent never holds the only credential.