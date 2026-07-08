import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
INIT = ADDON / "Init.lua"
DB_RAID_STORE = ADDON / "Database" / "DBRaidStore.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class RaidStoreApiOwnershipTest(unittest.TestCase):
    def test_raid_record_database_accessors_are_owned_by_raid_store(self):
        init = read(INIT)
        raid_store = read(DB_RAID_STORE)
        for method in (
            "EnsureRaidSchema",
            "EnsureRaidById",
            "EnsureRaidByNid",
            "GetRaidNidById",
            "GetRaidIdByNid",
            "StripRuntimeRaidCaches",
        ):
            pattern = r"function\s+Database\." + method + r"\s*\("
            self.assertRegex(raid_store, pattern, method)
            self.assertNotRegex(init, pattern, method)


if __name__ == "__main__":
    unittest.main()
