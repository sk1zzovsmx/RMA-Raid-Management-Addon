from __future__ import annotations

import hashlib
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
CONFIG_XML = ROOT / "Raid Management Addon" / "UI" / "Config.xml"
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


if __name__ == "__main__":
    unittest.main()
