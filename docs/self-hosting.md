# Self-hosting doin

Implementation is being verified locally; this configuration has not been deployed to a separate customer account yet. Personal self-hosting is for one configured owner. Companies and teams require a commercial license; changing hosting location does not change that requirement.

The supplied backend runs on your own Cloudflare Workers account, D1 database and KV namespace. Your email sender and external integration credentials belong to that deployment. The native terminal app uses the same Markdown files and commands as the official service.

## Personal deployment

1. In `cloud/`, run `npm ci`. Copy `wrangler.selfhost.example.jsonc` to an ignored local file such as `.wrangler.personal.jsonc`. Replace the Worker name, HTTPS origin, owner email and verified email sender. Keep the official `wrangler.jsonc` separate.
2. Create resources in your account with `npx wrangler d1 create doin-personal` and `npx wrangler kv namespace create OAUTH_KV`. Copy their IDs into your local configuration. Do not reuse the doin-operated database or namespace.
3. Configure Cloudflare Email Sending for your sender and restrict the `EMAIL` binding to that address. Sending to unverified recipients can require a paid Cloudflare plan. Infrastructure costs are yours; doin does not charge a personal self-host license fee.
4. Apply every migration: `npx wrangler d1 migrations apply doin-personal --remote --config .wrangler.personal.jsonc`.
5. Set `MCP_ENCRYPTION_KEY` with `npx wrangler secret put MCP_ENCRYPTION_KEY --config .wrangler.personal.jsonc`. Supply a cryptographically random 32-byte key encoded as 64 hexadecimal characters. Keep it outside the repository and terminal command arguments. Changing it makes existing encrypted integration credentials unreadable.
6. Deploy with `npx wrangler deploy --config .wrangler.personal.jsonc`. Set `ORIGIN` to the exact final HTTPS origin before using email or OAuth callbacks.
7. In the terminal, run `doin sync login --endpoint https://YOUR_WORKER_HOST`. Only the configured owner email can begin personal sign-in. Confirm the real email link and terminal code, then explicitly push/pull or enable automatic sync.

Personal mode needs no Stripe keys. It rejects team features. The service still requires authentication and scopes for integration access; it does not become a public task database. Use device revocation and encrypted backups on your own account.

## Commercial deployment

Use `SELF_HOST_MODE="commercial"`, the signed receipt in the `COMMERCIAL_LICENSE_RECEIPT` encrypted secret, and the issuer public key and key ID obtained through a separately trusted doin distribution. Never use a key supplied inside an untrusted receipt. A sandbox receipt grants no production rights. Supply your own email, D1, KV and integration encryption key as above. The commercial runtime is undergoing E2E verification; see [team documentation](team-plan.md) for its current state.

Only the official issuer deployment holds `LICENSE_SIGNING_KEY`. Customer self-hosts receive a receipt and public verification key, never a signing private key or doin's Stripe credentials. The receipt limits the organization, seat count and paid term. Expiry retains authorized data recovery while blocking new shared writes and integrations.

Configuration follows the current [Wrangler configuration documentation](https://developers.cloudflare.com/workers/wrangler/configuration/) and [KV bindings documentation](https://developers.cloudflare.com/kv/concepts/kv-bindings/), checked October 3, 2026 against Wrangler 4.147.0.
