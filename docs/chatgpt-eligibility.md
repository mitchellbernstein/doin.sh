# ChatGPT plan usage eligibility follow-up

Checked official OpenAI pages on 2026-10-03. No form submitted, account signed in, or provider approval obtained in this review.

## What the documentation establishes

The [plan usage overview](https://developers.openai.com/siwc/token-sharing-open-source) describes coverage for open-source and locally hosted apps, and directs developers offering plan usage in paid or remotely hosted apps to an interest form. It does not define an OSI license requirement or explicitly classify a free local client with optional paid hosted services. Its wording is insufficient to establish that local execution alone grants eligibility to every source-available commercial product.

The [commercial interest form](https://openai.com/form/sign-in-with-chatgpt-interest/) expressly invites commercial partners. Submitting interest is a request, not evidence of acceptance. Public documentation reviewed here does not state that form submission by itself authorizes production commercial plan usage.

The [registration guide](https://developers.openai.com/siwc/token-sharing-open-source/sign-in) provides dynamic registration for open-source clients without a client secret or partner API key. Technical support for that flow does not resolve eligibility for doin.sh's current distribution terms.

Current [LICENSE](../LICENSE) permits personal noncommercial use and requires a separate agreement for business use. This review describes it as **source-available**, not unrestricted open source. A public GitHub repository does not change those restrictions. No legal conclusion about OpenAI's classification follows from that observation.

**Outcome:** doin.sh's exact mixed model needs clarification from OpenAI. Do not advertise ChatGPT plan usage as approved for paid/team/hosted use, or describe working OAuth fixtures as provider approval. API keys and local models remain separate options.

## Concrete question for OpenAI

> Studio Yeehaw LLC develops doin.sh (https://doin.sh; https://github.com/mitchellbernstein/doin.sh), a native terminal task app. The free personal client runs on the user's computer and stores Markdown locally. Its current public source is under a personal noncommercial license; commercial/team use requires a paid license. We also offer optional paid Cloudflare-hosted sync and an authenticated remote MCP server. ChatGPT authorization tokens and ChatGPT-plan Responses requests stay in the native client; hosted sync/MCP do not proxy or consume these tokens. Does the locally hosted dynamic-registration route cover this free personal client under this license, even though the product has optional paid services? Does paid commercial/team use of the same local client require commercial partner approval? What approval or client registration is required before enabling ChatGPT plan usage for either case?

This is a prepared question, not a sent message. Reconfirm the token separation claim against the release being submitted.

## Interest form draft

Fields below reflect the actual official form inspected during this review.

| Field | Prepared value / missing information |
| --- | --- |
| Work email (required) | Unknown confirmed submission address; publisher must supply/confirm. |
| First name (required) | Mitchell, subject to submitter confirmation. |
| Last name (required) | Bernstein, subject to submitter confirmation. |
| Company name (required) | Studio Yeehaw LLC, as recorded in LICENSE. |
| Website URL (required) | https://doin.sh |
| Job title (optional) | Unknown; leave blank until supplied. |
| Capabilities (required) | Sign in and ChatGPT plan use for AI requests. |
| Products (required description) | Use the product description and eligibility question above; include public repository and license restrictions. |

No invented usage numbers, approval status, organization identifiers, or commercial launch claims should be added. Confirm contact details and final architecture before an authorized submission.

## Architecture boundaries that remain relevant

The [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations) exclude hosted MCP/connectors and transcription from this plan-usage route. Local MCP tool execution is a different mechanism. doin.sh's remote MCP server being available to external clients does not establish that it can be supplied as a hosted Responses tool through ChatGPT plan usage. Local Whistle speech recognition avoids dependence on the excluded transcription route.

Eligibility clarification, a successful real consent flow, and a completed eligible inference are distinct acceptance steps. This read-only documentation check proves none of the latter two.
