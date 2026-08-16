from __future__ import annotations

from pathlib import Path
import re
import unittest

from tests.lua_test_runner import run_lua_case


ROOT = Path(__file__).resolve().parents[1]
SLASH_EVENTS = ROOT / "Raid Management Addon" / "EntryPoints" / "SlashEvents.lua"
RAID_SESSION = ROOT / "Raid Management Addon" / "Services" / "Raid" / "Session.lua"
RAID_ROSTER = ROOT / "Raid Management Addon" / "Services" / "Raid" / "Roster.lua"
INIT = ROOT / "Raid Management Addon" / "Init.lua"


class RuntimeFoundationsBehaviorTest(unittest.TestCase):
    def test_screen_notice_uses_internal_event_without_direct_export(self) -> None:
        result = run_lua_case("screen_notice_uses_internal_event_without_direct_export")
        self.assertIn("PASS screen_notice_uses_internal_event_without_direct_export", result.stdout)

    def test_unknown_raid_retry_recovers_without_warning_spam(self) -> None:
        result = run_lua_case("unknown_raid_retry_recovers_without_warning_spam")
        self.assertIn("PASS unknown_raid_retry_recovers_without_warning_spam", result.stdout)

    def test_bounded_raid_retries_reenter_init_coordinator(self) -> None:
        init_source = INIT.read_text(encoding="utf-8")
        session_source = RAID_SESSION.read_text(encoding="utf-8")
        self.assertIn("ScheduleInstanceChecks(refreshRaidInstanceFromRetry)", init_source)
        self.assertIn("refreshInstance()", session_source)
        self.assertNotIn('SetScript("OnUpdate"', init_source)
        self.assertNotIn('SetScript("OnUpdate"', session_source)

    def test_raid_session_uses_transient_canonical_identity(self) -> None:
        result = run_lua_case("raid_session_uses_transient_canonical_identity")
        self.assertIn("PASS raid_session_uses_transient_canonical_identity", result.stdout)

    def test_raid_roster_rejects_stale_instance_context(self) -> None:
        result = run_lua_case("raid_roster_rejects_stale_instance_context")
        self.assertIn("PASS raid_roster_rejects_stale_instance_context", result.stdout)

    def test_session_and_roster_have_no_independent_instance_recognition(self) -> None:
        session_source = RAID_SESSION.read_text(encoding="utf-8")
        roster_source = RAID_ROSTER.read_text(encoding="utf-8")
        self.assertNotIn("RaidZones", session_source)
        self.assertNotIn("RaidZones", roster_source)
        self.assertNotIn("GetInstanceInfo", roster_source)
        self.assertNotIn("ResolveInstanceKey", roster_source)

    def test_minimap_remains_available_without_quick_bar(self) -> None:
        result = run_lua_case("rma_minimap_remains_available_without_quick_bar")
        self.assertIn("PASS rma_minimap_remains_available_without_quick_bar", result.stdout)

    def test_quick_bar_slash_routes_show_hide_and_help(self) -> None:
        result = run_lua_case("rma_quick_bar_slash_routes_show_hide_and_help")
        self.assertIn("PASS rma_quick_bar_slash_routes_show_hide_and_help", result.stdout)

    def test_quick_bar_routes_actions_and_persists_position(self) -> None:
        result = run_lua_case("rma_quick_bar_routes_actions_and_persists_position")
        self.assertIn("PASS rma_quick_bar_routes_actions_and_persists_position", result.stdout)

    def test_quick_bar_configures_layout_and_glow(self) -> None:
        result = run_lua_case("rma_quick_bar_configures_layout_and_glow")
        self.assertIn("PASS rma_quick_bar_configures_layout_and_glow", result.stdout)

    def test_quick_bar_config_panel_routes_settings(self) -> None:
        result = run_lua_case("rma_quick_bar_config_panel_routes_settings")
        self.assertIn("PASS rma_quick_bar_config_panel_routes_settings", result.stdout)

    def test_harness_executes_lua_51(self) -> None:
        result = run_lua_case("lua_51_smoke")

        self.assertIn("PASS lua_51_smoke", result.stdout)

    def test_group_helpers_preserve_wotlk_roster_semantics(self) -> None:
        result = run_lua_case("rma_group_helpers_preserve_wotlk_roster_semantics")
        self.assertIn("PASS rma_group_helpers_preserve_wotlk_roster_semantics", result.stdout)

    def test_manual_loot_method_enforces_authority(self) -> None:
        result = run_lua_case("rma_manual_loot_method_enforces_authority")
        self.assertIn("PASS rma_manual_loot_method_enforces_authority", result.stdout)

    def test_colors_own_class_and_markup_helpers(self) -> None:
        result = run_lua_case("rma_colors_own_class_and_markup_helpers")
        self.assertIn("PASS rma_colors_own_class_and_markup_helpers", result.stdout)

    def test_timer_runs_without_libcompat(self) -> None:
        result = run_lua_case("rma_timer_runs_without_libcompat")
        self.assertIn("PASS rma_timer_runs_without_libcompat", result.stdout)

    def test_print_preserves_chat_output_contract(self) -> None:
        result = run_lua_case("rma_print_preserves_chat_output_contract")
        self.assertIn("PASS rma_print_preserves_chat_output_contract", result.stdout)

    def test_logger_preserves_levels_flags_and_output_contract(self) -> None:
        result = run_lua_case("rma_logger_preserves_levels_flags_and_output_contract")
        self.assertIn("PASS rma_logger_preserves_levels_flags_and_output_contract", result.stdout)

    def test_bootstrap_retries_after_failure(self) -> None:
        result = run_lua_case("bootstrap_retries_after_failure")

        self.assertIn("PASS bootstrap_retries_after_failure", result.stdout)

    def test_bootstrap_raid_archive_quarantine_is_degraded_and_recovers(self) -> None:
        result = run_lua_case("bootstrap_raid_archive_quarantine_is_degraded_and_recovers")

        self.assertIn("PASS bootstrap_raid_archive_quarantine_is_degraded_and_recovers", result.stdout)

    def test_bootstrap_success_commits_before_roster_refresh(self) -> None:
        result = run_lua_case("bootstrap_success_commits_before_roster_refresh")

        self.assertIn("PASS bootstrap_success_commits_before_roster_refresh", result.stdout)

    def test_listener_removal_does_not_skip_next(self) -> None:
        result = run_lua_case("listener_removal_does_not_skip_next")

        self.assertIn("PASS listener_removal_does_not_skip_next", result.stdout)

    def test_nested_dispatch_preserves_outer_snapshot(self) -> None:
        result = run_lua_case("nested_dispatch_preserves_outer_snapshot")

        self.assertIn("PASS nested_dispatch_preserves_outer_snapshot", result.stdout)

    def test_player_entering_world_remains_registered_for_instance_entry(self) -> None:
        result = run_lua_case("player_entering_world_remains_registered_for_instance_entry")

        self.assertIn("PASS player_entering_world_remains_registered_for_instance_entry", result.stdout)

    def test_bootstrap_retries_after_commit_failure(self) -> None:
        result = run_lua_case("bootstrap_retries_after_commit_failure")

        self.assertIn("PASS bootstrap_retries_after_commit_failure", result.stdout)

    def test_error_reporting_failure_cleans_dispatch_snapshot(self) -> None:
        result = run_lua_case("error_reporting_failure_cleans_dispatch_snapshot")

        self.assertIn("PASS error_reporting_failure_cleans_dispatch_snapshot", result.stdout)

    def test_options_normalize_persisted_types(self) -> None:
        result = run_lua_case("options_normalize_persisted_types")

        self.assertIn("PASS options_normalize_persisted_types", result.stdout)

    def test_options_nested_defaults_are_independent(self) -> None:
        result = run_lua_case("options_nested_defaults_are_independent")

        self.assertIn("PASS options_nested_defaults_are_independent", result.stdout)

    def test_options_reject_ambiguous_ownership(self) -> None:
        result = run_lua_case("options_reject_ambiguous_ownership")

        self.assertIn("PASS options_reject_ambiguous_ownership", result.stdout)

    def test_options_reset_all_defaults(self) -> None:
        result = run_lua_case("options_reset_all_defaults")

        self.assertIn("PASS options_reset_all_defaults", result.stdout)

    def test_options_same_namespace_extension_preserves_storage(self) -> None:
        result = run_lua_case("options_same_namespace_extension_preserves_storage")

        self.assertIn("PASS options_same_namespace_extension_preserves_storage", result.stdout)

    def test_options_reject_invalid_registered_keys(self) -> None:
        result = run_lua_case("options_reject_invalid_registered_keys")

        self.assertIn("PASS options_reject_invalid_registered_keys", result.stdout)

    def test_options_table_default_redeclaration(self) -> None:
        result = run_lua_case("options_table_default_redeclaration")

        self.assertIn("PASS options_table_default_redeclaration", result.stdout)

    def test_options_reject_cyclic_defaults(self) -> None:
        result = run_lua_case("options_reject_cyclic_defaults")

        self.assertIn("PASS options_reject_cyclic_defaults", result.stdout)

    def test_future_raid_schema_is_preserved(self) -> None:
        result = run_lua_case("future_raid_schema_is_preserved")

        self.assertIn("PASS future_raid_schema_is_preserved", result.stdout)

    def test_raid_queries_are_deeply_read_only(self) -> None:
        result = run_lua_case("raid_queries_are_deeply_read_only")
        self.assertIn("PASS raid_queries_are_deeply_read_only", result.stdout)

    def test_raid_queries_reject_future_schema_without_touching_output(self) -> None:
        result = run_lua_case("raid_queries_reject_future_schema_without_touching_output")
        self.assertIn("PASS raid_queries_reject_future_schema_without_touching_output", result.stdout)

    def test_raid_validator_reports_raw_defects(self) -> None:
        result = run_lua_case("raid_validator_reports_raw_defects")
        self.assertIn("PASS raid_validator_reports_raw_defects", result.stdout)

    def test_raid_normalization_preserves_explicit_empty_boss_attendance(self) -> None:
        result = run_lua_case("raid_normalization_preserves_explicit_empty_boss_attendance")
        self.assertIn("PASS raid_normalization_preserves_explicit_empty_boss_attendance", result.stdout)

    def test_raid_validator_traverses_sparse_and_mapped_data(self) -> None:
        result = run_lua_case("raid_validator_traverses_sparse_and_mapped_data")
        self.assertIn("PASS raid_validator_traverses_sparse_and_mapped_data", result.stdout)

    def test_raid_queries_guard_malformed_collections(self) -> None:
        result = run_lua_case("raid_queries_guard_malformed_collections")
        self.assertIn("PASS raid_queries_guard_malformed_collections", result.stdout)

    def test_raid_read_indexes_are_fresh_and_do_not_alias(self) -> None:
        result = run_lua_case("raid_read_indexes_are_fresh_and_do_not_alias")
        self.assertIn("PASS raid_read_indexes_are_fresh_and_do_not_alias", result.stdout)

    def test_raid_query_output_buffers_never_alias_canonical_data(self) -> None:
        result = run_lua_case("raid_query_output_buffers_never_alias_canonical_data")
        self.assertIn("PASS raid_query_output_buffers_never_alias_canonical_data", result.stdout)

    def test_saved_variables_save_failure_stops_reserves(self) -> None:
        result = run_lua_case("saved_variables_save_failure_stops_reserves")

        self.assertIn("PASS saved_variables_save_failure_stops_reserves", result.stdout)

    def test_slash_validation_formats_future_schema_diagnostic(self) -> None:
        source = SLASH_EVENTS.read_text(encoding="utf-8")
        formatter = re.search(
            r"local function formatValidateRaidDetail\(entry\)(.*?)\nend",
            source,
            re.DOTALL,
        )
        self.assertIsNotNone(formatter)
        self.assertIn('code == "SCHEMA_VERSION_FUTURE"', formatter.group(1))


if __name__ == "__main__":
    unittest.main()
