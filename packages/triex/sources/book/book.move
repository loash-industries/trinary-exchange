// Copyright (c) Mysten Labs, Inc.
/// SPDX-License-Identifier: Apache-2.0

/// The book module contains the `Book` struct which represents the order book.
/// All order book operations are defined in this module.
///
/// This is the **multicoin** order book. Orders live in a `BigVector<Order>`
/// keyed by an encoded `u128` order id, with the best `HOT_CAPACITY` orders of
/// each side held inline in the pool object. Insert, cancel, modify and lookup
/// are O(log n) by key, and no operation rewrites the whole book, so depth is not
/// bounded by Sui's maximum object size.
///
/// The layout is the "C16u" design of
/// `docs/plans/multicoin-book-storage-whitepaper.md` §7.4, chosen because it
/// burns the least storage fee of the seven measured variants under all three
/// weightings. The flat `vector<Order>` it replaces cost 6,710 MIST per resting
/// order on *every* operation and stopped accepting orders entirely at 2,973 per
/// side.
///
/// Iteration order is identical to the flat vector book's, so matching, level2
/// and pagination observe orders in exactly the same sequence:
///   - bids: keys ascend by price, best bid is the max key — walk `max_slice`
///     then `prev_slice`.
///   - asks: keys ascend by price, best ask is the min key — walk `min_slice`
///     then `next_slice`.
/// Within one price level the per-side sequence counters (bids descending, asks
/// ascending — see `constants::start_bid_order_id`) put the oldest order first on
/// both sides, which is what makes key order equal price-time priority.
///
/// This file and `triex::coin_book` now share a storage design but remain forked:
/// they differ in matching semantics (`match_maker` returns `bool` here, a
/// three-state `MatchOutcome` there), in price scaling, and in which views they
/// expose. Re-merging them is possible but is its own piece of work.
///
/// The fee arithmetic in `get_quantity_out` is shared verbatim with
/// `triex::coin_book`; only the traversal differs. Any change to it must land in
/// both files.
module triex::book {
    use triex::{
        big_vector::{Self, BigVector, SliceRef, slice_borrow, slice_borrow_mut},
        constants,
        math,
        order::Order,
        order_info::OrderInfo,
        quote_fee,
        utils
    };

    /// === Errors ===
    const EInvalidAmountIn: u64 = 1;
    const EEmptyOrderbook: u64 = 2;
    const EInvalidPriceRange: u64 = 3;
    const EInvalidTicks: u64 = 4;
    const ENewQuantityMustBeLessThanOriginal: u64 = 7;
    // Note: there is no book-level "order not found" code any more. A cancel,
    // modify or lookup of an absent id aborts inside `big_vector` with its own
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
    /// competitive price beats the tree's best key and is admitted inline. Removing
    /// the return path was the single largest improvement measured — 42–47% off a
    /// 10-order sweep (whitepaper F6) — because a refill makes every sweep that
    /// drains the buffer pay tree removals to repopulate it, and the repopulated
    /// buffer then re-spills on the placements that follow.
    ///
    /// The capacity is deliberately small. Each inline order is rewritten on every
    /// transaction that touches the pool, at ~7.1k MIST, while the benefit of
    /// keeping churn off the tree saturates at about a dozen orders: a 64-order
    /// buffer costs 74% more per churn operation than this one and is worse than the
    /// flat vector it replaced in the 45–64 band (whitepaper F5). A hot cache is an
    /// asset only while it is small.
    const HOT_CAPACITY: u64 = 16;

    /// On genuine overflow, spill down to here rather than back to `HOT_CAPACITY`,
    /// leaving headroom for the placements that follow. Held exactly *at* capacity
    /// the buffer would spill on every top-of-book placement, paying a tree write
    /// each time — precisely the cost it exists to avoid.
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
        // Divisor used in qty ↔ quote conversions. 1 for multicoin pools —
        // price = human × QUOTE_UNIT, with no float division. (The coin book
        // uses FLOAT_SCALING; see `triex::coin_book`.) Kept as a field, rather
        // than read from `constants` at each use, so the conversion helpers stay
        // call-compatible with the coin book, which varies it.
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

    /// The `FLOAT_SCALING` constructor this module used to expose for coin pools is
    /// gone — they build their book through `coin_book::empty` now. Only the
    /// multicoin constructor below remains.
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

    public(package) fun price_scaling(self: &Book): u64 {
        self.price_scaling
    }

    /// Creates a new order.
    /// Order is matched against the book and injected into the book if necessary.
    /// If order is IOC or fully executed, it will not be injected.
    public(package) fun create_order(self: &mut Book, order_info: &mut OrderInfo, timestamp: u64) {
        order_info.validate_inputs(timestamp);
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
        let mut quantity_in_left = if (is_bid) quote_quantity else base_quantity;

        // The side quoted *against* is the opposite of the taker's.
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

            cur = self.cursor_next(maker_is_bid, cur);
            current_fills = current_fills + 1;
        };

        if (is_bid) {
            (quantity_out, quantity_in_left)
        } else {
            (quantity_in_left, quantity_out)
        }
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
    /// New quantity must be less than the original quantity.
    /// Order must not have already expired.
    /// #ref:order_modify
    public(package) fun modify_order(
        self: &mut Book,
        order_id: u128,
        new_quantity: u64,
        timestamp: u64,
    ): (u64, &Order) {
        let order = self.borrow_order_mut(order_id);
        assert!(new_quantity < order.quantity(), new_quantity_must_be_less_than_original());
        let cancel_quantity = order.quantity() - new_quantity;
        order.modify(new_quantity, timestamp);

        (cancel_quantity, order)
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

    // === Cursor ===
    public(package) fun cursor_is_null(self: &Cursor): bool {
        !self.in_hot && self.tree.is_none()
    }

    /// The best-priced order of a side: the back of the hot buffer, or the tree's
    /// own best when the buffer is empty.
    public(package) fun cursor_begin(self: &Book, is_bid: bool): Cursor {
        let hot = if (is_bid) &self.hot_bids else &self.hot_asks;
        let n = hot.length();
        if (n > 0) {
            return Cursor { hot_ix: n - 1, in_hot: true, tree: option::none(), offset: 0 }
        };
        self.cursor_tree_begin(is_bid)
    }

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
            // Off the front of the buffer; continue into the tree behind it.
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

    /// === Private Functions ===
    /// Book order: a bid is better the higher its key, an ask the lower.
    fun better(is_bid: bool, a: u128, b: u128): bool {
        if (is_bid) a > b else a < b
    }

    /// Position of `order_id` in a hot buffer, if it is there at all. Linear, but
    /// over at most `HOT_CAPACITY` elements already inline in the object.
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

    /// Index in a worst-first hot buffer at which `key` keeps it sorted.
    fun hot_insert_pos(hot: &vector<Order>, is_bid: bool, key: u128): u64 {
        let mut i = hot.length();
        while (i > 0 && better(is_bid, hot.borrow(i - 1).order_id(), key)) {
            i = i - 1;
        };

        i
    }

    /// Remove an order from whichever store holds it.
    fun remove_order(self: &mut Book, order_id: u128): Order {
        let (is_bid, _, _) = utils::decode_order_id(order_id);
        let at = hot_find(if (is_bid) &self.hot_bids else &self.hot_asks, order_id);
        if (at.is_some()) {
            let ix = at.destroy_some();
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

    /// Push the worst orders out of a genuinely overflowing hot buffer into the
    /// tree, down to `HOT_SPILL_TARGET`.
    ///
    /// Gated on real overflow. Without the gate the buffer is pinned at
    /// `HOT_SPILL_TARGET` and every placement above that depth pays a tree insert,
    /// which is the cache paying both structures' costs and keeping neither's
    /// benefit.
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

        while (!cur.cursor_is_null() && current_fills < max_fills) {
            let maker_order = self.cursor_borrow_mut(maker_is_bid, &cur);
            if (!order_info.match_maker(maker_order, timestamp)) break;
            cur = self.cursor_next(maker_is_bid, cur);
            current_fills = current_fills + 1;
        };

        // Resting orders this match consumed or expired leave the book. Removal is
        // keyed, so this costs one descent per retired order rather than the flat
        // vector's whole-side scan per fill. Nothing refills the buffer behind them.
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
            // path, and it prices as computation, which did not move when measured.
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
    /// `(bid tree depth, bids on the side, ask tree depth, asks on the side)` — for
    /// tests asserting where orders landed across the buffer/tree seam.
    public fun shape(self: &Book): (u8, u64, u8, u64) {
        (self.bids.depth(), self.side_length(true), self.asks.depth(), self.side_length(false))
    }
}
