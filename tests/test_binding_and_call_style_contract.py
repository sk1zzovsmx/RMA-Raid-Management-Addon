import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
MASTER = ADDON / "Controllers" / "Master.lua"
RAID_SESSION = ADDON / "Services" / "Raid" / "Session.lua"


class BindingAndCallStyleContractTest(unittest.TestCase):
    def test_master_loot_mutation_is_an_asserted_owner_binding(self):
        source = MASTER.read_text(encoding="utf-8")
        self.assertIn(
            'local GiveMasterLoot = assert(_G.GiveMasterLoot, "Master controller loot assignment API is not initialized")',
            source,
        )
        self.assertEqual(1, source.count("GiveMasterLoot(itemIndex, candidateIndex)"))

    def test_raid_icon_mutation_is_an_asserted_owner_binding(self):
        source = RAID_SESSION.read_text(encoding="utf-8")
        self.assertIn(
            'local SetRaidTarget = assert(_G.SetRaidTarget, "Raid session target icon API is not initialized")',
            source,
        )
        self.assertEqual(1, source.count('SetRaidTarget("raid" .. tostring(i), 0)'))

    def test_unbound_colon_methods_keep_explicit_self_at_call_sites(self):
        source = MASTER.read_text(encoding="utf-8")
        self.assertIsNone(re.search(r"\bRaidApi:[A-Za-z_][A-Za-z0-9_]*\(", source))
        for method in (
            "CanResolveMasterLootCandidates",
            "CanUseCapability",
            "EnsureMasterOnlyAccess",
            "FindMasterLootCandidateIndex",
            "GetRosterVersion",
            "RequestMasterLootCandidateRefresh",
        ):
            self.assertIn(f"RaidApi.{method}(Raid", source)


if __name__ == "__main__":
    unittest.main()
