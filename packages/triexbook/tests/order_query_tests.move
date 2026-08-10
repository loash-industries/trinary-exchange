// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::order_query_tests;

use std::unit_test::destroy;
use sui::{sui::SUI, test_scenario::{begin, end, return_shared}};
use token::cred::CRED;
use triexbook::{
    balance_manager_tests::{
        USDC,
        create_acct_and_share_with_funds as create_acct_and_share_with_funds
    },
    constants,
    order_query::iter_orders,
    pool::Pool,
    pool_tests::{setup_test, setup_pool_with_default_fees_and_reference_pool, place_limit_order}
};

const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;

#[test]
fun test_place_orders_ok() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let mut iter = 1;
    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let mut expire_timestamp = constants::max_u64();
    let is_bid = true;

    while (iter <= 10) {
        place_limit_order<SUI, USDC>(
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
        );
        iter = iter + 1;
    };

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
    let orders = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::none(),
        100,
        true,
    );
    assert!(orders.orders().length() == 10);
    assert!(orders.has_next_page() == false);
    let mut i = 1;
    while (i <= 10) {
        let order = &orders.orders()[i - 1];
        assert!(order.order_id() == i);
        assert!(order.price() == price);
        assert!(order.quantity() == quantity);
        assert!(order.is_bid() == is_bid);
        assert!(order.expire_timestamp() == expire_timestamp);
        i = i + 1;
    };
    return_shared(pool);

    let ask_price = 3 * constants::float_scaling();
    let ask_is_bid = false;
    while (iter <= 20) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            order_type,
            constants::self_matching_allowed(),
            ask_price,
            quantity,
            ask_is_bid,
            expire_timestamp,
            &mut test,
        );
        iter = iter + 1;
    };

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
    let orders = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::none(),
        100,
        false,
    );
    assert!(orders.orders().length() == 10);
    assert!(orders.has_next_page() == false);
    return_shared(pool);

    expire_timestamp = 100000000;
    place_limit_order<SUI, USDC>(
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
    );

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
    let orders = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::some(100000001),
        100,
        true,
    );
    assert!(orders.orders().length() == 10);

    let orders = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::none(),
        5,
        true,
    );
    assert!(orders.orders().length() == 5);
    assert!(orders.has_next_page() == true);

    destroy(pool);
    end(test);
}

#[test]
fun test_find_start_position_anchor_behavior() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let is_bid = true;

    let mut i = 1;
    while (i <= 10) {
        place_limit_order<SUI, USDC>(
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
        );
        i = i + 1;
    };

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

    // Exact anchor hit: start before anchor (so anchor isn't repeated).
    // In this setup, `iter_orders` returns bids in FIFO order: [1, 2, ..., 10].
    // Anchoring at 1 should return [2, 3, ..., 10].
    let page = iter_orders(
        &pool,
        option::some(1),
        option::none(),
        option::none(),
        100,
        true,
    );
    assert!(page.orders().length() == 9);
    assert!(page.has_next_page() == false);
    assert!(page.orders()[0].order_id() == 2);
    assert!(page.orders()[8].order_id() == 10);

    // Anchor miss: falls back to last index (so returns full set).
    let page = iter_orders(
        &pool,
        option::some(999),
        option::none(),
        option::none(),
        100,
        true,
    );
    assert!(page.orders().length() == 10);
    assert!(page.orders()[0].order_id() == 1);
    assert!(page.orders()[9].order_id() == 10);

    // Exact anchor hit at index 0: returns empty page.
    let page = iter_orders(
        &pool,
        option::some(10),
        option::none(),
        option::none(),
        100,
        true,
    );
    assert!(page.orders().length() == 0);
    assert!(page.has_next_page() == false);

    destroy(pool);
    end(test);
}

#[test]
fun test_iter_orders_limit_zero() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let mut i = 1;
    while (i <= 3) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            expire_timestamp,
            &mut test,
        );
        i = i + 1;
    };

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
    let page = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::none(),
        0,
        true,
    );
    assert!(page.orders().length() == 0);
    assert!(page.has_next_page() == false);

    destroy(pool);
    end(test);
}

#[test]
fun test_iter_orders_end_order_id_stop_and_pagination() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let mut i = 1;
    while (i <= 10) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            expire_timestamp,
            &mut test,
        );
        i = i + 1;
    };

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

    // Hard stop: `end_order_id` is not included in the page.
    let page = iter_orders(
        &pool,
        option::none(),
        option::some(5),
        option::none(),
        100,
        true,
    );
    assert!(page.orders().length() == 4);
    assert!(page.has_next_page() == false);
    assert!(page.orders()[0].order_id() == 1);
    assert!(page.orders()[3].order_id() == 4);

    // If the limit is hit before `end_order_id`, we still paginate.
    let page = iter_orders(
        &pool,
        option::none(),
        option::some(5),
        option::none(),
        2,
        true,
    );
    assert!(page.orders().length() == 2);
    assert!(page.has_next_page() == true);
    assert!(page.orders()[0].order_id() == 1);
    assert!(page.orders()[1].order_id() == 2);

    destroy(pool);
    end(test);
}

#[test]
fun test_iter_orders_min_expire_timestamp_filtering() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();

    let low_expire_timestamp = constants::max_u64() - 1000;
    let high_expire_timestamp = constants::max_u64();
    let min_expire_timestamp = constants::max_u64() - 500;

    let mut i = 1;
    while (i <= 10) {
        let expire_timestamp = if (i <= 5) low_expire_timestamp else high_expire_timestamp;
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            expire_timestamp,
            &mut test,
        );
        i = i + 1;
    };

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

    // Only include orders with expire_timestamp >= 200.
    let page = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::some(min_expire_timestamp),
        100,
        true,
    );
    assert!(page.orders().length() == 5);
    assert!(page.has_next_page() == false);
    assert!(page.orders()[0].order_id() == 6);
    assert!(page.orders()[4].order_id() == 10);

    // Filtering can skip earlier orders but still paginate when limit is hit.
    let page = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::some(min_expire_timestamp),
        2,
        true,
    );
    assert!(page.orders().length() == 2);
    assert!(page.has_next_page() == true);
    assert!(page.orders()[0].order_id() == 6);
    assert!(page.orders()[1].order_id() == 7);

    destroy(pool);
    end(test);
}

#[test]
fun test_iter_orders_asks_anchor_and_end_stop() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let price = 3 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let mut i = 1;
    while (i <= 10) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            false,
            expire_timestamp,
            &mut test,
        );
        i = i + 1;
    };

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

    let page = iter_orders(
        &pool,
        option::some(1),
        option::none(),
        option::none(),
        100,
        false,
    );
    assert!(page.orders().length() == 9);
    assert!(page.has_next_page() == false);
    assert!(page.orders()[0].order_id() == 2);
    assert!(page.orders()[8].order_id() == 10);

    let page = iter_orders(
        &pool,
        option::none(),
        option::some(5),
        option::none(),
        100,
        false,
    );
    assert!(page.orders().length() == 4);
    assert!(page.has_next_page() == false);
    assert!(page.orders()[0].order_id() == 1);
    assert!(page.orders()[3].order_id() == 4);

    destroy(pool);
    end(test);
}

#[test]
fun test_find_insert_position_bids_price_time_priority() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let is_bid = true;

    // Insert out-of-order by price to exercise find_insert_position.
    // Order IDs assigned sequentially: 1..4.
    let p2 = 2 * constants::float_scaling();
    let p1 = 1 * constants::float_scaling();
    let p3 = 3 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p2,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p1,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p3,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p2,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

    // Best bid is highest price; within same price, FIFO (older first).
    let page = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::none(),
        100,
        true,
    );
    assert!(page.orders().length() == 4);
    assert!(page.has_next_page() == false);

    // Full expected sequence: best price first; FIFO within price.
    let expected_order_ids = vector[3, 1, 4, 2];
    let expected_prices = vector[p3, p2, p2, p1];
    let mut j = 0;
    while (j < 4) {
        assert!(page.orders()[j].order_id() == expected_order_ids[j]);
        assert!(page.orders()[j].price() == expected_prices[j]);
        j = j + 1;
    };

    destroy(pool);
    end(test);
}

#[test]
fun test_find_insert_position_asks_price_time_priority() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let is_bid = false;

    // Insert out-of-order by price to exercise find_insert_position.
    // Order IDs assigned sequentially: 1..4.
    let p2 = 2 * constants::float_scaling();
    let p3 = 3 * constants::float_scaling();
    let p1 = 1 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p2,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p3,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p1,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p2,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

    // Best ask is lowest price; within same price, FIFO (older first).
    let page = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::none(),
        100,
        false,
    );
    assert!(page.orders().length() == 4);
    assert!(page.has_next_page() == false);

    // Full expected sequence: best (lowest) price first; FIFO within price.
    let expected_order_ids = vector[3, 1, 4, 2];
    let expected_prices = vector[p1, p2, p2, p3];
    let mut j = 0;
    while (j < 4) {
        assert!(page.orders()[j].order_id() == expected_order_ids[j]);
        assert!(page.orders()[j].price() == expected_prices[j]);
        j = j + 1;
    };

    destroy(pool);
    end(test);
}

#[test]
fun test_find_insert_position_insert_at_end_new_best_price() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let is_bid = true;

    let p2 = 2 * constants::float_scaling();
    let p3 = 3 * constants::float_scaling();
    let p4 = 4 * constants::float_scaling();

    // Place two orders, then place a new best price.
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p2,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p3,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p4,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

    // New best bid should be at END of the bids vector, so it is returned first.
    let page = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::none(),
        100,
        true,
    );
    assert!(page.orders().length() == 3);
    assert!(page.has_next_page() == false);

    let expected_order_ids = vector[3, 2, 1];
    let expected_prices = vector[p4, p3, p2];
    let mut j = 0;
    while (j < 3) {
        assert!(page.orders()[j].order_id() == expected_order_ids[j]);
        assert!(page.orders()[j].price() == expected_prices[j]);
        j = j + 1;
    };

    destroy(pool);
    end(test);
}

#[test]
fun test_find_insert_position_insert_at_start_worst_price() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let is_bid = true;

    let p2 = 2 * constants::float_scaling();
    let p3 = 3 * constants::float_scaling();
    let p1 = 1 * constants::float_scaling();

    // Place two orders, then place a new worst price.
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p2,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p3,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        p1,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

    // New worst bid should be at START of the bids vector, so it is returned last.
    let page = iter_orders(
        &pool,
        option::none(),
        option::none(),
        option::none(),
        100,
        true,
    );
    assert!(page.orders().length() == 3);
    assert!(page.has_next_page() == false);

    let expected_order_ids = vector[2, 1, 3];
    let expected_prices = vector[p3, p2, p1];
    let mut j = 0;
    while (j < 3) {
        assert!(page.orders()[j].order_id() == expected_order_ids[j]);
        assert!(page.orders()[j].price() == expected_prices[j]);
        j = j + 1;
    };

    destroy(pool);
    end(test);
}
