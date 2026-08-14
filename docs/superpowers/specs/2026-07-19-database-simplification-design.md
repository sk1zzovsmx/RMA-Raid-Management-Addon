# Database Simplification Design

## Objective

Simplify the RMA Database subsystem without changing its public addon contract,
SavedVariables names, archive wire format, or raid-management behavior. Remove
unreachable compatibility paths and defensive machinery that has no runtime
consumer, while preserving fail-closed persistence and sync behavior.

## Scope

This change covers:

- `Database/DB.lua`
- `Database/DBRaidStore.lua`
- `Database/DBRaidQueries.lua`
- Database-related Lua behavior tests and Python contract tests

`DBRaidEvents.lua`, `DBRaidValidator.lua`, `DBSyncProtocol.lua`,
`DBSyncSession.lua`, and `DBSyncer.lua` remain behaviorally unchanged unless a
direct caller update is required after removing an obsolete API.

## Canonical Persistence Model

`RMA_Raids` has one internal representation:

```lua
{
    formatVersion = 1,
    activeRaidUid = nil,
    order = {},
    raids = {},
}
```

`SavedVariables.GetRaids()` remains the sole runtime source of the raid archive.
It initializes this representation when the stored value is absent or has an
unsupported root format. Format-one archives continue through the existing
validator and quarantine path. No non-RMA import, old-brand import, or implicit
array migration is introduced.

`DBRaidStore.lua` will therefore operate only on archive v1. Branches that
normalize, index, mutate, or delete a root array of raid states will be removed.
The state records inside archive v1 keep their existing schema and behavior.

## API Reduction

Remove runtime APIs with no production caller:

- `Database.EnsureArchive`
- `RaidStore:CaptureRaidInsertionState`
- `RaidStore:RestoreRaidInsertionState`

The supported rollback contract remains
`CaptureRaidHistoryState`/`RestoreRaidHistoryState`. Tests will protect that
contract instead of preserving disabled insertion-era APIs.

All Database facade methods used by controllers, services, widgets, entry
points, or sync remain unchanged.

## Query Simplification

Read-only projections remain pure: they do not normalize or mutate canonical
raid data. Query results keep their current field shapes, ordering, filtering,
and optional reusable `out` parameter.

`GetRaidRuntimeForRead` and its whole-raid transient index are removed. Each
query will use the simplest lookup appropriate to its output:

- direct sequence scans for bounded raid collections;
- a small local lookup only when one query demonstrably reuses it;
- no population of unrelated player, boss, attendance, and loot indexes.

Admission and mutation indexes owned by `EnsureRaidRuntime` remain because they
serve write-side store operations and direct service lookups.

## Output Buffer Contract

The optional `out` table is caller-owned. Existing runtime callers already pass
dedicated UI buffers or newly allocated export arrays.

Queries will protect against the realistic accidental aliases that are cheap to
detect: `out` may not be the raid root or one of its top-level canonical
collections. Row reuse will allocate a fresh row when an existing output row is
one of the directly known canonical rows for the collection being projected.
The query layer will not recursively inventory every nested table in the raid.

This preserves canonical data against direct output aliasing while removing a
full graph traversal from every projection. Passing an arbitrary deeply nested
canonical table as `out` is outside the supported contract.

## Error Handling And Compatibility

- Invalid or future-schema raid inputs keep their existing stable rejection.
- Invalid archive v1 data remains fail-closed and quarantined.
- Active raid writes still require authority and semantic events.
- Historical mutations remain atomic and digest-validated.
- Sync protocol, request correlation, chunking, recovery, and handover behavior
  do not change.
- Lua remains compatible with Lua 5.1 and WoW 3.3.5a.

## Test Strategy

Use test-first changes for each behavior boundary:

1. Replace legacy-array and disabled-API assertions with archive-only contract
   assertions; verify the new tests fail against the old surface.
2. Add query tests showing projections remain fresh after same-length mutations
   without depending on a whole-raid read index; verify failure before removing
   it.
3. Replace deep arbitrary-alias tests with the documented top-level alias and
   caller-owned buffer contract; verify failure before simplifying traversal.
4. Run focused Database/bootstrap suites after each step.
5. Run the full Python/Lua test suite and repository validation gates once the
   refactor is complete.

Required final checks include the available Python tests, `tools/check-rma.ps1`,
StyleLua, Luacheck, TOC validation, Lua 5.1 validation, the `xpcall` scan, XML
handler scan, and `git diff --check`. In-game smoke testing remains a manual
follow-up and will be reported explicitly.

## Success Criteria

- Archive v1 is the only runtime raid root representation.
- No production or test reference remains to the removed APIs.
- Query projections preserve their current outputs and read-only behavior.
- Query reads do not build every transient index or recursively traverse the
  entire canonical table graph.
- SavedVariables, wire formats, authority, sync, and archive validation remain
  unchanged.
- Relevant automated and static validation gates pass.
