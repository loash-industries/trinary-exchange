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

    /// Mirrors `coin_book::HOT_CAPACITY`, which is private. A test that silently
    /// tracked a changed capacity would stop testing the boundary it names.
    const HOT_CAPACITY: u64 = 16;

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

        // A drained buffer in front of a stocked tree would mean a refill was
        // missed, and would let the next placement land on the wrong side of the
        // seam.
        let tree = read_tree(book, is_bid);
        if (hot.length() == 0) {
            assert!(tree.length() == 0);
            return
        };

        // The worst hot order still beats the best tree order.
        if (tree.length() > 0) {
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
    /// A taker that eats more than the buffer holds has to cross into the tree
    /// mid-sweep and then refill behind itself.
    fun sweep_past_the_buffer_refills_from_the_tree() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 0;
        while (i < 40) {
            rest(&mut book, price_at(39 - i), false);
            i = i + 1;
        };
        assert_ordered(&book, false, 40);

        // Twenty orders is more than the buffer holds, so the walk leaves it.
        let taker = sweep(&mut book, price_at(39), 20, true);
        assert!(taker.executed_quantity() == qty() * 20);

        assert_invariant(&book, false);
        assert_ordered(&book, false, 20);
        // The refill put the new best orders back in the buffer rather than
        // leaving the side to be served from the tree.
        assert!(book.hot_asks().length() > 0);

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
    /// A side refilled to empty and then rebuilt: the placement path has to handle
    /// a buffer that is empty while the tree is not, which is the one state where
    /// it cannot tell from the buffer alone where a new order belongs.
    fun rebuilds_after_being_emptied() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 0;
        while (i < 20) {
            rest(&mut book, price_at(i), true);
            i = i + 1;
        };
        let taker = sweep(&mut book, price_at(0), 20, false);
        assert!(taker.executed_quantity() == qty() * 20);
        assert!(book.side_is_empty(true));

        let mut j = 0;
        while (j < 25) {
            rest(&mut book, price_at(j), true);
            assert_invariant(&book, true);
            j = j + 1;
        };
        assert_ordered(&book, true, 25);

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
