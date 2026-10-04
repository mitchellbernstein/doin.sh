# Implementation contract

Brand: doin.sh. Repository: mitchellbernstein/doin.sh. Executable: doin.

One native Zig executable, no Zig package dependencies. curl supplies HTTPS using system trust; OpenSSL supplies OAuth signature verification. No Node or Python application runtime. macOS and Linux are the initial release targets. The program has no daemon, telemetry, embedded model, or automatic model download.

Storage is a user-chosen folder containing tasks.md. Configuration and credentials live separately in the OS user configuration directory. First-run onboarding asks storage location before optional model configuration. Enter chooses defaults; AI can be skipped. Plain Markdown remains editable in any editor. Task numbers refer to the current list, not permanent IDs.

AI can answer questions about the file or generate Markdown to append. Ask never writes. Generation previews and asks before applying (explicit --yes for automation). AI never receives tools to execute shell commands, delete files, or overwrite the task document. API and ChatGPT send the document to the chosen provider; local mode uses a loopback-only endpoint with no hosted fallback.

Failure modes established before implementation: missing/unwritable storage; unknown provider or invalid URL; invalid task numbers; multibyte or terminal-control text; Markdown code blocks confused for real tasks; API failures/refusals/malformed bodies/incomplete streams; noninteractive accidental AI write; external changes during AI generation; multiple concurrent app writers; stale undo wiping external edits; credentials leaking in arguments/config output; interrupted file writes; cancelled onboarding; unavailable auth tools/expired grants; wrong release archive or checksum.

Verification is black-box E2E with the compiled executable, isolated real files, a local HTTP fixture, and retained replayable artifacts. Mock-provider checks prove protocol and persistence behavior, not live model quality or real subscription eligibility. Live account sign-in is a separate user-driven check.
