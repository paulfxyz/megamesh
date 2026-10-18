# Three-model audits

## Round 1: v1.0.0 → v1.1.0

Before making the repository public, the complete v1.0.0 bundle (every file, numbered lines) plus the release notes was sent to three frontier models through OpenRouter with the same instructions: audit security, correctness and documentation; cite file:line; grade; list the top five changes before publishing. Raw reports are in [`audit/`](audit/), unedited.

| Model | Verdict | Grade |
|---|---|---|
| [Claude Opus 5.5](audit/claude-opus-5.5.md) | "Not safe to publish as-is" — 25 findings | C |
| [GPT-6.1 Sol Pro](audit/gpt-6.1-sol-pro.md) | "Not safe to publish as a hardened, release-ready installer as-is" — 18 findings | D |
| [Gemini 4 Argon](audit/gemini-4-argon.md) | "Not quite safe to publish as-is" — 18 findings | B+ |

All three agreed the architecture was right (two published ports, unpublished UI, TLS-ALPN, no secrets in the bundle) and all three found the same real bugs. That convergence is the useful signal; the grades are opinion.

### Findings that were real, and what was done

| Finding (models) | Fix in 1.1.0 | Verified how |
|---|---|---|
| **SSH lock-out**: `PermitRootLogin prohibit-password` written even when the script claims to keep password login on; `AllowUsers root` makes it total. (all three — Critical/High) | `PermitRootLogin` and both password directives now follow the same `lock` decision. `MEGAMESH_LOCK_SSH=yes` without a key refuses to run. Installer prints effective `sshd -T` values and tells you to test a new login. | Re-run on the reference server: `permitrootlogin=without-password passwordauthentication=no` with a key present; code path for the key-less case reviewed. |
| **SSH port moves before the firewall opens it** (Claude, GPT — Medium) | Firewall step runs before the SSH step. | Order in `install.sh`. |
| **Public setup wizard race**: the admin account did not exist while 443 was already reachable; the logbook even advertised it. (all three — Critical/High) | Default unattended setup via wg-easy `INIT_*` on first start, through a 0600 env file, then scrubbed and container recreated. Credentials in `/root/megamesh-admin-credentials` (0600). Verification step distinguishes `/login` from `/setup`. Docs rewritten in past tense — the owner had completed the wizard before the audit ran. | Fresh-install path not yet exercised end to end (the reference server was already set up); the env-file mechanism and the `/login` check were exercised by the re-run. |
| **Phase 2 recipes wrong**: `10.8.0.1` is inside the container's netns; firewalld rich rule for `10.8.0.0/24` would never match (traffic is MASQUERADEd to `10.42.42.42` on the `docker` zone); `10.42.42.0/24` matcher is a footgun. (all three — High/Medium) | Phase 2a rewritten around a measured mechanism: with Docker `userland-proxy` off, tunnel-origin requests reach Caddy as exactly `10.42.42.42`. `megamesh-lockdown` implements it with validation, in-place write and preconditions. Phase 2b (SSH via VPN) withdrawn with an explanation. | Live Caddy access-log measurements, both proxy modes, from inside wg-easy and from a public vantage point — table in [HARDENING.md](HARDENING.md#how-it-was-verified). |
| **`SYS_MODULE` and `/lib/modules` unnecessary** (GPT, Gemini — High/Low) | Removed; host loads and persists the modules. | Container recreated on the reference server with `NET_ADMIN` only: `wg0` up, same keys, peer intact. |
| **`curl \| sh` for Docker on Debian** (all three — Medium) | Official apt repository with keyring. | Code review only (Debian branch is unverified by design). |
| **`daemon.json` clobbered, backed up only sometimes; drifted from `config/`** (Claude, GPT, Gemini) | Always backed up; merged with a JSON parser; validated with `dockerd --validate`; `config/` is now copied from the live server after the installer ran. | Re-run; `config/docker/daemon.json` diff. |
| **Firewall `\|\| true` hides failures; WAN interface zone not checked** (GPT — High) | `fw()` accepts only success/`ALREADY_*`/`NOT_ENABLED`; default-route interface is moved to `public` if elsewhere; reload failure is fatal. | Re-run. |
| **Non-default `MEGAMESH_WG_PORT` would break**: mapping `${PORT}:51820` while wg-easy listens on the wizard port (Claude, GPT — Medium, "unverified") | Confirmed against wg-easy docs (`INIT_PORT`: "port clients will connect to and wireguard will listen on"). Mapping is now `${PORT}:${PORT}`. | Docs; default port unchanged on the reference server. |
| **Unformatted pre-existing `/swapfile` aborts the run** (Claude, Gemini — Low/Medium) | `blkid -t TYPE=swap` check, `mkswap` when missing. | Code. |
| **`accept_ra=0` breaks SLAAC** (Claude, GPT — Low/Medium) | Removed, with a comment. | Code. |
| **Prompt lets the agent hold the only credential; "do not ask me"; invalid one-line Caddyfile** (Claude, GPT — Medium) | Owner supplies their own public key; second session before lock; confirmation before SSH/firewall changes; real multi-line Caddyfile with a validate command. | Prompt review. |
| **Docs/claims**: Rocky/Alma "tested"; `megamesh-status` never installed; fail2ban filename; logbook end state; `down -v` deletes Caddy state; HSTS `includeSubDomains` on an apex; `semanage -a` on re-run; unanchored `grep` on `/etc/hosts`; Ubuntu `ssh.socket` ignoring `Port` (various — Low) | All corrected: wording, installer installs both helpers and records settings in `/etc/megamesh.conf`, filenames, end state, targeted volume reset, HSTS without `includeSubDomains`, `semanage -a \|\| -m`, `grep -qwF`, `ssh.socket` handled on Debian/Ubuntu. | Code and docs. |

### Findings that were considered and not adopted

- **Pin images by digest by default.** Kept major tags (`wg-easy:15`, `caddy:2-alpine`) so users get security fixes with `docker compose pull`; `WG_EASY_IMAGE`/`CADDY_IMAGE` accept `@sha256:` digests for anyone who wants strict pinning. Documented.
- **Verify external exposure from the installer.** The box cannot probe itself from outside; the docs say how to do it from a laptop and why a sandbox behind an egress proxy is not a valid vantage point.
- **"Future-dated" 2026 dates** (Gemini) — they are correct; the model's clock was behind.
- **Personal email in the Caddyfile** — it is the public contact address for the reference deployment and a required ACME field; the installer takes yours from `MEGAMESH_EMAIL`.
- **Test an actual fail2ban ban** — the jail's presence is verified; staging a ban against your own IP during an unattended install is not something a script should do.

### What the exercise cost and taught

One prompt, three models, roughly 20k input tokens each, a few dollars on OpenRouter, about ten minutes of wall clock (two of the three needed a streaming connection to survive a proxy idle timeout). It found one bug that would have locked a user out of a fresh server and one that would have shipped an unauthenticated admin wizard to the internet by default. The convergence across models made triage trivial: anything all three flagged was real. Reviewers' confident claims about runtime behavior (which IP Caddy sees, whether the container needs `SYS_MODULE`) were treated as hypotheses and measured on the live server before being adopted — one of them (the `10.42.42.0/24` footgun) was correct only under Docker's default userland proxy, which is why the fix includes turning that off rather than just narrowing the matcher.

## Round 2: v1.1.0 → v1.2.0 (final pass, after the rename)

Same three models, same instructions, told to focus on what was still wrong or newly introduced. Reports: [`audit/round2-*`](audit/). Grades B / C / A-; all three said "not publishable as-is" for a shared reason that the author had just observed live: **re-running `install.sh` rewrote the Caddyfile in open mode and switched VPN-only off.**

| Finding (models) | Fix in 1.2.0 | Verified how |
|---|---|---|
| **Re-run disables VPN-only mode** (all three — High) | Existing mode and redirect URL are detected; the open Caddyfile is not written at all in that case; `megamesh-lockdown enable` re-renders after the stack is up. | Re-run on the live, locked-down reference server: mode kept, outsider still gets `302 https://paulfleury.com/`. |
| **Unattended first start fails open**: `INIT_*` scrubbed after a health timeout even if setup never ran; Caddy started alongside (GPT High, Gemini Low, Claude Low) | First start brings up wg-easy alone, requires healthy **and** `/login`, then scrubs and starts Caddy; otherwise `die` with Caddy never started. Compose project name taken from `docker compose config`, not `basename`. | Code path reviewed; the non-first-start branch exercised live. Fresh-VPS run still pending (roadmap). |
| **`upgrade_type = security` does nothing on CentOS Stream** (Claude — Medium) | `default` on `ID=centos`, `security` elsewhere; docs and status output corrected. | `/etc/dnf/automatic.conf` on the reference server now `upgrade_type = default`. |
| **`set -e` pipeline traps in `lockdown.sh`**: `wg show … \| wc -l` and the `wget` check could abort after the Caddyfile was switched (Claude, GPT) | `\|\| true` inside the substitutions; verification reads the first `Location:` header and rolls back to open mode if the tunnel side is being redirected. | `megamesh-lockdown enable` on the live server: "first response → /login". |
| **Allow-list matcher too wide** (`10.8.0.0/24` for an unsupported topology) (GPT — Medium) | Matcher is the single measured address `10.42.42.42`. | Rendered and applied live. |
| **Password / URL sanitising**: `INIT_PASSWORD` through Compose env-file parsing; redirect URL could inject Caddyfile tokens (Gemini, Claude, GPT) | `MEGAMESH_ADMIN_PASSWORD` restricted to `[A-Za-z0-9._%+-]{12,}`; URL rejects whitespace, quotes, braces, semicolons; env file created 0600 via `mktemp` before any write; `umask` in a subshell. | Code. |
| **`daemon.json` merge replaced malformed JSON silently** (GPT — Medium) | Aborts with a message on unreadable/invalid JSON or non-object root. | Code. |
| **"Exactly three doors" not reconciled on re-run / port change** (GPT — Medium) | Previous WireGuard port retired; previous SSH port kept open with explicit instructions to remove it after a verified login; any non-owned ports/services/rich rules (excluding fail2ban's reject rules) reported. | Re-run on live server: warning correctly silent except for fail2ban bans before the exclusion was added. |
| **Port bounds / collisions; `openssl` not installed** (Gemini, Claude — Low) | 1–65535, not 443/51821; `openssl` in both package lists. | Code. |
| **SELinux label failure only warned** (GPT — High, as part of SSH migration) | `die` when SELinux is enforcing and the custom port cannot be labelled. | Code. |
| **Allow-list wording**: IP reassignment, "never the sole control", staleness (all three) | README section and `egress.json` `policy` field carry the caveats. | Text. |
| **Docs**: logbook order and end state, `config/Caddyfile` not matching the live VPN-only state, "four values", `/setup/1` in DNS.md, `docker-proxy` as a symptom, volume name, server ID in DNS.md (all three — Nits) | All corrected; `config/` re-copied from the live server. | Text. |

### Not adopted

- **Transactional SSH port migration with timed rollback** (GPT). Keeping both ports open until the operator confirms is the pragmatic version; a rollback timer that silently reverts sshd is its own foot-gun. Documented instead.
- **Regression test suite** (GPT). Welcome as a contribution; the author's test rig is the live reference server plus `shellcheck`.
- **Signed commits for `egress.json`** (Claude). Reasonable; not set up yet. The README no longer promises it.
