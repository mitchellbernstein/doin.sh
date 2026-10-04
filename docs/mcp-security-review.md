# MCP OAuth security review

Independent source review on October 3, 2026. Scope was incoming task OAuth and outgoing provider OAuth in `cloud/mcp-server.ts` and `cloud/mcp-oauth.ts`, their installed primary SDK implementations, and deployment flags. No build, network-provider consent or runtime security test was run in this review lane. Findings below are source-backed race analyses; their reproduction and fixes belong to the MCP owner.

## Findings

| Priority | Evidence at review | Failure sequence | Required correction | State |
| --- | --- | --- | --- | --- |
| P1 | `cloud/mcp-server.ts:69` checks active D1 grant before awaited entitlement lookup; `:72` reads content without a fresh grant check. | A valid request starts; billing lookup suspends; terminal revokes its grant; lookup resumes; the registered read tool returns document content. This contradicts the documented immediate D1 revocation boundary. | Recheck the grant after awaited entitlement and after the document read before exposing content. Add a real Worker fixture that revokes during entitlement I/O and expects no document disclosure. | Sent to MCP owner. Fix and E2E evidence pending. |
| P1 | `cloud/mcp-server.ts:74` checks grant before awaited document read; `:75` delegates team CAS without the OAuth authorization ID. Personal CAS on the same line already includes an active grant predicate. | A team task tool passes grant check; grant is revoked while its read is pending; the folder CAS still sees valid team membership and writes. Membership/folder access does not imply this external client's continued authorization. | Pass the authorization ID into the folder write helper and repeat active grant, account and selected scope in the mutation SQL. Add a fixture revoking between read and commit and assert unchanged document revision/content. | Folder owner added the optional atomic guard at MCP owner's request. MCP caller wiring and E2E remain pending. |

The helper change is outside this independent review's inspected target. It must receive separate integration verification. No finding is closed merely because its owner accepted it or edited a predicate.

## Guards inspected

- Incoming authorize requires exactly one canonical resource and PKCE S256 at `cloud/mcp-server.ts:23-25`. Token exchange requests also require the canonical resource at `:42-44`; token validation supplies that resource at `:69`. Requested scopes are narrowed to the displayed request and explicit terminal consent at `:54`.
- Incoming grants are account/client-bound in D1 at `cloud/mcp-server.ts:15`. Browser polling uses a random HttpOnly Secure SameSite cookie and expiring request ID at `:18-36`. Approval writes bind the authenticated terminal account and expected client/redirect/scopes at `:54-57`. Folder consent invokes current ACL validation before saving the chosen scope. Actual race verification remains the MCP owner's responsibility.
- Outgoing OAuth state, verifier, tokens and client secrets use AES-GCM with account, connection and URL associated data at `cloud/mcp-oauth.ts:8-15`. Callback state is random, hashed, expiring and tied to the initiating device at `:43-49`. Code replay clears its persisted state/verifier after successful exchange.
- Outgoing authorization and token requests require the configured MCP resource. Authorization enforces the fixed callback, random state and PKCE S256 at `cloud/mcp-oauth.ts:22`; token POST enforces the resource at `:36`. The provider is prevented from forwarding Basic credentials to registration or another URL at `:34-35`.
- Installed `@modelcontextprotocol/client` 2.3.0 checks the saved authorization-server binding on callbacks and performs exact RFC 9207 authorization-response issuer comparison. The adapter persists SDK discovery and issuer-bearing credentials. A missing `iss` is rejected when the provider metadata requires it. No issuer-bypass finding was established from this source review.
- Outgoing metadata/network requests validate public HTTPS URLs, resolve A/AAAA records, deny redirects and use time/response-size bounds at `cloud/mcp-oauth.ts:30-38`. CIMD is enabled in the incoming SDK, which requires Cloudflare's public-fetch flag. `cloud/wrangler.jsonc:6` contains `global_fetch_strictly_public`; therefore this review does not claim an unguarded CIMD fetch vulnerability.
- Outgoing OAuth DELETE currently deletes local encrypted state and changes the connection to anonymous at `cloud/mcp-oauth.ts:41`. It does not call a provider token-revocation endpoint. Describe this accurately as disconnecting doin's stored authorization, with provider-side revocation handled separately when needed. This is a capability boundary, not a demonstrated credential leak.

## Primary references

The current [MCP authorization specification, 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization) defines issuer-response validation, resource indicators, audience validation and bearer handling. The installed client SDK was read to verify those behaviors rather than assuming them from an import. [Cloudflare's public-fetch compatibility flag](https://developers.cloudflare.com/workers/configuration/compatibility-flags/#global-fetch-strictly-public) is the deployment boundary used by its OAuth provider for client-metadata fetches. [D1 transactional batches](https://developers.cloudflare.com/d1/worker-api/d1-database/) explain why an authorization predicate must be repeated in the authoritative mutation, instead of relying on an earlier asynchronous check.

## Source follow-up

Re-read current source after owner edits: post-billing grant validation and post-snapshot read validation are present; the team mutation now passes authorization_id to the atomic folder CAS. The described source gaps are addressed. Findings await the owner's race E2E receipt; this follow-up ran no heavy commands and does not claim runtime closure.
