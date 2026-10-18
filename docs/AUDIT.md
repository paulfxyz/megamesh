# Three-model audit of v1.0.0 → what changed in v1.1.0

Before making the repository public, the complete v1.0.0 bundle (every file, numbered lines) plus the release notes was sent to three frontier models through OpenRouter with the same instructions: audit security, correctness and documentation; cite file:line; grade; list the top five changes before publishing. Raw reports are in [`audit/`](audit/), unedited.

| Model | Verdict | Grade |
|---|---|---|
| [Claude Opus 5.5](audit/claude-opus-5.5.md) | "Not safe to publish as-is" — 25 findings | C |
| [GPT-6.1 Sol Pro](audit/gpt-6.1-sol-pro.md) | "Not safe to publish as a hardened, release-ready installer as-is" — 18 findings | D |
| [Gemini 4 Argon](audit/gemini-4-argon.md) | "Not quite safe to publish as-is" — 18 findings | B+ |

All three agreed the architecture was right (two published ports, unpublished UI, TLS-ALPN, no secrets in the bundle) and all three found the same real bugs. That convergence is the useful signal; the grades are opinion.

## Findings that were real, and what was done

| Finding (models) | Fix in 1.1.0 | Verified how |
|---|---|---|
| **SSH lock-out**: `PermitRootLogin prohibit-password` written even when the script claims to keep password login on; `AllowUsers root` makes it total. (all three — Critical/High) | `PermitRootLogin` and both password directives now follow the same `lock` decision. `PROXY_LOCK_SSH=yes` without a key refuses to run. Installer prints effective `sshd -T` values and tells you to test a new login. | Re-run on the reference server: `permitrootlogin=without-password passwordauthentication=no` with a key present; code path for the key-less case reviewed. |
| **SSH port moves before the firewall opens it** (Claude, GPT — Medium) | Firewall step runs before the SSH step. | Order in `install.sh`. |
| **Public setup wizard race**: the admin account did not exist while 443 was already reachable; the logbook even advertised it. (all three — Critical/High) | Default unattended setup via wg-easy `INIT_*` on first start, through a 0600 env file, then scrubbed and container recreated. Credentials in `/root/proxy-admin-credentials` (0600). Verification step distinguishes `/login` from `/setup`. Docs rewritten in past tense — the owner had completed the wizard before the audit ran. | Fresh-install path not yet exercised end to end (the reference server was already set up); the env-file mechanism and the `/login` check were exercised by the re-run. |
| **Phase 2 recipes wrong**: `10.8.0.1` is inside the container's netns; firewalld rich rule for `10.8.0.0/24` would never match (traffic is MASQUERADEd to `10.42.42.42` on the `docker` zone); `10.42.42.0/24` matcher is a footgun. (all three — High/Medium) | Phase 2a rewritten around a measured mechanism: with Docker `userland-proxy` off, tunnel-origin requests reach Caddy as exactly `10.42.42.42`. `proxy-lockdown` implements it with validation, in-place write and preconditions. Phase 2b (SSH via VPN) withdrawn with an explanation. | Live Caddy access-log measurements, both proxy modes, from inside wg-easy and from a public vantage point — table in [HARDENING.md](HARDENING.md#how-it-was-verified). |
| **`SYS_MODULE` and `/lib/modules` unnecessary** (GPT, Gemini — High/Low) | Removed; host loads and persists the modules. | Container recreated on the reference server with `NET_ADMIN` only: `wg0` up, same keys, peer intact. |
| **`curl \| sh` for Docker on Debian** (all three — Medium) | Official apt repository with keyring. | Code review only (Debian branch is unverified by design). |
| **`daemon.json` clobbered, backed up only sometimes; drifted from `config/`** (Claude, GPT, Gemini) | Always backed up; merged with a JSON parser; validated with `dockerd --validate`; `config/` is now copied from the live server after the installer ran. | Re-run; `config/docker/daemon.json` diff. |
| **Firewall `\|\| true` hides failures; WAN interface zone not checked** (GPT — High) | `fw()` accepts only success/`ALREADY_*`/`NOT_ENABLED`; default-route interface is moved to `public` if elsewhere; reload failure is fatal. | Re-run. |
| **Non-default `PROXY_WG_PORT` would break**: mapping `${PORT}:51820` while wg-easy listens on the wizard port (Claude, GPT — Medium, "unverified") | Confirmed against wg-easy docs (`INIT_PORT`: "port clients will connect to and wireguard will listen on"). Mapping is now `${PORT}:${PORT}`. | Docs; default port unchanged on the reference server. |
| **Unformatted pre-existing `/swapfile` aborts the run** (Claude, Gemini — Low/Medium) | `blkid -t TYPE=swap` check, `mkswap` when missing. | Code. |
| **`accept_ra=0` breaks SLAAC** (Claude, GPT — Low/Medium) | Removed, with a comment. | Code. |
| **Prompt lets the agent hold the only credential; "do not ask me"; invalid one-line Caddyfile** (Claude, GPT — Medium) | Owner supplies their own public key; second session before lock; confirmation before SSH/firewall changes; real multi-line Caddyfile with a validate command. | Prompt review. |
| **Docs/claims**: Rocky/Alma "tested"; `proxy-status` never installed; fail2ban filename; logbook end state; `down -v` deletes Caddy state; HSTS `includeSubDomains` on an apex; `semanage -a` on re-run; unanchored `grep` on `/etc/hosts`; Ubuntu `ssh.socket` ignoring `Port` (various — Low) | All corrected: wording, installer installs both helpers and records settings in `/etc/proxy.conf`, filenames, end state, targeted volume reset, HSTS without `includeSubDomains`, `semanage -a \|\| -m`, `grep -qwF`, `ssh.socket` handled on Debian/Ubuntu. | Code and docs. |

## Findings that were considered and not adopted

- **Pin images by digest by default.** Kept major tags (`wg-easy:15`, `caddy:2-alpine`) so users get security fixes with `docker compose pull`; `WG_EASY_IMAGE`/`CADDY_IMAGE` accept `@sha256:` digests for anyone who wants strict pinning. Documented.
- **Verify external exposure from the installer.** The box cannot probe itself from outside; the docs say how to do it from a laptop and why a sandbox behind an egress proxy is not a valid vantage point.
- **"Future-dated" 2026 dates** (Gemini) — they are correct; the model's clock was behind.
- **Personal email in the Caddyfile** — it is the public contact address for the reference deployment and a required ACME field; the installer takes yours from `PROXY_EMAIL`.
- **Test an actual fail2ban ban** — the jail's presence is verified; staging a ban against your own IP during an unattended install is not something a script should do.

## What the exercise cost and taught

One prompt, three models, roughly 20k input tokens each, a few dollars on OpenRouter, about ten minutes of wall clock (two of the three needed a streaming connection to survive a proxy idle timeout). It found one bug that would have locked a user out of a fresh server and one that would have shipped an unauthenticated admin wizard to the internet by default. The convergence across models made triage trivial: anything all three flagged was real. Reviewers' confident claims about runtime behavior (which IP Caddy sees, whether the container needs `SYS_MODULE`) were treated as hypotheses and measured on the live server before being adopted — one of them (the `10.42.42.0/24` footgun) was correct only under Docker's default userland proxy, which is why the fix includes turning that off rather than just narrowing the matcher.
