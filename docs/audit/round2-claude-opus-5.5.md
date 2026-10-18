## Verdict

The 1.1.0 fixes hold. The SSH lock decision is coherent, the firewall runs before sshd, `daemon.json` is merged, the INIT flow is sound, and the anchors resolve. Two real problems remain:

- **New regression:** re-running `install.sh` silently turns off VPN-only mode. The reference server is in that mode right now.
- **False claim:** "daily security updates" is not true on CentOS Stream 9.

The allow-list section is honest but leaves out the IP-reassignment risk. `egress.json` and `LICENSE` were not in the bundle, so I could not check them. The LOGBOOK contradicts itself.

**Grade: B. Publishable as-is: no.** The fixes are about an hour of work.

## Findings

| # | Severity | File:line | Issue | Concrete fix |
|---|---|---|---|---|
| 1 | High | install.sh:313, 350 | `cat > "${PROXY_DIR}/Caddyfile"` always writes the **open** config, then `caddy reload` applies it. This happens even when `PROXY_VPN_ONLY` is unset (the default). Re-running on a locked-down box makes the admin UI public again with no warning. README:68 invites re-runs, and LOGBOOK:69 shows the reference box is locked down. | Before writing, check `grep -q '@vpn remote_ip' Caddyfile`. If it matches, keep the current mode via `proxy-lockdown`, or skip the write. Better: record `PROXY_VPN_ONLY`/`PROXY_REDIRECT_URL` in `/etc/proxy.conf` and re-apply from there. |
| 2 | Medium | install.sh:368; HARDENING.md:59; LOGBOOK.md:55 | `upgrade_type = security`. CentOS Stream repos publish no `updateinfo`/errata metadata, so dnf-automatic in security mode applies nothing. `proxy-status` "Pending security updates" (status.sh:25) will always read 0. The claim "applies security updates daily" is false on the one verified distro. | On CentOS Stream (`ID=centos`), use `upgrade_type = default`. Or document the limitation and drop the claim. |
| 3 | Medium | README.md:110, 112 | "If the address ever changes, the change lands here first" cannot be promised. If the VPS lapses or is migrated, Hostkey hands `151.243.225.214` to someone else before you can commit. That person then inherits every allow-list entry. Also left out: anyone who gets root on the VPS or the wg-easy admin account also gets this egress. | Add: "treat this IP as a convenience signal, never the only control. Pair it with auth. Remove the entry if this file has not been updated in N months or the PTR stops matching." Consider signed commits/tags for `egress.json` changes. |
| 4 | Low | lockdown.sh:77 | `peers=$(docker exec wg-easy wg show wg0 peers 2>/dev/null \| wc -l)` runs under `set -euo pipefail`. If wg-easy is down, the pipeline fails and the script exits 1 **with no message**. install.sh:391 then prints a misleading "not enabled (see message above)". | Use `peers=$( { docker exec … \|\| true; } \| wc -l )`. Add an explicit "wg-easy not running" check. |
| 5 | Low | lockdown.sh:65 | Same pitfall: if `wget` exits non-zero (for example, no certificate yet), `code=$(…)` aborts the script after the Caddyfile was already switched. The exit is non-zero, so the caller reports failure even though the lockdown is live. | Append `\|\| true` inside the substitution. |
| 6 | Low | install.sh:344 | `umask 077` runs inside `{ … }`, which is the current shell, not a subshell. On a fresh install it stays in effect for the rest of the script, so `/etc/proxy.conf` and later files become 0600. Harmless today, but surprising. | Write the file as `( umask 077; printf … > "$cred_file" )`. |
| 7 | Low | install.sh:340 | `openssl` is not in either package list. Minimal Debian images may lack it, and the fresh unattended path would then die. | Add `openssl` to both install lines. Or use `python3 -c 'import secrets…'`. |
| 8 | Low | install.sh:351–356 | If wg-easy never reaches `healthy` within 90 s, `INIT_*` is still scrubbed and the container recreated. Setup may never have run. The later `/setup` warning catches this, but the success line at :358 already printed "created unattended". | Only print success, and only scrub, after `redir` shows `/login`. Otherwise warn and keep the credentials file. |
| 9 | Low | lockdown.sh:73, 43 | The redirect URL is only prefix-checked. Whitespace, `}` or newlines are written straight into the Caddyfile. Validation limits the damage, and only root can run it, but the input can still inject directives. | Reject `[[:space:]{}]` in the URL. |
| 10 | Low | docs/DNS.md:51 | Publishes the Hostkey server ID `69416` next to the IP. That helps social-engineering attempts against provider support. | Replace with "your server". |
| 11 | Info | lockdown.sh:23, 41 | `10.8.0.0/24` is hardcoded and assumed to be wg-easy's CIDR. In v15 the CIDR is editable in the UI, so the two can drift apart. The match is harmless (RFC 1918, rp_filter) but the value may be stale. | Note this in HARDENING. |
| 12 | Info | README.md:108, :161 | `egress.json` and `LICENSE` were not in the bundle, so neither is verified. | Ensure `egress.json` includes an explicit `ipv6: none`/`[]`, a `since`, and matches the table. |

## Nits

- **LOGBOOK.md:52 vs :56**: the end state says `admin UI … → 302 /login`, but also `vpn-only: ENABLED`. The public now sees `302 https://paulfleury.com/`.
- **LOGBOOK.md:42 vs :69**: step 20 says "not enabled — the owner will say when", and step 22 enables it.
- **LOGBOOK.md:68–69**: steps 21–22 sit after "Things that would have been faster to know". Move them into the Timeline.
- **config/Caddyfile**: it is described as "the exact files running on the reference server" (README:122), but the live file is the vpn-only render. Either update it or reword the description.
- **README.md:72**: "fill in four values". The prompt needs six: IP, password, OS, domain, email and public key.
- **docs/DNS.md:17**: "`/setup/1` (first run)" contradicts the unattended default. Mention that in VPN-only mode outsiders get the external redirect.
- **TROUBLESHOOTING.md:15**: "`ss` shows no `docker-proxy`" can no longer serve as a symptom, because userland-proxy is off by design. Use "`nft list ruleset` has no DOCKER DNAT rules".
- **TROUBLESHOOTING.md:41**: `proxy_etc_wireguard` is only correct for `/opt/proxy`. Use `$(basename $PROXY_DIR)_etc_wireguard`, and note that it is `wireguard_…` on the reference server.
- **README.md:98**: the heading says "Whitelisting" but the body says "allow-list". Use "Allow-listing" throughout.
- **README.md:147**: "400 lines" vs 419 actual. Say "~400".
- **README.md:155**: "five things … a sixth" does not match the six traps listed at :74–79. Either recount or reword.
- **install.sh:16**: a curly apostrophe in "Let’s Encrypt", while the rest of the file uses ASCII.

## Top 3 before calling it done

1. **Preserve VPN-only mode across re-runs** (finding 1). Persist the mode in `/etc/proxy.conf` and have install.sh re-apply it instead of overwriting the Caddyfile.
2. **Fix or stop claiming automatic security updates on CentOS Stream** (finding 2).
3. **Harden the allow-list wording and tidy the LOGBOOK.**
   - Add the IP-reassignment and "never the sole control" caveats (finding 3).
   - Confirm `egress.json` matches the README table.
   - Fix the LOGBOOK end state and step order, and sync `config/Caddyfile` with the live server.