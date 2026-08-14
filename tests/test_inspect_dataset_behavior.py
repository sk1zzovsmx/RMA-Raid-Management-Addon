from __future__ import annotations

import unittest

from tests.lua_test_runner import run_lua_case


class InspectDatasetBehaviorTests(unittest.TestCase):
    def test_equip_inspect_waits_for_complete_item_information(self) -> None:
        result = run_lua_case("equip_inspect_waits_for_complete_item_information")
        self.assertIn("PASS equip_inspect_waits_for_complete_item_information", result.stdout)

    def test_equip_inspect_item_information_timeout_preserves_last_good(self) -> None:
        result = run_lua_case("equip_inspect_item_information_timeout_preserves_last_good")
        self.assertIn("PASS equip_inspect_item_information_timeout_preserves_last_good", result.stdout)

    def test_equip_inspect_cancels_cold_item_work_when_raid_disappears(self) -> None:
        result = run_lua_case("equip_inspect_cancels_cold_item_work_when_raid_disappears")
        self.assertIn("PASS equip_inspect_cancels_cold_item_work_when_raid_disappears", result.stdout)

    def test_equip_inspect_distinguishes_cold_occupied_slot_from_empty(self) -> None:
        result = run_lua_case("equip_inspect_distinguishes_cold_occupied_slot_from_empty")
        self.assertIn("PASS equip_inspect_distinguishes_cold_occupied_slot_from_empty", result.stdout)

    def test_equip_inspect_failed_item_event_keeps_original_deadline(self) -> None:
        result = run_lua_case("equip_inspect_failed_item_event_keeps_original_deadline")
        self.assertIn("PASS equip_inspect_failed_item_event_keeps_original_deadline", result.stdout)

    def test_inspect_coordinator_serializes_global_ownership(self) -> None:
        result = run_lua_case("inspect_coordinator_serializes_global_ownership")
        self.assertIn("PASS inspect_coordinator_serializes_global_ownership", result.stdout)

    def test_equip_and_talent_refresh_share_global_inspect_owner(self) -> None:
        result = run_lua_case("equip_and_talent_refresh_share_global_inspect_owner")
        self.assertIn("PASS equip_and_talent_refresh_share_global_inspect_owner", result.stdout)

    def test_spec_inspect_correlates_lgt_completion_by_guid(self) -> None:
        result = run_lua_case("spec_inspect_correlates_lgt_completion_by_guid")
        self.assertIn("PASS spec_inspect_correlates_lgt_completion_by_guid", result.stdout)

    def test_equip_inspect_throttle_timer_failure_is_terminal(self) -> None:
        result = run_lua_case("equip_inspect_throttle_timer_failure_is_terminal")
        self.assertIn("PASS equip_inspect_throttle_timer_failure_is_terminal", result.stdout)

    def test_equip_inspect_own_timer_failures_are_terminal(self) -> None:
        result = run_lua_case("equip_inspect_own_timer_failures_are_terminal")
        self.assertIn("PASS equip_inspect_own_timer_failures_are_terminal", result.stdout)

    def test_vendored_lgt_respects_equipment_inspect_guard(self) -> None:
        result = run_lua_case("vendored_lgt_respects_equipment_inspect_guard")
        self.assertIn("PASS vendored_lgt_respects_equipment_inspect_guard", result.stdout)

    def test_localized_raid_identity_uses_instance_map_id(self) -> None:
        result = run_lua_case("localized_raid_identity_uses_instance_map_id")
        self.assertIn("PASS localized_raid_identity_uses_instance_map_id", result.stdout)

    def test_instance_datasets_share_canonical_identity(self) -> None:
        result = run_lua_case("instance_datasets_share_canonical_identity")
        self.assertIn("PASS instance_datasets_share_canonical_identity", result.stdout)

    def test_loot_dataset_build_failure_preserves_active_generation(self) -> None:
        result = run_lua_case("loot_dataset_build_failure_preserves_active_generation")
        self.assertIn("PASS loot_dataset_build_failure_preserves_active_generation", result.stdout)

    def test_loot_dataset_handles_duplicate_nil_and_malformed_entries(self) -> None:
        result = run_lua_case("loot_dataset_handles_duplicate_nil_and_malformed_entries")
        self.assertIn("PASS loot_dataset_handles_duplicate_nil_and_malformed_entries", result.stdout)

    def test_dataset_activation_rolls_back_cross_owner_failure(self) -> None:
        result = run_lua_case("dataset_activation_rolls_back_cross_owner_failure")
        self.assertIn("PASS dataset_activation_rolls_back_cross_owner_failure", result.stdout)

    def test_dataset_activation_rejects_false_owner_results(self) -> None:
        result = run_lua_case("dataset_activation_rejects_false_owner_results")
        self.assertIn("PASS dataset_activation_rejects_false_owner_results", result.stdout)

    def test_dataset_activation_reports_failed_rollback(self) -> None:
        result = run_lua_case("dataset_activation_reports_failed_rollback")
        self.assertIn("PASS dataset_activation_reports_failed_rollback", result.stdout)

    def test_dataset_activation_snapshots_restore_exact_generation(self) -> None:
        result = run_lua_case("dataset_activation_snapshots_restore_exact_generation")
        self.assertIn("PASS dataset_activation_snapshots_restore_exact_generation", result.stdout)



if __name__ == "__main__":
    unittest.main()
