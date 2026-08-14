# Delayed Raid Re-entry Recognition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start the existing raid re-entry recovery when WotLK exposes the raid instance only during the delayed login check.

**Architecture:** Keep WoW instance recognition and `RaidInstanceRecognized` publication in `Init.lua`. Reuse the existing three-second `CheckInitialRaidState` timer to refresh instance datasets through `handleRaidInstanceInfoChanged()` immediately before the ordinary session check; do not add timers or weaken the recovery-before-write barrier.

**Tech Stack:** WotLK 3.3.5a (Interface 30300), Lua 5.1, Python `unittest`, repository Lua runtime harness.

## Global Constraints

- Runtime target is WotLK 3.3.5a, Interface `30300`, Lua 5.1.
- Keep the existing recovery-before-write barrier in `Services/Raid/Session.lua` unchanged.
- Do not change SavedVariables schemas, addon-message protocol 3, public APIs, localization, or UI layout.
- Do not add a scheduler, retry loop, fallback raid creation, or compatibility layer.
- XML remains layout-only and vendored files under `Libs/*` remain untouched.
- Preserve unrelated modifications in `.superpowers/sdd/task-4-report.md` and untracked `.planning/`.

---

### Task 1: Republish delayed raid recognition before the guarded session check

**Files:**
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_raid_replication_behavior.py`
- Modify: `Raid Management Addon/Init.lua:885-887`
- Create: `.superpowers/sdd/delayed-reentry-recognition-report.md`

**Interfaces:**
- Consumes: local `handleRaidInstanceInfoChanged(emitRecognizedLog)` in `Init.lua`; `RaidInstanceRecognized` bus event; `DB.Syncer` re-entry guards; existing `Raid.CheckInitialRaidStateHandle` timer.
- Produces: no new public interface. The existing delayed timer publishes the existing recognition event when the context becomes valid.

- [ ] **Step 1: Add a mutable delayed-instance fixture**

In `installLiveReplicationClient`, store whether production instance data is ready:

```lua
productionInstanceReady = options.productionInstanceReady ~= false,
```

In `installProductionReentryRuntime`, replace both fixed production
`GetInstanceInfo` stubs with one local resolver and assign it at both existing
stub points:

```lua
local function getProductionInstanceInfo()
	if client.productionInstanceReady ~= true then
		return nil, "none", 0, nil, nil, nil, nil, nil
	end
	return "Naxxramas", "raid", 1, nil, nil, nil, nil, 533
end
```

```lua
_G.GetInstanceInfo = getProductionInstanceInfo
```

- [ ] **Step 2: Write the failing end-to-end regression**

Add this case beside the existing re-entry login regressions in
`tests/lua/runtime_harness.lua`:

```lua
function cases.raid_reentry_starts_when_instance_context_settles_after_login()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", nil, {
		realStore = true,
		seedActiveRaid = true,
		productionCapabilities = true,
		productionInstanceReady = false,
	})
	installReentryEntryWiring(leader)
	installLiveReplicationClient(network, "ReplicaB", leader.seedRecord)

	leader.addon:PLAYER_ENTERING_WORLD()
	assertEqual(nil, leader.syncer._reentry,
		"unavailable login context started re-entry recovery")
	assertEqual(nil, leader.addon.Database.GetCurrentRaid(),
		"unavailable login context selected a current raid")
	local initialCheckHandle = assert(leader.addon.Services.Raid.CheckInitialRaidStateHandle,
		"delayed initial raid check timer missing")
	local initialCheck = assert(leader.timers[initialCheckHandle],
		"delayed initial raid check callback missing")

	leader.productionInstanceReady = true
	initialCheck.callback()
	assertTrue(leader.syncer._reentry ~= nil,
		"settled delayed instance context did not start re-entry recovery")
	assertEqual(nil, leader.addon.Database.GetCurrentRaid(),
		"delayed recognition bypassed re-entry recovery")
	assertEqual(0, countEmittedEvent(leader,
		leader.addon.Events.Internal.RaidReplicationCommitted, "RAID_CREATED"),
		"delayed recognition created a competing raid")

	local completionHandle = assert(leader.syncer._reentry.timer,
		"delayed re-entry completion timer missing")
	assert(leader.timers[completionHandle]).callback()
	assertEqual(1, #leader.popupShows,
		"delayed instance recognition did not show exactly one re-entry popup")

	print("PASS raid_reentry_starts_when_instance_context_settles_after_login")
end
```

Expose it in `tests/test_raid_replication_behavior.py`:

```python
def test_reentry_starts_when_instance_context_settles_after_login(self) -> None:
    self.assert_case("raid_reentry_starts_when_instance_context_settles_after_login")
```

- [ ] **Step 3: Run the new test and verify RED**

Run:

```powershell
python -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_reentry_starts_when_instance_context_settles_after_login -v
```

Expected: FAIL because the delayed `CheckInitialRaidState` callback reaches the
recovery barrier without publishing `RaidInstanceRecognized`; `_reentry`
remains `nil`.

- [ ] **Step 4: Implement the minimal runtime fix**

Change only the existing `PLAYER_ENTERING_WORLD` delayed callback in
`Raid Management Addon/Init.lua`:

```lua
module.CheckInitialRaidStateHandle = module:ScheduleTimer(function()
	handleRaidInstanceInfoChanged()
	module:CheckInitialRaidState()
end, 3)
```

The refresh must precede `CheckInitialRaidState()` so the sync owner opens
re-entry recovery before the session owner evaluates its write barrier.

- [ ] **Step 5: Verify GREEN and nearby behavior**

Run the new focused test, then all re-entry/authority tests in
`tests.test_raid_replication_behavior`. Confirm the new case passes, existing
fresh bootstrap still creates exactly one raid, unresolved roster recovery
remains bounded, and no duplicate popup appears.

- [ ] **Step 6: Run the proportional final verification**

Run once:

```powershell
python -m unittest discover -s tests -p "test_*.py"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\validate_toc.py" "Raid Management Addon\Raid Management Addon.toc"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\lint_lua51.py" "Raid Management Addon"
py -3 "C:\Users\ferra\Downloads\RMA-Raid Management Addon\.agents\skills\wow-addon-dev-wotlk-v335a\scripts\scan_xpcall.py" "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon\UI" -g "*.xml"
luacheck "Raid Management Addon" --exclude-files "Raid Management Addon/Libs/**"
git diff --check
```

Treat `rg` exit 1 as success for the negative XML scan. Report any pre-existing
`luacheck` warning separately; do not change unrelated code.

- [ ] **Step 7: Record evidence and commit atomically**

Write RED/GREEN commands and results, validator output, changed-file scope, and
remaining manual smoke risk to
`.superpowers/sdd/delayed-reentry-recognition-report.md`.

Commit only the task files:

```powershell
git add -- "Raid Management Addon/Init.lua" "tests/lua/runtime_harness.lua" "tests/test_raid_replication_behavior.py" ".superpowers/sdd/delayed-reentry-recognition-report.md"
git commit -m "fix(sync-04): recognize delayed raid reentry context"
```

After review approval, deploy the complete addon folder from this isolated
worktree and repeat the in-game reload smoke: Yes resumes the same UID; No
concludes it and creates exactly one new UID.
