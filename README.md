# doin.sh

A tiny native terminal home for tasks and notes. Plain Markdown. Optional AI. Yours to edit.

**Tiny terminal tasks. Markdown storage. Your choice of AI.**

Early terminal release for macOS, Linux, and Windows. Native Apple apps are development builds, not published releases. The [Mac app](macos/README.md) uses the iOS app's Markdown library and services with a native window or menu bar interface.

```text
  1  [ ]  Review migration
  2  [ ]  Dry run restore
  3  [x]  Capture baseline

› generate turn my launch notes into a checklist
```

Personal **doinMORE** is $4.99/month or $49.99/year for managed sync and hosted integrations. **doinWITH** is $99/user/year for licensed team collaboration and commercial self-hosting. User-supplied AI, local voice, manual task management, custom properties, agent guidance and local MCP are free. Your local model or provider account supplies inference; model usage is not included. Managed sync across terminal and Apple apps is paid; App Store purchasing and macOS app distribution are separate work. See [plan policy and delivery](docs/paid-ai.md).

## Run locally

Requires Zig **0.15.2** to build. No Zig package dependencies. Runtime: macOS, Linux, or Windows. Manual commands need only the binary. User-supplied AI and local voice need no doin subscription. AI needs `curl`; ChatGPT sign-in also needs `openssl` and a browser.

```sh
zig build -Doptimize=ReleaseSmall
./zig-out/bin/doin
```

First run asks **where to store your Markdown**, then offers **Simple** (a straight list), **Custom** (your first folder), or **Templates** (Projects or Areas), followed by **manual**, **local Ollama**, **API key**, or **Continue with ChatGPT**. Enter skips AI. Default storage is `~/Documents/doin/tasks.md`; use any folder, including a Git or sync folder. Existing `tasks.md` is preserved.

On macOS with a newer SDK unsupported by Zig 0.15.2, use the task-local SDK fallback described in [development](docs/development.md). Downloaded binaries do not need Zig or an SDK.

On macOS and Linux, run `doin update` to install a newer public release into the current executable location. It works before setup, verifies the release archive against `SHA256SUMS`, and preserves tasks and settings. Current or newer installed versions stay in place. Download or verification failures leave the installed binary untouched. Release discovery follows the [GitHub Releases API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release).

Run `doin uninstall` to remove the terminal executable and its settings, even before first setup. Confirm the uninstall, then answer whether to delete the listed task folders and ALL their contents; answering no keeps them. Cancelling either question removes nothing. Unrelated tools and config files stay in place. The filesystem cleanup uses the matching [Zig 0.15.2 APIs](https://ziglang.org/documentation/0.15.2/).

## Everyday use

```sh
doin add 'Review the migration'
doin list
doin done 1
doin reopen 1
doin note 'Release deadline: Friday. Budget: $300.'
doin ask 'What should I tackle first?'
doin generate 'Create a release checklist from my notes'
doin undo
```

Run `doin` with no arguments for the editable composer and sectioned task board. First-run storage selection recommends `~/Documents/doin`. Choose “Select a folder…” to browse your home folders inside the terminal. Up/Down moves the highlight; Right or Enter opens a folder; Left goes to its parent; Alt+Left/Right revisits folder history. Type to filter folder names, Backspace to edit, or Ctrl+U to clear the filter. Select “Use this folder” to confirm. Escape returns to the storage choices. Type `/help` for commands or `/quit` to exit. Arrows edit your draft; Up recalls commands. On supported terminals, the composer stays at the bottom with output above it, including during onboarding and command processing. Scrollback retention with a reserved output region depends on your terminal emulator. Task numbers refer to the current Markdown order. Edit the document in any editor; app changes preserve the rest of the file. Checkboxes inside fenced code examples are excluded. Undo refuses to replace a document that changed externally. A successful undo can itself be undone.

Use `/today`, `/week`, or `/month` for dated open tasks, including overdue tasks. `/filter` narrows tasks by due period, status, priority, group, or text. Defaults are `todo`, `doing`, `blocked`, and `done`; `/statuses` lists them and supports adding, renaming, and removing custom statuses. `/mark 2 waiting` assigns a registered status; `/status waiting` shows matching tasks. Status definitions travel in the Markdown document. Removing a status still in use requires a replacement; `todo` and `done` retain checkbox semantics.

`/unblock 2` asks your selected AI for a focused next step without changing tasks. `/review` and `/prioritize` inspect open tasks and explicit priority hints. `/visualize` shows grouped completion with arrow-key navigation. `/delete` and `/clear` preview changes before saving. See [productivity commands](docs/productivity.md).

Use `/focus` to decide on one task for today. Your selected AI recommends an open task, explains why, and suggests a concrete first step. Accept the suggestion or choose another with the arrow-key picker. `/focus pick` asks again; `/focus manual` skips AI; `/focus N` selects a task by its current number. `/focus status` shows the chosen task, `/focus step ...` records a next action, `/focus done` completes only that task, and `/focus off` restores the full board. AI-off and failed recommendations use the picker. Daily focus stays private to this device and expires at the next local midnight.

Optional `/remind` commands attach reminder times to tasks. Notification settings and delivery history stay on each device. macOS can schedule a short check every minute while doin is closed; Linux uses an optional systemd user timer; Windows uses an optional per-user scheduled task. Scheduling is off until enabled. Synced reminders reach another device after a sync pull or an enabled background check; each device controls its own notification delivery. See [reminders](docs/reminders.md).

An empty document shows an original neutral ASCII placeholder with a rotating orbit. It stops on your first interaction. Set `DOIN_NO_ANIMATION=1` for a static frame; small or plain terminals omit the art.

AI generation shows a preview and asks before appending. For intentional scripting: `doin generate 'Draft a checklist' --yes`. `add` stays literal and instant; use `generate` for natural-language task extraction or longer notes. AI can use explicitly connected MCP tools through `/assist`; each tool call requires approval. It has no automatic shell or filesystem access. `ask` is read-only. AI sees the full `tasks.md` (up to 1 MiB); it does not scan other folders. Provider/network latency is separate from native CLI startup.

## Folders and properties

Simple starts with one list. `/folder` creates, selects, renames or moves nested folders; each folder has its own Markdown document and a stable identity. Folders can represent projects, recurring work or anything else. Team folder access includes descendants.

Everyone can define optional text, number, date, single-select, multi-select and Boolean properties with `/properties`. `/set`, `/unset` and `/filter property` manage values. Schemas and values travel with Markdown. Destructive schema changes preview their effect; undo preserves external-edit safety. Teams add `/assign` with members who can access the selected folder. See [folders](docs/folders.md) and [properties](docs/properties.md).

## Agent guidance

Fresh libraries create missing `AGENTS.md` files at the root and in folders. They describe the Markdown contract, preserve stable IDs and properties, and tell agents to reread current contents and check authority before editing. Existing user-written files are preserved. Older libraries opt in with `doin agents init`; `doin agents update` previews managed changes, and `--claude` adds an optional compatibility import. Local and hosted MCP provide matching advisory guidance. The service enforces team permissions; an instruction file cannot grant access. See [agent guidance](docs/agent-guidance.md).

## Choose your model

`/provider` opens the arrow-key provider picker and restores each provider's saved model and endpoint. `/model` changes the model. `doin login PROVIDER` connects an account; `doin logout PROVIDER` clears its local credentials and attempts supported remote revocation. [Provider setup and requirements](docs/providers.md).

- **Manual:** every task command works without AI or network.
- **Ollama:** pick an installed model, or enter its name. Defaults to `http://127.0.0.1:11434`. No model downloads or server startup happen behind your back. Local endpoints must use loopback; no cloud fallback. For strict local inference, disable Ollama cloud features using `OLLAMA_NO_CLOUD=1` in its server environment and restart Ollama. [Ollama FAQ](https://docs.ollama.com/faq#how-do-i-disable-ollama-cloud-features)
- **Custom API:** choose an OpenAI Chat Completions-compatible HTTPS base URL and model. Set `DOIN_API_KEY` (or `OPENAI_API_KEY`), or enter a hidden key during setup. Saved keys live in private credential files separate from configuration. Loopback HTTP supports local compatible servers such as LM Studio.
- **ChatGPT:** browser OAuth implements OpenAI’s documented direct client flow. Eligibility with this personal-use license and real account consent remain unverified. Eligible ChatGPT plans and granted plan-usage permission are required. Select a model from your account's current catalog. No Codex installation or credential copying. Subscription limits apply. [OpenAI guide](https://developers.openai.com/siwc/token-sharing-open-source)
- **Grok, Vercel Gateway, OpenRouter:** account sign-in flows. Grok and Vercel need registered doin OAuth client IDs; OpenRouter creates a key through browser consent. Vercel and OpenRouter also accept existing API keys.
- **GitHub Copilot:** official CLI login and SDK runtime; model tools are disabled. Requires Copilot access, Node, and the optional SDK.
- **Cloudflare, DeepSeek, OpenAI, Groq, Mistral, Together, Fireworks:** named API connections. Cloudflare needs your gateway endpoint and token. Claude account login is excluded.

Hosted providers receive task contents when you run an AI command. Manual mode makes no requests. Local models remain subject to your local server's configuration.

## Local voice

Type `/voice` to record with the optional [Whistle helper](docs/voice.md). Transcription runs locally and fills an editable draft. Review it before submitting. Recording stops with Enter or after 30 seconds; Ctrl-C discards it. Voice adds optional Python, microphone, engine, and model dependencies. The core executable does not download them.

Whistle recognizes speech. Your selected AI handles the resulting text after submission. Choose a local AI provider to keep both steps local.

## Optional device sync

The free app stores Markdown locally and needs no account. An optional account service and terminal sync client are implemented for **$4.99 USD/month or $49.99 USD/year** device sync. Email sign-in is deployed; billing remains in Stripe test mode. Use `/upgrade` to choose monthly or yearly. Production billing remains required.

Type `/account` for account management in the terminal. Sign-in uses your email and a magic link; no GitHub account is required. The browser confirms the email link and handles secure Stripe payment entry. Status, devices, sign-out and subscription controls remain in doin.

The client uses explicit `doin sync push` and `doin sync pull` commands. Conflicts preserve both copies; cancellation preserves local files. See [terminal sync](docs/sync-client.md) and [service deployment](docs/sync.md). AI credentials stay separate from sync credentials. Billing secrets exist only in the hosted Worker; downloaded executables and this repository contain no service credentials.

## doinWITH and self-hosting

**doinWITH** uses annual **$99 USD/user** seats, shared folders, inherited folder permissions and assignees. `/team` manages membership, invitations, billing and linked workspaces. Personal self-hosting is permitted; company/team use requires a commercial license. Paid teams can self-host using a signed commercial receipt. Billing is currently sandbox-only; the new team deployment is pending. See [teams](docs/team-plan.md) and [self-hosting](docs/self-hosting.md).

## MCP

Expose your configured tasks to Codex or Claude Code with `doin mcp serve`; add `--allow-write` for revision-checked task edits. It uses stdio and needs no background daemon or model.

Connect doin to a local server with `doin mcp add NAME -- EXECUTABLE ARG...`, inspect it with `doin mcp tools NAME`, and explicitly invoke a tool with `doin mcp call NAME TOOL '{"argument":"value"}'`. `/mcp` works inside the TUI too. Local personal use is free.

`doin mcp cloud` manages doinMORE hosted integration connections. It supports anonymous or user-supplied bearer-token providers; provider OAuth, terminal approval of incoming task access, and explicitly approved AI tool calls are implemented. Hosted deployment requires the OAuth KV binding. [Local task server](docs/mcp-local.md), [local client](docs/mcp-client.md), [hosted integrations](docs/mcp-cloud.md).

## Customize

`doin config` shows settings and their location; `doin path` prints the Markdown path. Configuration defaults to `$XDG_CONFIG_HOME/doin/config.json`, or `~/.config/doin/config.json`. Set `DOIN_CONFIG_DIR` for an isolated profile. ChatGPT credentials live beside configuration, separate from your Markdown, with owner-only permissions.

```json
{
  "storage": "/absolute/path/to/my-notes",
  "provider": "ollama",
  "model": "your-installed-model",
  "endpoint": "http://127.0.0.1:11434",
  "system_prompt": "Keep answers short. Prioritize small next actions."
}
```

Edit configuration to change storage, provider, model, or instructions. `doin init --storage /absolute/path --provider manual` also configures a folder noninteractively. Changing storage selects a document; it does not move or delete your previous folder. Hidden `.tasks.*` files in storage hold the write lock and one-step undo. Keep those files private too if your document is private.

## Download and install

Release automation prepares macOS arm64/x86_64, Linux arm64/x86_64, and Windows x86_64 archives with SHA-256 checksums. Download an archive from [Releases](https://github.com/mitchellbernstein/doin.sh/releases/latest), or download and run the checksum-verifying installer:

```sh
curl -fsSL https://raw.githubusercontent.com/mitchellbernstein/doin.sh/main/scripts/install.sh | sh
```

Default install location: `~/.local/bin`; override `DOIN_INSTALL_DIR`. Updates require explicit `DOIN_REPLACE=1`. Download binaries from [GitHub Releases](https://github.com/mitchellbernstein/doin.sh/releases/latest). Windows uses the checksum-verifying PowerShell installer in `scripts/install.ps1`; its default location is `%LOCALAPPDATA%\doin\bin`. Add that folder to your user PATH. Omarchy users can use the same Linux installer; see [Omarchy installation and validation status](docs/omarchy.md).

## Evidence and development

[Reproducible E2E scenarios](docs/testing.md), [OAuth behavior](docs/auth.md), [design and limits](docs/design.md). Local HTTP fixtures verify integration behavior; they do not establish real subscription entitlement or model quality. A live browser login and real provider requests remain a separate release verification step.

Source available under the [doin.sh Personal Use License](LICENSE): free personal, noncommercial use, modification and self-hosting. Companies and teams need a paid commercial license to self-host or use team features; licensed teams can self-host. Selling copies or modified versions is prohibited unless separately authorized. Team licensing is planned and is not available for purchase yet. This is not an OSI open-source license. Earlier MIT releases retain their original permissions; see [license details](docs/license.md). Inspired by fx's native Zig approach; this project does not embed or vendor fx.
