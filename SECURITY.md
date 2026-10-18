# Security policy

Megamesh is a small shell script that hardens a VPS and runs WireGuard behind a firewall. If it has a hole, people who trusted it have a hole too. Please tell us.

## Reporting a vulnerability

- **Preferred:** open a private report through [GitHub security advisories](https://github.com/paulfxyz/megamesh/security/advisories/new). Only the maintainer sees it until a fix is out.
- **Email:** [hi@megastack.sh](mailto:hi@megastack.sh). Put `megamesh` in the subject.
- Please do not open a public issue for anything exploitable. For hardening suggestions, typos in the firewall rules, or "this default is weaker than it should be", a normal [issue](https://github.com/paulfxyz/megamesh/issues) is fine.

What helps: the OS and version you tested on (`cat /etc/os-release`), the Megamesh version (`grep MEGAMESH_VERSION megamesh.sh`), what you did, what you saw, what you expected. A proof of concept is welcome; a working exploit against someone else's server is not.

## What you can expect

- An acknowledgement within 72 hours.
- A fix or a documented mitigation in the next release, usually within two weeks for anything that weakens the firewall, SSH, TLS or WireGuard posture.
- Credit in [CHANGELOG.md](CHANGELOG.md) and the release notes, unless you prefer to stay anonymous.

There is no bug bounty. This is a free, MIT-licensed tool maintained by one person.

## Scope

In scope:

- `megamesh.sh`, `install.sh` and everything under `scripts/` and `config/`.
- The web deployer at [megamesh.sh/deploy](https://megamesh.sh/deploy/) (`site/deploy/`, `site/api/`): credential handling, the SSH session it opens on your behalf, what it logs, what it keeps (nothing, by design — if you can show it keeps something, that is a bug).
- The website itself when it affects users (XSS, content injection, insecure headers).

Out of scope:

- WireGuard, wg-easy, Caddy, Docker, firewalld, fail2ban, topgrade and the host OS. Report those upstream; if Megamesh ships an insecure *configuration* of them, that is in scope.
- Attacks that need root on the server already.
- The reference servers `paulfleury.network` and `vpn.paulfleury.eu`. They are personal machines, not a playground; the published egress IP in [egress.json](egress.json) is there so you can verify what is and is not ours, not as an invitation.

## Supported versions

Only the latest release is supported. The installer upgrades in place and rolls back on failure; there is no reason to stay on an older one.

## Hardening claims

Every claim in the README about ports, SSH, TLS and the firewall is checked by the audits in [docs/AUDIT.md](docs/AUDIT.md). If you find a claim that is not true on a fresh install of a supported OS, that counts as a vulnerability report too.
