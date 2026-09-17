/// Tests for the coin book's inline top-of-book buffer.
///
/// Each side stores its best `HOT_CAPACITY` (16) orders in a plain vector inside
/// the `Book` and the rest in the `BigVector` behind it, on the invariant that
/// *every* hot order is better-priced than *every* tree order. Nothing outside the
/// book can see the split — a side reads back as one price-ordered sequence — so
/// these tests work both sides of it: they assert the visible ordering, and they
/// reach for the two stores separately to assert the invariant that produces it.
///
/// The cases that matter are the ones that move orders between the stores: a
/// placement that overflows the buffer and spills to the tree, a sweep or cancel
/// that drains it past the refill floor and pulls back from the tree, and any
/// operation landing exactly on the seam between the two.
#[test_only]
module triex::coin_book_hot_buffer_tests {
    use sui::test_scenario::begin;
    use triex::{
        big_vector::slice_borrow,
        coin_book::{Self, Book},
        coin_order_info::{Self, OrderInfo},
        constants
    };

    const OWNER: address = @0x1;

    /// Mirror `coin_book`'s private buffer constants. A test that silently tracked
    /// a changed capacity would stop testing the boundary it names.
    const HOT_CAPACITY: u64 = 32;
    const HOT_SPILL_TARGET: u64 = 24;

    fun scaling(): u64 { constants::float_scaling() }

    fun qty(): u64 { 1 * scaling() }

    /// Prices run `1e9, 2e9, ...`, well clear of the zero-quote bound.
    fun price_at(level: u64): u64 { (level + 1) * scaling() }

    fun order(order_type: u8, price: u64, quantity: u64, is_bid: bool, ts: u64): OrderInfo {
        coin_order_info::new(
            object::id_from_address(@0xB00C),
            object::id_from_address(@0xACC7),
            OWNER,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            0,
            0,
            0,
            constants::max_u64(),
            false,
            ts,
            scaling(),
        )
    }

    fun rest(book: &mut Book, price: u64, is_bid: bool): u128 {
        let mut info = order(constants::no_restriction(), price, qty(), is_bid, 0);
        book.create_order(&mut info, 0);
        assert!(info.order_inserted());

        info.order_id()
    }

    /// Cross the book with an IOC taker for `n` whole orders.
    fun sweep(book: &mut Book, price: u64, n: u64, is_bid: bool): OrderInfo {
        let mut info = order(constants::immediate_or_cancel(), price, qty() * n, is_bid, 0);
        book.create_order(&mut info, 0);

        info
    }

    /// The whole side in book order, via the cursor the book exposes for iteration.
    fun read_side(book: &Book, is_bid: bool): vector<u128> {
        let mut ids = vector[];
        let mut cur = book.cursor_begin(is_bid);
        while (!cur.cursor_is_null()) {
            ids.push_back(book.cursor_borrow(is_bid, &cur).order_id());
            cur = book.cursor_next(is_bid, cur);
        };

        ids
    }

    /// The cold tree alone, best price first.
    fun read_tree(book: &Book, is_bid: bool): vector<u128> {
        let cold = if (is_bid) book.bids() else book.asks();
        let mut ids = vector[];
        let (mut r, mut o) = if (is_bid) cold.max_slice() else cold.min_slice();
        while (!r.is_null()) {
            ids.push_back(slice_borrow(cold.borrow_slice(r), o).order_id());
            (r, o) = if (is_bid) cold.prev_slice(r, o) else cold.next_slice(r, o);
        };

        ids
    }

    fun better(is_bid: bool, a: u128, b: u128): bool {
        if (is_bid) a > b else a < b
    }

    /// Everything the split must guarantee, checked directly against both stores.
    fun assert_invariant(book: &Book, is_bid: bool) {
        let hot = if (is_bid) book.hot_bids() else book.hot_asks();
        assert!(hot.length() <= HOT_CAPACITY);

        // The buffer is stored worst-first, so keys must improve along it.
        let mut i = 1;
        while (i < hot.length()) {
            assert!(better(is_bid, hot[i].order_id(), hot[i - 1].order_id()));
            i = i + 1;
        };

        // Note what is *not* asserted, and would be under a refilling design: that a
        // stocked tree implies a stocked buffer. Spill is one-way, so the buffer
        // legitimately sits empty in front of a full tree after a sweep, until a
        // competitive quote arrives to repopulate it.
        //
        // The worst hot order still beats the best tree order. This is the whole
        // invariant: it is what lets a side be read as buffer-then-tree.
        let tree = read_tree(book, is_bid);
        if (hot.length() > 0 && tree.length() > 0) {
            assert!(better(is_bid, hot[0].order_id(), tree[0]));
        };

        assert!(book.side_length(is_bid) == hot.length() + tree.length());
    }

    /// The side reads back strictly best-first, with no duplicates or omissions.
    fun assert_ordered(book: &Book, is_bid: bool, expect_len: u64) {
        let ids = read_side(book, is_bid);
        assert!(ids.length() == expect_len);
        let mut i = 1;
        while (i < ids.length()) {
            assert!(better(is_bid, ids[i - 1], ids[i]));
            i = i + 1;
        };
    }

    // === Placement across the seam ===

    #[test]
    /// Every placement is the new best price, so each one enters the buffer and
    /// pushes its worst order out to the tree. This is the spill path, run 40 times.
    fun improving_prices_spill_in_order() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 0;
        while (i < 40) {
            rest(&mut book, price_at(i), true);
            assert_invariant(&book, true);
            i = i + 1;
        };

        assert_ordered(&book, true, 40);
        // The buffer really is holding the top of the book, not trailing it.
        assert!(book.hot_bids().length() > 0);
        assert!(book.bids().length() > 0);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The mirror case: every placement is worse than the last, so after the first
    /// the buffer is never the destination and orders go straight to the tree.
    fun worsening_prices_land_behind_the_buffer() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 40;
        while (i > 0) {
            rest(&mut book, price_at(i), true);
            assert_invariant(&book, true);
            i = i - 1;
        };

        assert_ordered(&book, true, 40);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Prices that jump either side of the seam, so placements alternate between
    /// the buffer and the tree and the sorted insert inside the buffer is exercised
    /// at positions other than the end.
    fun interleaved_prices_stay_ordered() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        // A stride coprime with the range visits every level in a scattered order.
        let mut i = 0;
        while (i < 50) {
            rest(&mut book, price_at((i * 23) % 50), true);
            assert_invariant(&book, true);
            i = i + 1;
        };

        assert_ordered(&book, true, 50);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Asks are stored in the buffer opposite to their tree order, so they get the
    /// same treatment rather than being assumed symmetric.
    fun ask_side_spills_and_orders() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 40;
        while (i > 0) {
            rest(&mut book, price_at(i), false);
            assert_invariant(&book, false);
            i = i - 1;
        };

        assert_ordered(&book, false, 40);
        assert!(book.hot_asks().length() > 0);
        assert!(book.asks().length() > 0);

        book.drop_for_testing();
        test.end();
    }

    // === Draining across the seam ===

    #[test]
    /// A taker that eats more than the buffer holds crosses into the tree mid-sweep
    /// and leaves nothing behind it. Under one-way spill that is the intended
    /// outcome, not a missed refill: the side goes on being served straight from the
    /// tree until a competitive quote rebuilds the buffer.
    fun sweep_past_the_buffer_leaves_it_empty() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        // Deep enough that the buffer spills and a tree exists behind it.
        let mut i = 0;
        while (i < 60) {
            rest(&mut book, price_at(59 - i), false);
            i = i + 1;
        };
        assert_ordered(&book, false, 60);
        let hot_before = book.hot_asks().length();
        assert!(hot_before > 0);
        assert!(book.asks().length() > 0);

        // More orders than the buffer holds, so the walk has to leave it.
        let taker = sweep(&mut book, price_at(59), hot_before + 4, true);
        assert!(taker.executed_quantity() == qty() * (hot_before + 4));

        assert_invariant(&book, false);
        assert_ordered(&book, false, 60 - hot_before - 4);
        // Emptied, and deliberately not repopulated.
        assert!(book.hot_asks().length() == 0);
        assert!(!book.asks().is_empty());

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The buffer repopulates from ordinary quoting with no tree traffic at all —
    /// the property that pays for removing the return path.
    fun competitive_quotes_rebuild_the_buffer_without_touching_the_tree() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 0;
        while (i < 60) {
            rest(&mut book, price_at(59 - i), false);
            i = i + 1;
        };
        let hot_before = book.hot_asks().length();
        sweep(&mut book, price_at(59), hot_before, true);
        assert!(book.hot_asks().length() == 0);

        let tree_after_sweep = book.asks().length();
        let best_tree = read_tree(&book, false)[0];
        let best_tree_px = book.get_order(best_tree).price();

        // Quote successively better than the tree's best; all of it lands inline.
        let mut j = 1;
        while (j <= HOT_CAPACITY) {
            rest(&mut book, best_tree_px - j * scaling() / 4, false);
            assert!(book.hot_asks().length() == j);
            assert!(book.asks().length() == tree_after_sweep);
            assert_invariant(&book, false);
            j = j + 1;
        };

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Spill is gated on genuine overflow, so a buffer at capacity is what a run of
    /// improving quotes settles at — not the spill target. Without the gate the
    /// buffer is pinned at `HOT_SPILL_TARGET` and every placement past that depth
    /// pays a tree insert.
    fun spill_is_gated_on_real_overflow() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 0;
        while (i < HOT_CAPACITY) {
            rest(&mut book, price_at(i), true);
            i = i + 1;
        };
        assert!(book.hot_bids().length() == HOT_CAPACITY);
        assert!(book.bids().is_empty());

        rest(&mut book, price_at(HOT_CAPACITY), true);
        assert!(book.hot_bids().length() == HOT_SPILL_TARGET);
        assert!(book.bids().length() == HOT_CAPACITY + 1 - HOT_SPILL_TARGET);

        assert_invariant(&book, true);
        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Draining a side to empty through repeated sweeps, checking the invariant at
    /// every step — the refill has to cope with a tree that runs out mid-batch.
    fun repeated_sweeps_drain_the_side_cleanly() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 0;
        while (i < 40) {
            rest(&mut book, price_at(39 - i), false);
            i = i + 1;
        };

        let mut remaining = 40;
        while (remaining > 0) {
            let n = if (remaining < 7) remaining else 7;
            let taker = sweep(&mut book, price_at(39), n, true);
            assert!(taker.executed_quantity() == qty() * n);
            remaining = remaining - n;
            assert_invariant(&book, false);
            assert_ordered(&book, false, remaining);
        };

        assert!(book.side_is_empty(false));
        assert!(book.hot_asks().length() == 0);
        assert!(book.asks().is_empty());

        book.drop_for_testing();
        test.end();
    }

    // === Cancelling on the seam ===

    #[test]
    /// Cancel the worst order still in the buffer and the best order in the tree —
    /// the two that sit either side of the seam — and then everything else.
    fun cancels_on_both_sides_of_the_seam() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut ids = vector[];
        let mut i = 0;
        while (i < 40) {
            ids.push_back(rest(&mut book, price_at(i), true));
            i = i + 1;
        };

        let worst_hot = book.hot_bids()[0].order_id();
        let best_cold = read_tree(&book, true)[0];

        book.cancel_order(worst_hot);
        assert_invariant(&book, true);
        assert_ordered(&book, true, 39);

        book.cancel_order(best_cold);
        assert_invariant(&book, true);
        assert_ordered(&book, true, 38);

        // Drain the rest in placement order, which walks the seam repeatedly.
        let mut left = 38;
        ids.do_ref!(|id| {
            if (*id != worst_hot && *id != best_cold) {
                book.cancel_order(*id);
                left = left - 1;
                assert_invariant(&book, true);
                assert_ordered(&book, true, left);
            };
        });
        assert!(book.side_is_empty(true));

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// A side swept to empty and then rebuilt. Depths are derived from
    /// `HOT_CAPACITY` rather than written as literals: at a hardcoded 20 orders this
    /// test stopped spilling the moment the buffer grew past that, and went on
    /// passing while testing nothing about the seam it is named for.
    fun rebuilds_after_being_emptied() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let deep = HOT_CAPACITY * 2;
        let mut i = 0;
        while (i < deep) {
            rest(&mut book, price_at(i), true);
            i = i + 1;
        };
        // The build must actually have straddled the seam, or the rest proves
        // nothing.
        assert!(!book.bids().is_empty());

        let taker = sweep(&mut book, price_at(0), deep, false);
        assert!(taker.executed_quantity() == qty() * deep);
        assert!(book.side_is_empty(true));

        let rebuild = HOT_CAPACITY + 8;
        let mut j = 0;
        while (j < rebuild) {
            rest(&mut book, price_at(j), true);
            assert_invariant(&book, true);
            j = j + 1;
        };
        assert_ordered(&book, true, rebuild);
        // And the rebuild straddled it too.
        assert!(!book.bids().is_empty());

        book.drop_for_testing();
        test.end();
    }

    // === Anchored reads across the seam ===

    #[test]
    /// Pagination anchors are exclusive and positional. Resuming from each order in
    /// turn must yield exactly the orders behind it, including when the anchor is
    /// the last hot order and the continuation is the first tree order.
    fun anchored_reads_cross_the_seam() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 0;
        while (i < 40) {
            rest(&mut book, price_at(i), true);
            i = i + 1;
        };

        let all = read_side(&book, true);
        let mut at = 0;
        while (at < all.length()) {
            let mut cur = book.cursor_after(true, all[at]);
            let mut seen = 0;
            while (!cur.cursor_is_null()) {
                assert!(book.cursor_borrow(true, &cur).order_id() == all[at + 1 + seen]);
                seen = seen + 1;
                cur = book.cursor_next(true, cur);
            };
            assert!(seen == all.length() - at - 1);
            at = at + 1;
        };

        book.drop_for_testing();
        test.end();
    }
}
