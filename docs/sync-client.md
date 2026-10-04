# Optional terminal account and sync

The hosted account/sync service is not live yet. Commands are implemented and tested locally; public email delivery and billing require a configured deployment.

Local Markdown and AI work without an account. Sync never runs automatically. AI sign-in and your doin.sh email account are separate.

1. Run `doin sync login`, or choose email sign-in from `/account` in the interactive app. Enter your email. The terminal sends one magic-link request and prints a six-digit confirmation code.
2. Open the email link and enter that code to verify this terminal request. The browser only verifies email access. Return to the terminal; it finishes sign-in automatically. No account portal or copied device token is required.
3. Manage your account in the terminal: `sync status`, `sync devices`, `sync revoke`, `sync billing`, `sync cancel`, `sync resume`, `sync recover`, `sync export`, `sync delete`, and `sync logout`. Use `sync push` or `sync pull` explicitly to synchronize Markdown.

Only secure payment entry uses Stripe Checkout in a browser. `sync billing` prints its validated HTTPS Checkout link. Cancellation, resuming renewal, and device revocation stay in the terminal and ask for confirmation. `sync recover` prints a validated Stripe invoice payment link when an outstanding invoice needs attention. `sync export > cloud-backup.md` retrieves your cloud Markdown even without an active sync entitlement. `sync delete` requires the exact phrase `delete my account`, cancels the subscription and deletes cloud data, and preserves local Markdown. For scripts, `sync cancel --yes`, `sync resume --yes`, and `sync revoke DEVICE_ID --yes` authorize their respective action. `sync logout` revokes this device session remotely and removes local credentials; an offline failure keeps credentials so you can retry. Already-expired sessions can be cleared locally.

Login creates a random verifier and sends only its S256 challenge when requesting the email. The 32-byte random verifier remains in the terminal and proves ownership when polling. A lost polling response is retried with the same proof until expiry, allowing recovery without extra device sessions. The email confirmation code binds the browser verification to the terminal request; mail scanners cannot complete sign-in by following a link alone. Polling stops on expiry, error, or cancellation. Failed login preserves an existing session and uploads no Markdown. Credentials are saved with owner-only permissions in `sync.json` inside the application configuration directory. Secrets go through stdin or owner-only temporary request bodies, never subprocess arguments.

`sync status` shows email and subscription state even without an active plan. The server checks device ownership for account actions and active entitlement for document access. Expired, unpaid, unavailable, or offline document requests fail without changing local Markdown. Each storage folder keeps endpoint/device-bound revision state in `.doin-sync.json`. Keep these hidden files local.

## Conflicts and recovery

A conflicting upload preserves local Markdown and saves a remote `.doin-sync-conflict-*` copy. Pull refuses to replace locally edited work. Compare and merge copies yourself. To adopt the cloud version explicitly, use `sync pull --accept-remote`; a `.doin-sync-local-*` backup remains. Then apply your merged changes and push. Pull shares the task-file lock, uses atomic replacement, checks independent editor changes, and maintains undo snapshots.

Offline or ambiguous uploads leave previous local revision state intact. The server may have received an upload before the connection broke; inspect or pull the remote copy before retrying. There are no automatic upload retries. An explicit retry can adopt a confirmed newer cloud revision when its content exactly matches the submitted Markdown.

For development, `sync login --endpoint http://127.0.0.1:PORT --email user@example.test --name Laptop` permits a loopback fixture. Other endpoints require HTTPS origins. Hosted email delivery and real payment verification are outside local fixture coverage.

## Reproducible verification

Email/account failure cases were enumerated and E2E scenarios updated before client implementation. Run `python3 tests/sync_client_e2e.py` after building. It exercises the real executable against a local HTTP service: PKCE and pending verification, account/device actions, trusted payment links, cancellation consent, failed mail/poll/logout, credentials, Unicode document conflicts, concurrent edits, locks, and ambiguous uploads. Evidence lives under `artifacts/sync-client/`.

With cloud development dependencies installed, `python3 tests/sync_client_e2e.py --worker` additionally drives the actual Worker+D1 through two-device email login, verification, sync conflicts, device revocation, subscription cancellation/resumption, export, logout, and account deletion while preserving local Markdown. Email and Stripe delivery are synthetic; no real messages or payments are sent.

Primary references: [RFC 7636 S256 proof](https://www.rfc-editor.org/rfc/rfc7636), [Zig 0.15.2](https://ziglang.org/documentation/0.15.2/), and this repository's `cloud/worker.ts` account/document contract. This is a custom email account protocol using S256 proof, not an OAuth provider integration.
