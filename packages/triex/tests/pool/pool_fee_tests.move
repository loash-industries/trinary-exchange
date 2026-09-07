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
fun test_admin_can_sweep_locked_maker_fees_until_triex138() {
    pool_test_utils::test_admin_can_sweep_locked_maker_fees_until_triex138();
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
