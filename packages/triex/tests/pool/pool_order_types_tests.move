// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::pool_order_types_tests;

use triexbook::pool_test_utils;

#[test, expected_failure(abort_code = ::triexbook::order_info::EOrderInvalidPrice)]
fun test_price_above_max_e() {
    pool_test_utils::test_price_above_max_e();
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EOrderInvalidPrice)]
fun test_price_below_min_e() {
    pool_test_utils::test_price_below_min_e();
}

#[test, expected_failure(abort_code = ::triexbook::order_info::ESelfMatchingCancelTaker)]
fun test_self_matching_cancel_taker_bid() {
    pool_test_utils::test_self_matching_cancel_taker_bid();
}

#[test, expected_failure(abort_code = ::triexbook::order_info::ESelfMatchingCancelTaker)]
fun test_self_matching_cancel_taker_ask() {
    pool_test_utils::test_self_matching_cancel_taker_ask();
}

#[test, expected_failure(abort_code = ::triexbook::pool_test_utils::EBookOrderNotFound)]
fun test_self_matching_cancel_maker_bid() {
    pool_test_utils::test_self_matching_cancel_maker_bid();
}

#[test, expected_failure(abort_code = ::triexbook::pool_test_utils::EBookOrderNotFound)]
fun test_self_matching_cancel_maker_ask() {
    pool_test_utils::test_self_matching_cancel_maker_ask();
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EPOSTOrderCrossesOrderbook)]
fun test_post_only_bid_e() {
    pool_test_utils::test_post_only_bid_e();
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EPOSTOrderCrossesOrderbook)]
fun test_post_only_ask_e() {
    pool_test_utils::test_post_only_ask_e();
}

#[test]
fun test_post_only_bid_ok() {
    pool_test_utils::test_post_only_bid_ok();
}

#[test]
fun test_post_only_ask_ok() {
    pool_test_utils::test_post_only_ask_ok();
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EFOKOrderCannotBeFullyFilled)]
fun test_fill_or_kill_bid_e() {
    pool_test_utils::test_fill_or_kill_bid_e();
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EFOKOrderCannotBeFullyFilled)]
fun test_fill_or_kill_ask_e() {
    pool_test_utils::test_fill_or_kill_ask_e();
}

#[test]
fun test_fill_or_kill_bid_ok() {
    pool_test_utils::test_fill_or_kill_bid_ok();
}

#[test]
fun test_fill_or_kill_ask_ok() {
    pool_test_utils::test_fill_or_kill_ask_ok();
}

#[test]
fun test_market_order_bid_then_ask_ok() {
    pool_test_utils::test_market_order_bid_then_ask_ok();
}

#[test]
fun test_market_order_ask_then_bid_ok() {
    pool_test_utils::test_market_order_ask_then_bid_ok();
}

#[test]
fun test_order_limit_bid_ok() {
    pool_test_utils::test_order_limit_bid_ok();
}

#[test]
fun test_order_limit_ask_ok() {
    pool_test_utils::test_order_limit_ask_ok();
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EOrderInvalidPrice)]
fun test_place_order_with_maxu64_as_price_e() {
    pool_test_utils::test_place_order_with_maxu64_as_price_e();
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EOrderInvalidPrice)]
fun test_place_order_with_zero_as_price_e() {
    pool_test_utils::test_place_order_with_zero_as_price_e();
}

#[test]
fun test_place_order_with_maxprice_ok() {
    pool_test_utils::test_place_order_with_maxprice_ok();
}

#[test]
fun test_place_order_with_minprice_ok() {
    pool_test_utils::test_place_order_with_minprice_ok();
}

#[test]
fun test_place_order_with_lot_size_ok() {
    pool_test_utils::test_place_order_with_lot_size_ok();
}

#[test]
fun test_modify_order_bid_ok() {
    pool_test_utils::test_modify_order_bid_ok();
}

#[test]
fun test_modify_order_ask_ok() {
    pool_test_utils::test_modify_order_ask_ok();
}

#[test, expected_failure(abort_code = ::triexbook::book::ENewQuantityMustBeLessThanOriginal)]
fun test_modify_order_increase_bid_e() {
    pool_test_utils::test_modify_order_increase_bid_e();
}

#[test, expected_failure(abort_code = ::triexbook::book::ENewQuantityMustBeLessThanOriginal)]
fun test_modify_order_increase_ask_e() {
    pool_test_utils::test_modify_order_increase_ask_e();
}

#[test, expected_failure(abort_code = ::triexbook::order::EInvalidNewQuantity)]
fun test_modify_order_invalid_new_quantity_bid_e() {
    pool_test_utils::test_modify_order_invalid_new_quantity_bid_e();
}

#[test, expected_failure(abort_code = ::triexbook::order::EInvalidNewQuantity)]
fun test_modify_order_invalid_new_quantity_ask_e() {
    pool_test_utils::test_modify_order_invalid_new_quantity_ask_e();
}

#[test]
fun test_modify_order_bid_input_ok() {
    pool_test_utils::test_modify_order_bid_input_ok();
}

#[test]
fun test_modify_order_ask_input_ok() {
    pool_test_utils::test_modify_order_ask_input_ok();
}

#[test, expected_failure(abort_code = ::triexbook::book::ENewQuantityMustBeLessThanOriginal)]
fun test_modify_order_increase_bid_input_e() {
    pool_test_utils::test_modify_order_increase_bid_input_e();
}

#[test, expected_failure(abort_code = ::triexbook::book::ENewQuantityMustBeLessThanOriginal)]
fun test_modify_order_increase_ask_input_e() {
    pool_test_utils::test_modify_order_increase_ask_input_e();
}

#[test, expected_failure(abort_code = ::triexbook::order::EInvalidNewQuantity)]
fun test_modify_order_invalid_new_quantity_bid_input_e() {
    pool_test_utils::test_modify_order_invalid_new_quantity_bid_input_e();
}

#[test, expected_failure(abort_code = ::triexbook::order::EInvalidNewQuantity)]
fun test_modify_order_invalid_new_quantity_ask_input_e() {
    pool_test_utils::test_modify_order_invalid_new_quantity_ask_input_e();
}
