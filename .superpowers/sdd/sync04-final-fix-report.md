# Sync-04 Final Review Fix Report

## Status

- Base: `4e5a3790671840e28ba1d5aaf557077b85195766`
- Branch: `codex/single-raid-history-sharing`
- Result: both release blockers and the terminal headless-recovery lifecycle finding fixed with the existing `DBSyncer` handover owner; dedup evidence strengthened.
- Scope: one runtime owner, the Lua runtime harness, the Python test surface, and this report.
- Not integrated into `codex/loot-bans-optimization`.

## Blocker 1: Persistent Barrier After `DIGEST_CONFLICT`

### RED

Command:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_digest_conflict_keeps_the_real_store_write_barrier_closed -v
```

Observed failure before the runtime edit:

```text
FAIL: digest conflict reopened the authority barrier
```

The regression uses the production `DBRaidStore` authority guard installed by `DBSyncer`. A tied position with a different digest suspended status but removed `_handover`, so `IsAuthorityRecovering(raidUid)` returned false.

### GREEN

The existing handover remains the transition-owned write barrier only when its terminal reason is `DIGEST_CONFLICT`. Other handover failures retain their previous release behavior. The regression now proves:

- `GetStatus()` remains `suspended`, reason `DIGEST_CONFLICT`;
- `IsAuthorityRecovering(raidUid)` remains true;
- real `CreateActiveRaid` and `CommitAuthoritativeEvent` both reject with `AUTHORITY_RECOVERING`;
- the local archive is byte-for-behavior unchanged by the rejected writes;
- the next authority change cancels only the obsolete handover and releases its barrier;
- the conflict source copy is never installed over the local copy.

The focused test passes.

## Blocker 2: Handover Discovery Without a Local Head

### RED

Command:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_handover_without_a_local_head_discovers_before_creating_once -v
```

Observed failure before the runtime edit:

```text
FAIL: headless authority transition did not start handover discovery
```

The regression wires the production `DBRaidStore`, `DBSyncer`, `Raid.State`, `Raid.Session`, `Raid.Capabilities`, and Init instance-recognition path. A known `ReplicaB -> localPlayer` transition with no local record previously reached the instance check without a handover barrier.

### GREEN

Every real non-nil authority transition to the local Raid Leader now opens the existing bounded handover, even when `raidUid` and local `head` are nil. That handover sends the existing v3 `HEAD_REQ`, admits valid active HEADs during its existing timer window, binds the selected UID, and uses the existing snapshot/recovery/promotion path.

The regression proves both bounded outcomes:

- before a remote HEAD, production `Raid.Session:Check`, real `CreateActiveRaid`, and real `CommitAuthoritativeEvent` are rejected without mutation;
- a valid active HEAD and snapshot are installed and promoted before any write can be enabled;
- no competing `RAID_CREATED` event or UID is produced during recovery;
- the recovered record is selected through the existing Database owner before the handover barrier is removed and lifecycle completion is published;
- when the bounded discovery window has no valid copy, only that handover is closed and the existing `Raid.Session:Check -> Raid.State:Create` lifecycle creates and selects exactly one new raid;
- initial `nil -> localPlayer` bootstrap remains fresh entry, and the existing re-entry/handover mutual-exclusion tests remain green.

The focused test passes.

## Dedup Evidence

The existing split Raid Leader/Master Looter regression now instruments the existing `_Workflow.RecordReceipt` owner and additionally proves that the matching chat reconciliation:

- commits `eventType == "LOOT_UPDATED"`;
- records exactly one workflow receipt.

Existing assertions remain in place for one row, stable `lootNid`, stable `rollSessionId`, one counter, divergent recipient/count/stale rows, and replica convergence.

Focused command:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_split_raid_leader_master_looter_records_and_replicates_trade_award_once -v
```

Result: `1 test`, `OK`.

## Verification

Focused blocker and compatibility run:

```text
3 tests, OK
```

Complete replication plus relevant sync communications:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_sync_communications_behavior -v
```

Result: `125 tests`, `OK`.

Full repository suite:

```powershell
py -3 -m unittest discover -s tests -v
```

Result: `388 tests`, `OK`.

Validators:

- `luacheck Raid Management Addon/Database/DBSyncer.lua`: `0 errors`; one pre-existing W542 warning remains at the untouched empty-branch compatibility guard (the same warning is present at `HEAD`).
- bundled TOC validator on `Raid Management Addon.toc`: pass.
- bundled Lua 5.1 validator on the addon tree: pass, `134 file(s) clean`.
- bundled Lua 5.1 xpcall scan on the addon tree: pass, `134 file(s) clean of variadic xpcall`.
- XML `<Scripts>`/`<On...>` scan: pass, no handlers found.
- changed-file `git diff --check`: pass.
- `stylua --check` was run on both changed Lua files. It reports whole-file pre-existing formatting differences, including untouched `DBSyncer` and runtime-harness regions. No out-of-scope whole-file rewrite was applied.
- `tools/check-rma.ps1` is not present in this worktree or the main repository, so it could not be run.

## Files

- `Raid Management Addon/Database/DBSyncer.lua`
- `tests/lua/runtime_harness.lua`
- `tests/test_raid_replication_behavior.py`
- `.superpowers/sdd/sync04-final-fix-report.md`

Preserved and excluded from this fix scope: `.superpowers/sdd/task-4-report.md`, `.planning/`, and `.superpowers/sdd/progress.md`.

## Invariants

- Raid Leader remains the only active-history authority in Master Loot and Group Loot.
- Protocol remains v3; no wire kind or payload change.
- No SavedVariables schema or `RMA_*` key change.
- No new module, polling, retry loop, lock manager, or recovery state machine.
- Handover and re-entry remain mutually exclusive.
- `nil -> localPlayer` remains fresh bootstrap rather than handover.
- Conflict handling remains fail-closed without overwriting either copy.
- No-copy creation uses the existing State/Session lifecycle and remains single-active-raid bounded.
- Lua 5.1 and WotLK 3.3.5a compatibility are preserved.

## KISS/YAGNI Self-Review

Verdict: `PASS` for the current runtime and test diff. The implementation reuses `_handover`, its existing timer, `HEAD_REQ`, snapshot recovery, authority guard, and Session/State creation lifecycle. The handover-specific HEAD validation is intentionally not merged with re-entry validation because the admission semantics differ. No speculative abstraction or compatibility layer was introduced.

## Remaining Concerns

- Live WotLK 3.3.5a smoke remains mandatory: login without Lua errors, transfer Raid Leader before the new leader has a local replica, confirm writes stay paused until recovery/no-copy resolution, and verify `/reload` preserves the expected `RMA_*` archive.
- The repository-wide StyLua baseline is not clean; this fix does not broaden into unrelated formatting churn.

## Re-review: Terminal Headless Recovery

### RED

The real-store regression was extended past snapshot installation and promotion to the terminal lifecycle state. Before the follow-up runtime edit it failed with:

```text
headless recovery did not select the recovered raid: expected 1, got nil
```

The recovered active record existed, but `Database.GetCurrentRaid()` stayed nil. That kept `IsAuthorityRecovering(raidUid)` true and prevented a real authoritative write unless another zone event or reload happened.

### GREEN

The existing handover now records only whether it started without a local head. After snapshot recovery and successful authority promotion, that path resolves the recovered raid's existing archive index and selects it through `Database.SetCurrentRaid` before `_handover` is cleared and recovery completion is published. No State/Database bypass, new protocol, SavedVariables field, retry loop, or recovery state was introduced.

The regression now proves in one production-wired transition, without another zone event or reload:

- the recovered UID is the sole active history and its archive index becomes `Database.GetCurrentRaid()`;
- the authority-recovery barrier is closed only after selection and is then released;
- a real `CommitAuthoritativeEvent` succeeds immediately, increments sequence, and mutates the recovered state;
- no second UID or `RAID_CREATED` event is produced.

### Follow-up Verification

- terminal headless recovery: `1 test`, `OK`;
- adjacent bootstrap, re-entry exclusion, begin-failure, digest-conflict, real-recovery, and repeated-authority-change checks: `7 tests`, `OK`;
- replication plus sync communications: `125 tests`, `OK`;
- full repository: `388 tests`, `OK`;
- TOC, Lua 5.1, variadic `xpcall`, XML-handler, and `git diff --check` gates: pass;
- Luacheck: `0 errors` plus the unchanged baseline W542 warning described above;
- StyLua: still reports broad pre-existing whole-file formatting drift; no unrelated rewrite applied;
- `tools/check-rma.ps1`: absent, so not run.

KISS/YAGNI follow-up verdict: `PASS`. The fix adds one transition-local boolean and one call to the existing Database selection owner; it does not create another lifecycle or persistence abstraction. Live WotLK smoke remains the only residual validation risk.
