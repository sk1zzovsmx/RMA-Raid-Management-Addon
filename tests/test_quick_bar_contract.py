from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "Raid Management Addon"
TOC = ADDON / "Raid Management Addon.toc"
CONTROLLER = ADDON / "Controllers" / "QuickBar.lua"
XML = ADDON / "UI" / "QuickBar.xml"
MINIMAP = ADDON / "EntryPoints" / "Minimap.lua"


class QuickBarContractTest(unittest.TestCase):
    def test_toc_loads_controller_before_minimap_and_xml_layout(self) -> None:
        toc = TOC.read_text(encoding="utf-8")
        self.assertLess(toc.index(r"Controllers\QuickBar.lua"), toc.index(r"EntryPoints\Minimap.lua"))
        self.assertIn(r"UI\QuickBar.xml", toc)

    def test_xml_declares_static_separators_and_loot_glows(self) -> None:
        source = XML.read_text(encoding="utf-8")
        self.assertNotRegex(source, r"<Scripts>|<On[A-Za-z]+>")
        for suffix in ("Separator1", "Separator2", "Separator3"):
            self.assertIn(f'name="$parent{suffix}"', source)
        for suffix in ("ML", "GL"):
            button = re.search(
                rf'<Button name="\$parent{suffix}".*?</Button>',
                source,
                re.DOTALL,
            )
            self.assertIsNotNone(button)
            self.assertRegex(
                button.group(),
                r'<Layers>\s*<Layer level="OVERLAY">\s*<Texture name="\$parentGlow"',
            )

    def test_controller_persists_only_approved_quick_bar_values(self) -> None:
        source = CONTROLLER.read_text(encoding="utf-8")
        expected = {
            "quickBar": "false",
            "quickBarX": "0",
            "quickBarY": "-180",
            "quickBarOrientation": '"horizontal"',
            "quickBarShowML": "true",
            "quickBarShowGL": "true",
            "quickBarShowSR": "true",
            "quickBarShowHIS": "true",
            "quickBarShowRW": "true",
        }
        for key, value in expected.items():
            self.assertRegex(source, rf"{key}\s*=\s*{re.escape(value)}")
        self.assertEqual(9, len(re.findall(r"^\s*quickBar[A-Za-z]*\s*=", source, re.MULTILINE)))
        self.assertIn('frame:SetPoint("CENTER", UIParent, "CENTER", x, y)', source)

    def test_minimap_resolves_quick_bar_lazily(self) -> None:
        source = MINIMAP.read_text(encoding="utf-8")
        self.assertIn("Controllers.QuickBar", source)
        self.assertNotIn("assert(Controllers.QuickBar", source)

    def test_quick_bar_is_final_minimap_menu_action(self) -> None:
        source = MINIMAP.read_text(encoding="utf-8")
        self.assertGreater(source.rindex("L.StrQuickBar"), source.rindex("L.StrClearIcons"))
