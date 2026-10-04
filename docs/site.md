# Marketing site

## Failure scenarios considered before implementation

- Narrow screens or enlarged text clip the headline, terminal, or installation command.
- Clipboard access is unavailable or denied, leaving the visitor without a selectable command.
- Keyboard navigation cannot reach the copy control or announce its outcome.
- Installer route returns HTML, a stale script, or a broken release link.
- A restrictive header blocks the site's own script or styles.
- Example commands misrepresent actual CLI output or imply that AI always runs locally.

## Design

A single static page, system fonts, no dependencies, tracking, or external assets. The image concept is a design reference, never a shipped screenshot. Markdown location and optional AI are the only two feature sections. ChatGPT, API, and local choices are explicit.

Cloudflare Pages serves `site/` directly. `/install` proxies to `/install.sh`; that file must remain byte-identical to `scripts/install.sh`. Relevant primary documentation: [Pages redirects](https://developers.cloudflare.com/pages/configuration/redirects/) and [Pages headers](https://developers.cloudflare.com/pages/configuration/headers/), checked October 3, 2026.

## Local reproduction

Run `python3 -m http.server 8787 --bind 127.0.0.1 --directory site`, visit http://127.0.0.1:8787, then stop the server. Python's server does not implement Pages headers or the `/install` proxy; verify those on the deployed Pages URL.

## Verification evidence

Existing task-owned `doin-marketing` browser session reused; no authentication window created. Screenshots: `artifacts/site/doin-desktop.png` at 1440 px wide and `artifacts/site/doin-mobile.png` at 375 px wide. Both screenshots and the generated concept were inspected visually. At 320 px and 375 px, document width matched viewport width: no horizontal overflow. Copy button activation through keyboard produced `Copied.`; clipboard readback was denied by browser permissions, so exact OS clipboard contents were not independently verified. Forced clipboard-write denial selected the entire exact installation command and announced manual-copy feedback. Browser error log was empty. Installer comparison with `cmp scripts/install.sh site/install.sh` passed.

Reproduce checks after starting the local server (use an available port):

```sh
agent-browser --session doin-marketing open http://127.0.0.1:8789
agent-browser --session doin-marketing set viewport 1440 1150
agent-browser --session doin-marketing screenshot artifacts/site/doin-desktop.png --full
agent-browser --session doin-marketing focus '#copy'
agent-browser --session doin-marketing press Enter
agent-browser --session doin-marketing wait --text 'Copied.'
agent-browser --session doin-marketing set viewport 375 812
agent-browser --session doin-marketing screenshot artifacts/site/doin-mobile.png --full
agent-browser --session doin-marketing eval 'document.documentElement.scrollWidth <= innerWidth'
agent-browser --session doin-marketing errors
```

## Fidelity ledger

- Copy and hierarchy: exact headline, subtitle, navigation, installer command, and feature copy preserved.
- Layout: centered 960 px content area; left-aligned hero; terminal then installer then two open feature columns and footer.
- Palette: near-black background, white text, restrained gray, thin dark borders; no gradients or glows.
- Typography: system sans and monospace, large two-line headline; responsive type keeps 320 px screen readable.
- Assets and controls: code-native terminal, copy icon, restrained terminal dots; no bitmap UI or external font download.
- Intentional deviations: terminal adds actual CLI `doin` heading and spacing, checked against `src/main.zig`; mobile stacks feature columns and wraps long terminal lines. The compact 960 px container makes the concept fit an ordinary browser rather than copying its generated full-width proportions.
- Above-fold copy diff: no invented marketing copy. Terminal accuracy adjustment above is the only added example text. Copy feedback is a functional state.

Implementation faithfully checked against the accepted concept. No material visual mismatch remains. Deployment still needs live installer-route and header checks because Python does not emulate Pages configuration.
