import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
CONTRACT = ROOT / "docs" / "API_SURFACE.md"

SUPPORTED_RMA_ROOT = {"name"}

KNOWN_INTERNAL_ROOT = {
    "ADDON_LOADED", "After", "Base64", "BossIDs", "Bus", "C", "CHAT_MSG_ADDON",
    "CHAT_MSG_LOOT", "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_SYSTEM",
    "COMBAT_LOG_EVENT_UNFILTERED", "CancelTimer", "Colors", "Comms", "Compat",
    "Controllers", "DB", "DBSchema", "Database", "Debugger", "Deformat",
    "Diag", "Diagnose", "EntryPoints", "Events", "IgnoredItems", "IgnoredMobs",
    "IsInGroup", "IsInRaid", "Item", "Json", "L", "LootSourceCandidates",
    "LootSources", "LootSourcesData", "Minimap", "NewTicker", "NewTimer", "Options",
    "PLAYER_DIFFICULTY_CHANGED", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "Print",
    "RAID_INSTANCE_WELCOME", "RAID_ROSTER_UPDATE", "RegisterEvent", "START_LOOT_ROLL",
    "Services", "Sort", "State", "Strings", "Time", "Timer", "UI",
    "UPDATE_INSTANCE_INFO", "UnregisterEvent", "Widgets", "ZONE_CHANGED_NEW_AREA",
    "_PerfFinish", "_PerfGetStats", "_PerfResetStats", "_PerfStart", "hasPerf", "options",
}


def discover_exports_from_source(source):
    names = set(re.findall(r"(?m)^\s*addon\.([A-Za-z_][A-Za-z0-9_]*)\s*=", source))
    names.update(re.findall(r"(?m)^\s*function\s+addon[:.]([A-Za-z_][A-Za-z0-9_]*)\s*\(", source))
    names.update(re.findall(r'''(?m)^\s*addon\[["']([A-Za-z_][A-Za-z0-9_]*)["']\]\s*=''', source))
    names.update(re.findall(r'''(?m)^\s*rawset\(\s*addon\s*,\s*["']([A-Za-z_][A-Za-z0-9_]*)["']''', source))
    return names


def discover_root_exports():
    names = set()
    for path in ADDON.rglob("*.lua"):
        if "Libs" in path.parts:
            continue
        source = path.read_text(encoding="utf-8")
        names.update(discover_exports_from_source(source))
    return names


class PublicApiSurfaceTest(unittest.TestCase):
    def test_export_discovery_covers_literal_root_assignment_shapes(self):
        source = '''
            addon.Dot = value
            addon["Bracket"] = value
            addon['SingleQuoted'] = value
            rawset(addon, "Raw", value)
            function addon:Method() end
        '''
        self.assertEqual(
            {"Dot", "Bracket", "SingleQuoted", "Raw", "Method"},
            discover_exports_from_source(source),
        )

    def test_root_exports_are_classified_without_freezing_removals(self):
        discovered = discover_root_exports()
        unknown = discovered - SUPPORTED_RMA_ROOT - KNOWN_INTERNAL_ROOT
        self.assertEqual(set(), unknown, f"unclassified _G.RMA root exports: {sorted(unknown)}")

    def test_global_identity_and_supported_surface_are_documented(self):
        contract = CONTRACT.read_text(encoding="utf-8")
        self.assertIn("`_G.RMA`", contract)
        self.assertIn("`RMA.name`", contract)
        self.assertIn("No callable method", contract)
        init = (ADDON / "Init.lua").read_text(encoding="utf-8")
        self.assertEqual(1, init.count('_G["RMA"] = addon'))


if __name__ == "__main__":
    unittest.main()
