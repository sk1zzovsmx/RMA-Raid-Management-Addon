from __future__ import annotations

import hashlib
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
CONFIG_XML = ROOT / "Raid Management Addon" / "UI" / "Config.xml"
LAYOUT_LUA = ROOT / "Raid Management Addon" / "Modules" / "UI" / "OptionsLayout.lua"
CONTROLLER_LUA = ROOT / "Raid Management Addon" / "Controllers" / "Config.lua"
EXPECTED_ORDERED_NAMES_SHA256 = (
    "53f86d9fa781ade75839a4d895840fd1013970add79c98a1bad9ef471fd8528d"
)
REQUIRED_PUBLIC_FRAMES = {
    "RMAConfig",
    "RMAInterfaceOptionsPanel",
    "RMAInterfaceOptionsMasterLootPanel",
    "RMAInterfaceOptionsMasterLootPanelScrollChild",
    "RMAInterfaceOptionsLootHistoryPanel",
    "RMAInterfaceOptionsLootHistoryPanelScrollChild",
    "RMAInterfaceOptionsLFMSpamPanel",
    "RMAInterfaceOptionsLFMSpamPanelScrollChild",
    "RMAInterfaceOptionsRaidWarningPanel",
    "RMAInterfaceOptionsRaidWarningPanelScrollChild",
    "RMAInterfaceOptionsHelpPanel",
    "RMAInterfaceOptionsHelpPanelScrollChild",
    "RMALootHistoryCleanupPopup",
}


def source() -> str:
    return CONFIG_XML.read_text(encoding="utf-8")


class ConfigXmlContractTest(unittest.TestCase):
    def test_xml_parses(self) -> None:
        ET.parse(CONFIG_XML)

    def test_ordered_name_contract_is_unchanged(self) -> None:
        names = re.findall(r'\bname="([^"]+)"', source())
        digest = hashlib.sha256("\n".join(names).encode("utf-8")).hexdigest()
        self.assertEqual(235, len(names))
        self.assertEqual(EXPECTED_ORDERED_NAMES_SHA256, digest)

    def test_required_public_frames_remain_declared(self) -> None:
        names = set(re.findall(r'\bname="([^"]+)"', source()))
        self.assertTrue(REQUIRED_PUBLIC_FRAMES.issubset(names))

    def test_xml_remains_layout_only(self) -> None:
        xml = source()
        self.assertNotRegex(xml, r"<Scripts>|<On[A-Za-z]+>")

    def test_repeated_geometry_is_reduced(self) -> None:
        xml = source()
        self.assertLessEqual(len(re.findall(r"<Anchor\b", xml)), 80)
        self.assertLessEqual(len(re.findall(r"<Size\b", xml)), 40)


class ConfigLayoutOwnershipTest(unittest.TestCase):

    def test_cleanup_success_ui_is_gated_by_completed_callback(self) -> None:
        source = CONTROLLER_LUA.read_text(encoding="utf-8")
        callback = source[source.index("return actions:StartRaidHistoryCleanup(function(cleanupResult") :]
        callback = callback[: callback.index("end, options)")]
        self.assertIn("if complete ~= true", callback)
        self.assertIn("return", callback)
    def test_layout_supports_explicit_justification(self) -> None:
        lua = LAYOUT_LUA.read_text(encoding="utf-8")
        self.assertIn('justifyH or "LEFT"', lua)
        self.assertIn('justifyV or "TOP"', lua)

    def test_layout_can_preserve_xml_owned_frame_size(self) -> None:
        lua = LAYOUT_LUA.read_text(encoding="utf-8")
        self.assertIn("if not (cfg and cfg.preserveFrameSize) then", lua)

    def test_cleanup_popup_selects_preserved_size_and_centered_title(self) -> None:
        lua = CONTROLLER_LUA.read_text(encoding="utf-8")
        self.assertRegex(
            lua,
            r'type = "title"[\s\S]{0,200}?suffix = "Title"[\s\S]{0,200}?justifyH = "CENTER"',
        )
        self.assertIn("preserveFrameSize = true", lua)


if __name__ == "__main__":
    unittest.main()
