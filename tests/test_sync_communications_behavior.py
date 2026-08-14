from __future__ import annotations

from pathlib import Path
import unittest

from tests.lua_test_runner import run_lua_case


ROOT = Path(__file__).resolve().parents[1]
DB_SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"


class SyncCommunicationsBehaviorTests(unittest.TestCase):
    def test_real_raid_capabilities_accept_numeric_unit_identity(self) -> None:
        result = run_lua_case("raid_capabilities_accept_numeric_unit_identity")

        self.assertIn(
            "PASS raid_capabilities_accept_numeric_unit_identity",
            result.stdout,
        )

    def test_db_syncer_does_not_export_manual_request_cancellation(self) -> None:
        source = DB_SYNCER.read_text(encoding="utf-8")
        retired_name = "Cancel" + "Request"
        self.assertNotIn(f"function module:{retired_name}", source)

    def test_sync_fixture_models_communications_boundaries(self) -> None:
        result = run_lua_case("sync_fixture_models_communications_boundaries")

        self.assertIn("PASS sync_fixture_models_communications_boundaries", result.stdout)

    def test_sync_authorization_fails_closed(self) -> None:
        result = run_lua_case("sync_authorization_fails_closed")

        self.assertIn("PASS sync_authorization_fails_closed", result.stdout)

    def test_real_db_syncer_authorizes_chunks_and_whisper_requests(self) -> None:
        result = run_lua_case("real_db_syncer_authorizes_chunks_and_whisper_requests")

        self.assertIn(
            "PASS real_db_syncer_authorizes_chunks_and_whisper_requests",
            result.stdout,
        )

    def test_committed_history_revision_emits_notice_once(self) -> None:
        result = run_lua_case("sync_committed_history_revision_emits_notice_once")

        self.assertIn(
            "PASS sync_committed_history_revision_emits_notice_once",
            result.stdout,
        )

    def test_sync_diagnostics_are_debug_gated(self) -> None:
        result = run_lua_case("sync_diagnostics_are_debug_gated")

        self.assertIn("PASS sync_diagnostics_are_debug_gated", result.stdout)

    def test_sync_diagnostics_trace_revision_pull(self) -> None:
        result = run_lua_case("sync_diagnostics_trace_revision_pull")

        self.assertIn("PASS sync_diagnostics_trace_revision_pull", result.stdout)

    def test_sync_diagnostics_trace_manual_admission(self) -> None:
        result = run_lua_case("sync_diagnostics_trace_manual_admission")

        self.assertIn("PASS sync_diagnostics_trace_manual_admission", result.stdout)

    def test_sync_diagnostics_trace_request_response_boundaries(self) -> None:
        result = run_lua_case("sync_diagnostics_trace_request_response_boundaries")

        self.assertIn(
            "PASS sync_diagnostics_trace_request_response_boundaries",
            result.stdout,
        )

    def test_sync_diagnostics_attribute_admission_reasons(self) -> None:
        result = run_lua_case("sync_diagnostics_attribute_admission_reasons")

        self.assertIn(
            "PASS sync_diagnostics_attribute_admission_reasons",
            result.stdout,
        )

    def test_sync_diagnostics_trace_push_admission_cardinality(self) -> None:
        result = run_lua_case("sync_diagnostics_trace_push_admission_cardinality")

        self.assertIn(
            "PASS sync_diagnostics_trace_push_admission_cardinality",
            result.stdout,
        )

    def test_revision_notice_targets_master_and_coalesces(self) -> None:
        result = run_lua_case("sync_revision_notice_targets_master_and_coalesces")

        self.assertIn(
            "PASS sync_revision_notice_targets_master_and_coalesces",
            result.stdout,
        )

    def test_revision_notice_different_lineage_preserves_pending_pull(self) -> None:
        result = run_lua_case(
            "sync_revision_notice_different_lineage_preserves_pending_pull"
        )

        self.assertIn(
            "PASS sync_revision_notice_different_lineage_preserves_pending_pull",
            result.stdout,
        )

    def test_revision_notice_rejects_stale_mismatch_and_non_master(self) -> None:
        result = run_lua_case("sync_revision_notice_rejects_stale_mismatch_and_non_master")

        self.assertIn(
            "PASS sync_revision_notice_rejects_stale_mismatch_and_non_master",
            result.stdout,
        )

    def test_late_join_targets_current_master_after_roster_identity(self) -> None:
        result = run_lua_case(
            "sync_late_join_targets_current_master_after_roster_identity"
        )

        self.assertIn(
            "PASS sync_late_join_targets_current_master_after_roster_identity",
            result.stdout,
        )

    def test_targeted_timeout_retries_once(self) -> None:
        result = run_lua_case("sync_targeted_timeout_retries_once")

        self.assertIn("PASS sync_targeted_timeout_retries_once", result.stdout)

    def test_pending_authority_pull_stops_when_persistent_sync_disables(self) -> None:
        result = run_lua_case(
            "sync_pending_authority_pull_stops_when_persistent_sync_disables"
        )

        self.assertIn(
            "PASS sync_pending_authority_pull_stops_when_persistent_sync_disables",
            result.stdout,
        )

    def test_disable_cancels_automatic_request_without_retry(self) -> None:
        result = run_lua_case("sync_disable_cancels_automatic_request_without_retry")

        self.assertIn("PASS sync_disable_cancels_automatic_request_without_retry", result.stdout)

    def test_disable_rejects_late_automatic_response(self) -> None:
        result = run_lua_case("sync_disable_rejects_late_automatic_response")

        self.assertIn("PASS sync_disable_rejects_late_automatic_response", result.stdout)

    def test_disable_preserves_manual_request_response(self) -> None:
        result = run_lua_case("sync_disable_preserves_manual_request_response")

        self.assertIn("PASS sync_disable_preserves_manual_request_response", result.stdout)

    def test_pending_authority_pull_retargets_changed_master(self) -> None:
        result = run_lua_case("sync_pending_authority_pull_retargets_changed_master")

        self.assertIn(
            "PASS sync_pending_authority_pull_retargets_changed_master",
            result.stdout,
        )

    def test_persistent_schedule_survives_request_exception(self) -> None:
        result = run_lua_case("sync_request_throw_preserves_persistent_schedule")

        self.assertIn(
            "PASS sync_request_throw_preserves_persistent_schedule",
            result.stdout,
        )

    def test_real_db_syncer_requires_push_consent(self) -> None:
        result = run_lua_case("real_db_syncer_requires_push_consent")

        self.assertIn("PASS real_db_syncer_requires_push_consent", result.stdout)

    def test_sync_transport_resources_are_bounded_before_allocation(self) -> None:
        result = run_lua_case("sync_transport_resources_are_bounded_before_allocation")

        self.assertIn("PASS sync_transport_resources_are_bounded_before_allocation", result.stdout)

    def test_envelope_validation_is_correlated_end_to_end(self) -> None:
        result = run_lua_case("sync_envelope_validation_is_correlated_end_to_end")

        self.assertIn("PASS sync_envelope_validation_is_correlated_end_to_end", result.stdout)

    def test_sync_payload_parser_declares_structural_limits(self) -> None:
        payload_source = (ROOT / "Raid Management Addon" / "Database" / "DBSyncPayload.lua").read_text(encoding="utf-8")
        comms_source = (ROOT / "Raid Management Addon" / "Modules" / "Comms.lua").read_text(encoding="utf-8")

        self.assertIn("MAX_PAYLOAD_ROWS", payload_source)
        self.assertIn("MAX_ENCODED_FIELD_BYTES", payload_source)
        self.assertIn("COMMS_ADDON_QUEUE_MAX", comms_source)
        self.assertIn("_addonQueueHead", comms_source)

    def test_compressed_inbound_payload_is_rejected_before_unbounded_inflate(self) -> None:
        payload_source = (ROOT / "Raid Management Addon" / "Database" / "DBSyncPayload.lua").read_text(encoding="utf-8")
        decode_body = payload_source.split("function SnapshotPayload.DecodeTransportText", 1)[1].split("function SnapshotPayload.BuildPlayerNameMaps", 1)[0]

        self.assertNotIn("DecompressDeflate", decode_body)
        self.assertIn("COMPRESSED_PREFIX", decode_body)

        result = run_lua_case("compressed_sync_payload_never_invokes_unbounded_inflate")
        self.assertIn("PASS compressed_sync_payload_never_invokes_unbounded_inflate", result.stdout)

    def test_multichunk_enqueue_and_sync_failure_are_atomic(self) -> None:
        result = run_lua_case("sync_multichunk_enqueue_is_atomic")

        self.assertIn("PASS sync_multichunk_enqueue_is_atomic", result.stdout)

    def test_snapshot_chunks_fit_wotlk_addon_message_limit(self) -> None:
        result = run_lua_case("sync_snapshot_chunks_fit_wotlk_addon_message_limit")

        self.assertIn(
            "PASS sync_snapshot_chunks_fit_wotlk_addon_message_limit",
            result.stdout,
        )

    def test_real_comms_batch_preflight_prevents_partial_enqueue(self) -> None:
        result = run_lua_case("comms_batch_preflight_prevents_partial_enqueue")

        self.assertIn("PASS comms_batch_preflight_prevents_partial_enqueue", result.stdout)

    def test_real_comms_queue_uses_constant_single_message_pacing(self) -> None:
        result = run_lua_case("comms_queue_uses_constant_single_message_pacing")

        self.assertIn(
            "PASS comms_queue_uses_constant_single_message_pacing",
            result.stdout,
        )

    def test_representative_payloads_meet_latency_budget(self) -> None:
        result = run_lua_case("sync_representative_payloads_meet_latency_budget")

        self.assertIn(
            "PASS sync_representative_payloads_meet_latency_budget",
            result.stdout,
        )

    def test_failed_item_done_trigger_is_removed(self) -> None:
        source = DB_SYNCER.read_text(encoding="utf-8")

        self.assertNotIn("COMPLETED_LOOT_SYNC_DELAY_SECONDS", source)
        self.assertNotIn("LootDistributionSessionChangedEvent", source)

    def test_request_ids_are_bounded_session_scoped_and_collision_aware(self) -> None:
        result = run_lua_case("comms_request_ids_are_bounded_session_scoped_and_collision_aware")
        self.assertIn(
            "PASS comms_request_ids_are_bounded_session_scoped_and_collision_aware",
            result.stdout,
        )

    def test_request_enqueue_backpressure_rolls_back_pending_state(self) -> None:
        result = run_lua_case("sync_request_backpressure_rolls_back_pending")

        self.assertIn("PASS sync_request_backpressure_rolls_back_pending", result.stdout)

    def test_request_lifecycle_is_correlated_and_terminal_once(self) -> None:
        result = run_lua_case("sync_request_lifecycle_is_correlated_and_terminal_once")

        self.assertIn(
            "PASS sync_request_lifecycle_is_correlated_and_terminal_once",
            result.stdout,
        )

    def test_request_timeout_fires_without_inbound_traffic(self) -> None:
        result = run_lua_case("sync_request_timeout_fires_without_inbound_traffic")
        self.assertIn("PASS sync_request_timeout_fires_without_inbound_traffic", result.stdout)

    def test_request_cleanup_is_context_scoped(self) -> None:
        result = run_lua_case("sync_request_cleanup_is_context_scoped")
        self.assertIn("PASS sync_request_cleanup_is_context_scoped", result.stdout)

    def test_timeout_revokes_only_correlated_push_consent(self) -> None:
        result = run_lua_case("sync_timeout_revokes_only_correlated_push_consent")
        self.assertIn("PASS sync_timeout_revokes_only_correlated_push_consent", result.stdout)

    def test_real_db_syncer_consumes_push_consent_once(self) -> None:
        result = run_lua_case("real_db_syncer_consumes_push_consent_once")

        self.assertIn("PASS real_db_syncer_consumes_push_consent_once", result.stdout)

    def test_real_db_syncer_releases_failed_push_consent(self) -> None:
        result = run_lua_case("real_db_syncer_releases_failed_push_consent")

        self.assertIn("PASS real_db_syncer_releases_failed_push_consent", result.stdout)

    def test_correlated_push_retries_after_import_failure(self) -> None:
        result = run_lua_case("real_db_syncer_retries_correlated_push_after_import_failure")

        self.assertIn("PASS real_db_syncer_retries_correlated_push_after_import_failure", result.stdout)

    def test_correlated_push_retries_after_decode_and_parse_failure(self) -> None:
        result = run_lua_case(
            "real_db_syncer_retries_correlated_push_after_decode_and_parse_failure"
        )

        self.assertIn(
            "PASS real_db_syncer_retries_correlated_push_after_decode_and_parse_failure",
            result.stdout,
        )

    def test_correlated_push_is_rejected_after_request_timeout(self) -> None:
        result = run_lua_case("real_db_syncer_rejects_correlated_push_after_request_timeout")

        self.assertIn("PASS real_db_syncer_rejects_correlated_push_after_request_timeout", result.stdout)

    def test_push_configuration_has_effective_runtime_semantics(self) -> None:
        source = DB_SYNCER.read_text(encoding="utf-8")

        self.assertIn('loggerOptions:Get("syncRequirePlayer")', source)
        self.assertIn('loggerOptions:Get("syncPushPlayer")', source)

    def test_db_syncer_has_no_authorization_grace_or_whisper_fail_open(self) -> None:
        source = DB_SYNCER.read_text(encoding="utf-8")

        self.assertNotIn("SYNC_OFFICER_LOOKUP_GRACE_SECONDS", source)
        self.assertIn("isCurrentGroupMember(rawSender)", source)

    def test_sync_payload_validation_rejects_invalid_and_stale_revisions(self) -> None:
        result = run_lua_case("sync_payload_validation_rejects_invalid_and_stale_revisions")

        self.assertIn("PASS sync_payload_validation_rejects_invalid_and_stale_revisions", result.stdout)

    def test_sync_history_import_is_atomic_across_build_and_commit_failures(self) -> None:
        result = run_lua_case("sync_history_import_is_atomic_across_build_and_commit_failures")

        self.assertIn("PASS sync_history_import_is_atomic_across_build_and_commit_failures", result.stdout)

    def test_notice_snapshot_round_trip_preserves_history_fields(self) -> None:
        result = run_lua_case("sync_notice_snapshot_round_trip_preserves_history_fields")
        self.assertIn("PASS sync_notice_snapshot_round_trip_preserves_history_fields", result.stdout)

    def test_late_join_bootstrap_replaces_unrelated_local_history(self) -> None:
        result = run_lua_case("sync_late_join_bootstrap_replaces_unrelated_local_history")

        self.assertIn("PASS sync_late_join_bootstrap_replaces_unrelated_local_history", result.stdout)

    def test_authoritative_bootstrap_rolls_back_atomically(self) -> None:
        result = run_lua_case("sync_authoritative_bootstrap_rolls_back_atomically")

        self.assertIn("PASS sync_authoritative_bootstrap_rolls_back_atomically", result.stdout)

    def test_sync_lineage_gates_incremental_delta(self) -> None:
        result = run_lua_case("sync_lineage_gates_incremental_delta")

        self.assertIn("PASS sync_lineage_gates_incremental_delta", result.stdout)

    def test_authoritative_delta_maps_source_to_local_raid(self) -> None:
        result = run_lua_case("sync_authoritative_delta_maps_source_to_local_raid")

        self.assertIn("PASS sync_authoritative_delta_maps_source_to_local_raid", result.stdout)

    def test_multipart_authority_change_rejects_completed_payload(self) -> None:
        result = run_lua_case("sync_multipart_authority_change_rejects_completed_payload")

        self.assertIn("PASS sync_multipart_authority_change_rejects_completed_payload", result.stdout)

    def test_multipart_bootstrap_rejects_replaced_local_raid(self) -> None:
        result = run_lua_case("sync_multipart_bootstrap_rejects_replaced_local_raid")

        self.assertIn("PASS sync_multipart_bootstrap_rejects_replaced_local_raid", result.stdout)

    def test_multipart_bootstrap_rejects_signature_drift(self) -> None:
        result = run_lua_case("sync_multipart_bootstrap_rejects_signature_drift")

        self.assertIn("PASS sync_multipart_bootstrap_rejects_signature_drift", result.stdout)

    def test_bootstrap_rejects_snapshot_header_signature_mismatch(self) -> None:
        result = run_lua_case("sync_bootstrap_rejects_snapshot_header_signature_mismatch")

        self.assertIn("PASS sync_bootstrap_rejects_snapshot_header_signature_mismatch", result.stdout)

    def test_sync_master_looter_is_authoritative_without_rank(self) -> None:
        result = run_lua_case("sync_master_looter_is_authoritative_without_rank")

        self.assertIn("PASS sync_master_looter_is_authoritative_without_rank", result.stdout)

    def test_sync_automatic_requests_allow_group_channels_only(self) -> None:
        result = run_lua_case("sync_automatic_requests_allow_group_channels_only")

        self.assertIn(
            "PASS sync_automatic_requests_allow_group_channels_only",
            result.stdout,
        )

    def test_sync_party_authority_rejects_members_and_outsiders(self) -> None:
        result = run_lua_case("sync_party_authority_rejects_members_and_outsiders")

        self.assertIn("PASS sync_party_authority_rejects_members_and_outsiders", result.stdout)

    def test_sync_v1_revision_zero_imports_through_real_store_without_regression(self) -> None:
        result = run_lua_case("sync_v1_revision_zero_imports_through_real_store_without_regression")

        self.assertIn("PASS sync_v1_revision_zero_imports_through_real_store_without_regression", result.stdout)

    def test_real_delta_builder_proves_complete_revision_coverage(self) -> None:
        result = run_lua_case("real_delta_builder_proves_complete_revision_coverage")

        self.assertIn("PASS real_delta_builder_proves_complete_revision_coverage", result.stdout)


if __name__ == "__main__":
    unittest.main()
