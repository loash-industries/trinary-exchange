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
        big_vector::{Self, BigVector, SliceRef, slice_borrow, slice_borrow_mut},
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
    /// The two watermarks exist to stop the buffer thrashing against its own edges.
    /// Held exactly *at* capacity, it would overflow on every top-of-book placement
    /// and underflow on every cancel, paying a tree write each time — precisely the
    /// cost it exists to avoid. Instead it floats between `HOT_REFILL_FLOOR` and
    /// `HOT_CAPACITY` and only rebalances when it leaves that band, so a run of churn
    /// at the inside market touches the tree once and then not at all.
    const HOT_CAPACITY: u64 = 16;

    /// On overflow, spill down to here rather than back to `HOT_CAPACITY`, leaving
    /// headroom for the placements that follow.
    const HOT_SPILL_TARGET: u64 = 12;

    /// On draining to here, refill to `HOT_CAPACITY` in one batch, so a taker sweep
    /// pays one tree descent per batch rather than one per order consumed.
    const HOT_REFILL_FLOOR: u64 = 8;

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
        // Divisor used in qty ↔ quote conversions. Always FLOAT_SCALING (1e9) for
        // coin pools — price = human × QUOTE_UNIT × FLOAT_SCALING / BASE_UNIT.
        // Kept as a field, rather than read from `constants` at each use, so the
        // conversion helpers stay call-compatible with the multicoin book, which
        // varies it.
        price_scaling: u64,
    }

    /// A position in one side of the book.
    ///
    /// A side spans two stores — the inline hot buffer and the `BigVector` behind it
    /// — and this addresses both as one sequence running best price first, so callers
    /// iterate a side without knowing where any given order lives. It replaces the
    /// bare `(SliceRef, u64)` pair the book used when every order was in the tree.
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
        let mut quantity_in_left = if (is_bid) quote_quantity else base_quantity;

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
                        // Same helper, same per-level basis as
                        // `calculate_partial_fill_balances`, so the quote reserves
                        // exactly the fee that settles.
                        let fee = quote_fee::fee_from_scaled_rate(
                            trade_specific_taker_fee,
                            matched_quote_quantity,
                        );
                        quantity_in_left = quantity_in_left - matched_quote_quantity - fee;
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
                        let fee = quote_fee::fee_from_scaled_rate(
                            trade_specific_taker_fee,
                            matched_quote_quantity,
                        );
                        quantity_out = quantity_out + matched_quote_quantity - fee;
                        quantity_in_left = quantity_in_left - matched_base_quantity;
                    };
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

    /// Cancels an order given order_id
    /// #ref:order_cancel
    public(package) fun cancel_order(self: &mut Book, order_id: u128): Order {
        let (is_bid, _, _) = utils::decode_order_id(order_id);
        let order = self.remove_order(order_id);
        self.top_up(is_bid);

        order
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
    /// callers that remove in a loop want one refill at the end, not one per order.
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

    /// Refill a drained hot buffer from the tree, in one batch up to `HOT_CAPACITY`.
    /// A no-op until the buffer falls below `HOT_REFILL_FLOOR`, so the ordinary
    /// place-and-cancel cycle at the inside market never reaches the tree at all.
    fun top_up(self: &mut Book, is_bid: bool) {
        let mut len = if (is_bid) self.hot_bids.length() else self.hot_asks.length();
        if (len >= HOT_REFILL_FLOOR) return;

        // The buffer is worst-first and everything pulled below is worse than all of
        // it, so the orders belong at the front. Reversing to best-first lets them be
        // appended instead, at two O(HOT_CAPACITY) reverses rather than a memmove per
        // order.
        if (is_bid) self.hot_bids.reverse() else self.hot_asks.reverse();
        while (len < HOT_CAPACITY) {
            let cold_empty = if (is_bid) self.bids.is_empty() else self.asks.is_empty();
            if (cold_empty) break;

            // The tree's own best order. Its key is its id, so reading it needs no
            // separate key lookup.
            let key = if (is_bid) {
                let (r, o) = self.bids.max_slice();
                slice_borrow(self.bids.borrow_slice(r), o).order_id()
            } else {
                let (r, o) = self.asks.min_slice();
                slice_borrow(self.asks.borrow_slice(r), o).order_id()
            };
            let order = if (is_bid) self.bids.remove(key) else self.asks.remove(key);
            if (is_bid) self.hot_bids.push_back(order) else self.hot_asks.push_back(order);
            len = len + 1;
        };
        if (is_bid) self.hot_bids.reverse() else self.hot_asks.reverse();
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
        // by key, so unlike the vector book there is no index bookkeeping to keep
        // valid across removals.
        order_info.fills_ref().do_ref!(|fill| {
            if (fill.expired() || fill.completed()) {
                self.remove_order(fill.maker_order_id());
            };
        });
        // One batched refill for the whole sweep. Doing it inside the loop above
        // would pay a tree descent per order consumed, which is what the buffer is
        // here to avoid.
        self.top_up(maker_is_bid);

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
            } else {
                // Buffer drained but the tree is not: the new order cannot be placed
                // in the buffer without knowing whether it beats what is still in the
                // tree, so it goes to the tree and the refill sorts out which orders
                // belong in front.
                if (is_bid) self.bids.insert(key, order) else self.asks.insert(key, order);
                self.top_up(is_bid);
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
