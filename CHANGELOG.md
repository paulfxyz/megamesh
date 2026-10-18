# Changelog

## 1.0.0 — 2026-10-18

First release, distilled from the reference deployment on `paulfleury.network` (CentOS Stream 9, Hostkey 1 vCPU / 1 GB).

- `install.sh`: idempotent, non-interactive installer — swap guard, packages, kernel modules, sysctl, key-only SSH with lock-out guard, fail2ban, firewalld three-door policy, Docker daemon fix, wg-easy v15 + Caddy stack, hostname, unattended security updates, self-check.
- `PROMPT.md`: the agent prompt with the known traps baked in.
- `config/`: the exact files running on the reference server.
- `scripts/status.sh`: one-screen health check.
- `docs/`: DNS and rDNS, hardening phases, troubleshooting, logbook.
