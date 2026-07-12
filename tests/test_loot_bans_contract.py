from __future__ import annotations

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
TOC = ADDON / "Raid Management Addon.toc"
SERVICE = ADDON / "Services" / "Raid" / "LootBans.lua"
EVENTS = ADDON / "Modules" / "Events.lua"


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


if __name__ == "__main__":
    unittest.main()
