// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::pool_fee_tests;

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
