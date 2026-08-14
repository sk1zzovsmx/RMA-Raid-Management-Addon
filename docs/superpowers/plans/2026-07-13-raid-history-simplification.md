# Raid History Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove duplicated raid-history validation, overlapping Create snapshots, roster hook sprawl, and logger rollback uncertainty without changing persisted data, event order, revisions, active-raid protection, or bounded cleanup behavior.

**Architecture:** Reuse `DBRaidValidator:GetRaidRecordValidation` as the single validity policy and the existing full-history snapshot as the sole Create rollback boundary. Replace the roster state hooks with three operations, and let `DBRaidStore` build a detached cleanup candidate before replacing the contents of the existing `RMA_Raids` root once.

**Tech Stack:** Lua 5.1, WoW WotLK 3.3.5a API, Python `unittest`, repository Lua behavior harness, PowerShell validation.
## Global Constraints

- Preserve Interface `30300`, Lua 5.1, and WotLK 3.3.5a compatibility.
- Preserve all `RMA_*` SavedVariables names and schemas; keep the existing `RMA_Raids` root table identity.
- Preserve stable NIDs, raid and loot revisions, active-raid protection, successful event order, and cleanup chunking/cancellation.
- Keep `CaptureRaidInsertionState` and `RestoreRaidInsertionState` for append-only imports.
- Do not add a validator issue model, a new snapshot API, a persistence replacement API, a generic transaction helper, or compatibility fallbacks.
- Do not modify `Libs/`, wire formats, XML ownership, `/rma`, frame identities, or visible workflows.
- Runtime code and comments remain ASCII.
- Defer the in-game smoke test until all simplification plans are integrated.

---

### Task 1: Delegate store validation to the existing raid validator

**Files:**
- Modify: `Raid Management Addon/Database/DBRaidStore.lua:1194-1334,1469-1477`
- Modify: `tests/lua/runtime_harness.lua:3741-3763`
- Modify: `tests/test_raid_recording_integrity_behavior.py:166-170`

**Interfaces:**
- Consumes: `Database.GetRaidValidator():GetRaidRecordValidation(raid, index, currentSchemaVersion) -> report`.
- Produces: store mutation commits return `false, firstErrorCode` using the first `report.details[i]` whose `level == "E"`.
- Preserves: `CommitRaidHistoryMutation` conflict, verify callback, revision, runtime-index, and publication behavior; `CommitNewRaidHistoryImport` keeps its existing return shape.

- [ ] **Step 1: Write the failing delegation test**

Add this case after `logger_history_validation_is_strict_and_complete`:
```lua
function cases.raid_store_uses_validator_first_error(addon)
	local fixture, _, raid = installLoggerAtomicFixture(addon)
	local staged = fixture.store:StageRaidHistoryMutation(raid)
	staged.players[1].playerNid = 1.5
	local report = addon.Database.GetRaidValidator():GetRaidRecordValidation(staged, 0, 6)
	local expected
	for i = 1, #report.details do if report.details[i].level == "E" then expected = report.details[i].code break end end
	assertTrue(type(expected) == "string", "fixture must produce a validator error")
	local committed, reason = fixture.store:CommitRaidHistoryMutation(raid, staged, { reason = "test" })
	assertEqual(false, committed, "invalid history must not commit"); assertEqual(expected, reason, "first error differs")
	print("PASS raid_store_uses_validator_first_error")
end
```
Add the Python entry point:
```python
def test_raid_store_uses_validator_first_error(self) -> None:
    result = run_lua_case("raid_store_uses_validator_first_error")
    self.assertIn("PASS raid_store_uses_validator_first_error", result.stdout)
```

- [ ] **Step 2: Run the new test and verify RED**

Run:
```powershell
py -3 -m unittest tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_raid_store_uses_validator_first_error -v
```

Expected: FAIL because the store still returns the duplicated local validator's error code.

- [ ] **Step 3: Add the minimal report adapter and remove duplicate policy**

Delete `validateSequence` and `validateLoggerHistoryMutation` from `DBRaidStore.lua`. Keep `isPositiveInteger` because the store still uses it for scoped NID and revision arguments.

Add this private adapter:
```lua
local function validateRaidHistory(raid)
	local validator = Database.GetRaidValidator()
	local report = validator:GetRaidRecordValidation(raid, 0, Database.GetRaidSchemaVersion())
	for i = 1, #(report and report.details or {}) do
		local detail = report.details[i]
		if detail.level == "E" then return false, detail.code end
	end
	return true
end
```

In `CommitRaidHistoryMutation`, replace the local graph validation with:
```lua
local valid, validationError = validateRaidHistory(stagedRaid)
if not valid then return false, validationError end
```

In `CommitNewRaidHistoryImport`, preserve its three-value error shape:
```lua
local valid, validationError = validateRaidHistory(raid)
if not valid then return nil, nil, validationError end
```

Do not change `DBRaidValidator.lua`: it already owns raw traversal, structural diagnostics, reference checks, and counter checks.

- [ ] **Step 4: Update strict-history expectations to validator codes**

In `logger_history_validation_is_strict_and_complete`, derive each expected code from the real validator before calling the store rather than duplicating the mapping in the test:
```lua
local function reject(mutator)
	local staged = fixture.store:StageRaidHistoryMutation(raid)
	mutator(staged)
	local report = addon.Database.GetRaidValidator():GetRaidRecordValidation(staged, 0, 6)
	local expected
	for i = 1, #report.details do if report.details[i].level == "E" then expected = report.details[i].code break end end
	local before = deepCopy(raid)
	local ok, reason = fixture.store:CommitRaidHistoryMutation(raid, staged, { reason = "test" })
	assertEqual(false, ok, "invalid staged history must reject")
	assertEqual(expected, reason, "store and validator error differ")
	assertTrue(deepEqual(before, raid), "rejected history must not mutate canonical data")
end
```

Keep the existing malformed player, loot, sparse collection, boss attendee, and loot-scope inputs. The explicit invalid `opts.lootNid` case continues to expect `INVALID_LOOT_SCOPE`, because it validates a commit argument rather than raid history.

- [ ] **Step 5: Run focused validation tests for GREEN**

Run:
```powershell
py -3 -m unittest tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_raid_store_uses_validator_first_error tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_logger_history_validation_is_strict_and_complete tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_raid_validator_reports_raw_defects tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_raid_validator_traverses_sparse_and_mapped_data -v
```

Expected: 4 tests PASS; rejected mutations leave canonical records unchanged.

- [ ] **Step 6: Commit**

```powershell
git add -- 'Raid Management Addon/Database/DBRaidStore.lua' 'tests/lua/runtime_harness.lua' 'tests/test_raid_recording_integrity_behavior.py'
git commit -m "refactor(database): reuse raid validation policy"
```

### Task 2: Use one Create snapshot and three roster state operations

**Files:**
- Modify: `Raid Management Addon/Services/Raid/Roster.lua:204-269`
- Modify: `Raid Management Addon/Services/Raid/State.lua:1497-1665`
- Modify: `tests/lua/runtime_harness.lua:635-715,1867-1935`

**Interfaces:**
- Consumes: existing `RaidStore:CaptureRaidHistoryState()` and `RaidStore:RestoreRaidHistoryState(snapshot)`.
- Produces: `Raid:CaptureRosterSessionState(realm) -> snapshot`, `Raid:RestoreRosterSessionState(snapshot) -> boolean`, and `Raid:CommitRosterSession(realm, pendingMeta, num) -> rosterVersion`.
- Preserves: existing roster refresh scheduling/cancellation owners, Create failure containment, previous raid closure, attendance event order, player metadata, and the final delayed refresh.

- [ ] **Step 1: Rewrite the Create fixture against three roster methods**

Replace the fixture's `_SetNumRaidInternal`, `_EnsureRealmPlayerMetaInternal`, and `_UpsertPlayerMetaInternal` seams with:
```lua
fixture.realmPlayers = { Existing = { name = "Existing", level = 80 } }
raid.CaptureRosterSessionState = function()
	fixture.rosterCaptures = (fixture.rosterCaptures or 0) + 1
	return { numRaid = addon.State.raid.numRaid, realmPlayers = deepCopy(fixture.realmPlayers) }
end
raid.RestoreRosterSessionState = function(snapshot)
	fixture.rosterRestores = (fixture.rosterRestores or 0) + 1
	addon.State.raid.numRaid, fixture.realmPlayers = snapshot.numRaid, deepCopy(snapshot.realmPlayers); return true
end
raid.CommitRosterSession = function(_, pendingMeta, num)
	for i = 1, #pendingMeta do fixture.realmPlayers[pendingMeta[i][1]] = { name = pendingMeta[i][1] } end
	addon.State.raid.numRaid = num; fixture.rosterCommits = (fixture.rosterCommits or 0) + 1; return fixture.rosterCommits
end
```

Instrument only the existing full snapshot:
```lua
local captureHistory = fixture.store.CaptureRaidHistoryState
local restoreHistory = fixture.store.RestoreRaidHistoryState
fixture.store.CaptureRaidHistoryState = function(self)
	fixture.historyCaptures = (fixture.historyCaptures or 0) + 1; return captureHistory(self)
end
fixture.store.RestoreRaidHistoryState = function(self, snapshot)
	fixture.historyRestores = (fixture.historyRestores or 0) + 1; return restoreHistory(self, snapshot)
end
```

Add to every failure iteration:
```lua
assertEqual(1, fixture.historyCaptures, "Create must capture history once")
assertEqual(1, fixture.rosterCaptures, "Create must capture roster once")
assertEqual(1, fixture.historyRestores, "failed Create must restore history once")
assertEqual(1, fixture.rosterRestores, "failed Create must restore roster once")
```

Add to the success case:
```lua
assertEqual(1, fixture.historyCaptures, "replacement captures history once")
assertEqual(nil, fixture.historyRestores, "successful replacement does not restore")
assertEqual(1, fixture.rosterCommits, "replacement commits roster once")
```

- [ ] **Step 2: Run Create tests and verify RED**

Run:
```powershell
py -3 -m unittest tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_raid_session_create_failure_is_atomic tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_raid_session_replacement_preserves_event_order tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_raid_session_switch_failure_rolls_back_candidate -v
```

Expected: FAIL because State still captures insertion plus history and calls the old roster hook family.

- [ ] **Step 3: Implement the three roster operations**

Reuse the existing file-local state and helpers in `Roster.lua`. Add one small copier and expose only:
```lua
local function copyRosterMeta(source)
	local copy = {}
	for name, value in pairs(source or {}) do
		copy[name] = {}
		for key, item in pairs(value) do copy[name][key] = item end
	end
	return copy
end
function module:CaptureRosterSessionState(realm)
	local realmPlayers = ensureRealmPlayerMeta(realm)
	return {
		numRaid = numRaid,
		rosterVersion = rosterVersion,
		realmPlayers = realmPlayers,
		playerMeta = copyRosterMeta(realmPlayers),
	}
end
function module:RestoreRosterSessionState(snapshot)
	if type(snapshot) ~= "table" or type(snapshot.realmPlayers) ~= "table" then return false end
	numRaid = tonumber(snapshot.numRaid) or 0
	rosterVersion = tonumber(snapshot.rosterVersion) or 0
	for name in pairs(snapshot.realmPlayers) do snapshot.realmPlayers[name] = nil end
	for name, value in pairs(copyRosterMeta(snapshot.playerMeta)) do snapshot.realmPlayers[name] = value end
	resetPendingUnitRetry()
	resetLiveUnitCaches()
	return true
end
function module:CommitRosterSession(realm, pendingMeta, raidSize)
	local realmPlayers = ensureRealmPlayerMeta(realm)
	for i = 1, #(pendingMeta or {}) do upsertPlayerMeta(realmPlayers, unpack(pendingMeta[i])) end
	numRaid = tonumber(raidSize) or 0
	rosterVersion = rosterVersion + 1
	resetPendingUnitRetry()
	resetLiveUnitCaches()
	return rosterVersion
end
```

Delete `_SetNumRaidInternal`, `_BumpRosterVersionInternal`, `_ResetRosterTrackingInternal`, `_CaptureRosterRuntimeInternal`, `_RestoreRosterRuntimeInternal`, `_EnsureRealmPlayerMetaInternal`, and `_UpsertPlayerMetaInternal`.

Keep the existing scheduling and cancellation functions in their roster owner. In `State.lua`, bind their existing exports once with mandatory assertions rather than capability checks:
```lua
local scheduleRosterRefresh = assert(module._ScheduleRosterRefreshInternal, "Raid roster scheduler is not initialized")
local cancelRosterRefresh = assert(module._CancelRosterRefreshInternal, "Raid roster cancellation is not initialized")
```

Do not add scheduling APIs or another timer owner.

- [ ] **Step 4: Collapse Raid:Create to the existing full snapshot**

Replace `insertionState`, optional history capture, roster runtime, metadata snapshot, and fallback rollback with:
```lua
local raidStore = Database.GetRaidStore()
local createState = {
	history = raidStore:CaptureRaidHistoryState(),
	currentRaid = Database.GetCurrentRaid(),
	lastBoss = Database.GetLastBoss(),
	roster = module:CaptureRosterSessionState(realm),
}
if type(createState.history) ~= "table" or type(createState.roster) ~= "table" then return false end
local function rollbackCreate()
	coreState.currentRaid = createState.currentRaid
	coreState.lastBoss = createState.lastBoss
	local historyOk = raidStore:RestoreRaidHistoryState(createState.history)
	local rosterOk = module:RestoreRosterSessionState(createState.roster)
	return historyOk == true and rosterOk == true
end
```

Every Create failure after capture calls `rollbackCreate()` exactly once. Remove all Create calls to `CaptureRaidInsertionState` and `RestoreRaidInsertionState`; do not change their import callers.

In the successful commit block, replace metadata, count, version, and reset hooks with:
```lua
if createState.currentRaid then
	if type(module.CancelInstanceChecks) == "function" then module:CancelInstanceChecks() end
	cancelRosterRefresh()
	coreState.currentRaid = createState.currentRaid
	attendanceChanged, attendanceRaidNid = finalizeRaidRecord(createState.currentRaid, currentTime, true)
	coreState.currentRaid = raidId
	Database.SetLastBoss(nil)
end
module:CommitRosterSession(realm, pendingPlayerMeta, num)
resetLootContextState()
```

After publication, call `scheduleRosterRefresh()` inside the existing `pcall`. In `End` and `CheckInitialRaidState`, replace scheduler capability checks with the asserted locals. Leave `_PublishRosterDelta` unchanged because Debug has a real caller.

- [ ] **Step 5: Run the raid-creation and roster slice for GREEN**

Run:
```powershell
py -3 -m unittest tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_raid_session_create_failure_is_atomic tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_raid_session_replacement_preserves_event_order tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_raid_session_switch_failure_rolls_back_candidate tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_real_roster_dispatch_and_scheduled_paths_publish_once tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_real_roster_session_end_publishes_final_delta -v
```

Expected: 5 tests PASS; replacement order remains insert, attendance event, RaidCreate event.

- [ ] **Step 6: Commit**

```powershell
git add -- 'Raid Management Addon/Services/Raid/Roster.lua' 'Raid Management Addon/Services/Raid/State.lua' 'tests/lua/runtime_harness.lua'
git commit -m "refactor(raid): simplify create rollback ownership"
```

### Task 3: Replace logger mutate-and-rollback with one store commit

**Files:**
- Modify: `Raid Management Addon/Database/DBRaidStore.lua:1495-1564`
- Modify: `Raid Management Addon/Services/Logger/Actions.lua:613-785,1347-1525`
- Modify: `tests/lua/runtime_harness.lua:2541-2750,3821-3948`
- Modify: `tests/test_raid_recording_integrity_behavior.py:118-150`

**Interfaces:**
- Consumes: cleanup plan fields already built by Logger: `protectedRaidNid`, `raidCandidates`, `lootCandidates`, and captured revisions/fingerprints.
- Produces: `RaidStore:CommitRaidHistoryCleanup(plan, currentRaidNid) -> result` or `nil, reason`; result is `{ raidsRemoved, lootRemoved, removedRaidNids, affectedRaidNids }`.
- Preserves: root table identity, active raid, revisions, stable IDs, one completion event, synchronous result shape, bounded asynchronous scan, callback-once, and cancellation-before-commit.

- [ ] **Step 1: Replace rollback uncertainty with detached failure behavior**

Replace `logger_cleanup_snapshot_failures_are_terminal` with:
```lua
function cases.logger_cleanup_detached_failure_is_atomic(addon)
	local fixture, actions = installLoggerCleanupFixture(addon)
	local root = fixture.store:GetRawRaids(); local before = deepCopy(root)
	local originalCommit = fixture.store.CommitRaidHistoryCleanup
	fixture.store.CommitRaidHistoryCleanup = function() return nil, "INJECTED_FAILURE" end
	local result = actions:CleanupRaidHistory({ emptyRaids = true, nonEpicLoot = true })
	fixture.store.CommitRaidHistoryCleanup = originalCommit
	assertEqual(true, result.failed, "store rejection must fail cleanup"); assertEqual("INJECTED_FAILURE", result.error)
	assertTrue(root == fixture.store:GetRawRaids(), "cleanup must preserve root identity")
	assertTrue(deepEqual(before, root), "failed detached commit must preserve history")
	assertEqual(nil, result.rollbackFailed, "rollback protocol must be absent"); assertEqual(0, #fixture.events)
	print("PASS logger_cleanup_detached_failure_is_atomic")
end
```

Rename its Python entry point accordingly. In `logger_async_cleanup_store_failure_is_atomic`, inject `CommitRaidHistoryCleanup = function() return nil, "INJECTED_FAILURE" end` and keep assertions for unchanged history/revision/current raid, one incomplete callback, terminal handle, and zero events. Delete rollback-failure assertions and injected failures in `DeleteRaidsByNid`, `CaptureRaidHistoryState`, and `RestoreRaidHistoryState`.

- [ ] **Step 2: Run the two failure cases and verify RED**

Run:
```powershell
py -3 -m unittest tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_logger_cleanup_detached_failure_is_atomic tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_logger_async_cleanup_store_failure_is_atomic -v
```

Expected: FAIL because the single store commit does not exist and Actions still exposes rollback state.

- [ ] **Step 3: Implement the detached store commit without replacing the root**

Add `CommitRaidHistoryCleanup` before `DeleteRaid` in `DBRaidStore.lua`. Use the existing `copyRaidHistoryValue`, `EnsureRaidRuntime`, revision methods, and `tremove`:
```lua
function module:CommitRaidHistoryCleanup(plan, currentRaidNid)
	if type(plan) ~= "table" or tonumber(plan.protectedRaidNid) ~= tonumber(currentRaidNid) then
		return nil, "CONFLICT"
	end
	local root = ensureRaidsTable()
	local candidate = copyRaidHistoryValue(root)
	local byNid, deleteSet, lootDeleteSet = {}, {}, {}
	for i = 1, #candidate do byNid[tonumber(candidate[i].raidNid)] = candidate[i] end
	for i = 1, #plan.raidCandidates do
		local entry = plan.raidCandidates[i]
		local raid = byNid[entry.raidNid]
		if entry.raidNid == tonumber(currentRaidNid) or not raid
			or self:GetRaidSyncRevision(raid) ~= entry.baseRevision then return nil, "CONFLICT" end
		deleteSet[entry.raidNid] = true
	end
	for i = 1, #plan.lootCandidates do
		local entry = plan.lootCandidates[i]
		local raid = byNid[entry.raidNid]
		local runtime = raid and self:EnsureRaidRuntime(raid) or nil
		local loot = runtime and runtime.lootByNid and runtime.lootByNid[entry.lootNid] or nil
		if not raid or not loot or self:GetRaidSyncRevision(raid) ~= entry.baseRevision
			or (tonumber(loot.syncRevision) or 0) ~= entry.lootRevision
			or tonumber(loot.itemId) ~= entry.itemId or loot.itemLink ~= entry.itemLink
			or tonumber(loot.bossNid) ~= entry.bossNid then return nil, "CONFLICT" end
		lootDeleteSet[entry.raidNid] = lootDeleteSet[entry.raidNid] or {}
		lootDeleteSet[entry.raidNid][entry.lootNid] = true
	end
	local removedRaidNids, affectedRaidNids = {}, {}
	local raidsRemoved, lootRemoved = 0, 0
	for i = #candidate, 1, -1 do
		local raid = candidate[i]
		local raidNid = tonumber(raid.raidNid)
		if deleteSet[raidNid] then
			tremove(candidate, i)
			raidsRemoved = raidsRemoved + 1
			removedRaidNids[#removedRaidNids + 1] = raidNid
		elseif lootDeleteSet[raidNid] then
			for lootIndex = #raid.loot, 1, -1 do
				if lootDeleteSet[raidNid][tonumber(raid.loot[lootIndex].lootNid)] then
					tremove(raid.loot, lootIndex)
					lootRemoved = lootRemoved + 1
				end
			end
			local valid, reason = validateRaidHistory(raid)
			if not valid then return nil, reason end
			self:TouchRaidSyncRevision(raid, "history_cleanup")
			self:EnsureRaidRuntime(raid)
			affectedRaidNids[#affectedRaidNids + 1] = raidNid
		end
	end
	for i = #root, 1, -1 do root[i] = nil end
	for i = 1, #candidate do root[i] = candidate[i] end
	markRaidNidIndexDirty()
	rebuildRaidNidIndex()
	return { raidsRemoved = raidsRemoved, lootRemoved = lootRemoved,
		removedRaidNids = removedRaidNids, affectedRaidNids = affectedRaidNids }
end
```

All validation and candidate work occurs before the two assignment loops. Those loops are the only publication step and keep the `RMA_Raids` root identity stable.

- [ ] **Step 4: Reduce Logger Actions to plan, commit, and notify**

Delete `findLootByNid`, `validateHistoryCleanupPlan`, `applyHistoryCleanupPlan`, and snapshot/restore code. Replace `executeHistoryCleanupPlan` with:
```lua
local function executeHistoryCleanupPlan(raidStore, plan, result)
	local committed, failure = raidStore:CommitRaidHistoryCleanup(plan, getCurrentRaidNid())
	if not committed then return false, failure end
	result.emptyRaids = plan.emptyRaids
	result.noBossEncounter = plan.noBossEncounter
	result.raidsRemoved = committed.raidsRemoved
	result.lootRemoved = committed.lootRemoved
	result.nonEpicLoot = committed.lootRemoved
	result.affectedRaidNids = committed.affectedRaidNids
	for i = 1, #committed.removedRaidNids do result.affectedRaidNids[#result.affectedRaidNids + 1] = committed.removedRaidNids[i] end
	result.changed = result.raidsRemoved > 0 or result.lootRemoved > 0
	result.complete = true
	return true
end
```

Both failure branches become:
```lua
result = newHistoryCleanupResult()
result.failed = true
result.conflict = failure == "CONFLICT"
result.error = tostring(failure)
```

Remove `rollbackFailed`, `rollbackError`, and `rollbackUncertain`. Keep `restoreCurrentRaidIndex`, cancellation before commit, chunk size/delay, callback-once behavior, and the single changed-data event after success.

- [ ] **Step 5: Run the cleanup behavior slice for GREEN**

Run:
```powershell
py -3 -m unittest tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_logger_cleanup_is_store_owned_and_revision_coherent tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_logger_cleanup_preserves_active_raid tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_logger_async_cleanup_conflicts_when_candidate_becomes_current tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_logger_async_cleanup_cancel_rolls_back_staged_work tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_logger_async_cleanup_completed_handle_is_terminal_not_cancelled tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_logger_async_cleanup_store_failure_is_atomic tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_logger_cleanup_detached_failure_is_atomic -v
```

Expected: 7 tests PASS; root identity and active raid are preserved, affected revisions advance once, cancellation/conflict publish nothing, and success publishes once.

- [ ] **Step 6: Prove cleanup rollback machinery is gone and commit**

Run:

```powershell
rg -n "rollbackFailed|rollbackError|rollbackUncertain|applyHistoryCleanupPlan|validateHistoryCleanupPlan" 'Raid Management Addon/Services/Logger/Actions.lua' tests
```

Expected: no matches.

```powershell
git add -- 'Raid Management Addon/Database/DBRaidStore.lua' 'Raid Management Addon/Services/Logger/Actions.lua' 'tests/lua/runtime_harness.lua' 'tests/test_raid_recording_integrity_behavior.py'
git commit -m "refactor(logger): commit cleanup from detached history"
```

### Gate: Verify the complete raid-history batch

**Files:**
- Verify: all files touched by Tasks 1-3.

**Interfaces:**
- Consumes: the three task outputs.
- Produces: a verified, independently revertible raid-history simplification batch.

- [ ] **Step 1: Run affected suites**

```powershell
py -3 -m unittest tests.test_runtime_foundations_behavior tests.test_raid_recording_integrity_behavior -v
```

Expected: all tests PASS.

- [ ] **Step 2: Run runtime and style validation**

```powershell
py -3 '..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py' 'Raid Management Addon\Raid Management Addon.toc'
py -3 '..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py' 'Raid Management Addon'
py -3 '..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py' 'Raid Management Addon'
stylua --check -- 'Raid Management Addon/Database/DBRaidStore.lua' 'Raid Management Addon/Services/Raid/Roster.lua' 'Raid Management Addon/Services/Raid/State.lua' 'Raid Management Addon/Services/Logger/Actions.lua' 'tests/lua/runtime_harness.lua'
luacheck -- 'Raid Management Addon/Database/DBRaidStore.lua' 'Raid Management Addon/Services/Raid/Roster.lua' 'Raid Management Addon/Services/Raid/State.lua' 'Raid Management Addon/Services/Logger/Actions.lua' 'tests/lua/runtime_harness.lua'
```

Expected: all five commands exit 0; TOC, Lua 5.1 syntax, and Lua 5.1 `xpcall` checks pass.

- [ ] **Step 3: Check simplification and diff coherence**

```powershell
rg -n "validateLoggerHistoryMutation|_SetNumRaidInternal|_BumpRosterVersionInternal|_ResetRosterTrackingInternal|_CaptureRosterRuntimeInternal|_RestoreRosterRuntimeInternal|_EnsureRealmPlayerMetaInternal|_UpsertPlayerMetaInternal|rollbackUncertain" 'Raid Management Addon' tests
git diff --check d4029e7..HEAD
git status --short --branch
```

Expected: retired-symbol search has no matches; diff check exits 0; status contains no unexpected files. Do not run the in-game smoke test or integrate at this stage.
