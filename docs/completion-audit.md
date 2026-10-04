# Completion audit

Snapshot checked October 3, 2026 at source HEAD `395ed75`. This is a read-only coverage review, not a fresh runtime or deployment verification. Source writers remain active. Source version prints `0.2.4`. Published and installed state below is taken from `docs/STATUS.md`; it must be reconciled against the next release's actual artifacts.

## Original product outcomes

| Requested outcome | Observed evidence | Lane | Remaining acceptance or gap |
| --- | --- | --- | --- |
| Named public repo in Documents/GitHub | README and STATUS name `mitchellbernstein/doin.sh`, local checkout is under Documents/GitHub | Root | Complete according to existing delivery receipts. |
| Small, fast native product based on fx's approach | Zig 0.15.2 build, no Zig package dependencies, STATUS records a 483,768-byte v0.2.4 native binary | Root | Native startup benchmark in STATUS belongs to an earlier build. Re-measure the final release before using a current speed claim. No code-size ceiling was specified. |
| Clean, readable fx/Codex-style TUI | `src/terminal.zig`, `docs/ui.md`, guarded PTY scenarios in STATUS | Auth/TUI | Final new-feature PTY verification and terminal cleanup remain necessary after active integration. Physical terminal scrollback behavior varies by emulator. |
| Storage location before model onboarding, manual skip | README, core E2E, TUI docs | Root/TUI | Existing coverage recorded. Preserve it through platform/model changes. |
| Markdown tasks and questions/generation through AI | README, core E2E, guarded preview/write behavior | Root | Existing manual/local/API behavior recorded. Live model quality is separate from HTTP fixture correctness. |
| Local model choice without forced cloud use | Loopback Ollama and compatible API documented; manual mode needs no account | Root | Ollama cloud disable is documented. No automatic downloads or inference-server startup should be introduced. |
| ChatGPT/Codex account sign-in | `src/auth.zig`, OAuth fixtures and recovery tests | Root/provider acceptance | Live consent and inference are not verified. The current personal-use license is not OSI open source. Eligibility cannot be inferred from successful fixture OAuth. See provider boundary below. |
| Installable downloads and local terminal installation | STATUS records published v0.2.4 and public-installer installation | Root | `artifacts/public-release/results.json` still records v0.1.0. Do not cite it as v0.2.4 proof. Preserve a version-specific next-release download/install receipt. |
| Public and open source | Public repository; current LICENSE explicitly limits business use and paid redistribution | Root | Later license choice superseded original MIT delivery. Current release is source available, not OSI open source. Preserve that distinction in site, README, release text and ChatGPT eligibility claims. Earlier MIT releases retain their grant. |
| Single-page Rams-inspired marketing site | Static `site/`, browser-evidence JSON records responsive widths, copy feedback, installer byte match | Root/site | Existing site evidence recorded. Reconcile links, license wording and pricing after final capabilities ship. |
| Purchased Namecheap domain protected through Cloudflare | `docs/domain-setup.md` records active zone, proxied apex/www, valid TLS, strict mode, HTTPS redirect and authenticated DNSSEC | Root/domain | No remaining migration gap recorded. New Worker hostnames need their own verified deployment records. |
| Optional accounts and multi-device paid sync | Worker/D1 and native sync client; live email sign-in recorded; conflict fixtures | Sync/root | Billing remains Stripe sandbox. A loaded Checkout is not a completed payment or live subscription. New checkout amount is $4.99/month or $49.99/year according to later pricing docs; the initial $2.99 offer is legacy. |
| Optional `/voice`, lightweight local Whistle | Seven real-engine checks in `artifacts/voice/check.json`; direct local C API; symlink regression verified | Voice complete; TUI hook owned by auth | Real microphone permission, Enter stop, 30-second timeout and Ctrl-C cancellation still need an explicit user `/voice` invocation. Do not record the microphone automatically to close this check. Speech becomes an editable draft, never an automatic task or AI request. |

## Current expanded gap-closing program

These items come from `docs/work-plan.md`, not speculative additional scope.

| Outcome | Current observed state | Active owner | Next required evidence |
| --- | --- | --- | --- |
| Windows native terminal/process/privacy behavior and installer | New `src/platform.zig`, Windows failure census; current release workflow still packages four macOS/Linux targets | Auth/platform | Wire shared call sites, implement Windows archive/installer workflow, run actual Windows/ConPTY E2E. A standalone module compile does not establish full application support. |
| Actual Omarchy desktop and Linux arm64 use | `docs/omarchy.md` provides installation and specific acceptance steps; arm64 currently cross-compiles | Root/platform environment | Real target execution and terminal/browser/notification artifacts. Do not relabel cross-compilation as desktop acceptance. |
| $99/user/year team seats, commercial terms and signed self-host receipts | New `cloud/team.ts`, `cloud/license.ts`, migration 0005; team-plan/commercial-license docs still describe proposal state | Team/sync accounts | Worker integration, terminal management, realistic isolation/seat/payment/receipt E2E, sandbox deployment, and truthful terms/version handling. Reconcile proposal docs once implemented. Production billing remains separate. |
| Provider OAuth and scoped incoming hosted task MCP | Existing hosted integration service accepts anonymous/user-provided bearer credentials; existing docs call OAuth future work | MCP cloud | Consent, refresh, revocation, callback attacks and incoming scoped task-access flows, then deployed real provider acceptance where consent exists. Existing bearer-token MCP checks do not cover OAuth. |
| Opt-in safe background sync | `src/sync.zig` now references `sync_background.zig`; root work-plan failure census is present | Root/sync design review | Final background module integration, timer ownership/cleanup and realistic two-writer conflicts, lost responses, credential changes and editor races. Explicit sync fixtures do not cover background convergence. |
| Linux reminder scheduling and portable calendar | Current reminders docs still describe manual Linux checks; existing calendar helper parses date/time | Sync accounts/local productivity | Opt-in scheduler installation/removal, device-local receipts, calendar round trip and timezone cases. Date parsing alone is not calendar export or scheduling. |
| Approval-gated bounded AI tool loops | New `src/ai_tools.zig` has dialects, typed catalog/hooks and explicit approval rule | Root | Wire selected provider and MCP catalog into real commands. Check denied/read-only/uncertain tool calls, bounded retries and integration results as untrusted data. Standalone module presence is not usable integration. |
| Live SSE display with no incomplete saves | New `src/streaming.zig` parser/sink | Root | Real request boundary integration and visible PTY streaming, cancellation, malformed/incomplete/error events, token sanitation and no task mutation on partial output. |
| Completed sandbox billing and production activation | Earlier payment page loaded, no submitted payment according to STATUS | Root/external billing gate | Explicit authorized payment/production setup. Fixture entitlement and deployed prices do not prove a completed payment. |

## Provider and licensing boundary

The current [OpenAI ChatGPT plan-usage guide](https://developers.openai.com/siwc/token-sharing-open-source) documents open-source and locally hosted apps. It directs paid or remotely hosted applications to an interest form. This is a provider-policy prerequisite, not an implementation defect that a simulated OAuth test can resolve. The current source-available personal-use license and optional paid service need their eligibility assessed before claiming universal ChatGPT plan support. Do not silently choose another app's client registration or reuse Codex credentials to bypass that boundary.

## Documentation reconciliation before handoff

1. Update STATUS and work-plan to the final version, binary hash, published archives and Worker deployment. Keep written, verified, published, installed and deployed states distinct.
2. Replace obsolete current-state wording in team-plan and commercial-license docs only after team implementation and acceptance land. Keep historical evidence clearly labeled.
3. Preserve the next public-installer receipt under a version-specific artifact path. The existing generic public-release receipt is v0.1.0.
4. Update README capabilities for Windows, Linux scheduling, automatic sync, provider OAuth, tool routing and streaming only after their actual release checks pass.
5. Keep live ChatGPT eligibility/consent, real microphone acceptance, actual Omarchy/arm64 execution and production billing visibly open when their required environment or authorization is missing. Do not convert them into fixture-backed completion claims.
