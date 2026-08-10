// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::book_tests;

use sui::{object::id_from_address, test_scenario::{next_tx, begin, end}};
use triexbook::{book, constants, order::{Self, Order}};

const OWNER: address = @0xF;
const ALICE: address = @0xA;

#[test]
// Test find_order_index with empty orderbook
fun find_order_index_empty_orderbook() {
    let mut test = begin(OWNER);
    test.next_tx(ALICE);

    let orderbook = vector[];
    let result = book::find_order_index(&orderbook, 1);
    assert!(result.is_none(), 0);

    test.end();
}

#[test]
// Test find_order_index with single order - found
fun find_order_index_single_order_found() {
    let mut test = begin(OWNER);
    test.next_tx(ALICE);

    let order_id = 42;
    let ord = create_test_order(100, 1000, true, order_id);
    let order_id = ord.order_id();
    let mut orderbook = vector[];
    orderbook.push_back(ord);
    let result = book::find_order_index(&orderbook, order_id);
    assert!(result.is_some(), 0);
    assert!(result.destroy_some() == 0, 0);

    test.end();
}

#[test]
// Test find_order_index with single order - not found
fun find_order_index_single_order_not_found() {
    let mut test = begin(OWNER);
    test.next_tx(ALICE);

    let order_id = 42;
    let order = create_test_order(100, 1000, true, order_id);
    let mut orderbook = vector[];
    orderbook.push_back(order);

    let result = book::find_order_index(&orderbook, 999);
    assert!(result.is_none(), 0);

    test.end();
}

#[test]
// Test find_order_index with multiple orders - first order found
fun find_order_index_multiple_orders_first_found() {
    let mut test = begin(OWNER);
    test.next_tx(ALICE);

    let mut orderbook = vector[];
    orderbook.push_back(create_test_order(100, 1000, true, 1));
    orderbook.push_back(create_test_order(101, 1000, true, 2));
    orderbook.push_back(create_test_order(102, 1000, true, 3));
    let book_order_id = orderbook[0].order_id();
    let result = book::find_order_index(&orderbook, book_order_id);
    assert!(result.is_some(), 0);
    assert!(result.destroy_some() == 0, 0);

    test.end();
}

#[test]
// Test find_order_index with multiple orders - middle order found
fun find_order_index_multiple_orders_middle_found() {
    let mut test = begin(OWNER);
    test.next_tx(ALICE);

    let mut orderbook = vector[];
    orderbook.push_back(create_test_order(100, 1000, true, 1));
    orderbook.push_back(create_test_order(101, 1000, true, 2));
    orderbook.push_back(create_test_order(102, 1000, true, 3));
    let book_order_id = orderbook[1].order_id();
    let result = book::find_order_index(&orderbook, book_order_id);
    assert!(result.is_some(), 0);
    assert!(result.destroy_some() == 1, 0);

    test.end();
}

#[test]
// Test find_order_index with multiple orders - last order found
fun find_order_index_multiple_orders_last_found() {
    let mut test = begin(OWNER);
    test.next_tx(ALICE);

    let mut orderbook = vector[];
    orderbook.push_back(create_test_order(100, 1000, true, 1));
    orderbook.push_back(create_test_order(101, 1000, true, 2));
    orderbook.push_back(create_test_order(102, 1000, true, 3));
    let book_order_id = orderbook[2].order_id();
    let result = book::find_order_index(&orderbook, book_order_id);
    assert!(result.is_some(), 0);
    assert!(result.destroy_some() == 2, 0);

    test.end();
}

#[test]
// Test find_order_index with multiple orders - not found
fun find_order_index_multiple_orders_not_found() {
    let mut test = begin(OWNER);
    test.next_tx(ALICE);

    let mut orderbook = vector[];
    orderbook.push_back(create_test_order(100, 1000, true, 1));
    orderbook.push_back(create_test_order(101, 1000, true, 2));
    orderbook.push_back(create_test_order(102, 1000, true, 3));

    let result = book::find_order_index(&orderbook, 999);
    assert!(result.is_none(), 0);

    test.end();
}

#[test]
// Test find_order_index with duplicate order_ids - should find last occurrence (searches backwards)
fun find_order_index_duplicate_order_ids() {
    let mut test = begin(OWNER);
    test.next_tx(ALICE);

    let mut orderbook = vector[];
    orderbook.push_back(create_test_order(100, 1000, true, 1));
    orderbook.push_back(create_test_order(101, 1000, true, 2));
    orderbook.push_back(create_test_order(102, 1000, true, 1)); // Duplicate order_id
    orderbook.push_back(create_test_order(103, 1000, true, 3));
    let book_order_id = orderbook[2].order_id();
    let result = book::find_order_index(&orderbook, book_order_id);
    assert!(result.is_some(), 0);
    // Should find the last occurrence (index 2) since it searches from the end backwards
    assert!(result.destroy_some() == 2, 0);

    test.end();
}

#[test]
// Test find_order_index searches from end (backwards) - should find last occurrence when searching backwards
fun find_order_index_searches_backwards() {
    let mut test = begin(OWNER);
    test.next_tx(ALICE);

    let mut orderbook = vector[];
    orderbook.push_back(create_test_order(100, 1000, true, 1));
    orderbook.push_back(create_test_order(101, 1000, true, 1)); // Same order_id
    orderbook.push_back(create_test_order(102, 1000, true, 1)); // Same order_id
    let book_order_id = orderbook[2].order_id();
    let result = book::find_order_index(&orderbook, book_order_id);
    assert!(result.is_some(), 0);
    // Since it searches from the end backwards, it should find the last occurrence (index 2)
    assert!(result.destroy_some() == 2, 0);

    test.end();
}

#[test_only]
// Helper function to create a test order
fun create_test_order(price: u64, quantity: u64, is_bid: bool, order_id: u64): Order {
    let balance_manager_id = id_from_address(ALICE);
    let epoch = 1;
    let expire_timestamp = constants::max_u64();

    order::new(
        order_id,
        balance_manager_id,
        price,
        is_bid,
        quantity,
        0,
        epoch,
        constants::live(),
        expire_timestamp,
    )
}
