from __future__ import annotations

from pathlib import Path
import unittest

from tests.lua_test_runner import run_lua_case


class RaidRecordingIntegrityBehaviorTests(unittest.TestCase):
    def test_raid_create_rejects_malformed_roster_metadata(self) -> None:
        result = run_lua_case("raid_create_rejects_malformed_roster_metadata")
        self.assertIn("PASS raid_create_rejects_malformed_roster_metadata", result.stdout)

    def test_raid_session_create_failure_is_atomic(self) -> None:
        result = run_lua_case("raid_session_create_failure_is_atomic")
        self.assertIn("PASS raid_session_create_failure_is_atomic", result.stdout)

    def test_raid_create_preserves_store_rejection_reason(self) -> None:
        result = run_lua_case("raid_create_preserves_store_rejection_reason")
        self.assertIn("PASS raid_create_preserves_store_rejection_reason", result.stdout)

    def test_raid_end_rejection_preserves_active_runtime(self) -> None:
        result = run_lua_case("raid_end_rejection_preserves_active_runtime")
        self.assertIn("PASS raid_end_rejection_preserves_active_runtime", result.stdout)

    def test_raid_state_resolves_roster_timers_after_toc_order_load(self) -> None:
        result = run_lua_case("raid_state_resolves_roster_timers_after_toc_order_load")
        self.assertIn("PASS raid_state_resolves_roster_timers_after_toc_order_load", result.stdout)

    def test_raid_recording_fixture_smoke(self) -> None:
        result = run_lua_case("raid_recording_fixture_smoke")
        self.assertIn("PASS raid_recording_fixture_smoke", result.stdout)

    def test_loot_canonical_mutations_advance_revision_before_notification(self) -> None:
        result = run_lua_case("loot_canonical_mutations_advance_revision_before_notification")
        self.assertIn(
            "PASS loot_canonical_mutations_advance_revision_before_notification",
            result.stdout,
        )

    def test_loot_semantic_store_failure_is_atomic(self) -> None:
        result = run_lua_case("loot_semantic_store_failure_is_atomic")
        self.assertIn("PASS loot_semantic_store_failure_is_atomic", result.stdout)

    def test_real_roster_session_end_publishes_final_delta(self) -> None:
        result = run_lua_case("real_roster_session_end_publishes_final_delta")
        self.assertIn("PASS real_roster_session_end_publishes_final_delta", result.stdout)

    def test_runtime_only_roster_settlement_does_not_publish_nil_delta(self) -> None:
        result = run_lua_case("real_roster_runtime_only_change_does_not_publish_nil_delta")
        self.assertIn("PASS real_roster_runtime_only_change_does_not_publish_nil_delta", result.stdout)

    def test_real_attendance_manual_refresh_calls_roster_owner(self) -> None:
        result = run_lua_case("real_attendance_manual_refresh_calls_roster_owner")
        self.assertIn("PASS real_attendance_manual_refresh_calls_roster_owner", result.stdout)

    def test_attendance_seed_and_close_are_idempotent_revisioned_transactions(self) -> None:
        result = run_lua_case("attendance_seed_and_close_are_idempotent_revisioned_transactions")
        self.assertIn("PASS attendance_seed_and_close_are_idempotent_revisioned_transactions", result.stdout)

    def test_attendance_delta_records_only_presence_transitions(self) -> None:
        result = run_lua_case("attendance_delta_records_only_presence_transitions")
        self.assertIn("PASS attendance_delta_records_only_presence_transitions", result.stdout)

    def test_attendance_controller_resolves_stable_event_identity(self) -> None:
        result = run_lua_case("attendance_controller_resolves_stable_event_identity")
        self.assertIn("PASS attendance_controller_resolves_stable_event_identity", result.stdout)

    def test_attendance_unknown_and_duplicate_leave_are_deep_noops(self) -> None:
        result = run_lua_case("attendance_unknown_and_duplicate_leave_are_deep_noops")
        self.assertIn("PASS attendance_unknown_and_duplicate_leave_are_deep_noops", result.stdout)

    def test_attendance_semantic_store_failure_is_atomic(self) -> None:
        result = run_lua_case("attendance_semantic_store_failure_is_atomic")
        self.assertIn("PASS attendance_semantic_store_failure_is_atomic", result.stdout)

    def test_attendance_delayed_transition_remains_monotonic(self) -> None:
        result = run_lua_case("attendance_delayed_transition_remains_monotonic")
        self.assertIn("PASS attendance_delayed_transition_remains_monotonic", result.stdout)

    def test_attendance_removal_preserves_raid_history(self) -> None:
        result = run_lua_case("attendance_removal_preserves_raid_history")
        self.assertIn("PASS attendance_removal_preserves_raid_history", result.stdout)

    def test_equip_inspect_delayed_work_tracks_stable_raid_identity(self) -> None:
        result = run_lua_case("equip_inspect_delayed_work_tracks_stable_raid_identity")
        self.assertIn("PASS equip_inspect_delayed_work_tracks_stable_raid_identity", result.stdout)

    def test_equip_inspect_preserves_ready_snapshot_after_terminal_attempts(self) -> None:
        result = run_lua_case("equip_inspect_preserves_ready_snapshot_after_terminal_attempts")
        self.assertIn("PASS equip_inspect_preserves_ready_snapshot_after_terminal_attempts", result.stdout)

    def test_equip_inspect_ready_snapshot_survives_reload_with_epoch_timestamp(self) -> None:
        result = run_lua_case("equip_inspect_ready_snapshot_survives_reload_with_epoch_timestamp")
        self.assertIn("PASS equip_inspect_ready_snapshot_survives_reload_with_epoch_timestamp", result.stdout)

    def test_equip_inspect_persists_truncated_item_level_with_reload_stable_digest(self) -> None:
        result = run_lua_case("equip_inspect_persists_truncated_item_level_with_reload_stable_digest")
        self.assertIn(
            "PASS equip_inspect_persists_truncated_item_level_with_reload_stable_digest",
            result.stdout,
        )

    def test_raid_inspect_persistence_compacts_only_on_explicit_save(self) -> None:
        result = run_lua_case("raid_inspect_persistence_compacts_only_on_explicit_save")
        self.assertIn("PASS raid_inspect_persistence_compacts_only_on_explicit_save", result.stdout)

    def test_equip_inspect_ready_persistence_is_atomic_revisioned_full_sync(self) -> None:
        result = run_lua_case("equip_inspect_ready_persistence_is_atomic_revisioned_full_sync")
        self.assertIn("PASS equip_inspect_ready_persistence_is_atomic_revisioned_full_sync", result.stdout)

    def test_equip_inspect_semantic_store_failure_is_atomic(self) -> None:
        result = run_lua_case("equip_inspect_semantic_store_failure_is_atomic")
        self.assertIn("PASS equip_inspect_semantic_store_failure_is_atomic", result.stdout)

    def test_equip_inspect_orphaned_work_is_cancelled(self) -> None:
        result = run_lua_case("equip_inspect_orphaned_work_is_cancelled")
        self.assertIn("PASS equip_inspect_orphaned_work_is_cancelled", result.stdout)

    def test_equip_inspect_force_player_returns_synchronous_terminal_failure(self) -> None:
        result = run_lua_case("equip_inspect_force_player_returns_synchronous_terminal_failure")
        self.assertIn("PASS equip_inspect_force_player_returns_synchronous_terminal_failure", result.stdout)

    def test_equip_inspect_table_raid_identity_reresolves_stably(self) -> None:
        result = run_lua_case("equip_inspect_table_raid_identity_reresolves_stably")
        self.assertIn("PASS equip_inspect_table_raid_identity_reresolves_stably", result.stdout)

    def test_equip_inspect_orphan_does_not_clear_unrelated_active_target(self) -> None:
        result = run_lua_case("equip_inspect_orphan_does_not_clear_unrelated_active_target")
        self.assertIn("PASS equip_inspect_orphan_does_not_clear_unrelated_active_target", result.stdout)

    def test_equip_inspect_serializes_global_notify_ownership(self) -> None:
        result = run_lua_case("equip_inspect_serializes_global_notify_ownership")
        self.assertIn("PASS equip_inspect_serializes_global_notify_ownership", result.stdout)

    def test_equip_inspect_delayed_raid_create_ignores_deleted_raid(self) -> None:
        result = run_lua_case("equip_inspect_delayed_raid_create_ignores_deleted_raid")
        self.assertIn("PASS equip_inspect_delayed_raid_create_ignores_deleted_raid", result.stdout)

    def test_real_logger_set_current_raid_calls_roster_owner(self) -> None:
        result = run_lua_case("real_logger_set_current_raid_calls_roster_owner")
        self.assertIn("PASS real_logger_set_current_raid_calls_roster_owner", result.stdout)

    def test_real_roster_dispatch_and_scheduled_paths_publish_once(self) -> None:
        result = run_lua_case("real_roster_dispatch_and_scheduled_paths_publish_once")
        self.assertIn("PASS real_roster_dispatch_and_scheduled_paths_publish_once", result.stdout)

    def test_logger_cleanup_is_store_owned_and_revision_coherent(self) -> None:
        result = run_lua_case("logger_cleanup_is_store_owned_and_revision_coherent")
        self.assertIn("PASS logger_cleanup_is_store_owned_and_revision_coherent", result.stdout)

    def test_logger_cleanup_preserves_active_raid(self) -> None:
        result = run_lua_case("logger_cleanup_preserves_active_raid")
        self.assertIn("PASS logger_cleanup_preserves_active_raid", result.stdout)

    def test_logger_async_cleanup_conflicts_when_candidate_becomes_current(self) -> None:
        result = run_lua_case("logger_async_cleanup_conflicts_when_candidate_becomes_current")
        self.assertIn("PASS logger_async_cleanup_conflicts_when_candidate_becomes_current", result.stdout)

    def test_raid_store_bulk_delete_honors_protected_nid(self) -> None:
        result = run_lua_case("raid_store_bulk_delete_honors_protected_nid")
        self.assertIn("PASS raid_store_bulk_delete_honors_protected_nid", result.stdout)

    def test_logger_async_cleanup_cancel_rolls_back_staged_work(self) -> None:
        result = run_lua_case("logger_async_cleanup_cancel_rolls_back_staged_work")
        self.assertIn("PASS logger_async_cleanup_cancel_rolls_back_staged_work", result.stdout)

    def test_logger_async_cleanup_completed_handle_is_terminal_not_cancelled(self) -> None:
        result = run_lua_case("logger_async_cleanup_completed_handle_is_terminal_not_cancelled")
        self.assertIn("PASS logger_async_cleanup_completed_handle_is_terminal_not_cancelled", result.stdout)

    def test_logger_async_cleanup_store_failure_is_atomic(self) -> None:
        result = run_lua_case("logger_async_cleanup_store_failure_is_atomic")
        self.assertIn("PASS logger_async_cleanup_store_failure_is_atomic", result.stdout)

    def test_logger_cleanup_detached_failure_is_atomic(self) -> None:
        result = run_lua_case("logger_cleanup_detached_failure_is_atomic")
        self.assertIn("PASS logger_cleanup_detached_failure_is_atomic", result.stdout)

    def test_logger_cleanup_planning_is_non_mutating(self) -> None:
        result = run_lua_case("logger_cleanup_planning_is_non_mutating")
        self.assertIn("PASS logger_cleanup_planning_is_non_mutating", result.stdout)

    def test_logger_cleanup_noop_preserves_canonical_identities(self) -> None:
        result = run_lua_case("logger_cleanup_noop_preserves_canonical_identities")
        self.assertIn("PASS logger_cleanup_noop_preserves_canonical_identities", result.stdout)

    def test_logger_async_cleanup_noop_preserves_canonical_identities(self) -> None:
        result = run_lua_case("logger_async_cleanup_noop_preserves_canonical_identities")
        self.assertIn("PASS logger_async_cleanup_noop_preserves_canonical_identities", result.stdout)

    def test_raid_store_cleanup_conflict_is_atomic(self) -> None:
        result = run_lua_case("raid_store_cleanup_conflict_is_atomic")
        self.assertIn("PASS raid_store_cleanup_conflict_is_atomic", result.stdout)

    def test_archive_cleanup_uses_exact_row_identity_and_is_atomic(self) -> None:
        result = run_lua_case("raid_archive_cleanup_exact_identity")
        self.assertIn("PASS raid_archive_cleanup_exact_identity", result.stdout)

    def test_logger_refresh_requests_coalesce_behaviorally(self) -> None:
        result = run_lua_case("logger_refresh_requests_coalesce_behaviorally")
        self.assertIn("PASS logger_refresh_requests_coalesce_behaviorally", result.stdout)

    def test_logger_bulk_raid_delete_publishes_once(self) -> None:
        result = run_lua_case("logger_bulk_raid_delete_publishes_once")
        self.assertIn("PASS logger_bulk_raid_delete_publishes_once", result.stdout)

    def test_logger_raid_list_invalidates_when_logger_data_changes(self) -> None:
        source = Path("Raid Management Addon/Controllers/Logger.lua").read_text(encoding="utf-8")
        raids_block = source.split("module.Raids = module.Raids or {}", 1)[1].split("-- Loot list.", 1)[0]
        self.assertIn("RegisterCallback(LoggerEvents.LoggerDataChanged", raids_block)
        self.assertIn("controller:Dirty()", raids_block)

    def test_logger_source_rebuild_is_atomic_and_revisioned(self) -> None:
        result = run_lua_case("logger_source_rebuild_is_atomic_and_revisioned")
        self.assertIn("PASS logger_source_rebuild_is_atomic_and_revisioned", result.stdout)

    def test_logger_source_rebuild_skips_active_record(self) -> None:
        result = run_lua_case("logger_source_rebuild_skips_active_record")
        self.assertIn("PASS logger_source_rebuild_skips_active_record", result.stdout)

    def test_logger_record_loot_verification_failure_is_atomic(self) -> None:
        result = run_lua_case("logger_record_loot_verification_failure_is_atomic")
        self.assertIn("PASS logger_record_loot_verification_failure_is_atomic", result.stdout)

    def test_logger_atomic_commit_failure_matrix(self) -> None:
        result = run_lua_case("logger_atomic_commit_failure_matrix")
        self.assertIn("PASS logger_atomic_commit_failure_matrix", result.stdout)

    def test_logger_history_validation_is_strict_and_complete(self) -> None:
        result = run_lua_case("logger_history_validation_is_strict_and_complete")
        self.assertIn("PASS logger_history_validation_is_strict_and_complete", result.stdout)

    def test_raid_store_uses_validator_first_error(self) -> None:
        result = run_lua_case("raid_store_uses_validator_first_error")
        self.assertIn("PASS raid_store_uses_validator_first_error", result.stdout)

    def test_raid_store_rejects_malformed_validator_reports(self) -> None:
        result = run_lua_case("raid_store_rejects_malformed_validator_reports")
        self.assertIn("PASS raid_store_rejects_malformed_validator_reports", result.stdout)

    def test_logger_async_rebuild_outcomes_and_conflict(self) -> None:
        result = run_lua_case("logger_async_rebuild_outcomes_and_conflict")
        self.assertIn("PASS logger_async_rebuild_outcomes_and_conflict", result.stdout)

    def test_config_rebuild_callback_ignores_incomplete_terminal_results(self) -> None:
        source = Path("Raid Management Addon/Controllers/Config.lua").read_text(encoding="utf-8")
        callback = source[source.index("actions:StartLootSourceRebuild(function") :]
        callback = callback[: callback.index("end)")]
        self.assertIn("function(rebuildResult, complete)", callback)
        guard = callback.index("if complete ~= true")
        success = callback.index("MsgLoggerLootSourcesRebuilt")
        refresh = callback.index("refreshLootHistoryReport()")
        self.assertLess(guard, success)
        self.assertLess(guard, refresh)


if __name__ == "__main__":
    unittest.main()
