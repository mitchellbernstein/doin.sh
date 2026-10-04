# Delivery state — October 3, 2026

Public repository: https://github.com/mitchellbernstein/doin.sh. Local checkout: /Users/mitchellbernstein/Documents/GitHub/doin.sh.

## Shipped

Public v0.3.0 is published with five platform archives and SHA-256 checksums, and installed at ~/.local/bin/doin through the public checksum-verifying installer. Linux, cloud and Windows runtime/installer gates and release automation passed. Installed macOS arm64 binary is 730184 bytes, SHA-256 73d2bb4835f4cbcef9203032bb0880cad4920a2ac73a1ebd07a8f3d5531d55be, identical to the locally verified package. The site and installer are live at https://doin.sh and https://www.doin.sh. Namecheap delegates to Cloudflare; DNSSEC, valid HTTPS certificates, HTTPS redirects, and proxied Pages records were verified.

## Verified 0.3.0 delivery

Source checkpoint `2e2e401` is public and prints 0.3.0. It adds nested folders, typed custom properties, team assignees and commercial self-hosting, whole-library/background sync, approved AI tool loops and streaming, hosted MCP OAuth, Windows packaging, and generated root/folder AGENTS.md guidance with an optional CLAUDE.md import. CI run 37166954111 passed the complete Linux native/cloud suites and all eight Windows runtime groups plus installation/update checks. Actual Omarchy/Foot resize acceptance passed. Five local packages and all five Unix installer groups passed. Release run 37167109824 passed and published v0.3.0; the public installer updated the native Mac binary. The deployed Worker still uses the older source.

Agent guidance passed six E2E groups with 18 recorded commands. Existing user text survives initialization and reviewed managed updates; stale edits and symlink changes are refused. Custom local guidance is not synced or promoted into cloud instructions. Server authorization remains authoritative.

Cloud deployment still needs the pending Cloudflare Workers KV consent for OAuth storage, migrations 0005–0009 and a new Worker deployment. Production billing, approved ChatGPT consent and actual microphone recording remain external acceptance gates. No real payment or automatic microphone recording occurred.


## Free AI and doinWITH checkpoint

The paid-AI requirement was reversed before release. User-supplied models, local voice and local MCP stay free without a doin account. doinMORE ($4.99/month or $49.99/year) covers managed sync and hosted integrations; doinWITH ($99/user/year) covers team collaboration and commercial self-hosting. Terminal and iOS paid-AI gates are removed while preserving account/workspace safety and server authorization. Terminal/backend policy source is public at 793c51f; CI run 37170052752 passed Linux native/cloud and Windows runtime/installer checks. Local terminal tool and streaming suites passed 16 and 12 groups; the actual Worker hosted-MCP suite passed six groups, including unpaid denial. iOS source remains local in the concurrently developed app. Its focused real UI test passed: guest proposal generation/application, signed-in unpaid AI, two keyless loopback provider requests, zero entitlement requests, and HTTP 402 for unpaid hosted tools. Evidence: ios/Artifacts/20261003-211002 (xcresult, request receipts and screenshots). Earlier failed UI artifact is preserved; the test was corrected to tap the observed nested switch. Fixtures and build processes stopped; no test-booted simulator remains. The installed v0.3.0 was already free of the unreleased paid-AI gate and remains unchanged; remote Worker deployment and production billing are separate work.

## Release history

Version 0.2.4 is published and installed through the public checksum-verifying installer. Linux CI and release automation passed. The installed public binary matches the locally verified native build. It adds a free local stdio task server, named local MCP client connections and explicit tool invocation, plus paid hosted integration connections. Six server groups, four native-client groups including binary-to-binary interoperability, the cloud CLI fixture, seventeen guarded PTY cases, four platform packages and five installer groups passed. Final native build: 483768 bytes, SHA-256 132da3260d20e9d87ca2edc2a375a575bdb03c62560936eb2f6654afd5300daf. Worker deployment c3528b47-027e-40d1-8d35-80351de4301c includes migration 0004 and an encrypted integration credential key. Curl verified health 200, unauthenticated MCP 401, and current sandbox monthly/yearly plan 200. Hosted MCP six groups passed; no actual user integration has been connected. Provider OAuth, automatic AI tool routing and incoming hosted task MCP remain future work.

Version 0.2.3 adds monthly/yearly doinMORE selection. Stripe test prices and Worker pricing are deployed with migration 0003. Seventeen guarded PTY, eight Worker groups/CAS defect check and five native-client integration groups passed. Four platform archives and five installer groups passed. Linux CI and release publication passed; the public installer installed the identical 439528-byte native build (SHA-256 68af01a4fe0684a642fa7131f8ce39ce4975a619d74fda4f185dbcbc69ed9e40).

The previous 0.2.2 native build shipped with a persistent bottom composer, onboarding docking, model popups above input, and an original neutral empty-state orbit. Seventeen guarded PTY, five core, and eight auth groups passed on the exact installed 422488-byte build (SHA-256 4d0509e41c97cd71060cc19e85363ecc1eb0cf6a2c005635d4fe0005ca211320). Linux CI and release automation passed; the public installer downloaded and verified this exact binary. Native scrollback retention with reduced scrolling margins depends on the terminal emulator. Motion can be disabled with DOIN_NO_ANIMATION=1.

The 0.2.0 source adds an editable inline terminal composer, sectioned task board, history, Unicode input, narrow-terminal behavior, model-catalog sanitization, optional local Whistle transcription, and a native sync/account client.

Optional sync uses email magic links. Account and device management stay in the terminal. A minimal browser confirmation verifies email ownership; Stripe hosts payment entry. The cloud service runs on a Cloudflare Worker and D1 with conditional document revisions, explicit push/pull, guarded local writes, conflict preservation, and export. Free local use needs no account.

Cloudflare Email Sending is enabled and DNS-configured for doin.sh. The account already has Workers Paid. A restricted Stripe test key is stored as an encrypted Worker secret with explicit owner approval. No service credentials are in the repository or downloaded application. Test prices are $4.99 USD/month and $49.99 USD/year; the old $2.99 price remains recognized for existing subscriptions. Production billing is not enabled.

## Verification boundaries

Core, OAuth, PTY, sync-client, Worker/D1 and optional speech checks produce reproducible artifacts. The account implementation passed native-client and Worker/D1 checks. Real email delivery, browser confirmation and terminal sign-in passed against the deployed service. The browser confirmation error was fixed by using an origin-only referrer policy. The native 0.2.1 build is installed and published with four platform archives containing the current license. The 0.2.1 model picker, productivity views, custom statuses, upgrade menu, and optional reminders are implemented and installed. Live ChatGPT consent/entitlement, microphone interaction and a completed Stripe sandbox payment remain separate acceptance checks. The real hosted test Checkout loaded the $2.99 monthly plan successfully; no payment was submitted.

macOS arm64 runs natively. Linux x86_64 ran in release CI. Other packaged targets cross-compile; that does not prove their native execution. Earlier startup benchmarks apply to v0.1.0 and are not measurements of 0.2.0 or model latency.

The installed 0.2.1 macOS arm64 build is 421320 bytes (SHA-256 0edc067d8d779c18319fee0689252fd712b5eaf7feb2042bbae9be6b742e61d4). Thirteen PTY scenarios and six reminder groups passed on its preceding 421288-byte checkpoint; the final document-size guard passed the full productivity CLI scenario with tasks and undo preserved. A preceding 314184-byte build’s empty-document benchmark over 100 serial subprocess calls measured 2.551 ms median and 3.518 ms p95 with a warm filesystem cache. This includes process startup and excludes AI/network latency. Receipt: artifacts/benchmark-0.2.0.json.

The updated simple marketing site and exact Windows installer were deployed at https://cbba3da6.doin-sh.pages.dev and verified through https://doin.sh. Deployment uses the existing Pages project following [Cloudflare Direct Upload documentation](https://developers.cloudflare.com/pages/get-started/direct-upload/). No new service plan was purchased.
