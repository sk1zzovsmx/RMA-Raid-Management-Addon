import re
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

    def test_contract_defines_one_way_ui_request_semantics(self):
        content = read(BOUNDARIES)
        self.assertIn("### UI Requests", content)
        self.assertIn("UI requests do not return a value.", content)
        self.assertIn("Commands and queries do not pass through addon.Bus.", content)
        self.assertIn(
            "addon.Bus may carry UI requests only as imperative one-way notifications.",
            content,
        )

    def test_module_registry_remains_diagnostic_only(self):
        source = read(REGISTRY)
        public_methods = set()
        for pattern in (
            r"\bfunction\s+ModuleRegistry\.([A-Za-z_]\w*)\s*\(",
            r"\bfunction\s+ModuleRegistry:([A-Za-z_]\w*)\s*\(",
            r"\bModuleRegistry\.([A-Za-z_]\w*)\s*=\s*function\b",
        ):
            public_methods.update(re.findall(pattern, source))

        self.assertEqual(
            {
                "AddModule",
                "SetLoaded",
                "GetStatus",
                "GetModules",
                "GetLoadOrderStatus",
            },
            public_methods,
        )

    def test_architecture_document_links_the_boundary_contract(self):
        self.assertIn("FEATURE_BOUNDARIES.md", read(ARCHITECTURE))
