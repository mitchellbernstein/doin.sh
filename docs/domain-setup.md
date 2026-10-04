# Domain and Cloudflare setup

## Current state (checked 2026-10-03)

- `doin.sh` is registered at Namecheap. WHOIS reports `clientTransferProhibited`; registrar lock is on. Leave the lock and registrar privacy settings unchanged.
- Namecheap's UI reports Cloudflare custom nameservers saved. Google Public DNS-over-HTTPS confirms delegation to `marjory.ns.cloudflare.com` and `sonny.ns.cloudflare.com`. The local recursive resolver still has stale Namecheap NS data cached.
- The initial pre-migration scan found no records for the apex or `www`, and DNSSEC was unsigned.
- Wrangler OAuth is available for `mitch@studioyeehaw.com`, with Pages write permission and zone read permission. It does not currently have zone write permission.
- A Free Cloudflare full zone now exists (`ea73c922ce139d0bdbac3c0d5c8945ec`) and the Cloudflare API reports `active`.
- Cloudflare assigned `marjory.ns.cloudflare.com` and `sonny.ns.cloudflare.com` to this zone. These exact nameservers are saved at Namecheap.
- The zone is Free and active. The apex and `www` have proxied CNAME records targeting `doin-sh.pages.dev`; both resolve to Cloudflare proxy addresses (`104.21.64.177`, `172.67.187.54`). Pages API reports both custom domains active, with verification and HTTP validation active.
- Full (strict) SSL/TLS and Always Use HTTPS are enabled. With `curl --resolve` directed at a Cloudflare edge IP, both HTTP hostnames return `301` to HTTPS, and both HTTPS hostnames return HTTP/2 `200` with certificate validation successful. A local resolver may still return cached Namecheap nameserver data until its prior NS TTL expires.
- DNSSEC is enabled. Google Public DNS-over-HTTPS returns the parent DS `2371 13 2 5DFBB446378DA0667D3509066F62C8AF9747BB1158C4793AC2D0BBC1A70FCC8B` with DNSSEC authenticated data (`AD=true`).
- The account's saved Wrangler OAuth remains zone read-only; Pages writes are available.

## Activation sequence

1. Keep the existing `doin.sh` zone on Cloudflare's Free plan; do not enable paid features.
2. The nameservers are saved and public delegation points to Cloudflare. Keep the registrar lock and privacy settings unchanged.
3. The proxied apex and `www` Pages domains are active and return HTTP/2 200 with valid TLS certificates.
4. Keep the Free plan's default DDoS protection and Free Managed Ruleset enabled. Cloudflare documents both as enabled by default for Free zones; no extra rules or challenge modes are needed for this static site.
5. Full (strict) and **Always Use HTTPS** are enabled; HTTP redirects and HTTPS responses were verified for both hostnames.
6. DNSSEC is enabled and the DS record is published at the parent registry.

## References

- [Cloudflare primary (full) DNS setup](https://developers.cloudflare.com/dns/zone-setups/full-setup/)
- [Cloudflare setup instructions](https://developers.cloudflare.com/dns/zone-setups/full-setup/setup/)
- [Cloudflare troubleshooting when adding a domain](https://developers.cloudflare.com/dns/zone-setups/troubleshooting/cannot-add-domain/)
- [Cloudflare DNSSEC overview](https://developers.cloudflare.com/dns/dnssec/)
- [Cloudflare Always Use HTTPS](https://developers.cloudflare.com/ssl/edge-certificates/additional-options/always-use-https/)
- [Cloudflare Full (strict) mode](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
- [Cloudflare DDoS protections enabled by default](https://developers.cloudflare.com/ddos-protection/get-started/)
- [Cloudflare Free Managed Ruleset](https://developers.cloudflare.com/waf/managed-rules/)
- [Cloudflare Pages custom domains and required CNAME setup](https://developers.cloudflare.com/pages/configuration/custom-domains/)
- [Namecheap changing nameservers](https://www.namecheap.com/support/knowledgebase/article.aspx/767/10/how-to-change-dns-for-a-domain/)
- [Namecheap DNSSEC for custom nameservers](https://www.namecheap.com/support/knowledgebase/article.aspx/9722/2232/managing-dnssec-for-domains-pointed-to-custom-dns/)
