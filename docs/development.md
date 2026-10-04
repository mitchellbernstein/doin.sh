# Build notes

Pinned compiler: Zig 0.15.2. Core and terminal use its standard library; HTTPS is delegated to bounded `curl` children using system certificate trust. Credentials pass through stdin, not command arguments. No Zig package manager downloads are required. [Zig documentation](https://ziglang.org/documentation/0.15.2/)

The development Mac has macOS 27 and an SDK with arm64e-only libSystem targets. Its installed Zig cannot link its build runner against that SDK. A local wrapper tells Zig SDK discovery to fall back to the libSystem definitions it already bundles. This changes only the current build's PATH; it does not modify Xcode, SDK files, shell profiles, or the installed compiler:

```sh
mkdir -p .zig-cache/sdk-fallback
printf '#!/bin/sh\nexit 1\n' > .zig-cache/sdk-fallback/xcrun
chmod +x .zig-cache/sdk-fallback/xcrun
PATH="$PWD/.zig-cache/sdk-fallback:$PATH" zig build -Dtarget=aarch64-macos.15.0 -Doptimize=ReleaseSmall
```

Normal Linux CI uses `zig build -Doptimize=ReleaseSmall`. Releases cross-compile macOS using Zig's bundled definitions and Linux with musl. Minimum macOS deployment target: 15.0. Test native binaries on each target before broad release; cross-compilation alone does not verify execution on that platform.

Provider docs verified October 3, 2026:

- [Ollama chat endpoint](https://docs.ollama.com/api/chat): non-streaming local chat and model name.
- [Chat Completions API](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create): compatible API-key provider adapter.
- [ChatGPT registration](https://developers.openai.com/siwc/token-sharing-open-source/sign-in): dynamic client registration, PKCE, callback client identity, verified ID token.
- [ChatGPT inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference): account catalog, public Responses endpoint, `store=false`, `stream=true`, and completed-event validation.
- [ChatGPT session management](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions): rotating refresh and logout.

Responses streaming uses an incremental SSE parser with a live display callback. The parser bounds stream and event sizes, rejects refusals and incomplete streams, and checks that the completed response output matches displayed deltas. Partial display is never a document commit. The transport must feed the parser as bytes arrive and verify child success before accepting completion.

## AI integration failure census

Before automatic tool routing and incremental SSE implementation, verify these failure boundaries with real CLI E2E fixtures:

1. Unknown or duplicate tool aliases, unsupported provider tools, malformed arguments, multiple tool calls, repeated calls, unbounded tool loops, canceled approval, denied approval, and tool failure. Every attempted tool needs separate explicit approval; no automatic tool retry.
2. Read-only questions must offer only tools explicitly marked read-only. Missing annotations do not imply permission. Tool descriptions/results and task Markdown remain untrusted data, never system messages.
3. Partial SSE events, CRLF, multiline data, split UTF-8/control bytes, huge events/output, malformed JSON, provider refusal/error/incomplete response, absent completion, conflicting final text, cancellation, and disconnect. Displayed partial text never becomes a saved task without validated completion and normal preview approval.
4. Credentials stay in the request transport, not provider messages, task Markdown, tool arguments, or transcripts. Bound request count, tool count, bytes, overall deadline, and subprocess cleanup.

Primary docs: [OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling), [Responses streaming](https://developers.openai.com/api/docs/guides/streaming-responses), and [Ollama tool calling](https://docs.ollama.com/capabilities/tool-calling), checked October 3, 2026. Provider tool calls must be returned in the matching conversation format; Responses continuation preserves output items and uses `function_call_output` with `call_id`.


## Automatic integration tools

`doin assist SERVER REQUEST` selects one registered MCP connection for AI-assisted use. It does not start every configured server. Ordinary `ask` and `generate` keep integration tools disabled. Each model-selected tool requires a separate explicit terminal approval showing the actual server, tool, and arguments; declining returns a denial to the model. `--yes` on generation does not approve external tools. Assist displays its final answer without automatically appending task Markdown.

The adapter supports Ollama structured function arguments, Chat Completions function calls and `tool_call_id` replies, and Responses function calls and `function_call_output` replies. Responses continuation preserves returned reasoning and output items. Unsupported tool providers retain manual `/mcp call` access rather than executing model-generated text as a tool request. Tool descriptions/results are data and are never elevated to system instructions.

Limits: six provider rounds, eight tool calls, 120-second total operation deadline, 1 MiB conversation, 64 KiB arguments, 256 KiB tool results, and bounded schema/argument nesting. A repeated tool with structurally identical arguments is refused, including reordered object keys. Each transport receives the absolute deadline and must cancel/reap its owned process. After a failed or uncertain tool, further tools are disabled for the remaining operation; the model may only summarize. A failed mutation is never automatically retried with identical or changed arguments.

E2E commands: `python3 tests/ai_tools_e2e.py --bin zig-out/bin/doin` and `python3 tests/streaming_e2e.py --bin zig-out/bin/doin`. These use only temporary private configuration, loopback model/stdio integration fixtures, and an incremental curl shim. Results and reproducer receipts go to `artifacts/ai-tools-e2e/results.json` and `artifacts/streaming-e2e/results.json`. Implementation and fixture verification are separate release gates; do not treat written fixtures as a passing run.

Verification checkpoint: the macOS ARM64 ReleaseSmall build passed with Zig 0.15.2; real CLI AI-tool E2E passed 16 checks and streaming E2E passed 12 checks. The streaming suite first reproduced standalone SIGTERM being swallowed by an interactive-only cancellation guard; the terminal owner corrected that guard, and the full streaming suite then passed. `artifacts/streaming-e2e/before-cli-signal-fix.json` preserves the failure evidence. Process cleanup reported zero owned fixture survivors. This checkpoint verifies macOS fixtures, not live OpenAI/Ollama providers or Windows runtime execution.

Interactive argument failure census: quoted names and paths may split; JSON quotes may be stripped; unmatched quotes may partially execute; shell syntax may execute accidentally; natural-language assist requests may lose punctuation. Structured commands tokenize literal arguments without shell expansion; MCP JSON and assist request remainders retain their original bytes.

Custom-property UI failure census: task selectors can refer to fenced examples; typed values can be malformed or overflow; choices can contain whitespace; unknown/removed properties can leave stale metadata; cancelled pickers can accidentally write; malicious labels can inject terminal control sequences; undo can diverge from a concurrent task edit. Main must obtain pure proposals, validate against the current Markdown, and commit under the existing document lock/size/undo boundary. Values appear only when set, without empty table columns. Assignees require an active team and current eligible-member IDs; labels remain display-only, and remote membership/grant checks enforce push permissions independently.

Terminal resize behavior follows Foot's primary documentation: `resize-delay-ms` says Foot reflows the grid before reporting final dimensions to the client ([Foot configuration reference](https://codeberg.org/dnkl/foot/src/branch/master/doc/foot.ini.5.scd)). Its [grid implementation](https://codeberg.org/dnkl/foot/src/branch/master/grid.c) also remaps saved cursor coordinates during reflow. A footer cannot be retired using its old absolute rows. On a dimension change, doin archives the current viewport through full-screen scrolling, erases the active display with ED2, then resets the output region and redraws. Native history is retained; previous UI frames can remain there. It never uses ED3 to erase history. Unchanged short-screen prompts do not repeat this reset.

Reproduce `python3 tests/reflow_e2e.py --bin zig-out/bin/doin`. This drives a real PTY, carries the old grid through width reflow before feeding resize output to the existing ANSI renderer, and checks one active composer, Unicode draft preservation, unchanged Markdown, and prior help text in native history. The old binary's duplicate footer failure is retained under `artifacts/reflow-e2e/before-fix`; final receipts are under `artifacts/reflow-e2e`. This renderer is a targeted acceptance aid; actual Foot desktop screenshots remain required release evidence.

Agent-guidance integration failure census: existing user files may be replaced; stale config can target the wrong workspace after preview; root and selected folder can coincide; symlinks can redirect writes; partially failed creation must not claim success; generated guidance can contain private paths, credentials, or stale team membership; automatic guidance must not grant tool/server permissions. Fresh initialization creates only missing guidance without another onboarding prompt; older configurations opt in explicitly. Existing-content updates require preview/approval and byte comparisons under the guidance lock.

Primary discovery references: [Codex AGENTS.md guide](https://developers.openai.com/codex/guides/agents-md) says a workspace without a detected project root only checks its current directory. [Claude Code memory documentation](https://code.claude.com/docs/en/memory) now describes native AGENTS.md loading in recent versions and supports an adjacent `@AGENTS.md` compatibility import. Child guidance therefore stays self-contained, and the optional Claude bridge is an import rather than a permission mechanism.
