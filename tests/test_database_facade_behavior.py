import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
DB_FILE = ADDON / "Database" / "DB.lua"
INIT = ADDON / "Init.lua"


def run_lua(script):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".lua", encoding="utf-8", delete=False) as handle:
        handle.write(script)
        script_path = Path(handle.name)
    try:
        subprocess.run(["lua.cmd", str(script_path)], check=True, cwd=ROOT)
    finally:
        script_path.unlink(missing_ok=True)


class DatabaseFacadeBehaviorTest(unittest.TestCase):
    def test_database_facade_resolves_concrete_owners_without_manager_layer(self):
        run_lua(textwrap.dedent(f"""
            local owners = {{
                RaidStore = {{}},
                RaidQueries = {{}},
                RaidMigrations = {{}},
                RaidValidator = {{}},
                Syncer = {{}},
            }}
            local addon = {{ Database = {{}}, DB = owners }}
            assert(loadfile([[{DB_FILE.as_posix()}]]))("RMA", addon)
            assert(addon.DBManager == nil)
            assert(addon.DB.SetManager == nil and addon.DB.GetManager == nil)
            assert(addon.Database.GetRaidStore() == owners.RaidStore)
            assert(addon.Database.GetRaidQueries() == owners.RaidQueries)
            assert(addon.Database.GetRaidMigrations() == owners.RaidMigrations)
            assert(addon.Database.GetRaidValidator() == owners.RaidValidator)
            assert(addon.Database.GetSyncer() == owners.Syncer)

            owners.Syncer = nil
            local ok, reason = pcall(addon.Database.GetSyncer)
            assert(ok == false)
            assert(string.find(tostring(reason), "Syncer is not initialized", 1, true))
        """))

    def test_init_has_no_database_manager_bootstrap(self):
        source = INIT.read_text(encoding="utf-8")
        self.assertNotIn("ensureDBManager", source)
        self.assertNotIn("addon.DBManager", source)


if __name__ == "__main__":
    unittest.main()
