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
DBSYNCER_LUA = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"
DIAGNOSE_LOG_LUA = ROOT / "Raid Management Addon" / "Localization" / "DiagnoseLog.en.lua"
LOCALIZATION_LUA = ROOT / "Raid Management Addon" / "Localization" / "localization.en.lua"
EXPECTED_ORDERED_NAMES_SHA256 = (
    "ce25782a47e22d0874c1e46a6e6f9ecb2bed99d5f47e10feddd6ef6f71f710e9"
)
REQUIRED_PUBLIC_FRAMES = {
    "RMAConfig",
    "RMAInterfaceOptionsPanel",
    "RMAInterfaceOptionsMasterLootPanel",
    "RMAInterfaceOptionsMasterLootPanelScrollChild",
    "RMAInterfaceOptionsQuickBarPanel",
    "RMAInterfaceOptionsQuickBarPanelScrollChild",
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
        self.assertEqual(242, len(names))
        self.assertEqual(EXPECTED_ORDERED_NAMES_SHA256, digest)

    def test_required_public_frames_remain_declared(self) -> None:
        names = set(re.findall(r'\bname="([^"]+)"', source()))
        self.assertTrue(REQUIRED_PUBLIC_FRAMES.issubset(names))

    def test_xml_remains_layout_only(self) -> None:
        xml = source()
        self.assertNotRegex(xml, r"<Scripts>|<On[A-Za-z]+>")

    def test_quick_bar_panel_is_layout_only_and_exposes_settings(self) -> None:
        xml = source()
        self.assertIn('name="RMAInterfaceOptionsQuickBarPanel"', xml)
        self.assertNotRegex(xml, r"<Scripts>|<On[A-Za-z]+>")
        for suffix in ("OrientationDropDown", "ShowML", "ShowGL", "ShowSR", "ShowHIS", "ShowRW"):
            self.assertIn(suffix, xml)

    def test_repeated_geometry_is_reduced(self) -> None:
        xml = source()
        self.assertLessEqual(len(re.findall(r"<Anchor\b", xml)), 80)
        self.assertLessEqual(len(re.findall(r"<Size\b", xml)), 40)


class ConfigLayoutOwnershipTest(unittest.TestCase):

    def test_help_lists_only_current_loot_history_and_perf_commands(self) -> None:
        localization = LOCALIZATION_LUA.read_text(encoding="utf-8")
        self.assertIn("/rma logger [share]", localization)
        for retired in (
            "/rma history " + "req",
            "/rma history " + "push",
            "/rma history " + "sync",
            "audit|" + "sync|items",
        ):
            self.assertNotIn(retired, localization)

    def test_logger_preferences_keep_only_current_recording_defaults(self) -> None:
        source = DBSYNCER_LUA.read_text(encoding="utf-8")
        start = source.index('Options.RegisterNamespace("Logger", {')
        end = source.index("\n\t})", start)
        defaults = source[start:end]
        self.assertIn("ignoreGroupLoot = false,", defaults)
        self.assertIn("ignoreSelectionThreshold = true,", defaults)
        self.assertIn("loggerLootQualityThreshold = 4,", defaults)

    def test_retired_config_sync_diagnostic_is_removed(self) -> None:
        source = DIAGNOSE_LOG_LUA.read_text(encoding="utf-8")
        self.assertNotIn("LogSyncConfigAction", source)

    def test_logger_panel_keeps_recording_preferences_only(self) -> None:
        xml = source()
        controller = CONTROLLER_LUA.read_text(encoding="utf-8")
        for retired in (
            "Persistent" + "SyncCheck",
            "RequireDatabaseEditBox",
            "RequireDatabaseBtn",
            "PushDatabaseEditBox",
            "PushDatabaseBtn",
            "SyncNowBtn",
        ):
            self.assertNotIn(retired, xml)
            self.assertNotIn(retired, controller)
        self.assertNotIn("RequestLogger" + "SyncPanelAction", controller)

    def test_cleanup_success_ui_is_gated_by_completed_callback(self) -> None:
        source = CONTROLLER_LUA.read_text(encoding="utf-8")
        callback = source[source.index("return actions:StartRaidHistoryCleanup(function(cleanupResult") :]
        callback = callback[: callback.index("end, options)")]
        self.assertIn("if complete ~= true", callback)
        self.assertIn("return", callback)

    def test_spammer_clear_delegates_to_controller_owner(self) -> None:
        lua = CONTROLLER_LUA.read_text(encoding="utf-8")
        clear_branch = lua[lua.index('elseif actionName == "clear" then') :]
        clear_branch = clear_branch[: clear_branch.index("\n\t\telse")]
        self.assertIn("SpammerController:RequestClearDraft()", clear_branch)
        self.assertNotIn("SpammerDraft.ClearDraft", clear_branch)
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
