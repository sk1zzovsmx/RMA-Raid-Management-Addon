from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
TOC = ADDON / "Raid Management Addon.toc"
SERVICE = ADDON / "Services" / "Raid" / "LootBans.lua"
EVENTS = ADDON / "Modules" / "Events.lua"
RESPONSES = ADDON / "Services" / "Rolls" / "Responses.lua"
ROLL_STRATEGIES = ADDON / "Services" / "Rolls" / "Strategies.lua"
ROLL_RESOLUTION = ADDON / "Services" / "Rolls" / "Resolution.lua"
AWARD_SEQUENCE = ADDON / "Services" / "Master" / "AwardSequence.lua"
TRADE_EXECUTION = ADDON / "Services" / "Master" / "TradeExecution.lua"
RAID_GRID = ADDON / "Widgets" / "RaidGrid.lua"
MASTER = ADDON / "Controllers" / "Master.lua"
ATTENDANCE = ADDON / "Controllers" / "Attendance.lua"
FRAMES = ADDON / "Modules" / "UI" / "Frames.lua"
MASTER_XML = ADDON / "UI" / "Master.xml"


def run_lua(assertions: str) -> None:
    lua = shutil.which("lua")
    if lua is None:
        raise AssertionError("Lua runtime is required for Loot Bans behavioral contracts")
    service_path = SERVICE.as_posix()
    script = f"""
local players = {{}}
local published = {{}}
local addon = {{
    Database = {{
        GetRealmName = function() return "TestRealm" end,
        SavedVariables = {{ GetPlayers = function() return players end }},
    }},
    Services = {{ Raid = {{}} }},
    Strings = {{}},
    Bus = {{}},
    Events = {{ Internal = {{ LootBansChanged = "LootBansChanged" }} }},
}}
function addon.Strings.TrimText(value, allowNil)
    if value == nil then return allowNil and nil or "" end
    return string.gsub(tostring(value), "^%s*(.-)%s*$", "%1")
end
function addon.Strings.NormalizeName(value, allowNil)
    local text = addon.Strings.TrimText(value, allowNil)
    if text == nil then return nil end
    text = string.lower(text)
    return string.gsub(text, "%a", string.upper, 1)
end
function addon.Bus.TriggerEvent(eventName, playerName, active, note)
    published[#published + 1] = {{ eventName, playerName, active, note }}
end
local chunk = assert(loadfile("{service_path}"))
local LootBans = chunk("Raid Management Addon", addon)
{assertions}
"""
    completed = subprocess.run(
        [lua, "-"],
        input=script,
        text=True,
        encoding="utf-8",
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError(completed.stderr or completed.stdout)


def run_award_sequence_lua(assertions: str) -> None:
    lua = shutil.which("lua")
    if lua is None:
        raise AssertionError("Lua runtime is required for award enforcement contracts")
    award_path = AWARD_SEQUENCE.as_posix()
    script = f"""
local bans = {{}}
local getCalls = {{}}
local isActiveCalls = 0
local warnings = {{}}
local effects = 0
local assigns = 0
local scheduled = nil
local lootCount = 1
local testWinners = {{}}
local lootBans = {{}}
function lootBans.Get(name)
    getCalls[#getCalls + 1] = name
    local ban = bans[name]
    if ban == true then return true, nil end
    return ban ~= nil, ban
end
function lootBans.IsActive(name)
    isActiveCalls = isActiveCalls + 1
    return bans[name] ~= nil
end
local loot = {{}}
function loot:GetLootWindowItemCountByKey() return lootCount end
local addon = {{
    Services = {{
        Master = {{}},
        Loot = loot,
        Raid = {{ LootBans = lootBans }},
    }},
    L = {{
        ErrMLWinnerLootBanned = "Cannot award: %s has an active Loot Ban.",
        ErrMLWinnerLootBannedWithNote = "Cannot award: %s has an active Loot Ban. Reason: %s",
        ErrNoWinnerSelected = "none",
        ChatAward = "%s %s",
        ChatAwardMutiple = "%s %s",
    }},
    Diag = {{
        D = {{ LogMLMultiAwardStarted = "%s %s %s %s %s" }},
        W = {{
            ErrMLMultiSelectNotEnough = "%s %s",
            ErrMLMultiAwardInterruptedTimeout = "%s %s %s %s %s",
        }},
    }},
}}
function addon.Services.EnsureNamespace(name)
    addon.Services[name] = addon.Services[name] or {{}}
    return addon.Services[name]
end
local AwardSequence = assert(loadfile("{award_path}"))("Raid Management Addon", addon)
local lootState = {{ currentRollType = 1, fromInventory = false }}
local awardExecutor = {{ effect = nil }}
function awardExecutor:Assign()
    assigns = assigns + 1
    return true
end
local awardPlanner = {{}}
function awardPlanner.BuildMultiAwardWinnersPlan()
    return {{ winners = testWinners }}
end
function awardPlanner.BuildMultiAwardState(args)
    return {{ state = {{
        active = true,
        itemLink = args.itemLink,
        itemKey = args.itemLink,
        lastCount = args.available,
        rollType = args.rollType,
        winners = args.winners,
        currentWinner = args.winners[1] and args.winners[1].name,
        pos = 2,
        total = #args.winners,
    }} }}
end
local rollSelection = {{}}
function rollSelection:GetSelectedCount() return #testWinners end
function rollSelection:BuildModel() return {{ rows = testWinners }} end
function rollSelection:GetSelectedWinnersOrdered() return testWinners end
function rollSelection:ClearAnchor() end
local itemCount = {{}}
function itemCount:Set() end
function itemCount:Reset() end
local controller = AwardSequence.CreateController({{
    awardPlanner = awardPlanner,
    inventory = {{ BuildMultiAwardSlotCandidates = function() return {{}}, {{}} end }},
    lootState = lootState,
    rollSelection = rollSelection,
    scheduleTimer = function(callback) scheduled = callback return callback end,
    cancelTimer = function() scheduled = nil end,
    warn = function(message) warnings[#warnings + 1] = message end,
    registerAwardedItem = function() end,
    awardExecutor = awardExecutor,
    itemCount = itemCount,
    multiAwardTimeoutSeconds = 0,
    multiAwardDelaySeconds = 0,
    createAttempt = function(args)
        effects = effects + 1
        return {{
            Confirm = function() return args.onConfirm() end,
            Fail = function(_, reason) return args.onFail(reason) end,
        }}
    end,
    getRollSessionId = function() return "session" end,
    getItemKey = function(itemLink) return itemLink end,
    getRaidNid = function() return 1 end,
}})
{assertions}
"""
    completed = subprocess.run(
        [lua, "-"],
        input=script,
        text=True,
        encoding="utf-8",
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError(completed.stderr or completed.stdout)


def run_roll_reprojection_lua(assertions: str) -> None:
    lua = shutil.which("lua")
    if lua is None:
        raise AssertionError("Lua runtime is required for roll reprojection contracts")
    paths = [ROLL_STRATEGIES.as_posix(), RESPONSES.as_posix(), ROLL_RESOLUTION.as_posix()]
    script = f"""
table.wipe = table.wipe or function(value) for key in pairs(value) do value[key] = nil end end
GetTime = function() return 1 end
local banned = false
local addon = {{
    C = {{ rollTypes = {{ MAINSPEC = 1, OFFSPEC = 2, RESERVED = 3, FREE = 4 }} }},
    L = {{ StrRollBlockedTag = "BLK", StrRollDuplicateTag = "DUP", StrRollTimedOutTag = "OOT",
        StrRollTieTag = "TIE", StrRollPassTag = "PASS", StrRollCancelledTag = "CANCEL" }},
    Diag = {{ D = {{}} }}, Comms = {{}}, Item = {{}},
    Database = {{ GetCurrentRaid = function() return 1 end }},
    Options = {{ GetValue = function() return false end, IsDebugEnabled = function() return false end }},
    Strings = {{ NormalizeName = function(name) return name end }},
    Services = {{ Chat = {{}}, Raid = {{
        LootBans = {{ IsActive = function(name) return banned and name == "Alice" end }},
        GetUnitID = function() return "raid1" end,
    }} }},
}}
function addon.Services.EnsureNamespace(name)
    addon.Services[name] = addon.Services[name] or {{}}
    return addon.Services[name]
end
for _, path in ipairs({{ "{paths[0]}", "{paths[1]}", "{paths[2]}" }}) do
    assert(loadfile(path))("Raid Management Addon", addon)
end
local Responses = addon.Services.Rolls._Responses
local Resolution = addon.Services.Rolls._Resolution
local state = {{ responsesByPlayer = {{
    Alice = {{ name = "Alice", status = Responses.STATUS.ROLL, bucket = "MS", reason = Responses.REASONS.ELIGIBLE,
        bestRoll = 100, usedRolls = 1, allowedRolls = 1, isEligible = true }},
    Bob = {{ name = "Bob", status = Responses.STATUS.ROLL, bucket = "MS", reason = Responses.REASONS.ELIGIBLE,
        bestRoll = 90, usedRolls = 1, allowedRolls = 1, isEligible = true }},
}}, manualExclusions = {{}}, deniedReasons = {{}} }}
local ctx = {{ state = state, responseStatus = Responses.STATUS, reasonCodes = Responses.REASONS,
    getRollTypeBucket = function() return "MS" end, acquireItemTracker = function() return {{ Alice = 1, Bob = 1 }} end,
    getRaidService = function() return addon.Services.Raid end, getExpectedWinnerCount = function() return 1 end,
    isSelectableRollResponse = Responses.IsSelectableRollResponse,
}}
local function resolve()
    local entries, strategy = Resolution.BuildResolvedEntries(ctx, 1, 1)
    return Resolution.BuildResolution(ctx, entries, strategy)
end
{assertions}
"""
    completed = subprocess.run([lua, "-"], input=script, text=True, encoding="utf-8", capture_output=True)
    if completed.returncode != 0:
        raise AssertionError(completed.stderr or completed.stdout)


def run_trade_execution_lua(assertions: str) -> None:
    lua = shutil.which("lua")
    if lua is None:
        raise AssertionError("Lua runtime is required for trade enforcement contracts")
    trade_path = TRADE_EXECUTION.as_posix()
    script = f"""
local bans, warnings = {{}}, {{}}
local effects, trades = 0, 0
local lootBans = {{}}
function lootBans.Get(name)
    local note = bans[name]
    if note == true then return true, nil end
    return note ~= nil, note
end
local addon = {{
    Services = {{ Raid = {{ LootBans = lootBans }} }},
    C = {{ RAID_TARGET_MARKERS = {{}}, rollTypes = {{ MAINSPEC = 1, OFFSPEC = 2, RESERVED = 3, FREE = 4 }} }},
    L = {{
        ErrMLWinnerLootBanned = "Cannot award: %s has an active Loot Ban.",
        ErrMLWinnerLootBannedWithNote = "Cannot award: %s has an active Loot Ban. Reason: %s",
        ErrNoWinnerSelected = "none", ErrMLWinnerIneligible = "%s ineligible",
        ErrMLInventoryItemMissing = "%s missing", ErrItemStack = "%s stack",
        ChatTrade = "%s %s", ErrScreenReminder = "screen",
    }},
    Diag = {{ D = {{}}, W = {{}}, E = {{}} }},
}}
function addon.Services.EnsureNamespace(name)
    addon.Services[name] = addon.Services[name] or {{}}
    return addon.Services[name]
end
local TradeExecution = assert(loadfile("{trade_path}"))("Raid Management Addon", addon)
local lootState = {{ fromInventory = true, selectedItemCount = 2, currentRollItem = 1 }}
local itemInfo = {{}}
local controller = TradeExecution.CreateController({{
    lootBans = lootBans,
    trade = {{ Reset = function() end }},
    inventory = {{
        ResolveTradeableInventoryItem = function() return {{ bag = 0, slot = 1, slotCount = 1, totalCount = 2 }} end,
        ResolveTradeAwardedCount = function() return 1 end,
        ResolveInventoryAwardedCount = function() return 1 end,
    }},
    awardPlanner = {{ BuildTradeNotificationPlan = function() return {{ keep = false }} end }},
    rollSelection = {{
        GetSelectedCount = function() return 1 end,
        GetSelectedWinnersOrdered = function() return {{ {{ name = "Alice", roll = 100 }} }} end,
        DeselectWinner = function() end,
    }},
    raid = {{
        GetUnitID = function() return "raid1" end, ClearRaidIcons = function() end,
        AddPlayerCountForRollType = function() end,
    }},
    loot = {{ GetItemLink = function() return "item:1" end, ClearLoot = function() end }},
    distribution = {{
        PublishRollEnd = function() end, AcquireSessionOwnership = function() return "token" end,
        ReleaseSessionOwnership = function() return true end,
    }},
    rolls = {{
        EnsureLootRollSession = function() end,
        ValidateWinner = function() return {{ ok = true }} end,
        GetRolls = function() return {{}} end,
    }},
    comms = {{ SendWhisper = function() end }},
    database = {{ GetPlayerName = function() return "Master" end, GetCurrentRaid = function() return 1 end }},
    item = {{ GetItemIdFromLink = function() return 1 end }},
    lootState = lootState, itemInfo = itemInfo,
    wow = {{
        ClearCursor = function() end, CursorHasItem = function() return true end,
        GetContainerItemInfo = function() return nil, 1 end,
        GetContainerItemLink = function() return "item:1" end,
        InitiateTrade = function() trades = trades + 1 end, PickupContainerItem = function() end,
        SetRaidTarget = function() end, CheckInteractDistance = function() return 1 end,
    }},
    getOption = function() return false end,
    buildRollSelectionModel = function() return {{ winner = "Alice", rows = {{ {{ name = "Alice", roll = 100 }} }} }} end,
    buildLootRollSessionOptions = function() return {{}} end,
    resetTradeState = function() end, hideTradeDropdowns = function() end,
    clearLootAndResetRecordedRolls = function() end, ensureTradeLootContext = function() return 1, false end,
    requestLoggerLootLog = function() return true end, registerAwardedItem = function() return false end,
    requestRefresh = function() end, announce = function() end,
    isAnnounced = function() return false end, setAnnounced = function() end,
    isScreenshotWarn = function() return false end, setScreenshotWarn = function() end,
    warn = function(message) warnings[#warnings + 1] = message end, error = function() end,
    createAttempt = function(args)
        effects = effects + 1
        return {{ Confirm = function() return args.onConfirm({{ executorContext = args.executorContext }}) end,
            Fail = function(_, reason) return args.onFail(reason) end }}
    end,
    getItemKey = function(link) return link end,
}})
{assertions}
"""
    completed = subprocess.run([lua, "-"], input=script, text=True, encoding="utf-8", capture_output=True)
    if completed.returncode != 0:
        raise AssertionError(completed.stderr or completed.stdout)


def run_frames_lua(assertions: str) -> None:
    lua = shutil.which("lua")
    if lua is None:
        raise AssertionError("Lua runtime is required for frame helper contracts")
    frames_path = FRAMES.as_posix()
    script = f"""
CreateFrame = function() return {{}} end
InCombatLockdown = function() return false end
local addon = {{
    C = {{}},
    State = {{}},
    Strings = {{ TrimText = function(value) return value end }},
    UI = {{}},
}}
assert(loadfile("{frames_path}"))("Raid Management Addon", addon)
{assertions}
"""
    completed = subprocess.run(
        [lua, "-"],
        input=script,
        text=True,
        encoding="utf-8",
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise AssertionError(completed.stderr or completed.stdout)


def toc_entries() -> list[str]:
    return [
        line.strip()
        for line in TOC.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


class LootBansDomainContractTest(unittest.TestCase):
    def test_owner_loads_after_roster_and_before_rolls(self) -> None:
        entries = toc_entries()
        owner = r"Services\Raid\LootBans.lua"
        self.assertIn(owner, entries)
        self.assertLess(entries.index(r"Services\Raid\Roster.lua"), entries.index(owner))
        self.assertLess(entries.index(owner), entries.index(r"Services\Rolls\Responses.lua"))

    def test_owner_is_the_only_runtime_writer(self) -> None:
        writers = []
        for path in ADDON.rglob("*.lua"):
            if "Libs" in path.parts:
                continue
            text = path.read_text(encoding="utf-8")
            if re.search(r"\.lootBan\s*=|\[\s*[\"']lootBan[\"']\s*\]\s*=", text):
                writers.append(path.relative_to(ADDON).as_posix())
        self.assertEqual(["Services/Raid/LootBans.lua"], writers)

    def test_change_event_is_declared(self) -> None:
        self.assertIn('Internal.LootBansChanged = "LootBansChanged"', EVENTS.read_text(encoding="utf-8"))

    def test_validate_note_accepts_absent_and_empty_values(self) -> None:
        run_lua("""
assert(LootBans.ValidateNote(nil) == nil)
assert(LootBans.ValidateNote("") == nil)
assert(LootBans.ValidateNote(" \t ") == nil)
""")

    def test_validate_note_enforces_ascii_and_length_without_truncation(self) -> None:
        run_lua(r"""
local exact = string.rep("a", 240)
local tooLong = string.rep("b", 241)
assert(LootBans.ValidateNote(exact) == exact)
local clean, lengthError = LootBans.ValidateNote(tooLong)
assert(clean == nil and lengthError == "note_too_long")
local nonAscii, asciiError = LootBans.ValidateNote("caf\195\169")
assert(nonAscii == nil and asciiError == "note_non_ascii")
""")

    def test_set_persists_canonical_shape_and_emits_normalized_payload(self) -> None:
        run_lua("""
assert(LootBans.Set(" aLiCe ", " reason ") == true)
local ban = players.TestRealm.Alice.lootBan
assert(ban.active == true and ban.note == "reason")
assert(LootBans.IsActive("alice") == true)
local active, note = LootBans.Get("ALICE")
assert(active == true and note == "reason")
assert(#published == 1)
assert(published[1][1] == "LootBansChanged")
assert(published[1][2] == "Alice")
assert(published[1][3] == true)
assert(published[1][4] == "reason")
""")

    def test_remove_deletes_persisted_ban_and_emits_inactive_payload(self) -> None:
        run_lua("""
assert(LootBans.Set("Alice", nil) == true)
assert(LootBans.Remove("alice") == true)
assert(players.TestRealm.Alice.lootBan == nil)
assert(LootBans.IsActive("Alice") == false)
assert(#published == 2)
assert(published[2][2] == "Alice")
assert(published[2][3] == false)
assert(published[2][4] == nil)
assert(LootBans.Remove("Alice") == false)
assert(#published == 2)
""")

    def test_invalid_persisted_records_are_inactive_without_mutation(self) -> None:
        run_lua(r"""
players.TestRealm = { Alice = {} }
local invalid = {
    { active = true, note = string.rep("x", 241) },
    { active = true, note = "caf\195\169" },
    { active = true, note = 42 },
    { active = "true", note = "reason" },
}
for i = 1, #invalid do
    players.TestRealm.Alice.lootBan = invalid[i]
    local active, note = LootBans.Get("Alice")
    assert(active == false and note == nil)
    assert(players.TestRealm.Alice.lootBan == invalid[i])
end
""")


class LootBansEnforcementContractTest(unittest.TestCase):
    def test_rolls_use_specific_loot_ban_reason(self) -> None:
        source = RESPONSES.read_text(encoding="utf-8")
        self.assertIn('LOOT_BAN = "loot_ban"', source)
        self.assertRegex(source, r"LootBans\.IsActive\([^)]*name[^)]*\)")
        self.assertIn("reasonCodes.LOOT_BAN", source)

    def test_existing_roll_reprojects_out_of_resolution_and_back(self) -> None:
        run_roll_reprojection_lua("""
local ordinary = resolve()
assert(ordinary.autoWinners[1].name == "Alice")
banned = true
local response = Responses.SyncResponseEligibility(ctx, "Alice", 1, "item:1", 1, "loot-ban-change")
assert(response.status == Responses.STATUS.INELIGIBLE)
assert(response.reason == Responses.REASONS.LOOT_BAN)
assert(response.bestRoll == 100)
assert(Resolution.BuildRowInfoText(ctx, response, false) == "BLK")
local blocked = resolve()
assert(blocked.autoWinners[1].name == "Bob")
assert(blocked.requiresManualResolution == false and #blocked.tiedNames == 0)
banned = false
response = Responses.SyncResponseEligibility(ctx, "Alice", 1, "item:1", 1, "loot-ban-change")
assert(response.status == Responses.STATUS.ROLL)
assert(response.reason == Responses.REASONS.ELIGIBLE)
local restored = resolve()
assert(restored.autoWinners[1].name == "Alice")
""")

    def test_banned_single_has_no_effect_or_assignment_and_propagates_reason(self) -> None:
        run_award_sequence_lua("""
bans.Alice = true
local ok, reason = controller:TrySingleCopy("item:1", "Alice")
assert(ok == nil and reason == "loot_ban")
assert(effects == 0 and assigns == 0)
assert(#getCalls == 1 and getCalls[1] == "Alice")
assert(isActiveCalls == 0)
assert(warnings[1] == "Cannot award: Alice has an active Loot Ban.")
""")

    def test_banned_single_warning_includes_note(self) -> None:
        run_award_sequence_lua("""
bans.Alice = "attendance"
local ok, reason = controller:TrySingleCopy("item:1", "Alice")
assert(ok == nil and reason == "loot_ban")
assert(warnings[1] == "Cannot award: Alice has an active Loot Ban. Reason: attendance")
""")

    def test_initial_multi_checks_all_winners_and_rechecks_first_before_effect(self) -> None:
        run_award_sequence_lua("""
local calls = 0
function lootBans.Get(name)
    calls = calls + 1
    getCalls[#getCalls + 1] = name
    if name == "Alice" and calls == 4 then return true, "late" end
    return false, nil
end
local winners = { { name = "Alice" }, { name = "Bob" }, { name = "Cara" } }
local ok, reason = controller:Start("item:1", 3, winners)
assert(ok == nil and reason == "loot_ban")
assert(#getCalls == 4)
assert(getCalls[1] == "Alice" and getCalls[2] == "Bob" and getCalls[3] == "Cara" and getCalls[4] == "Alice")
assert(effects == 0 and assigns == 0)
""")

    def test_multi_public_entry_propagates_loot_ban_reason(self) -> None:
        run_award_sequence_lua("""
testWinners = { { name = "Alice" }, { name = "Bob" } }
bans.Bob = true
local ok, reason = controller:TryMultipleCopies("item:1", 2, 2)
assert(ok == nil and reason == "loot_ban")
assert(effects == 0 and assigns == 0)
""")

    def test_winner_banned_during_delay_is_blocked_before_next_effect(self) -> None:
        run_award_sequence_lua("""
local winners = { { name = "Alice" }, { name = "Bob" } }
local ok = controller:Start("item:1", 2, winners)
assert(ok == true and effects == 1 and assigns == 1)
bans.Bob = "late ban"
lootCount = 1
assert(controller:ContinueOnLootSlotCleared(1) == true)
assert(type(scheduled) == "function")
scheduled()
assert(effects == 1 and assigns == 1)
assert(lootState.multiAward == nil)
assert(warnings[#warnings] == "Cannot award: Bob has an active Loot Ban. Reason: late ban")
""")

    def test_inventory_trade_rechecks_ban_before_effect_and_trade(self) -> None:
        run_trade_execution_lua("""
bans.Alice = "late ban"
assert(controller:TradeItem("item:1", "Alice", 1, 100) == false)
assert(effects == 0 and trades == 0)
assert(warnings[1] == "Cannot award: Alice has an active Loot Ban. Reason: late ban")
""")

    def test_successive_inventory_attempt_rechecks_new_ban(self) -> None:
        run_trade_execution_lua("""
assert(controller:TradeItem("item:1", "Alice", 1, 100) == true, "first trade result")
assert(effects == 1 and trades == 1, "first counts " .. effects .. "/" .. trades)
bans.Alice = true
assert(controller:TradeItem("item:1", "Alice", 1, 100) == false, "second trade result")
assert(effects == 1 and trades == 1, "second counts " .. effects .. "/" .. trades)
assert(warnings[#warnings] == "Cannot award: Alice has an active Loot Ban.", tostring(warnings[#warnings]))
""")


class LootBansUiContractTest(unittest.TestCase):
    def test_master_xml_remains_layout_only(self) -> None:
        xml = MASTER_XML.read_text(encoding="utf-8")
        self.assertNotRegex(xml, r"<Scripts>|<On[A-Za-z]+>")
        self.assertIn('name="$parentLootBansBtn"', xml)

    def test_raid_grid_accepts_projection_without_ban_policy(self) -> None:
        source = RAID_GRID.read_text(encoding="utf-8")
        self.assertIn("entry.textColor", source)
        self.assertIn("entry.tooltipLines", source)
        self.assertNotIn("LootBans", source)

    def test_master_owns_loot_ban_mode_and_editor(self) -> None:
        source = MASTER.read_text(encoding="utf-8")
        self.assertIn('mode = "lootBan"', source)
        self.assertIn('"RMA_LOOT_BAN_EDITOR"', source)
        self.assertIn("LootBans.Set", source)
        self.assertIn("LootBans.Remove", source)

    def test_loot_ban_editor_supplies_popup_format_argument(self) -> None:
        source = MASTER.read_text(encoding="utf-8")
        self.assertIn(
            'ShowPopup("RMA_LOOT_BAN_EDITOR", entry.name, nil, { name = entry.name })',
            source,
        )
        self.assertNotIn(
            'ShowPopup("RMA_LOOT_BAN_EDITOR", nil, nil, { name = entry.name })',
            source,
        )

    def test_loot_ban_change_requests_master_model_refresh(self) -> None:
        source = MASTER.read_text(encoding="utf-8")
        handler = re.search(
            r"RegisterCallback\(MasterEvents\.LootBansChanged, function\(\)(.*?)\n\s*end\)",
            source,
            re.S,
        )
        self.assertIsNotNone(handler)
        self.assertIn('requestCoalescedUiRefresh("loot-bans")', handler.group(1))


class LootBansAttendanceContractTest(unittest.TestCase):
    def test_script_binding_rejects_a_font_string_like_owner(self) -> None:
        run_frames_lua(
            """
local fontString = {}
assert(addon.UI.Frames.SetScriptSafely(fontString, "OnEnter", function() end) == false)
local button = { SetScript = function(self, scriptType, handler) self[scriptType] = handler end }
assert(addon.UI.Frames.SetScriptSafely(button, "OnEnter", function() end) == true)
assert(type(button.OnEnter) == "function")
"""
        )

    def test_attendance_uses_current_ban_projection(self) -> None:
        source = ATTENDANCE.read_text(encoding="utf-8")
        self.assertIn("LootBans.Get(it.name)", source)
        self.assertIn("AttendanceEvents.LootBansChanged", source)
        self.assertRegex(source, r"SetVertexColor\(0\.5,\s*0\.5,\s*0\.5\)")
        self.assertIn("StrLootBanTooltipTitle", source)

    def test_reused_attendance_rows_replace_loot_ban_tooltip_state(self) -> None:
        source = ATTENDANCE.read_text(encoding="utf-8")
        self.assertIn("hotspot._RMALootBanActive = lootBanned", source)
        self.assertIn("hotspot._RMALootBanNote = lootBanNote", source)
        self.assertIn("if self._RMALootBanActive then", source)
        self.assertIn("self._RMALootBanNote", source)

    def test_attendance_uses_a_script_bearing_name_hotspot(self) -> None:
        source = ATTENDANCE.read_text(encoding="utf-8")
        self.assertIn('CreateFrame("Button", nil, row)', source)
        self.assertIn("hotspot:SetAllPoints(ui.Name)", source)
        self.assertIn('SetScriptSafely(hotspot, "OnEnter"', source)
        self.assertIn('SetScriptSafely(hotspot, "OnLeave"', source)
        self.assertIn('SetScriptSafely(hotspot, "OnClick"', source)
        self.assertNotIn('SetScriptSafely(ui.Name, "OnEnter"', source)

    def test_attendance_hotspot_binding_and_click_forwarding_are_row_safe(self) -> None:
        source = ATTENDANCE.read_text(encoding="utf-8")
        self.assertRegex(
            source,
            r"hotspot\._RMALootBanTooltipBound\s*=\s*enterBound\s+and\s+leaveBound\s+and\s+clickBound",
        )
        self.assertIn("hotspot._RMARow = row", source)
        self.assertIn('self._RMARow:GetScript("OnClick")', source)
        self.assertIn("rowOnClick(self._RMARow, button)", source)


if __name__ == "__main__":
    unittest.main()
