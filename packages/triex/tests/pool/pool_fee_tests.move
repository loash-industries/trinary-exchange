// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::pool_fee_tests {
    use triexbook::pool_test_utils;

    #[test]
    fun test_bid_with_quote_fees_updates_vault_reserve() {
        pool_test_utils::test_bid_with_quote_fees_updates_vault_reserve();
    }

    #[test]
    fun test_admin_withdraws_quote_fee_reserve() {
        pool_test_utils::test_admin_withdraws_quote_fee_reserve();
    }

    #[test]
    fun test_ask_cancel_leaves_bid_escrow_intact() {
        pool_test_utils::test_ask_cancel_leaves_bid_escrow_intact();
    }

    #[test]
    fun test_modify_down_releases_escrow_proportionally() {
        pool_test_utils::test_modify_down_releases_escrow_proportionally();
    }

    #[test]
    fun test_admin_sweep_takes_unlocked_portion() {
        pool_test_utils::test_admin_sweep_takes_unlocked_portion();
    }

    #[test]
    #[expected_failure(abort_code = triexbook::vault::EFeesLocked)]
    fun test_admin_sweep_above_unlocked_portion_aborts() {
        pool_test_utils::test_admin_sweep_above_unlocked_portion_aborts();
    }

    #[test]
    fun test_expired_bid_maker_releases_escrow() {
        pool_test_utils::test_expired_bid_maker_releases_escrow();
    }

    #[test]
    fun test_locked_fee_escrow_tracks_open_orders() {
        pool_test_utils::test_locked_fee_escrow_tracks_open_orders();
    }

    #[test]
    #[expected_failure(abort_code = triexbook::vault::EFeesLocked)]
    fun test_admin_cannot_sweep_locked_maker_fees() {
        pool_test_utils::test_admin_cannot_sweep_locked_maker_fees();
    }

    #[test]
    fun test_admin_can_sweep_maker_fees_once_filled() {
        pool_test_utils::test_admin_can_sweep_maker_fees_once_filled();
    }

    #[test]
    fun test_bid_fee_reaches_reserve_when_settled_covers_owed() {
        pool_test_utils::test_bid_fee_reaches_reserve_when_settled_covers_owed();
    }

    #[test]
    fun test_bid_fee_reaches_reserve_when_settled_partially_covers_owed() {
        pool_test_utils::test_bid_fee_reaches_reserve_when_settled_partially_covers_owed();
    }

    #[test]
    fun test_fractional_basis_point_fees_are_charged_as_configured() {
        pool_test_utils::test_fractional_basis_point_fees_are_charged_as_configured();
    }

    #[test]
    fun test_ask_taker_fee_conservation() {
        pool_test_utils::test_ask_taker_fee_conservation();
    }

    #[test]
    fun test_ask_maker_fill_fee_uses_snapshotted_rate() {
        pool_test_utils::test_ask_maker_fill_fee_uses_snapshotted_rate();
    }

    #[test]
    fun test_cancel_refunds_escrow_to_maker() {
        pool_test_utils::test_cancel_refunds_escrow_to_maker();
    }

    #[test]
    fun test_cancel_after_partial_fill_refunds_unfilled_only() {
        pool_test_utils::test_cancel_after_partial_fill_refunds_unfilled_only();
    }

    #[test]
    fun test_cancel_uses_snapshotted_retention_rate() {
        pool_test_utils::test_cancel_uses_snapshotted_retention_rate();
    }

    #[test]
    fun test_expired_bid_maker_is_refunded() {
        pool_test_utils::test_expired_bid_maker_is_refunded();
    }

    #[test]
    fun test_cancel_and_refund_events_agree() {
        pool_test_utils::test_cancel_and_refund_events_agree();
    }

    #[test]
    fun test_expiry_refund_event_attributes_the_maker() {
        pool_test_utils::test_expiry_refund_event_attributes_the_maker();
    }

    #[test]
    fun test_cancel_refund_survives_sweep_to_the_floor() {
        pool_test_utils::test_cancel_refund_survives_sweep_to_the_floor();
    }

    #[test]
    fun test_repeated_modify_downs_then_cancel_stay_solvent() {
        pool_test_utils::test_repeated_modify_downs_then_cancel_stay_solvent();
    }

    #[test]
    fun test_many_partial_fills_then_cancel_stay_solvent() {
        pool_test_utils::test_many_partial_fills_then_cancel_stay_solvent();
    }

    #[test]
    fun test_multiple_expired_makers_each_get_their_own_refund() {
        pool_test_utils::test_multiple_expired_makers_each_get_their_own_refund();
    }

    #[test]
    fun test_expired_ask_maker_refunds_nothing() {
        pool_test_utils::test_expired_ask_maker_refunds_nothing();
    }

    #[test]
    fun test_self_match_cancel_maker_refunds_the_bid_escrow() {
        pool_test_utils::test_self_match_cancel_maker_refunds_the_bid_escrow();
    }

    #[test]
    fun test_cancel_all_orders_refunds_every_bid() {
        pool_test_utils::test_cancel_all_orders_refunds_every_bid();
    }

    #[test]
    fun test_zero_retention_refunds_the_whole_escrow() {
        pool_test_utils::test_zero_retention_refunds_the_whole_escrow();
    }

    #[test]
    fun test_refund_rounding_dust_favors_the_retention() {
        pool_test_utils::test_refund_rounding_dust_favors_the_retention();
    }

    // === Conservation of funds ===

    #[test]
    fun test_multi_maker_sweep_conserves_funds() {
        pool_test_utils::test_multi_maker_sweep_conserves_funds();
    }

    #[test]
    fun test_dust_accumulation_stays_bounded() {
        pool_test_utils::test_dust_accumulation_stays_bounded();
    }

    // === Fee tiers (TRIEX-137) ===

    #[test]
    fun test_resting_bid_earns_no_tier_progress() {
        pool_test_utils::test_resting_bid_earns_no_tier_progress();
    }

    #[test]
    fun test_fill_accrues_turnover_to_both_sides() {
        pool_test_utils::test_fill_accrues_turnover_to_both_sides();
    }

    #[test]
    fun test_bid_taker_fill_accrues_turnover() {
        pool_test_utils::test_bid_taker_fill_accrues_turnover();
    }

    #[test]
    fun test_tier_discount_applies_from_the_next_order() {
        pool_test_utils::test_tier_discount_applies_from_the_next_order();
    }

    #[test]
    fun test_fee_schedule_activates_next_epoch() {
        pool_test_utils::test_fee_schedule_activates_next_epoch();
    }

    #[test]
    fun test_flat_fee_setter_keeps_schedule_in_lockstep() {
        pool_test_utils::test_flat_fee_setter_keeps_schedule_in_lockstep();
    }

    #[test]
    fun test_turnover_ages_out_after_the_window() {
        pool_test_utils::test_turnover_ages_out_after_the_window();
    }

    #[test]
    fun test_turnover_survives_to_the_window_edge() {
        pool_test_utils::test_turnover_survives_to_the_window_edge();
    }

    #[test]
    fun test_resting_order_keeps_placement_rate_across_schedule_change() {
        pool_test_utils::test_resting_order_keeps_placement_rate_across_schedule_change();
    }

    #[test]
    fun test_resting_order_keeps_placement_rate_across_tier_promotion() {
        pool_test_utils::test_resting_order_keeps_placement_rate_across_tier_promotion();
    }

    #[test]
    fun test_expired_bid_maker_accrues_no_turnover() {
        pool_test_utils::test_expired_bid_maker_accrues_no_turnover();
    }

    #[test]
    fun test_modify_down_accrues_no_turnover() {
        pool_test_utils::test_modify_down_accrues_no_turnover();
    }

    #[test]
    fun test_partial_fill_accrues_only_the_filled_portion() {
        pool_test_utils::test_partial_fill_accrues_only_the_filled_portion();
    }

    #[test]
    fun test_each_maker_accrues_only_their_own_fee() {
        pool_test_utils::test_each_maker_accrues_only_their_own_fee();
    }

    #[test]
    fun test_untouched_account_reports_entry_tier() {
        pool_test_utils::test_untouched_account_reports_entry_tier();
    }

    #[test]
    #[expected_failure(abort_code = triexbook::fee_policy::EInvalidCancelRetention)]
    fun test_schedule_setter_rejects_retention_above_full() {
        pool_test_utils::test_schedule_setter_rejects_retention_above_full();
    }

    #[test]
    #[expected_failure(abort_code = triexbook::fee_schedule::EThresholdsNotAscending)]
    fun test_schedule_setter_rejects_descending_thresholds() {
        pool_test_utils::test_schedule_setter_rejects_descending_thresholds();
    }

    #[test]
    #[expected_failure(abort_code = triexbook::fee_schedule::ETakerRateNotMonotone)]
    fun test_schedule_setter_rejects_rising_taker_rate() {
        pool_test_utils::test_schedule_setter_rejects_rising_taker_rate();
    }
}
