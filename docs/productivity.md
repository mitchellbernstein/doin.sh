# Productivity commands

`/focus` asks your selected AI to recommend one open task for today, with a short reason and a concrete first step. The suggestion stays a preview until you accept it. Decline to choose another task with the arrow-key picker. `/focus pick` asks again; `/focus manual` opens the picker without AI; `/focus N` uses the current task number. AI-off, unavailable providers, and invalid recommendations use the picker.

`/focus status` shows the current focus. While focused, the board shows that task and an optional next action saved with `/focus step TEXT`. `/focus done` completes the selected task through the normal undo boundary; `/focus off` restores the full board. A finished focus stays visible for the day.

Focus is private to this device and storage folder, survives restart, and expires at the next local midnight. A stable identity in Markdown follows the task through external reordering and title edits. Missing or duplicate identities refuse completion. Focus works without an AI provider. Run `python3 tests/focus_e2e.py` for reproducible CLI and terminal scenarios in `artifacts/focus-e2e`.

AI recommendations reuse the selected provider's existing [Chat Completions](https://developers.openai.com/api/reference/resources/chat) or [Ollama chat](https://docs.ollama.com/api/chat) request path. Local validation accepts only an open task from the original document. An external edit during recommendation or confirmation rejects the stale proposal. `python3 tests/focus_ai_e2e.py` records provider requests, CLI results, and terminal captures in `artifacts/focus-ai-e2e`.

`/review` lists open tasks with their original numbers and groups. A checkbox does not reveal when a task was created or why it remains open; doin does not claim to know which tasks you have avoided.

`/prioritize` previews open tasks ordered by explicit `@priority(high)`, `@priority(medium)`, or `@priority(low)`, then `@due(YYYY-MM-DD)`. Tasks without priority follow marked tasks. Equal tasks keep their original order. This local read-only view never sends contents to AI or changes Markdown.

`/delete 1,3` selects task numbers. `/delete group:Home` selects tasks under that heading. `/delete done`, `/delete open`, and `/delete all` select status groups. `/clear` defaults to completed tasks. The UI previews task names and count and asks for confirmation. The main storage boundary checks the original file, locks the write, and records undo; this module never writes files. Headings, prose, and fenced examples survive deletion.

`/visualize` shows a native ASCII completion chart per heading. Arrow keys select a group in the interactive TUI. The chart measures the current document's completed/total tasks, not productivity, efficiency, or historical throughput. Empty documents have no invented statistics. No chart library or background service is required.

The implementation uses [Zig 0.15.2](https://ziglang.org/documentation/0.15.2/). `python3 tests/productivity_e2e.py zig-out/bin/doin` runs realistic CLI operations with grouped tasks, fenced examples, cancellation, invalid selection, and undo. Its reproducible receipt is `artifacts/productivity-e2e/scenario.json`.

Task display hides validated trailing doin reminder markers and the iOS completion-day marker `<!-- doin:completed=YYYY-MM-DD -->`. A completion marker is private metadata only when it is a standalone, calendrically valid HTML comment followed solely by whitespace-separated HTML metadata comments; this lets portable values, task identity, and the final reminder marker follow it. Malformed dates, duplicate completion markers, and marker-looking text followed by quote, backtick, or ordinary title bytes remain visible content. Terminal task mutations preserve completion metadata byte-for-byte; iOS removes it when reopening and writes the new local day on a later completion. Deletion retains untouched task bytes, including reminder IDs and timestamps; malformed or unrelated comments remain visible and unchanged.

Due-date ordering validates Gregorian dates, including leap years; malformed dates sort as undated and retain original ordering. Task numbering ignores fenced examples with matching delimiter characters and closing runs at least as long as the opener. A triple-backtick line cannot close a four-backtick block.

`/today`, `/week`, and `/month` are `/filter due today|week|month` shortcuts. They show open dated tasks overdue through today, the local week's Sunday, or the month's last day. Week starts Monday. Missing or invalid dates are excluded; dates come only from explicit `@due(YYYY-MM-DD)` tags.

`/filter status doing`, `/filter priority high`, `/filter group Work`, and `/filter text invoice` are local read-only views. `/status blocked` is a shorthand for the status filter. Text matching is case-sensitive; group matches the complete heading.

`/mark 3 doing`, `/mark 3 blocked`, `/mark 3 done`, and `/mark 3 todo` propose a single task update for the normal confirmation and undo boundary. Doing and blocked use explicit `@status(...)` tags. A checked checkbox always means done, even when older status tags remain. Marking todo/done removes existing recognized status tags. Reminder IDs, due instants, unrelated comments, and untouched lines survive the update.

The time views use the operating system's local calendar through `localtime_r` and `mktime`, including daylight-saving boundaries. `/unblock` can use the selected task returned by `find`; the surrounding command must keep AI output read-only until the user chooses a separate change.

Custom statuses travel with the document in a `<!-- doin:statuses=doing,blocked,waiting -->` declaration outside fenced examples. `/statuses` lists available states. `/statuses add waiting` creates one; `/statuses rename waiting review` updates its task tags; `/statuses remove review todo` removes it and replaces task tags. Removing a used state without a replacement fails. `todo` and `done` remain protected checkbox meanings; `doing` and `blocked` are manageable open states. Names use lowercase slugs beginning with a letter, with letters, digits, or hyphens, up to 32 characters. Unknown names and malformed declarations fail explicitly. Registry and task edits use the same preview, confirmation, locked commit, and undo flow as other changes.
