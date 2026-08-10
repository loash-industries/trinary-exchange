// Copyright (c) Mysten Labs, Inc.
/// SPDX-License-Identifier: Apache-2.0

/// The book module contains the `Book` struct which represents the order book.
/// All order book operations are defined in this module.
module triexbook::book;

use triexbook::{constants, math, order::Order, order_info::OrderInfo};

/// === Errors ===
const EInvalidAmountIn: u64 = 1;
const EEmptyOrderbook: u64 = 2;
const EInvalidPriceRange: u64 = 3;
const EInvalidTicks: u64 = 4;
const ENewQuantityMustBeLessThanOriginal: u64 = 7;
const EBookOrderNotFound: u64 = 8;

public fun invalid_amount_in(): u64 { EInvalidAmountIn }

public fun empty_orderbook(): u64 { EEmptyOrderbook }

public fun invalid_price_range(): u64 { EInvalidPriceRange }

public fun invalid_ticks(): u64 { EInvalidTicks }

public fun new_quantity_must_be_less_than_original(): u64 { ENewQuantityMustBeLessThanOriginal }

public fun book_order_not_found(): u64 { EBookOrderNotFound }

/// === Structs ===
public struct Book has store {
    // bids: BigVector<Order>,
    // asks: BigVector<Order>, // #feat:bv
    bids: vector<Order>, // sorted ASCENDING by price (best bid at END)
    asks: vector<Order>, // sorted DESCENDING by price (best ask at END)
    next_order_id: u64,
    // Divisor used in qty ↔ quote conversions.
    // Normal pools: FLOAT_SCALING (1e9) — price = human × QUOTE_UNIT × FLOAT_SCALING / BASE_UNIT.
    // Multicoin pools: 1 — price = human × QUOTE_UNIT (no float division).
    price_scaling: u64,
}

/// === Public-Package Functions ===
/// public(package) fun bids(self: &Book): &BigVector<Order> { // #feat:bv
public(package) fun bids(self: &Book): &vector<Order> {
    &self.bids
}

/// public(package) fun asks(self: &Book): &BigVector<Order> { // #feat:bv
public(package) fun asks(self: &Book): &vector<Order> {
    &self.asks
}

/// #feat:bv
/// #ref:order_null
/// public(package) fun empty(tick_size: u64, lot_size: u64, min_size: u64, ctx: &mut TxContext): Book {
///     Book {
///         tick_size,
///         lot_size,
///         min_size,
///         bids: big_vector::empty(
///             constants::max_slice_size(),
///             constants::max_fan_out(),
///             ctx,
///         ),
///         asks: big_vector::empty(
///             constants::max_slice_size(),
///             constants::max_fan_out(),
///             ctx,
///         ),
///         next_bid_order_id: START_BID_ORDER_ID,
///         next_ask_order_id: START_ASK_ORDER_ID,
///     }
/// }
/// #ref:order_null
public(package) fun empty(_ctx: &mut TxContext): Book {
    Book {
        bids: vector[],
        asks: vector[],
        next_order_id: 1,
        price_scaling: constants::float_scaling(),
    }
}

public(package) fun empty_multicoin(_ctx: &mut TxContext): Book {
    Book {
        bids: vector[],
        asks: vector[],
        next_order_id: 1,
        price_scaling: 1,
    }
}

public(package) fun price_scaling(self: &Book): u64 {
    self.price_scaling
}

public(package) fun find_order_index(orderbook: &vector<Order>, book_order_id: u64): Option<u64> {
    let len = orderbook.length();
    if (len == 0) {
        return option::none()
    };
    // on len < 20, linear search is faster than binary search. Start from back for stacked orders.
    let mut i = len;
    // arr size 20 (i = 20)
    while (i > 0) {
        i = i - 1;
        // i = 19 ... 0
        if (orderbook[i].order_id() == book_order_id) {
            return option::some(i)
        };
    };
    //
    return option::none()
}

/// Creates a new order.
/// Order is matched against the book and injected into the book if necessary.
/// If order is IOC or fully executed, it will not be injected.
public(package) fun create_order(self: &mut Book, order_info: &mut OrderInfo, timestamp: u64) {
    order_info.validate_inputs(timestamp);
    let order_id = allocate_order_id(self);
    order_info.set_order_id(order_id);
    self.match_against_book(order_info, timestamp);
    if (order_info.assert_execution()) return;
    self.inject_limit_order(order_info);
    order_info.set_order_inserted();
    order_info.emit_order_placed();
}

/// Given base_quantity and quote_quantity, calculate the base_quantity_out and
/// quote_quantity_out with quote-denominated fees. Cred fees are always zero.
/// #ref:quantity_out
public(package) fun get_quantity_out(
    self: &Book,
    base_quantity: u64,
    quote_quantity: u64,
    trade_specific_taker_fee: u64, // this has already been adjusted for user-specific fees
    current_timestamp: u64,
): (u64, u64) {
    assert!((base_quantity > 0) != (quote_quantity > 0), invalid_amount_in());
    let is_bid = quote_quantity > 0;
    let input_fee_rate = math::mul(constants::fee_penalty_multiplier(), trade_specific_taker_fee);
    let fee_waived = false;

    let mut quantity_out = 0;
    let mut quantity_in_left = if (is_bid) quote_quantity else base_quantity;

    let book_side = if (is_bid) &self.asks else &self.bids;
    let max_fills = constants::max_fills();
    let mut current_fills = 0;
    let mut i = book_side.length(); // Start from END (best price)

    while (i > 0 && quantity_in_left > 0 && current_fills < max_fills) {
        i = i - 1;
        let order = &book_side[i];
        let cur_price = order.price();
        let cur_quantity = order.quantity() - order.filled_quantity();

        if (current_timestamp <= order.expire_timestamp()) {
            let mut matched_base_quantity;
            let quantity_to_match = if (fee_waived) {
                quantity_in_left
            } else {
                math::div(quantity_in_left, constants::float_scaling() + input_fee_rate)
            };

            if (is_bid) {
                matched_base_quantity =
                    math::quote_to_qty(quantity_to_match, cur_price, self.price_scaling).min(
                        cur_quantity,
                    );
                quantity_out = quantity_out + matched_base_quantity;
                let matched_quote_quantity = math::qty_to_quote(
                    matched_base_quantity,
                    cur_price,
                    self.price_scaling,
                );
                quantity_in_left = quantity_in_left - matched_quote_quantity;
                if (!fee_waived) {
                    quantity_in_left =
                        quantity_in_left - math::mul(matched_quote_quantity, input_fee_rate);
                };
            } else {
                matched_base_quantity = quantity_to_match.min(cur_quantity);
                quantity_out =
                    quantity_out + math::qty_to_quote(matched_base_quantity, cur_price, self.price_scaling);
                quantity_in_left = quantity_in_left - matched_base_quantity;
                if (!fee_waived) {
                    quantity_in_left =
                        quantity_in_left - math::mul(matched_base_quantity, input_fee_rate);
                };
            };

            if (matched_base_quantity == 0) break;
        };

        current_fills = current_fills + 1;
    };

    if (is_bid) {
        (quantity_out, quantity_in_left)
    } else {
        (quantity_in_left, quantity_out)
    }
}

/// Cancels an order given order_id
/// #ref:order_cancel
/// #feat:bv
/// public(package) fun cancel_order(self: &mut Book, order_id: u128): Order {
///     self.book_side_mut(order_id).remove(order_id)
/// }
/// #ref:order_cancel
public(package) fun cancel_order(self: &mut Book, order_id: u64): Order {
    // Fast path: if it's at the end (best price) on either side, pop_back in O(1)
    if (!self.bids.is_empty()) {
        if (self.bids[self.bids.length() - 1].order_id() == order_id) {
            return self.bids.pop_back()
        }
    };
    if (!self.asks.is_empty()) {
        if (self.asks[self.asks.length() - 1].order_id() == order_id) {
            return self.asks.pop_back()
        }
    };

    // Otherwise, find and remove (O(n))
    let mut index = 0;
    let bids_len = self.bids.length();
    while (index < bids_len) {
        if (self.bids[index].order_id() == order_id) {
            return self.bids.remove(index)
        };
        index = index + 1;
    };
    let mut index = 0;
    let asks_len = self.asks.length();
    while (index < asks_len) {
        if (self.asks[index].order_id() == order_id) {
            return self.asks.remove(index)
        };
        index = index + 1;
    };
    abort book_order_not_found()
}

/// Helper to find order by ID
/// In book.move, replace the simple find_order_index with:

/// Optimized search for order by ID with hybrid strategy:
/// - Check last 5 orders first (O(1) for recent orders - common case)
/// - Use binary search if vector is large (>50 orders)
/// - Fall back to linear search for medium-sized vectors
/// fun find_order_index(orders: &vector<Order>, order_id: u128): u64 {
///     let len = orders.length();
///     if (len == 0) {
///         abort EBookOrderNotFound
///     };

///     // Strategy 1: Check last 5 orders first (most frequently updated)
///     let check_recent = if (len < 5) len else 5;
///     let mut i = len;
///     let mut checked = 0;
///     while (checked < check_recent) {
///         i = i - 1;
///         if (orders[i].order_id() == order_id) {
///             return i
///         };
///         checked = checked + 1;
///     };

///     // Strategy 2: Binary search for large vectors (>50 orders)
///     if (len > 50) {
///         return binary_search_by_order_id(orders, order_id, 0, len - check_recent)
///     };

///     // Strategy 3: Linear search for medium vectors (6-50 orders)
///     while (i > 0) {
///         i = i - 1;
///         if (orders[i].order_id() == order_id) {
///             return i
///         };
///     };
///     abort EBookOrderNotFound
/// }
/// Binary search for order by order_id in a sorted vector
/// Handles both ascending (bids) and descending (asks) sorted vectors
/// fun binary_search_by_order_id(orders: &vector<Order>, order_id: u64, start: u64, end: u64): u64 {
///     if (start >= end) {
///         abort EBookOrderNotFound
///     };
///     let mut lo = start;
///     let mut hi = end;
///     // Determine sorting direction by comparing first and last elements
///     let is_ascending = orders[lo].order_id() < orders[hi - 1].order_id();
///     while (lo < hi) {
///         let mid = lo + (hi - lo) / 2;
///         let mid_order_id = orders[mid].order_id();
///         if (mid_order_id == order_id) {
///             return mid
///         };
///         if (is_ascending) {
///             // Ascending order (bids: low to high price at end)
///             if (order_id < mid_order_id) {
///                 hi = mid;
///             } else {
///                 lo = mid + 1;
///             }
///         } else {
///             // Descending order (asks: high to low price at end)
///             if (order_id > mid_order_id) {
///                 hi = mid;
///             } else {
///                 lo = mid + 1;
///             }
///         }
///     };
///     // Binary search failed, fall back to linear scan
///     // This handles edge cases where orders at same price might not be fully sorted by order_id
///     let mut i = start;
///     while (i < end) {
///         if (orders[i].order_id() == order_id) {
///             return i
///         };
///         i = i + 1;
///     };

///     abort EBookOrderNotFound
/// }

/// Modifies an order given order_id and new_quantity.
/// New quantity must be less than the original quantity.
/// Order must not have already expired.
/// #ref:order_modify
/// #feat:bv
/// public(package) fun modify_order(
///     self: &mut Book,
///     order_id: u64,
///     new_quantity: u64,
///     timestamp: u64,
/// ): (u64, &Order) {
///     assert!(new_quantity >= self.min_size, EOrderBelowMinimumSize);
///     assert!(new_quantity % self.lot_size == 0, EOrderInvalidLotSize);

///     let order = self.book_sidde_mut(order_id).borrow_mut(order_id);
///     assert!(new_quantity < order.quantity(), ENewQuantityMustBeLessThanOriginal);
///     let cancel_quantity = order.quantity() - new_quantity;
///     order.modify(new_quantity, timestamp);

///     (cancel_quantity, order)
/// }

/// #ref:order_modify
public(package) fun modify_order(
    self: &mut Book,
    order_id: u64,
    new_quantity: u64,
    timestamp: u64,
): (u64, &Order) {
    let mut index = 0;
    let bids_len = self.bids.length();
    while (index < bids_len) {
        if (self.bids[index].order_id() == order_id) {
            let order = &mut self.bids[index];

            assert!(new_quantity < order.quantity(), new_quantity_must_be_less_than_original());
            let cancel_quantity = order.quantity() - new_quantity;
            order.modify(new_quantity, timestamp);

            return (cancel_quantity, order)
        };
        index = index + 1;
    };
    let mut index = 0;
    let asks_len = self.asks.length();
    while (index < asks_len) {
        if (self.asks[index].order_id() == order_id) {
            let order = &mut self.asks[index];

            assert!(new_quantity < order.quantity(), new_quantity_must_be_less_than_original());
            let cancel_quantity = order.quantity() - new_quantity;
            order.modify(new_quantity, timestamp);

            return (cancel_quantity, order)
        };
        index = index + 1;
    };
    abort book_order_not_found()
}

/// Returns the mid price of the order book.
/// #ref:mid_price
/// #feat:bv
/// public(package) fun mid_price(self: &Book, current_timestamp: u64): u64 {
///     let (mut ask_ref, mut ask_offset) = self.asks.min_slice();
///     let (mut bid_ref, mut bid_offset) = self.bids.max_slice();
///     let mut best_ask_price = 0;
///     let mut best_bid_price = 0;

///     while (!ask_ref.is_null()) {
///         let best_ask_order = slice_borrow(
///             self.asks.borrow_slice(ask_ref),
///             ask_offset,
///         );
///         best_ask_price = best_ask_order.price();
///         if (current_timestamp <= best_ask_order.expire_timestamp()) break;
///         (ask_ref, ask_offset) = self.asks.next_slice(ask_ref, ask_offset);
///     };

///     while (!bid_ref.is_null()) {
///         let best_bid_order = slice_borrow(
///             self.bids.borrow_slice(bid_ref),
///             bid_offset,
///         );
///         best_bid_price = best_bid_order.price();
///         if (current_timestamp <= best_bid_order.expire_timestamp()) break;
///         (bid_ref, bid_offset) = self.bids.prev_slice(bid_ref, bid_offset);
///     };

///     assert!(!ask_ref.is_null() && !bid_ref.is_null(), EEmptyOrderbook);

///     math::mul(best_ask_price + best_bid_price, constants::half())
/// }

/// #ref:mid_price
public(package) fun mid_price(self: &Book, current_timestamp: u64): u64 {
    let mut best_ask_price = 0;
    let mut best_bid_price = 0;

    // Find first non-expired ask (start from END - best price)
    let mut i = self.asks.length();
    while (i > 0) {
        i = i - 1;
        let order = &self.asks[i];
        if (current_timestamp <= order.expire_timestamp()) {
            best_ask_price = order.price();
            break
        };
    };

    // Find first non-expired bid (start from END - best price)
    let mut i = self.bids.length();
    while (i > 0) {
        i = i - 1;
        let order = &self.bids[i];
        if (current_timestamp <= order.expire_timestamp()) {
            best_bid_price = order.price();
            break
        };
    };

    assert!(best_ask_price > 0 && best_bid_price > 0, empty_orderbook());

    math::mul(best_ask_price + best_bid_price, constants::half())
}

/// Returns the best bids and asks.
/// The number of ticks is the number of price levels to return.
/// The price_low and price_high are the range of prices to return.
/// #ref:level2
/// #feat:bv
/// public(package) fun get_level2_range_and_ticks(
///     self: &Book,
///     price_low: u64,
///     price_high: u64,
///     ticks: u64,
///     is_bid: bool,
///     current_timestamp: u64,
/// ): (vector<u64>, vector<u64>) {
///     assert!(price_low <= price_high, EInvalidPriceRange);
///     assert!(
///         price_low >= constants::min_price() &&
///         price_low <= constants::max_price(),
///         EInvalidPriceRange,
///     );
///     assert!(
///         price_high >= constants::min_price() &&
///         price_high <= constants::max_price(),
///         EInvalidPriceRange,
///     );
///     assert!(ticks > 0, EInvalidTicks);

///     let mut price_vec = vector[];
///     let mut quantity_vec = vector[];

///     // convert price_low and price_high to keys for searching
///     let msb = if (is_bid) {
///         (0 as u128)
///     } else {
///         (1 as u128) << 127
///     };
///     let key_low = ((price_low as u128) << 64) + msb;
///     let key_high = ((price_high as u128) << 64) + (((1u128 << 64) - 1) as u128) + msb;
///     let book_side = if (is_bid) &self.bids else &self.asks;
///     let (mut ref, mut offset) = if (is_bid) {
///         book_side.slice_before(key_high)
///     } else {
///         book_side.slice_following(key_low)
///     };
///     let mut ticks_left = ticks;
///     let mut cur_price = 0;
///     let mut cur_quantity = 0;

///     while (!ref.is_null() && ticks_left > 0) {
///         let order = slice_borrow(book_side.borrow_slice(ref), offset);
///         if (current_timestamp <= order.expire_timestamp()) {
///             let (_, order_price, _) = utils::decode_order_id(order.order_id());
///             if (
///                 (is_bid && order_price < price_low) || (
///                     !is_bid && order_price > price_high,
///                 )
///             ) break;
///             if (
///                 cur_price == 0 && (
///                     (is_bid && order_price <= price_high) || (
///                         !is_bid && order_price >= price_low,
///                     ),
///                 )
///             ) {
///                 cur_price = order_price
///             };

///             if (cur_price != 0 && order_price != cur_price) {
///                 price_vec.push_back(cur_price);
///                 quantity_vec.push_back(cur_quantity);
///                 cur_price = order_price;
///                 cur_quantity = 0;
///                 ticks_left = ticks_left - 1;
///                 if (ticks_left == 0) break;
///             };
///             if (cur_price != 0) {
///                 cur_quantity = cur_quantity + order.quantity() - order.filled_quantity();
///             };
///         };

///         (ref, offset) = if (is_bid) book_side.(ref, offset) else book_side.next_slice(ref, offset);
///     };

///     if (cur_price != 0 && ticks_left > 0) {
///         price_vec.push_back(cur_price);
///         quantity_vec.push_back(cur_quantity);
///     };

///     (price_vec, quantity_vec)
/// }

/// #ref:level2
public(package) fun get_level2_range_and_ticks(
    self: &Book,
    price_low: u64,
    price_high: u64,
    ticks: u64,
    is_bid: bool,
    current_timestamp: u64,
): (vector<u64>, vector<u64>) {
    assert!(price_low <= price_high, invalid_price_range());
    assert!(
        price_low >= constants::min_price() && price_low <= constants::max_price(),
        invalid_price_range(),
    );
    assert!(
        price_high >= constants::min_price() && price_high <= constants::max_price(),
        invalid_price_range(),
    );
    assert!(ticks > 0, invalid_ticks());

    let mut price_vec = vector[];
    let mut quantity_vec = vector[];

    let book_side = if (is_bid) &self.bids else &self.asks;
    let mut ticks_left = ticks;
    let mut cur_price = 0;
    let mut cur_quantity = 0;

    // Start from END (best price) and work backwards
    let mut i = book_side.length();

    while (i > 0 && ticks_left > 0) {
        i = i - 1;
        let order = &book_side[i];

        if (current_timestamp <= order.expire_timestamp()) {
            let order_price = order.price();

            // Check if price is in range
            if ((is_bid && order_price < price_low) || (!is_bid && order_price > price_high)) {
                break
            };

            if ((is_bid && order_price > price_high) || (!is_bid && order_price < price_low)) {
                continue
            };

            // Initialize cur_price
            if (cur_price == 0) {
                cur_price = order_price;
            };

            // New price level
            if (order_price != cur_price) {
                price_vec.push_back(cur_price);
                quantity_vec.push_back(cur_quantity);
                cur_price = order_price;
                cur_quantity = 0;
                ticks_left = ticks_left - 1;
                if (ticks_left == 0) break;
            };

            cur_quantity = cur_quantity + order.quantity() - order.filled_quantity();
        };
    };

    if (cur_price != 0 && ticks_left > 0) {
        price_vec.push_back(cur_price);
        quantity_vec.push_back(cur_quantity);
    };

    (price_vec, quantity_vec)
}

/// #ref:order_query
/// #feat:bv
/// public(package) fun get_order(self: &Book, order_id: u128): Order {
///     let order = self.book_side(order_id).borrow(order_id);
///     order.copy_order()
/// }
/// #ref:order_query
public(package) fun get_order(self: &Book, order_id: u64): Order {
    let mut index = 0;
    let bids_len = self.bids.length();
    while (index < bids_len) {
        if (self.bids[index].order_id() == order_id) {
            return self.bids[index].copy_order()
        };
        index = index + 1;
    };
    let mut index = 0;
    let asks_len = self.asks.length();
    while (index < asks_len) {
        if (self.asks[index].order_id() == order_id) {
            return self.asks[index].copy_order()
        };
        index = index + 1;
    };
    abort book_order_not_found()
}

/// === Private Functions ===
/// Access side of book where order_id belongs
/// fun book_side_mut(self: &mut Book, order_id: u128): &mut BigVector<Order> { // #feat:bv
///     let (is_bid, _, _) = utils::decode_order_id(order_id);
///     if (is_bid) {
///         &mut self.bids
///     } else {
///         &mut self.asks
///     }
/// }
/// fun book_side(self: &Book, order_id: u128): &BigVector<Order> { // #feat:bv
///     let (is_bid, _, _) = utils::decode_order_id(order_id);
///     if (is_bid) {
///         &self.bids
///     } else {
///         &self.asks
///     }
/// }
/// #feat:bv

/// Matches the given order and quantity against the order book.
/// If is_bid, it will match against asks, otherwise against bids.
/// Mutates the order and the maker order as necessary.
/// #ref:matching
/// #feat:bv
/// fun match_against_book(self: &mut Book, order_info: &mut OrderInfo, timestamp: u64) {
///     let is_bid = order_info.is_bid();
///     let book_side = if (is_bid) &mut self.asks else &mut self.bids;
///     let (mut ref, mut offset) = if (is_bid) book_side.min_slice() else book_side.max_slice();
///     let max_fills = constants::max_fills();
///     let mut current_fills = 0;
///     while (!ref.is_null() &&
///         current_fills < max_fills) {
///         let maker_order = slice_borrow_mut(
///             book_side.borrow_slice_mut(ref),
///             offset,
///         );
///         if (!order_info.match_maker(maker_order, timestamp)) break;
///         (ref, offset) = if (is_bid) book_side.next_slice(ref, offset)
///         else book_side.prev_slice(ref, offset);
///         current_fills = current_fills + 1;
///     };
///     order_info.fills_ref().do_ref!(|fill| {
///         if (fill.expired() || fill.completed()) {
///             book_side.remove(fill.maker_order_id());
///         };
///     });
///     if (current_fills == max_fills) {
///         order_info.set_fill_limit_reached();
///     }
/// }
/// #ref:matching
fun match_against_book(self: &mut Book, order_info: &mut OrderInfo, timestamp: u64) {
    let is_bid = order_info.is_bid();
    let book_side = if (is_bid) &mut self.asks else &mut self.bids;

    let max_fills = constants::max_fills();
    let mut current_fills = 0;

    // Start from END (best price) and work backwards
    let mut i = book_side.length();

    while (i > 0 && current_fills < max_fills) {
        i = i - 1; // Move to next order (from best to worst)
        let maker_order = &mut book_side[i];

        if (!order_info.match_maker(maker_order, timestamp)) break;
        current_fills = current_fills + 1;
    };

    // Remove completed/expired orders
    // Iterate from end to avoid index shifting issues
    let mut to_remove = vector[];
    let mut g = book_side.length();
    while (g > 0) {
        g = g - 1;
        let order = &book_side[g];
        let order_id = order.order_id();

        let mut should_remove = false;
        order_info.fills_ref().do_ref!(|fill| {
            if (
                fill.maker_order_id() == order_id && 
                (fill.expired() || fill.completed())
            ) {
                should_remove = true;
            };
        });

        if (should_remove) {
            to_remove.push_back(g);
        };
    };

    // Remove in descending order (so indices remain valid)
    let remove_index = to_remove.length();
    let mut idx = 0;
    if (idx < remove_index) {
        while (idx < to_remove.length()) {
            let rem = to_remove[idx];
            book_side.remove(rem);
            idx = idx + 1;
        };
    };
    if (current_fills == max_fills) {
        order_info.set_fill_limit_reached();
    }
}

fun allocate_order_id(self: &mut Book): u64 {
    let order_id = self.next_order_id;
    self.next_order_id = self.next_order_id + 1;

    order_id
}

/// Balance accounting happens before this function is called
/// fun inject_limit_order(self: &mut Book, order_info: &OrderInfo,) {
///     let order = order_info.to_order();
///     if (order_info.is_bid()) {
///         self.bids.insert(order_info.order_id(), order);
///     } else {
///         self.asks.insert(order_info.order_id(), order);
///     };
/// }
/// Binary search for insertion point - REVERSED sorting
/// #ref:order_insert
fun find_insert_position(orders: &vector<Order>, price: u64, order_id: u64, is_bid: bool): u64 {
    let mut lo = 0;
    let mut hi = orders.length();

    // For bids: ascending order (best/highest prices at END)
    // For asks: descending order (best/lowest prices at END)
    while (lo < hi) {
        let mid = (hi - lo) / 2 + lo;
        let mid_price = orders[mid].price();
        let mid_order_id = orders[mid].order_id();

        // Sorting invariants:
        // - bids: ascending price (best/highest at END)
        // - asks: descending price (best/lowest at END)
        // - same price: descending order_id so older orders are closer to END
        let should_go_left = if (is_bid) {
            if (price < mid_price) {
                true
            } else if (price > mid_price) {
                false
            } else {
                order_id > mid_order_id
            }
        } else {
            if (price > mid_price) {
                true
            } else if (price < mid_price) {
                false
            } else {
                order_id > mid_order_id
            }
        };

        if (should_go_left) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    };
    lo
}

/// #ref:order_insert
fun inject_limit_order(self: &mut Book, order_info: &OrderInfo) {
    let order = order_info.to_order();
    let price = order_info.price();
    let order_id = order_info.order_id();
    let is_bid = order_info.is_bid();

    if (is_bid) {
        let index = find_insert_position(&self.bids, price, order_id, true);
        self.bids.insert(order, index);
    } else {
        let index = find_insert_position(&self.asks, price, order_id, false);
        self.asks.insert(order, index);
    };
}
