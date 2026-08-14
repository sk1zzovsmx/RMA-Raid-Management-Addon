# Runtime Support Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove four demonstrated support-layer abstractions while preserving option reset behavior, atomic dataset activation, inspect reliability, and UTF-8-safe persisted text.

**Architecture:** Keep every behavior in its existing cohesive owner. `DBOptions` exposes one concrete all-defaults operation, `Init.lua` coordinates the two fixed dataset owners through their mandatory snapshot contract, `Strings` owns the proven shared UTF-8 prefix algorithm, and `InspectCoordinator` alone owns inspect pacing, combat deferral, and the active-request timeout.

**Tech Stack:** World of Warcraft 3.3.5a (Interface `30300`), Lua 5.1, Python `unittest`, repository Lua runtime harness, PowerShell validation commands.

## Global Constraints

- Work from the approved `d4029e7`-based branch `codex/rework-simplification`.
- Preserve addon name, folder name, runtime short name `RMA`, `/rma`, RMA branding, frame identities, `RMA_*` SavedVariables names and schemas, addon-message prefixes, and wire formats.
- Target WotLK 3.3.5a, Interface `30300`, and Lua 5.1 only; do not use `C_Timer`, Retail/Classic-only APIs, Lua 5.2+ syntax, or `xpcall` extra arguments.
- Do not add Ace2/Ace3 dependencies, new modules, generic helper containers, migrations, compatibility fallbacks, or speculative configuration.
- Do not modify vendored files under `Raid Management Addon/Libs/*`.
- Keep XML layout-only and keep runtime code, comments, labels, and diagnostics ASCII.
- Preserve the mutation rule `input -> validation -> detached candidate -> atomic commit -> event/UI`.
- Each task is an independently revertible commit and must pass its focused tests before commit.
- Do not run the in-game smoke test in this plan; it remains the final integrated-candidate gate.

---

## File Map

- `Raid Management Addon/Database/DBOptions.lua`: own the concrete reset of every registered option namespace; remove the closure facade.
- `Raid Management Addon/Controllers/Config.lua`: call the concrete options reset operation from the existing Defaults action.
- `Raid Management Addon/Init.lua`: coordinate activation rollback through the mandatory capture/restore API of the two fixed dataset owners.
- `Raid Management Addon/Modules/Dataset/LootSourcesData.lua`: unchanged contract provider; verify existing `CaptureActivationState()` and `RestoreActivationState(snapshot)` behavior.
- `Raid Management Addon/Modules/Dataset/IgnoredMobs.lua`: unchanged contract provider; verify existing `CaptureActivationState()` and `RestoreActivationState(snapshot)` behavior.
- `Raid Management Addon/Modules/Strings.lua`: own the shared UTF-8-safe byte-prefix algorithm.
- `Raid Management Addon/Services/Spammer/Draft.lua`: consume `Strings.Utf8SafePrefix` while retaining spammer-specific byte limits.
- `Raid Management Addon/Services/Warnings/Store.lua`: consume `Strings.Utf8SafePrefix` while retaining warnings-specific validation and byte limits.
- `Raid Management Addon/Services/InspectCoordinator.lua`: own global start pacing, combat deferral, and timeout beginning at activation.
- `Raid Management Addon/Services/EquipInspect.lua`: retain equipment work and correlation but remove its second global scheduler and combat retry chain.
- `tests/lua/runtime_harness.lua`: behavior fixtures and cases for all four simplifications.
- `tests/test_runtime_foundations_behavior.py`: Python entrypoint for the options behavior case.
- `tests/test_inspect_dataset_behavior.py`: Python entrypoints for direct dataset contracts and single-owner inspect scheduling.
- `tests/test_raid_recording_integrity_behavior.py`: remove the obsolete EquipInspect-owned combat-retry expectation.
- `tests/test_spammer_warnings_behavior.py`: Python entrypoint for the shared UTF-8 behavior case.

### Task 1: Replace the option namespace facade with `ResetAllDefaults`

**Files:**
- Modify: `Raid Management Addon/Database/DBOptions.lua:354-378`
- Modify: `Raid Management Addon/Controllers/Config.lua:31-35,939-948`
- Modify: `tests/lua/runtime_harness.lua:4444-4457,4565-4583`
- Modify: `tests/test_runtime_foundations_behavior.py:65-68,90-93`

**Interfaces:**
- Consumes: existing private `namespaces: table<string, namespace>` and `namespaceMt:ResetDefaults() -> table`.
- Produces: `Options.ResetAllDefaults() -> true`; it resets every registered namespace and preserves each namespace's existing `Events.OptionsReset` emission.
- Removes: `Options.GetNamespaces()` and the `GetOptionNamespaces` binding in `Controllers/Config.lua`.

- [ ] **Step 1: Replace facade-specific tests with the concrete reset behavior**

In `tests/lua/runtime_harness.lua`, delete `cases.options_namespace_snapshot_is_isolated` and `cases.options_namespace_facade_contract`, then add this case in their place:

```lua
function cases.options_reset_all_defaults(addon)
	local options = installOptionsStubs(addon)
	local first = options.RegisterNamespace("First", { enabled = true, nested = { count = 1 } })
	local second = options.RegisterNamespace("Second", { mode = "safe" })
	assertEqual(true, first:Set("enabled", false))
	assertEqual(true, first:Set("nested", { count = 9 }))
	assertEqual(true, second:Set("mode", "custom"))

	assertEqual(true, options.ResetAllDefaults(), "all-default reset must report success")
	assertEqual(true, first:Get("enabled"), "first namespace scalar must reset")
	assertEqual(1, first:Get("nested").count, "first namespace nested value must reset")
	assertEqual("safe", second:Get("mode"), "second namespace must reset")
	assertEqual(nil, options.GetNamespaces, "namespace enumeration facade must not remain public")
	print("PASS options_reset_all_defaults")
end
```

In `tests/test_runtime_foundations_behavior.py`, delete `test_options_namespace_snapshot_is_isolated` and `test_options_namespace_facade_contract`, then add:

```python
    def test_options_reset_all_defaults(self) -> None:
        result = run_lua_case("options_reset_all_defaults")
        self.assertIn("PASS options_reset_all_defaults", result.stdout)
```

- [ ] **Step 2: Run the new test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_runtime_foundations_behavior.RuntimeFoundationsBehaviorTest.test_options_reset_all_defaults -v
```

Expected: FAIL because `options.ResetAllDefaults` is nil while `GetNamespaces` still exists.

- [ ] **Step 3: Implement the concrete store-owned reset operation**

In `Raid Management Addon/Database/DBOptions.lua`, delete the entire `Options.GetNamespaces()` function at lines 354-378 and add:

```lua
function Options.ResetAllDefaults()
	for _, ns in pairs(namespaces) do
		ns:ResetDefaults()
	end
	return true
end
```

In `Raid Management Addon/Controllers/Config.lua`, replace the line-34 binding with:

```lua
local ResetAllOptionDefaults = assert(Options.ResetAllDefaults, "Config options reset operation is not initialized")
```

Replace the namespace loop in `loadDefaultOptions()` with the direct operation:

```lua
	local function loadDefaultOptions()
		ResetAllOptionDefaults()
		SetDebugEnabled(false)
		module:RequestRefresh("defaults")
		refreshInterfaceOptionsPanel()
		addon:info(L.MsgDefaultsRestored)
	end
```

- [ ] **Step 4: Run focused options tests and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_runtime_foundations_behavior -v
```

Expected: all runtime-foundation tests PASS, including `test_options_reset_all_defaults`; no test references `GetNamespaces`.

Run:

```powershell
rg -n "GetNamespaces|GetOptionNamespaces" "Raid Management Addon" tests
```

Expected: no matches and exit code 1.

- [ ] **Step 5: Validate and commit the options batch**

Run:

```powershell
stylua --check "Raid Management Addon/Database/DBOptions.lua" "Raid Management Addon/Controllers/Config.lua"
luacheck "Raid Management Addon/Database/DBOptions.lua" "Raid Management Addon/Controllers/Config.lua"
git diff --check
```

Expected: all commands exit 0.

Commit:

```powershell
git add -- "Raid Management Addon/Database/DBOptions.lua" "Raid Management Addon/Controllers/Config.lua" "tests/lua/runtime_harness.lua" "tests/test_runtime_foundations_behavior.py"
git commit -m "refactor(options): replace namespace facade with reset operation"
```

Expected: one commit containing only the four listed files.

### Task 2: Make the two dataset snapshot owners mandatory

**Files:**
- Modify: `Raid Management Addon/Init.lua:691-779`
- Test: `tests/lua/runtime_harness.lua:4097-4128,4177-4273`
- Test: `tests/test_inspect_dataset_behavior.py:57-83`
- Verify only: `Raid Management Addon/Modules/Dataset/LootSourcesData.lua:355-373`
- Verify only: `Raid Management Addon/Modules/Dataset/IgnoredMobs.lua:237-251`

**Interfaces:**
- Consumes from both fixed owners: `CaptureActivationState() -> table`, `RestoreActivationState(snapshot: table) -> true`, `ActivateInstance(instanceKey: string) -> true | false, reason`, `DeactivateInstance()`, and `GetActiveInstanceKey() -> string | nil`.
- Produces: unchanged atomic cross-owner activation; failure restores the exact prior generation through snapshots or raises `dataset_rollback_failed` if a restore rejects or throws.
- Removes: capability checks for `CaptureActivationState`/`RestoreActivationState` and fallback rollback through `ActivateInstance(previousKey)` or `DeactivateInstance()`.

- [ ] **Step 1: Add a failing behavior case for a missing internal owner contract**

Add this case to `tests/lua/runtime_harness.lua` after `instance_datasets_share_canonical_identity`:

```lua
function cases.dataset_activation_requires_snapshot_contract(addon)
	installInitStubs(addon)
	addon.L = { RaidZones = {} }
	addon.Diag = { D = { LogRaidInstanceRecognized = "%s %s" }, W = { LogRaidUnmappedZone = "%s %s" } }
	addon.warn = function() end
	local lootKey
	local ignoredKey
	addon.LootSourcesData = {
		ResolveInstanceKey = function() return "icecrown citadel" end,
		GetActiveInstanceKey = function() return lootKey end,
		ActivateInstance = function(key) lootKey = key return true end,
		DeactivateInstance = function() lootKey = nil return true end,
	}
	addon.IgnoredMobs = {
		GetActiveInstanceKey = function() return ignoredKey end,
		ActivateInstance = function(key) ignoredKey = key return true end,
		DeactivateInstance = function() ignoredKey = nil return true end,
	}
	_G.GetInstanceInfo = function() return "Localized", "raid", 1, nil, 10, 0, false, 631 end
	loadAddonFile(addon, "Raid Management Addon/Init.lua")
	local ok, err = pcall(addon.ZONE_CHANGED_NEW_AREA, addon)
	assertEqual(false, ok, "missing mandatory dataset snapshot methods must fail fast")
	assertTrue(string.find(tostring(err), "CaptureActivationState", 1, true) ~= nil)
	print("PASS dataset_activation_requires_snapshot_contract")
end
```

Add the Python entrypoint in `tests/test_inspect_dataset_behavior.py`:

```python
    def test_dataset_activation_requires_snapshot_contract(self) -> None:
        result = run_lua_case("dataset_activation_requires_snapshot_contract")
        self.assertIn("PASS dataset_activation_requires_snapshot_contract", result.stdout)
```

- [ ] **Step 2: Run the new dataset test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_inspect_dataset_behavior.InspectDatasetBehaviorTests.test_dataset_activation_requires_snapshot_contract -v
```

Expected: FAIL because the current coordinator accepts owners without snapshot methods and activation succeeds.

- [ ] **Step 3: Update existing dataset fixtures to implement the real mandatory contract**

For each fake owner in `instance_datasets_share_canonical_identity`, `dataset_activation_rolls_back_cross_owner_failure`, `dataset_activation_rejects_false_owner_results`, and `dataset_activation_reports_failed_rollback`, add capture/restore methods that snapshot and restore that owner's local key. Use this exact form, replacing `lootKey` with `activated.loot` in the canonical-identity case and `ignoredKey` with `activated.ignored` for its peer:

```lua
		CaptureActivationState = function() return { activeInstanceKey = lootKey } end,
		RestoreActivationState = function(snapshot)
			lootKey = snapshot.activeInstanceKey
			return true
		end,
```

For the ignored owner use:

```lua
		CaptureActivationState = function() return { activeInstanceKey = ignoredKey } end,
		RestoreActivationState = function(snapshot)
			ignoredKey = snapshot.activeInstanceKey
			return true
		end,
```

In `dataset_activation_reports_failed_rollback`, make only the loot restore reject so the existing terminal rollback assertion remains meaningful:

```lua
		RestoreActivationState = function()
			return false
		end,
```

Do not add snapshot methods to `dataset_activation_requires_snapshot_contract`; it is the fail-fast case.

- [ ] **Step 4: Replace capability fallback with direct snapshot capture and restore**

In `Raid Management Addon/Init.lua`, retain `activateDatasetOwner` unchanged. Replace `restoreDatasetOwner` with:

```lua
	local function restoreDatasetOwner(owner, previousKey, snapshot)
		if owner.GetActiveInstanceKey() == previousKey then
			return true
		end
		local ok, restored = pcall(owner.RestoreActivationState, snapshot)
		if not ok then
			return false, restored
		end
		if restored ~= true or owner.GetActiveInstanceKey() ~= previousKey then
			return false, "snapshot-restore-rejected"
		end
		return true
	end
```

In `refreshActiveInstanceDatasets()`, replace the optional captures with direct mandatory calls:

```lua
			local previousLootKey = activeLootSourcesData.GetActiveInstanceKey()
			local previousIgnoredKey = activeIgnoredMobs.GetActiveInstanceKey()
			local lootSnapshot = activeLootSourcesData.CaptureActivationState()
			local ignoredSnapshot = activeIgnoredMobs.CaptureActivationState()
```

Keep the existing ordered activation, both rollback attempts, `dataset_rollback_failed` diagnostic, and non-raid deactivation unchanged.

- [ ] **Step 5: Run focused dataset tests and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_inspect_dataset_behavior -v
```

Expected: all inspect/dataset tests PASS, including missing-contract failure, exact-generation restore, false-result rejection, and rollback-failure reporting.

Run:

```powershell
rg -n "type\(.*CaptureActivationState|type\(.*RestoreActivationState|ActivateInstance, previousKey|owner.DeactivateInstance" "Raid Management Addon/Init.lua"
```

Expected: no matches and exit code 1.

- [ ] **Step 6: Validate and commit the dataset batch**

Run:

```powershell
stylua --check "Raid Management Addon/Init.lua"
luacheck "Raid Management Addon/Init.lua"
git diff --check
```

Expected: all commands exit 0.

Commit:

```powershell
git add -- "Raid Management Addon/Init.lua" "tests/lua/runtime_harness.lua" "tests/test_inspect_dataset_behavior.py"
git commit -m "refactor(dataset): require activation snapshot owners"
```

Expected: one commit containing only the three listed files; the two dataset owner files remain unchanged.

### Task 3: Move the proven UTF-8 prefix behavior to `Strings`

**Files:**
- Modify: `Raid Management Addon/Modules/Strings.lua:8-13,24-51`
- Modify: `Raid Management Addon/Services/Spammer/Draft.lua:13-17,48-90`
- Modify: `Raid Management Addon/Services/Warnings/Store.lua:27-34,82-136`
- Test: `tests/lua/runtime_harness.lua:8057-8256`
- Test: `tests/test_spammer_warnings_behavior.py:12-16`

**Interfaces:**
- Produces: `Strings.Utf8SafePrefix(text: string, maxBytes: number) -> string`; returns the longest valid UTF-8 prefix whose encoded byte length is at most `maxBytes`, and returns `""` for non-string input or a non-positive/invalid limit.
- Consumes in Draft/Warnings: the exact public function above; feature byte limits and trim/validation policy remain local.
- Removes: both private copies of `utf8SequenceLength`, `isValidUtf8Sequence`, and `utf8SafePrefix`.

- [ ] **Step 1: Add direct behavior coverage for the shared string owner**

Add this Lua case before `spammer_warnings_saved_variables_are_normalized`:

```lua
function cases.strings_utf8_safe_prefix(addon)
	local prefix = addon.Strings.Utf8SafePrefix
	assertEqual("abc", prefix("abc", 3), "ASCII text at the boundary must remain intact")
	assertEqual("A", prefix("A" .. string.char(0xc3, 0xa9), 2), "a split multibyte character must be omitted")
	assertEqual("A" .. string.char(0xc3, 0xa9), prefix("A" .. string.char(0xc3, 0xa9), 3), "a complete multibyte character must remain")
	assertEqual("Good", prefix("Good" .. string.char(0xc0, 0x80) .. "suffix", 255), "malformed UTF-8 and its suffix must be removed")
	assertEqual("", prefix(nil, 10), "non-string input must normalize to an empty prefix")
	assertEqual("", prefix("text", 0), "non-positive limits must return an empty prefix")
	print("PASS strings_utf8_safe_prefix")
end
```

Add the Python entrypoint in `tests/test_spammer_warnings_behavior.py`:

```python
    def test_strings_utf8_safe_prefix(self) -> None:
        result = run_lua_case("strings_utf8_safe_prefix")
        self.assertIn("PASS strings_utf8_safe_prefix", result.stdout)
```

- [ ] **Step 2: Run the new string-owner test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_spammer_warnings_behavior.SpammerWarningsBehaviorTests.test_strings_utf8_safe_prefix -v
```

Expected: FAIL because `addon.Strings.Utf8SafePrefix` is nil.

- [ ] **Step 3: Implement `Strings.Utf8SafePrefix` in the existing owner**

In `Raid Management Addon/Modules/Strings.lua`, add `tonumber` to the primitive aliases and replace the existing standalone `strsub` alias with the combined byte/length aliases:

```lua
local type, tostring, tonumber = type, tostring, tonumber
local byte, strlen, strsub = string.byte, string.len, string.sub
```

Add these private helpers before the public-method section:

```lua
local function utf8SequenceLength(firstByte)
	if firstByte <= 0x7f then return 1 end
	if firstByte >= 0xc2 and firstByte <= 0xdf then return 2 end
	if firstByte >= 0xe0 and firstByte <= 0xef then return 3 end
	if firstByte >= 0xf0 and firstByte <= 0xf4 then return 4 end
	return nil
end

local function isValidUtf8Sequence(text, index, sequenceLength)
	local firstByte = byte(text, index)
	for offset = 1, sequenceLength - 1 do
		local continuation = byte(text, index + offset)
		if not continuation or continuation < 0x80 or continuation > 0xbf then return false end
		if offset == 1 then
			if firstByte == 0xe0 and continuation < 0xa0 then return false end
			if firstByte == 0xed and continuation > 0x9f then return false end
			if firstByte == 0xf0 and continuation < 0x90 then return false end
			if firstByte == 0xf4 and continuation > 0x8f then return false end
		end
	end
	return true
end
```

Add the public operation immediately after `Strings.TrimText`:

```lua
function Strings.Utf8SafePrefix(text, maxBytes)
	if type(text) ~= "string" then
		return ""
	end
	local limit = tonumber(maxBytes) or 0
	if limit <= 0 then
		return ""
	end
	local index, lastValid, textLength = 1, 0, strlen(text)
	while index <= textLength do
		local sequenceLength = utf8SequenceLength(byte(text, index))
		if not sequenceLength or index + sequenceLength - 1 > limit then break end
		if not isValidUtf8Sequence(text, index, sequenceLength) then break end
		lastValid = index + sequenceLength - 1
		index = lastValid + 1
	end
	return strsub(text, 1, lastValid)
end
```

- [ ] **Step 4: Replace both private copies with the shared operation**

In `Raid Management Addon/Services/Spammer/Draft.lua`, delete the three UTF-8 private helpers at lines 49-82, remove the now-unused `byte` and `strsub` aliases while retaining `strlen` for output-length calculation, and make `normalizeText` call:

```lua
local function normalizeText(value, maxBytes)
	if type(value) ~= "string" then
		return ""
	end
	local text = Strings.TrimText(value)
	return Strings.Utf8SafePrefix(text, maxBytes)
end
```

In `Raid Management Addon/Services/Warnings/Store.lua`, delete the same three private helpers at lines 83-116, remove now-unused `byte` and `strsub` aliases while retaining `strlen` for the explicit too-long check, then use:

```lua
	text = Strings.Utf8SafePrefix(text, maxBytes)
```

in `normalizeBoundedText`, and:

```lua
	if Strings.Utf8SafePrefix(text, maxBytes) ~= text then return nil, "invalid_" .. field end
```

in `validateBoundedText`.

- [ ] **Step 5: Run focused string, spammer, and warning tests and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_spammer_warnings_behavior -v
```

Expected: all spammer/warnings tests PASS, including exact UTF-8 byte boundaries and malformed-suffix normalization.

Run:

```powershell
rg -n "local function utf8SequenceLength|local function isValidUtf8Sequence|local function utf8SafePrefix" "Raid Management Addon"
```

Expected: the shared implementation has only the two private parser helpers in `Modules/Strings.lua`; there is no private `utf8SafePrefix` match.

- [ ] **Step 6: Validate and commit the UTF-8 owner batch**

Run:

```powershell
stylua --check "Raid Management Addon/Modules/Strings.lua" "Raid Management Addon/Services/Spammer/Draft.lua" "Raid Management Addon/Services/Warnings/Store.lua"
luacheck "Raid Management Addon/Modules/Strings.lua" "Raid Management Addon/Services/Spammer/Draft.lua" "Raid Management Addon/Services/Warnings/Store.lua"
git diff --check
```

Expected: all commands exit 0.

Commit:

```powershell
git add -- "Raid Management Addon/Modules/Strings.lua" "Raid Management Addon/Services/Spammer/Draft.lua" "Raid Management Addon/Services/Warnings/Store.lua" "tests/lua/runtime_harness.lua" "tests/test_spammer_warnings_behavior.py"
git commit -m "refactor(strings): share UTF-8 safe prefix handling"
```

Expected: one commit containing only the five listed files.

### Task 4: Make `InspectCoordinator` the only global inspect scheduler

**Files:**
- Modify: `Raid Management Addon/Services/InspectCoordinator.lua:24-28,40-151`
- Modify: `Raid Management Addon/Services/EquipInspect.lua:5,37,50-70,474-535,546-557,646-684,761-789,833-959,1122-1150`
- Modify: `tests/lua/runtime_harness.lua:2874-2950,3049-3159,3564-3598`
- Modify: `tests/test_inspect_dataset_behavior.py:29-45`
- Modify: `tests/test_raid_recording_integrity_behavior.py:94-96`

**Interfaces:**
- Consumes: `InspectCoordinator:Request(owner, unit, guid, onStart, onFinish, category) -> accepted: boolean, stateOrReason: string`, `Release(owner, guid) -> boolean`, and `Cancel(owner) -> boolean`.
- Preserves: queue bound 40, minimum global start interval 1.75 seconds, active timeout 8 seconds, category ownership, GUID correlation, and terminal reasons `timer_failed`, `start_failed`, `timeout`, `cancelled`, and `complete`.
- Changes: the 8-second timeout is armed only when the request becomes active; queued combat work waits for `PLAYER_REGEN_ENABLED` without an EquipInspect retry timer.
- Removes from EquipInspect: `UnitAffectingCombat`, `THROTTLE_SECONDS`, `MAX_COMBAT_ATTEMPTS`, `globalNextHandle`, `scheduleNextGlobalRequest`, `scheduleRetryCurrentRequest`, and every `retryHandle`/`combatAttempts` branch.
- Retains in EquipInspect: `globalInspectRequest` solely as the currently active equipment-request correlation record for WoW inspect callbacks, not as a scheduler.

- [ ] **Step 1: Rewrite coordinator coverage so queued time does not consume the active timeout**

In `cases.inspect_coordinator_serializes_global_ownership`, replace the `combat-expiry` assertions with:

```lua
	local combatStarts, combatFinishes = 0, 0
	combat = true
	coordinator:Request("combat-deferral", "raid3", "guid-combat", function()
		combatStarts = combatStarts + 1
	end, function(reason)
		assertEqual("timeout", reason, "active combat-deferred request must retain the timeout reason")
		combatFinishes = combatFinishes + 1
	end)
	nowValue = 21
	for i = 1, #timers do
		if not timers[i].cancelled and timers[i].deadline <= nowValue then
			timers[i].cancelled = true
			timers[i].callback()
		end
	end
	assertEqual(0, combatStarts, "combat-deferred work must not start in combat")
	assertEqual(0, combatFinishes, "queued time must not consume the active timeout")
	combat = false
	callbacks.PLAYER_REGEN_ENABLED()
	assertEqual(1, combatStarts, "regen must start deferred work once")
	nowValue = 29.1
	for i = 1, #timers do
		if not timers[i].cancelled and timers[i].deadline <= nowValue then
			timers[i].cancelled = true
			timers[i].callback()
		end
	end
	assertEqual(1, combatFinishes, "timeout must begin at activation and finish once")
```

Keep the queue-bound assertions after this block.

- [ ] **Step 2: Replace the EquipInspect combat-retry case with coordinator-owned deferral**

Delete `cases.equip_inspect_combat_retry_is_single_owned_chain` and add:

```lua
function cases.equip_inspect_combat_deferral_is_coordinator_owned(addon)
	local fixture, inspect = installEquipInspectFixture(addon)
	fixture.inCombat = true
	assertEqual("queued", select(2, inspect:ForcePlayer(2, 21)), "combat request must enter the coordinator queue")
	fixture:AdvanceTime(20)
	assertEqual(0, #fixture.inspectRequests, "queued combat work must not notify before regen")
	local activeTimers = 0
	for i = 1, #fixture.timers do
		if fixture.timers[i].active then activeTimers = activeTimers + 1 end
	end
	assertEqual(0, activeTimers, "EquipInspect must not own a combat retry timer")

	fixture.inCombat = false
	fixture.inspectCallbacks.PLAYER_REGEN_ENABLED()
	assertEqual(1, #fixture.inspectRequests, "regen must let the coordinator notify once")
	fixture:AdvanceTime(8.1)
	local snapshot = inspect:GetSnapshot(fixture.raids[2], 21)
	assertEqual("timeout", snapshot.status, "active request must time out after coordinator activation")
	assertEqual("inspect_timeout", snapshot.reason, "active timeout reason must remain stable")
	print("PASS equip_inspect_combat_deferral_is_coordinator_owned")
end
```

Delete the combat timer-failure loop in `cases.equip_inspect_own_timer_failures_are_terminal` (the block that injects `EquipInspect combat timer failure`); retain the handoff and item-information timer failure coverage.

In `tests/test_raid_recording_integrity_behavior.py`, delete `test_equip_inspect_combat_retry_is_single_owned_chain`. In `tests/test_inspect_dataset_behavior.py`, add:

```python
    def test_equip_inspect_combat_deferral_is_coordinator_owned(self) -> None:
        result = run_lua_case("equip_inspect_combat_deferral_is_coordinator_owned")
        self.assertIn("PASS equip_inspect_combat_deferral_is_coordinator_owned", result.stdout)
```

- [ ] **Step 3: Run the changed inspect tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_inspect_dataset_behavior.InspectDatasetBehaviorTests.test_inspect_coordinator_serializes_global_ownership tests.test_inspect_dataset_behavior.InspectDatasetBehaviorTests.test_equip_inspect_combat_deferral_is_coordinator_owned -v
```

Expected: both tests FAIL: queued combat currently consumes the coordinator deadline and EquipInspect currently owns a retry timer.

- [ ] **Step 4: Arm the coordinator timeout only when a request starts**

In `Raid Management Addon/Services/InspectCoordinator.lua`, simplify `expire` so only the active owner can expire:

```lua
local function expire(request)
	if request.finished or active ~= request then
		return
	end
	active = nil
	finish(request, "timeout", true)
	drain()
end
```

Delete `removeQueued`, because timeouts no longer remove queued requests. Replace `start` with:

```lua
local function start(request)
	active = request
	lastStartedAt = now()
	request.deadlineHandle = schedule(REQUEST_TIMEOUT_SECONDS, function()
		expire(request)
	end)
	if not request.deadlineHandle then
		request.startError = "timer_failed"
		active = nil
		finish(request, "timer_failed", false)
		drain()
		return
	end
	local ok = pcall(request.onStart)
	if not ok and active == request then
		active = nil
		finish(request, "start_failed", true)
		drain()
	end
end
```

In `module:Request`, remove `enqueuedAt` and all deadline scheduling before enqueue. The tail of the method becomes:

```lua
	local request = {
		owner = owner,
		category = category or owner,
		unit = unit,
		guid = guid,
		onStart = onStart,
		onFinish = onFinish,
	}
	queue[#queue + 1] = request
	drain()
	if request.startError then
		return false, request.startError
	end
	return true, active == request and "active" or "queued"
end
```

Do not add a queued deadline, polling `OnUpdate`, or a second combat fallback; the existing `PLAYER_REGEN_ENABLED` callback remains the only combat wake-up.

- [ ] **Step 5: Remove EquipInspect's second global scheduler and combat retry chain**

In `Raid Management Addon/Services/EquipInspect.lua`:

1. Delete the `UnitAffectingCombat` binding, `THROTTLE_SECONDS`, `MAX_COMBAT_ATTEMPTS`, and `globalNextHandle`.
2. Delete `scheduleNextGlobalRequest` and `scheduleRetryCurrentRequest` entirely.
3. Delete all cancellation/clearing of `request.retryHandle`, including loops over queued requests.
4. Delete `globalNextHandle = nil` from `terminalizeQueuedTimerWork`.
5. Delete calls to `scheduleNextGlobalRequest` from orphan cleanup and finalization.
6. In `ProcessQueue`, delete the `globalInspectRequest`, `globalNextHandle`, and `nextQueuedRaid` scheduling gates at current lines 845-855. `activeRequestByRaid[resolved]` remains the per-raid duplicate-work guard.
7. Delete the complete `UnitAffectingCombat("player")` branch at current lines 918-929.
8. Keep the direct `InspectCoordinator:Request(...)` call and set `globalInspectRequest = request` only inside its `onStart` callback immediately after `NotifyInspect(unit)` succeeds.
9. Delete `handlePlayerRegenEnabled`, its `PLAYER_REGEN_ENABLED` resolution/registration, and `wow.PLAYER_REGEN_ENABLED` from the file contract comment; the coordinator already owns that event.
10. After `InspectCoordinator:Release(...)` in `finalizeRequest`, progress only the same feature queue without a timer:

```lua
	if request and request.coordinatorOwner then
		InspectCoordinator:Release(request.coordinatorOwner, request.unitGUID)
	end
	module:ProcessQueue(raidNid)
```

This immediate call only submits the next equipment request; `InspectCoordinator` applies the 1.75-second global interval and queues it during combat.

- [ ] **Step 6: Run all inspect behavior and verify GREEN**

Run:

```powershell
py -3 -m unittest tests.test_inspect_dataset_behavior tests.test_raid_recording_integrity_behavior -v
```

Expected: all tests PASS; combat work waits without an EquipInspect timer, starts once after regen, and times out eight seconds after activation.

Run:

```powershell
rg -n "globalNextHandle|scheduleNextGlobalRequest|scheduleRetryCurrentRequest|MAX_COMBAT_ATTEMPTS|combatAttempts|UnitAffectingCombat|retryHandle" "Raid Management Addon/Services/EquipInspect.lua"
```

Expected: no matches and exit code 1.

Run:

```powershell
rg -n "REQUEST_TIMEOUT_SECONDS|MIN_START_INTERVAL_SECONDS|UnitAffectingCombat|PLAYER_REGEN_ENABLED" "Raid Management Addon/Services/InspectCoordinator.lua"
```

Expected: all four policies are present only in the coordinator; the timeout scheduling occurs inside `start`.

- [ ] **Step 7: Run runtime/static validation and commit the inspect batch**

Run:

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -v
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon/Raid Management Addon.toc"
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "..\..\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
stylua --check "Raid Management Addon/Services/InspectCoordinator.lua" "Raid Management Addon/Services/EquipInspect.lua"
luacheck "Raid Management Addon/Services/InspectCoordinator.lua" "Raid Management Addon/Services/EquipInspect.lua"
git diff --check
git status --short --branch
```

Expected:

- complete Python/Lua suite PASS;
- TOC and Lua 5.1 validators exit 0;
- `xpcall` scan reports no Lua 5.1 extra-argument traps;
- XML scan returns no script handlers (exit code 1 is expected for no matches);
- formatter/linter checks and `git diff --check` exit 0;
- status lists only the five files in this task before commit.

Commit:

```powershell
git add -- "Raid Management Addon/Services/InspectCoordinator.lua" "Raid Management Addon/Services/EquipInspect.lua" "tests/lua/runtime_harness.lua" "tests/test_inspect_dataset_behavior.py" "tests/test_raid_recording_integrity_behavior.py"
git commit -m "refactor(inspect): centralize global scheduling"
```

Expected: one commit containing only the five listed files and a clean worktree after commit.

## Plan Completion Check

After Task 4, run:

```powershell
git log --oneline -5
git status --short --branch
git diff d4029e7..HEAD --check
```

Expected: four independent simplification commits above the design commit, a clean worktree, and no whitespace errors. Record the following for the later whole-branch simplicity review and commit-coherence report:

- `GetNamespaces` and its closure facade are absent;
- both dataset owners are called through the mandatory snapshot contract;
- only `Strings` implements UTF-8-safe prefix parsing;
- only `InspectCoordinator` owns global pacing, combat deferral, and inspect timeout;
- no SavedVariables schema, wire format, TOC entry, XML handler, or user-visible workflow changed;
- the in-game smoke test remains intentionally deferred to the final integrated candidate.
