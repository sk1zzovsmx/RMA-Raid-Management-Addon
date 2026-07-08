import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
INIT = ADDON / "Init.lua"
RAID_STATE = ADDON / "Services" / "Raid" / "State.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class RaidSessionStateOwnershipTest(unittest.TestCase):
    def test_current_raid_session_state_accessors_are_owned_by_raid_state_service(self):
        init = read(INIT)
        raid_state = read(RAID_STATE)
        for method in (
            "GetCurrentRaid",
            "SetCurrentRaid",
            "GetLastBoss",
            "SetLastBoss",
            "GetNextReset",
            "SetNextReset",
        ):
            pattern = r"function\s+Database\." + method + r"\s*\("
            self.assertRegex(raid_state, pattern, method)
            self.assertNotRegex(init, pattern, method)

    def test_bootstrap_only_initializes_frame_state_not_raid_session_policy(self):
        init = read(INIT)
        self.assertIn("coreState.frames", init)
        self.assertNotIn("coreState.currentRaid =", init)
        self.assertNotIn("coreState.lastBoss =", init)
        self.assertNotIn("coreState.nextReset =", init)


if __name__ == "__main__":
    unittest.main()
