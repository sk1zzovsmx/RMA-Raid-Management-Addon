import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"


class RollWinnerPrefixLifecycleTests(unittest.TestCase):
    def test_retired_roll_winner_prefix_has_no_runtime_references(self):
        runtime_suffixes = {".lua", ".xml", ".toc"}
        references = []

        for path in ADDON.rglob("*"):
            if path.is_file() and path.suffix.lower() in runtime_suffixes and "Libs" not in path.parts:
                if "RMA-RollWinner" in path.read_text(encoding="utf-8"):
                    references.append(str(path.relative_to(ROOT)))

        self.assertEqual([], references)

    def test_roll_selection_has_no_dead_winner_sync_callback(self):
        source = (ADDON / "Services" / "Master" / "RollSelection.lua").read_text(encoding="utf-8")

        self.assertNotIn("syncWinner", source)


if __name__ == "__main__":
    unittest.main()
