# Changelog

## 1.3.0 — 2026-10-18

- **Scheduled upgrades with topgrade.** `scripts/upgrade.sh` → `megamesh-upgrade`: topgrade (`system` + `containers`) → `docker compose up -d` → health check (wg-easy healthy, `wg0` up, Caddy on 443) → image rollback by recorded image ID on failure → reboot only when the kernel/libc requires it (`MEGAMESH_AUTO_REBOOT`, default 1). Weekly systemd timer (`MEGAMESH_UPGRADE_SCHEDULE`, default `Mon *-*-* 04:30`, 20 min jitter, persistent). `--dry-run` and `--no-reboot` flags.
- `install.sh`: installs topgrade 17.13.1 from the GitHub release as a static musl binary, pinned by version and SHA-256 (`TOPGRADE_VERSION`, `TOPGRADE_SHA256_X86_64`); writes `/etc/megamesh/topgrade.toml` and the systemd units; validates the schedule with `systemd-analyze calendar`; `MEGAMESH_TOPGRADE=0` opts out. Records `MEGAMESH_AUTO_REBOOT` in `/etc/megamesh.conf`.
- `megamesh-status`: shows the next timer run, topgrade version and the last run's result lines.
- Logo (`docs/logo.svg`), hero updated, README "Keeping it updated" section, HARDENING/TROUBLESHOOTING/PROMPT updated.
- Fixed during live testing: topgrade stops its containers step at the first failed pull, so rollback references are image IDs rather than `*:megamesh-prev` tags; `allow_root = true` for non-interactive root runs; firewall exposure check ignores fail2ban reject/drop rich rules.

## 1.2.0 — 2026-10-18

- **Renamed `proxy` → `megamesh`** (nod to megastack.sh). Repository is now `paulfxyz/megamesh` (GitHub redirects the old URL). Env-var prefix `PROXY_*` → `MEGAMESH_*`; helpers `megamesh-status` / `megamesh-lockdown`; `/etc/megamesh.conf`; default dir `/opt/megamesh`; config file names `00-megamesh-hardening.conf`, `99-megamesh-hardening.conf`, `megamesh-sshd.local`, `modules-load.d/megamesh.conf`; credentials file `/root/megamesh-admin-credentials`. Existing installs: re-run `install.sh` from the new checkout; it writes the new file names (remove the old `*proxy*` drop-ins by hand or with the snippet in docs/TROUBLESHOOTING.md).
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

- `install.sh`: idempotent, non-interactive installer — swap guard, packages, kernel modules, sysctl, key-only SSH with lock-out guard, fail2ban, firewalld three-door policy, Docker daemon fix, wg-easy v15 + Caddy stack, hostname, unattended security updates, self-check.
- `PROMPT.md`: the agent prompt with the known traps baked in.
- `config/`: the exact files running on the reference server.
- `scripts/status.sh`: one-screen health check.
- `docs/`: DNS and rDNS, hardening phases, troubleshooting, logbook.
