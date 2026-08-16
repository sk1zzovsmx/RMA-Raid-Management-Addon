from __future__ import annotations

from pathlib import Path
import unittest

from tests.lua_test_runner import run_lua_case


ROOT = Path(__file__).resolve().parents[1]
DB_SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"
LOGGER = ROOT / "Raid Management Addon" / "Controllers" / "Logger.lua"
LIST_CONTROLLER = ROOT / "Raid Management Addon" / "Modules" / "UI" / "ListController.lua"


class SyncCommunicationsBehaviorTests(unittest.TestCase):
    def assert_case(self, case_name: str) -> None:
        result = run_lua_case(case_name)
        self.assertIn(f"PASS {case_name}", result.stdout)

    def test_authoritative_event_replicates_between_independent_clients(self) -> None:
        self.assert_case("raid_live_sync_event")

    def test_oversized_real_protocol_event_falls_back_to_head_and_converges(self) -> None:
        self.assert_case("raid_live_sync_oversized_event_head_fallback")

    def test_compact_live_loot_broadcast_advances_every_aligned_replica(self) -> None:
        self.assert_case("raid_live_loot_broadcast_advances_multiple_replicas")

    def test_lost_final_live_loot_recovers_from_consolidated_head(self) -> None:
        self.assert_case("raid_live_loot_lost_final_recovers_from_trailing_head")

    def test_missing_event_recovers_one_contiguous_range(self) -> None:
        self.assert_case("raid_live_sync_range_recovery")

    def test_late_join_bootstraps_by_snapshot(self) -> None:
        self.assert_case("raid_live_sync_snapshot_bootstrap")

    def test_snapshot_bootstrap_coalesces_newer_event_burst(self) -> None:
        self.assert_case("raid_live_sync_snapshot_coalesces_newer_event_burst")

    def test_snapshot_bootstrap_coalesces_newer_snapshot_burst(self) -> None:
        self.assert_case("raid_live_sync_snapshot_coalesces_newer_snapshot_burst")

    def test_snapshot_follow_up_digest_conflict_cancels_recovery(self) -> None:
        self.assert_case("raid_live_sync_snapshot_follow_up_digest_conflict")

    def test_returning_leader_without_a_local_uid_requires_replica_consensus(self) -> None:
        self.assert_case("raid_leader_reentry_unknown_uid_requires_consensus")

    def test_returning_leader_reentry_uses_one_immediate_head_request_and_one_retry(self) -> None:
        self.assert_case("raid_leader_reentry_retry_is_bounded")

    def test_unavailable_range_falls_back_to_snapshot(self) -> None:
        self.assert_case("raid_live_sync_range_snapshot_fallback")

    def test_missed_pre_conclusion_event_recovers_from_bounded_final_snapshot(self) -> None:
        self.assert_case("raid_live_sync_conclusion_snapshot_recovery")

    def test_real_session_future_conclusion_requests_snapshot_without_range_or_retry(self) -> None:
        self.assert_case("raid_live_sync_real_session_future_conclusion")

    def test_real_session_final_head_repairs_and_compacts_without_conclusion_event(self) -> None:
        self.assert_case("raid_live_sync_real_session_final_head")

    def test_real_session_coalesces_future_conclusion_event_and_final_head(self) -> None:
        self.assert_case("raid_live_sync_real_session_conclusion_coalescing")

    def test_real_session_coalesces_identical_range_recovery(self) -> None:
        self.assert_case("raid_live_sync_real_session_range_coalescing")

    def test_range_recovery_coalesces_newer_head_burst(self) -> None:
        self.assert_case("raid_live_sync_range_coalesces_newer_head_burst")

    def test_real_session_newer_conclusion_supersedes_pending_range(self) -> None:
        self.assert_case("raid_live_sync_real_session_monotonic_supersession")

    def test_rate_limited_live_recovery_retries_latest_head_once(self) -> None:
        self.assert_case("raid_live_sync_retries_latest_rate_limited_head")

    def test_retained_live_retry_ignores_a_delayed_older_head(self) -> None:
        self.assert_case("raid_live_sync_retained_retry_ignores_delayed_head")

    def test_retained_live_retry_rejects_a_delayed_digest_conflict(self) -> None:
        self.assert_case("raid_live_sync_retained_retry_rejects_delayed_digest_conflict")

    def test_real_store_event_clears_its_admission_retry(self) -> None:
        self.assert_case("raid_live_sync_real_store_event_clears_admission_retry")

    def test_digest_mismatch_clears_live_admission_retry(self) -> None:
        self.assert_case("raid_live_sync_digest_mismatch_clears_admission_retry")

    def test_unavailable_admission_retry_timer_is_terminal(self) -> None:
        self.assert_case("raid_live_sync_admission_retry_timer_unavailable_is_terminal")

    def test_real_session_direct_event_cancels_obsolete_recovery(self) -> None:
        self.assert_case("raid_live_sync_real_session_direct_event_cancellation")

    def test_real_store_pending_head_digest_conflict_cancels_recovery(self) -> None:
        self.assert_case("raid_live_sync_real_store_pending_head_digest_conflict")

    def test_real_store_pending_event_digest_conflict_cancels_before_apply(self) -> None:
        self.assert_case("raid_live_sync_real_store_pending_event_digest_conflict")

    def test_complete_head_never_bootstraps_missing_or_different_live_uid(self) -> None:
        self.assert_case("raid_live_sync_complete_head_consent_boundary")

    def test_expired_or_unrelated_final_snapshot_is_not_history_sync(self) -> None:
        self.assert_case("raid_live_sync_conclusion_snapshot_scope")

    def test_matching_persisted_head_sends_no_request(self) -> None:
        self.assert_case("raid_live_sync_reload_noop")

    def test_untrusted_sender_and_old_epoch_fail_closed(self) -> None:
        self.assert_case("raid_live_sync_authority_rejection")

    def test_non_raid_leader_client_cannot_originate_local_event(self) -> None:
        self.assert_case("raid_live_sync_local_authority_guard")

    def test_raid_leader_role_and_normalized_identity_must_agree(self) -> None:
        self.assert_case("raid_live_sync_authority_requires_role_identity_agreement")

    def test_same_position_with_different_digest_suspends(self) -> None:
        self.assert_case("raid_live_sync_digest_conflict")

    def test_runtime_has_one_v3_prefix_and_no_polling_or_beta_dispatch(self) -> None:
        source = DB_SYNCER.read_text(encoding="utf-8")
        self.assertIn('COMM_PREFIX = "RMARaidSync"', source)
        self.assertNotIn('COMM_PREFIX = "RMALogSync"', source)
        self.assertNotIn("PERSISTENT_SYNC_INTERVAL", source)

    def test_raid_archive_quarantine_has_one_pre_transport_admission_boundary(self) -> None:
        source = DB_SYNCER.read_text(encoding="utf-8")
        self.assertIn("local function admitRaidHistorySync", source)
        self.assertIn("Database.SavedVariables", source)
        self.assertIn("GetRaidArchiveError", source)
        self.assertIn("RaidSyncStatusQuarantined", source)
        self.assertIn('COMM_PREFIX = "RMARaidSync"', source)
        self.assertIn("Protocol.VERSION == 5", source)
        self.assertNotIn("RMA_Raids", source)

    def test_quarantine_suspends_raid_sync_without_touching_other_handlers(self) -> None:
        self.assert_case("raid_history_quarantine_suspends_only_raid_sync")

    def test_logger_lists_use_shared_layout_primitives_without_behavior_drift(self) -> None:
        self.assert_case("logger_lists_use_shared_layout_primitives_without_behavior_drift")
        logger = LOGGER.read_text(encoding="utf-8")
        shared = LIST_CONTROLLER.read_text(encoding="utf-8")
        for owned_symbol in (
            "LoggerLayout",
            "RAID_LAYOUT_COLUMNS",
            "LOOT_LAYOUT_COLUMNS",
            'headerExtraWidthKey = "icon"',
            'hitBoxKey = "SourceHitBox"',
            "updateSourceHeaderState",
            "getLootEmptyStateText",
            "buildSourceTooltipModel",
        ):
            self.assertIn(owned_symbol, logger)
            self.assertNotIn(owned_symbol, shared)

    def test_transfer_session_retries_once_then_fails_once(self) -> None:
        self.assert_case("raid_transfer_session_retry")

    def test_transfer_session_enqueues_one_atomic_batch(self) -> None:
        self.assert_case("raid_transfer_session_atomic_batch")

    def test_snapshot_transfer_rechunks_below_the_safe_addon_wire_limit(self) -> None:
        self.assert_case("raid_transfer_session_rechunks_snapshot_at_safe_wire_limit")

    def test_transfer_session_rate_limits_have_exact_boundaries(self) -> None:
        # Covers independently bounded live and historical transfer budgets.
        self.assert_case("raid_transfer_session_rate_limits")

    def test_shared_wire_codec_round_trips_and_fails_closed(self) -> None:
        self.assert_case("comms_shared_wire_codec_round_trip_and_rejection")

    def test_comms_routes_prioritized_flows_through_chat_throttle(self) -> None:
        self.assert_case("comms_chat_throttle_priority_and_queue_names")

    def test_comms_transport_options_fail_closed(self) -> None:
        self.assert_case("comms_transport_options_fail_closed")

    def test_comms_batch_preflight_prevents_malformed_partial_enqueue(self) -> None:
        self.assert_case("comms_batch_preflight_prevents_malformed_partial_enqueue")

    def test_comms_rejects_invalid_addon_message_destinations_before_enqueue(self) -> None:
        self.assert_case("comms_addon_destination_validation")

    def test_comms_version_r5_envelope_and_alert_ack(self) -> None:
        self.assert_case("comms_version_r5_envelope_and_alert_ack")

    def test_reserves_r5_envelopes_chunks_reassemble_and_fail_closed(self) -> None:
        self.assert_case("reserves_sync_r5_envelopes_chunks_and_rejections")

    def test_reserves_done_before_chunks_and_foreign_error_are_safe(self) -> None:
        self.assert_case("reserves_sync_done_before_chunks_and_foreign_error_are_safe")

    def test_reserves_metadata_requests_are_correlated_and_bounded(self) -> None:
        self.assert_case("reserves_sync_metadata_requests_are_correlated_and_bounded")

    def test_reserves_incoming_requests_are_rate_limited_before_response_work(self) -> None:
        self.assert_case("reserves_sync_incoming_requests_are_rate_limited_before_response_work")

    def test_reserves_assembly_admission_is_globally_and_per_sender_bounded(self) -> None:
        self.assert_case("reserves_sync_assembly_admission_is_globally_and_per_sender_bounded")

    def test_real_raid_capabilities_accept_numeric_unit_identity(self) -> None:
        self.assert_case("raid_capabilities_accept_numeric_unit_identity")

    def test_request_id_generation_remains_owned_by_session(self) -> None:
        comms = (ROOT / "Raid Management Addon" / "Modules" / "Comms.lua").read_text(encoding="utf-8")
        session = (ROOT / "Raid Management Addon" / "Database" / "DBSyncSession.lua").read_text(encoding="utf-8")
        self.assertNotIn("function Comms.NextRequestId", comms)
        self.assertIn("local function nextRequestId", session)

    def test_syncer_loads_after_raid_capabilities_dependency(self) -> None:
        toc = (ROOT / "Raid Management Addon" / "Raid Management Addon.toc").read_text(encoding="utf-8")
        store_at = toc.index("Database\\DBRaidStore.lua")
        syncer_at = toc.index("Database\\DBSyncer.lua")
        capability_at = toc.index("Services\\Raid\\Capabilities.lua")
        self.assertLess(store_at, capability_at)
        self.assertLess(capability_at, syncer_at)
        source = DB_SYNCER.read_text(encoding="utf-8")
        self.assertIn(
            "local Raid = assert(Services.Raid, Diag.A.RaidServiceDependencyNotInitialized)",
            source,
        )
        self.assertIn("Raid:GetRaidLeaderName()", source)
        self.assertIn("RaidStore:SetAuthorityGuard", source)
        self.assertIn("Raid:IsRaidLeader() == true", source)
        self.assertNotIn("Raid:GetMasterLooterName()", source)
        self.assertNotIn("Raid:IsMasterLooter()", source)


if __name__ == "__main__":
    unittest.main()
