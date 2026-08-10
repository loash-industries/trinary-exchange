// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::pool_fill_tests;

use triexbook::pool_test_utils;

#[test]
fun test_place_then_fill_bid_ask() {
    pool_test_utils::test_place_then_fill_bid_ask();
}

#[test]
fun test_place_then_fill_bid_ask_stable() {
    pool_test_utils::test_place_then_fill_bid_ask_stable();
}

#[test]
fun test_place_then_fill_ask_bid() {
    pool_test_utils::test_place_then_fill_ask_bid();
}

#[test]
fun test_place_then_fill_ask_bid_stable() {
    pool_test_utils::test_place_then_fill_ask_bid_stable();
}

#[test]
fun test_place_then_ioc_bid_ask() {
    pool_test_utils::test_place_then_ioc_bid_ask();
}

#[test]
fun test_place_then_ioc_bid_ask_stable() {
    pool_test_utils::test_place_then_ioc_bid_ask_stable();
}

#[test]
fun test_place_then_ioc_ask_bid() {
    pool_test_utils::test_place_then_ioc_ask_bid();
}

#[test]
fun test_place_then_ioc_ask_bid_stable() {
    pool_test_utils::test_place_then_ioc_ask_bid_stable();
}

#[test]
fun test_fills_bid_ok() {
    pool_test_utils::test_fills_bid_ok();
}

#[test]
fun test_fills_ask_ok() {
    pool_test_utils::test_fills_ask_ok();
}

#[test, expected_failure(abort_code = ::triexbook::book::EBookOrderNotFound)]
fun test_place_then_ioc_no_fill_bid_ask_order_removed_e() {
    pool_test_utils::test_place_then_ioc_no_fill_bid_ask_order_removed_e();
}

#[test, expected_failure(abort_code = ::triexbook::book::EBookOrderNotFound)]
fun test_place_then_ioc_no_fill_ask_bid_order_removed_e() {
    pool_test_utils::test_place_then_ioc_no_fill_ask_bid_order_removed_e();
}

#[test, expected_failure(abort_code = ::triexbook::pool_test_utils::EBookOrderNotFound)]
fun test_expired_order_removed_bid_ask_e() {
    pool_test_utils::test_expired_order_removed_bid_ask_e();
}

#[test, expected_failure(abort_code = ::triexbook::pool_test_utils::EBookOrderNotFound)]
fun test_expired_order_removed_ask_bid_e() {
    pool_test_utils::test_expired_order_removed_ask_bid_e();
}

#[test]
fun test_partial_fill_order_bid_ok() {
    pool_test_utils::test_partial_fill_order_bid_ok();
}

#[test]
fun test_partial_fill_order_ask_ok() {
    pool_test_utils::test_partial_fill_order_ask_ok();
}

#[test]
fun test_fill_partial_maker_bid_ok() {
    pool_test_utils::test_fill_partial_maker_bid_ok();
}

#[test]
fun test_fill_partial_maker_ask_ok() {
    pool_test_utils::test_fill_partial_maker_ask_ok();
}

#[test]
fun test_partially_filled_maker_bid_ok() {
    pool_test_utils::test_partially_filled_maker_bid_ok();
}

#[test]
fun test_partially_filled_maker_ask_ok() {
    pool_test_utils::test_partially_filled_maker_ask_ok();
}

#[test]
fun test_crossing_multiple_orders_bid_ok() {
    pool_test_utils::test_crossing_multiple_orders_bid_ok();
}

#[test]
fun test_crossing_multiple_orders_ask_ok() {
    pool_test_utils::test_crossing_multiple_orders_ask_ok();
}

#[test]
fun test_queue_priority_bid_ok() {
    pool_test_utils::test_queue_priority_bid_ok();
}

#[test]
fun test_queue_priority_ask_ok() {
    pool_test_utils::test_queue_priority_ask_ok();
}
