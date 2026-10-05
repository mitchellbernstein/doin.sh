# Billing E2E failure census

| Flow | Failure case | Expected protection |
| --- | --- | --- |
| MORE period switch | No active accepted subscription, multiple subscriptions/items, wrong customer, or a period already ending | Reject before mutation; keep existing access unchanged |
| MORE period switch | Quote is expired, submitted amount differs, or Stripe preview changes at confirmation | Requote or reject before mutation; require fresh confirmation |
| MORE period switch | Stripe reports `pending_update` after immediate invoice payment needs action | Keep current plan and access; expose the pending target; block another switch |
| MORE period switch | Stripe accepts a change but response is lost | Persist operation key and fields; reconcile/replay exact request safely |
| MORE period switch | Browser reloads after invoice recovery settles a pending change | Reconcile the saved quote read-only on billing refresh; permit later switch without the old quote ID |
| MORE period switch | Completed quote is confirmed again | Replay `changed: true` without another Stripe mutation |
| MORE period switch | Expired ambiguous update crosses the current period boundary | Reject stale retry after reconciliation; do not send a new provider update |
| MORE period switch | Legacy monthly price has a different amount | Show the current Stripe price amount, not the replacement monthly amount |
| MORE period switch | Repeated same-target preview or excessive distinct preview requests | Reuse a live bound quote without extra provider calls or row growth; limit new preview work before Stripe |
| MORE period switch | Provider reports an unrelated pending target | Do not associate unrelated pending work with this quote |
| MORE period switch | Zero due after proration | Accept explicit zero confirmation; never treat zero as missing |
| MORE billing portal | Missing customer, malformed response, unsafe host/protocol, or portal provider outage | Return bounded error; never return an unvalidated provider URL |
| WITH billing portal | Non-owner, missing team subscription, or unsafe URL | Reject access or return bounded error |
| MORE to WITH | Team checkout exists but is incomplete, canceled, or inaccessible | Preserve personal renewal; only permit explicit cancellation after active team access |
| MORE to WITH | User lacks owner role, malformed confirmation, or has no active MORE subscription | Reject without changing any subscription |
| MORE to WITH | Cancel request succeeds | Set `cancel_at_period_end`; preserve personal active term and leave team subscription untouched |

The executable scenarios live in `e2e.mjs` and `team-e2e.mjs`. They use Stripe-shaped sandbox fixtures, authenticated Worker requests, D1 migrations, and write reproducible JSON reports under `cloud/artifacts/`.
