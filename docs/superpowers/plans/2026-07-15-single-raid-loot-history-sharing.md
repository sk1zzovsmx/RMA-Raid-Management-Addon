# Single-Raid Loot History Sharing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a player offer one selected Loot History raid to a current group member, require explicit recipient consent, and recover the current raid directly from Loot History.

**Architecture:** `Database/DBSyncer.lua` owns one small additive offer envelope and its 30-second runtime consent state, then reuses `RequestLoggerReq` and the existing atomic snapshot importer after acceptance. `Controllers/Logger.lua` owns the compact Share dialog and recipient confirmation; XML remains static layout only. Config retains persistent sync preferences but loses operational Push, Require, and Sync Now controls.

**Tech Stack:** World of Warcraft WotLK 3.3.5a build 12340, Interface 30300, Lua 5.1.5, FrameXML `UIDropDownMenuTemplate` and `StaticPopupDialogs`, Python `unittest`, repository Lua runtime harness.

## Global Constraints

- Preserve addon name `Raid Management Addon`, runtime name `RMA`, `/rma`, `RMA_*` SavedVariables, and `RMA` addon-message prefixes.
- Use only WotLK 3.3.5a APIs and Lua 5.1 syntax; do not use `C_Timer`, `Settings.*`, `table.unpack`, `goto`, or Lua 5.2+ constructs.
- Keep XML layout-only: no `<Scripts>` or `<On[A-Za-z]+>` handlers.
- Do not add Ace2, Ace3, a new runtime module, a remote catalog, or a new snapshot/delta format.
- Transmit no Loot History records before recipient acceptance.
- Keep pending offers runtime-only; make no SavedVariables schema change and do not clear `syncRequirePlayer` or `syncPushPlayer`.
- Preserve `/rma history req`, `/rma history push`, and `/rma history sync`.
- Keep every addon message at or below 255 bytes.
- Integration remains suspended until the two-client smoke test passes.

## File Map

- `Raid Management Addon/Modules/Events.lua`: declares the internal `LoggerRaidOfferReceived` event name.
- `Raid Management Addon/Database/DBSyncer.lua`: builds, validates, expires, accepts, and declines offer envelopes; accepted offers enter the existing request path.
- `Raid Management Addon/UI/LootHistory.xml`: declares `ShareBtn` and one compact static Share frame.
- `Raid Management Addon/Controllers/Logger.lua`: binds the Share frame, builds the current-roster dropdown, and renders the recipient confirmation popup.
- `Raid Management Addon/UI/Config.xml`: removes only the three operational synchronization rows.
- `Raid Management Addon/Controllers/Config.lua`: removes layout, localization, refresh, and handlers used only by those rows.
- `Raid Management Addon/Localization/localization.en.lua`: adds Share copy and removes copy used only by the retired Config rows.
- `tests/lua/runtime_harness.lua`: exercises offer validation and the consent-to-request transition with the real `DBSyncer`.
- `tests/test_sync_communications_behavior.py`: exposes the new Lua runtime cases to the Python suite.
- `tests/test_single_raid_sharing_contract.py`: protects XML/controller ownership and the Config surface.
- `tests/test_config_xml_contract.py`: updates the intentional Config XML name contract after removing eleven private children.
- `README.md` and `Raid Management Addon/README.md`: document the discoverable Share workflow while preserving all existing user-authored edits.

## Execution Setup

Use `superpowers:using-git-worktrees` to create an isolated implementation worktree from the branch containing this plan. Leave the two dirty README files in the original worktree untouched; Task 3 edits clean copies in the isolated branch, and final integration reconciles only the documented Share hunks with the preserved user changes.

---

### Task 1: Add the consent-gated single-raid offer protocol

**Files:**
- Modify: `Raid Management Addon/Modules/Events.lua:31-55`
- Modify: `Raid Management Addon/Database/DBSyncer.lua:60-127,177-230,430-610,1974-2071,2307-2417`
- Modify: `Raid Management Addon/Localization/localization.en.lua:50-70,400-455`
- Modify: `tests/lua/runtime_harness.lua:7185-7522`
- Modify: `tests/test_sync_communications_behavior.py:1-180`

**Interfaces:**
- Produces: `addon.Events.Internal.LoggerRaidOfferReceived` carrying one table with `offerId`, `sender`, `raidNid`, `zone`, `startTime`, `size`, `difficulty`, and `lootCount`.
- Produces: `Database.GetSyncer():OfferLoggerRaid(raidRef, targetName) -> true | false, reason`.
- Produces: `Database.GetSyncer():AcceptLoggerOffer(sender, offerId) -> true | false, reason`.
- Produces: `Database.GetSyncer():DeclineLoggerOffer(sender, offerId) -> true | false`.
- Reuses: `Database.GetSyncer():RequestLoggerReq(raidRef, targetName)` without changing its signature or request/snapshot wire format.

- [ ] **Step 1: Add failing Python entry points for the real Lua cases**

Add these methods to `SyncCommunicationsBehaviorTests`:

```python
    def test_raid_offer_requires_acceptance_and_requests_once(self) -> None:
        result = run_lua_case("sync_raid_offer_requires_acceptance_and_requests_once")
        self.assertIn("PASS sync_raid_offer_requires_acceptance_and_requests_once", result.stdout)

    def test_raid_offer_rejects_invalid_target_and_expires(self) -> None:
        result = run_lua_case("sync_raid_offer_rejects_invalid_target_and_expires")
        self.assertIn("PASS sync_raid_offer_rejects_invalid_target_and_expires", result.stdout)

    def test_raid_offer_is_bounded_and_replaces_sender_pending(self) -> None:
        result = run_lua_case("sync_raid_offer_is_bounded_and_replaces_sender_pending")
        self.assertIn("PASS sync_raid_offer_is_bounded_and_replaces_sender_pending", result.stdout)
```

- [ ] **Step 2: Add failing runtime cases using the existing real-DBSyncer fixture**

Extend `installRealDbSyncerFixture` with `LoggerRaidOfferReceived = "LOGGER_RAID_OFFER"`, give its canonical raid `startTime = 1721066400` and `loot = { { lootNid = 1 } }`, and add these cases:

```lua
function cases.sync_raid_offer_requires_acceptance_and_requests_once(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}
	fixture.groupUnits["leader-test realm"] = "raid1"
	fixture.groupUnits["tester-test realm"] = "raid2"

	syncer:OnAddonMessage(
		"RMALogSync",
		table.concat({ "OF", 2, "offer-1", 41, "Tester-Test Realm", "Naxxramas", 1721066400, 25, 1, 1 }, "\t"),
		"WHISPER",
		"Leader-Test Realm"
	)
	assertEqual(1, #fixture.events, "valid offer must publish once")
	assertEqual("LOGGER_RAID_OFFER", fixture.events[1].eventName, "offer event differs")
	assertEqual(0, #fixture.sent, "offer receipt must not request history before acceptance")
	assertEqual(0, fixture.imports, "offer receipt must not import history")

	assertEqual(true, syncer:AcceptLoggerOffer("Leader-Test Realm", "offer-1"), "offer acceptance must request history")
	assertEqual(1, #fixture.sent, "acceptance must send exactly one request")
	local fields = { string.match(fixture.sent[1].message, "([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)") }
	assertEqual("RQ", fields[1], "acceptance must reuse request envelope")
	assertEqual("REQ", fields[4], "accepted offer must use manual request mode")
	assertEqual("41", fields[5], "accepted offer must request the offered source raid")
	assertEqual(false, syncer:AcceptLoggerOffer("Leader-Test Realm", "offer-1"), "offer must be single-use")
	assertEqual(1, #fixture.sent, "repeat acceptance must not send another request")
	print("PASS sync_raid_offer_requires_acceptance_and_requests_once")
end

function cases.sync_raid_offer_rejects_invalid_target_and_expires(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}
	fixture.groupUnits["leader-test realm"] = "raid1"
	fixture.groupUnits["tester-test realm"] = "raid2"

	local function receive(id, target, sender)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "OF", 2, id, 41, target, "Naxxramas", 1721066400, 25, 1, 1 }, "\t"),
			"WHISPER",
			sender
		)
	end
	receive("wrong-target", "Someone-Test Realm", "Leader-Test Realm")
	receive("outsider", "Tester-Test Realm", "Outsider-Test Realm")
	syncer:OnAddonMessage("RMALogSync", table.concat({ "UNKNOWN", 2, "ignored", "data" }, "\t"), "WHISPER", "Leader-Test Realm")
	assertEqual(0, #fixture.events, "invalid offers must not reach UI")
	assertEqual(0, fixture.imports, "unknown additive message kinds must be harmless")
	receive("expires", "Tester-Test Realm", "Leader-Test Realm")
	fixture.now = fixture.now + 31
	assertEqual(false, syncer:AcceptLoggerOffer("Leader-Test Realm", "expires"), "expired offer must fail")
	assertEqual(0, #fixture.sent, "expired offer must not request history")
	print("PASS sync_raid_offer_rejects_invalid_target_and_expires")
end

function cases.sync_raid_offer_is_bounded_and_replaces_sender_pending(addon)
	local fixture, syncer = installRealDbSyncerFixture(addon)
	fixture.roster = {
		{ name = "Leader-Test Realm", rank = 0 },
		{ name = "Tester-Test Realm", rank = 0 },
	}
	fixture.groupUnits["leader-test realm"] = "raid1"
	fixture.groupUnits["tester-test realm"] = "raid2"
	assertEqual(true, syncer:OfferLoggerRaid(41, "Leader-Test Realm"), "outbound offer must queue")
	assertTrue(#fixture.sent[1].message <= 255, "offer must fit the WotLK addon-message limit")
	assertTrue(not string.find(fixture.sent[1].message, "snapshot", 1, true), "offer must contain no history payload")

	local function receive(id)
		syncer:OnAddonMessage(
			"RMALogSync",
			table.concat({ "OF", 2, id, 41, "Tester-Test Realm", "Naxxramas", 1721066400, 25, 1, 1 }, "\t"),
			"WHISPER",
			"Leader-Test Realm"
		)
	end
	receive("old-offer")
	receive("new-offer")
	receive("new-offer")
	assertEqual(2, #fixture.events, "duplicate offer ID must not republish")
	assertEqual(false, syncer:AcceptLoggerOffer("Leader-Test Realm", "old-offer"), "new offer must replace old sender offer")
	assertEqual(true, syncer:AcceptLoggerOffer("Leader-Test Realm", "new-offer"), "latest sender offer must remain valid")
	print("PASS sync_raid_offer_is_bounded_and_replaces_sender_pending")
end
```

- [ ] **Step 3: Run the new tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_raid_offer_requires_acceptance_and_requests_once tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_raid_offer_rejects_invalid_target_and_expires tests.test_sync_communications_behavior.SyncCommunicationsBehaviorTests.test_raid_offer_is_bounded_and_replaces_sender_pending -v
```

Expected: FAIL because the three Lua cases and offer methods are not yet available.

- [ ] **Step 4: Declare the event and implement the minimal offer state machine**

Add to `Modules/Events.lua`:

```lua
Internal.LoggerRaidOfferReceived = "LoggerRaidOfferReceived"
```

In `DBSyncer.lua`, add `MSG_OFFER = "OF"`, `OFFER_TTL_SECONDS = 30`, `module._pendingOffers = module._pendingOffers or {}`, and clean entries older than 30 seconds inside `cleanupExpiredState`. Add the event assertion beside the existing internal event bindings.

Implement these exact public transitions and dispatch rule:

```lua
function module:OfferLoggerRaid(raidRef, targetName)
	if not ensureGroupSyncAvailable() then return false, "not_in_group" end
	local target = resolveExternalTarget(targetName)
	if not target or not isCurrentGroupMember(target) then
		addon:warn(L.MsgLoggerRaidOfferTargetUnavailable)
		return false, "target_not_member"
	end
	local raid = select(1, SnapshotImport.ResolveRaidByReference(tonumber(raidRef), false))
	if type(raid) ~= "table" then
		addon:warn(L.MsgLoggerSyncNoRaid)
		return false, "raid_not_found"
	end
	local raidNid = tonumber(raid.raidNid) or 0
	local startTime = tonumber(raid.startTime) or 0
	local size = tonumber(raid.size) or 0
	local difficulty = tonumber(raid.difficulty) or 0
	local lootCount = type(raid.loot) == "table" and #raid.loot or 0
	if raidNid <= 0 or startTime <= 0 or size < 1 or size > 40 or difficulty < 1 or difficulty > 4 or lootCount > 10000 then
		return false, "invalid_raid_summary"
	end
	local offerId, reason = allocateRequestId(self)
	if not offerId then return false, reason end
	local payload = packFields(
		FIELD_SEP,
		MSG_OFFER,
		PROTOCOL_VERSION,
		offerId,
		raidNid,
		target,
		SnapshotPayload.EncodeText(tostring(raid.zone or "")),
		startTime,
		size,
		difficulty,
		lootCount
	)
	if #payload > MAX_ADDON_MESSAGE_BYTES then return false, "message_too_large" end
	local queued, queueReason = sendAddonPayload(target, payload)
	if not queued then return false, queueReason end
	addon:info(L.MsgLoggerRaidOfferSent:format(tostring(raid.raidNid), tostring(target)))
	return true
end

function module:AcceptLoggerOffer(sender, offerId)
	cleanupExpiredState()
	local key = stableSenderKey(sender)
	local offer = key and self._pendingOffers[key] or nil
	if not offer or offer.offerId ~= tostring(offerId or "") then
		addon:warn(L.MsgLoggerRaidOfferUnavailable)
		return false, "offer_unavailable"
	end
	if not addon.IsInGroup() or not isCurrentGroupMember(offer.sender) then
		self._pendingOffers[key] = nil
		return false, "sender_not_member"
	end
	self._pendingOffers[key] = nil
	return self:RequestLoggerReq(offer.raidNid, offer.sender)
end

function module:DeclineLoggerOffer(sender, offerId)
	local key = stableSenderKey(sender)
	local offer = key and self._pendingOffers[key] or nil
	if not offer or offer.offerId ~= tostring(offerId or "") then return false end
	self._pendingOffers[key] = nil
	return true
end
```

Before the generic protocol-version branch in `OnAddonMessage`, accept only a version-2 whisper with ten fields, a bounded offer ID, a positive raid ID and start time, size `1..40`, difficulty `1..4`, loot count `0..10000`, a non-empty decoded zone, a target matching the local player, and a current-group sender. Ignore an offer when the same sender already has the same `offerId`; otherwise store it under `stableSenderKey(sender)`, replacing only that sender's prior offer, then call:

```lua
TriggerEvent(LoggerRaidOfferReceivedEvent, {
	offerId = offerId,
	sender = normalizeSender(sender),
	raidNid = sourceRaidNid,
	zone = zone,
	startTime = startTime,
	size = size,
	difficulty = difficulty,
	lootCount = lootCount,
})
```

Add these English messages:

```lua
L.MsgLoggerRaidOfferSent = "Raid #%s offered to %s."
L.MsgLoggerRaidOfferTargetUnavailable = "Select a current group member."
L.MsgLoggerRaidOfferUnavailable = "That raid offer is no longer available."
```

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Step 3 command again.

Expected: all three tests PASS; the first case proves no request/import before acceptance and exactly one existing `REQ` after acceptance.

- [ ] **Step 6: Run the complete sync regression file**

Run:

```powershell
py -3 -m unittest tests.test_sync_communications_behavior -v
```

Expected: all sync communication tests PASS with unchanged request, snapshot, delta, Push, and persistent-sync behavior.

- [ ] **Step 7: Commit Task 1**

```powershell
git add -- "Raid Management Addon/Modules/Events.lua" "Raid Management Addon/Database/DBSyncer.lua" "Raid Management Addon/Localization/localization.en.lua" "tests/lua/runtime_harness.lua" "tests/test_sync_communications_behavior.py"
git commit -m "feat(sync): add consent-gated raid offers"
```

---

### Task 2: Add the compact Share dialog to Loot History

**Files:**
- Modify: `Raid Management Addon/UI/LootHistory.xml:244-269,624-end`
- Modify: `Raid Management Addon/Controllers/Logger.lua:10-60,86-130,1484-1601,1713-1730,2180-2201`
- Modify: `Raid Management Addon/Localization/localization.en.lua:50-80,400-470`
- Create: `tests/test_single_raid_sharing_contract.py`

**Interfaces:**
- Consumes: `OfferLoggerRaid`, `AcceptLoggerOffer`, `DeclineLoggerOffer`, `RequestLoggerSync`, and `LoggerRaidOfferReceived` from Task 1.
- Produces: XML frame `RMALootHistoryShareFrame` and button `RMALootHistoryRaidsShareBtn`.
- Keeps recipient selection in `module._shareTarget`; it is runtime-only and is cleared when the dialog closes or roster membership changes.

- [ ] **Step 1: Write failing layout and controller contract tests**

Create `tests/test_single_raid_sharing_contract.py`:

```python
from __future__ import annotations

from pathlib import Path
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
XML = ROOT / "Raid Management Addon" / "UI" / "LootHistory.xml"
LOGGER = ROOT / "Raid Management Addon" / "Controllers" / "Logger.lua"


class SingleRaidSharingContractTests(unittest.TestCase):
    def test_share_layout_is_static_and_declares_required_controls(self) -> None:
        ET.parse(XML)
        source = XML.read_text(encoding="utf-8")
        self.assertNotRegex(source, r"<Scripts>|<On[A-Za-z]+>")
        for name in (
            "$parentShareBtn",
            "RMALootHistoryShareFrame",
            "$parentSummary",
            "$parentRecipientDropDown",
            "$parentSendBtn",
            "$parentRecoverBtn",
        ):
            self.assertIn(f'name="{name}"', source)

    def test_logger_binds_share_actions_to_existing_sync_owner(self) -> None:
        source = LOGGER.read_text(encoding="utf-8")
        self.assertIn("syncer:OfferLoggerRaid(raid.raidNid, module._shareTarget)", source)
        self.assertIn("syncer:RequestLoggerSync()", source)
        self.assertIn("syncer:AcceptLoggerOffer(offer.sender, offer.offerId)", source)
        self.assertIn("syncer:DeclineLoggerOffer(offer.sender, offer.offerId)", source)
        self.assertIn("RegisterCallback(LoggerEvents.LoggerRaidOfferReceived", source)

    def test_share_actions_are_fail_closed(self) -> None:
        source = LOGGER.read_text(encoding="utf-8")
        self.assertIn("Raid:IsGroupMember(module._shareTarget)", source)
        self.assertIn("Raid:GetMasterLooterName()", source)
        self.assertIn("UI.Primitives.SetEnabled", source)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the contract tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_single_raid_sharing_contract -v
```

Expected: FAIL because the button, frame, and controller bindings do not exist.

- [ ] **Step 3: Add static XML layout without scripts**

In the raids panel, place a 65x25 `$parentShareBtn` between `$parentCurrentBtn` and `$parentDeleteBtn`, re-anchor Delete to Share, and adjust Current's horizontal offset so all three remain centered.

Append one hidden `RMALootHistoryShareFrame` inheriting `RMAWindowTemplate`, parented to `UIParent`, 360x230, centered, `frameStrata="DIALOG"`, with these named static children:

```xml
<Frame name="RMALootHistoryShareFrame" inherits="RMAWindowTemplate" parent="UIParent" frameStrata="DIALOG" hidden="true">
	<Size><AbsDimension x="360" y="230" /></Size>
	<Anchors><Anchor point="CENTER" /></Anchors>
	<Layers>
		<Layer level="ARTWORK">
			<FontString name="$parentSummary" inherits="GameFontHighlightSmall" justifyH="LEFT" justifyV="TOP">
				<Anchors>
					<Anchor point="TOPLEFT"><Offset><AbsDimension x="24" y="-46" /></Offset></Anchor>
					<Anchor point="TOPRIGHT"><Offset><AbsDimension x="-24" y="-46" /></Offset></Anchor>
				</Anchors>
			</FontString>
			<FontString name="$parentRecipientLabel" inherits="GameFontNormalSmall" justifyH="LEFT">
				<Anchors><Anchor point="TOPLEFT"><Offset><AbsDimension x="24" y="-112" /></Offset></Anchor></Anchors>
			</FontString>
		</Layer>
	</Layers>
	<Frames>
		<Frame name="$parentRecipientDropDown" inherits="UIDropDownMenuTemplate">
			<Anchors><Anchor point="TOPLEFT"><Offset><AbsDimension x="8" y="-126" /></Offset></Anchor></Anchors>
		</Frame>
		<Button name="$parentSendBtn" inherits="RMAActionButtonTemplate">
			<Size><AbsDimension x="135" y="25" /></Size>
			<Anchors><Anchor point="BOTTOMLEFT"><Offset><AbsDimension x="24" y="24" /></Offset></Anchor></Anchors>
		</Button>
		<Button name="$parentRecoverBtn" inherits="RMAActionButtonTemplate">
			<Size><AbsDimension x="155" y="25" /></Size>
			<Anchors><Anchor point="LEFT" relativeTo="$parentSendBtn" relativePoint="RIGHT"><Offset><AbsDimension x="8" y="0" /></Offset></Anchor></Anchors>
		</Button>
	</Frames>
</Frame>
```

- [ ] **Step 4: Bind the Share dialog and recipient confirmation in Logger**

Add `LoggerRaidOfferReceived` and `RaidRosterDelta` to `LoggerEvents`. Bind `UnitName`, `UnitIsUnit`, and `addon.GetGroupTypeAndCount` at file scope. Implement `collectShareRecipients()` by iterating group units from the compatibility helper, excluding `UnitIsUnit(unit, "player")`, normalizing names, sorting with the existing string comparator, and returning only current members.

Implement one `bindShareFrame()` owner that:

- initializes the WotLK `UIDropDownMenuTemplate` with `UIDropDownMenu_Initialize`, `UIDropDownMenu_CreateInfo`, and `UIDropDownMenu_AddButton`;
- sets dropdown width to 220 and button width to 240;
- calls `SetFrameTitle("RMALootHistoryShareFrame", L.StrLoggerShareTitle)` and localizes the recipient label and both action buttons;
- renders `zone`, `RaidProjections.FormatTimestamp(startTime)`, `RaidProjections.GetDifficultyLabel(raid)`, and `#raid.loot` into `$parentSummary`;
- enables Send only when `module._shareTarget` is still returned by `Raid:IsGroupMember`;
- enables Recover only when a current raid exists, the player is grouped, and `Raid:GetMasterLooterName()` returns a non-empty name;
- binds Send to the exact call tested in Step 1 and hides the frame only on success;
- binds Recover to `syncer:RequestLoggerSync()` and hides the frame only on success.
- clears `module._shareTarget` from the frame's `OnHide` handler.

Bind and localize `$parentShareBtn` next to the existing Current/Delete bindings. Enable it only when `module.selectedRaid` resolves to a raid and `addon.IsInGroup()` is true. On `LoggerEvents.RaidRosterDelta`, clear `_shareTarget` if it is no longer a group member, rebuild the dropdown, and refresh Send/Recover state when the Share frame is visible.

Define the receiver popup once with the following behavior:

```lua
DefinePopup("RMALOGGER_RAID_OFFER", {
	text = L.StrLoggerRaidOfferPrompt,
	button1 = L.BtnAccept,
	button2 = L.BtnDecline,
	timeout = 30,
	whileDead = 1,
	hideOnEscape = 1,
	preferredIndex = 3,
	OnAccept = function(_, offer)
		local syncer = Database.GetSyncer()
		if syncer and offer then syncer:AcceptLoggerOffer(offer.sender, offer.offerId) end
	end,
	OnCancel = function(_, offer)
		local syncer = Database.GetSyncer()
		if syncer and offer then syncer:DeclineLoggerOffer(offer.sender, offer.offerId) end
	end,
})
```

Register `LoggerEvents.LoggerRaidOfferReceived`, format a two-line display summary, and call `ShowPopup("RMALOGGER_RAID_OFFER", offer.sender, summary, offer)`. Do not import, request, or mutate history in the event callback.

Add these localized strings:

```lua
L.BtnShare = "Share"
L.BtnAccept = "Accept"
L.BtnDecline = "Decline"
L.BtnLoggerSendRaid = "Send selected raid"
L.BtnLoggerRecoverRaid = "Recover current raid"
L.StrLoggerShareTitle = "Share Raid History"
L.StrLoggerShareRecipient = "Group member"
L.StrLoggerShareSummary = "%s\n%s - %s - %d loot records"
L.StrLoggerRaidOfferPrompt = "%s offered this raid history:\n%s"
```

- [ ] **Step 5: Run UI contracts and XML validation**

Run:

```powershell
py -3 -m unittest tests.test_single_raid_sharing_contract -v
py -3 -c "import xml.etree.ElementTree as ET; ET.parse(r'Raid Management Addon/UI/LootHistory.xml'); print('PASS LootHistory.xml')"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
```

Expected: the test file and XML parse PASS; the `rg` command returns no matches.

- [ ] **Step 6: Commit Task 2**

```powershell
git add -- "Raid Management Addon/UI/LootHistory.xml" "Raid Management Addon/Controllers/Logger.lua" "Raid Management Addon/Localization/localization.en.lua" "tests/test_single_raid_sharing_contract.py"
git commit -m "feat(logger): add single-raid share dialog"
```

---

### Task 3: Remove operational Config actions and document the new workflow

**Files:**
- Modify: `Raid Management Addon/UI/Config.xml:536-564`
- Modify: `Raid Management Addon/Controllers/Config.lua:405-445,797-825,1110-1165,1385-1477`
- Modify: `Raid Management Addon/Localization/localization.en.lua:59-61,437-443`
- Modify: `tests/test_config_xml_contract.py:13-75`
- Modify: `tests/test_single_raid_sharing_contract.py`
- Modify: `README.md:118-160,215-225`
- Modify: `Raid Management Addon/README.md:118-160,215-225`

**Interfaces:**
- Consumes: the Share workflow from Task 2.
- Preserves: `persistentSync`, `syncRequirePlayer`, and `syncPushPlayer` option registrations and values.
- Preserves: all three `/rma history` operational slash commands.
- Removes: only the Config-panel controls and `Config:RequestLoggerSyncPanelAction` path.

- [ ] **Step 1: Change tests to require a preference-only Config panel**

Replace `test_logger_sync_panel_actions_emit_debug_gated_results` with:

```python
    def test_logger_panel_keeps_preferences_but_removes_operational_actions(self) -> None:
        xml = source()
        controller = CONTROLLER_LUA.read_text(encoding="utf-8")
        self.assertIn("PersistentSyncCheck", xml)
        for retired in (
            "RequireDatabaseEditBox",
            "RequireDatabaseBtn",
            "PushDatabaseEditBox",
            "PushDatabaseBtn",
            "SyncNowBtn",
        ):
            self.assertNotIn(retired, xml)
            self.assertNotIn(retired, controller)
        self.assertNotIn("RequestLoggerSyncPanelAction", controller)
```

Update the ordered-name contract to:

```python
EXPECTED_ORDERED_NAMES_SHA256 = (
    "717c5a58e583d7a5f64a1a72ca00f534a0bce0b2615affcba026ddcc5302028e"
)
```

and change the expected count from `235` to `224`.

Extend `test_single_raid_sharing_contract.py` with a source assertion that `EntryPoints/SlashEvents.lua` still contains `RequestLoggerReq`, `BroadcastLoggerPush`, and `RequestLoggerSync` in the history command branch.

- [ ] **Step 2: Run the Config tests and verify RED**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract tests.test_single_raid_sharing_contract -v
```

Expected: FAIL because the operational Config controls and controller code still exist.

- [ ] **Step 3: Remove only the operational Config surface**

From `UI/Config.xml`, delete the eleven private elements whose names contain:

```text
RequireDatabaseTitle
RequireDatabaseDesc
PushDatabaseTitle
PushDatabaseDesc
SyncNowTitle
SyncNowDesc
RequireDatabaseEditBox
RequireDatabaseBtn
PushDatabaseEditBox
PushDatabaseBtn
SyncNowBtn
```

From `Controllers/Config.lua`, delete:

- the two `Layout.EditCommandRow` entries and the `Layout.CommandRow("SyncNow", "SyncNowBtn", {` entry;
- their eleven localization assignments;
- their edit-box refresh/save fields;
- `bindLootHistorySyncEditBox`;
- their five frame references and three click handlers;
- `traceConfigSyncAction` and `RequestLoggerSyncPanelAction` when `rg` confirms they have no remaining callers.

Keep the Logger options namespace keys in `DBSyncer.lua`; do not write nil or empty values into existing SavedVariables.

Remove only the now-unused Config-specific English strings `BtnLoggerRequireDatabase`, `BtnLoggerPushDatabase`, `BtnLoggerSyncNow`, `StrConfigLootHistoryRequireDatabaseTitle`, `StrConfigLootHistoryRequireDatabaseDesc`, `StrConfigLootHistoryPushDatabaseTitle`, `StrConfigLootHistoryPushDatabaseDesc`, `StrConfigLootHistorySyncNowTitle`, and `StrConfigLootHistorySyncNowDesc`.

- [ ] **Step 4: Update both user-facing README copies without replacing existing edits**

Under `### Loot History`, add:

```markdown
- Use **Share** in Loot History to offer the selected raid to one current group
  member. The recipient must accept before RMA requests and imports that raid.
- Use **Recover current raid** from the same dialog to request the active raid
  from the current Master Looter.
```

In the configuration list, describe Loot History configuration as:

```markdown
- Loot History persistent sync, passive Group Loot filtering,
  quality-threshold override, maintenance, cleanup, and data-health actions.
```

Do not stage unrelated README hunks. If the isolated implementation worktree does not contain the two current user-owned README edits, record the exact documentation patch and apply it while preserving those edits before the feature branch is offered for integration.

- [ ] **Step 5: Run focused tests and documentation diff checks**

Run:

```powershell
py -3 -m unittest tests.test_config_xml_contract tests.test_single_raid_sharing_contract -v
git diff --check
git diff -- README.md "Raid Management Addon/README.md"
```

Expected: tests PASS; no whitespace errors; README diff contains only the two new Share bullets and the Config wording change in addition to pre-existing user edits.

- [ ] **Step 6: Commit Task 3**

```powershell
git add -- "Raid Management Addon/UI/Config.xml" "Raid Management Addon/Controllers/Config.lua" "Raid Management Addon/Localization/localization.en.lua" "tests/test_config_xml_contract.py" "tests/test_single_raid_sharing_contract.py" "README.md" "Raid Management Addon/README.md"
git diff --cached --check
git commit -m "refactor(config): move raid sharing into loot history"
```

---

## Final Simplicity Review And Verification

- [ ] Run `$base = git merge-base HEAD codex/loot-bans-optimization; git diff "$base..HEAD" --name-only` and confirm it contains no new runtime module, no TOC change, no SavedVariables migration, and no snapshot/delta format change.
- [ ] Confirm `rg -n "Offer|pendingOffers|LoggerRaidOffer" "Raid Management Addon" -g "*.lua" -g "*.xml"` shows exactly one wire owner (`DBSyncer`) and one UI owner (`Logger`).
- [ ] Confirm the offer has no ACK framework, retry loop, persistent registry, remote catalog, or full-database path.
- [ ] Run the full automated suite:

```powershell
py -3 -m unittest discover -s tests -p "test_*.py" -v
```

- [ ] Run repository and WotLK validators:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/check-rma.ps1
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/validate_toc.py "Raid Management Addon/Raid Management Addon.toc"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/lint_lua51.py "Raid Management Addon"
py -3 .agents/skills/wow-addon-dev-wotlk-v335a/scripts/scan_xpcall.py "Raid Management Addon"
rg -n "<Scripts>|<On[A-Za-z]+>" "Raid Management Addon/UI" -g "*.xml"
git diff --check
git status --short --branch
```

Expected: all automated checks PASS; XML handler search returns no matches; only deliberately preserved user-owned files may remain dirty outside the implementation worktree.

## Two-Client Smoke Gate

Do not integrate before completing all seven checks:

1. A and B join the same party or raid with compatible RMA versions.
2. A selects one historical raid, clicks Share, chooses B, and sends the offer.
3. B declines; no raid or loot row changes on B.
4. A repeats the offer; B accepts and receives only that raid with no duplicate loot rows.
5. A sends another offer and waits more than 30 seconds; accepting cannot start a transfer.
6. B uses Recover current raid and receives the active raid from the current Master Looter.
7. Both clients `/reload`; no offer prompt/state survives, saved sync preferences remain, and Config contains preferences but no Push, Require, or Sync Now actions.

After the smoke passes, run `superpowers:finishing-a-development-branch` and integrate only the reviewed commits while preserving the two pre-existing README modifications in the main worktree.
