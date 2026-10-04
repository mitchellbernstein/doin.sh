# Hosted MCP integrations

Implementation checkpoint: hosted integration client implemented and fixture-only E2E verified. The hosted Worker is deployed with migration 0004 and an encrypted integration key; curl health and unauthenticated access checks passed. Public v0.2.4 is published and the native client is installed. Hosted integration access requires doinMORE. Local MCP remains free. No user integration has been connected.

## Shape under review

Selected: request-scoped `@modelcontextprotocol/client` 2.3.0 Streamable HTTP client in the existing Worker, encrypted per-account D1 connection registry, and explicit terminal tool invocation. Each request authenticates the existing device session. Registry discovery, registration, tools, and calls check live Stripe entitlement before access or outbound traffic. Owned connection deletion remains available without paid entitlement or working Stripe billing, so users can always erase stored integration credentials. Sessions initialize, discover tools, perform one explicit call if requested, terminate, and close within that request. Remote tool calls refuse schemas containing provider-defined regular expressions or external references, and limit schema traversal to 512 nodes and 20 levels to avoid executing untrusted regexes in the Worker. Discovery can still display these tools. Tool results remain untrusted data; they do not execute further tools or mutate doin tasks automatically.

Alternative: a per-account Cloudflare Agents Durable Object retaining MCP transport and OAuth state. It supports persistent sessions and provider OAuth but adds storage migrations, durable runtime state, and encryption customization. The request-scoped approach avoids those costs for manual calls.

Proposed terminal REST contract:

- `GET /v1/mcp/connections`: account-owned connection metadata only.
- `POST /v1/mcp/connections`: `{name, url, token?}`; optional integration-specific Bearer credential, never the doin device token.
- `DELETE /v1/mcp/connections/:name`: revoke that account's stored connection.
- `GET /v1/mcp/connections/:name/tools`: initialize and discover bounded tools.
- `POST /v1/mcp/connections/:name/call`: `{tool, arguments, confirmation:true}`; explicit invocation only.

Connections store configuration without silently invoking a provider tool; discovery and calls initialize a fresh bounded session. OAuth-only providers need a future consent adapter; this version supports unauthenticated endpoints and manually supplied integration-specific Bearer credentials only. Registration credentials never appear in registry lists.

Allowed endpoints are HTTPS on port 443, public DNS hostnames, no credentials/query/fragment in the URL, no IP literals, local/metadata names, or own doin zone. Every SDK fetch checks exact registered endpoint and public A/AAAA resolution; redirects are rejected. DNS validation is defense in depth, not socket resolution pinning. The deployment relies additionally on Workers' documented public-Internet-only outbound proxy and must not add private network bindings.

Hosted requests share a 15-second deadline beginning before entitlement lookup. Each provider fetch has an 8-second maximum; responses allow at most 512 KiB, discovery 128 tools over 8 pages with a 512 KiB aggregate catalog, and each account 20 connections. `tools/call` POSTs are not automatically retried. SSE results are processed without waiting for a persistent response stream to close. Revocation denies subsequent provider operations; best-effort DELETE of an already owned remote session may still run solely to release that session. A call already dispatched to a third party cannot be undone by revocation. This release bounds the whole operation to 15 seconds but does not propagate terminal/client disconnect to the hosted provider: an explicitly confirmed call may complete after the terminal disconnects. A lost response does not prove that a mutating call failed, so retrying manually may duplicate a provider action.

Credentials use AES-GCM with fresh IVs and account/name/URL authenticated associated data. The 256-bit key is a Worker secret outside source and downloads. Registry reads never reveal credentials; remote errors are normalized rather than echoing authorization headers or raw network errors.

A remote task MCP server requires scoped OAuth consent, PKCE, token audience binding, registration, and grant revocation. It is distinct from the terminal REST integration client. A device-token gateway is not a substitute.

## Failure census (before implementation)

1. Signed-out, revoked, expired, cross-account, closing/deleted account requests; owner isolation on matching connection names; no outbound calls before entitlement.
2. Unpaid, expired paid period, canceled immediately, canceled at period end, wrong Stripe price, billing provider outage; fail closed without hiding public local features.
3. Private/reserved DNS, mixed public/private answers, IP spellings, IPv6 mapped addresses, localhost/metadata/trailing-dot domains, own zone, alternate ports, URL credentials/query/fragment; DNS outage/oversized replies; DNS check cannot alone eliminate rebinding.
4. Redirects, credential forwarding to another endpoint, integration credential reused as account token, malformed/oversized tokens, absent/wrong encryption key, tampered ciphertext, copied ciphertext between accounts/names/URLs; no plaintext D1 or API leaks.
5. Duplicate registration and account connection quotas, remove/revoke concurrent with call, database failure, deleted account foreign-key cleanup; failed discovery should not create an unusable credential-bearing registration silently.
6. MCP initialization/version/capability failure, missing initialized notification, lost session, JSON and SSE response paths, unexpected pushed requests/elicitation, paginated tool loops/catalog bounds, malformed JSON, wrong response ID, huge response/stream, invalid schema, remote authentication denial, disconnect/offline/timeout.
7. Missing explicit call confirmation, unknown tool, non-object or oversized arguments, malicious tool descriptions/output, ANSI/control output, remote method errors, tool-result isError; no automatic execution or retry of potentially mutating calls.
8. Session termination, pending GET stream cancellation, cleanup on every failure, response and total operation deadlines; no task-owned process orphan.

E2E evidence will use the real bundled Worker, Miniflare D1, outbound provider fixtures, two distinct paid accounts, a third unpaid account, an SSE/JSON remote MCP fixture with real lifecycle checks, and saved JSON transcript/results. No live email, real payment, user data, or actual integration credential is needed.

## Primary documentation consulted

- [Cloudflare MCP client API](https://developers.cloudflare.com/agents/model-context-protocol/apis/client-api/) (current v0.20.0 uses split SDK packages; reviewed October 3, 2026).
- [Cloudflare MCP handler API](https://developers.cloudflare.com/agents/model-context-protocol/apis/handler-api/).
- [Official TypeScript MCP SDK client transport](https://github.com/modelcontextprotocol/typescript-sdk/blob/main/packages/client/src/client/streamableHttp.ts).
- [MCP 2025-11-25 transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization), and [security guidance](https://modelcontextprotocol.io/docs/2025-11-25/tutorials/security/security_best_practices).
- [Workers security model](https://developers.cloudflare.com/workers/reference/security-model/) and [fetch limitations](https://developers.cloudflare.com/workers/platform/known-issues/).

Deployment requires migration `0004.sql` and a 64-lowercase-hex-character `MCP_ENCRYPTION_KEY` Worker secret for authenticated integrations. Anonymous connections do not need that secret. Do not rotate or remove the key while retaining encrypted rows; existing credentials must be removed and re-added for intentional rotation. The key never enters the public repo or native download.

Reproduce the fixture-only E2E: `cd cloud && node tests/mcp-e2e.mjs`. Evidence is written to `artifacts/mcp/cloud-e2e.json`. No network listener is started; Miniflare is always disposed.

Verification: `npm test` passed eight existing account/sync/billing groups followed by six hosted MCP E2E groups. The hosted evidence includes JSON, finite SSE, and an SSE stream deliberately left open after its result, credential encryption and account-bound associated data, malformed/oversized responses, repeat-cursor pagination, regex-schema rejection, revocation between discovery and invocation, unpaid/provider-down credential removal, and account-delete cascade. The final artifact reports zero remaining owned remote sessions. Workspace process audit reports zero orphan candidates.

Workers runtime evidence selected `redirect: manual` with explicit refusal of all 3xx responses. [Cloudflare Request documentation](https://developers.cloudflare.com/workers/runtime-apis/request/) specifically recommends manual handling to prevent forwarding sensitive headers on redirects. The current local workerd runtime rejects `redirect: error` even though the constructor reference lists it.

## OAuth extension failure census — before code

The owner now authorizes provider consent and a remote synced-task MCP endpoint. The extension is in progress; the v0.2.4 limits above describe the released baseline until verification/deployment completes.

1. Provider discovery must reject private DNS, redirects, malicious metadata URLs, issuer mismatch, missing PKCE, substituted resource/audience, insecure authorization/token/registration URLs, and cross-provider credentials. Every network fetch is public and bounded; the browser authorization URL is validated before return.
2. Provider consent state is random, account/connection/device-bound, expires in ten minutes, survives redirects encrypted, and is claimed under a lease. Wrong/replayed/expired state, wrong issuer, provider denial, deleted/revoked connection/device, canceled/expired paid access and billing outage fail closed. Tokens/client secrets/verifiers stay encrypted and never appear in registry/CLI output.
3. Concurrent consent/refresh, provider refresh rotation, lost responses, missing/tampered encryption keys, invalid token type/expiration, storage failures, external revocation and OAuth-only providers must not duplicate a mutating MCP call or silently open a consent browser. Failed renewal asks for explicit reconnection.
4. Incoming MCP uses separate OAuth access tokens and a canonical resource URI, never the terminal device session. Test DCR/CIMD validation, exact redirects, PKCE S256, missing/changed resource, invalid scope, stolen/replayed code, audience mismatch, expired/rotated/revoked tokens, and malformed/oversized protocol requests.
5. Remote authorization needs explicit authenticated terminal consent for the displayed client, redirect and requested scopes. Browser polling is bound to an HttpOnly SameSite cookie and short-lived request nonce. Cross-account approval/review confusion, request substitution, unsupported scope escalation, CSRF/browser origin, client metadata HTML injection, denial and abandoned requests are covered.
6. Every remote task operation checks the account's current hosted entitlement and active grant. Read-only grants cannot write; revoked grants and account deletion are denied immediately in D1 even if KV revocation propagates later. Account cleanup erases grants and encrypted provider state.
7. Markdown scenarios include Unicode, fenced checkbox examples, custom statuses/reminder markers, CRLF, unclosed fences, invalid task numbers and stale revisions. Writes use the synced document's CAS revision and preserve unrelated Markdown. Two concurrent writers cannot both win. Remote writes update the cloud document only; local push/pull remains explicit.
8. Real official SDK client/server + Cloudflare OAuth provider run against isolated Miniflare D1/KV with fixture-only discovery, registration, token, refresh and MCP traffic. Save protocol/consent outcomes and cleanup artifacts. Do not connect an actual provider or send user data as part of development evidence.

Primary sources for this extension: [Cloudflare OAuth provider 1.2.1](https://github.com/cloudflare/workers-oauth-provider), its [authorization-server reference](https://github.com/cloudflare/workers-oauth-provider/blob/main/docs/authorization-server.md), [consent guidance](https://github.com/cloudflare/workers-oauth-provider/blob/main/docs/consent-page.md), [official SDK HTTP serving](https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/serving/http.md), and [MCP 2025-11-25 authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization).

### OAuth surfaces being verified

The provider client uses SDK 2.3.0 OAuth discovery, CIMD/DCR, S256 PKCE and issuer/resource checks. `POST /v1/mcp/connections/NAME/oauth` returns a browser authorization URL; optional pre-registered `client_id`/`client_secret` and `scope` are accepted. Provider secrets, refresh tokens and PKCE verifiers are AES-GCM encrypted in D1 with account/connection/resource associated data. No tool invocation automatically opens consent or retries after authentication failure. `DELETE` on the same path revokes the stored credential even after payment expiry. It removes the local credential; it cannot promise revocation at an external provider that offers no revocation endpoint.

The incoming synced-task endpoint is `https://sync.doin.sh/mcp`. Its OAuth server publishes RFC 8414 and protected-resource metadata, accepts public DCR/CIMD clients, requires S256 PKCE and the exact resource indicator, and uses separate short-lived OAuth tokens. The Cloudflare library hashes token/code/client-secret storage and encrypts grant props in `OAUTH_KV`. The `global_fetch_strictly_public` Worker compatibility flag is required for safe CIMD fetches. Migration `0006.sql`, the existing encryption key and a dedicated KV binding are required before deployment.

Consent stays in the terminal. The browser displays a random ten-minute request ID and client/redirect/scopes, then waits. `GET /v1/mcp/grants/requests/ID` reviews it. `POST /v1/mcp/grants/approve` requires the exact reviewed client ID, redirect URI, selected requested scopes and `confirmation:true`. The terminal may explicitly select a personal `folder_id`, or a `team_id` and `folder_id`; this limits the resulting grant to exactly that folder, without sibling or descendant access. Deleted personal folders invalidate their grants. Approval requires the corresponding personal or team entitlement and current folder access. Browser polling is bound to a Secure HttpOnly SameSite cookie. Denial and owned grant deletion remain available without payment.

Remote tools expose read/list/add/complete/status/reminder operations on the selected synced Markdown snapshot. Writes require a SHA-256 document revision and explicit confirmation; D1 CAS rejects stale changes. Read-only scopes cannot invoke changes. Team folder reads/writes recheck current inherited ACLs and membership; a removed member loses access. Reminder timestamps on the remote endpoint require ISO 8601 with a timezone, or `off`. Local files update through normal explicit sync, not direct remote filesystem access.

Every request checks live hosted entitlement and an unrevoked D1 grant, including during token exchange/refresh. D1 revocation closes the KV propagation window. A request already dispatched to a provider can still finish if the terminal disconnects; requests are bounded to fifteen seconds. No real provider connection or user data transfer is part of the fixture verification.

Reproduce the OAuth fixture with `cd cloud && node tests/mcp-oauth-e2e.mjs`; it saves `artifacts/mcp/oauth-e2e.json` and disposes its isolated D1/KV runtime. Deployment and terminal command completion are coordinated by the release owner; this section does not claim that unverified changes are live.

Terminal commands for this extension:

```sh
doin mcp cloud oauth work
# Optional pre-registered client; secret is read from an environment variable.
doin mcp cloud oauth work --scope read --client-id CLIENT --client-secret-env PROVIDER_SECRET
doin mcp cloud oauth-revoke work
doin mcp cloud grants list
doin mcp cloud grants review REQUEST_ID
doin mcp cloud grants review REQUEST_ID --folder PERSONAL_FOLDER_ID
doin mcp cloud grants review REQUEST_ID --team TEAM_ID --folder FOLDER_ID
doin mcp cloud grants revoke GRANT_ID
```

Review displays the client identity, verified CIMD domain when available, exact redirect, requested scopes and personal/folder target. It asks for `approve`, `deny` or `cancel`; approval then requires typing the scopes to grant. Permissions cannot exceed the reviewed request. Provider consent opens a validated public HTTPS browser URL; new client credentials are read through an environment variable and private request storage, never command arguments. CLI E2E evidence is reproduced with `python3 tests/mcp_oauth_cli_e2e.py --bin zig-out/bin/doin` and saved to `artifacts/mcp-oauth-cli/results.json`.

OAuth verification completed locally: nine E2E groups passed against real pinned SDK client/server, Cloudflare OAuth provider and isolated D1/KV. Evidence includes provider refresh before dispatch, incoming refresh rotation, terminal consent/cookie/PKCE, read-only denial, paid expiry with free credential cleanup, account isolation, folder-only personal/team writes, sibling and foreign-folder rejection, immutable folder scope across refresh, and tombstone/member/ACL revocation. The artifact explicitly records both regression races: revocation during the entitlement await returned 401 without a snapshot; revocation between a team folder snapshot and CAS returned an error with unchanged content. The full six-suite cloud gate also passed: eight account/billing/sync, six hosted MCP, nine OAuth, eight team/commercial, five team-folder and eight personal-folder groups. OAuth evidence also covers a paid-team-only account using a private outbound integration without a personal plan, foreign-team denial, offboarding/expiry cleanup, and actual HTTPS CIMD client discovery with verified domain and PKCE exchange. Native OAuth CLI validation and production deployment remain release-owner steps.

### Account-owned integrations using a team license: failure census

Before implementation: test a team member with no personal subscription explicitly creating an integration under a paid team; prevent foreign/nonmember team selection, silent conversion of existing personal connections, and credential visibility from another member/account. Reconcile the selected team's live entitlement for registration, discovery, invocation, consent and callbacks. Offboarding, team expiry/deletion, account closing and provider outages must block use/refresh while owned credential removal remains available. Preserve personal-plan connections and all account quotas. Migration `0009.sql` stores only the selected license team; it does not share the connection or credential.

An account can explicitly use its paid team license for a private outbound integration:

```sh
doin mcp cloud add work https://provider.example.com/mcp --team TEAM_ID
doin mcp cloud list --team TEAM_ID
doin mcp cloud oauth work
```

The license team is fixed when the connection is created. An existing personal connection keeps its personal entitlement; changing context requires explicit removal and recreation. The selected team does not gain access to the account's connection or secret, and another team member cannot discover or invoke it. Team entitlement and current membership gate discovery, calls, consent and token renewal; offboarding or expiry stops use. Owned removal stays available. No second personal doinMORE subscription is required for a team-licensed connection.

Agent guidance failure census: instructions could reveal another folder, suggest that Markdown grants permissions, promote malicious document text into server instructions, omit read-only restrictions, or describe a stale revision. The existing scoped OAuth E2E now checks protocol instructions and revision-bound team/personal guidance alongside sibling isolation and revocation races. Guidance remains advisory; it does not replace live authorization.

MCP initialize instructions provide static advisory workflow guidance. `doin_read` returns guidance with the exact granted folder, approved scopes and the returned SHA256 revision. No document or AGENTS.md text is promoted into protocol instructions; root/nearest AGENTS.md discovery needs separately authorized filesystem access. Live server entitlement, membership, folder ACL and grant checks remain authoritative. This uses the optional `instructions` field in the [MCP 2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle).
