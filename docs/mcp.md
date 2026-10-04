# MCP support

Status: shipped in public v0.2.4, verified and installed; hosted Worker deployed. The owner confirmed both directions, with local use free and doin-hosted integrations paid.

## The product boundary

| Capability | Free local app | doinMORE |
| --- | --- | --- |
| Expose local Markdown tasks to Codex, Claude Code, or another MCP client | Yes | Yes |
| Connect doin to user-configured local MCP servers | Yes | Yes |
| Route integrations through doin's hosted service | No | Yes |

The subscription pays for doin's hosting and account integrations. Personal local MCP use is free. Business or team self-hosting requires a separate paid commercial license; see [team proposal](team-plan.md). Monthly and yearly plans get the same hosted integration features. Provider fees, quotas, and required subscriptions remain separate.

## Start with the native local server

The `doin mcp serve` entry point runs the existing binary over stdio. The calling MCP client starts and stops it. It needs no account, network listener, background daemon, or Node application runtime. MCP messages alone use stdout. Diagnostics use stderr. This follows the [MCP stdio transport specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

The first tools cover reading tasks, filtering tasks, adding tasks, and changing completion, status, or reminder metadata. They operate on the configured storage folder. They do not accept arbitrary file paths or execute shell commands. Read access is the default. Users explicitly enable task writes when registering the server. Client approval remains available for individual tool calls.

Each read returns a document revision and task references tied to that revision. A write targeting an existing task requires that revision. The current task numbers change when Markdown changes, so treating them as permanent IDs would let an agent modify the wrong task. The adapter must reuse the existing file lock, comparison against current contents, atomic write, and undo behavior in `src/main.zig`.

Local MCP requires no doin AI model. Codex or Claude Code can bring its own model. Those clients' model choices determine whether task contents leave the computer.

## Add the local MCP client separately

The `/mcp` commands list connections, add a connection, inspect its tools, disconnect, and remove it. Local stdio connections store an executable and argument array, not a shell string. Servers launch only when needed and stop on disconnect or app exit. Credentials stay in private configuration outside task Markdown and sync documents.

Tool calls require explicit permission. A model must support the selected tool-call format before doin offers AI-driven integration actions. Manual invocation can remain available without an AI model. Imported tool descriptions and results are data, not authority to change local files or invoke another tool.

## Keep hosting out of the native app

A Cloudflare Worker integration module owns remote MCP connections. A hosted task server is a separate future proposal that requires full scoped OAuth. Cloudflare documents both [MCP clients](https://developers.cloudflare.com/agents/model-context-protocol/apis/client-api/) and [MCP server handlers](https://developers.cloudflare.com/agents/model-context-protocol/apis/handler-api/). Use the supported libraries there rather than copying OAuth and HTTP transport machinery into Zig.

The existing doin email account identifies the user. Each external integration has its own consent and credentials. This gateway currently supports anonymous providers or an integration-specific bearer token supplied by the user. It does not implement provider OAuth consent. Providers requiring OAuth need a future authorization adapter following [MCP HTTP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization). The terminal manages connections and revocation.

Hosted integration usage checks account ownership and the current paid entitlement on the server. Authenticated owners can erase their stored connection even after payment expires or billing becomes unavailable. Cancellation keeps access through the paid period. Expiry blocks hosted operations while local features continue. Third-party tokens need encrypted per-account storage and must never enter downloads, the public repository, task Markdown, or AI requests.

Hosted calls invoke explicitly selected tools on the configured external integration server. They do not expose or mutate doin task documents, or reach local files. Tool output is untrusted data. Automatic AI tool routing and a hosted incoming task MCP server are future work.

## Delivery order and evidence

1. Ship and verify the local task server with real stdio initialization, discovery, reads, and guarded writes.
2. Add local server connections and explicit tool invocation in the TUI.
3. Add authenticated hosted integration discovery and explicit calls behind the paid entitlement. Incoming hosted task access remains future work.

Failure scenarios must be written before implementation. E2E evidence must cover malformed and oversized messages, clean stdout, disconnect cleanup, Unicode and fenced Markdown, stale references, concurrent TUI edits, task undo, denied writes, and isolation between storage folders. Hosted scenarios add expired grants, revoked integrations, cross-account requests, unpaid accounts, billing outages, and paid-period expiry. Client scenarios add subprocess failures, timeouts, cancellation, unsupported model tool calling, and malicious tool output. Save transcripts, resulting documents, process cleanup, and reproducible commands.

Laziness Protocol keeps local support inside the native binary and moves hosted protocol libraries into the Worker. Boundary Discipline puts authorization and paid entitlement checks at each server request, rather than trusting the terminal menu.

Throughput checkpoint: native server, native client, and hosted integration gateway are separate implementation lanes. Heavy checks run serially. Team design is independent. No actual user integration has been connected.
