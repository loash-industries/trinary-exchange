// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::pool_cancel_tests;

use sui::{sui::SUI, test_scenario::{begin, end, Scenario}};
use token::cred::CRED;
use triexbook::{
    balance_manager_tests::{create_acct_and_share_with_funds, USDC},
    constants,
    pool_test_utils
};

const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;

#[test_only]
fun cancel_all_orders_case(is_bid: bool, has_open_orders: bool) {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
        SUI,
        USDC,
        SUI,
        CRED,
    >(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let mut order_info_1_id = 0;

    if (has_open_orders) {
        order_info_1_id =
            pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                balance_manager_id_alice,
                order_type,
                constants::self_matching_allowed(),
                price,
                quantity,
                is_bid,
                expire_timestamp,
                &mut test,
            ).order_id();

        let order_info_2_id = pool_test_utils::place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        ).order_id();

        pool_test_utils::borrow_order_ok<SUI, USDC>(pool_id, order_info_1_id, is_bid, &mut test);
        pool_test_utils::borrow_order_ok<SUI, USDC>(pool_id, order_info_2_id, is_bid, &mut test);
    };

    pool_test_utils::cancel_all_orders<SUI, USDC>(
        pool_id,
        ALICE,
        balance_manager_id_alice,
        &mut test,
    );

    if (has_open_orders) {
        // Cancel-all should remove the order from the book.
        // We purposely re-borrow to ensure it aborts as expected.
        pool_test_utils::borrow_order_ok<SUI, USDC>(pool_id, order_info_1_id, is_bid, &mut test);
    };

    end(test);
}

#[test_only]
fun cancel_orders_case(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
        SUI,
        USDC,
        SUI,
        CRED,
    >(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let order_info_1 = pool_test_utils::place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    let order_info_2 = pool_test_utils::place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    let mut orders_to_cancel = vector[];
    orders_to_cancel.push_back(order_info_1.order_id());
    orders_to_cancel.push_back(order_info_2.order_id());

    pool_test_utils::cancel_orders<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        orders_to_cancel,
        &mut test,
    );

    // Verify order_1 was canceled in the book.
    pool_test_utils::borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_1.order_id(),
        is_bid,
        quantity,
        0,
        test.ctx().epoch(),
        constants::canceled(),
        expire_timestamp,
        &mut test,
    );

    end(test);
}

#[test, expected_failure(abort_code = ::triexbook::pool_test_utils::EBookOrderNotFound)]
fun test_cancel_all_orders_bid_e() {
    cancel_all_orders_case(true, true);
}

#[test, expected_failure(abort_code = ::triexbook::pool_test_utils::EBookOrderNotFound)]
fun test_cancel_all_orders_ask_e() {
    cancel_all_orders_case(false, true);
}

#[test]
fun test_cancel_all_orders_bid_ok() {
    cancel_all_orders_case(true, false);
}

#[test]
fun test_cancel_all_orders_ask_ok() {
    cancel_all_orders_case(false, false);
}

#[test, expected_failure(abort_code = ::triexbook::pool_test_utils::EBookOrderNotFound)]
fun test_cancel_orders_bid() {
    cancel_orders_case(true);
}

#[test, expected_failure(abort_code = ::triexbook::pool_test_utils::EBookOrderNotFound)]
fun test_cancel_orders_ask() {
    cancel_orders_case(false);
}
