from __future__ import annotations

from collections import defaultdict
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
TOC = ADDON / "Raid Management Addon.toc"
LOOT_SOURCE_DIR = ADDON / "Modules" / "Dataset" / "LootSources"
LOOT_SOURCE_DATA = ADDON / "Modules" / "Dataset" / "LootSourcesData.lua"
MASTER_CONTROLLER = ADDON / "Controllers" / "Master.lua"
APPROVED_AWARD_SERVICE_FILES = {
    r"Services\Loot\LootAttribution.lua",
    r"Services\Master\AwardAttempt.lua",
    r"Services\Master\AwardSequence.lua",
    r"Services\Master\AwardConfirmation.lua",
}
RETIRED_AWARD_SERVICE_FILES = {
    r"Services\Loot\PendingAwards.lua",
    r"Services\Master\Award.lua",
    r"Services\Master\AwardTransaction.lua",
    r"Services\Master\PendingAwardExecution.lua",
}
APPROVED_AWARD_OWNERS = {
    "Services.Loot.LootAttribution",
    "Services.Master.AwardAttempt",
    "Services.Master.AwardSequence",
    "Services.Master.AwardConfirmation",
}
RETIRED_AWARD_OWNERS = {
    "Services.Loot.PendingAwards",
    "Services.Master.Award",
    "Services.Master.AwardTransaction",
    "Services.Master.PendingAwardExecution",
}


def toc_entries() -> list[str]:
    return [
        line.strip()
        for line in TOC.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def duplicate_raid_names() -> set[str]:
    occurrences: dict[str, list[str]] = defaultdict(list)
    for path in sorted(LOOT_SOURCE_DIR.glob("*.lua")):
        for line in path.read_text(encoding="utf-8").splitlines():
            match = re.match(r'^\t\tname = "([^"]+)",$', line)
            if match:
                key = " ".join(match.group(1).strip().lower().split())
                occurrences[key].append(path.name)
    return {name for name, files in occurrences.items() if len(files) > 1}


class RuntimeBootstrapContractTest(unittest.TestCase):
    def test_award_services_use_approved_domain_names(self) -> None:
        entries = set(toc_entries())
        self.assertTrue(APPROVED_AWARD_SERVICE_FILES <= entries)
        self.assertTrue(RETIRED_AWARD_SERVICE_FILES.isdisjoint(entries))

        runtime = "\n".join(
            path.read_text(encoding="utf-8")
            for path in sorted(ADDON.rglob("*.lua"))
            if "Libs" not in path.parts
        )
        for owner in APPROVED_AWARD_OWNERS:
            self.assertIsNotNone(re.search(rf"{re.escape(owner)}(?![A-Za-z])", runtime))
        for owner in RETIRED_AWARD_OWNERS:
            self.assertIsNone(re.search(rf"{re.escape(owner)}(?![A-Za-z])", runtime))

    def test_roster_loads_before_capabilities(self) -> None:
        entries = toc_entries()
        self.assertLess(
            entries.index(r"Services\Raid\Roster.lua"),
            entries.index(r"Services\Raid\Capabilities.lua"),
        )

    def test_cross_expansion_duplicates_use_later_dataset_precedence(self) -> None:
        self.assertEqual({"naxxramas", "onyxia's lair"}, duplicate_raid_names())
        source = LOOT_SOURCE_DATA.read_text(encoding="utf-8")
        self.assertNotIn("duplicate normalized loot-source raid name", source)
        self.assertIn("rawByInstance[raidKey] = raid", source)

    def test_master_loot_assignment_always_has_an_award_attempt(self) -> None:
        source = MASTER_CONTROLLER.read_text(encoding="utf-8")
        assign_item = source[source.index("\tfunction assignItem(") :]
        assign_item = assign_item[: assign_item.index("\n\tend\n", assign_item.index("GiveMasterLoot"))]

        self.assertRegex(assign_item, r"effect\s*=\s*effect\s*or\s*createAwardAttempt\(\{")


if __name__ == "__main__":
    unittest.main()
