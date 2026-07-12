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

    def test_award_sequence_has_final_ban_guard(self) -> None:
        source = AWARD_SEQUENCE.read_text(encoding="utf-8")
        assign = source[source.index("function controller:TrySingleCopy") :]
        self.assertRegex(assign, r"LootBans\.IsActive\(selectedWinner\)")
        self.assertLess(assign.index("LootBans.IsActive"), assign.index("awardExecutor:Assign"))


if __name__ == "__main__":
    unittest.main()
