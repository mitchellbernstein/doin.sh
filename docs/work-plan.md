# Current work

1. Read the Principles section of poteto-mode. Done.
2. Frame. Optional paid sync, readable terminal interface, optional local voice, and protected domain.
3. Fan out. TUI owns src/main.zig and src/terminal.zig. Sync owns cloud/. Voice owns voice/. Domain owns docs/domain-setup.md and read-only DNS checks. Root owns browser changes and integration.
4. Aggregate. Review each diff and rerun the relevant real-product check before release.
5. Report. Distinguish local verification, installed binaries, published releases, and deployed services.

## Done predicates

- TUI supports editable input, task hierarchy, history, narrow terminals, and safe terminal restoration. A reproducible PTY recording proves behavior.
- Sync uses doin email magic links. Account status, devices, revocation, subscription and cancellation are managed in the terminal. The browser only verifies the email link and enters payment details in Stripe Checkout. Two devices exchange Markdown. Stale writes return a conflict without overwriting either copy. Billing remains test-only until production credentials are configured.
- Voice begins only after an explicit command. Audio stays local. Cancel deletes temporary audio. A transcript fills the composer for review before any AI request.
- Namecheap delegates to Cloudflare. Apex and www use proxied Pages records. HTTPS serves the actual site and installer with valid certificates.

## Throughput checkpoint

Each writer has a distinct directory or file responsibility. Run only one memory-heavy install, build, or broad test at a time. Each lane records failures before implementation and leaves reproducible E2E artifacts. Parent integration starts after the lane's output is stable.

## Delivery state

Public v0.2.2 exists and is installed at ~/.local/bin/doin through its public installer. The native macOS arm64 public installer and Linux x86_64 CI were verified. The static site is deployed at doin.sh and www.doin.sh. Namecheap delegates to Cloudflare; HTTPS redirects, certificates and DNSSEC were verified. The sync Worker and D1 database are deployed at sync.doin.sh, with account login and billing still gated.

The 0.2.1 TUI, model picker, custom statuses, productivity commands, reminders, sync, and voice build is installed and published.

The owner chose email magic links instead of GitHub sign-in. An unused GitHub OAuth registration has no secret and is excluded from the implementation. Cloudflare Workers Paid is already the current account plan. Email sending is enabled with configured DNS; both Stripe test secrets are encrypted Worker bindings, with explicit approval. No live billing or real payment has been enabled.

## Model picker follow-up

1. Ground. Trace the existing editor, config, catalog adapters and inference payloads.
2. Sketch. Compare parsed command text with focused typed picker fields and options.
3. Agree. Use typed fields; keep networking and config writes outside raw terminal input. No optional human checkpoint was requested.
4. Implement. Inline model/window/effort placeholders, filtered neutral popup, Tab navigation and discovered provider capabilities.
5. Scrap. Remove designs that lose queued input, treat paste as submission, or clear scrollback in short terminals.

Completion requires actual PTY artifacts for filtering, field navigation, cancellation, paste, resize, provider defaults and request payloads. The existing public v0.2.0 remains available while this change is verified.

## Productivity and reminders follow-up

- Native help/settings discovery and doinMORE upgrade menu with explicit browser transition after email sign-in.
- Open-task review, explicit-hint priority preview, and grouped checkbox progress. Historical avoidance and efficiency are not inferred.
- Batch deletion previews selected task lines before the existing locked write/undo boundary; prose and fenced examples remain.
- Optional per-task reminders use portable Markdown IDs and due times with device-local delivery history. Notification scheduling is off until explicit opt-in.
- The integrated 0.2.1 checkpoint passed thirteen PTY scenarios, six reminder groups and the productivity CLI lifecycle. A final shared commit guard passed the near-limit task/undo preservation regression. The final build is installed through the public installer, and four downloadable packages are published. Linux CI and release automation passed.

## Custom statuses follow-up

- Start with todo, doing, blocked and done; keep todo/done aligned with Markdown checkbox semantics.
- Store managed open statuses in the Markdown document so they travel with task sync.
- Provide /statuses list, add, rename and remove, with an explicit replacement when removing a status still used by tasks.
- Route registry and task changes through the existing locked write and undo boundary. Verify realistic create/assign/filter/rename/remove flows and preservation of fenced examples before release.

## Docked composer and empty state

1. Ground: trace Editor, onboarding, picker, chart, and output ownership. Done.
2. Sketch: compare a normal-screen reserved footer with an alternate-screen transcript viewport. Done.
3. Agree: use normal-screen cursor positioning and a reserved output region; terminal scrollback retention depends on the emulator. No additional human checkpoint requested.
4. Implement: bottom composer, popup above it, neutral original placeholder art, idle-only animation with no-motion and plain-terminal fallbacks.
5. Scrap/verify: seventeen guarded PTY scenarios passed on the installed 0.2.2 build, including onboarding, resize recovery, long output, popup geometry, animation stop and signal cleanup. Five core and eight auth groups passed. Four-target packaging and five installer groups passed. Linux CI and release automation passed; v0.2.2 is published and installed through the public checksum-verifying installer.

## MCP proposal

The owner confirmed free local MCP in both directions and paid doin-hosted integrations. The scoped design and verification sequence are in [MCP design proposal](mcp.md). MCP is planned, not implemented.

## MCP implementation

1. Ground. Trace the configured Markdown folder, locked mutations, terminal streams, private credentials, paid Worker gates, and current MCP protocol documentation.
2. Sketch. Compare a native callback adapter and request-scoped hosted SDK client with shell wrappers and persistent Durable Objects.
3. Agree. Choose native stdio server/client and request-scoped hosted integrations. The separate hosted task server requires scoped OAuth and remains a future proposal.
4. Implement. Delegate local server, local client, hosted integration gateway, and team planning to disjoint owners. Root owns main/sync bridges and release integration.
5. Scrap. Reject designs that print UI on protocol stdout, use stale task numbers, leak tokens across origins, or create persistent processes unnecessarily.

Throughput checkpoint:

- Blocking first steps. Write failure censuses and confirm typed module APIs before implementation.
- Independent workstreams. Local task server, local integration client, cloud integrations, and team design have separate modules and evidence.
- Shared mutable state. Root alone edits main/sync bridges. Cloud owner alone edits Worker/migrations. Native writes reuse the existing storage lock and compare-before-write guard.
- Smallest safe decomposition. One owner per protocol module. Heavy build/test/install commands run serially.

## Previously documented gaps (status updated 2026-10-04)

Done predicate: every current gap below has implemented behavior, reproducible E2E receipts, reviewed integration, and a published/installed or deployed delivery. Environment-blocked checks remain open rather than being relabeled supported.

1. Platform: Windows native adapter, ConPTY/process/privacy behavior, downloadable installer; actual Omarchy desktop acceptance and Linux arm64 execution where available.
2. Commercial teams: test-mode annual $99/seat billing, terms and entity acceptance, internal commercial self-host rights, signed receipts, team access controls and native management are locally implemented. Parent integration E2E results are pending. Production remains blocked: remote migrations 0005–0009 are pending, local source adds `0010.sql`, Worker deployment is pending, and no live purchase is enabled. Real Stripe sandbox checkout, hosted Checkout and 3DS remain unverified.
3. Hosted MCP: external provider OAuth consent/refresh/revocation and separately scoped incoming task MCP OAuth with terminal grant approval.
4. Local productivity: opt-in safe background sync; Linux user reminder scheduling; portable calendar and device-local notification receipts.
5. AI: explicit per-tool approval with bounded provider tool loops, live SSE display without saving incomplete output.
6. Existing acceptance: real local voice engine and ChatGPT sign-in eligibility/consent; live integrations only where account consent is granted. Production Stripe activation remains a separate external gate, not a fixture pass.

Workflow: inventory and typed seam agreements; failure census and realistic E2E fixtures before isolated implementation; disjoint worker modules; root integration; one heavy build/test/VM/deploy lane; independent review of each stable batch; release and public installer verification. Existing v0.2.4 stays available throughout.

Background-sync failure census: missing/changed credential identity, absent baseline, divergent initial files, local-only/remote-only/both edits, cloud CAS conflict, independent external editor bypassing lock, malformed remote contents, unavailable/unpaid/revoked account, interrupted or ambiguous PUT, changed configured storage, repeated timer invocation and concurrent app edits. Preserve local task and undo files on every rejected or ambiguous operation. No initial differing document may be silently replaced. No payment, model call or signup may happen from a timer.

### Personal self-host boundary

Personal mode is explicit deployment configuration, never enabled on the official hosted Worker. It permits only a configured owner email, rejects team features, and does not require Stripe for that owner. Failure census: missing/malformed owner configuration, alternate email enrollment, closed account entitlement, company-mode bypass, and official deployment accidentally receiving self-host flags. Local Worker fixtures cover the personal-mode boundary; production deployment remains pending.

### Verification checkpoint: folders and completion batch

Native AI tools passed 16 real CLI scenarios; Responses streaming passed 12. The latest macOS build, six reminder scenarios, interruption cleanup, Linux scheduler fixtures and automatic sync conflict scenarios passed. Hosted MCP passed six OAuth groups, the existing eight account groups and six gateway groups. Further OAuth refresh and concurrent-revocation cases are being added before final verification.

Folder storage uses stable IDs, a parent relation and one Markdown document per folder. Team folder grants apply to descendants; moving folders and offboarding must recompute access at each operation. Simple onboarding remains the default; Custom creates a first folder and optional task, and Templates offers Projects or Areas. Local folder and cloud ACL runtime checks remain queued while root integration proceeds.

Commercial self-hosting has local runtime receipt verification, with issuer keys supplied independently of the receipt and no issuer billing secrets on a customer deployment. Personal self-hosting restricts sign-in to the configured owner and denies team routes. Local fixture results do not establish deployed-service behavior.

The shared heavy-command lane is assigned serially by the root. The isolated Omarchy VM is stopped until the final Linux build is ready. The old published/installed v0.2.4 and hosted Worker remain the user-facing versions; this batch has not been released or deployed. Cloudflare KV authorization awaits the user's explicit security-access approval.

Team sandbox catalogue created in the existing authenticated Chrome tab: product `prod_VNNKFUqT2xZZWJ`, yearly USD 9,900-cent per-user price `price_1UMca5J8ruTe6uCO8v5cTsqo`. Dashboard confirmed Sandbox and zero active subscriptions. No payment or live product created. Real Stripe sandbox checkout, hosted Checkout and 3DS remain unverified. The remote D1 migration listing reports 0005–0009 pending; local source adds `0010.sql`. Worker binding is saved locally; deployment remains pending. No migrations were applied.

### Properties and assignments checkpoint

Everyone can define text, number, date, single-select, multi-select and Boolean properties. Team Assignee values use canonical account IDs and display labels; new assignments require current member access to the selected folder at the document CAS commit. Schemas, stable option IDs and values live in fence-safe escaped Markdown comments. Simple onboarding adds no property questions. Property edits use the same lock, preview, compare-before-write and undo boundary as other task changes.

Failure census: malformed/duplicate metadata, fenced examples, property renames and option removals, incompatible type changes, injected comment delimiters or built-in status tags, reminder identity loss, external editor races, foreign or offboarded assignees, revoked folder access or expired plan during commit. Native property acceptance is pending integration; team backend assignment checks passed, with final parser/expiry cases queued for rerun.

All six cloud suites passed 44 groups before assignment integration. Native folder lifecycle/escape E2E passed. New native sync/team/OAuth tests exposed signed decimal timeout formatting (`20.+000`) rejected by curl before HTTP; the timeout now formats unsigned values and those scenarios must pass before release.

### Earlier local acceptance checkpoint, before latest billing changes

The results immediately below are historical checkpoints. They do not verify the current interval-switching, team billing, browser or migration changes; use the current generated E2E receipts before claiming those checks.

Native whole-library sync, folder lifecycle, team CLI (including assignees), hosted MCP client/OAuth consent and seven reminder groups pass. Properties pass seven real CLI groups/46 commands, including actual reminder recognition, multi-select preservation, destructive preview cancellation, external edits, symlink replacement and configuration changes. The 18-group TUI suite passes, including startup growth and subsequent shrink. A separate quoted-command/picker PTY fixture still requires a clean final exit receipt.

Cloud account8, gateway6, OAuth9, team9, team-folder5 and personal-folder8 groups pass (45 total). Windows full application and platform-driver cross-compilation pass; real Windows CI is pending. Latest Linux/Omarchy acceptance and package/install verification remain open. Current local source is0.3.0; v0.2.4 remains published/installed.


### Final 0.3.0 delivery checkpoint

- Source/tag `2e2e401` passed CI37166954111, including the entire Linux/cloud suite and Windows native console, Unicode, MCP, private ACL, process jobs, scheduler, browser and notification checks. Windows installer installed and atomically updated an existing executable.
- Release37167109824 passed native behavior, five-target packaging and Windows runtime/install gates; v0.3.0 is public with five archives and checksums. Local installer five groups passed. Public installer updated ~/.local/bin/doin to0.3.0; 730184bytes and SHA25673d2bb4835f4cbcef9203032bb0880cad4920a2ac73a1ebd07a8f3d5531d55be match local verified package.
- AGENTS guidance six groups/18commands passed; folders preserve custom guidance on rename, MCP shares the protocol, existing files remain intact and stale/symlink writes are refused.
- Site deployment cbba3da6.doin-sh.pages.dev is live; doin.sh and exact Windows installer downloaded and checked.
- External gates remain Cloudflare expanded KV consent, remote D1 migrations 0005–0009 and local migration 0010, Worker deployment, production Stripe catalog/secrets/webhook setup, published commercial terms, verified signing-key consistency, real Stripe sandbox/hosted Checkout/3DS acceptance, provider-approved ChatGPT consent and user microphone acceptance. Customized local AGENTS files are not cloud-synced.
