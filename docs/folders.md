# Folders and projects

Failure census before implementation. Local folders must preserve stable IDs through rename/move, preserve every document byte, reject path components and symlink escapes, prevent moving an ancestor into its descendant, retain selected folder identity, avoid recursive-stack depth limits, bound total nodes and document sizes, refuse collisions, and serialize concurrent structural edits. Model setup is unrelated to folders. Templates must preserve existing documents.

Team folders must isolate tenants, require current membership, enforce inherited read/write scope on every document operation, hide inaccessible ancestors, reject forged IDs/cycles, compare document revisions, prevent stale ACL checks authorizing writes, and require explicit acknowledgment before moves change inherited access. Removed members lose access. Existing root documents and existing member access must migrate without losing data. New narrow invitations grant only their named subtree. Owner/admin can manage folders and grants; paid team entitlement remains required by the integration boundary.

The local model is a physical directory tree under a library root. Each managed directory owns `tasks.md` and a private `.doin-folder.json` identity. Library root and selected storage are separate configuration fields. Existing single-folder configurations remain their own library root. Node count is bounded to 4,096; there is no application nesting-depth limit, although filesystem path limits still apply.

The team model uses stable IDs, parent IDs and independent document revisions. Grants apply to a folder and its descendants. Read grants cannot write; an inherited write grant can. Removing one grant does not remove access inherited from another ancestor. Members cannot move folders or edit grants. Moving a folder requires explicit access-change acknowledgment because destination ancestry can change sharing.

Primary source checked before integration. [Cloudflare D1 database binding](https://developers.cloudflare.com/d1/worker-api/d1-database/) documents prepared bindings and sequential transactional batches. Document CAS and membership/ACL checks must share the mutation SQL. Fixture outcomes are not deployed-service acceptance.

## Command contract

`doin folder list` prints the managed tree with IDs. `folder create PARENT_ID NAME` creates or adopts a real child directory while preserving an existing `tasks.md`. `folder rename ID NAME` preserves its identity. `folder move ID PARENT_ID` moves its complete subtree and rejects cycles. `folder select ID` selects that folder's document. The main configuration persists the library root separately, so selecting a project does not shrink the searchable library. Existing unmanaged directories are adopted only through explicit create or template application. Folder names are single visible UTF-8 components, not relative paths.

Templates are `simple`, `projects`, and `areas`. Simple keeps one root document. Projects adds Inbox, Projects and Archive. Areas adds Personal, Work and Someday. Applying a template preserves existing documents. The onboarding owner supplies prompts and configuration writes; the folder module has no model or account dependency.

Team routes are `/v1/teams/TEAM/folders`, `/folders/FOLDER`, `/folders/FOLDER/document`, and `/folders/FOLDER/grants`. Documents have independent revision numbers. A narrow member invitation can grant read or write on one folder subtree without root access. Admin is a global management role and cannot be represented as a narrow-folder role. Existing memberships migrate with root write access. Existing root document content and revisions migrate unchanged.

All mutating team routes require the paid-team check from the service boundary. Authorized document reads and metadata remain available for expiry/export recovery. Document writes repeat membership, inherited write scope and active paid-term predicates in the CAS mutation. Owner/admin moves require explicit acknowledgment when inherited sharing may change. Folder metadata lists omit invisible ancestors rather than returning their private IDs.

## Verification state

`python3 tests/folders_e2e.py --bin zig-out/bin/doin` exercises native create/adopt/rename/move/select, document preservation, cycle and escape refusal, and 24 additional nested levels. `cd cloud && node tests/folders-e2e.mjs` exercises the real Worker/D1 folder protocol, root migration, inherited ACLs, hidden ancestors, CAS, cycles, explicit move acknowledgment, cross-tenant forgery, removed membership and 24-level sharing.

These checks are written and awaiting the shared build/test lane. Their results must not yet be reported as passed. Planned artifacts are `artifacts/folders/native.json` and `cloud/artifacts/folders-e2e/report.json`.

Onboarding and selection failure census (before wiring the main app): canceled or invalid organization choice; canceled model setup; existing Unicode/fenced Markdown in a chosen root; templates adopting existing directories without overwriting documents; custom names containing path separators; optional first-task text never invoking AI; selected descendant tracking through ancestor rename/move; stable library root after project selection; failed configuration persistence after a successful filesystem move; unrelated settings changes preserving the selected library; changing storage explicitly clearing library context. E2E must exercise actual CLI onboarding and preserve resulting trees/configuration as artifacts.

Onboarding asks for storage, then organization, then optional AI. Enter keeps Simple. Custom creates a named folder and can add a first task manually. Templates seed Projects or Areas without replacing existing Markdown. Scripted setup supports `doin init --storage /absolute/path --provider manual --template projects`, or `--folder "Launch" --task "First next step"` with the Simple template.

`doin folder` opens the current workspace's folder picker. Personal folder commands support `list`, `create PARENT_ID NAME`, `rename ID NAME`, `move ID PARENT_ID`, and `select ID`. Interactive commands preserve quoted paths and names; MCP calls preserve the JSON remainder, and assist preserves the request text after its server selector. Saved library paths must retain their canonical location.

Team selection activates its separate local folder for ordinary task editing. `team personal` restores the previous personal folder. Personal `sync push`, `sync pull`, and `sync auto` are refused while a team workspace is active; use `team push` and `team pull` there. Selection never uploads tasks automatically.

Service acceptance2026-10-03: `cd cloud && node tests/folders-e2e.mjs` passed five realistic groups; receipt `cloud/artifacts/folders-e2e/report.json`. Covers migration, scoped descendant ACL, hidden ancestors, CAS/cycle/move behavior, tenant and removed-member denial, and twenty-four levels. Native CLI/onboarding acceptance is tracked separately.
