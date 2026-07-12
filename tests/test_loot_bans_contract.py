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
AWARD_SEQUENCE = ADDON / "Services" / "Master" / "AwardSequence.lua"


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


class LootBansEnforcementContractTest(unittest.TestCase):
    def test_rolls_use_specific_loot_ban_reason(self) -> None:
        source = RESPONSES.read_text(encoding="utf-8")
        self.assertIn('LOOT_BAN = "loot_ban"', source)
        self.assertRegex(source, r"LootBans\.IsActive\([^)]*name[^)]*\)")
        self.assertIn("reasonCodes.LOOT_BAN", source)

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


if __name__ == "__main__":
    unittest.main()
