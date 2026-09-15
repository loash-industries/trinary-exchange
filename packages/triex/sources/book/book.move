// Copyright (c) Mysten Labs, Inc.
/// SPDX-License-Identifier: Apache-2.0

/// The book module contains the `Book` struct which represents the order book.
/// All order book operations are defined in this module.
///
/// This is the **multicoin** order book, and it stores orders in a sorted
/// `vector<Order>` keyed by nothing — order ids are opaque ascending `u64`
/// serials, and position in the vector is what encodes priority. That is a
/// deliberate, permanent choice, not a staging post: coin pools needed
/// unbounded depth and O(log n) access and got their own `BigVector`-backed
/// book in `triex::coin_book`, keyed by an encoded `u128` id. The two stacks run
/// side by side.
///
/// The fee arithmetic in `get_quantity_out` is shared verbatim with
/// `triex::coin_book`; only the traversal differs. Any change to it must land in
/// both files.
module triex::book {
    use triex::{constants, math, order::Order, order_info::OrderInfo, quote_fee};

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
        bids: vector<Order>, // sorted ASCENDING by price (best bid at END)
        asks: vector<Order>, // sorted DESCENDING by price (best ask at END)
        next_order_id: u64,
        // Divisor used in qty ↔ quote conversions. 1 for multicoin pools —
        // price = human × QUOTE_UNIT, with no float division. (The coin book
        // uses FLOAT_SCALING; see `triex::coin_book`.)
        price_scaling: u64,
    }

    /// === Public-Package Functions ===
    public(package) fun bids(self: &Book): &vector<Order> {
        &self.bids
    }

    public(package) fun asks(self: &Book): &vector<Order> {
        &self.asks
    }

    /// The `FLOAT_SCALING` constructor this module used to expose for coin pools is
    /// gone — they build their book through `coin_book::empty` now. Only the
    /// multicoin constructor below remains.
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

    #[test_only]
    /// Linear scan for an order's position in a plain `vector<Order>`. The book
    /// itself keys orders through `BigVector`, so nothing in production needs this;
    /// tests use it to assert ordering over a slice they have drained.
    public(package) fun find_order_index(
        orderbook: &vector<Order>,
        book_order_id: u64,
    ): Option<u64> {
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

                if (is_bid) {
                    // Bid takers pay the fee on top of the quote they spend, so
                    // part of the input is reserved for it — at the rate
                    // settlement charges, no more. Reserving a multiple of a
                    // known, exactly computable fee is not a reserve; it is input
                    // the swap never deploys and nobody receives, and it made the
                    // bid and ask sides of the same book quote asymmetrically.
                    let quantity_to_match = math::div(
                        quantity_in_left,
                        constants::float_scaling() + trade_specific_taker_fee,
                    );
                    // Capped inside the conversion rather than with a
                    // `.min(cur_quantity)` after it: the uncapped form has to
                    // land the whole scaled quotient in a `u64` before any cap
                    // applies, which a level resting near MIN_PRICE overflows —
                    // on an answer that was only ever going to be `cur_quantity`.
                    matched_base_quantity =
                        math::quote_to_qty_capped(
                            quantity_to_match,
                            cur_price,
                            self.price_scaling,
                            cur_quantity,
                        );
                    quantity_out = quantity_out + matched_base_quantity;
                    let matched_quote_quantity = math::qty_to_quote(
                        matched_base_quantity,
                        cur_price,
                        self.price_scaling,
                    );
                    // Same helper, same per-level basis as
                    // `calculate_partial_fill_balances`, so the quote reserves
                    // exactly the fee that settles.
                    let fee = quote_fee::fee_from_scaled_rate(
                        trade_specific_taker_fee,
                        matched_quote_quantity,
                    );
                    quantity_in_left = quantity_in_left - matched_quote_quantity - fee;
                } else {
                    // Ask takers have the fee deducted from the quote proceeds,
                    // so the full base input matches and the output is netted
                    // through the same helper settlement uses, per level, so the
                    // quote agrees with what calculate_partial_fill_balances
                    // settles.
                    matched_base_quantity = quantity_in_left.min(cur_quantity);
                    let matched_quote_quantity = math::qty_to_quote(
                        matched_base_quantity,
                        cur_price,
                        self.price_scaling,
                    );
                    let fee = quote_fee::fee_from_scaled_rate(
                        trade_specific_taker_fee,
                        matched_quote_quantity,
                    );
                    quantity_out = quantity_out + matched_quote_quantity - fee;
                    quantity_in_left = quantity_in_left - matched_base_quantity;
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

    /// Binary search for order by order_id in a sorted vector
    /// Handles both ascending (bids) and descending (asks) sorted vectors

    /// Modifies an order given order_id and new_quantity.
    /// New quantity must be less than the original quantity.
    /// Order must not have already expired.
    /// #ref:order_modify

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

    /// Matches the given order and quantity against the order book.
    /// If is_bid, it will match against asks, otherwise against bids.
    /// Mutates the order and the maker order as necessary.
    /// #ref:matching
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
}
