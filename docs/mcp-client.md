# Local MCP client

## Failure census before implementation

A configured command can be misquoted or accidentally run through a shell, names can collide or resolve another server, config/temporary files can expose arguments, concurrent edits can overwrite connections, and adding/listing can unexpectedly launch a process. A server can print invalid JSON or banners, fragment messages, send the wrong ID/version, omit tool capabilities, paginate forever, inject terminal controls, flood stderr/stdout, hang without consuming stdin, close early, fail a tool, exit nonzero after a response, or fork children that outlive cancellation. Cancellation during initialize, discovery or call must never trigger a retry or a second tool call. Invalid tool arguments/names must fail before tools/call. AI/manual mode must work equally; no task document is sent automatically.

## Interface and boundary

`doin mcp list`, `add NAME -- EXECUTABLE ARG...`, `tools NAME`, `call NAME TOOL JSON`, and `remove NAME` use a private named stdio connection config. Arguments are passed directly to the executable, never interpreted by a shell. A configured server is a program you trust: it retains your user permissions and inherited environment, including any network access it independently uses. doin itself sends only MCP protocol messages and the explicit JSON arguments you request. It does not send your task Markdown, execute AI tool requests, or advertise sampling/resources/elicitation capabilities.

Primary sources checked: MCP [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [lifecycle/version negotiation/shutdown](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), and [tools discovery/call](https://modelcontextprotocol.io/specification/2025-11-25/server/tools), version 2025-11-25. The tiny client supports that version, JSON-RPC2.0 newline framing, initialized notification and paginated tool lists. Unsupported server requests receive method-not-found rather than invoking local capabilities.

Each tools/call operation starts its server on demand and shuts it down. Requests share an absolute timeout (default10seconds; `DOIN_MCP_TIMEOUT_MS`100..30000),1MiB message/output bound,256protocol-message bound,32catalog pages/512tools and4KiB captured stderr. Shutdown closes stdin, waits briefly, then signals only the owned process group and reaps its leader. Server logs/results are terminal-sanitized. Timeout/cancellation sends a best-effort notification for ordinary requests, never for initialize, then closes the transport; a tool already sent may have taken effect, so the client never retries it. Config is atomically saved mode0600; lockfile prevents lost edits. Tokens should be supplied through the server's own environment/authentication setup, not command-line arguments visible to process inspection.

## Reproducible E2E

`python3 tests/mcp_client_e2e.py --bin zig-out/bin/doin` drives the actual CLI against real executable fixtures. Artifact `artifacts/mcp-client-e2e/results.json` records commands, protocol transcripts, file permissions and process cleanup. No live provider account or external network is used. CLI call results represent one explicitly authorized tool invocation; tool errors are reported without retry.

Cancellation behavior also checked against the primary [2025-11-25 cancellation spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation): initialize cannot be cancelled; ordinary in-flight requests can receive a best-effort cancellation notification before transport shutdown.

Verification: the native 0.2.4 CLI passed all four real subprocess E2E groups, including actual client-to-doin-server interoperability, fragmented paginated discovery, exact argument preservation, private configuration, malformed/oversized output, stderr flooding, tool failure, deadline shutdown and SIGTERM during an active call. Receipts and provider transcripts are in `artifacts/mcp-client-e2e/`. No external service was contacted.
