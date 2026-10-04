# Omarchy

Omarchy is a Linux compatibility target for doin. Use the existing Linux release and installer; a separate runtime or desktop plugin is not required. The installer selects x86_64 or aarch64 from `uname -m`.

## Install

Download the installer, inspect it, then run it in an Omarchy terminal:

```sh
curl -fsSL https://doin.sh/install.sh -o /tmp/doin-install.sh
sh /tmp/doin-install.sh
export PATH="$HOME/.local/bin:$PATH"
doin --version
doin
```

The installer verifies the release archive against published SHA-256 checksums and installs to `~/.local/bin`. Add that directory to your shell's persistent PATH if it is not already present. To update an existing installation, run `DOIN_REPLACE=1 sh /tmp/doin-install.sh`.

For manual use, no model is required. AI features require your configured local model or provider. Local MCP works through the same `doin mcp` commands. Browser account flows use `xdg-open`; Linux desktop notifications use `notify-send`. Background scheduling requires explicit opt-in; see [reminders](reminders.md).

## Verification boundary

An actual disposable Omarchy desktop has now been exercised with the current **0.3.0 Linux aarch64 binary**. The signed official Try Omarchy v0.4.1 image boots Omarchy 4.0.0.alpha on Arch ARM kernel 7.2.6, QEMU 11.1.1/HVF, four CPUs and 4 GiB RAM. Native CLI initialization, Unicode Markdown, complete/undo, number/select properties and filtering, nested Unicode folder creation/selection/rename, client-to-server MCP discovery/read, and real PTY editing, resize, Ctrl-C and terminal restoration passed. Foot ran doin inside Hyprland. A real doin reminder appeared in the desktop notification UI. `xdg-open` launched Chromium, whose fresh profile showed browser setup consent; a separate no-first-run Chromium process displayed the isolated local HTML fixture.

Final resize acceptance passed on **Foot 1.28.0-2**: wide to half-width Hyprland tiling, a third window reducing height, and growth back to the full viewport each showed one clean bottom composer. A live Unicode draft survived shrink/grow and was stored exactly. Resize archives the preceding viewport into native scrollback and clears only the active grid; earlier frames can remain in history. CJK bytes survived editing and storage; the supplied desktop font displayed missing glyph boxes, which is an OS font fallback limitation.

Evidence lives in `artifacts/omarchy-e2e/`: `reflow-results.json`, `reflow-terminal.ansi`, `reflow-half-final.png`, `reflow-short.png`, `reflow-grow-notification.png`, `final-results.json`, `final-terminal.ansi`, `final-reminder-desktop.png`, `final-browser-desktop.png`, `final-local-browser-desktop.png`, and `runtime.json` (earlier checkpoint provenance). The reproducible guest fixture is `tests/omarchy_guest_e2e.py`. Browser evidence covers a real local browser process, not live account consent or payment. The test bypassed factory GUI onboarding through an authorized disposable guest recovery shell and called the vendor's provisioning functions; factory GUI onboarding is unverified.

The official DMG SHA-256 matched its published asset digest. Its app signature passed strict verification. A copied launcher used the signed runtime and guest with host clipboard, camera, authentication and audio/microphone bridges omitted. Only a private test folder was shared; SSH was bound to loopback. No host home, repository, credentials or account data were exposed. The VM and guest services were stopped and the read-only DMG unmounted. A cache-only provisioned disk snapshot is retained as reproducible test evidence; no VM process remains between build batches.

Sources checked: [Try Omarchy official runtime](https://github.com/omacom/try-omarchy/tree/v0.4.1),  [Omarchy](https://omarchy.us/), [terminal manual](https://github.com/omacom/omarchy/blob/quattro/manual/15-terminal.md). Omarchy documents Foot as default and Alacritty, Ghostty and Kitty as supported alternatives.
