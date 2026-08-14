from __future__ import annotations

import unittest
from pathlib import Path

from tests.lua_test_runner import run_lua_case


class RaidReplicationBehaviorTests(unittest.TestCase):
    def assert_case(self, case_name: str) -> None:
        result = run_lua_case(case_name)
        self.assertIn(f"PASS {case_name}", result.stdout)

    def test_event_identity_is_deterministic_and_bounded(self) -> None:
        self.assert_case("raid_replication_event_identity")

    def test_replica_loot_invalidates_loot_history(self) -> None:
        self.assert_case("raid_live_sync_replica_loot_refreshes_history")

    def test_new_active_replica_selects_loot_history_once(self) -> None:
        self.assert_case("raid_live_sync_new_replica_selects_loot_history_once")

    def test_digest_is_order_independent_for_maps(self) -> None:
        self.assert_case("raid_replication_digest")

    def test_reducers_are_idempotent_and_fail_closed(self) -> None:
        self.assert_case("raid_replication_reducers")

    def test_distribution_award_commits_loot_and_counter_atomically(self) -> None:
        self.assert_case("raid_replication_distribution_award_is_atomic")

    def test_all_event_reducers_enforce_entity_semantics(self) -> None:
        self.assert_case("raid_replication_all_event_reducers")

    def test_metadata_and_conclusion_protect_lifecycle_state(self) -> None:
        self.assert_case("raid_replication_lifecycle_guards")

    def test_conclusion_rejects_malformed_collections_without_throwing(self) -> None:
        self.assert_case("raid_replication_malformed_conclusion")

    def test_event_digest_validation_is_exact_and_bounded(self) -> None:
        self.assert_case("raid_replication_event_digest_validation")

    def test_canonical_values_fail_closed(self) -> None:
        self.assert_case("raid_replication_canonical_failures")

    def test_beta_store_resets_and_reload_preserves_sync_position(self) -> None:
        self.assert_case("raid_replication_archive_reload")

    def test_store_commit_and_replica_apply_are_atomic(self) -> None:
        self.assert_case("raid_replication_atomic_store")

    def test_exposed_state_tampering_is_rejected_by_every_active_mutation_path(self) -> None:
        self.assert_case("raid_replication_rejects_exposed_state_tampering")

    def test_checkpoint_bounds_range_and_snapshot_fallback(self) -> None:
        self.assert_case("raid_replication_checkpoint")

    def test_snapshot_status_and_conflict_validation_is_atomic(self) -> None:
        self.assert_case("raid_replication_snapshot_validation")

    def test_authenticated_live_snapshot_repairs_only_current_active_record(self) -> None:
        self.assert_case("raid_replication_live_snapshot_repair")

    def test_authoritative_commit_requires_runtime_raid_leader_guard(self) -> None:
        self.assert_case("raid_replication_authority_guard")

    def test_group_loot_uses_raid_leader_as_authority(self) -> None:
        self.assert_case("raid_live_sync_group_loot_leader_authority")

    def test_fresh_leader_entry_does_not_start_recovery(self) -> None:
        self.assert_case("raid_fresh_leader_entry_creates_without_recovery")

    def test_initial_authority_discovery_is_not_a_handover(self) -> None:
        self.assert_case("raid_initial_authority_discovery_is_not_handover")

    def test_reentry_and_handover_are_mutually_exclusive(self) -> None:
        self.assert_case("raid_reentry_and_handover_are_mutually_exclusive")

    def test_late_nonleader_discovers_the_leaders_existing_active_raid(self) -> None:
        self.assert_case("raid_live_sync_late_join_discovers_existing_active_raid")

    def test_unresolved_authority_retries_once_after_roster_settlement(self) -> None:
        self.assert_case("raid_live_sync_unresolved_authority_retries_after_roster_settlement")

    def test_member_entry_before_the_designated_leader_waits_for_authority(self) -> None:
        self.assert_case("raid_live_sync_member_enters_before_designated_leader")

    def test_returning_raid_leader_recovers_the_highest_replica_before_any_write(self) -> None:
        self.assert_case("raid_leader_reentry_recovers_highest_replica_before_write")

    def test_returning_raid_leader_repairs_corrupt_equal_position_from_replica(self) -> None:
        self.assert_case("raid_leader_reentry_repairs_corrupt_equal_position")

    def test_reentry_resume_and_replace_use_the_controlled_raid_transition(self) -> None:
        self.assert_case("raid_reentry_state_applies_resume_and_replace")

    def test_reentry_replacement_defers_attendance_until_after_lifecycle_publication(self) -> None:
        self.assert_case("raid_reentry_create_defers_attendance_until_transition_finishes")

    def test_reentry_popup_routes_only_explicit_yes_or_no_decisions(self) -> None:
        self.assert_case("raid_reentry_popup_routes_explicit_decisions")

    def test_reentry_entry_wiring_emits_one_popup(self) -> None:
        self.assert_case("raid_reentry_entry_wiring_emits_one_popup")

    def test_reentry_starts_when_instance_context_settles_after_login(self) -> None:
        self.assert_case("raid_reentry_starts_when_instance_context_settles_after_login")

    def test_reentry_retries_once_after_leader_roster_settlement(self) -> None:
        self.assert_case("raid_reentry_retries_once_after_leader_roster_settlement")

    def test_reentry_waits_for_leader_identity_after_role_settlement(self) -> None:
        self.assert_case("raid_reentry_waits_for_leader_identity_after_role_settlement")

    def test_reentry_yes_resumes_once(self) -> None:
        self.assert_case("raid_reentry_yes_resumes_once")

    def test_reentry_no_replaces_once_without_digest_conflict(self) -> None:
        self.assert_case("raid_reentry_no_replaces_once_without_digest_conflict")

    def test_reentry_yes_keeps_the_recovered_raid_identity(self) -> None:
        self.assert_case("raid_leader_reentry_resume_keeps_identity")

    def test_reentry_no_replaces_the_recovered_raid_once(self) -> None:
        self.assert_case("raid_leader_reentry_replace_uses_recovered_base")

    def test_reentry_no_publishes_the_conclusion_before_the_new_head(self) -> None:
        self.assert_case("raid_leader_reentry_replace_publishes_lifecycle_before_head")

    def test_reentry_rollback_discards_deferred_lifecycle_events(self) -> None:
        self.assert_case("raid_leader_reentry_discards_deferred_events_on_rollback")

    def test_reentry_context_mismatch_replaces_without_a_popup(self) -> None:
        self.assert_case("raid_leader_reentry_context_mismatch_skips_popup")

    def test_reentry_dismissal_keeps_the_write_barrier_closed(self) -> None:
        self.assert_case("raid_leader_reentry_dismissal_stays_suspended")

    def test_returning_raid_leader_suspends_when_the_highest_position_has_divergent_digests(self) -> None:
        self.assert_case("raid_leader_reentry_suspends_on_tied_digest_conflict")

    def test_authority_change_cancels_a_returning_leaders_pending_snapshot(self) -> None:
        self.assert_case("raid_leader_reentry_authority_change_cancels_pending_snapshot")

    def test_split_raid_leader_master_looter_records_and_replicates_trade_award_once(self) -> None:
        self.assert_case("raid_live_sync_split_loot_authority_records_trade_award_once")

    def test_group_loot_waits_for_recovery_before_consuming_runtime_state(self) -> None:
        self.assert_case("raid_handover_replays_group_loot_after_snapshot")

    def test_master_loot_award_reuses_bounded_retry_during_recovery(self) -> None:
        self.assert_case("raid_handover_master_loot_uses_existing_retry")

    def test_loot_chat_recovery_gate_precedes_passive_observation(self) -> None:
        self.assert_case("raid_handover_loot_chat_gate_is_side_effect_free")

    def test_group_loot_replay_survives_one_store_rejection(self) -> None:
        self.assert_case("raid_handover_group_loot_retry_is_counter_safe")

    def test_recovery_keeps_selection_and_winner_for_one_roll(self) -> None:
        self.assert_case("raid_handover_keeps_selection_and_winner_facts")

    def test_system_loot_parsing_is_winner_only_and_still_forwards_rolls(self) -> None:
        self.assert_case("raid_system_loot_parse_is_winner_only")

    def test_normal_ignored_passive_winner_is_terminal(self) -> None:
        self.assert_case("raid_loot_normal_ignored_passive_winner_is_terminal")

    def test_recovery_ignored_passive_winner_is_terminal(self) -> None:
        self.assert_case("raid_loot_recovery_ignored_passive_winner_is_terminal")

    def test_normal_passive_duplicate_is_terminal(self) -> None:
        self.assert_case("raid_loot_normal_passive_duplicate_is_terminal")

    def test_recovery_passive_duplicate_is_terminal(self) -> None:
        self.assert_case("raid_loot_recovery_passive_duplicate_is_terminal")

    def test_archive_capture_restore_rolls_back_every_canonical_key(self) -> None:
        self.assert_case("raid_replication_archive_rollback")

    def test_single_active_archive_invariant_is_enforced(self) -> None:
        self.assert_case("raid_replication_single_active")

    def test_local_mutations_commit_semantic_events_in_order(self) -> None:
        self.assert_case("raid_replication_local_mutations")

    def test_conclusion_compacts_the_active_event_ledger_atomically(self) -> None:
        self.assert_case("raid_replication_conclusion")

    def test_version_3_protocol_round_trips_every_closed_message_kind(self) -> None:
        self.assert_case("raid_replication_protocol_round_trip")

    def test_version_3_protocol_rejects_invalid_envelopes_and_bodies(self) -> None:
        self.assert_case("raid_replication_protocol_rejects_invalid")

    def test_transfer_sessions_assemble_ranges_and_reject_conflicting_duplicates(self) -> None:
        self.assert_case("raid_transfer_session_assembly")

    def test_transfer_sessions_reject_capacity_overflow_before_allocation(self) -> None:
        self.assert_case("raid_transfer_session_capacity")

    def test_transfer_sessions_correlate_kind_metadata_and_immutable_callback(self) -> None:
        self.assert_case("raid_transfer_session_correlation")

    def test_transfer_sessions_bound_channel_decode_without_deflate(self) -> None:
        self.assert_case("raid_transfer_session_decode_bounds")

    def test_replacement_publishes_attendance_before_create(self) -> None:
        self.assert_case("raid_session_replacement_preserves_event_order")

    def test_authority_promotion_uses_only_recovered_state(self) -> None:
        self.assert_case("raid_handover_store_promotion_is_recovery_only")

    def test_handover_publishes_lifecycle_and_warns_only_old_and_new_leaders(self) -> None:
        self.assert_case("raid_handover_recovery_lifecycle_and_warnings")

    def test_handover_begin_request_failures_close_recovery_once(self) -> None:
        self.assert_case("raid_handover_begin_request_failures_close_recovery_once")

    def test_raid_leader_handover_prefers_previous_authority_and_rejects_old_writes(self) -> None:
        self.assert_case("raid_handover_previous_authority")

    def test_raid_leader_handover_suspends_on_divergent_tied_heads(self) -> None:
        self.assert_case("raid_handover_digest_conflict")

    def test_digest_conflict_keeps_the_real_store_write_barrier_closed(self) -> None:
        self.assert_case("raid_handover_digest_conflict_keeps_write_barrier")

    def test_handover_without_a_local_head_discovers_before_creating_once(self) -> None:
        self.assert_case("raid_handover_without_local_head_discovers_before_create")

    def test_raid_leader_handover_recovers_through_real_store_protocol_and_session(self) -> None:
        self.assert_case("raid_handover_real_recovery")

    def test_raid_leader_change_closes_writes_before_the_wow_event(self) -> None:
        self.assert_case("raid_handover_mutation_detects_authority_change")

    def test_repeated_raid_leader_changes_cancel_stale_work(self) -> None:
        self.assert_case("raid_handover_repeated_authority_change")

    def test_recovery_replays_roster_and_boss_without_nid_aliasing(self) -> None:
        self.assert_case("raid_handover_replays_raid_facts_after_snapshot")

    def test_recovery_failure_discards_pending_raid_facts(self) -> None:
        self.assert_case("raid_handover_discards_raid_facts_on_failure")

    def test_recovery_dedupe_keeps_a_recent_fact_after_the_window(self) -> None:
        self.assert_case("raid_handover_recovery_dedupe_is_temporal")

    def test_recovery_gate_is_read_only_before_schema_normalization(self) -> None:
        self.assert_case("raid_handover_recovery_gate_precedes_schema_mutation")

    def test_manual_conclusion_is_not_retried_after_recovery(self) -> None:
        self.assert_case("raid_handover_manual_conclusion_is_not_retried")

    def test_recovery_raid_fact_bounds_and_invalid_success_are_safe(self) -> None:
        self.assert_case("raid_handover_recovery_fact_bounds_and_invalid_success")

    def test_historical_import_has_explicit_atomic_outcomes(self) -> None:
        self.assert_case("raid_history_import_outcomes")

    def test_share_eligibility_is_consistent_and_observable(self) -> None:
        self.assert_case("logger_share_eligibility_is_consistent_and_observable")

    def test_share_send_surfaces_backend_rejection(self) -> None:
        self.assert_case("logger_share_send_surfaces_backend_rejection")

    def test_historical_offer_acceptance_imports_once_through_real_transport(self) -> None:
        self.assert_case("raid_history_consent_transfer")

    def test_sequence_zero_completed_history_imports_through_real_transport(self) -> None:
        self.assert_case("raid_history_sequence_zero_consent_transfer")

    def test_historical_decline_expiry_and_partial_transfer_never_mutate(self) -> None:
        self.assert_case("raid_history_consent_rejections")

    def test_historical_two_peer_flow_retries_and_closes_result_state(self) -> None:
        self.assert_case("raid_history_two_peer_retry_and_result_matrix")

    def test_historical_results_are_state_closed_and_visible_to_both_peers(self) -> None:
        self.assert_case("raid_history_result_matrix_and_feedback")

    def test_archive_row_identity_survives_colliding_display_nids(self) -> None:
        self.assert_case("raid_archive_row_identity_collision")

    def test_legacy_nid_deletes_reject_active_and_ambiguous_records(self) -> None:
        self.assert_case("raid_archive_legacy_nid_delete_is_fail_closed")

    def test_invalid_format_one_archive_is_quarantined_without_mutation(self) -> None:
        self.assert_case("raid_archive_invalid_load_quarantine")

    def test_history_ui_uses_archive_order_identity(self) -> None:
        projections = Path("Raid Management Addon/Services/Raid/Projections.lua").read_text(encoding="utf-8")
        logger = Path("Raid Management Addon/Controllers/Logger.lua").read_text(encoding="utf-8")
        self.assertIn("id = seq", projections)
        self.assertNotIn("GetRaidIndexByNid", logger)
        self.assertIn("DeleteRaidsByIndex", logger)

    def test_runtime_indexes_never_enter_canonical_raid_state(self) -> None:
        self.assert_case("raid_runtime_indexes_are_store_owned")

    def test_queries_and_validator_have_no_runtime_field_exception(self) -> None:
        queries = Path("Raid Management Addon/Database/DBRaidQueries.lua").read_text(encoding="utf-8")
        validator = Path("Raid Management Addon/Database/DBRaidValidator.lua").read_text(encoding="utf-8")
        self.assertNotIn('key ~= "_runtime"', queries)
        self.assertNotIn('key ~= "_runtime"', validator)

if __name__ == "__main__":
    unittest.main()
