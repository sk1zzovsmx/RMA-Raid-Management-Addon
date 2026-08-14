import unittest

from tests.lua_test_runner import run_lua_case


class LootDistributionHardeningTests(unittest.TestCase):
    def assert_case(self, name: str) -> None:
        result = run_lua_case(name)
        self.assertIn(f"PASS {name}", result.stdout)

    def test_award_freezes_roll_intake(self) -> None:
        self.assert_case("loot_award_freezes_roll_intake")

    def test_duplicate_award_is_rejected_in_flight(self) -> None:
        self.assert_case("loot_duplicate_award_is_rejected_in_flight")

    def test_award_attempt_checkpoints_are_retry_safe(self) -> None:
        self.assert_case("loot_award_attempt_checkpoints_are_retry_safe")

    def test_award_confirmation_retains_uncertain_effect(self) -> None:
        self.assert_case("loot_award_confirmation_retains_uncertain_effect")

    def test_award_prerequisites_and_sequence_retry_are_ordered(self) -> None:
        self.assert_case("loot_award_prerequisites_and_sequence_retry_are_ordered")

    def test_slot_clear_stops_after_matched_confirmation_failure(self) -> None:
        self.assert_case("loot_slot_clear_stops_after_matched_confirmation_failure")

    def test_award_confirmation_expiry_is_bounded(self) -> None:
        self.assert_case("loot_award_confirmation_expiry_is_bounded")

    def test_distribution_done_retries_wire_without_duplicate_state(self) -> None:
        self.assert_case("loot_distribution_done_retries_wire_without_duplicate_state")

    def test_award_confirmation_expiry_survives_presentation_failures(self) -> None:
        self.assert_case("loot_award_confirmation_expiry_survives_presentation_failures")

    def test_award_finalize_and_single_reset_are_retry_safe(self) -> None:
        self.assert_case("loot_award_finalize_and_single_reset_are_retry_safe")

    def test_loot_inventory_slot_validation_is_strict(self) -> None:
        self.assert_case("loot_inventory_slot_validation_is_strict")

    def test_loot_attribution_cancellation_is_transaction_scoped(self) -> None:
        self.assert_case("loot_attribution_cancellation_is_transaction_scoped")

    def test_loot_award_attribution_event_order_is_atomic(self) -> None:
        self.assert_case("loot_award_attribution_event_order_is_atomic")

    def test_loot_service_stages_authoritative_before_consumption(self) -> None:
        self.assert_case("loot_service_stages_authoritative_before_consumption")

    def test_loot_award_event_orders_share_full_production_chain(self) -> None:
        self.assert_case("loot_award_event_orders_share_full_production_chain")

    def test_master_effect_boundary_is_failure_safe(self) -> None:
        self.assert_case("loot_master_effect_boundary_is_failure_safe")

    def test_master_success_and_timeout_follow_confirmation_evidence(self) -> None:
        self.assert_case("loot_master_success_and_timeout_follow_confirmation_evidence")

    def test_master_announcement_failure_is_retry_safe(self) -> None:
        self.assert_case("loot_master_announcement_failure_is_retry_safe")

    def test_distribution_window_sender_is_atomic(self) -> None:
        self.assert_case("loot_distribution_window_sender_is_atomic")

    def test_distribution_window_receiver_is_session_scoped(self) -> None:
        self.assert_case("loot_distribution_window_receiver_is_session_scoped")

    def test_distribution_snapshot_cannot_resurrect_ended_session(self) -> None:
        self.assert_case("loot_distribution_snapshot_cannot_resurrect_ended_session")

    def test_distribution_ownership_and_session_end_are_retry_safe(self) -> None:
        self.assert_case("loot_distribution_ownership_and_session_end_are_retry_safe")

    def test_loot_fetch_propagates_distribution_failure(self) -> None:
        self.assert_case("loot_fetch_propagates_distribution_failure")

    def test_distribution_clear_requires_ordered_owner_transition(self) -> None:
        self.assert_case("loot_distribution_clear_requires_ordered_owner_transition")

    def test_trade_inventory_evidence_requires_a_positive_delta(self) -> None:
        self.assert_case("loot_trade_inventory_evidence_requires_a_positive_delta")

    def test_award_trade_event_order_is_evidence_gated(self) -> None:
        self.assert_case("loot_award_trade_event_order_is_evidence_gated")

    def test_manual_hold_trade_requires_inventory_evidence(self) -> None:
        self.assert_case("loot_manual_hold_trade_requires_inventory_evidence")

    def test_multi_award_cancellation_preserves_current_and_future_admission(self) -> None:
        self.assert_case("loot_multi_award_cancellation_preserves_current_and_future_admission")

    def test_multi_award_clear_button_is_truthful(self) -> None:
        self.assert_case("loot_multi_award_clear_button_is_truthful")

    def test_slot_clear_perf_spans_close_on_all_exits(self) -> None:
        self.assert_case("loot_slot_clear_perf_spans_close_on_all_exits")

    def test_multi_award_twenty_slot_work_is_bounded(self) -> None:
        self.assert_case("loot_multi_award_twenty_slot_work_is_bounded")
