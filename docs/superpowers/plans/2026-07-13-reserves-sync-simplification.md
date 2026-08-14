# Reserves and Sync Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish reserve values and their derived indexes from one detached candidate, while removing identity-preserving rollback machinery and public test-only sync seams.

**Architecture:** Reserve edits and imports will validate and build SavedVariables data, runtime data, display indexes, and metadata before touching canonical roots. Publication then swaps the prepared roots once and emits observers after commit; sync keeps its existing bounds, checksum projection, wire format, authorization, consent, replay, TTL, and correlation behavior.

**Tech Stack:** Lua 5.1, World of Warcraft WotLK 3.3.5a API, Python `unittest`, repository Lua runtime harness.

## Global Constraints

- Keep Interface `30300` and Lua 5.1 compatibility; do not use Retail/Classic-only APIs or Lua 5.2+ syntax.
- Do not change `RMA_*` SavedVariables names or schemas, addon-message prefixes, protocol versions, or wire formats.
- Preserve all inbound payload, row, byte, queue, chunk, TTL, authorization, consent, replay, revision, and sender/request-correlation checks.
- Persistent mutation order is `input -> validation -> detached candidate -> atomic commit -> event/UI`.
- No test may require SavedVariables, runtime roots, index roots, or reserve rows to preserve `rawequal` identity across a failed or successful publication.
- Do not edit vendored libraries, XML, TOC load order, or unrelated runtime owners.
- Runtime code, comments, diagnostics, and UI text remain ASCII.
- Run `stylua` and `luacheck` only on the Lua files touched by this plan; do not perform repo-wide formatting.

---

## File Map

- `Raid Management Addon/Services/Reserves.lua`: owns canonical reserve values, mutation candidates, publication, local checksum/serialization helpers, and root selection.
- `Raid Management Addon/Services/Reserves/Display.lua`: builds derived reserve indexes into caller-provided detached tables; it does not publish roots.
- `Raid Management Addon/Database/DBSyncer.lua`: owns logger-history sync request lifecycle; the unused manual cancellation facade is removed while internal terminalization remains private.
- `tests/lua/runtime_harness.lua`: verifies reserve values/cache/events and public sync workflows without private identity or cancellation seams.
- `tests/test_reserves_integrity_behavior.py`: exposes the focused reserve Lua cases to `unittest`.
- `tests/test_sync_communications_behavior.py`: exposes the focused sync lifecycle cases and asserts that the test-only cancellation API is absent.

### Task 1: Write the reserve detached-publication contract without committing RED

**Files:**
- Modify: `tests/lua/runtime_harness.lua:5250-6106`
- Modify: `tests/test_reserves_integrity_behavior.py:5-75`

**Interfaces:**
- Consumes: `Reserves:ApplyBatch(commands) -> true, summary | nil, reason, rowIndex`; `Reserves:GetPlayerReserveEntries(playerName) -> row[]`; `Reserves:GetSyncMetadata() -> metadata`; `Reserves._Sync:GetPayload() -> reserves, metadata`.
- Produces: behavioral coverage for detached build failure, single publication, canonical value preservation, coherent derived lookup, and absence of `BuildCanonicalSerialization` from the public module.

- [ ] **Step 1: Rewrite the bulk-edit case so it fails on the current identity-preserving implementation**

In `cases.reserves_bulk_edits_are_atomic`, remove direct calls to `reserves.BuildCanonicalSerialization`, remove checksum monkey-patching, and replace the persistence-fault identity block with this contract:

```lua
assertEqual(nil, reserves.BuildCanonicalSerialization,
	"canonical serialization must remain a private reserve implementation detail")

local savedBefore = deepCopy(_G.RMA_Reserves)
local runtimeBefore = deepCopy(select(1, reserves._Sync:GetPayload()))
local savesBefore, eventsBefore = fixture.saveCount or 0, #fixture.events
fixture.failStage = "index"
local ok, reason = reserves:ApplyBatch({
	{ kind = "quantity", playerName = "Alpha", itemId = 100, value = 4 },
})
fixture.failStage = nil
assertEqual(nil, ok, "detached index failure must reject the batch")
assertEqual("publish_failed", reason, "detached index failure reason differs")
assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "failed detached build must preserve SavedVariables values")
assertTrue(deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
	"failed detached build must preserve runtime values")
assertEqual(savesBefore, fixture.saveCount or 0, "failed detached build must not save")
assertEqual(eventsBefore, #fixture.events, "failed detached build must not publish")
```

Keep the existing malformed-input, 500-command bound, net-no-op, summary, save-count, event-count, and synced-cache promotion assertions. Do not weaken those invariants.

- [ ] **Step 2: Replace reserve `rawequal` assertions with value and behavior assertions**

Within reserve cases only (`tests/lua/runtime_harness.lua:5311-6106`), delete assertions about the identity of `_G.RMA_Reserves`, `_Sync:GetPayload()`, and reserve rows. For every deleted assertion, retain or add the corresponding value assertion, for example:

```lua
assertTrue(deepEqual(savedBefore, _G.RMA_Reserves), "failed publication must preserve SavedVariables values")
assertTrue(deepEqual(runtimeBefore, select(1, reserves._Sync:GetPayload())),
	"failed publication must preserve runtime values")
assertEqual(expectedQuantity, reserves:GetReserveCountForItem(itemId, playerName),
	"derived reserve lookup must match the published candidate")
assertEqual(eventsBefore, #fixture.events, "failed publication must not notify observers")
```

Change injected `ReplaceReserves = "mutate_then_throw"` scenarios to fail before assignment, matching the real `SavedVariables.ReplaceReserves` contract:

```lua
ReplaceReserves = function(value)
	if fixture.failReplace then error("injected reserve persistence failure") end
	fixture.saveCount = (fixture.saveCount or 0) + 1
	_G.RMA_Reserves = deepCopy(value or {})
	return _G.RMA_Reserves
end
```

Retain scheduler-failure, malformed import, direct import revalidation, alias failure, notification containment, and cache-ownership coverage. Those are behavioral invariants, not identity seams.

- [ ] **Step 3: Rename Python test descriptions that promise exact table rollback**

In `tests/test_reserves_integrity_behavior.py`, keep the same Lua cases but rename the Python methods as follows:

```python
def test_async_import_publish_failure_preserves_values_and_events(self) -> None:
    result = run_lua_case("reserves_async_import_publish_faults_rollback_exact_state")
    self.assertIn("PASS reserves_async_import_publish_faults_rollback_exact_state", result.stdout)

def test_single_edits_publish_detached_values_atomically(self) -> None:
    result = run_lua_case("reserves_single_edits_rollback_exact_state")
    self.assertIn("PASS reserves_single_edits_rollback_exact_state", result.stdout)
```

The case identifiers remain stable in this batch so the test registration table does not need an unrelated rename.

- [ ] **Step 4: Run the focused tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_reserves_integrity_behavior -v
```

Expected: `test_bulk_edits_are_atomic` fails because `BuildCanonicalSerialization` is still public and/or index construction still happens after SavedVariables replacement. All unrelated reserve bounds and sync checksum tests should remain passing.

- [ ] **Step 5: Keep the RED contract uncommitted and continue immediately to Task 2**

```powershell
git status --short
```

Expected: only `tests/lua/runtime_harness.lua` and `tests/test_reserves_integrity_behavior.py` are modified by this task. Do not stage or commit them while RED; Task 2 implements the contract, returns the tree to GREEN, and commits tests plus runtime atomically.

### Task 2: Build and publish one detached reserve state

**Files:**
- Modify: `Raid Management Addon/Services/Reserves.lua:525-703`
- Modify: `Raid Management Addon/Services/Reserves.lua:718-735`
- Modify: `Raid Management Addon/Services/Reserves.lua:924-969`
- Modify: `Raid Management Addon/Services/Reserves.lua:1041-1065`
- Modify: `Raid Management Addon/Services/Reserves.lua:1136-1178`
- Modify: `Raid Management Addon/Services/Reserves.lua:1447-1536`
- Verify unchanged: `Raid Management Addon/Services/Reserves/Display.lua:905-1018`
- Test: `tests/lua/runtime_harness.lua:5311-6106`
- Test: `tests/test_reserves_integrity_behavior.py:5-75`

**Interfaces:**
- Consumes: `SavedVariables.ReplaceReserves(value) -> table`; `Display.RebuildIndex(ctx) -> nil`; existing `buildSavedReservesData`, `buildRuntimeReservesData`, `buildCanonicalDataSerialization`, and `notifyReservesDataChanged` local helpers.
- Produces: local `buildPublicationCandidate(candidate, nextMode) -> publication | nil, reason`; local `publishCandidate(publication) -> true | nil, reason`; unchanged public mutation/import return contracts; public `BuildCanonicalProjection` and `BuildCanonicalChecksum` retained for `Services/Reserves/Sync.lua`.

- [ ] **Step 1: Delete recursive rollback and the serialization facade**

Remove `captureTableGraph` and `restoreTableGraph` from `Reserves.lua:525-546`. Keep `buildCanonicalDataSerialization` local because `ApplyBatch` still needs collision-free net-change detection, but delete only this public wrapper:

```lua
function module.BuildCanonicalSerialization(sourceData)
	return buildCanonicalDataSerialization(sourceData)
end
```

Do not remove these two runtime sync interfaces:

```lua
function module.BuildCanonicalProjection(sourceData)
	return buildCanonicalProjection(sourceData)
end

function module.BuildCanonicalChecksum(sourceData)
	return buildReservesChecksum(sourceData)
end
```

- [ ] **Step 2: Build the existing display context against detached roots without changing Display's API**

Change only the local `getDisplayContext` factory to accept an optional prepared state. Keep `Display.RebuildIndex(ctx)` unchanged: it already writes exclusively through `ctx.*`. Define candidate lookup inside the context factory rather than widening the signatures of the existing canonical lookup helpers:

```lua
local function getDisplayContext(state)
	state = state or {
		reservesData = reservesData,
		reservesByItemID = reservesByItemID,
		reservesByItemPlayer = reservesByItemPlayer,
		playerItemsByName = playerItemsByName,
		reservesDisplayList = reservesDisplayList,
		reservesDisplayRowsByKey = reservesDisplayRowsByKey,
		reservesDisplayActiveKeys = reservesDisplayActiveKeys,
		grouped = grouped,
		reservesDirty = reservesDirty,
	}
	local function findReserveEntry(itemId, playerName)
		if not itemId or not playerName then return nil end
		local playerKey = Strings.NormalizeLower(playerName, true)
		if not (playerKey and state.reservesData[playerKey]) then
			playerKey = AliasHelpers.ResolveReserveKey(getAliasState(), state.reservesData, playerName)
		end
		if not playerKey then return nil end
		local byPlayer = state.reservesByItemPlayer[itemId]
		if type(byPlayer) == "table" and byPlayer[playerKey] then return byPlayer[playerKey] end
		local player = state.reservesData[playerKey]
		for i = 1, #(player and player.reserves or {}) do
			local row = player.reserves[i]
			if row and row.rawID == itemId then return row end
		end
		return nil
	end
	return {
		reservesData = state.reservesData,
		reservesByItemID = state.reservesByItemID,
		reservesByItemPlayer = state.reservesByItemPlayer,
		playerItemsByName = state.playerItemsByName,
		reservesDisplayList = state.reservesDisplayList,
		reservesDisplayRowsByKey = state.reservesDisplayRowsByKey,
		reservesDisplayActiveKeys = state.reservesDisplayActiveKeys,
		grouped = state.grouped,
		resolvePlayerNameDisplay = resolvePlayerNameDisplay,
		getReserveEntryForItem = findReserveEntry,
		getPlusForItem = function(itemId, playerName)
			local row = findReserveEntry(itemId, playerName)
			return (row and tonumber(row.plus)) or 0
		end,
		isPlusSystem = function()
			return normalizeImportMode(state.nextMode or importMode) == "plus"
		end,
		isMultiReserve = function()
			return normalizeImportMode(state.nextMode or importMode) == "multi"
		end,
		getRaidService = function()
			return Services.Raid
		end,
		getCurrentRaid = function()
			return Database.GetCurrentRaid()
		end,
		getAliasState = getAliasState,
		getAliasMatches = function(reservePlayers, raidPlayers)
			return AliasHelpers.GetAliasMatches(getAliasState(), reservePlayers, raidPlayers)
		end,
		setDirty = function(value)
			state.reservesDirty = value == true
		end,
		isDirty = function()
			return state.reservesDirty == true
		end,
	}
end
```

Do not modify `Services/Reserves/Display.lua`; its existing context boundary already supports detached construction and does not need a second builder or public API.

- [ ] **Step 3: Build the complete publication candidate before canonical mutation**

Replace `commitCandidate` with these two local phases. Use distinct runtime and persisted clones because synced runtime data may diverge from the persisted local payload:

```lua
local function buildPublicationCandidate(candidate, nextMode)
	local state = {
		savedData = buildSavedReservesData(candidate),
		persistedData = buildRuntimeReservesData(candidate, "publish-persisted"),
		reservesData = buildRuntimeReservesData(candidate, "publish-runtime"),
		reservesByItemID = {},
		reservesByItemPlayer = {},
		playerItemsByName = {},
		reservesDisplayList = {},
		reservesDisplayRowsByKey = {},
		reservesDisplayActiveKeys = {},
		grouped = {},
		reservesDirty = false,
		nextMode = nextMode ~= nil and normalizeImportMode(nextMode) or nil,
	}
	local built = pcall(DisplayHelpers.RebuildIndex, getDisplayContext(state))
	if not built then return nil, "publish_failed" end
	return state
end

local function publishCandidate(state)
	if state.nextMode ~= nil then
		local optionWritten = pcall(reservesNs.Set, reservesNs, "srImportMode", importModeToOptionValue(state.nextMode))
		if not optionWritten then return nil, "publish_failed" end
	end
	local saved, savedRoot = pcall(SavedVariables.ReplaceReserves, state.savedData)
	if not saved then return nil, "publish_failed" end

	persistedReservesData = state.persistedData
	reservesData = state.reservesData
	reservesByItemID = state.reservesByItemID
	reservesByItemPlayer = state.reservesByItemPlayer
	playerItemsByName = state.playerItemsByName
	reservesDisplayList = state.reservesDisplayList
	reservesDisplayRowsByKey = state.reservesDisplayRowsByKey
	reservesDisplayActiveKeys = state.reservesDisplayActiveKeys
	grouped = state.grouped
	reservesDirty = state.reservesDirty
	syncedCacheMeta = nil
	syncedCacheActive = false
	if state.nextMode ~= nil then importMode = state.nextMode end
	return true, savedRoot
end

local function commitCandidate(candidate, nextMode)
	local state, reason = buildPublicationCandidate(candidate, nextMode)
	if not state then return nil, reason end
	return publishCandidate(state)
end
```

All functions that can throw (`DisplayHelpers.RebuildIndex`, option storage, and SavedVariables replacement) execute before the local canonical roots are rebound. The real `SavedVariables.ReplaceReserves` is a single root assignment; do not reintroduce a mutate-then-throw compatibility protocol.

- [ ] **Step 4: Remove the single-use batch publication alias**

Delete:

```lua
local publishBatchCandidate = publishMutationCandidate
```

At the end of `ApplyBatch`, call the actual owner directly:

```lua
local published, publishReason = publishMutationCandidate(candidate)
if not published then return nil, publishReason end
return true, { commands = #commands, changed = changed }
```

Keep `buildCanonicalDataSerialization` private and keep the before/after comparison at `ApplyBatch:1520-1524`; it prevents checksum collisions or command sequences that net to no persisted change from causing a save/event.

- [ ] **Step 5: Run the reserve tests and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_reserves_integrity_behavior -v
```

Expected: all 18 reserve tests pass. In particular, bounds/checksum/wire verification remains green, detached index failure performs zero saves/events, successful batch publication performs one save/event, and synced-cache promotion occurs once.

- [ ] **Step 6: Run focused Lua static checks**

Run:

```powershell
stylua --check -- 'Raid Management Addon/Services/Reserves.lua'
luacheck --no-color -- 'Raid Management Addon/Services/Reserves.lua'
git diff --check
```

Expected: all commands exit `0`; no Lua 5.2+ syntax, formatting error, lint error, or whitespace error is reported.

- [ ] **Step 7: Commit the reserve publication simplification**

```powershell
git add -- 'Raid Management Addon/Services/Reserves.lua' 'tests/lua/runtime_harness.lua' 'tests/test_reserves_integrity_behavior.py'
git commit -m "refactor(reserves): publish detached reserve state"
```

### Task 3: Remove the unused DBSyncer cancellation seam

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua:1438-1455`
- Modify: `tests/lua/runtime_harness.lua:6972-7083`
- Modify: `tests/test_sync_communications_behavior.py:87-104`

**Interfaces:**
- Consumes: `DBSyncer:RequestLoggerReq(raidRef, targetName) -> boolean, reason?`; `DBSyncer:OnAddonMessage(prefix, message, channel, sender)`; internal `terminalizeRequest(requestId, reason)` used by timeout, completion, rejection, and cleanup.
- Produces: no manual `DBSyncer:CancelRequest`; terminal-once, late-response rejection, timeout cleanup, replay/correlation, and context-scoped cleanup remain testable through request, timer, and inbound-message workflows.

- [ ] **Step 1: Add the public-surface assertion and remove direct cancellation from behavior tests**

At the start of `cases.sync_request_lifecycle_is_correlated_and_terminal_once`, add:

```lua
assertEqual(nil, syncer.CancelRequest, "DBSyncer must not expose a test-only cancellation facade")
```

Delete the `pending("cancel", ...)` / `syncer:CancelRequest("cancel")` block at current lines 7007-7014. Adjust later callback counts down by one while keeping assertions for completion, timeout, terminal-ID reuse, late-response rejection, and terminal-state expiry.

In `cases.sync_request_timeout_fires_without_inbound_traffic`, replace the callback's reentrant `CancelRequest` call with a reentrant late response and assert only one terminal callback/import attempt:

```lua
pending.callback = function(reason)
	callbackCount = callbackCount + 1
	assertEqual("timeout", reason, "timer terminal reason differs")
	syncer:OnAddonMessage("RMALogSync", table.concat({
		"SN", 2, "generated", "REQ", 41, 1, 1, "snapshot",
	}, "\t"), "WHISPER", "Leader-Test Realm")
end
```

In `cases.sync_request_cleanup_is_context_scoped`, expire the local colliding request through the existing timeout timer instead of direct cancellation:

```lua
fixture.now = fixture.now + 31
fixture:FireTimers()
assertEqual(nil, syncer._incoming["local"], "timeout must remove its local response assembly")
assertTrue(syncer._incoming[pushKey] ~= nil, "timeout must preserve unrelated PUSH with the same wire ID")
```

- [ ] **Step 2: Add a Python source assertion for the smaller API**

Add to `SyncCommunicationsBehaviorTests`:

```python
def test_db_syncer_does_not_export_manual_request_cancellation(self) -> None:
    source = DB_SYNCER.read_text(encoding="utf-8")
    self.assertNotIn("function module:CancelRequest", source)
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_db_syncer_does_not_export_manual_request_cancellation tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_request_lifecycle_is_correlated_and_terminal_once tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_request_timeout_fires_without_inbound_traffic tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_request_cleanup_is_context_scoped -v
```

Expected: the new source/public-surface assertion fails because `DBSyncer:CancelRequest` is still exported; lifecycle failures, if any, identify a callback-count adjustment missed when deleting the artificial cancel scenario.

- [ ] **Step 4: Confirm there is no runtime caller, then delete only the facade**

Run:

```powershell
rg -n "CancelRequest" 'Raid Management Addon' -g '*.lua'
```

Expected before editing: exactly one match, the definition in `Raid Management Addon/Database/DBSyncer.lua:1451`. Delete:

```lua
function module:CancelRequest(requestId)
	return terminalizeRequest(tostring(requestId or ""), "cancel")
end
```

Do not delete or weaken private `terminalizeRequest`, `completeRequest`, request timers, terminal tombstones, incoming cleanup, consent revocation, or request-ID collision checks.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the same four-test command from Step 3.

Expected: all four tests pass; requests still complete or time out once, late responses remain rejected, and context-scoped cleanup preserves unrelated PUSH state.

- [ ] **Step 6: Commit the sync API simplification**

```powershell
git add -- 'Raid Management Addon/Database/DBSyncer.lua' 'tests/lua/runtime_harness.lua' 'tests/test_sync_communications_behavior.py'
git commit -m "refactor(sync): remove manual cancellation test seam"
```

### Task 4: Verify reserves and sync as one compatibility-preserving batch

**Files:**
- Verify: `Raid Management Addon/Services/Reserves.lua`
- Verify: `Raid Management Addon/Services/Reserves/Display.lua`
- Verify: `Raid Management Addon/Services/Reserves/Sync.lua`
- Verify: `Raid Management Addon/Database/DBSyncer.lua`
- Verify: `tests/lua/runtime_harness.lua`
- Verify: `tests/test_reserves_integrity_behavior.py`
- Verify: `tests/test_sync_communications_behavior.py`

**Interfaces:**
- Consumes: completed Tasks 1-3.
- Produces: evidence that reserve publication is value-atomic and sync security/resource contracts are unchanged.

- [ ] **Step 1: Prove removed seams have no runtime or test dependency**

Run:

```powershell
rg -n "captureTableGraph|restoreTableGraph|BuildCanonicalSerialization|publishBatchCandidate|CancelRequest" 'Raid Management Addon' tests
```

Expected: no matches. Then run:

```powershell
rg -n "BuildCanonicalProjection|BuildCanonicalChecksum|MAX_|TTL|consent|replay|revision|requestId" 'Raid Management Addon/Services/Reserves/Sync.lua' 'Raid Management Addon/Database/DBSyncer.lua'
```

Expected: the canonical checksum/projection calls and existing bounds/correlation protections remain present; this is an inspection gate, not an instruction to rename them.

- [ ] **Step 2: Run both focused suites**

Run:

```powershell
py -3 -m unittest tests.test_reserves_integrity_behavior tests.test_sync_communications_behavior -v
```

Expected: all reserve and communications tests pass.

- [ ] **Step 3: Run repository runtime validation**

Run:

```powershell
py -3 -m unittest discover -s tests -p 'test_*.py' -v
py -3 ..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py "Raid Management Addon/Raid Management Addon.toc"
py -3 ..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py "Raid Management Addon"
py -3 ..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py "Raid Management Addon"
stylua --check -- 'Raid Management Addon/Services/Reserves.lua' 'Raid Management Addon/Database/DBSyncer.lua'
luacheck --no-color -- 'Raid Management Addon/Services/Reserves.lua' 'Raid Management Addon/Database/DBSyncer.lua'
git diff --check
git status --short --branch
```

Expected: the Python suite and the three WotLK validators pass; formatter, lint, and whitespace checks exit `0`; status contains only the intentional commits/changes for this plan. The in-game smoke test remains deferred to the final whole-rework candidate, as required by the approved design.

- [ ] **Step 4: Commit any verification-only test correction**

If Step 3 required a correction solely to the two focused test files, commit the exact correction:

```powershell
git add -- 'tests/lua/runtime_harness.lua' 'tests/test_reserves_integrity_behavior.py' 'tests/test_sync_communications_behavior.py'
git commit -m "test(reserves): align publication verification"
```

If no correction was required, do not create an empty commit. Do not fold unrelated formatting or documentation into this plan.
