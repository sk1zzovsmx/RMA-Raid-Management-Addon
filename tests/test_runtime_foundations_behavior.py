from __future__ import annotations

from pathlib import Path
import re
import unittest

from tests.lua_test_runner import run_lua_case


ROOT = Path(__file__).resolve().parents[1]
SLASH_EVENTS = ROOT / "Raid Management Addon" / "EntryPoints" / "SlashEvents.lua"


class RuntimeFoundationsBehaviorTest(unittest.TestCase):
    def test_harness_executes_lua_51(self) -> None:
        result = run_lua_case("lua_51_smoke")

        self.assertIn("PASS lua_51_smoke", result.stdout)

    def test_bootstrap_retries_after_failure(self) -> None:
        result = run_lua_case("bootstrap_retries_after_failure")

        self.assertIn("PASS bootstrap_retries_after_failure", result.stdout)

    def test_bootstrap_success_commits_before_roster_refresh(self) -> None:
        result = run_lua_case("bootstrap_success_commits_before_roster_refresh")

        self.assertIn("PASS bootstrap_success_commits_before_roster_refresh", result.stdout)

    def test_listener_removal_does_not_skip_next(self) -> None:
        result = run_lua_case("listener_removal_does_not_skip_next")

        self.assertIn("PASS listener_removal_does_not_skip_next", result.stdout)

    def test_nested_dispatch_preserves_outer_snapshot(self) -> None:
        result = run_lua_case("nested_dispatch_preserves_outer_snapshot")

        self.assertIn("PASS nested_dispatch_preserves_outer_snapshot", result.stdout)

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

    def test_options_namespace_snapshot_is_isolated(self) -> None:
        result = run_lua_case("options_namespace_snapshot_is_isolated")

        self.assertIn("PASS options_namespace_snapshot_is_isolated", result.stdout)

    def test_options_same_namespace_extension_preserves_storage(self) -> None:
        result = run_lua_case("options_same_namespace_extension_preserves_storage")

        self.assertIn("PASS options_same_namespace_extension_preserves_storage", result.stdout)

    def test_options_reject_invalid_registered_keys(self) -> None:
        result = run_lua_case("options_reject_invalid_registered_keys")

        self.assertIn("PASS options_reject_invalid_registered_keys", result.stdout)

    def test_options_table_default_redeclaration(self) -> None:
        result = run_lua_case("options_table_default_redeclaration")

        self.assertIn("PASS options_table_default_redeclaration", result.stdout)

    def test_options_cyclic_defaults_remain_independent(self) -> None:
        result = run_lua_case("options_cyclic_defaults_remain_independent")

        self.assertIn("PASS options_cyclic_defaults_remain_independent", result.stdout)

    def test_options_namespace_facade_contract(self) -> None:
        result = run_lua_case("options_namespace_facade_contract")

        self.assertIn("PASS options_namespace_facade_contract", result.stdout)

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
