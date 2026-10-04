# Optional paid sync

Personal local use stays free and works without an account; company/team use requires a commercial license. The optional hosted service is designed for $4.99 USD per month or $49.99 USD per year sync between computers. AI provider credentials and sync accounts are separate. The native client supports explicit sync commands and optional per-device background checks.

Accounts use email verification. Account status, devices, export, subscription management and deletion belong in the terminal. The browser only confirms the emailed link or accepts payment through Stripe. There is no GitHub account requirement and no web account portal.

Verification pages use `Referrer-Policy: strict-origin`: native form submissions retain the real Origin for the exact-origin guard, while Referer contains no email-token path/query. `no-referrer` turns native form Origin into `null` under the [Fetch Standard](https://fetch.spec.whatwg.org/#append-a-request-origin-header); [strict-origin](https://www.w3.org/TR/referrer-policy/#referrer-policy-strict-origin) sends only the origin and suppresses HTTPS downgrade referrers. Null and foreign origins remain rejected.

Public `GET /v1/plan` returns `{name:"doinMORE",amount:499,currency:"usd",interval:"month",options:[{interval:"month",amount:499},{interval:"year",amount:4999}],billing_mode:"test"|"live"|"unavailable",email_ready:boolean,billing_ready:boolean}` before sign-in. Readiness reports configured prerequisites, not provider uptime or verified permissions. Billing mode requires a configured price and a known server-key prefix; unknown, missing or placeholder configuration is unavailable. [Stripe documents test/live key prefixes](https://docs.stripe.com/keys). This endpoint reads no database, calls no provider and exposes no keys or provider IDs. The upgrade screen must label test mode as sandbox; Checkout independently verifies the actual active price is USD 4.99 monthly or USD 49.99 yearly before issuing a payment URL.

The service is not ready to accept live payments until production credentials and live verification are complete. The current configured price is a Stripe test-mode price. Tests send no real emails and charge no cards.

## Shape and ownership

| Object | Stored data |
| --- | --- |
| Account | Random account ID, verified email, display name, Stripe customer ID and optional closing state. |
| Login request | Email, device name, S256 proof challenge, email-link token hash, confirmation-code hash, ten-minute expiry and claim receipt. |
| Device session | SHA-256 bearer-token hash, account ID, device name and 90-day expiry. |
| Document revision | Account ID, whole Markdown document, increasing revision and update time. |
| Subscription | Informational current active/inactive snapshot. Access always checks current Stripe subscriptions. |
| Checkout | One open session per account, persisted idempotency key, Stripe session ID and provider-enforced expiry. |

Workers plus D1 gives one deployment and one database. A conditional SQL update protects whole-file revisions. Durable Objects would add another persistence system; introduce them only if live collaborative editing becomes a requirement.

Model the Domain puts account, proof and revision ownership into tables. Boundary Discipline validates network data before writes. Make Operations Idempotent preserves the same claim and checkout through retries. Laziness Protocol keeps the native local client independent and the server framework-free. Test Behavior, Not Implementation and Prove It Works require HTTP scenarios against workerd and actual D1.

## Email sign-in

The terminal generates a random verifier with at least 256 bits of entropy. It sends the RFC 7636 S256 challenge and device name with the email address. The response contains a request ID and six-digit confirmation code. The code remains in the terminal. The email contains an independent random verification link, not the code or device token.

Opening the link only displays a confirmation form. GET never approves or consumes it, so email scanners cannot sign a user in. The form requires the six-digit terminal code and an exact same-origin POST. Five attempts lock that request. The page identifies the requesting device and tells users to ignore an unsolicited request. Login links expire after ten minutes. Starts allow three requests per email and thirty per IP per hour. Responses do not reveal whether the email already has an account. Delivery errors do not claim that a message was sent.

The terminal polls with its original verifier. A stolen request ID or emailed link cannot claim the account without that proof. Approval and device-session issuance are separate. The device bearer is SHA-256 of a domain-separated original verifier; the server stores only its hash. A D1 batch creates the account, document and session, then commits its claim receipt. A retry after a lost response returns the same bearer while the original ten-minute receipt and session remain valid. Concurrent claims do not mint multiple sessions. Revoking a device prevents its receipt from restoring it.

Devices expire after ninety days. Every account and billing endpoint requires a device bearer. Tokens never belong in URLs, Markdown, model requests or command-line arguments. The native client stores them in an owner-only credential file separate from AI credentials. Server responses use no-store, no-referrer and a restrictive content security policy. The emailed verification token appears in the verification URL; request URLs must not be recorded in application logs.

## Terminal API

The service origin is `https://sync.doin.sh`. Auth requests use JSON. Other calls require `Authorization: Bearer TOKEN`.

| Request | Contract |
| --- | --- |
| `POST /v1/auth/start` | `{email,name,code_challenge}`. Returns `{request_id,confirmation_code,expires_in:600,interval:2}`. The S256 challenge uses unpadded base64url. |
| `POST /v1/auth/poll` | `{request_id,code_verifier}`. Returns HTTP 202 `{status:"pending"}` or HTTP 200 `{token,expires_at,account:{id,email,name}}`. Invalid proof, expiry and revoked receipt return 401. |
| `GET /auth/verify?token=...` | Minimal browser confirmation form. No account session or state change. |
| `POST /auth/verify` | `{token,confirmation_code}` or equivalent form fields. Requires the service origin. The terminal claims the device afterward. |
| `GET /v1/account` | `{id,email,name,deletion_pending}`. |
| `GET /v1/devices` | `{devices:[{id,name,expires_at,current}]}`. Device IDs are token hashes, not usable credentials. |
| `POST /v1/devices/revoke` | `{id}`. Revokes only a device owned by the authenticated account. |
| `POST /v1/logout` | Revokes the current device. |
| `GET /v1/export` | Cloud document and revision, even after subscription cancellation. |
| `GET /v1/billing` | `{active,status,cancel_at_period_end,current_period_end}`. |
| `POST /v1/checkout` | Returns a Stripe-hosted payment URL for the configured monthly price. |
| `POST /v1/billing/cancel` | Stops renewal at the paid period end. Existing paid access remains until then. |
| `POST /v1/billing/resume` | Resumes renewal for the existing active subscription before its cancellation takes effect. |
| `POST /v1/billing/recover` | Returns the owned open invoice's Stripe payment URL for a recoverable failed payment. |
| `DELETE /v1/account` | Requires `{confirmation:"delete my account"}`. Expires open payment sessions, cancels subscriptions immediately, then deletes cloud data and sessions. Local Markdown stays on disk. |

The terminal must ask for the exact deletion phrase before calling DELETE. Deletion starts a persistent closing state. New checkout, cancellation and renewal mutations cannot race it. If Stripe fails, the account and document remain available for export and deletion retry; new subscription creation stays blocked. A per-account billing lease prevents concurrent mutations, and a closing account remains closed even if a lease expires. The server recovers a lost checkout response using its persisted idempotency key, expires all owned open payment sessions, then cancels subscriptions before deleting the Stripe linkage. Uncertain provider state or pagination fails safely rather than deleting early. A provider-expiry edge may require retrying deletion after the existing session expires. Stripe may retain billing records after cloud account deletion.

## Sync and payment boundary

`GET /v1/document` returns `{revision,content,updated_at}`. A new account starts at revision zero with empty content. `PUT /v1/document` accepts `{revision,content}`. One SQL update succeeds only when the supplied revision still matches. Success returns the new revision. Retrying content already saved returns the current revision without adding another.

HTTP 409 returns `{error:"revision_conflict",revision,content,updated_at}`. Preserve both local and cloud content. Ask which version to use or save a conflict file before resolving it. A one-MiB UTF-8 limit bounds the document. No line-based merge is attempted. The client also compares local bytes while holding its existing write lock before applying a downloaded document; an editor may change the file during the request.

HTTP 401 requires sign-in. HTTP 402 requires an active subscription. HTTP 503 requires a later retry. None authorizes deleting or overwriting local Markdown. `billing_busy` returns 409 while another billing operation holds the lease.

Stripe Checkout accepts only `{interval:"month"|"year"}` and defaults to month when omitted. Server allowlists `STRIPE_MONTHLY_PRICE_ID` (USD 499 cents/month) and `STRIPE_YEARLY_PRICE_ID` (USD 4999 cents/year). `STRIPE_PRICE_ID` remains a legacy entitlement ID for existing USD 299-cent subscriptions; existing subscriptions are never repriced. Clients cannot choose amount, customer, account, price or return URL. Stable account-derived keys prevent duplicate customer creation. A persisted checkout key and URL survive retries across clock-hour boundaries. Stripe enforces the same one-hour expiry; changing interval recovers uncertain creation using the persisted original price/key, expires the owned old session before replacement, and checks subscriptions again. Provider failure retains the old state for safe retry. Migration `0003.sql` records selected price; older rows replay using the legacy price. Existing incomplete or past-due subscriptions use payment recovery instead of creating a second billable subscription.

Every sync request fetches current Stripe subscriptions. Access requires this account's customer, the configured price, active status and an unexpired item billing period. Cancellation at period end retains paid access. Canceled, unpaid, past-due and provider failures deny sync. This initial implementation uses one billing read per sync instead of caching entitlement. Cache only after measuring cost and choosing a revocation delay.

Webhooks verify HMAC SHA-256 against the raw body with a five-minute timestamp tolerance. Relevant events reconcile current Stripe state. Snapshot and event receipt commit in one D1 transaction. Event timestamps never decide ordering. Replay receipts prevent repeated writes. The subscription snapshot cannot authorize stale access because sync checks Stripe directly.

Cloud documents are readable by the service operator. HTTPS protects transport. This is not end-to-end encryption. A canceled user can export existing cloud Markdown without paying again.

## Verify locally

```sh
cd cloud
npm ci
npm test
node tests/verify-cas.mjs
```

E2E runs the actual Worker bundle in workerd with real local D1. Mail delivery and Stripe use fixtures. A test-only compiled clock shim tests checkout retries across an hour boundary; it does not ship. The report is `cloud/artifacts/e2e.json`. The failure census in `cloud/tests/FAILURES.md` preceded the authentication rewrite. The CAS check inserts a stale-writer defect only into a temporary bundle and requires the E2E to reject it. Its receipt is `cloud/artifacts/cas-mutation.json`.

`node cloud/tests/cli-fixture.mjs` serves the actual Worker on loopback port 8792 with temporary D1 and a synthetic paid `fixture@example.com` account. The fixture prints fake-email verification URLs so native CLI E2E can perform the real confirmation flow. It sends no emails. Set `DOIN_FIXTURE_PORT` for another free port. Stop that exact process with SIGINT or SIGTERM; it disposes workerd. Never bind this fixture publicly or use real credentials.

## Deployment requirements

1. Cloudflare Workers and D1 write access. D1 database `doin-sync` exists. Apply every migration (currently `0001.sql` through `0009.sql`) with `npx wrangler d1 migrations apply doin-sync --remote`; `0002.sql` preserves IDs and billing/document references while adding email identity and authentication receipts.
2. Cloudflare Email Sending domain onboarding and a restricted sender binding for `login@doin.sh`. Arbitrary recipients require Workers Paid; sending only to account-verified destinations is available free. This account already has Workers Paid according to the owner dashboard check. Domain DNS must show SPF, DKIM, DMARC and bounce records configured. Enable `EMAIL_ENABLED` only after that setup is verified. Local bindings are simulated; never set `remote:true` merely to test because it sends real emails.
3. Stripe test-mode monthly and yearly prices, plus the preserved legacy entitlement price, and encrypted Worker secrets `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`. Minimum restricted runtime-key permissions are Customers write, Checkout Sessions write, Prices read, Subscriptions write and Invoices read. Secrets stay in Worker secret storage, never source or frontend code.
4. Attach `sync.doin.sh` to the Worker and keep `ORIGIN` exactly equal to its HTTPS origin. Deploy using `npx wrangler deploy` after review. Email sign-in has no OAuth app or provider password configuration.
5. The Stripe destination subscribes to `checkout.session.completed` and `customer.subscription.created`, `.updated`, `.deleted`. API requests explicitly pin `2025-03-31.basil` for item billing periods. Webhook handling reads stable event/customer fields and reconciles via those pinned API requests; an older destination event version is supported. Record the actual destination version after setup.
6. Verify real delivery only when the owner explicitly invokes sign-in. Test a sandbox checkout, payment recovery, cancellation/resumption, export, revocation, account deletion and two-device conflict before promoting live Stripe credentials. Live payments also require completed merchant onboarding and public billing, privacy and support policies.

## Primary documentation read

- [D1 prepare and transactional batch](https://developers.cloudflare.com/d1/worker-api/d1-database/).
- [D1 SQL and schema changes](https://developers.cloudflare.com/d1/sql-api/sql-statements/).
- [Workers Web Crypto](https://developers.cloudflare.com/workers/runtime-apis/web-crypto/).
- [Cloudflare Email Service plan availability](https://developers.cloudflare.com/email-service/).
- [Native Email Sending API](https://developers.cloudflare.com/email-service/api/send-emails/workers-api/).
- [Restricted email bindings](https://developers.cloudflare.com/email-service/configuration/send-bindings/).
- [Local email simulation and remote delivery](https://developers.cloudflare.com/email-service/local-development/sending/).
- [Stripe Checkout](https://docs.stripe.com/api/checkout/sessions/create).
- [List owned open payment sessions](https://docs.stripe.com/api/checkout/sessions/list).
- [Signed, duplicated and unordered webhooks](https://docs.stripe.com/webhooks).
- [Subscription cancellation and renewal](https://docs.stripe.com/billing/subscriptions/cancel).
- [Immediate subscription cancellation](https://docs.stripe.com/api/subscriptions/cancel).
- [Hosted invoice payment recovery](https://docs.stripe.com/invoicing/hosted-invoice-page).
- [Basil item billing periods](https://docs.stripe.com/changelog/basil/2025-03-31/deprecate-subscription-current-period-start-and-end).

Background sync failure census (before adapter): enabling absent login; implicit first upload; OS activation failure and rollback; local/cloud both change; stale CAS; ordinary editor ignores lock; lost provider response; expired entitlement/offline; scheduler paths containing Unicode/quotes/%/$; replaced storage config; stopped tick leaves HTTP child; overlapping ticks; disabling leaves a live timer; status falsely claims activation. E2E uses compiled CLI + local HTTP and fake scheduler commands, never installs real user jobs.


## Opt-in background checks

`doin sync auto enable` registers a per-user one-shot OS timer after sign-in; `disable` stops it, `status` shows installation and the last result, and `check` runs one bounded tick. No timer is installed by default. macOS uses a LaunchAgent, Linux a systemd user timer, and Windows a least-privilege interactive Task Scheduler task. Checks run roughly once a minute while the user session is available. The job pins its configured folder and refuses a later folder mismatch.

An initial baseline is established only when local and cloud content agree. Subsequent checks push only local changes with a revision precondition, pull only cloud changes with local undo, and preserve both copies when both changed. Conflicts create a remote Markdown snapshot and require a manual decision; checks never force a merge. An expired login, unpaid subscription or provider outage leaves local files intact. Disabling persists the off flag before stopping the OS job, so a scheduler outage cannot authorize later network ticks.

`python3 tests/auto_sync_e2e.py` runs the real native CLI against a local HTTP service and fake scheduler, producing `artifacts/auto-sync/result.json`. It covers activation failure, two devices editing, conditional push/pull, undo, conflict snapshots, denied access, stale pinned folders and disable. It installs no real user jobs. OS references: [Apple LaunchAgents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html), [systemd timers](https://github.com/systemd/systemd/blob/main/man/systemd.timer.xml), and [Microsoft Task Scheduler schema](https://learn.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-schema).

## Personal folder libraries

When a library is configured, `sync push`, `sync pull`, and `sync auto` synchronize every managed folder, with stable folder IDs, one metadata revision, and independent Markdown revisions. Background jobs pin the library root. Renames preserve contents and selected-folder identity. Legacy single-folder configurations retain the root-document protocol.

Divergent edits create a private `.doin-library-conflict-*` directory containing both trees and folder Markdown. `sync push --force` chooses local document contents across the library; `sync pull --accept-remote` chooses cloud contents. Each prints affected folders and saves both copies before using current revision preconditions. These flags do not authorize folder deletion or bypass tree conflicts. Automatic checks never force a choice.

`sync export PATH` saves a new private `doin-library-v1` JSON bundle with the active tree, all active documents, and retained tombstone documents. Reads remain available for recovery after a subscription expires. See [native library design and E2E census](library-sync-native.md); verification receipts are recorded there.
