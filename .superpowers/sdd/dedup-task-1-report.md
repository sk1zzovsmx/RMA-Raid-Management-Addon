# Dedup Task 1 Report: Reconcile Distribution Awards With Loot Chat

## Outcome

- A recent canonical `DISTRIBUTION_AWARD` is now reconciled with its matching
  `CHAT_MSG_LOOT` observation before a second `LOOT_ADDED` can be committed.
- Matching is deliberately closed to item identity, recipient identity, item
  count, and the existing pending-award TTL. Only the newest 20 loot rows are
  inspected.
- The authoritative `lootNid`, `rollSessionId`, source, and already-applied
  counter remain unchanged. Observed item metadata is committed through one
  `LOOT_UPDATED` when it adds information.
- Different recipients, different counts, and stale observations remain
  separate canonical rows.

## TDD Evidence

### RED

The regression was added before production code and exercised the actual
`ITEM_DONE -> RecordDistributionAward -> LogTradeOnlyLoot` path followed by a
real `AddLoot` call with a parsed winner receipt.

Command:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_split_raid_leader_master_looter_records_and_replicates_trade_award_once -v
```

Expected failure observed:

```text
matching chat receipt created a duplicate loot row: expected 1, got 2
Ran 1 test ... FAILED (failures=1)
```

No red commit was created.

### GREEN

Focused command:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_split_raid_leader_master_looter_records_and_replicates_trade_award_once tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_distribution_award_commits_loot_and_counter_atomically -v
```

Result: 2 tests passed.

The regression proves:

- matching chat keeps one loot row and returns `reconciled`;
- exactly one `LOOT_UPDATED` is replicated for the observed item metadata;
- the canonical `lootNid` and `rollSessionId` are preserved;
- the award increments Winner MS from 0 to 1, while matching chat leaves it at
  1 (exactly once);
- a different recipient appends a row and increments Other MS to 1;
- a count-2 receipt appends a row and increments Winner MS from 1 to 3;
- a receipt beyond the 8-second TTL appends a row and increments Winner MS to
  4;
- subsequent non-countable awards do not change those counters, and all three
  replicas converge.

## Implementation

- `Raid Management Addon/Services/Loot/Recording.lua`
  - Added `FindRecentAuthorityFallback(raid, args, ttlSeconds)`.
  - Uses `looterNid` when both records have one; otherwise requires equal
    normalized names.
  - Requires `DISTRIBUTION_AWARD`, equal item key and count, non-negative age
    within TTL, and a position among the newest 20 rows.
- `Raid Management Addon/Services/Loot/Service.lua`
  - Calls the matcher after building the normal chat loot record and before
    `appendLootRecord`.
  - Copies the authoritative row, reuses `MergeTradeOnlyFallback`, merges
    observed item metadata, and commits `LOOT_UPDATED` when state changes.
  - Runs receipt/runtime finalization without invoking the normal append or
    loot-counter block.
- `tests/lua/runtime_harness.lua`
  - Extends the split raid-leader/master-looter fixture through matching chat,
    conservative negative cases, identity assertions, counter assertions, and
    replica convergence.
- `tests/test_raid_replication_behavior.py`
  - The existing split-authority Python entry point already invoked the
    extended Lua case, so no source change was necessary.

## Validation

- Pertinent files:
  - `py -3 -m unittest tests.test_raid_recording_integrity_behavior tests.test_raid_replication_behavior -v`
  - Result: 146 tests passed.
- Final full suite (run once on final code):
  - `py -3 -m unittest discover -s tests -v`
  - Result: 384 tests passed.
- `stylua --check` on both changed runtime Lua files: passed.
- `luacheck` on both changed runtime Lua files: 0 warnings / 0 errors.
- Lua 5.1 validator on the full addon: 134 files clean.
- Lua 5.1 variadic `xpcall` scan on the full addon: 134 files clean.
- `git diff --check`: passed; only existing line-ending conversion warnings
  were reported.
- `tools/check-rma.ps1` was not present in this worktree.
- No TOC or XML files changed. No in-game WotLK 3.3.5a smoke test was run.

## KISS Self-Review

Verdict: PASS.

- No generic merge engine, module, schema, SavedVariables migration, wire
  change, registry entry, or TOC entry was introduced.
- The scan bound and TTL are local correctness limits, not configuration or an
  extension point.
- The existing append path is unchanged for non-matches.
- The only residual concern is client-runtime timing/API behavior that the Lua
  harness cannot reproduce; it should be covered by the normal in-game loot
  smoke test.
