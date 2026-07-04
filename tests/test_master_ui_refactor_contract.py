import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "Raid Management Addon" / "Controllers" / "Master.lua"
MASTER_XML = ROOT / "Raid Management Addon" / "UI" / "Master.xml"


def read(path):
    return path.read_text(encoding="utf-8")


class MasterUiRefactorContractTest(unittest.TestCase):
    def test_master_refactor_keeps_xml_layout_only(self):
        xml = read(MASTER_XML)
        self.assertNotIn("<Scripts>", xml)
        self.assertIsNone(re.search(r"<On[A-Za-z]+>", xml))

    def test_master_uses_cached_named_refs_for_button_refresh(self):
        source = read(MASTER)
        self.assertIn("local MASTER_REF_SUFFIXES", source)
        self.assertIn("local function acquireMasterRefs()", source)
        self.assertIn("module._refs", source)
        self.assertIn("refs.CountdownBtn", source)
        self.assertLess(source.count("getNamedPart("), 20)

    def test_master_update_helpers_are_not_recreated_inside_refresh_function(self):
        source = read(MASTER)
        body = source[source.index("local function updateMasterButtonsIfChanged") :]
        body = body[: body.index('updateTextState(texts, "countdown"')]
        self.assertNotIn("local function updateEnabled", body)
        self.assertNotIn("local function updateGlow", body)
        self.assertNotIn("local function updateTooltip", body)


if __name__ == "__main__":
    unittest.main()
