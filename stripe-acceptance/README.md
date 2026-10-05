# Actual Stripe sandbox acceptance

## Failure modes to cover before isolating the Worker

The acceptance runner is designed around these real-world failure paths:

1. A missing, malformed, restricted or live API key; missing/misconfigured Price IDs; Price objects that are live, inactive, wrong currency/amount/interval/usage type; or a Stripe account different from the sandbox used by Stripe CLI.
2. The compiled Worker makes an unexpected outbound request, attempts to send an email, or has incompatible D1/KV/migration bindings. Stripe rejects a request, returns a malformed/incomplete object, a request times out after creating an object, or rate limits the sandbox.
3. Checkout returns an unsafe/missing URL, uses the wrong Price or quantity, gets expired/replayed with lost local state, or remains uncompleted because no interactive hosted form was run. A direct API-created subscription is not evidence that Checkout succeeded.
4. A monthly/yearly quote is stale, mismatched or replayed; the amount or selected interval differs; payment fails or requires action; a Stripe pending update becomes entitlement before paid confirmation; duplicate/late/reordered webhook events corrupt state; or cancellation/resume/replacement changes access at the wrong time.
5. A seat increase produces an unexpected proration/invoice, a failed payment grants extra seats, paid seats and renewal seats get conflated, cancellation drops paid access early, or renewal fails after test-clock advancement.
6. Webhook secret is absent/wrong, Stripe CLI is unavailable or listens to a different test account, a genuine event is not delivered, a tampered signature is accepted, or duplicate delivery is applied more than once. Basil API requests and webhook-event API versions can differ.
7. Cleanup runs twice, is interrupted, hits a provider outage, cannot advance/delete a test clock, or accidentally targets a preexisting object. Only customers, subscriptions, Checkout sessions and clocks created by this run may be canceled/expired/deleted.

## Run

From `cloud/`, run `node tests/stripe-sandbox-acceptance.mjs`. No install is needed; it uses the pinned local `miniflare` and `esbuild` dependencies. It reads required Stripe values from the process environment; if missing, it reads only the Stripe names from ignored `cloud/.dev.vars` without printing them. Required values are `STRIPE_SECRET_KEY` (must be full `sk_test_`), `STRIPE_MONTHLY_PRICE_ID`, `STRIPE_YEARLY_PRICE_ID`, and `STRIPE_TEAM_PRICE_ID`. Stripe CLI must already be authenticated to that same test-mode account; the runner starts `stripe listen` without passing credentials in argv. It pins every API request made by the Worker and runner to `Stripe-Version: 2025-03-31.basil`.

The runner preflights all three Prices before creating anything, builds the actual exported Worker into Miniflare with real Stripe API outbound traffic as its only allowed destination, creates task-owned customers/subscriptions and a local D1 team/session, and writes a secret-free JSON artifact under `cloud/tests/artifacts/stripe-sandbox-acceptance/`. All generated customer emails use the reserved `.test` domain. It never invokes auth email, stores card data, prints keys/webhook secrets/Checkout URLs/provider payloads, or makes a live-mode API call. `STRIPE_SECRET_KEY` must be a full test key; the three Price IDs can come from the environment or existing sandbox `vars` in `cloud/wrangler.jsonc` and are verified as test-mode before mutation. When the runner exits normally, it cancels or deletes only its tracked test objects. A cleanup manifest is persisted before provider writes; after interruption, run `node tests/stripe-sandbox-acceptance.mjs --cleanup tests/artifacts/stripe-sandbox-acceptance/<manifest>.json` from `cloud/`. Cleanup verifies run metadata before acting, refuses incomplete/paginated lookups, and reports unresolved resources instead of treating provider errors as absence.

The runner exercises real Stripe API subscription mutations and a real Stripe CLI signed-event delivery through `/webhooks/stripe`. It validates successful and failed subscription changes, pending-update entitlement boundaries, doinWITH quote/proration/seat behavior, personal and team cancellation/resume, replacement confirmation, test-clock renewal, and personal/team payment-method portal sessions. It creates personal and team Checkout Sessions through the Worker and verifies their real Stripe objects, then expires them during cleanup. It does **not** complete the hosted Checkout form, perform interactive 3DS, or prove Checkout payment/entitlement; those remain separate `NOT_RUN` browser acceptance rows until a human completes Stripe-hosted test Checkout with documented test values. As a result, API lifecycle success alone is reported as `ISSUES`, not a full acceptance `PASS`.

A nonzero result or missing credentials is not a sandbox pass. Fixture E2E tests are separate and do not satisfy any real Stripe evidence row. The script does not deploy, create webhook endpoints, or write production secrets.

## Evidence and primary documentation

Artifacts include outcome, sanitized run alias, check labels, redacted IDs, interval/amount/status/`livemode` and event types only. No email, customer data, payment credentials, secret key, webhook secret, Checkout URL, or raw API response is retained.

- [Stripe test mode and test card values](https://docs.stripe.com/testing): use test keys and Stripe's documented PaymentMethod test IDs; Stripe explicitly distinguishes successful, decline, and 3DS scenarios.
- [Attach a PaymentMethod to a Customer](https://docs.stripe.com/api/payment_methods/attach): use a SetupIntent or PaymentIntent for a real saved payment flow; the harness seeds sandbox subscriptions with Stripe's documented test-only PaymentMethod fixtures and does not exercise hosted form data entry.
- [Stripe CLI webhook testing](https://docs.stripe.com/stripe-cli): `stripe listen` forwards genuine test-mode events and supplies an ephemeral signing secret for local webhook verification.
- [Update a subscription](https://docs.stripe.com/api/subscriptions/update): `pending_if_incomplete` applies a subscription change only after its invoice is paid.
- [Test clocks](https://docs.stripe.com/billing/testing/test-clocks): sandbox time simulation and renewal events.
- [Basil 2025-03-31 subscription-period change](https://docs.stripe.com/changelog/basil/2025-03-31/deprecate-subscription-current-period-start-and-end): period bounds are on subscription items, not the subscription object.
- [Stripe API versioning](https://docs.stripe.com/api/versioning): webhook endpoints can use an API version independent of the request header; compare the observed event `api_version` with the configured endpoint during release readiness.
