# Personal folder sync

Failure census before implementation: all local folders mapping to one cloud document; cross-account ID forgery; stale tree or document overwrites; concurrent snapshots; cyclic/disconnected hierarchy; Unicode/name/path escapes; arbitrarily deep nesting; root migration divergence; omitted metadata deleting data; restore losing old content; writes after account closing; expired paid access; deleted-folder writes; unbounded retained tombstones; account deletion cleanup.

The original account `documents` row remains the only root document. Migration0008 creates root metadata without copying content. Existing `/v1/document` and personal MCP remain consistent with `/v1/folders/root/document`. New account trigger creates library/root metadata. Child document revisions are independent of tree revisions.

- `GET /v1/folders` returns `{tree_revision,folders,tombstones}`; each metadata entry contains `id,parent_id,name,revision`.
- `PUT /v1/folders` accepts `{tree_revision,folders:[{id,parent_id,name}],tombstone_ids?:string[]}`. This is a full active tree snapshot. Every omitted previously active ID requires explicit tombstone acknowledgement; otherwise409 `explicit_tombstones_required`. Root cannot be omitted.
- Successful metadata CAS increments tree_revision. Stale CAS returns409 `tree_revision_conflict` with current snapshot. A closing race returns409 `tree_revision_conflict_or_account_closed`.
- `GET/PUT /v1/folders/:id/document` use `{revision,content,updated_at}`. Stale document CAS409 `revision_conflict`; independent folder revisions prevent cross-folder overwrite.
- Root cloud ID is `root`; native local root identity is translated. Descendants retain their existing local stable IDs.

Tombstones preserve metadata and document bytes. GET permits export/recovery of a tombstoned child; PUT requires restoring it in an explicit metadata snapshot first. Clients must never delete local files merely because remote metadata omits them. A snapshot can restore an old ID without losing content. No endpoint permanently deletes folder contents. Account deletion cascades remove owned rows.

Owner-only operations bind the authenticated account in every query. Current account closing state is checked within document/tree mutations; it cannot be bypassed by a stale authenticated actor. The supplied Worker adapter verifies paid subscription or approved personal self-host access before mutations. Reads permit recovery after subscription expiry. The module does not independently call Stripe: entitlement policy remains the Worker boundary's responsibility.

Trees must be connected to root, acyclic, and have unique sibling names and IDs. Iterative traversal has no depth ceiling; active nodes are limited4096 and retained identities8192, metadata request1MiB, document1MiB. Metadata projection runs in an SQLite trigger inside the tree CAS statement, so a stale writer cannot partially edit folder rows. Names forbid path separators/control characters/dot-prefix and exceed neither120UTF8bytes nor visible boundaries.

Primary provider guidance checked2026-10-03: [Cloudflare D1 binding API](https://developers.cloudflare.com/d1/worker-api/d1-database/) documents prepared parameter binding and transactional batch rollback; [D1 SQL](https://developers.cloudflare.com/d1/sql-api/sql-statements/) describes SQLite-compatible operations. No manual BEGIN/COMMIT or background database process is introduced.

Reproduce service E2E with `cd cloud && node tests/personal-folders-e2e.mjs`. Receipt: `cloud/artifacts/personal-folders-e2e/report.json`. Verified2026-10-03: eight service E2E groups passed against real Miniflare/D1, including legacy root single truth/idempotent retry, independent folder CAS, cross-account denial, stale/cyclic/path metadata rejection, tombstone recovery/restore, forty-eight levels, expired recovery/closing races, and new-account/deletion lifecycle. Native device-to-device library integration is a separate acceptance lane.
