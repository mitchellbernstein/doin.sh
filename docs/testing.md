# Reproducible behavior tests

Tests were defined before implementation. They run the real compiled program and a real loopback HTTP provider fixture. Python is a development-only dependency, not an application runtime dependency.

```sh
zig build -Doptimize=ReleaseSmall
python3 tests/e2e.py
```

Evidence is written to `artifacts/e2e/results.json` and `artifacts/e2e/transcript.md`. The JSON includes the tested binary's SHA-256, commands, exits, provider requests, and failure details. No real credentials or remote model calls are needed.

The scenarios cover a launch checklist mixed with notes, links and Unicode; external Markdown edits; task completion and reopening; bad indexes; undo; literal shell characters; AI context; read-only questions; generation preview rejection; HTTP failure; concurrent edits during inference; and Ollama/OpenAI-compatible requests. Interactive onboarding and real provider authentication additionally need manual verification before release.

## Failure modes considered first

- Invalid storage location or provider configuration.
- Lost external Markdown edits, malformed Unicode, or shell interpolation.
- Invalid indexes changing unrelated tasks or incorrect undo snapshots.
- Questions writing content, or generation saving without confirmation.
- HTTP failures or concurrent edits resulting in partial or lost data.
- Configuration output exposing credentials.
- Wrong platform downloads, checksum failures, or overwriting installed files.

## Distribution

Release workflows cross-compile Zig 0.15.2 for macOS and Linux, both arm64 and x86_64. Tagged releases attach archives and SHA-256 checksums. CI retains test evidence even on failure. A maintainer must inspect native platform behavior before claiming all platform builds tested; cross-compilation alone does not establish that.

Primary references: [Zig 0.15.2](https://ziglang.org/documentation/0.15.2/), [GitHub release API](https://docs.github.com/en/rest/releases/releases), [GitHub workflow artifacts](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts).

## Installer and auth checks

`python3 tests/auth_e2e.py` drives the real CLI OAuth listener using an isolated HTTPS provider shim and real RSA/OpenSSL validation. It records identity, nonce, signature, scope, refresh, logout, and permission behavior under `artifacts/auth-e2e`. No real account or provider tokens are used.

After `sh scripts/package.sh`, run `python3 tests/install_e2e.py` for real-archive installation, checksum rejection, destination preservation, and explicit updates. It uses an isolated download shim and executes the installed native binary. Evidence is under `artifacts/install-e2e`.

Manual list startup benchmark: 100 serial subprocess calls against a new default Markdown file, warm filesystem cache. Results are saved to `artifacts/benchmark.json`; this does not measure model latency or large documents.

## Terminal, accounts and sync

```sh
python3 tests/tui_e2e.py
python3 tests/productivity_e2e.py
python3 tests/reminders_e2e.py
python3 tests/sync_client_e2e.py
npm ci --prefix cloud
npm test --prefix cloud
python3 tests/sync_client_e2e.py --worker
```

Run these sequentially. PTY scenarios exercise the actual executable's editing, history, Unicode, resizing, manual and AI behavior, voice drafts, account menus and cancellation. They preserve raw recordings, decoded screens and terminal-restoration receipts under `artifacts/tui-e2e`. Pillow is optional for PNG rendering; behavior checks do not depend on it.

Footer scenarios render actual cursor positioning and scrolling margins, including onboarding, model popups, long output, height-only and tiny-to-large resize, idle animation, notes-only content and motion opt-out. Slow local AI and email-poll requests prove signal handling resets margins immediately and reaps owned curl processes. A test-only curl wrapper rejects non-loopback request URLs before forwarding allowed fixture requests to real curl; an intentional denial probe verifies the guard itself. These fixtures do not send hosted login emails or verify real accounts.

Productivity scenarios cover grouped tasks, dates, custom-status creation/assignment/filtering/rename/removal, fenced examples, reminders, undo, cancellation, and document-limit rejection preserving both undo files. Receipts are under `artifacts/productivity-e2e`. Reminder scenarios cover portable metadata, independent device delivery history, explicit opt-in, completed/deleted tasks, local-time validation, failed delivery and hung child cleanup. They use notification adapters rather than sending real OS notifications or installing persistent jobs; receipts are under `artifacts/reminders`.

Sync scenarios preserve HTTP and real Worker/D1 integration receipts under `artifacts/sync-client`. The combined scenario starts two isolated native clients, verifies synthetic email approvals, exchanges Markdown, creates stale revisions, preserves conflicting local content and revokes device access. Provider fixtures do not prove actual email delivery or Stripe payment acceptance.

The backend runs the real Worker bundle in workerd with D1. Email and Stripe outbound calls use isolated fixtures. Its failure census and artifact are in `cloud/tests/FAILURES.md` and `cloud/artifacts/e2e.json`. See [sync deployment](sync.md) for acceptance boundaries and [voice](voice.md) for the optional real speech-engine checks.

CI retains native and Worker evidence. Publication requires passing native behavior and installer checks; live service activation also requires provider configuration and a separate real test-mode acceptance check.

## MCP

Run `python3 tests/mcp_e2e.py`, `python3 tests/mcp_client_e2e.py` and `python3 tests/mcp_cloud_client_e2e.py` sequentially against the compiled binary. They preserve real stdio protocol transcripts, resulting Markdown, subprocess cleanup receipts and loopback gateway requests under `artifacts/`. Local server checks include revision conflicts, held locks, undo, Unicode, metadata, read-only access and malformed messages. Local client checks include pagination, explicit calls, timeout and cancellation with stubborn descendants.

`npm test --prefix cloud` includes `cloud/tests/mcp-e2e.mjs`: real Worker/D1 and the pinned MCP client SDK, with isolated Stripe/DNS/remote MCP fixtures. It covers account isolation, encrypted credentials, paid gates, revocation after expiry, persistent SSE, pagination and bounded responses. No actual user integration is connected by these checks.
