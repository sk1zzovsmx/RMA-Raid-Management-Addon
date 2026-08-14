# Raid Leader Authority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Raid Leader create and replicate the canonical active raid in both Group Loot and Master Loot while keeping Master Looter checks limited to loot operations.

**Architecture:** Add explicit Raid Leader capability methods to the existing Raid service and make `DBSyncer` use them as its sole active-database authority contract. Keep the current event stream, handover protocol, SavedVariables schema, and wire format unchanged; improve `Raid:Create` only enough to return its rejected store reason.

**Tech Stack:** World of Warcraft 3.3.5a build 12340, Interface 30300, Lua 5.1.5, Python `unittest`, repository Lua runtime harness.

## Global Constraints

- Work only in the isolated `codex/single-raid-history-sharing` worktree.
- Do not integrate into `codex/loot-bans-optimization` before a positive two-client in-game smoke.
- Do not change SavedVariables schemas or protocol version 3 wire messages.
- Do not add peer election, assistant fallback, polling, or compatibility wrappers.
- Keep Master Looter checks used by loot UI and loot-operation permissions.
- Use Lua 5.1 and WotLK 3.3.5a APIs only.

## File Map

- Modify `Raid Management Addon/Services/Raid/Capabilities.lua`: own Raid Leader identity and local-role resolution.
- Modify `Raid Management Addon/Database/DBRaidStore.lua`: report the correct rejected-authority role.
- Modify `Raid Management Addon/Database/DBSyncer.lua`: consume Raid Leader authority for creation guards, announcements, recovery, and handover.
- Modify `Raid Management Addon/Services/Raid/State.lua`: preserve the rejected creation reason after atomic rollback.
- Modify `tests/lua/runtime_harness.lua`: exercise Group Loot leadership, active replication authority, handover, and creation failures.
- Modify `tests/test_raid_replication_behavior.py`: expose the new live authority harness case to `unittest`.
- Modify `tests/test_raid_recording_integrity_behavior.py`: expose the creation-reason harness case to `unittest`.
- Modify `tests/test_sync_communications_behavior.py`: protect the Syncer-to-Raid capability dependency without encoding Master Looter authority.
- Modify `docs/superpowers/smoke/2026-07-16-raid-data-replication.md`: record automated evidence and the required fresh live scenario.

---

### Task 1: Expose Raid Leader Authority

**Files:**
- Modify: `Raid Management Addon/Services/Raid/Capabilities.lua:13-120`
- Test: `tests/lua/runtime_harness.lua:12090-12135`

**Interfaces:**
- Consumes: `GetNumRaidMembers()`, `GetRaidRosterInfo(index)`, `Database.GetUnitRank(unit, fallback)`.
- Produces: `Raid:GetRaidLeaderName() -> string|nil` and `Raid:IsRaidLeader() -> boolean`.

- [ ] **Step 1: Write the failing Group Loot capability test**

Extend the capability harness with a raid roster whose leader is `Local`, while `GetLootMethod()` returns `"group"`:

```lua
_G.GetNumRaidMembers = function() return 3 end
_G.GetRaidRosterInfo = function(index)
	local names = { "Local", "Disonesta", "Member" }
	return names[index], index == 1 and 2 or 0
end
_G.GetLootMethod = function() return "group", nil, nil end
addon.Database.GetUnitRank = function(unit) return unit == "player" and 2 or 0 end

assertEqual("Local", Raid:GetRaidLeaderName(), "group-loot raid leader differs")
assertEqual(true, Raid:IsRaidLeader(), "group-loot leader must own raid authority")
assertEqual(false, Raid:IsMasterLooter(), "group loot must not invent a master looter")
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_real_raid_capabilities_accept_numeric_unit_identity -v
```

Expected: FAIL because `GetRaidLeaderName`/`IsRaidLeader` are absent.

- [ ] **Step 3: Implement the minimal capability methods**

Bind the two WotLK roster APIs at file load and add the methods without changing existing Master Looter methods:

```lua
local GetNumRaidMembers = assert(_G.GetNumRaidMembers, "Raid capability roster count API is not initialized")
local GetRaidRosterInfo = assert(_G.GetRaidRosterInfo, "Raid capability roster API is not initialized")

function module:GetRaidLeaderName()
	local count = tonumber(GetNumRaidMembers()) or 0
	for i = 1, count do
		local name, rank = GetRaidRosterInfo(i)
		if name and tonumber(rank) == 2 then
			return name
		end
	end
	return nil
end

function module:IsRaidLeader()
	return IsPlayerInRaid(module) and (tonumber(GetUnitRank("player", 0)) or 0) >= 2
end
```

- [ ] **Step 4: Run the focused capability test and verify GREEN**

Run the command from Step 2. Expected: PASS, including the existing numeric `UnitIsUnit` Master Looter assertions.

- [ ] **Step 5: Commit the capability slice**

```powershell
git add -f -- "tests/lua/runtime_harness.lua"
git add -- "Raid Management Addon/Services/Raid/Capabilities.lua"
git commit -m "feat(raid): Expose raid leader authority"
```

---

### Task 2: Make Replication Authority Independent Of Loot Method

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua:97-1361`
- Modify: `Raid Management Addon/Database/DBRaidStore.lua:90-98`
- Modify: `tests/lua/runtime_harness.lua:12546-13905`
- Modify: `tests/test_raid_replication_behavior.py`
- Modify: `tests/test_sync_communications_behavior.py:108-120`

**Interfaces:**
- Consumes: `Raid:GetRaidLeaderName()` and `Raid:IsRaidLeader()` from Task 1.
- Produces: unchanged `DB.Syncer` public API and unchanged protocol version 3 messages.

- [ ] **Step 1: Write failing authority-contract tests**

Change the structural dependency assertion and live fixtures to expose only the new authority API:

```python
self.assertIn("Raid:GetRaidLeaderName()", source)
self.assertIn("RaidStore:SetAuthorityGuard", source)
self.assertIn("Raid:IsRaidLeader() == true", source)
self.assertNotIn("Raid:GetMasterLooterName()", source)
self.assertNotIn("Raid:IsMasterLooter()", source)
```

Rename the live-network authority field from `master` to `raidLeader`, then add:

```lua
function cases.raid_live_sync_group_loot_leader_authority()
	local network = newLiveReplicationNetwork()
	local leader = installLiveReplicationClient(network, "Leader", makeLiveRecord(1))
	local member = installLiveReplicationClient(network, "Member", makeLiveRecord(1))
	local committed, reason = leader.store:Commit(makeLiveEvent(2))
	assertTrue(committed ~= nil, "group-loot raid leader was rejected: " .. tostring(reason))
	local rejected, rejectedReason = member.store:Commit(makeLiveEvent(2))
	assertEqual(nil, rejected, "ordinary member originated an authoritative event")
	assertEqual("NOT_RAID_LEADER", rejectedReason, "store rejection contract changed")
	print("PASS raid_live_sync_group_loot_leader_authority")
end
```

Expose the case in `test_raid_replication_behavior.py`:

```python
def test_group_loot_uses_raid_leader_as_authority(self) -> None:
    self.assert_case("raid_live_sync_group_loot_leader_authority")
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior -v
py -3 -m unittest tests.test_raid_replication_behavior.RaidReplicationBehaviorTests.test_group_loot_uses_raid_leader_as_authority -v
```

Expected: structural assertion fails on Master Looter calls and the new runtime case fails until the fixture and Syncer use Raid Leader authority.

- [ ] **Step 3: Replace Syncer authority reads, preserving protocol behavior**

At every authority boundary in `DBSyncer.lua`, replace only the role resolver:

```lua
normalizeName(Raid:GetMasterLooterName())  --> normalizeName(Raid:GetRaidLeaderName())
Raid:IsMasterLooter()                     --> Raid:IsRaidLeader()
```

Rename local variables such as `master`/`isMasterLooter` to `leader`/`isRaidLeader`. Keep message kinds, fields, sequence rules, retry limits, handover state, and historical consent unchanged. Update all Syncer harness fixtures to provide:

```lua
GetRaidLeaderName = function() return network.raidLeader end,
IsRaidLeader = function() return name == network.raidLeader end,
```

Change the fail-closed store reason to match its new contract:

```lua
if not ok or allowed ~= true then
	return nil, "NOT_RAID_LEADER"
end
```

Update existing runtime assertions from `NOT_MASTER_LOOTER` to
`NOT_RAID_LEADER`. This reason is runtime-only and does not alter SavedVariables
or the protocol wire format.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run both commands from Step 2. Expected: PASS.

- [ ] **Step 5: Run the replication and communication suites**

```powershell
py -3 -m unittest tests.test_raid_replication_behavior tests.test_sync_communications_behavior -v
```

Expected: PASS with no protocol-version, consent, retry, conflict, or handover regression.

- [ ] **Step 6: Commit the replication slice**

```powershell
git add -- "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Database/DBRaidStore.lua"
git add -f -- "tests/lua/runtime_harness.lua" "tests/test_raid_replication_behavior.py" "tests/test_sync_communications_behavior.py"
git commit -m "fix(sync): Use raid leader as active authority"
```

---

### Task 3: Preserve Active-Raid Creation Failure Reasons

**Files:**
- Modify: `Raid Management Addon/Services/Raid/State.lua:1557-1588`
- Test: `tests/lua/runtime_harness.lua:3000-3200`
- Test: `tests/test_raid_recording_integrity_behavior.py`

**Interfaces:**
- Consumes: `RaidStore:CreateActiveRaid(args) -> raid, index, uid | nil, reason`.
- Produces: `Raid:Create(...) -> true | false, reason` while retaining atomic rollback.

- [ ] **Step 1: Write the failing diagnostic regression**

Inject a store rejection into the existing atomic creation fixture:

```lua
fixture.store.CreateActiveRaid = function()
	return nil, "INJECTED_CREATE_REJECTION"
end
local created, reason = raid:Create("Naxxramas", 10, 1)
assertEqual(false, created, "rejected raid creation must fail")
assertEqual("INJECTED_CREATE_REJECTION", reason, "creation rejection reason was hidden")
```

Retain the existing assertions proving history, roster metadata, current raid, indexes, and events are unchanged.

Expose the case in `test_raid_recording_integrity_behavior.py`:

```python
def test_raid_create_preserves_store_rejection_reason(self) -> None:
    result = run_lua_case("raid_create_preserves_store_rejection_reason")
    self.assertIn("PASS raid_create_preserves_store_rejection_reason", result.stdout)
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_raid_recording_integrity_behavior.RaidRecordingIntegrityBehaviorTests.test_raid_create_preserves_store_rejection_reason -v
```

Expected: FAIL because `Raid:Create` currently returns only `false`.

- [ ] **Step 3: Return the clean store reason after rollback**

Replace the assertion-only store call inside the protected commit:

```lua
local commitOk, commitError = pcall(function()
	-- existing conclusion logic remains unchanged
	local raidInfo, raidId = raidStore:CreateActiveRaid({
		-- existing fields remain unchanged
	})
	if not raidInfo then
		error(raidId or "RAID_CREATE_FAILED", 0)
	end
	-- existing current-raid and roster commit logic remains unchanged
end)
if not commitOk then
	rollbackCreate()
	return false, commitError
end
```

- [ ] **Step 4: Run the focused test and atomic creation tests**

Run the new case plus the existing `raid_session_create_failure_is_atomic` case. Expected: PASS and no partial state.

- [ ] **Step 5: Commit the diagnostic slice**

```powershell
git add -- "Raid Management Addon/Services/Raid/State.lua"
git add -f -- "tests/lua/runtime_harness.lua" "tests/test_raid_recording_integrity_behavior.py"
git commit -m "fix(raid): Preserve session creation rejection"
```

---

### Task 4: Verify And Refresh The Smoke Gate

**Files:**
- Modify: `docs/superpowers/smoke/2026-07-16-raid-data-replication.md`

**Interfaces:**
- Consumes: completed Tasks 1-3.
- Produces: evidence-backed automated results and an explicitly blocked live integration gate.

- [ ] **Step 1: Run the complete automated suite**

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -q
```

Expected: all tests PASS.

- [ ] **Step 2: Run WotLK and repository validators**

```powershell
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon/Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
git diff --check
```

Expected: TOC/Lua/xpcall checks pass, XML search has no matches, and diff check exits 0.

- [ ] **Step 3: Record the new evidence without opening the gate**

Update the smoke artifact with the exact commit, test count, commands, and these unchecked live steps:

```markdown
- [ ] In Group Loot, Raid Leader A enters a recognized raid and creates exactly one active raid.
- [ ] Participant B creates no competing raid and receives A's snapshot.
- [ ] Switching to Master Loot with a different ML does not change database authority.
- [ ] Loot, boss, reload, delta recovery, conclusion, and historical offer/acceptance converge.
```

Keep `Integration Gate: BLOCKED` until the user reports a positive two-client in-game smoke.

- [ ] **Step 4: Commit the verification artifact**

```powershell
git add -f -- "docs/superpowers/smoke/2026-07-16-raid-data-replication.md"
git commit -m "test(sync): Refresh raid leader smoke gate"
```

- [ ] **Step 5: Report the deployment and live-smoke handoff**

Report commits, exact automated results, remaining live steps, and confirm that `codex/loot-bans-optimization` was not changed.
