# DNS, reverse DNS and the nameserver question

## The one record you need

| Type | Host | Value | TTL |
|---|---|---|---|
| A | `@` (or `vpn` if you use a subdomain) | your server's IPv4 | Automatic |

Remove whatever the registrar parked there — typically a `CNAME www → parkingpage.<registrar>` and a `URL Redirect @`. They are harmless but confusing, and a stray redirect on `@` can shadow the A record in some panels.

No `www`, no `AAAA` unless the server really has routed IPv6, no port-80 anything. Caddy obtains the certificate with the TLS-ALPN-01 challenge over 443 and retries by itself until the record resolves. Propagation to the big public resolvers took about three minutes on the reference server; the certificate followed within a minute.

Verify from your laptop:

```sh
dig +short A vpn.example.com @1.1.1.1
curl -sI https://vpn.example.com/ | head -3      # expect: HTTP/2 302 … location: /login (or your redirect URL in VPN-only mode)
```

## Reverse DNS (PTR)

Set it in your hosting provider's panel, not at the registrar — the provider owns the IP block. Hostkey: *My servers → server → Network / rDNS*; Hetzner: *Server → Networking → Reverse DNS*; OVH: *IP → Edit reverse*. Value: the same FQDN as the A record.

Forward-confirmed reverse DNS only "works" when both directions agree, so do the A record first.

## Should you run `ns1`/`ns2.yourdomain` on this box?

No, and this project will not help you do it. Reasons:

- A VPN server whose whole point is "nothing but WireGuard is exposed" would have to open udp/53 and tcp/53 to the world.
- Authoritative DNS needs at least two nameservers on different networks; one 1-vCPU VPS is neither.
- If the VPS is down, your domain is dark too — including the records you need to reach the VPS.
- Glue records at the registrar, zone transfers, DNSSEC signing: real work for zero gain here.

Use the registrar's DNS (Namecheap BasicDNS is fine) or a free anycast provider in DNS-only mode (Cloudflare "grey cloud" — WireGuard is UDP and cannot go through their proxy anyway). You get redundancy for free and the VPN box stays single-purpose.

## What was done on the reference server (2026-10-18)

Namecheap Advanced DNS for `paulfleury.network`, changed from Perplexity Computer driving the owner's own browser:

1. Removed `URL Redirect Record @ → http://www.paulfleury.network/` (Unmasked).
2. Removed `CNAME www → parkingpage.namecheap.com.`
3. Added `A @ → 151.243.225.214`, TTL Automatic.

Result: `dig A paulfleury.network @1.1.1.1` → `151.243.225.214` after ~3 minutes; Caddy logged `certificate obtained successfully` right after. The owner completed the wizard the same hour; the UI now answers `302 /login`.

### Setting the PTR at Hostkey

Hostkey exposes reverse DNS per IP in the client area ([invapi.hostkey.com](https://invapi.hostkey.com/)):

1. *My servers* → open your server → the **Network** tab.
2. Click **IP settings and DNS PTR management** (rightmost button on the IP row), enter `paulfleury.network` in the PTR box, click **Update PTR**.
3. Save; propagation is typically minutes to an hour. Verify with `dig -x 151.243.225.214 +short` → `paulfleury.network.`

Hostkey's own nameserver (`dig -x <ip> @ns1.hostkey.com`) answers immediately; public resolvers follow within the hour. Only the owner of the IP block (the hosting provider) can publish PTR records; nothing at Namecheap can do it. Done on the reference server on 2026-10-18.
