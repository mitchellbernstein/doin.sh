# Team implementation failure census

Written before the team backend implementation. Existing personal accounts and documents must remain unchanged.

- Authentication/tenant isolation: missing session, forged team/document IDs, revoked member racing a write, admin privilege escalation, last-owner departure/account deletion, account closing.
- Invitations: malformed email/token, replay, wrong verified email, expired token, simultaneous claims for last seat, inviter loses privileges, no paid capacity, failed email delivery. Only hashed invite credentials persist.
- Documents: stale revision across two devices, oversized/invalid Markdown, cancellation expiry, departed member exporting another team, no silent overwrite.
- Billing: invalid annual price, unsafe provider URL, duplicate open checkout, lost provider response, changed checkout quantity, completion race, billing lease expiry, payment failure/pending update, duplicate webhook, quantity reconciliation outage, seat decrease below occupied users, refund surprise.
- Licensing: no signing binding, malformed JWK, altered receipt, wrong issuer/environment/key, expired term, renewed receipt replay, organizational use presented as personal free, signing secret leakage.
- Lifecycle: cancellation/delete during payable checkout, incomplete provider cleanup, owner deleted while team retained, downloaded offline copy cannot be revoked remotely.

E2E evidence must exercise three users/two devices, two tenants, last-seat race, conflict, role boundaries, failed/pending/successful seat changes and tampered/expired receipts against workerd and D1. Save reproducible artifacts with no real emails/payments/secrets. Test local outbound adapter only.

## Team assignees census (before implementation)

Three members across a root and restricted folder: a task must never acquire an assignee from another organization, an inaccessible folder, or a removed account. Read-only actors cannot assign. A membership/grant revocation between picker lookup and CAS must deny the newly assigned ID at commit. Existing former-member assignment history stays on the same stable task ID without resolving it to a reused email. Malformed/duplicate/oversized portable metadata fails closed; expired licenses and stale revisions preserve both documents. Bulk assignments remain one document CAS and ordinary Markdown undo. Personal workspaces expose no assignment command or default assignee property. E2E artifact must cover valid assignment, restricted-member rejection, offboarding/history, invalid IDs, read-only writes, expiry and a revoke-before-commit race.
