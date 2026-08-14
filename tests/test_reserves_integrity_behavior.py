import unittest

from tests.lua_test_runner import run_lua_case


class ReservesIntegrityBehaviorTests(unittest.TestCase):
    def test_reserve_lookup_preserves_identity_index_fallback_and_detached_state(self) -> None:
        result = run_lua_case("reserves_lookup_preserves_identity_index_fallback_and_detached_state")
        self.assertIn("PASS reserves_lookup_preserves_identity_index_fallback_and_detached_state", result.stdout)

    def test_failed_synced_mutations_do_not_promote_cache(self) -> None:
        result = run_lua_case("reserves_failed_synced_mutations_do_not_promote_cache")
        self.assertIn("PASS reserves_failed_synced_mutations_do_not_promote_cache", result.stdout)

    def test_sync_checksums_are_canonical_and_inbound_payloads_are_verified(self) -> None:
        result = run_lua_case("reserves_sync_checksums_and_payloads_are_verified")
        self.assertIn("PASS reserves_sync_checksums_and_payloads_are_verified", result.stdout)

    def test_sync_protocol_version_projection_and_chunks_fail_closed(self) -> None:
        result = run_lua_case("reserves_sync_protocol_projection_and_chunks_fail_closed")
        self.assertIn("PASS reserves_sync_protocol_projection_and_chunks_fail_closed", result.stdout)

    def test_async_import_snapshots_input_and_publishes_once(self) -> None:
        result = run_lua_case("reserves_async_import_snapshots_input_and_publishes_once")
        self.assertIn("PASS reserves_async_import_snapshots_input_and_publishes_once", result.stdout)

    def test_async_import_replacement_cancel_and_stale_callbacks_are_terminal(self) -> None:
        result = run_lua_case("reserves_async_import_replacement_cancel_and_stale_callbacks_are_terminal")
        self.assertIn(
            "PASS reserves_async_import_replacement_cancel_and_stale_callbacks_are_terminal",
            result.stdout,
        )

    def test_async_import_failure_rolls_back_and_callbacks_are_reentrant(self) -> None:
        result = run_lua_case("reserves_async_import_failure_rolls_back_and_callbacks_are_reentrant")
        self.assertIn(
            "PASS reserves_async_import_failure_rolls_back_and_callbacks_are_reentrant",
            result.stdout,
        )

    def test_async_import_rejects_noncanonical_and_sparse_sources(self) -> None:
        result = run_lua_case("reserves_async_import_rejects_noncanonical_and_sparse_sources")
        self.assertIn("PASS reserves_async_import_rejects_noncanonical_and_sparse_sources", result.stdout)

    def test_async_import_scheduler_failures_are_terminal(self) -> None:
        result = run_lua_case("reserves_async_import_scheduler_failures_are_terminal")
        self.assertIn("PASS reserves_async_import_scheduler_failures_are_terminal", result.stdout)

    def test_async_import_publish_failure_preserves_values_and_events(self) -> None:
        result = run_lua_case("reserves_async_import_publish_faults_rollback_exact_state")
        self.assertIn("PASS reserves_async_import_publish_faults_rollback_exact_state", result.stdout)

    def test_import_option_notification_observes_committed_state(self) -> None:
        result = run_lua_case("reserves_import_option_notification_is_post_commit")
        self.assertIn("PASS reserves_import_option_notification_is_post_commit", result.stdout)

    def test_import_limits_and_schema_fail_closed(self) -> None:
        result = run_lua_case("reserves_import_limits_and_schema_fail_closed")
        self.assertIn("PASS reserves_import_limits_and_schema_fail_closed", result.stdout)

    def test_bulk_edits_are_atomic(self) -> None:
        result = run_lua_case("reserves_bulk_edits_are_atomic")
        self.assertIn("PASS reserves_bulk_edits_are_atomic", result.stdout)

    def test_single_edits_publish_detached_values_atomically(self) -> None:
        result = run_lua_case("reserves_single_edits_rollback_exact_state")
        self.assertIn("PASS reserves_single_edits_rollback_exact_state", result.stdout)

    def test_add_player_reserve_is_transactional(self) -> None:
        result = run_lua_case("reserves_add_player_reserve_is_transactional")
        self.assertIn("PASS reserves_add_player_reserve_is_transactional", result.stdout)

    def test_alias_publication_is_transactional(self) -> None:
        result = run_lua_case("reserves_alias_publication_is_transactional")
        self.assertIn("PASS reserves_alias_publication_is_transactional", result.stdout)

    def test_direct_import_apis_revalidate_bounded_canonical_input(self) -> None:
        result = run_lua_case("reserves_direct_import_apis_revalidate_bounded_canonical_input")
        self.assertIn("PASS reserves_direct_import_apis_revalidate_bounded_canonical_input", result.stdout)

    def test_bulk_edit_ui_retains_failed_edits(self) -> None:
        result = run_lua_case("reserves_bulk_edit_ui_retains_failed_edits")
        self.assertIn("PASS reserves_bulk_edit_ui_retains_failed_edits", result.stdout)

    def test_whisper_admission_is_bounded_and_fail_closed(self) -> None:
        result = run_lua_case("reserves_whisper_admission_is_bounded_and_fail_closed")
        self.assertIn("PASS reserves_whisper_admission_is_bounded_and_fail_closed", result.stdout)

    def test_whisper_storage_identity_resolution_is_owner_bound(self) -> None:
        result = run_lua_case("reserves_whisper_storage_identity_resolution_is_owner_bound")
        self.assertIn("PASS reserves_whisper_storage_identity_resolution_is_owner_bound", result.stdout)


if __name__ == "__main__":
    unittest.main()
