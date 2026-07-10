import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
BOUNDARIES = ROOT / "docs" / "FEATURE_BOUNDARIES.md"
ARCHITECTURE = ROOT / "docs" / "ARCHITECTURE.md"
REGISTRY = ADDON / "Modules" / "ModuleRegistry.lua"


def read(path):
    return path.read_text(encoding="utf-8")


class VerticalSliceArchitectureTest(unittest.TestCase):
    def test_feature_boundary_contract_names_every_product_slice(self):
        content = read(BOUNDARIES)
        for heading in (
            "## Shared Kernel",
            "## Configuration",
            "## Raid",
            "## Master Loot",
            "## Logger And Attendance",
            "## Reserves",
            "## Warnings",
            "## Spammer",
        ):
            with self.subTest(heading=heading):
                self.assertIn(heading, content)

    def test_contract_defines_command_query_notification_semantics(self):
        content = read(BOUNDARIES)
        self.assertIn("### Commands", content)
        self.assertIn("### Queries", content)
        self.assertIn("### Notifications", content)
        self.assertIn("Commands and queries use direct owner calls.", content)
        self.assertIn("Notifications use addon.Bus after the state change succeeds.", content)

    def test_module_registry_remains_diagnostic_only(self):
        source = read(REGISTRY)
        for forbidden in (
            "function ModuleRegistry.Resolve",
            "function ModuleRegistry.Require",
            "function ModuleRegistry.Call",
            "function ModuleRegistry.Dispatch",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, source)

    def test_architecture_document_links_the_boundary_contract(self):
        self.assertIn("FEATURE_BOUNDARIES.md", read(ARCHITECTURE))
