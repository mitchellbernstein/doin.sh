# Commercial use and self-hosting terms

Status: terms acceptance, test-mode seat billing and signed-receipt flows are locally implemented. Production team schema is not deployed: remote D1 migrations 0005–0009 are pending and local source adds `0010.sql`. Stripe remains in test mode. Real Stripe sandbox checkout, hosted Checkout and 3DS acceptance are unverified; no live commercial purchase or production license has been issued. The repository LICENSE permits personal self-hosting and requires a paid commercial license for company/team self-hosting or team features. Existing payments grant no new commercial rights.

## Confirmed policy

| Use | Deployment | Required permission |
| --- | --- | --- |
| Individual personal, noncommercial use | Local app or personally self-hosted service | Free Personal Use License. |
| Company, organization or team use, including internal-only use | Local app or self-hosted service | Paid commercial license from Studio Yeehaw LLC. |
| Team features | Self-hosted or doin-operated service | Paid commercial license/team entitlement. |
| Personal sync and hosted integrations | doin-operated service | Optional personal doinMORE subscription; no implied business-use grant. |
| Selling copies, modifications, white-label deployments or third-party hosted access | Any deployment | The current terms grant no redistribution or resale right. |

The intended large-team offer is $99 USD per user per year, annual only. The initial implementation uses the same price for small and large teams and permits self-hosting within the commercial grant; no separate self-host-only price is configured. Paid teams can choose their own hosting. That permission does not promise a managed deployment, infrastructure costs, uptime commitment or enterprise certification.

## License boundary and remaining delivery gates

The root implementation added personal self-hosting permission in LICENSE Section 2 and the paid company/team requirement plus commercial self-hosting/resale boundary in Section 3. Section 4 preserves separate hosted-service terms and no implied commercial redistribution rights. Earlier MIT permissions and third-party licenses remain excluded from the new restrictions.

The canonical local terms are returned by `GET /v1/teams/terms`; checkout records the accepted terms version and legal entity. Production sale still requires legal review and publication of the terms, a live Stripe catalog and keys, deployed team schema and Worker, and end-to-end checks of the live configuration. A personal doinMORE payment does not buy commercial rights. Keep doinWITH described as test-only until those gates pass. Sandbox receipts are test evidence only and grant no production rights.

## Separate commercial agreement must define

- Licensed legal entity, permitted internal users/contractors, purchased seats, term and renewal; whether affiliates can use the same grant.
- Internal execution, copying, modification and self-hosting permission; no resale, paid redistribution, white-label product or third-party service rights under the standard offer.
- Named or concurrent seat accounting and reassignment rules; pricing, proration, taxes, cancellation/refund terms and what hosted services are included.
- Expiry and an explicit data-export transition: organizational use does not become free on lapse, but licensing must not delete task data or imply remote erasure of downloaded copies.
- Self-hosted license receipt issuance and offline verification/renewal policy; responsibility for infrastructure, provider costs and integration credentials; any support commitment only if actually sold.

Do not put signing secrets, Stripe secrets or user task contents in license receipts or public artifacts. A signed receipt can demonstrate an issued entitlement; it cannot by itself stop someone modifying source or guarantee usage counts. Contract scope and any runtime verification should be described honestly. The current implementation verifies a receipt through its annual expiry and requires a renewed signed receipt for the next term.

## Locally implemented terms and receipt flow

`GET /v1/teams/terms` returns the canonical `doin-commercial-1.0` text and annual seat price from `cloud/license.ts`. Team creation records legal entity, accepted terms version, accepting account and timestamp. Checkout requires that exact version again. Verified active annual payment permits the owner to export an Ed25519-signed receipt containing issuer, key ID, entity, team, paid seats, expiry, terms version and billing environment. Public-key trust comes from deployment configuration, never from the receipt. Sandbox receipts fail live verification. No private signing or payment key is included in exported receipts. The Worker signing secret exists in the configured secret store, but its cryptographic match to the configured public key has not been verified for production.

The grant covers internal execution, copying, modification and self-hosting for licensed users during the paid term; permits no resale or third-party paid service rights; preserves third-party and earlier MIT grants; and states seat reassignment, explicit prorated additions, no automatic midterm refunds, expiry and customer infrastructure responsibility. No certification or uptime promise is made. Native `/team create` displays these terms and asks explicit entity acceptance; `/team subscribe <seats>` displays the annual total and requires confirmation before opening Stripe. The focused local acceptance command is `cd cloud && node tests/team-e2e.mjs`; it writes `cloud/artifacts/team-e2e/report.json`. Report only the result present in the generated artifact.

Production readiness requires the live catalog, webhook configuration, remote D1 migrations 0005–0009 plus local migration `0010.sql`, Worker deployment, published terms and verified signing-key consistency. Real Stripe sandbox checkout, hosted Checkout and 3DS are not verified. Do not apply migrations or deploy as part of this documentation change.

## Commercial self-host configuration

Set `SELF_HOST_MODE="commercial"`, `SELF_HOST_OWNER_EMAIL` to the verified email allowed to bootstrap the organization, `COMMERCIAL_LICENSE_RECEIPT` to the paid receipt, and `LICENSE_PUBLIC_KEY`/`LICENSE_KEY_ID` to the separately trusted Studio Yeehaw public verification key and its ID. Self-hosted operators receive no official Stripe key or license-signing private key. `SELF_HOST_MODE="personal"` rejects all team features and requires the configured personal owner for personal hosted-service access.

A commercial deployment accepts only a live receipt with a valid signature, current term, entity, fixed team ID and seat count. The bootstrap owner must use the configured email and exactly the receipt's entity; a different account cannot capture the organization. Other verified accounts join only through scoped invitations and available licensed seats. The local team ID comes from the receipt, not a caller-chosen new tenant. Stripe checkout, seat purchases and subscription changes remain on the official service; renewing or increasing a self-host license means supplying a newly issued receipt. Team data need not be sent to the official service for verification.

Expired or invalid receipts deny shared writes and hosted integration/tool access. Existing membership and folder permissions continue to control read/export for data recovery; this does not grant renewed commercial execution or active team-feature rights. Export never overrides a revoked membership or folder grant. Offline receipts cannot guarantee immediate revocation, and source/configuration can be modified by the operator; the commercial agreement still controls permitted use. No technical DRM guarantee is claimed.
