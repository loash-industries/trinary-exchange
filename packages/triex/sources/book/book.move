// Copyright (c) Mysten Labs, Inc.
/// SPDX-License-Identifier: Apache-2.0

/// The book module contains the `Book` struct which represents the order book.
/// All order book operations are defined in this module.
///
/// One book serves both pool kinds. Coin pools build it with `empty`
/// (`price_scaling = FLOAT_SCALING`); multicoin pools with `empty_multicoin`
/// (`price_scaling = 1`). Everything else — storage, matching, validation, the
/// dry-run quote and the hot-buffer size — is the same code.
///
/// The zero-quote guards (the placement size bound, `MatchOutcome::Skipped`, the
/// dry-run step-over) exist for coin pools, where a fractional price times a
/// small quantity can floor to zero quote. A multicoin quantity is a whole number
/// of indivisible units and its price is a whole number of quote units, so every
/// non-empty fill is worth at least one quote unit: at `price_scaling = 1`,
/// `min_qty_for_nonzero_quote` is 1 and the guards never fire.
///
/// Orders live in a `BigVector<Order>` keyed by an encoded `u128` order id, with
/// the best orders of each side held inline in the pool object. Insert, cancel,
/// modify and lookup are O(log n) by key, and no operation rewrites the whole
/// book, so depth is not bounded by Sui's maximum object size.
///
/// Iteration order is identical to the flat vector book this replaced, so
/// matching, level2 and pagination observe orders in exactly the same sequence:
///   - bids: keys ascend by price, best bid is the max key — walk `max_slice`
///     then `prev_slice`.
///   - asks: keys ascend by price, best ask is the min key — walk `min_slice`
///     then `next_slice`.
/// Within one price level the per-side sequence counters (bids descending, asks
/// ascending — see `constants::start_bid_order_id`) put the oldest order first on
/// both sides, which is what makes key order equal price-time priority.
module triex::book {
    use triex::{
        big_vector::{Self, BigVector, SliceRef, slice_borrow, slice_borrow_mut},
        order::Order,
        order_info::OrderInfo,
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

    /// === Top-of-book buffer ===
    /// Each side keeps its best `HOT_CAPACITY` orders inline in the `Book` and the
    /// rest in the `BigVector` behind it. One invariant ties the two stores together:
    ///
    ///   *every order in a side's hot buffer is better-priced than every order in
    ///   that side's tree*
    ///
    /// so the pair concatenates into a single price-ordered sequence, and iterating a
    /// side means walking the buffer from its back and then continuing into the tree.
    /// `Cursor` is the only thing that needs to know this.
    ///
    /// **Spill is one-way.** Orders leave the buffer for the tree on overflow and
    /// never travel back; the tree drains in place through matching and cancels, and
    /// the buffer repopulates on its own, because any newly posted order at a
    /// competitive price beats the tree's best key and is admitted inline.
    /// Refill-on-drain would make every sweep that empties the buffer pay tree
    /// *removals* to repopulate it, and the repopulated buffer would then re-spill on
    /// the placements that follow — paying twice for one sweep. Removing the return
    /// path was the largest single improvement in the multicoin storage experiment
    /// (42–47% off a 10-order sweep).
    ///
    /// On genuine overflow a side spills down to its spill target rather than back to
    /// capacity, leaving headroom for the placements that follow. Held exactly *at*
    /// capacity the buffer would spill on every top-of-book placement, paying a tree
    /// write each time — precisely the cost it exists to avoid. The gap to capacity
    /// sets how *lumpy* spilling is, not how much it costs.
    ///
    /// The capacity is deliberately small, and the same for both pool kinds. Each
    /// inline order is rewritten on every transaction that touches the pool, at
    /// ~7.1k MIST, while the benefit of keeping churn off the tree saturates at
    /// about a dozen orders: the storage experiment measured a 64-order buffer at
    /// 74% more per churn operation, and a 32-order one worse than 16 at depths
    /// 30/150/300. A hot cache is an asset only while it is small.
    const HOT_CAPACITY: u64 = 16;
    const HOT_SPILL_TARGET: u64 = 12;

    /// === Structs ===
    public struct Book has store {
        bids: BigVector<Order>, // keyed ascending by price; best bid is the max key
        asks: BigVector<Order>, // keyed ascending by price; best ask is the min key
        // Inline top-of-book buffers: the best `HOT_CAPACITY` orders of each side,
        // held in the pool object itself rather than behind a dynamic field. A trade
        // at the inside market — which is nearly all of them — then reads and writes
        // no dynamic field at all.
        //
        // Both are stored **worst-priced first**, so the best order of either side is
        // the last element: consuming it is a `pop_back` and posting a new best price
        // is a `push_back`, neither of which moves anything. That means `hot_asks`
        // runs opposite to the ask tree's ascending key order — deliberately, so the
        // two sides share one set of helpers rather than mirroring each other.
        hot_bids: vector<Order>,
        hot_asks: vector<Order>,
        next_bid_order_id: u64, // descends from START_BID_ORDER_ID
        next_ask_order_id: u64, // ascends from START_ASK_ORDER_ID
        // Divisor used in qty ↔ quote conversions: FLOAT_SCALING (1e9) for coin
        // pools, where price = human × QUOTE_UNIT × FLOAT_SCALING / BASE_UNIT, and 1
        // for multicoin pools, where price = human × QUOTE_UNIT with no division.
        price_scaling: u64,
    }

    /// A position in one side of the book.
    ///
    /// A side spans two stores — the inline hot buffer and the `BigVector` behind it
    /// — and this addresses both as one sequence running best price first, so callers
    /// iterate a side without knowing where any given order lives.
    public struct Cursor has copy, drop, store {
        /// Index into the hot buffer, meaningful only while `in_hot`. The buffer is
        /// stored worst-first, so a walk runs this down from `length - 1` to 0.
        hot_ix: u64,
        in_hot: bool,
        /// Position in the tree, once the hot buffer is used up. `none` both before
        /// the walk reaches the tree and after it runs off the end; `in_hot`
        /// disambiguates the two.
        tree: Option<SliceRef>,
        offset: u64,
    }

    /// === Public-Package Functions ===
    /// The cold tree for a side. This is **not** the whole side: its best
    /// `HOT_CAPACITY` orders are in `hot_bids` / `hot_asks`. Callers that need to see
    /// a side whole must go through `Cursor`, `get_order` or `side_length`.
    public(package) fun bids(self: &Book): &BigVector<Order> {
        &self.bids
    }

    public(package) fun asks(self: &Book): &BigVector<Order> {
        &self.asks
    }

    public(package) fun hot_bids(self: &Book): &vector<Order> {
        &self.hot_bids
    }

    public(package) fun hot_asks(self: &Book): &vector<Order> {
        &self.hot_asks
    }

    /// Orders resting on a side, across both stores.
    public(package) fun side_length(self: &Book, is_bid: bool): u64 {
        if (is_bid) {
            self.hot_bids.length() + self.bids.length()
        } else {
            self.hot_asks.length() + self.asks.length()
        }
    }

    public(package) fun side_is_empty(self: &Book, is_bid: bool): bool {
        self.side_length(is_bid) == 0
    }

    // === Cursor ===

    public(package) fun cursor_is_null(self: &Cursor): bool {
        !self.in_hot && self.tree.is_none()
    }

    /// Position at the best-priced order of a side, or a null cursor if it is empty.
    public(package) fun cursor_begin(self: &Book, is_bid: bool): Cursor {
        let hot = if (is_bid) &self.hot_bids else &self.hot_asks;
        let n = hot.length();
        if (n > 0) {
            // Worst-first storage: the best order is the last element.
            return Cursor { hot_ix: n - 1, in_hot: true, tree: option::none(), offset: 0 }
        };
        self.cursor_tree_begin(is_bid)
    }

    /// Position at the first order strictly worse than `key` in book order.
    ///
    /// Used for pagination, where the anchor is exclusive and positional: `key` need
    /// not name a live order, and an id that has since left the book resolves to the
    /// position it would have occupied.
    public(package) fun cursor_after(self: &Book, is_bid: bool, key: u128): Cursor {
        let hot = if (is_bid) &self.hot_bids else &self.hot_asks;
        // Scan the buffer best-first for the first order the anchor is better than.
        let mut i = hot.length();
        while (i > 0) {
            if (better(is_bid, key, hot.borrow(i - 1).order_id())) {
                return Cursor { hot_ix: i - 1, in_hot: true, tree: option::none(), offset: 0 }
            };
            i = i - 1;
        };

        // At or past every hot order, so resume in the tree. Both seeks below also do
        // the right thing for an anchor that lies in the *hot* key range: such a key
        // is better than every tree key, so each lands on the tree's own best order.
        let cold = if (is_bid) &self.bids else &self.asks;
        let (r, o) = if (is_bid) cold.slice_before(key) else cold.slice_following(key);
        if (r.is_null()) return cursor_exhausted();
        let cur = Cursor { hot_ix: 0, in_hot: false, tree: option::some(r), offset: o };
        // `slice_before` is already strictly-before, but `slice_following` is
        // inclusive, so an exact hit on the ask side has to be stepped over to keep
        // the anchor exclusive on both sides.
        if (!is_bid && slice_borrow(cold.borrow_slice(r), o).order_id() == key) {
            self.cursor_next(is_bid, cur)
        } else {
            cur
        }
    }

    /// Advance one order towards the worse side of the book.
    public(package) fun cursor_next(self: &Book, is_bid: bool, cur: Cursor): Cursor {
        if (cur.in_hot) {
            if (cur.hot_ix > 0) {
                return Cursor {
                    hot_ix: cur.hot_ix - 1,
                    in_hot: true,
                    tree: option::none(),
                    offset: 0,
                }
            };
            // Buffer exhausted: fall through into the tree. This is the only dynamic
            // field a top-of-book walk touches, and only if it runs past the buffer.
            return self.cursor_tree_begin(is_bid)
        };
        if (cur.tree.is_none()) return cursor_exhausted();

        let r = *cur.tree.borrow();
        let cold = if (is_bid) &self.bids else &self.asks;
        let (nr, no) = if (is_bid) {
            cold.prev_slice(r, cur.offset)
        } else {
            cold.next_slice(r, cur.offset)
        };
        if (nr.is_null()) {
            cursor_exhausted()
        } else {
            Cursor { hot_ix: 0, in_hot: false, tree: option::some(nr), offset: no }
        }
    }

    public(package) fun cursor_borrow(self: &Book, is_bid: bool, cur: &Cursor): &Order {
        if (cur.in_hot) {
            let hot = if (is_bid) &self.hot_bids else &self.hot_asks;
            return hot.borrow(cur.hot_ix)
        };
        let cold = if (is_bid) &self.bids else &self.asks;
        slice_borrow(cold.borrow_slice(*cur.tree.borrow()), cur.offset)
    }

    fun cursor_exhausted(): Cursor {
        Cursor { hot_ix: 0, in_hot: false, tree: option::none(), offset: 0 }
    }

    fun cursor_tree_begin(self: &Book, is_bid: bool): Cursor {
        let cold = if (is_bid) &self.bids else &self.asks;
        let (r, o) = if (is_bid) cold.max_slice() else cold.min_slice();
        if (r.is_null()) {
            cursor_exhausted()
        } else {
            Cursor { hot_ix: 0, in_hot: false, tree: option::some(r), offset: o }
        }
    }

    fun cursor_borrow_mut(self: &mut Book, is_bid: bool, cur: &Cursor): &mut Order {
        if (cur.in_hot) {
            let hot = if (is_bid) &mut self.hot_bids else &mut self.hot_asks;
            return hot.borrow_mut(cur.hot_ix)
        };
        let cold = if (is_bid) &mut self.bids else &mut self.asks;
        slice_borrow_mut(cold.borrow_slice_mut(*cur.tree.borrow()), cur.offset)
    }

    /// The coin-pool book: `price_scaling = FLOAT_SCALING`. Multicoin pools use
    /// `empty_multicoin`.
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
            hot_bids: vector[],
            hot_asks: vector[],
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

        let mut quantity_out = 0;
        // Settlement charges the taker fee once, on the order's whole matched
        // quote, so the walk tallies that quote and the fee comes off after it.
        // A bid pays its fee on top of the quote it spends, so its input funds at
        // most `budget` of quote, the largest amount with `budget * (1 + r)` still
        // inside the input; the walk spends against that. Reserving the fee at
        // the rate settlement charges and no more keeps the bid and ask sides of
        // the same book quoting symmetrically.
        let mut quantity_in_left = if (is_bid) {
            math::div(quote_quantity, constants::float_scaling() + trade_specific_taker_fee)
        } else {
            base_quantity
        };
        let mut matched_quote = 0;

        // Best price first, across the hot buffer and then the tree behind it.
        let maker_is_bid = !is_bid;
        let mut cur = self.cursor_begin(maker_is_bid);
        let max_fills = constants::max_fills();
        let mut current_fills = 0;

        while (!cur.cursor_is_null() && quantity_in_left > 0 && current_fills < max_fills) {
            let order = self.cursor_borrow(maker_is_bid, &cur);
            let cur_price = order.price();
            let cur_quantity = order.quantity() - order.filled_quantity();

            if (current_timestamp <= order.expire_timestamp()) {
                let mut matched_base_quantity;

                if (is_bid) {
                    // Capped inside the conversion rather than with a
                    // `.min(cur_quantity)` after it: the uncapped form has to
                    // land the whole scaled quotient in a `u64` before any cap
                    // applies, which a level resting near MIN_PRICE overflows —
                    // on an answer that was only ever going to be `cur_quantity`.
                    matched_base_quantity =
                        math::quote_to_qty_capped(
                            quantity_in_left,
                            cur_price,
                            self.price_scaling,
                            cur_quantity,
                        );
                    matched_base_quantity =
                        self.extend_if_affordable(
                            matched_base_quantity,
                            cur_quantity,
                            cur_price,
                            matched_quote,
                            quote_quantity,
                            trade_specific_taker_fee,
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
                        matched_quote = matched_quote + matched_quote_quantity;
                        // A unit `extend_if_affordable` added is paid for out of the fee's
                        // floor, not the budget, so it can overrun the budget by that unit.
                        quantity_in_left =
                            quantity_in_left - matched_quote_quantity.min(quantity_in_left);
                        // The budget ran out inside this maker. Execution fills the
                        // returned base greedily, so any further unit would come
                        // from this maker too — under one floor with this piece —
                        // never from a worse one. Pricing a unit behind it at its
                        // own floor under-costs the plan, and the swap then needs
                        // more quote than it was given.
                        if (matched_base_quantity < cur_quantity) break;
                    };
                } else {
                    // Ask takers have the fee deducted from the quote proceeds,
                    // so the full base input matches; the fee is netted off the
                    // output once the walk is done.
                    matched_base_quantity = quantity_in_left.min(cur_quantity);
                    let matched_quote_quantity = math::qty_to_quote(
                        matched_base_quantity,
                        cur_price,
                        self.price_scaling,
                    );
                    // As above: a maker worth no quote is stepped over, not treated as
                    // the end of the book.
                    if (matched_base_quantity == 0 || matched_quote_quantity > 0) {
                        matched_quote = matched_quote + matched_quote_quantity;
                        quantity_out = quantity_out + matched_quote_quantity;
                        quantity_in_left = quantity_in_left - matched_base_quantity;
                    };
                };

                if (matched_base_quantity == 0) break;
            };

            cur = self.cursor_next(maker_is_bid, cur);
            current_fills = current_fills + 1;
        };

        // Same helper, same aggregate basis as `calculate_partial_fill_balances`,
        // so the quote reserves exactly the fee that settles. A bid cannot
        // underflow here: either `matched_quote <= budget`, and flooring the fee
        // keeps `matched_quote + fee <= budget * (1 + r) <= quote_quantity`, or
        // `extend_if_affordable` took the last unit having checked exactly that
        // sum, and the spent budget ended the walk.
        let fee = quote_fee::fee_from_scaled_rate(trade_specific_taker_fee, matched_quote);
        if (is_bid) {
            (quantity_out, quote_quantity - matched_quote - fee)
        } else {
            (quantity_in_left, quantity_out - fee)
        }
    }

    /// One unit past the fee-reserving estimate, if the exact settle cost still fits.
    ///
    /// The budget `quote_quantity / (1 + fee)` reserves the fee on the unfloored
    /// quote, but settlement floors that fee once on the order's whole matched
    /// quote, so the budget can fall a unit short of what the input actually
    /// buys. The shortfall is at most one unit whenever a unit costs at least one
    /// raw quote; checking the order's total with the settle-side helper keeps the
    /// quote exact without over-committing.
    fun extend_if_affordable(
        self: &Book,
        base_quantity: u64,
        cur_quantity: u64,
        price: u64,
        matched_quote: u64,
        quote_quantity: u64,
        taker_fee: u64,
    ): u64 {
        if (base_quantity >= cur_quantity) return base_quantity;
        let total =
            matched_quote + math::qty_to_quote(base_quantity + 1, price, self.price_scaling);
        if (total > quote_quantity) return base_quantity;
        let fee = quote_fee::fee_from_scaled_rate(taker_fee, total);
        if (fee > quote_quantity - total) return base_quantity;
        base_quantity + 1
    }

    /// Cancels an order given order_id.
    ///
    /// Nothing refills the buffer behind the removal: spill is one-way, and a
    /// drained buffer repopulates from the next competitively-priced placement.
    /// #ref:order_cancel
    public(package) fun cancel_order(self: &mut Book, order_id: u128): Order {
        self.remove_order(order_id)
    }

    /// Modifies an order given order_id and new_quantity.
    /// New quantity must be less than the original quantity, and must leave a
    /// remainder at or above the order's zero-quote bound — see `order::modify`.
    /// Order must not have already expired.
    /// #ref:order_modify
    public(package) fun modify_order(
        self: &mut Book,
        order_id: u128,
        new_quantity: u64,
        timestamp: u64,
    ): (u64, &Order) {
        let price_scaling = self.price_scaling;
        let order = self.borrow_order_mut(order_id);
        assert!(new_quantity < order.quantity(), new_quantity_must_be_less_than_original());
        let cancel_quantity = order.quantity() - new_quantity;
        order.modify(new_quantity, timestamp, price_scaling);

        (cancel_quantity, order)
    }

    /// #ref:order_query
    public(package) fun get_order(self: &Book, order_id: u128): Order {
        let (is_bid, _, _) = utils::decode_order_id(order_id);
        let hot = if (is_bid) &self.hot_bids else &self.hot_asks;
        let at = hot_find(hot, order_id);
        if (at.is_some()) {
            return hot.borrow(at.destroy_some()).copy_order()
        };

        self.book_side(order_id).borrow(order_id).copy_order()
    }


    /// The multicoin book: `price_scaling = 1`. Coin pools use `empty`.
    public(package) fun empty_multicoin(ctx: &mut TxContext): Book {
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
            hot_bids: vector[],
            hot_asks: vector[],
            next_bid_order_id: constants::start_bid_order_id(),
            next_ask_order_id: constants::start_ask_order_id(),
            price_scaling: 1,
        }
    }


    /// Returns the mid price of the order book.
    /// #ref:mid_price
    public(package) fun mid_price(self: &Book, current_timestamp: u64): u64 {
        let mut best_ask_price = 0;
        let mut best_bid_price = 0;

        // Find the first non-expired ask, walking the side best price first.
        let mut cur = self.cursor_begin(false);
        while (!cur.cursor_is_null()) {
            let order = self.cursor_borrow(false, &cur);
            if (current_timestamp <= order.expire_timestamp()) {
                best_ask_price = order.price();
                break
            };
            cur = self.cursor_next(false, cur);
        };

        // Same for bids.
        let mut cur = self.cursor_begin(true);
        while (!cur.cursor_is_null()) {
            let order = self.cursor_borrow(true, &cur);
            if (current_timestamp <= order.expire_timestamp()) {
                best_bid_price = order.price();
                break
            };
            cur = self.cursor_next(true, cur);
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

        let mut ticks_left = ticks;
        let mut cur_price = 0;
        let mut cur_quantity = 0;

        // Start at the best price and work away from it.
        let mut cur = self.cursor_begin(is_bid);

        while (!cur.cursor_is_null() && ticks_left > 0) {
            let order = self.cursor_borrow(is_bid, &cur);

            if (current_timestamp <= order.expire_timestamp()) {
                let order_price = order.price();

                // Walked past the far end of the range; nothing behind can be in it.
                if ((is_bid && order_price < price_low) || (!is_bid && order_price > price_high)) {
                    break
                };

                // Not yet inside the range.
                if ((is_bid && order_price > price_high) || (!is_bid && order_price < price_low)) {
                    cur = self.cursor_next(is_bid, cur);
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
            cur = self.cursor_next(is_bid, cur);
        };

        if (cur_price != 0 && ticks_left > 0) {
            price_vec.push_back(cur_price);
            quantity_vec.push_back(cur_quantity);
        };

        (price_vec, quantity_vec)
    }

    /// === Private Functions ===
    /// Book order: a bid is better the higher its key, an ask the lower. Both hot
    /// buffers are sorted by this, worst first.
    fun better(is_bid: bool, a: u128, b: u128): bool {
        if (is_bid) a > b else a < b
    }

    /// Position of `order_id` in a hot buffer, if it is there.
    ///
    /// Scanned best-first because the callers that matter — retiring the makers a
    /// taker just consumed — are always working at the best-priced end.
    fun hot_find(hot: &vector<Order>, order_id: u128): Option<u64> {
        let mut i = hot.length();
        while (i > 0) {
            if (hot.borrow(i - 1).order_id() == order_id) {
                return option::some(i - 1)
            };
            i = i - 1;
        };

        option::none()
    }

    /// Index in a worst-first hot buffer at which `key` keeps it sorted. A new best
    /// price — the common case — walks nothing and lands at the end.
    fun hot_insert_pos(hot: &vector<Order>, is_bid: bool, key: u128): u64 {
        let mut i = hot.length();
        while (i > 0 && better(is_bid, hot.borrow(i - 1).order_id(), key)) {
            i = i - 1;
        };

        i
    }

    /// Remove an order from whichever store holds it. Does not refill the buffer:
    /// spill is one-way, and the buffer repopulates from new placements.
    ///
    /// An id on neither store still aborts with `big_vector`'s `ENotFound`, as it did
    /// when the tree was the only store.
    fun remove_order(self: &mut Book, order_id: u128): Order {
        let (is_bid, _, _) = utils::decode_order_id(order_id);
        let at = hot_find(if (is_bid) &self.hot_bids else &self.hot_asks, order_id);
        if (at.is_some()) {
            let ix = at.destroy_some();
            // At the best-priced end `ix` is the last element, so this moves nothing.
            return if (is_bid) self.hot_bids.remove(ix) else self.hot_asks.remove(ix)
        };

        if (is_bid) self.bids.remove(order_id) else self.asks.remove(order_id)
    }

    fun borrow_order_mut(self: &mut Book, order_id: u128): &mut Order {
        let (is_bid, _, _) = utils::decode_order_id(order_id);
        let at = hot_find(if (is_bid) &self.hot_bids else &self.hot_asks, order_id);
        if (at.is_some()) {
            let ix = at.destroy_some();
            return if (is_bid) {
                self.hot_bids.borrow_mut(ix)
            } else {
                self.hot_asks.borrow_mut(ix)
            }
        };

        if (is_bid) self.bids.borrow_mut(order_id) else self.asks.borrow_mut(order_id)
    }

    /// Push the worst orders out of an overflowing hot buffer and into the tree,
    /// down to `HOT_SPILL_TARGET`. Spilling past capacity rather than back to it is
    /// what stops a run of top-of-book placements paying a tree insert every time.
    ///
    /// Gated on *genuine* overflow. Without the gate the buffer is pinned at
    /// `HOT_SPILL_TARGET` — every placement above that depth pays a tree insert and
    /// the headroom up to `HOT_CAPACITY` is never used, which is the cache paying
    /// both structures' costs and keeping neither's benefit.
    fun spill(self: &mut Book, is_bid: bool) {
        let mut len = if (is_bid) self.hot_bids.length() else self.hot_asks.length();
        if (len <= HOT_CAPACITY) return;
        while (len > HOT_SPILL_TARGET) {
            let order = if (is_bid) self.hot_bids.remove(0) else self.hot_asks.remove(0);
            let key = order.order_id();
            if (is_bid) self.bids.insert(key, order) else self.asks.insert(key, order);
            len = len - 1;
        };
    }

    /// Access side of book where order_id belongs. The side is carried in the
    /// id's top bit, so no lookup is needed to route by it.
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
        // The side matched *against* is the opposite of the taker's.
        let maker_is_bid = !is_bid;
        let mut cur = self.cursor_begin(maker_is_bid);
        let max_fills = constants::max_fills();
        let mut current_fills = 0;

        while (!cur.cursor_is_null() &&
            current_fills < max_fills) {
            let maker_order = self.cursor_borrow_mut(maker_is_bid, &cur);
            // Only a `Stopped` outcome ends the walk. A maker that cannot settle for
            // a non-zero quote is skipped or retired, and the orders behind it stay
            // reachable — treating that as terminal wedged the whole side.
            if (!order_info.match_maker(maker_order, timestamp).continues()) break;
            cur = self.cursor_next(maker_is_bid, cur);
            current_fills = current_fills + 1;
        };

        // Resting orders this match consumed or expired leave the book. Removal is
        // by key, so unlike the old flat vector book there is no index bookkeeping to keep
        // valid across removals.
        order_info.fills_ref().do_ref!(|fill| {
            if (fill.expired() || fill.completed()) {
                self.remove_order(fill.maker_order_id());
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
        let key = order_info.order_id();
        let is_bid = order_info.is_bid();

        let hot_len = if (is_bid) self.hot_bids.length() else self.hot_asks.length();
        if (hot_len == 0) {
            let cold_empty = if (is_bid) self.bids.is_empty() else self.asks.is_empty();
            if (cold_empty) {
                // First order on this side.
                if (is_bid) self.hot_bids.push_back(order) else self.hot_asks.push_back(order);
                return
            };

            // Buffer drained but the tree is not. Spill is one-way, so the only way
            // to hold the hot-over-tree invariant is to admit inline exactly those
            // orders that beat the whole tree, and send the rest behind it. Reading
            // the tree's best key is the one structural cost of removing the return
            // path, and it prices as computation.
            let best_cold = if (is_bid) {
                let (r, o) = self.bids.max_slice();
                slice_borrow(self.bids.borrow_slice(r), o).order_id()
            } else {
                let (r, o) = self.asks.min_slice();
                slice_borrow(self.asks.borrow_slice(r), o).order_id()
            };
            if (better(is_bid, key, best_cold)) {
                if (is_bid) self.hot_bids.push_back(order) else self.hot_asks.push_back(order);
            } else {
                if (is_bid) self.bids.insert(key, order) else self.asks.insert(key, order);
            };
            return
        };

        // The buffer holds the best orders of the side, so anything not better than
        // its worst belongs behind it, in the tree.
        let worst_hot = if (is_bid) {
            self.hot_bids.borrow(0).order_id()
        } else {
            self.hot_asks.borrow(0).order_id()
        };
        if (!better(is_bid, key, worst_hot)) {
            if (is_bid) self.bids.insert(key, order) else self.asks.insert(key, order);
            return
        };

        let at = hot_insert_pos(if (is_bid) &self.hot_bids else &self.hot_asks, is_bid, key);
        if (is_bid) self.hot_bids.insert(order, at) else self.hot_asks.insert(order, at);
        self.spill(is_bid);
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
            hot_bids: vector[],
            hot_asks: vector[],
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
            hot_bids: _,
            hot_asks: _,
            next_bid_order_id: _,
            next_ask_order_id: _,
            price_scaling: _,
        } = self;
        bids.drop();
        asks.drop();
    }

    #[test_only]
    /// Tree geometry, for asserting which regime a benchmark actually exercised.
    /// Tree depth per side, and the side's *total* length across the hot buffer and
    /// the tree — a caller asking how deep the book is means the book, not the cold
    /// half of it.
    public fun shape(self: &Book): (u8, u64, u8, u64) {
        (self.bids.depth(), self.side_length(true), self.asks.depth(), self.side_length(false))
    }
}
