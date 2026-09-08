// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// This module defines the OrderPage struct and its methods to iterate over orders in a pool.
module triexbook::order_query;

use triexbook::{order::Order, pool::Pool};

/// === Structs ===
public struct OrderPage has drop {
    orders: vector<Order>,
    has_next_page: bool,
}

/// === Public Functions ===
/// Iterate orders in book priority order (best price first).
///
/// With vector implementation, both sides are iterated from END backwards (best at END).
/// `start_order_id` (if provided) acts as an anchor: iteration starts *before* that order_id
/// in the current vector ordering (so pages don't repeat). `end_order_id` (if provided) acts
/// as a hard stop when encountered.
public fun iter_orders<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    start_order_id: Option<u64>,
    end_order_id: Option<u64>,
    min_expire_timestamp: Option<u64>,
    limit: u64,
    bids: bool,
): OrderPage {
    let self = self.load_inner();
    let side = if (bids) self.bids() else self.asks();
    if (side.is_empty() || limit == 0) {
        return OrderPage { orders: vector[], has_next_page: false }
    };

    let start = start_order_id.get_with_default(0);
    let end = end_order_id.get_with_default(0);
    let min_expire = min_expire_timestamp.get_with_default(0);

    // Determine starting index (inclusive) in the current vector ordering.
    let (mut index, found_exact_start) = if (start == 0) {
        (side.length() - 1, false)
    } else {
        find_start_position(side, start)
    };

    // If we found the exact anchor, start *before* it to avoid repeating the prior page.
    if (found_exact_start) {
        if (index == 0) {
            return OrderPage { orders: vector[], has_next_page: false }
        };
        index = index - 1;
    };

    let mut orders = vector[];
    let mut stopped_by_end = false;

    while (orders.length() < limit) {
        let order = &side[index];

        if (end != 0 && order.order_id() == end) {
            stopped_by_end = true;
            break
        };

        if (order.expire_timestamp() >= min_expire) {
            orders.push_back(order.copy_order());
        };

        if (index == 0) {
            break
        };
        index = index - 1;
    };

    let has_next_page = !stopped_by_end && (orders.length() == limit) && (index > 0);

    OrderPage { orders, has_next_page }
}

public fun orders(self: &OrderPage): &vector<Order> {
    &self.orders
}

public fun has_next_page(self: &OrderPage): bool {
    self.has_next_page
}

/// === Private Helper Functions ===

/// Find the index of the exact `start_order_id` in the current vector ordering.
/// Returns (index, found_exact). If not found, returns (last_index, false).
fun find_start_position(orders: &vector<Order>, start_order_id: u64): (u64, bool) {
    let len = orders.length();
    if (len == 0) {
        return (0, false)
    };
    let mut i = len;
    while (i > 0) {
        i = i - 1;
        if (orders[i].order_id() == start_order_id) {
            return (i, true)
        };
    };

    (len - 1, false)
}
