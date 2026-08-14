from __future__ import annotations

from pathlib import Path
import unittest

from tests.lua_test_runner import run_lua_case


ROOT = Path(__file__).resolve().parents[1]
DB_SYNCER = ROOT / "Raid Management Addon" / "Database" / "DBSyncer.lua"


class SyncCommunicationsBehaviorTests(unittest.TestCase):
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

    def test_real_comms_batch_preflight_prevents_partial_enqueue(self) -> None:
        result = run_lua_case("comms_batch_preflight_prevents_partial_enqueue")

        self.assertIn("PASS comms_batch_preflight_prevents_partial_enqueue", result.stdout)

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

    def test_sync_v1_revision_zero_imports_through_real_store_without_regression(self) -> None:
        result = run_lua_case("sync_v1_revision_zero_imports_through_real_store_without_regression")

        self.assertIn("PASS sync_v1_revision_zero_imports_through_real_store_without_regression", result.stdout)

    def test_real_delta_builder_proves_complete_revision_coverage(self) -> None:
        result = run_lua_case("real_delta_builder_proves_complete_revision_coverage")

        self.assertIn("PASS real_delta_builder_proves_complete_revision_coverage", result.stdout)


if __name__ == "__main__":
    unittest.main()
