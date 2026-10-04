# Local MCP task server

Failure census recorded before implementation: malformed/oversized JSON lines; wrong lifecycle/version; unknown requests; notifications accidentally producing responses; stdout diagnostics; unexpected EOF; invalid UTF-8; task Markdown inside code fences; ambiguous task numbers after edits; control/newline injection; unknown operation fields or arbitrary paths; read-only bypass; concurrent editor/app writes; lost undo; oversized resulting document; folder isolation; reminder metadata without implicit network/device notifications.

Implemented entry point: `doin mcp serve` over stdio, read-only by default. `--allow-write` explicitly exposes typed task mutations. Existing configured storage is required; the server does no onboarding and opens no network listeners.

Primary protocol references: [MCP 2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools), [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

E2E command: `python3 tests/mcp_e2e.py`. Retained transcript, document, undo and result artifacts live in `artifacts/mcp-e2e/`. Tests drive the compiled CLI with real pipes and isolated files, no models/accounts/providers.

## Client registration

Use the absolute path to your installed `doin` executable:

```json
{"mcpServers":{"doin":{"command":"/absolute/path/to/doin","args":["mcp","serve"]}}}
```

For approved task writes, add `"--allow-write"` to the argument array. Configuration is read from the usual doin config directory; setting `DOIN_CONFIG_DIR` explicitly isolates another task folder. No tool accepts a path, executable, model, credentials or account identifier.

`doin_read` returns `{revision,markdown,tasks}`; `doin_list` returns `{revision,tasks}` and accepts optional `completed`, `status` and literal `text` filters. Each task has its current `number`, `text`, `completed`, `status` and `group`. Revision is SHA256 of the exact UTF-8 document bytes.

Writes all require that revision: `doin_add {text,revision}`, `doin_complete {number,completed,revision}`, `doin_status {number,status,revision}`, and `doin_reminder {number,time,revision}`. Status must be registered in the document. Reminder time uses existing doin formats such as `in 15m` or `off`; this tool saves portable metadata and does not implicitly enable notifications on this device. Successful mutations return the committed revision and tasks. Read again after a conflict before choosing the correct task number.

Writes reuse the main app's exclusive lock, exact-content comparison, atomic save and undo records. External edits may advance immediately after a successful write, so the returned revision describes the committed snapshot rather than promising the file will stay unchanged. Tool errors use MCP `isError:true`; malformed protocol messages use JSON-RPC errors. Messages are limited to 64 KiB per line, documents to 1 MiB, and tool calls to 128 per second per session. EOF exits cleanly and unfinished messages never execute. The server supports protocol `2025-11-25`; other requested versions negotiate that supported version, and clients that cannot support it should disconnect.

Local MCP requires no doin model or hosted account. Personal local use is free under the repository LICENSE; company/team use requires the paid commercial license described there. The MCP client's model determines whether task text leaves your computer. Clients should retain their approval prompts for write calls; `--allow-write` grants this server capability and does not replace client consent.

Verification: native macOS ARM64 compiled CLI passed the stdio E2E groups, including actual lock/undo files, external revision conflicts and EOF shutdown. No model or live account was used. Other release platforms require their usual cross-build and runtime checks; this result proves the local macOS execution only.
