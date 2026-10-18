# Changelog

## 1.5.1 — 2026-10-18

- **megamesh.sh redesigned again.** The Construct (1.5.0) lasted an evening. The site is now light, typographic and modern: mist grey `#f2f4f6`, ink `#060a12`, electric blue `#2c56f5` fading to teal; Geist + Geist Mono; pill navigation, floating dock, scroll-brightening manifesto, a three-tab terminal that types the three ways in, live GitHub stars/release, a count-up and a stage-by-stage pipeline drawing. No illustrations. Light/dark switch and the 50-language picker kept; engravings and Matrix references removed.
- **Door 03 is "the deployer" again** (was "the Operator"). Same four steps — server · check · install · hand over — same optional root-password change, reskinned.
- **Logo recoloured**: white M-shield on a blue tile (`docs/logo.svg`, `docs/favicon.svg`), bare mark in `currentColor`. README, badges and screenshots updated; `docs/pills.webp`, `docs/morpheus.webp`, `docs/choice.png` removed.
- Mobile fixes: the port-count bars and pipeline stages now lay out correctly under 560 px; social preview image regenerated.

## 1.5.0 — 2026-10-18

- **megamesh.sh redesigned — "the Construct".** Own identity instead of the megastack.sh look: bone white, ink, one ultraviolet; Instrument Serif + Instrument Sans + Geist Mono; faint grid. Eight graphite engravings in the calliope.agency style (pills in hands, the bald man in the coat, two chairs and a TV, the wall with three doors and the agents, white rabbit, spoon, phone booth, operator's tape deck). Matrix references throughout; no green, no red.
- **Light/dark switch** (dark = graphite room, engravings as negatives), **language picker** with the 50 most spoken languages, flags and search (English content only for now; choice remembered), mobile menu, scroll reveals, typewriter, count-up, logo that redraws on hover and pings on click.
- **The Operator** (door 03, formerly "the deployer") can now **change the root password** before the install: optional field with a generator, applied via `chpasswd` as a separate `passwd` action; the client switches to the new password for all later calls, which proves it took. Shown again at hand-over with copy buttons. Also: per-field validation, consent checkbox, plan summary, phase indicator and elapsed time during the install, retry after lost contact, non-secret fields survive a reload.
- **New logo**: one M whose legs curve into a shield point, with an ultraviolet node (`docs/logo.svg`, `docs/logo-mark.svg`, `docs/favicon.svg`). README rebuilt around the new identity with screenshots (`docs/site.png`, `docs/deployer.png`, `docs/choice.png`).
- Site asset URLs are versioned (`?v=`) so cached stylesheets never outlive a deploy; `/api/lib/` denial fixed to survive Apache's `<FilesMatch>` merge order.

## 1.4.0 — 2026-10-18

- **megamesh.sh is live**: landing page in the megastack.sh design language plus the web deployer (door 03) — a stateless PHP endpoint around phpseclib that logs into the user's VPS, runs `megamesh.sh` with defaults (`MEGAMESH_LOCK_SSH=no`), polls the log and hands over the admin credentials. Source under `site/`.
- **Installer renamed `install.sh` → `megamesh.sh`** (served at https://megamesh.sh/megamesh.sh). Run standalone it fetches the matching release tarball for helpers and configs; `install.sh` remains as a shim.
- **New logo**: a single M shaped like a shield (`docs/logo.svg`, `docs/logo-mark.svg`); hero updated.
- Naming rule: "Megamesh" as a word, `megamesh` / `megamesh.sh` in technical contexts.

## 1.3.0 — 2026-10-18

- **Scheduled upgrades with topgrade.** `scripts/upgrade.sh` → `megamesh-upgrade`: topgrade (`system` + `containers`) → `docker compose up -d` → health check (wg-easy healthy, `wg0` up, Caddy on 443) → image rollback by recorded image ID on failure → reboot only when the kernel/libc requires it (`MEGAMESH_AUTO_REBOOT`, default 1). Weekly systemd timer (`MEGAMESH_UPGRADE_SCHEDULE`, default `Mon *-*-* 04:30`, 20 min jitter, persistent). `--dry-run` and `--no-reboot` flags.
- `megamesh.sh`: installs topgrade 17.13.1 from the GitHub release as a static musl binary, pinned by version and SHA-256 (`TOPGRADE_VERSION`, `TOPGRADE_SHA256_X86_64`); writes `/etc/megamesh/topgrade.toml` and the systemd units; validates the schedule with `systemd-analyze calendar`; `MEGAMESH_TOPGRADE=0` opts out. Records `MEGAMESH_AUTO_REBOOT` in `/etc/megamesh.conf`.
- `megamesh-status`: shows the next timer run, topgrade version and the last run's result lines.
- Logo (`docs/logo.svg`), hero updated, README "Keeping it updated" section, HARDENING/TROUBLESHOOTING/PROMPT updated.
- Fixed during live testing: topgrade stops its containers step at the first failed pull, so rollback references are image IDs rather than `*:megamesh-prev` tags; `allow_root = true` for non-interactive root runs; firewall exposure check ignores fail2ban reject/drop rich rules.

## 1.2.0 — 2026-10-18

- **Renamed `proxy` → `megamesh`** (nod to megastack.sh). Repository is now `paulfxyz/megamesh` (GitHub redirects the old URL). Env-var prefix `PROXY_*` → `MEGAMESH_*`; helpers `megamesh-status` / `megamesh-lockdown`; `/etc/megamesh.conf`; default dir `/opt/megamesh`; config file names `00-megamesh-hardening.conf`, `99-megamesh-hardening.conf`, `megamesh-sshd.local`, `modules-load.d/megamesh.conf`; credentials file `/root/megamesh-admin-credentials`. Existing installs: re-run `megamesh.sh` from the new checkout; it writes the new file names (remove the old `*proxy*` drop-ins by hand or with the snippet in docs/TROUBLESHOOTING.md).
- README: "Whitelisting the author" section and `egress.json` — the reference server's address as the owner's public egress, machine-readable.
- Second audit pass (same three models) on the renamed tree; see docs/AUDIT.md.

## 1.1.0 — 2026-10-18

Response to a three-model audit of 1.0.0 (Claude Opus 5.5, GPT-6.1 Sol Pro, Gemini 4 Argon — see `docs/AUDIT.md`), plus the VPN-only mode.

### Fixed
- **SSH lock-out on key-less hosts**: `PermitRootLogin prohibit-password` was written unconditionally; now follows the same decision as the password directives. `MEGAMESH_LOCK_SSH=yes` without a key refuses to run.
- Firewall is configured **before** sshd restarts, so a custom `MEGAMESH_SSH_PORT` is open when the service moves.
- Non-default `MEGAMESH_WG_PORT` now maps `${PORT}:${PORT}` (wg-easy listens on the configured port).
- `daemon.json` is merged (JSON parser), always backed up, validated; no longer clobbered.
- Firewall commands fail loudly on anything but "already there"; default-route interface is moved into `public` if needed.
- Pre-existing unformatted `/swapfile` is `mkswap`'d instead of aborting; `grep -qwF` on `/etc/hosts`; `semanage -a || -m`; Ubuntu `ssh.socket` handled.
- Docs: phase-2 recipes that ignored the container network namespace removed; filenames, end state, Rocky/Alma wording, `down -v` warning corrected.

### Changed
- wg-easy runs with `NET_ADMIN` only; `SYS_MODULE` and the `/lib/modules` mount are gone (host loads the modules).
- Docker `userland-proxy` off (no `docker-proxy` processes; hairpin traffic keeps its real source).
- Debian/Ubuntu branch installs Docker from the signed apt repository instead of `curl | sh`.
- HSTS without `includeSubDomains`; `accept_ra` sysctl dropped; ICMP allow-list trimmed to what is needed.
- `PROMPT.md`: owner supplies their own public key, second session before lock, confirmation before SSH/firewall changes, real Caddyfile.

### Added
- **Unattended admin account** (`MEGAMESH_UNATTENDED=1` default): created via wg-easy `INIT_*` on first start, before 443 is reachable; credentials in `/root/megamesh-admin-credentials`; `INIT_*` scrubbed and container recreated afterwards.
- **`scripts/lockdown.sh` → `megamesh-lockdown`**: VPN-only admin UI with redirect for outsiders; `render` to preview and validate, preconditions (peers exist, userland-proxy off), in-place Caddyfile write, reload, tunnel-side check.
- `/etc/megamesh.conf` written by the installer; `megamesh-status` and `megamesh-lockdown` installed by the installer.
- `docs/AUDIT.md` and the three raw reports under `docs/audit/`; Hostkey PTR instructions in `docs/DNS.md`.

## 1.0.0 — 2026-10-18

First release, distilled from the reference deployment on `paulfleury.network` (CentOS Stream 9, Hostkey 1 vCPU / 1 GB).

- `megamesh.sh`: idempotent, non-interactive installer — swap guard, packages, kernel modules, sysctl, key-only SSH with lock-out guard, fail2ban, firewalld three-door policy, Docker daemon fix, wg-easy v15 + Caddy stack, hostname, unattended security updates, self-check.
- `PROMPT.md`: the agent prompt with the known traps baked in.
- `config/`: the exact files running on the reference server.
- `scripts/status.sh`: one-screen health check.
- `docs/`: DNS and rDNS, hardening phases, troubleshooting, logbook.
