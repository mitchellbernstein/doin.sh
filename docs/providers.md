# AI providers

Use `/provider` in the terminal to choose a connection. Up and Down move the highlight; Enter selects; Escape cancels. Manual is the first recommended option. Each provider remembers its model and endpoint when you switch away and return. `/model` changes the selected model.

For scripts, use `doin provider deepseek --model deepseek-chat`, or `doin provider api --model your-model --endpoint https://your-server.example/v1`. Noninteractive selection configures the provider; `doin login PROVIDER` starts account sign-in. `doin logout PROVIDER` disconnects it.

| Provider | Connection |
| --- | --- |
| Manual | No AI or network |
| Ollama | Installed local model, loopback server |
| ChatGPT | Browser OAuth; eligible account and granted plan usage required |
| Grok | Browser OAuth; eligible account and a registered public doin OAuth client |
| Vercel AI Gateway | Device sign-in, Gateway API key, or Vercel OIDC token |
| OpenRouter | Browser sign-in creates a private API credential, or use an existing API key |
| GitHub Copilot | Official Copilot CLI login plus optional official SDK runtime |
| Cloudflare AI Gateway | Your account/gateway endpoint and API token |
| DeepSeek, OpenAI, Groq, Mistral, Together AI, Fireworks AI | Provider API key |
| Custom API | OpenAI Chat Completions-compatible base URL and key |

Claude account login is excluded. Models offered through gateways follow the gateway's own billing and permissions. A ChatGPT, Grok, or Copilot subscription does not pay for Gateway requests.

## Account setup

OpenRouter's [PKCE flow](https://openrouter.ai/docs/guides/overview/auth/oauth) supports a local browser callback without registering a client application. The resulting key uses your OpenRouter credits. Disconnecting deletes the local credential; revoke it in OpenRouter account settings when required.

Grok requires `DOIN_GROK_CLIENT_ID` for a registered public OAuth client authorized for the Grok subscription proxy. Vercel device sign-in requires `DOIN_VERCEL_CLIENT_ID` for a registered public OAuth client with device authorization enabled. Doin does not reuse fx's client identities. Without those registrations, the respective login reports a setup requirement. Vercel can also use `AI_GATEWAY_API_KEY` or `VERCEL_OIDC_TOKEN`. Set `DOIN_VERCEL_TEAM_ID` to select your team's Gateway billing scope. See [Vercel authorization server](https://vercel.com/docs/sign-in-with-vercel/authorization-server-api), [Gateway authentication](https://vercel.com/docs/ai-gateway/authentication-and-byok), and [fx's authentication reference](https://fx.sh/docs/getting-started/authentication).

OAuth uses fixed trusted API endpoints. An endpoint override is rejected for account providers, including when an environment key is supplied. Local credential files are private, provider-specific, and separate from `config.json`. Failed or cancelled provider configuration leaves the active provider unchanged. Tokens are refreshed when needed; a refresh failure requires sign-in again.

## API credentials

Environment variables take precedence over saved keys:

| Provider | Variable |
| --- | --- |
| Custom API | `DOIN_API_KEY`, with `OPENAI_API_KEY` fallback |
| Vercel | `AI_GATEWAY_API_KEY`, then `VERCEL_OIDC_TOKEN` |
| OpenRouter | `OPENROUTER_API_KEY` |
| Cloudflare | `CLOUDFLARE_API_TOKEN` |
| DeepSeek | `DEEPSEEK_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| Groq | `GROQ_API_KEY` |
| Mistral | `MISTRAL_API_KEY` |
| Together AI | `TOGETHER_API_KEY` |
| Fireworks AI | `FIREWORKS_API_KEY` |

Interactive API setup accepts a hidden key and stores it in a private credential file. Model names are selected explicitly because account catalogs and aliases change. Hosted AI commands send the current Markdown document to the selected provider.

Cloudflare's current [REST API](https://developers.cloudflare.com/ai-gateway/usage/rest-api/) supports the base URL `https://api.cloudflare.com/client/v4/accounts/ACCOUNT_ID/ai/v1`, with a Cloudflare token and the account's default gateway. Existing `/compat` gateway URLs also work, though Cloudflare deprecated them for new single-model integrations. Configure the full base URL and enable stored provider keys or [unified billing](https://developers.cloudflare.com/ai-gateway/features/unified-billing/) as appropriate. Doin does not offer Cloudflare consumer account login.

Provider presets follow official API documentation: [DeepSeek](https://api-docs.deepseek.com/), [OpenAI](https://platform.openai.com/docs/api-reference), [Groq](https://console.groq.com/docs/openai), [Mistral](https://docs.mistral.ai/api/), [Together AI](https://docs.together.ai/docs/openai-api-compatibility), and [Fireworks AI](https://docs.fireworks.ai/api-reference/introduction).

## Copilot runtime

Install the [official Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli) and Node 20.19+ or 22.12+. Install the optional SDK into your doin configuration's `copilot` directory:

```sh
npm install --prefix "$HOME/.config/doin/copilot" @github/copilot-sdk@1.0.16
doin login copilot
doin provider copilot --model auto
```

If you set `DOIN_CONFIG_DIR` or `XDG_CONFIG_HOME`, use that configuration directory's `copilot` subdirectory for the install. Managed installations may set `DOIN_COPILOT_SDK` to the SDK's absolute module entry path. No runtime package is installed automatically.

The SDK runs in its [documented empty mode](https://github.com/github/copilot-sdk/blob/v1.0.16/nodejs/src/client.ts), with no model tools, file hooks, skills, custom instructions, MCP connections, or host Git operations. Doin sends only the selected task document and request. `/assist` is unavailable for this adapter. Stored Copilot credentials use the isolated private doin Copilot home. `doin logout copilot` removes that local login; it does not revoke your GitHub account or remove externally supplied tokens or GitHub CLI credentials, which the official runtime may use as fallbacks. A fixture SDK verifies request and cancellation behavior; live subscription inference remains unverified.

## Verification

Run `python3 tests/providers_e2e.py` against the built binary. It writes a reproducible command/request report with the binary hash to `artifacts/providers-e2e/results.json`. Authentication and Copilot fixtures have separate reports. Fixture success verifies local integration behavior; live account consent, entitlement, registered application permissions, and billable inference require separate release verification.
