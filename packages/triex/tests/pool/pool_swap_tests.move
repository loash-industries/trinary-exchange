// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::pool_swap_tests;

use triexbook::pool_test_utils;

#[test]
fun test_mid_price_ok() {
    pool_test_utils::test_mid_price_ok();
}

#[test]
fun test_swap_exact_amount_bid_ask() {
    pool_test_utils::test_swap_exact_amount_bid_ask();
}

#[test]
fun test_swap_exact_amount_ask_bid() {
    pool_test_utils::test_swap_exact_amount_ask_bid();
}

#[test]
fun test_swap_exact_amount_bid_ask_with_manager() {
    pool_test_utils::test_swap_exact_amount_bid_ask_with_manager();
}

#[test]
fun test_swap_exact_amount_ask_bid_with_manager() {
    pool_test_utils::test_swap_exact_amount_ask_bid_with_manager();
}

#[test]
fun test_swap_exact_amount_with_input_bid_ask() {
    pool_test_utils::test_swap_exact_amount_with_input_bid_ask();
}

#[test]
fun test_swap_exact_amount_with_input_ask_bid() {
    pool_test_utils::test_swap_exact_amount_with_input_ask_bid();
}

#[test]
fun test_swap_exact_not_fully_filled_bid_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_bid_ok();
}

#[test]
fun test_swap_exact_not_fully_filled_bid_with_manager_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_bid_with_manager_ok();
}

#[test]
fun test_swap_exact_not_fully_filled_ask_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_ask_ok();
}

#[test]
fun test_swap_exact_not_fully_filled_ask_with_manager_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_ask_with_manager_ok();
}

#[test]
fun test_swap_exact_not_fully_filled_bid_low_qty_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_bid_low_qty_ok();
}

#[test]
fun test_swap_exact_not_fully_filled_bid_with_manager_low_qty_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_bid_with_manager_low_qty_ok();
}

#[test]
fun test_swap_exact_not_fully_filled_ask_low_qty_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_ask_low_qty_ok();
}

#[test]
fun test_swap_exact_not_fully_filled_ask_with_manager_low_qty_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_ask_with_manager_low_qty_ok();
}

#[test, expected_failure(abort_code = ::triexbook::pool::EMinimumQuantityOutNotMet)]
fun test_swap_exact_not_fully_filled_bid_min_e() {
    pool_test_utils::test_swap_exact_not_fully_filled_bid_min_e();
}

#[test, expected_failure(abort_code = ::triexbook::pool::EMinimumQuantityOutNotMet)]
fun test_swap_exact_not_fully_filled_bid_with_manager_min_e() {
    pool_test_utils::test_swap_exact_not_fully_filled_bid_with_manager_min_e();
}

#[test, expected_failure(abort_code = ::triexbook::pool::EMinimumQuantityOutNotMet)]
fun test_swap_exact_not_fully_filled_ask_min_e() {
    pool_test_utils::test_swap_exact_not_fully_filled_ask_min_e();
}

#[test, expected_failure(abort_code = ::triexbook::pool::EMinimumQuantityOutNotMet)]
fun test_swap_exact_not_fully_filled_ask_with_manager_min_e() {
    pool_test_utils::test_swap_exact_not_fully_filled_ask_with_manager_min_e();
}

#[test]
fun test_swap_exact_not_fully_filled_maker_partial_bid_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_maker_partial_bid_ok();
}

#[test]
fun test_swap_exact_not_fully_filled_maker_partial_bid_with_manager_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_maker_partial_bid_with_manager_ok();
}

#[test]
fun test_swap_exact_not_fully_filled_maker_partial_ask_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_maker_partial_ask_ok();
}

#[test]
fun test_swap_exact_not_fully_filled_maker_partial_ask_with_manager_ok() {
    pool_test_utils::test_swap_exact_not_fully_filled_maker_partial_ask_with_manager_ok();
}
