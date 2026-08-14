# Database Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make archive v1 the only raid persistence model, remove obsolete Database APIs, and simplify read projections without changing RMA SavedVariables, sync, or user-visible behavior.

**Architecture:** `SavedVariables.GetRaids()` remains the single source of the canonical archive and `DBRaidStore` stops carrying an unreachable array-root implementation. Query projections operate directly on canonical sequences, build only query-specific transient data, and reuse caller-owned output buffers without recursively traversing the raid graph.

**Tech Stack:** WoW 3.3.5a build 12340, Interface 30300, Lua 5.1.5, Python `unittest`, PowerShell repository validators, StyleLua, Luacheck.

## Global Constraints

- Keep public SavedVariables exactly `RMA_Raids`, `RMA_Players`, `RMA_Reserves`, `RMA_Warnings`, `RMA_Spammer`, and `RMA_Options`.
- Keep the archive wire shape `{ formatVersion = 1, activeRaidUid, order, raids }` unchanged.
- Do not add non-RMA imports, implicit array migrations, Ace2/Ace3, Retail APIs, or Lua 5.2+ syntax.
- Keep sync protocol, authority, recovery, handover, event reducer, and validator behavior unchanged.
- Preserve query result fields, ordering, filtering, stable future-schema errors, and read-only input behavior.
- Do not modify files under `Raid Management Addon/Libs/`.

---

### Task 1: Canonical Archive-Only Store And API Reduction

**Files:**
- Modify: `tests/lua/runtime_harness.lua:3187-3211`
- Modify: `tests/test_runtime_bootstrap_contract.py:1-180`
- Modify: `Raid Management Addon/Database/DB.lua:80-98`
- Modify: `Raid Management Addon/Database/DBRaidStore.lua:151-176,463-645,719-721,1270-1373,1703-1805,1853-1953,2188-2211,2311-2374`

**Interfaces:**
- Consumes: `SavedVariables.GetRaids() -> archiveV1`, `RaidValidator:ValidateArchive(archive) -> true | nil, reason`.
- Produces: the existing `RaidStore` API backed only by archive v1; `CaptureRaidHistoryState()` and `RestoreRaidHistoryState(snapshot)` remain the sole full-archive rollback pair.
- Removes: `Database.EnsureArchive`, `RaidStore:CaptureRaidInsertionState`, and `RaidStore:RestoreRaidInsertionState`.

- [ ] **Step 1: Write failing behavior and architecture tests**

Replace the insertion-era assertions in `cases.raid_replication_archive_rollback` with the supported API contract:

```lua
function cases.raid_replication_archive_rollback(addon)
	local store = installRaidArchiveFixture(addon)
	local emptyArchive = deepCopy(store:EnsureArchive())
	assertEqual(nil, store.CaptureRaidInsertionState, "obsolete insertion capture API must be absent")
	assertEqual(nil, store.RestoreRaidInsertionState, "obsolete insertion restore API must be absent")

	local historyCapture = store:CaptureRaidHistoryState()
	assert(store:CreateActiveRaid({ authorityKey = "Leader-Realm", raidNid = 73, zone = "Ulduar", serverTime = 1721120100 }))
	local insertedArchive = store:EnsureArchive()
	assertTrue(insertedArchive.activeRaidUid ~= nil and #insertedArchive.order == 1,
		"simulated post-insert failure setup did not persist canonical raid")
	assertTrue(store:RestoreRaidHistoryState(historyCapture), "history restore failed")
	assertTrue(deepEqual(emptyArchive, store:EnsureArchive()), "history restore did not restore full archive")
	assertEqual(nil, addon.Database.EnsureRaidByNid(73), "history restore left stale raidNid index")
	assertEqual(0, #store:GetAllRaids(), "history restore left an ordered feature row")
	print("PASS raid_replication_archive_rollback")
end
```

In `cases.raid_validator_traverses_sparse_and_mapped_data`, stop installing a
noncanonical root into `_G.RMA_Raids`. Exercise the validator's raw diagnostic
input independently:

```lua
local getRawRaids = addon.DB.RaidStore.GetRawRaids
addon.DB.RaidStore.GetRawRaids = function()
	return { [2] = raid, mapped = "malformed raid" }
end
local report = addon.DB.RaidValidator:ValidateAllRaids({ maxDetails = 200 })
addon.DB.RaidStore.GetRawRaids = getRawRaids
```

Add this contract test to `RuntimeBootstrapContractTest`:

```python
def test_raid_store_has_one_canonical_archive_root(self) -> None:
    store = (ADDON / "Database" / "DBRaidStore.lua").read_text(encoding="utf-8")
    db = (ADDON / "Database" / "DB.lua").read_text(encoding="utf-8")
    for retired in (
        "isRaidArchive",
        "buildRaidNidIndexSignature",
        "hasRawRaidNid",
        "legacyRaids",
        "CaptureRaidInsertionState",
        "RestoreRaidInsertionState",
    ):
        self.assertNotIn(retired, store)
    self.assertNotIn("function Database.EnsureArchive", db)
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_archive_capture_restore_rolls_back_every_canonical_key tests.test_runtime_bootstrap_contract.RuntimeBootstrapContractTest.test_raid_store_has_one_canonical_archive_root
```

Expected: FAIL because the three obsolete APIs and the array-root helpers still exist.

- [ ] **Step 3: Remove the obsolete facade and rollback APIs**

Delete this pass-through from `DB.lua`:

```lua
function Database.EnsureArchive()
	return Database.GetRaidStore():EnsureArchive()
end
```

Delete these methods from `DBRaidStore.lua`:

```lua
function module:CaptureRaidInsertionState()
	local raids = ensureRaidsTable()
	return { raids = deepCopy(raids), nextRaidNid = storeState.nextRaidNid }
end

function module:RestoreRaidInsertionState(snapshot)
	return false, "LEGACY_SYNC_DISABLED"
end
```

Keep `restoreCapturedRaids`, `CaptureRaidHistoryState`, and `RestoreRaidHistoryState` unchanged except for archive-only naming of local variables.

- [ ] **Step 4: Collapse the store to archive v1**

Delete `isRaidArchive`, `buildRaidNidIndexSignature`, `hasRawRaidNid`, and every array-root branch. Replace the shared index entry points with archive-only implementations:

```lua
local function rebuildRaidNidIndex()
	local archive = ensureRaidsTable()
	return archive, rebuildArchiveRaidNidIndex(archive)
end

local function ensureRaidNidIndex()
	local archive = ensureRaidsTable()
	return archive, ensureArchiveRaidNidIndex(archive)
end

local function getNextRaidNid(preferred)
	local _, raidIdxByNid = ensureRaidNidIndex()
	local raidNid = tonumber(preferred)
	if raidNid and raidNid > 0 and not raidIdxByNid[raidNid] then
		if raidNid >= (tonumber(storeState.nextRaidNid) or 1) then
			storeState.nextRaidNid = raidNid + 1
		end
		return raidNid
	end
	local nextRaidNid = tonumber(storeState.nextRaidNid) or 1
	while raidIdxByNid[nextRaidNid] do
		nextRaidNid = nextRaidNid + 1
	end
	storeState.nextRaidNid = nextRaidNid + 1
	return nextRaidNid
end
```

Make ordered reads archive-only:

```lua
function module:GetAllRaids()
	local archive = self:EnsureArchive()
	local states = {}
	for i = 1, #archive.order do
		local record = archive.raids[archive.order[i]]
		states[i] = record and record.state or nil
	end
	return states
end

function module:GetRawRaids()
	return self:GetAllRaids()
end

function module:EnsureRaidByIndex(index)
	local idx = tonumber(index)
	if not idx or idx < 1 then
		return nil, nil
	end
	return self:GetStateByIndex(idx)
end

function module:EnsureRaidByNid(raidNid)
	local nid = tonumber(raidNid)
	if not nid then
		return nil, nil, nil
	end
	local archive = self:EnsureArchive()
	local raidIdxByNid = ensureArchiveRaidNidIndex(archive)
	local idx = raidIdxByNid[nid]
	local record = idx and archive.raids[archive.order[idx]] or nil
	return record and record.state or nil, idx, nid
end

function module:NormalizeAllRaids()
	local archive = ensureRaidsTable()
	markRaidNidIndexDirty()
	rebuildArchiveRaidNidIndex(archive)
	return archive
end

function module:PrepareAllRaidsForSave()
	return ensureRaidsTable()
end
```

In `CommitRaidHistoryMutation`, replace the complete `if not record then ... end`
legacy-array mutation block with:

```lua
if not record then
	return false, "CONFLICT"
end
```

Make single deletion archive-only:

```lua
function module:DeleteRaid(raidNid)
	local archive, archiveReason = requireValidArchive()
	if not archive then
		return false, nil, archiveReason
	end
	local archiveKey, _, resolveReason = resolveDeletableArchiveKeyByRaidNid(archive, raidNid)
	if not archiveKey then
		return false, nil, resolveReason
	end
	return self:DeleteRaidByArchiveKey(archiveKey)
end
```

For `DeleteRaidsByNid`, retain the existing archive-key resolution through
`resolveDeletableArchiveKeyByRaidNid` and `DeleteRaidsByArchiveKey`, then delete
the array fallback beginning with `local protectedRaidNid`. For
`DeleteLootByNid`, call `requireValidArchive()` unconditionally before resolving
the raid. Remove all remaining loops over numeric root keys. Keep
`SavedVariables.ReplaceRaids(candidate)` for atomic archive replacements.

- [ ] **Step 5: Run focused Database tests and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_runtime_bootstrap_contract
```

Expected: all tests PASS with no Lua errors.

- [ ] **Step 6: Commit the archive-only store**

```powershell
git add -- 'Raid Management Addon/Database/DB.lua' 'Raid Management Addon/Database/DBRaidStore.lua' 'tests/lua/runtime_harness.lua' 'tests/test_runtime_bootstrap_contract.py'
git commit -m "refactor(database): keep one raid archive model"
```

---

### Task 2: Direct Read Projections And Bounded Buffer Protection

**Files:**
- Modify: `tests/lua/runtime_harness.lua:7936-8035`
- Modify: `tests/test_raid_replication_behavior.py:300-310`
- Modify: `Raid Management Addon/Database/DBRaidQueries.lua:29-110,316-571`
- Modify: `Raid Management Addon/Database/DBRaidStore.lua:1528-1617`

**Interfaces:**
- Consumes: canonical raid state sequences and the existing optional caller-owned `out` arrays.
- Produces: unchanged `RaidQueries` result shapes and filters without `RaidStore:GetRaidRuntimeForRead`.
- Preserves: write-side `RaidStore:EnsureRaidRuntime` and `RaidStore:UpsertLootIndex`.

- [ ] **Step 1: Write failing tests for the smaller read contract**

Replace the read-index setup in `cases.raid_read_indexes_are_fresh_and_do_not_alias` with an absence assertion while retaining the same-length mutation checks:

```lua
function cases.raid_read_indexes_are_fresh_and_do_not_alias(addon)
	installRaidDatabaseStubs(addon)
	local raid = canonicalRaidFixture()
	assertEqual(nil, addon.DB.RaidStore.GetRaidRuntimeForRead, "whole-raid read index API must be absent")

	local queries = addon.DB.RaidQueries
	assertEqual(1, #queries:GetLoot(raid, 1, "Alpha"), "initial query should use current content")
	raid.players[1].name = "Gamma"
	raid.loot[1].looterNid = 2
	addon.DB.RaidStore:UpsertLootIndex(raid, raid.loot[1], 1)
	assertEqual(0, #queries:GetLoot(raid, 1, "Alpha"), "query must observe same-length player and loot changes")
	assertEqual(1, #queries:GetLoot(raid, 1, "Beta"), "query must observe the replacement looter")
	print("PASS raid_read_indexes_are_fresh_and_do_not_alias")
end
```

Limit `cases.raid_query_output_buffers_never_alias_canonical_data` to:

```lua
local canonicalOut = spec.collection(raid)
local rows = spec.call(raid, canonicalOut)
assertEqual(spec.expected, #rows, "top-level canonical output alias should return complete query " .. i)
assertTrue(rows ~= canonicalOut, "top-level canonical output alias should be replaced for query " .. i)
assertTrue(deepEqual(before, raid), "top-level output alias must preserve raid for query " .. i)

raid = canonicalRaidFixture()
local callerOut = { { stale = true }, { stale = true }, { stale = true } }
rows = spec.call(raid, callerOut)
assertTrue(rows == callerOut, "caller-owned output table should remain reusable for query " .. i)
```

Extend `test_runtime_indexes_never_enter_canonical_raid_state` in `test_raid_replication_behavior.py`:

```python
store = Path("Raid Management Addon/Database/DBRaidStore.lua").read_text(encoding="utf-8")
queries = Path("Raid Management Addon/Database/DBRaidQueries.lua").read_text(encoding="utf-8")
self.assertNotIn("GetRaidRuntimeForRead", store)
self.assertNotIn("collectCanonicalTables", queries)
```

- [ ] **Step 2: Run focused query tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_runtime_indexes_never_enter_canonical_raid_state tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_queries_and_validator_have_no_runtime_field_exception
```

Then run the Lua cases directly:

```powershell
py -3 -c "from tests.lua_test_runner import run_lua_case; print(run_lua_case('raid_read_indexes_are_fresh_and_do_not_alias').stdout); print(run_lua_case('raid_query_output_buffers_never_alias_canonical_data').stdout)"
```

Expected: FAIL because `GetRaidRuntimeForRead` and `collectCanonicalTables` still exist.

- [ ] **Step 3: Replace recursive buffer discovery with shallow ownership checks**

Replace `collectCanonicalTables`, `prepareOutputRows`, and `acquireOutputRow` with:

```lua
local function isTopLevelCanonicalTable(raid, value)
	return value == raid
		or value == raid.players
		or value == raid.bossKills
		or value == raid.loot
		or value == raid.attendance
		or value == raid.changes
end

local function prepareOutputRows(raid, source, out)
	local sourceRows = {}
	for i = 1, #source do
		if type(source[i]) == "table" then
			sourceRows[source[i]] = true
		end
	end
	if type(out) ~= "table" or isTopLevelCanonicalTable(raid, out) then
		return {}, sourceRows
	end
	return out, sourceRows
end

local function acquireOutputRow(rows, index, sourceRows)
	local row = rows[index]
	if type(row) ~= "table" or sourceRows[row] then
		row = {}
		rows[index] = row
		return row
	end
	return clearRow(row)
end
```

In each projection, resolve its source sequence before calling `prepareOutputRows`:

```lua
local bosses = getCollection(raid.bossKills)
local rows, sourceRows = prepareOutputRows(raid, bosses, out)
```

Use `players` for attendance projections and `lootRows` for loot projections.

- [ ] **Step 4: Remove the whole-raid read index and use direct reads**

Delete `RaidStore:GetRaidRuntimeForRead`. Remove `ensureRuntime` from
`DBRaidQueries.lua`. Pass `nil` to existing lookup helpers so they take their
already implemented direct-scan fallback:

```lua
function module:ResolveLootLooterName(raid, loot, runtime)
	raid = normalizeRaid(raid)
	return resolveLootLooterName(raid, runtime, loot)
end
```

For `GetRaidAttendance`, call:

```lua
local attendanceEntry = getAttendanceEntry(raid, nil, player.playerNid)
```

For `GetBossAttendance`, resolve the boss directly and build only its attendee
set:

```lua
local bossKill = findBossByNid(raid, queryNid)
local set = {}
if type(bossKill) == "table" and isBossFightRecord(bossKill) and type(bossKill.players) == "table" then
	for i = 1, #bossKill.players do
		local playerNid = tonumber(bossKill.players[i])
		if playerNid and playerNid > 0 then
			set[playerNid] = true
		end
	end
end
```

For `GetLoot`, scan `lootRows` once and resolve player/boss rows through the
existing direct helpers. Do not allocate unrelated attendance or loot index
maps. Preserve the current filter and output field assignments exactly.

- [ ] **Step 5: Run focused query tests and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_raid_replication_behavior
py -3 -c "from tests.lua_test_runner import run_lua_case; names = ('raid_queries_are_deeply_read_only', 'raid_queries_reject_future_schema_without_touching_output', 'raid_queries_guard_malformed_collections', 'raid_read_indexes_are_fresh_and_do_not_alias', 'raid_query_output_buffers_never_alias_canonical_data'); [print(run_lua_case(name).stdout) for name in names]"
```

Expected: the Python module and all five direct Lua query cases PASS.

- [ ] **Step 6: Commit the query simplification**

```powershell
git add -- 'Raid Management Addon/Database/DBRaidQueries.lua' 'Raid Management Addon/Database/DBRaidStore.lua' 'tests/lua/runtime_harness.lua' 'tests/test_raid_replication_behavior.py'
git commit -m "refactor(database): simplify raid read projections"
```

---

### Task 3: Integration Verification And Coherence Review

**Files:**
- Inspect: `Raid Management Addon/Raid Management Addon.toc`
- Inspect: `Raid Management Addon/Database/*.lua`
- Inspect: `tests/**/*.py`
- Inspect: `tests/lua/runtime_harness.lua`

**Interfaces:**
- Consumes: the archive-only store and direct query projections from Tasks 1-2.
- Produces: verified Lua 5.1-compatible runtime with no stale TOC, API, or test references.

- [ ] **Step 1: Search for retired APIs and models**

Run:

```powershell
rg -n 'Database\.EnsureArchive|CaptureRaidInsertionState|RestoreRaidInsertionState|GetRaidRuntimeForRead|collectCanonicalTables|isRaidArchive|legacyRaids|buildRaidNidIndexSignature|hasRawRaidNid' 'Raid Management Addon' tests -g '*.lua' -g '*.py' -g '!Libs/**'
```

Expected: no matches. If a match is a test description rather than a runtime
reference, rename it to describe the canonical behavior and rerun the search.

- [ ] **Step 2: Run the complete automated suite**

Run:

```powershell
py -3 -m unittest discover -s tests -p 'test_*.py'
```

Expected: all tests PASS with zero failures and zero errors.

- [ ] **Step 3: Run repository and WotLK validators**

Run:

```powershell
& '.\tools\check-rma.ps1'
py -3 '.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py' 'Raid Management Addon\Raid Management Addon.toc'
py -3 '.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py' 'Raid Management Addon'
py -3 '.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py' 'Raid Management Addon'
stylua --check -- 'Raid Management Addon\Database\DB.lua' 'Raid Management Addon\Database\DBRaidStore.lua' 'Raid Management Addon\Database\DBRaidQueries.lua' 'tests\lua\runtime_harness.lua'
luacheck 'Raid Management Addon\Database\DB.lua' 'Raid Management Addon\Database\DBRaidStore.lua' 'Raid Management Addon\Database\DBRaidQueries.lua'
rg -n '<Scripts>|<On[A-Za-z]+>' 'Raid Management Addon\UI' -g '*.xml'
git diff --check
```

Expected: every validator exits 0; the XML scan returns no matches.

- [ ] **Step 4: Review commit coherence**

Run:

```powershell
git status --short --branch
git diff HEAD~2 --stat
git diff HEAD~2 -- 'Raid Management Addon/Raid Management Addon.toc'
rg -n 'Database\\DB.lua|Database\\DBRaidStore.lua|Database\\DBRaidQueries.lua' 'Raid Management Addon\Raid Management Addon.toc'
```

Confirm that no TOC entry changed, no runtime file is untracked, no deleted API
has a caller, SavedVariables names are unchanged, and only the intended Database
and test files changed.

- [ ] **Step 5: Record the manual smoke-test limitation**

Report that automated validation cannot prove these in-client checks:

```text
Login without Lua errors; /rma opens; raid creation and conclusion work;
Logger and Attendance lists refresh; /reload preserves RMA_Raids;
live replication and historical sharing complete between two 3.3.5a clients.
```

Do not claim in-game verification unless those checks were actually performed.
