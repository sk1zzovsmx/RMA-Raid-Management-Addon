from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

from tests.lua_test_runner import run_lua_case


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_LUA = ROOT / "Raid Management Addon" / "Services" / "Spammer" / "Runtime.lua"
CONTROLLER_LUA = ROOT / "Raid Management Addon" / "Controllers" / "Spammer.lua"
SPAMMER_XML = ROOT / "Raid Management Addon" / "UI" / "Spammer.xml"


class SpammerWarningsBehaviorTests(unittest.TestCase):
    def test_spammer_channel_selector_has_readable_label_width(self) -> None:
        root = ET.parse(SPAMMER_XML).getroot()
        label = None
        for node in root.iter():
            if node.tag.endswith("FontString") and node.attrib.get("name") == "$parentChannelsStr":
                label = next(
                    (child for child in node.iter() if child.tag.endswith("AbsDimension")),
                    None,
                )
                break
        self.assertIsNotNone(label)
        self.assertGreaterEqual(int(label.attrib["x"]), 70)

    def test_strings_utf8_safe_prefix(self) -> None:
        result = run_lua_case("strings_utf8_safe_prefix")
        self.assertIn("PASS strings_utf8_safe_prefix", result.stdout)

    def test_saved_variables_are_normalized_on_reload(self) -> None:
        result = run_lua_case("spammer_warnings_saved_variables_are_normalized")
        self.assertIn("PASS spammer_warnings_saved_variables_are_normalized", result.stdout)

    def test_spammer_runtime_is_bounded_and_atomic(self) -> None:
        result = run_lua_case("spammer_runtime_is_bounded_and_atomic")
        self.assertIn("PASS spammer_runtime_is_bounded_and_atomic", result.stdout)

    def test_spammer_runtime_contains_callback_exceptions_and_reasons(self) -> None:
        result = run_lua_case("spammer_runtime_contains_callback_exceptions_and_reasons")
        self.assertIn("PASS spammer_runtime_contains_callback_exceptions_and_reasons", result.stdout)

    def test_spammer_controller_reports_terminal_failures_once(self) -> None:
        result = run_lua_case("spammer_controller_reports_terminal_failures_once")
        self.assertIn("PASS spammer_controller_reports_terminal_failures_once", result.stdout)

    def test_spammer_controller_depends_directly_on_runtime_owner(self) -> None:
        runtime = RUNTIME_LUA.read_text(encoding="utf-8")
        controller = CONTROLLER_LUA.read_text(encoding="utf-8")
        self.assertNotIn("function Chat:GetSpamRuntimeState", runtime)
        self.assertNotIn("function Chat:StartSpamCycle", runtime)
        self.assertNotIn("function Chat:StopSpamCycle", runtime)
        self.assertNotIn("function Chat:PauseSpamCycle", runtime)
        self.assertIn('requireServiceMethod("Spammer.Runtime", RuntimeSvc, "GetState")', controller)
        self.assertNotIn('requireServiceMethod("Chat", Chat, "GetSpamRuntimeState")', controller)

    def test_headless_spammer_uses_saved_draft_through_runtime_owner(self) -> None:
        result = run_lua_case("headless_spammer_uses_saved_draft_through_runtime_owner")
        self.assertIn("PASS headless_spammer_uses_saved_draft_through_runtime_owner", result.stdout)

    def test_controller_request_start_uses_saved_draft_without_frame(self) -> None:
        result = run_lua_case("controller_request_start_uses_saved_draft_without_frame")
        self.assertIn("PASS controller_request_start_uses_saved_draft_without_frame", result.stdout)

    def test_spammer_clear_invalidates_ui_without_mutating_active_snapshot(self) -> None:
        result = run_lua_case("spammer_clear_invalidates_ui_without_mutating_active_snapshot")
        self.assertIn("PASS spammer_clear_invalidates_ui_without_mutating_active_snapshot", result.stdout)

    def test_spammer_frame_binding_applies_uncached_clear_state(self) -> None:
        result = run_lua_case("spammer_frame_binding_applies_uncached_clear_state")
        self.assertIn("PASS spammer_frame_binding_applies_uncached_clear_state", result.stdout)

    def test_spammer_channel_menu_normalizes_unavailable_saved_choices(self) -> None:
        result = run_lua_case("spammer_channel_menu_normalizes_unavailable_saved_choices")
        self.assertIn("PASS spammer_channel_menu_normalizes_unavailable_saved_choices", result.stdout)

    def test_chat_delivery_uses_live_destinations_and_reports_failures(self) -> None:
        result = run_lua_case("chat_delivery_uses_live_destinations_and_reports_failures")
        self.assertIn("PASS chat_delivery_uses_live_destinations_and_reports_failures", result.stdout)

    def test_warning_controller_reports_terminal_announcement_outcomes(self) -> None:
        result = run_lua_case("warning_controller_reports_terminal_announcement_outcomes")
        self.assertIn("PASS warning_controller_reports_terminal_announcement_outcomes", result.stdout)


if __name__ == "__main__":
    unittest.main()
