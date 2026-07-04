from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
INIT = ADDON / "Init.lua"
TOC = ADDON / "Raid Management Addon.toc"
SLASH = ADDON / "EntryPoints" / "SlashEvents.lua"
DB = ADDON / "Database" / "DB.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class InitCoreMicroCleanupContractTest(unittest.TestCase):
    def test_public_rma_identity_is_preserved(self):
        init = read(INIT)
        toc = read(TOC)
        slash = read(SLASH)
        self.assertIn("Raid Management Addon", toc)
        self.assertIn("## Interface: 30300", toc)
        self.assertIn("RMA_Raids", toc)
        self.assertIn("RMA_Options", toc)
        self.assertIn('SLASH_RMA1 = "/rma"', slash)
        self.assertIn("RMA_Raids = RMA_Raids or {}", init)
        self.assertIn("RMA_Options = RMA_Options or {}", init)

    def test_init_uses_lua51_safe_cached_gettime(self):
        src = read(INIT)
        self.assertIn("local GetTime = _G.GetTime", src)
        self.assertNotIn("_ENV", src)
        self.assertNotIn("table.unpack", src)
        self.assertNotIn("C_Timer", src)

    def test_addon_event_count_is_not_recomputed_in_debug_log(self):
        src = read(INIT)
        self.assertIn("ADDON_EVENTS_COUNT", src)
        self.assertNotIn("tLength(addonEvents)", src)

    def test_bootstrap_does_not_create_new_generic_utils_or_db_registration_helper(self):
        init = read(INIT)
        db = read(DB)
        self.assertNotIn("addon.Utils", init)
        self.assertNotIn("addon.Helpers", init)
        self.assertNotIn("function Database.RegisterModule", db)


if __name__ == "__main__":
    unittest.main()
