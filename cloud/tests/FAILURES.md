# Sync E2E failure census

Original OAuth census preceded the initial implementation. This email/TUI revision census was updated before rewriting authentication. The check drives HTTP through workerd and real local D1. Mail delivery and Stripe remain network fixtures.

1. An attacker steals a request ID or email link but lacks the original PKCE verifier. Proof substitution, expired approvals, callback replay, email scanners, wrong confirmation codes and invalid addresses must not mint a device session.
2. A login claim succeeds but the HTTP response is lost. Original-proof retry returns the same session without creating another. Revocation and expiry prevent restoring that session from the claim receipt. Concurrent claims produce exactly one session.
3. Email delivery fails, accounts are enumerated, abusive starts bypass per-email/IP limits, or terminal control characters enter a device name. Errors are bounded and no real messages are sent by tests.
4. Missing, expired or revoked device credentials and cross-account document/device/billing access are denied. GET email verification has no mutations and POST needs the TUI code plus same origin.
5. A free account attempts sync, a subscription lapses/cancels, another product/price is purchased, Stripe times out or returns invalid data. TUI cancellation changes only this account's subscriptions and schedules period-end cancellation without losing already paid access.
6. Two computers edit the same revision concurrently. Exactly one wins, the loser gets 409 and current cloud content. Retrying the same saved content is safe. A large or malformed document is rejected before a write.
7. A webhook signature is missing, wrong, stale or rotated. The same event arrives twice or events arrive out of order. A failed database write must not acknowledge success.
8. Checkout retries create duplicate customers/subscriptions, hostile return URLs redirect outside the service, canceled accounts cannot export their existing data.
9. D1 is unavailable during claim, cancellation or document save. Responses disclose neither SQL nor credentials and never claim the write succeeded.
10. A native browser form POST applies Referrer-Policy differently from a CORS fetch: `no-referrer` serializes Origin as `null`, breaking legitimate confirmation. Real Chrome must submit the form with the service origin while the email token is absent from Referer. Null and hostile origins must still be rejected. Reproduce before/after with `python3 tests/browser-origin-probe.py`; its browser artifact records received headers without real email tokens.
11. A logged-out upgrade screen mistakes sandbox Checkout for a real purchase, unknown key formats for live billing, placeholders for configured prerequisites, or leaks server keys in plan metadata. Public plan discovery must need no account and must remain read-only during provider outages. Real Checkout still independently validates the configured price before offering payment.

Artifact records scenario assertions, runtime versions and reproducible command. No customer or real payment credentials are required.

12. Monthly/yearly selection must use server price IDs and USD499/4999 validation. A pending legacy/monthly Checkout cannot be returned for yearly selection. Recover lost creation responses with the original price/idempotency key, expire old sessions before replacement, and retain original state on provider failure. Old299 and both new intervals retain account entitlement, cancellation/recovery/deletion without repricing.
