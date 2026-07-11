import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
SERVICES = ADDON / "Services"
FEATURE_API_MAP = ROOT / "docs" / "FEATURE_API_MAP.md"


def read(path):
    return path.read_text(encoding="utf-8")


class FeatureBoundaryGuardrailsTest(unittest.TestCase):
    def test_services_do_not_reference_controller_or_widget_namespaces(self):
        forbidden = ("Controllers.", "Widgets.", "feature.Controllers", "feature.Widgets")

        for path in SERVICES.rglob("*.lua"):
            source = read(path)
            with self.subTest(path=path.relative_to(ADDON).as_posix()):
                for token in forbidden:
                    self.assertNotIn(token, source)

    def test_feature_api_map_preserves_interaction_and_compatibility_rules(self):
        content = read(FEATURE_API_MAP)

        for heading in ("## Master Loot", "## Reserves", "## Database Synchronization", "## Refactor Gate"):
            with self.subTest(heading=heading):
                self.assertIn(heading, content)

        self.assertIn("Commands and queries use direct calls to the owner", content)
        self.assertIn("Notifications use `addon.Bus`", content)
        self.assertIn("`RMA_*` SavedVariables and addon-message payloads", content)

    def test_feature_api_map_catalogs_runtime_addon_message_prefixes(self):
        content = read(FEATURE_API_MAP)

        for prefix in ("RMAVersion", "RMAResSync", "RMADist", "RMALogSync", "RMA-RollWinner"):
            with self.subTest(prefix=prefix):
                self.assertIn(f"`{prefix}`", content)


if __name__ == "__main__":
    unittest.main()
