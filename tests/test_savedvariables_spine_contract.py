import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
TOC = ADDON / "Raid Management Addon.toc"
INIT = ADDON / "Init.lua"
SV = ADDON / "Database" / "SavedVariables.lua"
DB_OPTIONS = ADDON / "Database" / "DBOptions.lua"
DB_RAID_STORE = ADDON / "Database" / "DBRaidStore.lua"
DB = ADDON / "Database" / "DB.lua"
WARNINGS_STORE = ADDON / "Services" / "Warnings" / "Store.lua"
SPAMMER_DRAFT = ADDON / "Services" / "Spammer" / "Draft.lua"
RESERVES = ADDON / "Services" / "Reserves.lua"
RAID_ROSTER = ADDON / "Services" / "Raid" / "Roster.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class SavedVariablesSpineContractTest(unittest.TestCase):
    def test_canonical_raid_store_is_a_required_dependency(self):
        source = read(DB)
        self.assertIn("function Database.GetRaidStore()", source)
        self.assertIn("local raidStore = DB.RaidStore", source)
        self.assertNotIn('getManagerStore("GetRaidStore")', source)
        self.assertIn('assert(type(raidStore) == "table", "RMA RaidStore is not initialized")', source)
        self.assertNotIn("GetRaidStoreOrNil", source)

    def test_savedvariables_owner_exists_and_is_loaded_before_store_users(self):
        self.assertTrue(SV.exists(), "Database/SavedVariables.lua must own RMA_* store access")
        toc = read(TOC)
        self.assertIn("Database\\SavedVariables.lua", toc)
        self.assertLess(toc.index("Database\\SavedVariables.lua"), toc.index("Database\\DBOptions.lua"))
        self.assertLess(toc.index("Database\\SavedVariables.lua"), toc.index("Database\\DBRaidStore.lua"))

    def test_savedvariables_owner_exports_named_rma_store_accessors(self):
        source = read(SV)
        self.assertIn("addon.Database.SavedVariables", source)
        for method in (
            "EnsureAll",
            "NormalizeAfterLoad",
            "PrepareForSave",
            "GetRaids",
            "GetPlayers",
            "GetReserves",
            "ReplaceReserves",
            "ClearReserves",
            "GetWarnings",
            "GetSpammer",
            "GetOptions",
        ):
            self.assertRegex(source, r"function\s+SavedVariables\." + method + r"\s*\(")
        self.assertNotIn("function SavedVariables.WasWarningsFresh()", source)
        self.assertNotRegex(source, r"\bKRT_|Karazhan|KaraRaid|KRaid")

    def test_bootstrap_delegates_rma_savedvariable_initialization_to_owner(self):
        source = read(INIT)
        self.assertIn("SavedVariables.EnsureAll()", source)
        self.assertNotIn("RMA_Raids = RMA_Raids or {}", source)
        self.assertNotIn("RMA_Options = RMA_Options or {}", source)
        self.assertNotIn("RMA_Warnings = RMA_Warnings or {}", source)

    def test_load_and_logout_preparation_are_owned_by_savedvariables_boundary(self):
        init = read(INIT)
        source = read(SV)
        self.assertIn("SavedVariables.NormalizeAfterLoad()", init)
        self.assertIn('SavedVariables.PrepareForSave("logout")', init)
        self.assertNotIn("function Database.NormalizeSavedVariablesAfterLoad", init)
        self.assertNotIn("function Database.PrepareSavedVariablesForSave", init)
        self.assertIn("Database.GetRaidStore", source)
        self.assertIn("NormalizeAllRaids", source)
        self.assertIn("PrepareAllRaidsForSave", source)

    def test_savedvariables_lifecycle_uses_declared_owners_without_fallbacks(self):
        source = read(SV)
        normalize_fallback = source.split("function SavedVariables.NormalizeAfterLoad()", 1)[1]
        normalize_fallback = normalize_fallback.split("function SavedVariables.PrepareForSave", 1)[0]
        save_fallback = source.split("function SavedVariables.PrepareForSave", 1)[1]

        self.assertIn("local GetRaidStore = assert(", source)
        self.assertIn('"SavedVariables raid store resolver is not initialized"', source)
        self.assertIn("local function getReservesSave", source)
        self.assertIn('"SavedVariables reserves service is not initialized"', source)
        self.assertIn('"SavedVariables reserves save handler is not initialized"', source)
        self.assertIn("local raidStore = GetRaidStore()", normalize_fallback)
        self.assertIn("local raidStore = GetRaidStore()", save_fallback)
        self.assertIn('raidStore:NormalizeAllRaids("load")', normalize_fallback)
        self.assertIn("raidStore:PrepareAllRaidsForSave()", save_fallback)
        self.assertIn("local saveReserves, reservesService = getReservesSave()", save_fallback)
        self.assertIn('saveReserves(reservesService, contextTag or "save")', save_fallback)
        self.assertNotIn('type(Database.EnsureRaidSchema) == "function"', normalize_fallback)
        self.assertNotIn("Database.EnsureRaidSchema(raids[i])", normalize_fallback)
        self.assertNotIn('type(Database.StripRuntimeRaidCaches) == "function"', save_fallback)
        self.assertNotIn("Database.StripRuntimeRaidCaches(raids[i])", save_fallback)
        self.assertNotIn("StripAllRuntime", save_fallback)
        self.assertNotIn("Services and Services.Reserves", save_fallback)

    def test_store_users_go_through_savedvariables_owner(self):
        users = {
            "DBOptions.lua": read(DB_OPTIONS),
            "DBRaidStore.lua": read(DB_RAID_STORE),
            "Warnings/Store.lua": read(WARNINGS_STORE),
            "Spammer/Draft.lua": read(SPAMMER_DRAFT),
            "Reserves.lua": read(RESERVES),
            "Raid/Roster.lua": read(RAID_ROSTER),
        }
        for label, source in users.items():
            self.assertIn("SavedVariables", source, label)
            self.assertNotRegex(source, r"\b_G\.RMA_(Options|Warnings|Spammer)\b", label)
            self.assertNotRegex(source, r"\bRMA_(Raids|Players|Reserves)\b", label)

if __name__ == "__main__":
    unittest.main()
