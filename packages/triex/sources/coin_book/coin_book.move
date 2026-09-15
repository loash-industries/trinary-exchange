// Copyright (c) Mysten Labs, Inc.
/// SPDX-License-Identifier: Apache-2.0

/// The book module contains the `Book` struct which represents the order book.
/// All order book operations are defined in this module.
///
/// Coin-pool fork of `triex::book`, and the reason the fork exists: orders live
/// in a `BigVector<Order>` keyed by the encoded order id rather than in a sorted
/// `vector<Order>`. Insert, cancel, modify and lookup are all O(log n) by key,
/// and the book no longer rewrites one flat vector per placement, so depth is not
/// bounded by object size. Multicoin pools keep the vector book in `triex::book`.
///
/// Iteration order is deliberately identical to the vector book's, so matching,
/// level2 and pagination observe orders in exactly the same sequence:
///   - bids: keys ascend by price, best bid is the max key — walk `max_slice`
///     then `prev_slice`.
///   - asks: keys ascend by price, best ask is the min key — walk `min_slice`
///     then `next_slice`.
/// Within one price level the per-side sequence counters (bids descending, asks
/// ascending — see `constants::start_bid_order_id`) put the oldest order first on
/// both sides, which is what makes key order equal price-time priority.
///
/// The fee arithmetic in `get_quantity_out` is triex-specific and shared with
/// `triex::book` verbatim; only the traversal differs. Any change to it must land
/// in both files.
module triex::coin_book {
    use triex::{
        big_vector::{Self, BigVector, slice_borrow, slice_borrow_mut},
        coin_order::Order,
        coin_order_info::OrderInfo,
        constants,
        math,
        quote_fee,
        utils
    };

    /// === Errors ===
    const EInvalidAmountIn: u64 = 1;
    const EEmptyOrderbook: u64 = 2;
    const EInvalidPriceRange: u64 = 3;
    const EInvalidTicks: u64 = 4;
    const ENewQuantityMustBeLessThanOriginal: u64 = 7;
    // Note: there is no book-level "order not found" code here. A cancel, modify
    // or lookup of an absent id aborts inside `big_vector` with its own
    // `ENotFound`, because the id *is* the storage key — the book never searches
    // for it, so it has no opportunity to raise a code of its own.

    public fun invalid_amount_in(): u64 { EInvalidAmountIn }

    public fun empty_orderbook(): u64 { EEmptyOrderbook }

    public fun invalid_price_range(): u64 { EInvalidPriceRange }

    public fun invalid_ticks(): u64 { EInvalidTicks }

    public fun new_quantity_must_be_less_than_original(): u64 { ENewQuantityMustBeLessThanOriginal }

    /// === Structs ===
    public struct Book has store {
        bids: BigVector<Order>, // keyed ascending by price; best bid is the max key
        asks: BigVector<Order>, // keyed ascending by price; best ask is the min key
        next_bid_order_id: u64, // descends from START_BID_ORDER_ID
        next_ask_order_id: u64, // ascends from START_ASK_ORDER_ID
        // Divisor used in qty ↔ quote conversions. Always FLOAT_SCALING (1e9) for
        // coin pools — price = human × QUOTE_UNIT × FLOAT_SCALING / BASE_UNIT.
        // Kept as a field, rather than read from `constants` at each use, so the
        // conversion helpers stay call-compatible with the multicoin book, which
        // varies it.
        price_scaling: u64,
    }

    /// === Public-Package Functions ===
    public(package) fun bids(self: &Book): &BigVector<Order> {
        &self.bids
    }

    public(package) fun asks(self: &Book): &BigVector<Order> {
        &self.asks
    }

    public(package) fun empty(ctx: &mut TxContext): Book {
        Book {
            bids: big_vector::empty(
                constants::max_slice_size(),
                constants::max_fan_out(),
                ctx,
            ),
            asks: big_vector::empty(
                constants::max_slice_size(),
                constants::max_fan_out(),
                ctx,
            ),
            next_bid_order_id: constants::start_bid_order_id(),
            next_ask_order_id: constants::start_ask_order_id(),
            price_scaling: constants::float_scaling(),
        }
    }

    public(package) fun price_scaling(self: &Book): u64 {
        self.price_scaling
    }

    /// Creates a new order.
    /// Order is matched against the book and injected into the book if necessary.
    /// If order is IOC or fully executed, it will not be injected.
    public(package) fun create_order(self: &mut Book, order_info: &mut OrderInfo, timestamp: u64) {
        order_info.validate_inputs(timestamp);
        // The id is derived from the order's own price, so it is only well-formed
        // once `validate_inputs` has bounded the price at `MAX_PRICE` — the widest
        // value bits 64..126 of the key can hold.
        let order_id = utils::encode_order_id(
            order_info.is_bid(),
            order_info.price(),
            self.get_order_id(order_info.is_bid()),
        );
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
        let input_fee_rate = math::mul(
            constants::fee_penalty_multiplier(),
            trade_specific_taker_fee,
        );
        let fee_waived = false;

        let mut quantity_out = 0;
        let mut quantity_in_left = if (is_bid) quote_quantity else base_quantity;

        let book_side = if (is_bid) &self.asks else &self.bids;
        // Best price first: asks ascend from the min key, bids descend from the max.
        let (mut ref, mut offset) = if (is_bid) book_side.min_slice() else book_side.max_slice();
        let max_fills = constants::max_fills();
        let mut current_fills = 0;

        while (!ref.is_null() && quantity_in_left > 0 && current_fills < max_fills) {
            let order = slice_borrow(book_side.borrow_slice(ref), offset);
            let cur_price = order.price();
            let cur_quantity = order.quantity() - order.filled_quantity();

            if (current_timestamp <= order.expire_timestamp()) {
                let mut matched_base_quantity;

                if (is_bid) {
                    // Bid takers pay the fee on top of the quote they spend, so
                    // part of the input is reserved for it.
                    let quantity_to_match = if (fee_waived) {
                        quantity_in_left
                    } else {
                        math::div(quantity_in_left, constants::float_scaling() + input_fee_rate)
                    };
                    matched_base_quantity =
                        math::quote_to_qty(quantity_to_match, cur_price, self.price_scaling).min(
                            cur_quantity,
                        );
                    let matched_quote_quantity = math::qty_to_quote(
                        matched_base_quantity,
                        cur_price,
                        self.price_scaling,
                    );
                    // The matcher steps over a maker that cannot settle for a non-zero
                    // quote — retiring it when the maker itself is under the bound,
                    // skipping it when the shortfall is the taker's own residue — and
                    // reaches the orders behind it either way. The quote has to walk the
                    // same way: stopping here would under-report every level behind the
                    // first such maker while settlement filled straight through it.
                    if (matched_base_quantity == 0 || matched_quote_quantity > 0) {
                        quantity_out = quantity_out + matched_base_quantity;
                        quantity_in_left = quantity_in_left - matched_quote_quantity;
                        if (!fee_waived) {
                            quantity_in_left =
                                quantity_in_left - math::mul(matched_quote_quantity, input_fee_rate);
                        };
                    };
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
                    // As above: a maker worth no quote is stepped over, not treated as
                    // the end of the book.
                    if (matched_base_quantity == 0 || matched_quote_quantity > 0) {
                        let fee = if (fee_waived) {
                            0
                        } else {
                            quote_fee::fee_from_scaled_rate(
                                trade_specific_taker_fee,
                                matched_quote_quantity,
                            )
                        };
                        quantity_out = quantity_out + matched_quote_quantity - fee;
                        quantity_in_left = quantity_in_left - matched_base_quantity;
                    };
                };

                if (matched_base_quantity == 0) break;
            };

            (ref, offset) = if (is_bid) book_side.next_slice(ref, offset)
            else book_side.prev_slice(ref, offset);
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
    public(package) fun cancel_order(self: &mut Book, order_id: u128): Order {
        self.book_side_mut(order_id).remove(order_id)
    }

    /// Modifies an order given order_id and new_quantity.
    /// New quantity must be less than the original quantity, and must leave a
    /// remainder at or above the order's zero-quote bound — see `coin_order::modify`.
    /// Order must not have already expired.
    /// #ref:order_modify
    public(package) fun modify_order(
        self: &mut Book,
        order_id: u128,
        new_quantity: u64,
        timestamp: u64,
    ): (u64, &Order) {
        let price_scaling = self.price_scaling;
        let order = self.book_side_mut(order_id).borrow_mut(order_id);
        assert!(new_quantity < order.quantity(), new_quantity_must_be_less_than_original());
        let cancel_quantity = order.quantity() - new_quantity;
        order.modify(new_quantity, timestamp, price_scaling);

        (cancel_quantity, order)
    }

    /// Returns the mid price of the order book.
    /// #ref:mid_price
    public(package) fun mid_price(self: &Book, current_timestamp: u64): u64 {
        let (mut ask_ref, mut ask_offset) = self.asks.min_slice();
        let (mut bid_ref, mut bid_offset) = self.bids.max_slice();
        let mut best_ask_price = 0;
        let mut best_bid_price = 0;

        // Walk past expired orders at the top of each side, exactly as the vector
        // book does, so a stale front row never becomes the reported mid.
        while (!ask_ref.is_null()) {
            let best_ask_order = slice_borrow(
                self.asks.borrow_slice(ask_ref),
                ask_offset,
            );
            if (current_timestamp <= best_ask_order.expire_timestamp()) {
                best_ask_price = best_ask_order.price();
                break
            };
            (ask_ref, ask_offset) = self.asks.next_slice(ask_ref, ask_offset);
        };

        while (!bid_ref.is_null()) {
            let best_bid_order = slice_borrow(
                self.bids.borrow_slice(bid_ref),
                bid_offset,
            );
            if (current_timestamp <= best_bid_order.expire_timestamp()) {
                best_bid_price = best_bid_order.price();
                break
            };
            (bid_ref, bid_offset) = self.bids.prev_slice(bid_ref, bid_offset);
        };

        assert!(best_ask_price > 0 && best_bid_price > 0, empty_orderbook());

        math::mul(best_ask_price + best_bid_price, constants::half())
    }

    /// Returns the best bids and asks.
    /// The number of ticks is the number of price levels to return.
    /// The price_low and price_high are the range of prices to return.
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

        // Convert the price bounds into keys, so the walk can be seeded directly at
        // the requested end of the range instead of scanning in from the edge of
        // the book. Both sides still start at their best price within the range.
        let msb = if (is_bid) {
            0u128
        } else {
            1u128 << 127
        };
        let key_low = ((price_low as u128) << 64) + msb;
        let key_high = ((price_high as u128) << 64) + (((1u128 << 64) - 1) as u128) + msb;
        let book_side = if (is_bid) &self.bids else &self.asks;
        let (mut ref, mut offset) = if (is_bid) {
            book_side.slice_before(key_high)
        } else {
            book_side.slice_following(key_low)
        };
        let mut ticks_left = ticks;
        let mut cur_price = 0;
        let mut cur_quantity = 0;

        while (!ref.is_null() && ticks_left > 0) {
            let order = slice_borrow(book_side.borrow_slice(ref), offset);

            if (current_timestamp <= order.expire_timestamp()) {
                // Equivalent to decoding the price out of the key: the id encodes
                // the order's own price, and `Order` carries it directly.
                let order_price = order.price();

                // Walked off the far end of the requested range; the side is
                // price-ordered, so nothing deeper qualifies either.
                if ((is_bid && order_price < price_low) || (!is_bid && order_price > price_high)) {
                    break
                };

                if (
                    cur_price == 0 && (
                        (is_bid && order_price <= price_high) || (
                            !is_bid && order_price >= price_low,
                        ),
                    )
                ) {
                    cur_price = order_price
                };

                if (cur_price != 0 && order_price != cur_price) {
                    price_vec.push_back(cur_price);
                    quantity_vec.push_back(cur_quantity);
                    cur_price = order_price;
                    cur_quantity = 0;
                    ticks_left = ticks_left - 1;
                    if (ticks_left == 0) break;
                };
                if (cur_price != 0) {
                    cur_quantity = cur_quantity + order.quantity() - order.filled_quantity();
                };
            };

            (ref, offset) = if (is_bid) book_side.prev_slice(ref, offset)
            else book_side.next_slice(ref, offset);
        };

        if (cur_price != 0 && ticks_left > 0) {
            price_vec.push_back(cur_price);
            quantity_vec.push_back(cur_quantity);
        };

        (price_vec, quantity_vec)
    }

    /// #ref:order_query
    public(package) fun get_order(self: &Book, order_id: u128): Order {
        let order = self.book_side(order_id).borrow(order_id);

        order.copy_order()
    }

    /// === Private Functions ===
    /// Access side of book where order_id belongs. The side is carried in the
    /// id's top bit, so no lookup is needed to route by it.
    fun book_side_mut(self: &mut Book, order_id: u128): &mut BigVector<Order> {
        let (is_bid, _, _) = utils::decode_order_id(order_id);
        if (is_bid) {
            &mut self.bids
        } else {
            &mut self.asks
        }
    }

    fun book_side(self: &Book, order_id: u128): &BigVector<Order> {
        let (is_bid, _, _) = utils::decode_order_id(order_id);
        if (is_bid) {
            &self.bids
        } else {
            &self.asks
        }
    }

    /// Matches the given order and quantity against the order book.
    /// If is_bid, it will match against asks, otherwise against bids.
    /// Mutates the order and the maker order as necessary.
    /// #ref:matching
    fun match_against_book(self: &mut Book, order_info: &mut OrderInfo, timestamp: u64) {
        let is_bid = order_info.is_bid();
        let book_side = if (is_bid) &mut self.asks else &mut self.bids;
        let (mut ref, mut offset) = if (is_bid) book_side.min_slice() else book_side.max_slice();
        let max_fills = constants::max_fills();
        let mut current_fills = 0;

        while (!ref.is_null() &&
            current_fills < max_fills) {
            let maker_order = slice_borrow_mut(
                book_side.borrow_slice_mut(ref),
                offset,
            );
            // Only a `Stopped` outcome ends the walk. A maker that cannot settle for
            // a non-zero quote is skipped or retired, and the orders behind it stay
            // reachable — treating that as terminal wedged the whole side.
            if (!order_info.match_maker(maker_order, timestamp).continues()) break;
            (ref, offset) = if (is_bid) book_side.next_slice(ref, offset)
            else book_side.prev_slice(ref, offset);
            current_fills = current_fills + 1;
        };

        // Resting orders this match consumed or expired leave the book. Removal is
        // by key, so unlike the vector book there is no index bookkeeping to keep
        // valid across removals.
        order_info.fills_ref().do_ref!(|fill| {
            if (fill.expired() || fill.completed()) {
                book_side.remove(fill.maker_order_id());
            };
        });

        if (current_fills == max_fills) {
            order_info.set_fill_limit_reached();
        }
    }

    /// Allocate the next sequence number for `is_bid`. Bids count down and asks
    /// count up so that, at a given price, an older order always sorts ahead of a
    /// newer one in the direction that side is walked.
    fun get_order_id(self: &mut Book, is_bid: bool): u64 {
        if (is_bid) {
            self.next_bid_order_id = self.next_bid_order_id - 1;
            self.next_bid_order_id
        } else {
            self.next_ask_order_id = self.next_ask_order_id + 1;
            self.next_ask_order_id
        }
    }

    /// Balance accounting happens before this function is called
    /// #ref:order_insert
    fun inject_limit_order(self: &mut Book, order_info: &OrderInfo) {
        let order = order_info.to_order();
        if (order_info.is_bid()) {
            self.bids.insert(order_info.order_id(), order);
        } else {
            self.asks.insert(order_info.order_id(), order);
        };
    }

    // === Test Helpers ===
    #[test_only]
    /// Build a book with explicit `BigVector` geometry so a benchmark can vary slice
    /// size against a fixed workload. Production always takes the geometry from
    /// `constants`; nothing outside tests may choose it.
    ///
    /// `price_scaling` is overridable too, so a benchmark can neutralise the
    /// arithmetic difference between this book and the multicoin one. Coin pools
    /// always use `FLOAT_SCALING`, whose `qty_to_quote` is a u128 multiply *and* a
    /// divide; multicoin uses 1, a bare multiply. Comparing the two engines without
    /// matching this measures the conversion math as well as the storage.
    public fun empty_with_geometry_scaled(
        max_slice_size: u64,
        max_fan_out: u64,
        price_scaling: u64,
        ctx: &mut TxContext,
    ): Book {
        Book {
            bids: big_vector::empty(max_slice_size, max_fan_out, ctx),
            asks: big_vector::empty(max_slice_size, max_fan_out, ctx),
            next_bid_order_id: constants::start_bid_order_id(),
            next_ask_order_id: constants::start_ask_order_id(),
            price_scaling,
        }
    }

    #[test_only]
    /// Tear down a book built by `empty_with_geometry_scaled`. `Order` is droppable, so the
    /// slices can be released without draining them order by order.
    public fun drop_for_testing(self: Book) {
        let Book {
            bids,
            asks,
            next_bid_order_id: _,
            next_ask_order_id: _,
            price_scaling: _,
        } = self;
        bids.drop();
        asks.drop();
    }

    #[test_only]
    /// Tree geometry, for asserting which regime a benchmark actually exercised.
    public fun shape(self: &Book): (u8, u64, u8, u64) {
        (self.bids.depth(), self.bids.length(), self.asks.depth(), self.asks.length())
    }
}
