# Group Loot live sync fix report

## Root cause

The production Group Loot service can commit a canonical `LOOT_ADDED` row without
`rollType` when the winning chat receipt has no matching roll context. In this
case `rollValue` is normalized to `0`. `DBRaidStore` accepts that row, but the R4
`LIVE_LOOT` positional codec required slot 9 to be an integer. The compact send
therefore failed and fell back to trailing `HEAD` recovery.

The reproduced four-loot sequence contained two rows with roll types 8/9 and two
rows without `rollType`. Before the fix the leader stored all four while the
replica received only the first two before the trailing `HEAD`.

The initially suspected transient `lootInfo.looter` field was not the wire
failure: `Recording.Append` rebuilds the row through `Recording.Build`, and the
four committed Service rows contained no `looter` key.

## RED

Command:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_group_loot_service_rows_replicate_immediately_without_recovery
```

Current-head failure before the production change:

```text
replica Group Loot count differs before trailing HEAD: expected 4, got 2
Ran 1 test in 0.065s
FAILED (failures=1)
```

The case uses the real Loot Service path to produce the rows and then real R4
protocol plus real raid stores for the leader and replicas.

## GREEN

The 16-slot wire shape is unchanged. Slot 9 now uses JSON null when `rollType`
is absent. Decode accepts either JSON null or an integer in the existing 0..9
range and omits `rollType` when reconstructing a null slot. `rollValue` remains
mandatory because the real Service normalizes it to `0`.

Focused command:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_group_loot_service_rows_replicate_immediately_without_recovery
```

```text
Ran 1 test in 0.068s
OK
```

Nearby Group Loot, compact-protocol, split-authority, and recovery checks:

```text
Ran 6 tests in 0.286s
OK
```

Raid replication and sync suites:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_sync_communications_behavior
```

```text
Ran 146 tests in 5.723s
OK
```

Validation:

- Lua 5.1 validator: both changed Lua files clean.
- Luacheck: 0 errors; 6 existing harness warnings.
- `git diff --check`: clean (line-ending notices only).

## Residual risk

Automated tests prove immediate convergence before the trailing `HEAD`. A
two-client WotLK 3.3.5a Group Loot smoke test is still required to validate the
client chat variants and real addon-message delivery.
