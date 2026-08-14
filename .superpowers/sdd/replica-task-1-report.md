# Replica Task 1 Report

## Outcome

B now persists A's newly installed active replica and receives exactly one
`LoggerSelectRaid(index, "sync")` notification without changing
`Database.GetCurrentRaid()`. Later authoritative deltas continue to publish only
`LoggerDataChanged("raid_sync")`, so they refresh Loot History without stealing
the user's selection. Historical offer/accept selection remains on its existing,
separate path.

## RED

Regression added first:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_new_active_replica_selects_loot_history_once -v
```

Observed before the runtime change: exit 1 with the expected behavioral failure:

```text
new replica was not selected exactly once: expected 1, got 0
```

The two-peer case had already driven A's authoritative loot event through B's
snapshot recovery, persisted one loot row on B, and kept B's current raid nil.
No staging or red commit occurred.

## GREEN

`DBSyncer` now checks the store's existing `GetIndexByUid` owner method before
applying a live snapshot. After a successful apply it always emits the existing
data-change event, and emits the existing selection event only when that UID was
not present before installation. The event-only delta refresh was not changed.

Focused regression:

```text
Ran 1 test in 0.060s - OK
```

Raid replication module:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior -v
```

```text
Ran 89 tests in 5.386s - OK
```

Final full suite, run once on final code:

```powershell
py -3 -m unittest discover -s tests -p 'test_*.py' -v
```

```text
Ran 384 tests in 17.823s - OK
```

Additional validation:

- TOC validator: 0 errors, 0 warnings.
- Lua 5.1 validator: 134 files clean.
- Variadic `xpcall` scan: 134 files clean.
- XML handler scan: no XML script handlers.
- `git diff --check`: exit 0 (line-ending conversion warnings only).
- `luacheck` on touched Lua files: 0 errors and 7 pre-existing warnings, all
  outside modified lines.
- `stylua --check` reports existing whole-file formatting differences; no bulk
  formatting was applied because it would be unrelated scope.
- `tools/check-rma.ps1` is not present in this worktree.

## Files

- `Raid Management Addon/Database/DBSyncer.lua`
- `tests/lua/runtime_harness.lua`
- `tests/test_raid_replication_behavior.py`
- `.superpowers/sdd/replica-task-1-report.md`

## Self-review

- The pre-apply presence check and post-apply index resolution both use
  `RaidStore:GetIndexByUid`; no archive scan was duplicated in Logger or Syncer.
- Selection is snapshot-install-only. Repairing an existing UID and applying a
  later event cannot reselect it.
- `Database.GetCurrentRaid()` is read by existing recovery logic but is not
  written by this change.
- No DB-to-controller call, new event, schema, wire field, SavedVariables key,
  or compatibility layer was introduced.
- Historical import still selects only after explicit accepted import through
  its existing `ImportHistoricalSnapshot` path.
- The diff is scoped to the requested runtime owner, faithful two-peer fixture,
  Python wrapper, and this report.

## Concern

An in-game WotLK 3.3.5a smoke test was not available. The automated two-peer
harness proves publication, persistence, nil current-raid state, and one-time
selection, but actual Loot History frame visibility should still be confirmed
in client.
