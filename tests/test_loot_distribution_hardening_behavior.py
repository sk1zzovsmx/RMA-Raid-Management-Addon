from pathlib import Path
import re
import unittest

from tests.lua_test_runner import run_lua_case

ROOT = Path(__file__).resolve().parents[1]


class LootDistributionHardeningTests(unittest.TestCase):
    def assert_case(self, name: str) -> None:
        result = run_lua_case(name)
        self.assertIn(f"PASS {name}", result.stdout)

    def test_award_freezes_roll_intake(self) -> None:
        self.assert_case("loot_award_freezes_roll_intake")

    def test_duplicate_award_is_rejected_in_flight(self) -> None:
        self.assert_case("loot_duplicate_award_is_rejected_in_flight")

    def test_direct_assignment_admits_before_mutation(self) -> None:
        self.assert_case("loot_direct_assignment_admits_before_mutation")

    def test_direct_assignment_rejects_in_flight_trade_before_mutation(self) -> None:
        self.assert_case("loot_direct_assignment_rejects_in_flight_trade_before_mutation")

    def test_award_attempt_checkpoints_are_retry_safe(self) -> None:
        self.assert_case("loot_award_attempt_checkpoints_are_retry_safe")

    def test_award_attempt_snapshots_supported_fields_only(self) -> None:
        self.assert_case("loot_award_attempt_snapshots_supported_fields_only")

    def test_award_confirmation_retains_uncertain_effect(self) -> None:
        self.assert_case("loot_award_confirmation_retains_uncertain_effect")

    def test_award_prerequisites_and_sequence_retry_are_ordered(self) -> None:
        self.assert_case("loot_award_prerequisites_and_sequence_retry_are_ordered")

    def test_award_sequence_schedule_failure_is_terminal(self) -> None:
        self.assert_case("loot_award_sequence_schedule_failure_is_terminal")

    def test_slot_clear_stops_after_matched_confirmation_failure(self) -> None:
        self.assert_case("loot_slot_clear_stops_after_matched_confirmation_failure")

    def test_award_confirmation_expiry_is_bounded(self) -> None:
        self.assert_case("loot_award_confirmation_expiry_is_bounded")

    def test_distribution_done_retries_wire_without_duplicate_state(self) -> None:
        self.assert_case("loot_distribution_done_retries_wire_without_duplicate_state")

    def test_remote_final_award_carries_complete_facts_and_is_idempotent(self) -> None:
        self.assert_case("loot_distribution_remote_final_award_is_complete_and_idempotent")

    def test_split_master_looter_publishes_final_facts_without_local_writes(self) -> None:
        self.assert_case("loot_master_split_authority_publishes_final_facts_without_local_writes")

    def test_split_master_looter_cancels_local_delayed_attribution(self) -> None:
        self.assert_case("loot_master_split_authority_cancels_local_delayed_attribution")

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

    def test_attribution_schedule_failure_finalizes_once(self) -> None:
        self.assert_case("loot_attribution_schedule_failure_finalizes_once")

    def test_attribution_terminal_callbacks_are_contained(self) -> None:
        self.assert_case("loot_attribution_terminal_callbacks_are_contained")

    def test_master_warns_once_when_authoritative_reconciliation_fails(self) -> None:
        self.assert_case("loot_master_warns_once_when_authoritative_reconciliation_fails")

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

    def test_distribution_r5_snapshot_chunks_reassemble_and_fail_closed(self) -> None:
        self.assert_case("loot_distribution_r5_snapshot_chunks_and_rejections")

    def test_distribution_ordered_flow_uses_one_normal_queue(self) -> None:
        self.assert_case("loot_distribution_ordered_flow_uses_one_normal_queue")

    def test_distribution_r5_rejects_invalid_body_scalars(self) -> None:
        self.assert_case("loot_distribution_r5_rejects_invalid_body_scalars")

    def test_distribution_snapshot_requests_are_correlated_and_bounded(self) -> None:
        self.assert_case("loot_distribution_snapshot_requests_are_correlated_and_bounded")

    def test_distribution_ownership_and_session_end_are_retry_safe(self) -> None:
        self.assert_case("loot_distribution_ownership_and_session_end_are_retry_safe")

    def test_loot_fetch_propagates_distribution_failure(self) -> None:
        self.assert_case("loot_fetch_propagates_distribution_failure")

    def test_distribution_clear_requires_ordered_owner_transition(self) -> None:
        self.assert_case("loot_distribution_clear_requires_ordered_owner_transition")

    def test_distribution_generated_session_order_is_validated(self) -> None:
        self.assert_case("loot_distribution_generated_session_order_is_validated")

    def test_distribution_authority_handoff_without_provenance_is_validated(self) -> None:
        self.assert_case("loot_distribution_authority_handoff_without_provenance_is_validated")

    def test_trade_inventory_evidence_requires_a_positive_delta(self) -> None:
        self.assert_case("loot_trade_inventory_evidence_requires_a_positive_delta")

    def test_inventory_canonical_match_and_required_count(self) -> None:
        self.assert_case("loot_inventory_canonical_match_and_required_count")

    def test_award_trade_event_order_is_evidence_gated(self) -> None:
        self.assert_case("loot_award_trade_event_order_is_evidence_gated")

    def test_trader_keep_uses_award_callback_contract(self) -> None:
        self.assert_case("loot_trader_keep_uses_award_callback_contract")

    def test_split_master_looter_trade_finalizes_without_local_canonical_writes(self) -> None:
        self.assert_case("loot_split_master_trade_finalizes_without_local_canonical_writes")

    def test_trade_rejects_second_in_flight(self) -> None:
        self.assert_case("loot_trade_rejects_second_in_flight")

    def test_out_of_range_trade_can_retry(self) -> None:
        self.assert_case("loot_out_of_range_trade_can_retry")

    def test_trade_required_count_tracks_placed_stack(self) -> None:
        self.assert_case("loot_trade_required_count_tracks_placed_stack")

    def test_trade_close_retries_once_after_bag_update(self) -> None:
        self.assert_case("loot_trade_close_retries_once_after_bag_update")

    def test_trade_menu_is_manual_only(self) -> None:
        self.assert_case("loot_trade_menu_is_manual_only")

    def test_recovery_of_recovery_state_is_absent(self) -> None:
        owner_paths = (
            ROOT / "Raid Management Addon" / "Controllers" / "Master.lua",
            ROOT / "Raid Management Addon" / "Services" / "Master" / "AwardConfirmation.lua",
            ROOT / "Raid Management Addon" / "Services" / "Master" / "TradeExecution.lua",
            ROOT / "Raid Management Addon" / "Services" / "Loot" / "LootAttribution.lua",
        )
        forbidden = tuple(
            "".join(parts)
            for parts in (
                ("Retry", "PendingResolution"),
                ("Retry", "Finalization"),
                ("Retry", "TerminalPublication"),
                ("record_finalization", "_exhausted"),
                ("authoritative_reconciliation", "_exhausted"),
                ("publication", "_retrying"),
                ("publication", "_exhausted"),
                ("provisional_capacity", "_exhausted"),
            )
        )
        for path in owner_paths:
            source = path.read_text(encoding="utf-8")
            for identifier in forbidden:
                self.assertNotIn(identifier, source, f"{identifier} leaked into {path}")

    def test_loot_chat_has_one_canonical_entrypoint_without_pass_through_wrappers(self) -> None:
        addon = ROOT / "Raid Management Addon"
        init_source = (addon / "Init.lua").read_text(encoding="utf-8")
        service_source = (addon / "Services" / "Loot" / "Service.lua").read_text(encoding="utf-8")
        runtime_source = "\n".join(
            path.read_text(encoding="utf-8")
            for path in addon.rglob("*.lua")
            if "Libs" not in path.parts
        )

        self.assertIn("lootService:HandleLootChatMessage(msg, winnerOnly)", init_source)
        self.assertIsNotNone(
            re.search(
                r"assert\(\s*lootService and lootService\.HandleLootChatMessage",
                init_source,
            )
        )
        self.assertNotIn("type(PassiveGroupLoot.ParseGroupLootMessage)", service_source)
        self.assertNotIn("type(PassiveGroupLoot.ApplyGroupLootObservation)", service_source)

        retired_entrypoints = (
            "ObservePassiveLootMessage",
            "AddGroupLootMessage",
            "ObserveGroupLootMessage",
            "ObserveGroupLootWinnerMessage",
        )
        for entrypoint in retired_entrypoints:
            self.assertNotIn(entrypoint, runtime_source)

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
