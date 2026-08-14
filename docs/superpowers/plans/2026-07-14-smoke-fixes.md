# Smoke Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the five behaviors found during the WotLK smoke test while preserving the simplified architecture and existing data-safety contracts.

**Architecture:** Patch the existing Logger, Master/Trade, Spammer/Comms, and DBSync owners. Trade settlement gains one event-driven retry, the Spammer gains one live multi-select, and persistent sync gains an explicit authoritative bootstrap that preserves local raid identity without merging unrelated NIDs.

**Tech Stack:** WoW WotLK 3.3.5a, Lua 5.1, FrameXML `UIDropDownMenuTemplate`, Python `unittest`, PowerShell, Git.

## Global Constraints

- Execute on `codex/rework-simplification`, starting from `61075a8` plus the two planning commits.
- Keep TOC Interface `30300` and Lua 5.1 compatibility.
- Do not change addon-message protocol version 2 or any message field layout.
- Do not change the `RMA_*` SavedVariables schema.
- Do not add runtime files, modules, polling `OnUpdate`, recovery registries, or global raid IDs.
- Keep XML layout-only and do not edit `Libs/`.
- Preserve the dirty `README.md` and `Raid Management Addon/README.md` in the main checkout.
- Each task is one independently reviewable commit.
- Run one simplicity review after implementation; do not open another speculative hardening cycle.
- Do not integrate into `codex/loot-bans-optimization` until the in-game smoke passes.

---

### Task 1: Settle Accepted Trades After The Bag Update And Gate Manual Dropdowns

**Files:**
- Modify: `Raid Management Addon/Init.lua:89-97,599-608`
- Modify: `Raid Management Addon/Controllers/Master.lua:2127-2168,3539-3575,3734-3757`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_loot_distribution_hardening_behavior.py`

**Interfaces:**
- Consumes: `TradeExecution:HasInFlightAward()`, `HasPendingAcceptedTrade()`, and `SettleAcceptedTrade(partnerName)`.
- Produces: one local, one-shot `BAG_UPDATE` retry allowance and one local manual-candidate refresh helper.
- Preserves: `TradeExecution.lua`, `Trade.lua`, and `TradeMenu.lua` transaction semantics.

- [ ] **Step 1: Write failing controller cases**

Add `loot_trade_close_retries_once_after_bag_update` and `loot_trade_menu_is_manual_only` to `tests/lua/runtime_harness.lua`.

The settlement case must assert:

```lua
master:TRADE_CLOSED()
runScheduledTimers()
assertEqual(true, tradeController:HasPendingAcceptedTrade(), "early close settle must remain pending")

ownedCount = ownedCount - 1
master:BAG_UPDATE()
runScheduledTimers()
assertEqual(false, tradeController:HasInFlightAward(), "bag update did not settle accepted trade")
assertEqual(1, confirmCalls, "accepted trade confirmed more than once")

master:BAG_UPDATE()
runScheduledTimers()
assertEqual(1, confirmCalls, "later bag update repeated settlement")
```

The menu case must run `TRADE_SHOW`, `TRADE_PLAYER_ITEM_CHANGED`, and `TRADE_TARGET_ITEM_CHANGED` with `HasInFlightAward()` true and assert zero `RefreshCandidate` calls plus hidden dropdowns. Run one item-change event with it false and assert one manual refresh.

- [ ] **Step 2: Run the focused tests and verify RED**

```powershell
py -3 -m unittest tests.test_loot_distribution_hardening_behavior -q
```

Expected: the new bag-update case has no registered handler and addon-driven item changes refresh manual candidates.

- [ ] **Step 3: Forward `BAG_UPDATE` through the existing event map**

Add the canonical event beside the trade events in `Init.lua`:

```lua
Wow.BagUpdate = Wow.BagUpdate or "wow.BAG_UPDATE"
```

Map the WoW event in the existing dispatcher:

```lua
BAG_UPDATE = WowEvents.BagUpdate,
```

Register `BAG_UPDATE` through `Private.RegisterWowForwarded` in `Controllers/Master.lua`.

- [ ] **Step 4: Add one bounded bag-update retry allowance**

Keep the current zero-delay close settlement. Add only local controller state:

```lua
local tradeCloseBagRetryAvailable = false

local function hasPendingTradeSettlement()
	return MasterService.Trade.HasClosePending() or tradeExecutionController:HasPendingAcceptedTrade()
end
```

Set the allowance before scheduling settlement in `TRADE_CLOSED`. Consume it at most once:

```lua
function module:BAG_UPDATE()
	if not tradeCloseBagRetryAvailable then return end
	if not hasPendingTradeSettlement() then
		tradeCloseBagRetryAvailable = false
		return
	end
	tradeCloseBagRetryAvailable = false
	scheduleManualTradeCloseSettle()
end
```

Clear the allowance on `TRADE_SHOW`, `TRADE_REQUEST_CANCEL`, explicit failure, and successful terminal settlement. Do not turn unresolved evidence into success and do not add periodic retries.

- [ ] **Step 5: Centralize the manual-menu gate**

Add one local helper and use it from all three trade-window events:

```lua
local function refreshManualTradeCandidate(source)
	if tradeExecutionController:HasInFlightAward() then
		Widgets.TradeMenu.HideDropdowns()
		return false
	end
	Widgets.TradeMenu.RefreshCandidate(source)
	return true
end
```

In `TRADE_ACCEPT_UPDATE`, derive `isAddonDrivenTrade` from `HasInFlightAward()` instead of duplicating `lootState.trader`/winner inference.

- [ ] **Step 6: Run GREEN and commit**

```powershell
py -3 -m unittest tests.test_loot_distribution_hardening_behavior -q
py -3 -m unittest discover -s tests -q
git diff --check
git add -- "Raid Management Addon/Init.lua" "Raid Management Addon/Controllers/Master.lua" tests/lua/runtime_harness.lua tests/test_loot_distribution_hardening_behavior.py
git commit -m "fix(trade): Settle accepted awards after bag updates"
```

Expected: one confirmation/release, no later duplicate, manual HOLD behavior preserved, addon-driven dropdowns always hidden.

---

### Task 2: Bootstrap Late Joiners From The Current Loot Authority

**Files:**
- Modify: `Raid Management Addon/Database/DBSyncer.lua:389-405,728-734,856-940,1012-1057,1061-1107,1536-1565`
- Modify: `Raid Management Addon/Database/DBSyncImport.lua:79-169,216-369`
- Modify: `Raid Management Addon/Database/DBRaidStore.lua:1274-1402`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_sync_communications_behavior.py`

**Interfaces:**
- Produces: `SnapshotImport.ReplaceRaidFromAuthority(raid, snapshot) -> raid | nil, reason`.
- Produces: `RaidStore:CommitAuthoritativeRaidHistoryImport(raid, stagedRaid, revision) -> boolean, raid | reason`.
- Keeps private: `module._syncLineage[localRaidNid] = { authorityName, sourceRaidNid, sourceRevision }`.
- Preserves: strict generic snapshot/delta validation for manual REQ/PUSH imports.

- [ ] **Step 1: Add failing late-join and authority tests**

Add these Lua cases and Python wrappers:

```text
sync_late_join_bootstrap_replaces_unrelated_local_history
sync_authoritative_bootstrap_rolls_back_atomically
sync_lineage_gates_incremental_delta
sync_master_looter_is_authoritative_without_rank
```

The bootstrap fixture must use different local/source `raidNid`, `startTime`, revision, and colliding player/boss/loot NIDs. Assert:

```lua
assertEqual(localRaidNid, destination.raidNid, "bootstrap replaced local raid identity")
assertEqual(sourceStartTime, destination.startTime, "bootstrap kept late login time")
assertEqual(sourcePlayerName, destination.players[1].name, "colliding player NID was merged")
assertEqual(#snapshot.loot, #destination.loot, "authoritative loot was not replaced exactly")
assertEqual(sourceRevision, store:GetRaidSyncRevision(destination), "source revision not adopted")
```

Also prove a rank-zero master looter is accepted while an assistant is rejected when master loot is active.

- [ ] **Step 2: Run the focused sync tests and verify RED**

```powershell
py -3 -m unittest tests.test_sync_communications_behavior -q
```

Expected: the envelope is rejected for `raid_mismatch`, or the importer attempts an unsafe NID upsert.

- [ ] **Step 3: Add a store-owned authoritative replacement commit**

Add a separate store method rather than weakening `CommitRaidHistoryImport`:

```lua
function module:CommitAuthoritativeRaidHistoryImport(raid, stagedRaid, targetRevision)
	if not isPositiveInteger(targetRevision) then
		return false, "INVALID_REVISION"
	end
	local base = stagedMutationBase[stagedRaid]
	if not base or base.raid ~= raid or self:GetRaidSyncRevision(raid) ~= base.revision then
		return false, "CONFLICT"
	end
	local valid, validationError = validateRaidHistory(stagedRaid)
	if not valid then return false, validationError end

	local canonicalFound = false
	local raids = ensureRaidsTable()
	for i = 1, #raids do
		if raids[i] == raid then canonicalFound = true; break end
	end
	if not canonicalFound then return false, "CONFLICT" end

	local snapshot = copyRaidHistoryValue(raid)
	local function replaceRaid(source)
		for key in pairs(raid) do raid[key] = nil end
		for key, value in pairs(copyRaidHistoryValue(source)) do raid[key] = value end
	end
	local committed = pcall(function()
		replaceRaid(stagedRaid)
		if self:SetRaidSyncRevision(raid, targetRevision, "sync_bootstrap") ~= targetRevision then
			error("REVISION_FAILED")
		end
		if type(self:EnsureRaidRuntime(raid)) ~= "table" then
			error("INDEX_REBUILD_FAILED")
		end
	end)
	if not committed then
		replaceRaid(snapshot)
		return false, "COMMIT_FAILED"
	end
	stagedMutationBase[stagedRaid] = nil
	return true, raid
end
```

This method may adopt a lower numeric revision because the old local revision belongs to an unrelated history. It must still reject concurrent local mutation by checking the staged base revision.

- [ ] **Step 4: Add the explicit authoritative importer**

`ReplaceRaidFromAuthority` must:

```lua
local localRaidNid = raid.raidNid
local valid, reason = SnapshotPayload.ValidateSnapshot(snapshot, 0, snapshot.header.raidNid)
if not valid then return nil, reason end

local staged = raidStore:StageRaidHistoryMutation(raid)
staged.raidNid = localRaidNid
staged.schemaVersion = snapshot.header.schemaVersion
staged.realm = snapshot.header.realm
staged.zone = snapshot.header.zone
staged.size = snapshot.header.size
staged.difficulty = snapshot.header.difficulty
staged.startTime = snapshot.header.startTime
staged.endTime = snapshot.header.endTime > 0 and snapshot.header.endTime or nil
staged.players = {}
staged.attendance = {}
staged.bossKills = {}
staged.loot = {}
```

Copy validated snapshot rows into the empty staged collections, apply the source next-NID counters, normalize once, and commit through `CommitAuthoritativeRaidHistoryImport`. Do not call the existing upsert path.

- [ ] **Step 5: Make authority match the actual loot authority**

For broadcast `MODE_SYNC`:

```lua
local function isAuthorizedSyncResponder(rawSender)
	local raid = Services.Raid
	if raid:GetLootMethodName() == "master" then
		return raid:IsLootAuthority(rawSender) == true
	end
	local _, rank = findRaidRosterMember(rawSender)
	return rank == 2
end
```

The local responder uses `Raid:IsMasterLooter()` under master loot and raid-leader rank otherwise. Do not change targeted REQ/PUSH authorization.

- [ ] **Step 6: Add runtime lineage and full-bootstrap fallback**

Initialize only runtime state:

```lua
module._syncLineage = module._syncLineage or {}
```

When creating a `MODE_SYNC` request, send `sinceRevision = 0` unless the lineage authority is still current and its recorded source revision equals the local raid revision. For an unbootstrapped snapshot, accept the authorized sender's positive envelope `raidNid`, validate header against that same source ID, replace the current raid atomically, then store normalized authority name, source ID, and source revision.

For a delta, require all three lineage values to match before parsing/applying it. Update `sourceRevision` only after a successful delta commit. Authority change, local revision drift, missing lineage after `/reload`, or source-ID change forces the next full snapshot.

- [ ] **Step 7: Run GREEN and commit**

```powershell
py -3 -m unittest tests.test_sync_communications_behavior -q
py -3 -m unittest discover -s tests -q
git diff --check
git add -- "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Database/DBSyncImport.lua" "Raid Management Addon/Database/DBRaidStore.lua" tests/lua/runtime_harness.lua tests/test_sync_communications_behavior.py
git commit -m "fix(sync): Bootstrap late raid joiners safely"
```

Expected: late joiners receive the master's complete current history, local raid identity remains valid, unsafe collisions do not merge, and deltas require proven lineage.

---

### Task 3: Invalidate The Loot History Raid List After Deletion

**Files:**
- Modify: `Raid Management Addon/Controllers/Logger.lua:1486-1751`
- Modify: `tests/test_raid_recording_integrity_behavior.py`

**Interfaces:**
- Consumes: existing `LoggerDataChanged` publication from `Services/Logger/Actions.lua`.
- Produces: no new API or event.

- [ ] **Step 1: Add a failing source-level controller contract**

In `tests/test_raid_recording_integrity_behavior.py`, isolate the `module.Raids` block and assert that it subscribes to `LoggerEvents.LoggerDataChanged` and calls its local `controller:Dirty()`.

```python
raids_block = source.split("module.Raids = module.Raids or {}", 1)[1].split("-- Loot list.", 1)[0]
self.assertIn("RegisterCallback(LoggerEvents.LoggerDataChanged", raids_block)
self.assertIn("controller:Dirty()", raids_block)
```

- [ ] **Step 2: Run RED**

```powershell
py -3 -m unittest tests.test_raid_recording_integrity_behavior -q
```

Expected: only the Loot block currently subscribes.

- [ ] **Step 3: Add the minimal raid-list subscription**

Inside the Raids block:

```lua
RegisterCallback(LoggerEvents.LoggerDataChanged, function()
	controller:Dirty()
end)
```

Keep `DeleteRaidsByNid`, focus recomputation, `LoggerSelectRaid("ui")`, and the existing Loot subscription unchanged. `Dirty()` followed by `Touch()` remains coalesced by the existing list controller.

- [ ] **Step 4: Run GREEN and commit**

```powershell
py -3 -m unittest tests.test_raid_recording_integrity_behavior -q
py -3 -m unittest discover -s tests -q
git diff --check
git add -- "Raid Management Addon/Controllers/Logger.lua" tests/test_raid_recording_integrity_behavior.py
git commit -m "fix(logger): Refresh raid rows after deletion"
```

---

### Task 4: Show Live Spammer Channels Without Mutating Saved Choices

**Files:**
- Modify: `Raid Management Addon/UI/Spammer.xml`
- Modify: `Raid Management Addon/Controllers/Spammer.lua:140-208,390-415,560-581,680-698,818-840`
- Modify: `Raid Management Addon/Modules/Comms.lua:389-411`
- Modify: `Raid Management Addon/Localization/localization.en.lua`
- Modify: `tests/lua/runtime_harness.lua`
- Modify: `tests/test_spammer_warnings_behavior.py`

**Interfaces:**
- Produces: one controller-local option model `{ value, text, checked, disabled }`.
- Preserves: name-based `Draft.GetChannels` and `Draft.SetChannelChecked` persistence.
- Removes: the fixed numeric `Chat1` through `Chat8` interaction contract.

- [ ] **Step 1: Add failing WotLK channel and dropdown tests**

Change the Comms fixture to the WotLK pair shape:

```lua
GetChannelList = function()
	return 1, "General", 2, "Trade"
end
```

Add a controller case with live `Trade`/`LookingForGroup`, saved `Trade`/`OldChannel`/`GUILD`, and `IsInGuild() == false`. Assert:

```lua
assertChoice("Trade", true, false)
assertChoice("LookingForGroup", false, false)
assertChoice("OldChannel", true, true)
assertChoice("GUILD", true, true)
assertChoice("YELL", false, false)
assertSameChannels(savedBefore, Draft.GetChannels(store), "render changed saved preferences")
```

Clicking `LookingForGroup` must add it. Disabled rows must not call `SetChannelChecked`.

- [ ] **Step 2: Run RED**

```powershell
py -3 -m unittest tests.test_spammer_warnings_behavior -q
```

Expected: Comms skips pair-shaped entries and the fixed checkbox UI cannot represent unavailable saved channels.

- [ ] **Step 3: Replace fixed controls with one WotLK dropdown**

In `UI/Spammer.xml`, remove the fixed channel-number labels and checkbuttons and place one layout-only frame:

```xml
<Frame name="$parentChannelMenu" inherits="UIDropDownMenuTemplate">
    <Size><AbsDimension x="205" y="32" /></Size>
    <Anchors>
        <Anchor point="TOPLEFT" relativeTo="$parentChannelsStr" relativePoint="BOTTOMLEFT" />
    </Anchors>
</Frame>
```

Use `UIDropDownMenu_Initialize`, `UIDropDownMenu_CreateInfo`, and `UIDropDownMenu_AddButton` from Lua. Opening the menu rebuilds choices from current membership; no polling or membership cache is added.

- [ ] **Step 4: Build choices without persistence side effects**

In `Controllers/Spammer.lua`, parse `{ GetChannelList() }` in steps of two, append `YELL`, then `GUILD`. Append saved-but-missing names as checked disabled rows using a localized unavailable suffix.

```lua
local function addChoice(value, checked, disabled)
	choices[#choices + 1] = {
		value = value,
		text = disabled and L.StrSpammerChannelUnavailable:format(value) or value,
		checked = checked,
		disabled = disabled,
	}
end
```

Only the dropdown click callback calls `Draft.SetChannelChecked`. Use the existing `setInputsLocked` path to enable/disable the dropdown during a run.

- [ ] **Step 5: Correct Comms channel resolution**

Change only the WotLK iteration shape:

```lua
for i = 1, #rows, 2 do
	local id, name = tonumber(rows[i]), rows[i + 1]
	-- existing exact-name and ambiguity checks
end
```

Keep delivery failure semantics unchanged.

- [ ] **Step 6: Run GREEN and commit**

```powershell
py -3 -m unittest tests.test_spammer_warnings_behavior -q
py -3 -m unittest tests.test_config_xml_contract -q
py -3 -m unittest discover -s tests -q
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
git diff --check
git add -- "Raid Management Addon/UI/Spammer.xml" "Raid Management Addon/Controllers/Spammer.lua" "Raid Management Addon/Modules/Comms.lua" "Raid Management Addon/Localization/localization.en.lua" tests/lua/runtime_harness.lua tests/test_spammer_warnings_behavior.py
git commit -m "fix(spammer): Select only live chat channels"
```

Expected: the XML scan returns no matches; unavailable saved choices remain visible and unchanged.

---

### Task 5: Run One Simplicity Review And All Offline Gates

**Files:**
- Review: changes after the two planning commits
- Modify only when removing unnecessary implementation complexity

**Interfaces:**
- Produces: one simplicity verdict and verified offline build.

- [ ] **Step 1: Run the four focused suites and full suite**

```powershell
py -3 -m unittest tests.test_loot_distribution_hardening_behavior -q
py -3 -m unittest tests.test_sync_communications_behavior -q
py -3 -m unittest tests.test_raid_recording_integrity_behavior -q
py -3 -m unittest tests.test_spammer_warnings_behavior -q
py -3 -m unittest discover -s tests -q
```

Expected: all commands exit 0.

- [ ] **Step 2: Perform the single simplicity review**

Use `detect-over-engineering` once over the implementation range. Reject:

```text
- any new runtime file or TOC entry
- persisted sync lineage or global raid ID
- more than one post-close trade retry
- channel polling or a second channel persistence model
- a new Logger refresh event
- compatibility wrappers used by only one caller
```

Apply only findings that remove code or state while preserving the approved behavior. If the review changes code, rerun the four focused suites and commit once:

```powershell
git add -- "Raid Management Addon" tests
git commit -m "refactor(runtime): Simplify smoke fixes"
```

- [ ] **Step 3: Run repository validators**

```powershell
py -3 ".agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py" "Raid Management Addon/Raid Management Addon.toc"
py -3 ".agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py" "Raid Management Addon"
py -3 ".agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py" "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
$luaFiles = rg --files "Raid Management Addon" -g "*.lua" -g "!Libs/**"
luacheck $luaFiles
git diff --check
git status --short --branch
```

Expected: TOC/Lua/xpcall/luacheck pass; XML search has no matches; diff check is clean.

---

### Task 6: Execute One In-Game Smoke And Integrate Only On PASS

**Files:**
- Preserve in main checkout: `README.md`
- Preserve in main checkout: `Raid Management Addon/README.md`

**Interfaces:**
- Produces: smoke-approved local integration into `codex/loot-bans-optimization`.

- [ ] **Step 1: Load the exact rework worktree build**

Use `C:\Users\ferra\Downloads\RMA-Raid Management Addon\.worktrees\rework-simplification\Raid Management Addon` in the WotLK 3.3.5a client.

- [ ] **Step 2: Run the smoke matrix**

```text
[ ] Login, /rma, all primary windows, and /reload produce no Lua errors.
[ ] Delete a non-current Loot History raid: its row disappears immediately and focus moves correctly.
[ ] Addon-driven HOLD trade: no roll-type dropdown appears on show or slot changes.
[ ] Accepted addon-driven trade: item leaves bags, award clears, and the next item can be awarded.
[ ] Manual later HOLD trade: matching items show roll-type selectors and log the chosen reasons.
[ ] Duplicate item copies settle from total inventory delta without retaining the old award.
[ ] Spammer selector lists current joined channels by name.
[ ] Leaving a saved channel keeps it visible checked+disabled; rejoining restores it without reselection.
[ ] Two-client sync: A enters the raid first and records loot; B joins later with a different local history.
[ ] B receives A's raid start time, roster, bosses, loot, roll data, and subsequent incremental updates.
[ ] B keeps a valid local raid record and neither client gains duplicated/corrupted rows.
[ ] A as rank-zero master looter is accepted as authority; a non-master assistant does not win the sync response.
```

Any failure blocks integration and becomes a focused reproduction; do not stack speculative fixes.

- [ ] **Step 3: Integrate locally after PASS**

From the main checkout:

```powershell
git status --short --branch
git stash push -m "user-local-before-smoke-fixes" -- README.md "Raid Management Addon/README.md"
git merge --ff-only codex/rework-simplification
git stash apply stash@{0}
py -3 -m unittest discover -s tests -q
git diff --check
git status --short --branch
```

Expected: fast-forward succeeds, all tests pass, and exactly the two pre-existing README modifications remain. Drop the stash only after verifying both files:

```powershell
git stash drop stash@{0}
```

## Final Acceptance Criteria

- All five smoke findings are covered by focused tests.
- No false trade confirmation or duplicate settlement is introduced.
- Manual and addon-driven trade UIs remain distinct.
- Late-join sync replaces unrelated history atomically and preserves local raid identity.
- Saved Spammer choices are never silently removed.
- No new module, SavedVariables field, protocol field, global raid ID, or polling loop exists.
- The full suite and offline validators pass.
- The two-client in-game smoke passes before integration.
- The main checkout's two README modifications are preserved.
