/// Exhaustive verification of the coin book's admission decision, and of the claim
/// that **promotion cannot happen**.
///
/// ## What is being verified
///
/// Under one-way spill an order may travel buffer → tree and never back. The
/// buffer is therefore populated only by *admission* of newly placed orders, and
/// `inject_limit_order` is the whole of that logic. It has three branches:
///
/// ```text
///   hot_len == 0 && tree empty      -> ADMIT                        (branch A)
///   hot_len == 0 && tree non-empty  -> ADMIT iff better(key, best_cold)   (W)
///   hot_len >  0                    -> ADMIT iff better(key, worst_hot)   (branch C)
///                                      then spill if now over capacity
/// ```
///
/// Branch **W** is the promotion window: the only place in the module that reads
/// the tree in order to decide buffer membership, and the branch that does not
/// existed while this book still refilled. It opens whenever the buffer
/// drains while the tree is still stocked — by a sweep, by cancels, or by a mix —
/// and it stays open until something is admitted through it.
///
/// ## Why the window is sound
///
/// The tree is key-ordered, so `better(key, best_cold)` implies `key` beats *every*
/// tree order, and admitting it leaves a one-element buffer that is entirely better
/// than the tree. Rejecting in the other case is necessary, not merely safe:
/// admitting an order that does not beat `best_cold` would put a worse order inline
/// in front of a better one, and nothing downstream would repair it.
///
/// Branch C then inherits soundness from W by induction: `worst_hot` beats
/// `best_cold`, so anything beating `worst_hot` beats the whole tree.
///
/// Branch C is *conservative*: an order worse than `worst_hot` but better than
/// `best_cold` is sent to the tree even though the buffer has room and the
/// invariant would permit it inline. That costs a tree write and never breaks
/// anything. It is asserted below (`GAP`) so the behaviour is pinned rather than
/// assumed.
///
/// ## Promotion is structurally impossible
///
/// Every write into a hot buffer in `coin_book.move` is one of three `push_back` /
/// `insert` calls in `inject_limit_order`, and all three write the same local
/// `order`, bound once from `order_info.to_order()`. No value read out of a
/// `BigVector` ever reaches a hot-buffer write: `spill` moves buffer → tree,
/// `remove_order` returns to its caller, and `borrow_mut` mutates in place. That is
/// an exhaustive argument over write sites, and `assert_no_promotion` below is its
/// observable form — after every operation, no id that was in the tree is in the
/// buffer.
///
/// ## How "exhaustive" is meant here
///
/// No prover is available in this toolchain, so this is a bounded exhaustive check
/// rather than a proof. The decision depends on the side, the buffer occupancy, the
/// tree occupancy and where the incoming price falls relative to the two stores'
/// boundaries. Every combination of those is enumerated and checked, with the
/// occupancies taken at the values that bound behaviour: 0, 1, 2, `HOT_CAPACITY-1`
/// and `HOT_CAPACITY` for the buffer; 0, 1, 2 and 17 (past one leaf slice) for the
/// tree. Both sides get the full grid, because the window reads `max_slice` on bids
/// and `min_slice` on asks and compares under an inverted `better` — a swap between
/// the two would be invisible on one side.
///
/// This is the `triex::book` module ported to the coin stack, at `HOT_CAPACITY` 32.
#[test_only]
module triex::coin_book_admission_window_tests {
    use sui::test_scenario::{begin, Scenario};
    use triex::{
        big_vector::slice_borrow,
        coin_book::{Self, Book},
        coin_order_info::{Self, OrderInfo},
        constants
    };

    const OWNER: address = @0x1;
    const HOT_CAPACITY: u64 = 32;
    const HOT_SPILL_TARGET: u64 = 24;

    /// Prices are laid out on a grid so that a "strictly between two adjacent
    /// ranks" price always exists. Coin pools price through `FLOAT_SCALING`, so the
    /// grid is scaled to keep every level's quote far clear of the zero-quote bound.
    fun scaling(): u64 { constants::float_scaling() }

    fun base(): u64 { 1_000 * scaling() }

    fun stride(): u64 { scaling() }

    fun qty(): u64 { 1 * scaling() }

    // === Price helpers, written once and reused per side ===

    /// Rank 0 is the best price of a side; higher ranks are progressively worse.
    fun px(is_bid: bool, rank: u64): u64 {
        if (is_bid) base() - rank * stride() else base() + rank * stride()
    }

    fun improve(is_bid: bool, p: u64, d: u64): u64 {
        if (is_bid) p + d else p - d
    }

    fun worsen(is_bid: bool, p: u64, d: u64): u64 {
        if (is_bid) p - d else p + d
    }

    fun better_px(is_bid: bool, a: u64, b: u64): bool {
        if (is_bid) a > b else a < b
    }

    fun better_key(is_bid: bool, a: u128, b: u128): bool {
        if (is_bid) a > b else a < b
    }

    // === Book helpers ===

    fun order(order_type: u8, price: u64, quantity: u64, is_bid: bool): OrderInfo {
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
            0,
            scaling(),
        )
    }

    fun rest(book: &mut Book, price: u64, is_bid: bool): u128 {
        let mut info = order(constants::no_restriction(), price, qty(), is_bid);
        book.create_order(&mut info, 0);
        assert!(info.order_inserted());

        info.order_id()
    }

    fun side(book: &Book, is_bid: bool): vector<u128> {
        let mut ids = vector[];
        let mut cur = book.cursor_begin(is_bid);
        while (!cur.cursor_is_null()) {
            ids.push_back(book.cursor_borrow(is_bid, &cur).order_id());
            cur = book.cursor_next(is_bid, cur);
        };

        ids
    }

    fun hot_ids(book: &Book, is_bid: bool): vector<u128> {
        let hot = if (is_bid) book.hot_bids() else book.hot_asks();
        let mut ids = vector[];
        let mut i = 0;
        while (i < hot.length()) {
            ids.push_back(hot[i].order_id());
            i = i + 1;
        };

        ids
    }

    fun tree_ids(book: &Book, is_bid: bool): vector<u128> {
        let cold = if (is_bid) book.bids() else book.asks();
        let mut ids = vector[];
        let (mut r, mut o) = if (is_bid) cold.max_slice() else cold.min_slice();
        while (!r.is_null()) {
            ids.push_back(slice_borrow(cold.borrow_slice(r), o).order_id());
            (r, o) = if (is_bid) cold.prev_slice(r, o) else cold.next_slice(r, o);
        };

        ids
    }

    fun hot_len(book: &Book, is_bid: bool): u64 {
        if (is_bid) book.hot_bids().length() else book.hot_asks().length()
    }

    fun tree_len(book: &Book, is_bid: bool): u64 {
        if (is_bid) book.bids().length() else book.asks().length()
    }

    // === The properties ===

    /// The observable form of "promotion is impossible": nothing that was in the
    /// tree before an operation may be in the buffer after it.
    fun assert_no_promotion(before_tree: &vector<u128>, after_hot: &vector<u128>, case: u64) {
        let mut i = 0;
        while (i < after_hot.length()) {
            assert!(!before_tree.contains(&after_hot[i]), case);
            i = i + 1;
        };
    }

    /// The buffer/tree split is well formed and the side reads back as one strictly
    /// key-ordered sequence holding exactly the expected multiset of ids.
    fun assert_side_matches(book: &Book, is_bid: bool, expected: &vector<u128>, case: u64) {
        let hot = hot_ids(book, is_bid);
        let tree = tree_ids(book, is_bid);
        assert!(hot.length() <= HOT_CAPACITY, case);

        // Buffer is worst-first and internally ordered.
        let mut i = 1;
        while (i < hot.length()) {
            assert!(better_key(is_bid, hot[i], hot[i - 1]), case);
            i = i + 1;
        };
        // Tree is best-first and internally ordered.
        let mut j = 1;
        while (j < tree.length()) {
            assert!(better_key(is_bid, tree[j - 1], tree[j]), case);
            j = j + 1;
        };
        // The seam.
        if (hot.length() > 0 && tree.length() > 0) {
            assert!(better_key(is_bid, hot[0], tree[0]), case);
        };

        // The merged read is strictly ordered, and is exactly `expected` as a set
        // of the right size — which for a strictly ordered sequence pins it to the
        // unique sorted arrangement.
        let read = side(book, is_bid);
        assert!(read.length() == hot.length() + tree.length(), case);
        assert!(read.length() == expected.length(), case);
        let mut k = 1;
        while (k < read.length()) {
            assert!(better_key(is_bid, read[k - 1], read[k]), case);
            k = k + 1;
        };
        let mut m = 0;
        while (m < expected.length()) {
            assert!(read.contains(&expected[m]), case);
            m = m + 1;
        };
    }

    // === State construction ===

    /// A side holding exactly `h` orders inline and `t` in the tree, with a full
    /// price grid rank below each: buffer occupies ranks `h-1 .. 0` and the tree
    /// ranks `h .. h+t-1`, so adjacent ranks are always `stride()` apart.
    ///
    /// The buffer is built worst-price-first so every placement beats the current
    /// worst resident and is admitted; the tree is then built from prices worse
    /// than all of them, so each goes straight behind. Neither step spills, which
    /// is asserted, because a construction that spilled would not produce the
    /// occupancy it claims.
    fun build(test: &mut Scenario, is_bid: bool, h: u64, t: u64): (Book, vector<u128>) {
        let mut book = coin_book::empty(test.ctx());
        let mut keys = vector[];

        let mut i = h;
        while (i > 0) {
            i = i - 1;
            keys.push_back(rest(&mut book, px(is_bid, i), is_bid));
        };
        assert!(hot_len(&book, is_bid) == h);
        assert!(tree_len(&book, is_bid) == 0);

        let mut j = 0;
        while (j < t) {
            keys.push_back(rest(&mut book, px(is_bid, h + j), is_bid));
            j = j + 1;
        };
        assert!(hot_len(&book, is_bid) == h);
        assert!(tree_len(&book, is_bid) == t);

        (book, keys)
    }

    /// The window state itself: buffer empty, tree holding `t`. Built by putting one
    /// order inline over a tree of `t` and then removing it — by cancel or by a
    /// taker sweep, because those are the two ways the window opens in practice and
    /// they reach it through different code.
    fun build_window(
        test: &mut Scenario,
        is_bid: bool,
        t: u64,
        by_sweep: bool,
    ): (Book, vector<u128>) {
        let (mut book, mut keys) = build(test, is_bid, 1, t);
        let inline = keys.remove(0);

        if (by_sweep) {
            let taker_price = if (is_bid) constants::min_price() else constants::max_price();
            let mut taker = order(
                constants::immediate_or_cancel(),
                taker_price,
                qty(),
                !is_bid,
            );
            book.create_order(&mut taker, 0);
            assert!(taker.executed_quantity() == qty());
        } else {
            book.cancel_order(inline);
        };

        assert!(hot_len(&book, is_bid) == 0);
        assert!(tree_len(&book, is_bid) == t);

        (book, keys)
    }

    // === The decision table ===

    // Price classes for the incoming order, relative to the two stores.
    const ABOVE_ALL: u64 = 1; // beats every resting order
    const BUFFER_INTERIOR: u64 = 2; // between the buffer's worst and its next-best
    const TIE_HOT_WORST: u64 = 3; // same price as the buffer's worst, later arrival
    const GAP: u64 = 4; // worse than the buffer's worst, better than the tree's best
    const TIE_TREE_BEST: u64 = 5; // same price as the tree's best, later arrival
    const BELOW_ALL: u64 = 6; // worse than every resting order

    fun class_applies(class: u64, h: u64, t: u64): bool {
        if (class == BUFFER_INTERIOR) h >= 2
        else if (class == TIE_HOT_WORST) h >= 1
        else if (class == GAP) h >= 1 && t >= 1
        else if (class == TIE_TREE_BEST) t >= 1
        else true
    }

    /// The price a class names, read from the book's actual contents rather than
    /// recomputed from ranks, so the table cannot drift from the state it describes.
    fun class_price(book: &Book, is_bid: bool, class: u64): u64 {
        let all = side(book, is_bid);
        if (class == ABOVE_ALL) {
            if (all.is_empty()) return px(is_bid, 0);
            return improve(is_bid, book.get_order(all[0]).price(), stride())
        };
        if (class == BELOW_ALL) {
            if (all.is_empty()) return px(is_bid, 0);
            return worsen(is_bid, book.get_order(all[all.length() - 1]).price(), stride())
        };
        let hot = hot_ids(book, is_bid);
        let tree = tree_ids(book, is_bid);
        if (class == BUFFER_INTERIOR) {
            // Strictly between the buffer's worst and its next-best.
            return improve(is_bid, book.get_order(hot[0]).price(), stride() / 2)
        };
        if (class == TIE_HOT_WORST) {
            return book.get_order(hot[0]).price()
        };
        if (class == GAP) {
            // Strictly between the buffer's worst and the tree's best.
            return worsen(is_bid, book.get_order(hot[0]).price(), stride() / 2)
        };
        // TIE_TREE_BEST
        book.get_order(tree[0]).price()
    }

    /// The specification, written from the invariant rather than from the code: an
    /// order belongs inline exactly when it beats everything already inline, or —
    /// with an empty buffer — when it beats the whole tree. Equal price means later
    /// arrival, which is strictly worse, so every comparison here is strict.
    fun spec_admits(book: &Book, is_bid: bool, h: u64, t: u64, price: u64): bool {
        if (h == 0 && t == 0) return true;
        if (h == 0) {
            let tree = tree_ids(book, is_bid);
            return better_px(is_bid, price, book.get_order(tree[0]).price())
        };
        let hot = hot_ids(book, is_bid);

        better_px(is_bid, price, book.get_order(hot[0]).price())
    }

    /// One cell of the table: build the state, place one order of the given class,
    /// and check the outcome against the specification and against every invariant.
    fun check_cell(
        test: &mut Scenario,
        is_bid: bool,
        h: u64,
        t: u64,
        class: u64,
        window_by_sweep: bool,
    ) {
        if (!class_applies(class, h, t)) return;

        let case =
            (if (is_bid) 1_000_000 else 2_000_000) +
            h * 10_000 + t * 100 + class * 10 + (if (window_by_sweep) 1 else 0);

        let (mut book, mut keys) = if (h == 0 && t > 0) {
            build_window(test, is_bid, t, window_by_sweep)
        } else {
            build(test, is_bid, h, t)
        };

        let tree_before = tree_ids(&book, is_bid);
        let price = class_price(&book, is_bid, class);
        let expect_hot = spec_admits(&book, is_bid, h, t, price);

        let placed = rest(&mut book, price, is_bid);
        keys.push_back(placed);

        // 1. The side is still a well-formed, strictly ordered split holding
        //    exactly the orders placed into it.
        assert_side_matches(&book, is_bid, &keys, case);

        // 2. Nothing was promoted out of the tree.
        assert_no_promotion(&tree_before, &hot_ids(&book, is_bid), case);

        // 3. The order landed where the specification says, and the occupancies
        //    moved by exactly the right amounts.
        let hot_after = hot_len(&book, is_bid);
        let tree_after = tree_len(&book, is_bid);
        assert!(hot_after + tree_after == h + t + 1, case);

        if (expect_hot) {
            if (h + 1 > HOT_CAPACITY) {
                // Admission overflowed the buffer, so the spill fired. The spilled
                // orders are the buffer's worst, which may include the newcomer
                // itself — `assert_side_matches` has already confirmed the result is
                // correctly ordered either way.
                assert!(hot_after == HOT_SPILL_TARGET, case);
                assert!(tree_after == h + t + 1 - HOT_SPILL_TARGET, case);
            } else {
                assert!(hot_after == h + 1, case);
                assert!(tree_after == t, case);
                assert!(hot_ids(&book, is_bid).contains(&placed), case);
            };
        } else {
            assert!(hot_after == h, case);
            assert!(tree_after == t + 1, case);
            assert!(tree_ids(&book, is_bid).contains(&placed), case);
        };

        book.drop_for_testing();
    }

    /// One row of the grid: a fixed buffer occupancy, every tree depth, every price
    /// class, both window entry paths. Split per occupancy rather than run as one
    /// test because at `HOT_CAPACITY` 32 each cell builds a much larger book than the
    /// multicoin grid does, and a single test over the whole grid exceeds the Move
    /// harness's per-test time budget.
    fun run_row(is_bid: bool, h: u64) {
        // 17 puts the tree past one 16-slot leaf slice, so `max_slice` / `min_slice`
        // have to descend rather than read the only leaf.
        let depths = vector[0u64, 1, 2, 17];

        let mut ti = 0;
        while (ti < depths.length()) {
            let t = depths[ti];
            let mut class = 1;
            while (class <= 6) {
                // The window state has two entry paths; every other state has one.
                if (h == 0 && t > 0) {
                    let mut test = begin(OWNER);
                    check_cell(&mut test, is_bid, h, t, class, true);
                    test.end();
                    let mut test2 = begin(OWNER);
                    check_cell(&mut test2, is_bid, h, t, class, false);
                    test2.end();
                } else {
                    let mut test = begin(OWNER);
                    check_cell(&mut test, is_bid, h, t, class, false);
                    test.end();
                };
                class = class + 1;
            };
            ti = ti + 1;
        };
    }

    #[test]
    fun admission_grid_asks_empty_buffer() { run_row(false, 0) }

    #[test]
    fun admission_grid_asks_one_inline() { run_row(false, 1) }

    #[test]
    fun admission_grid_asks_two_inline() { run_row(false, 2) }

    #[test]
    fun admission_grid_asks_one_below_capacity() { run_row(false, HOT_CAPACITY - 1) }

    #[test]
    fun admission_grid_asks_at_capacity() { run_row(false, HOT_CAPACITY) }

    // The bid side is not redundant: the window reads `max_slice` here where the ask
    // side reads `min_slice`, and every comparison runs under the opposite sense of
    // `better`, so a swap between the two would pass on one side and fail here.

    #[test]
    fun admission_grid_bids_empty_buffer() { run_row(true, 0) }

    #[test]
    fun admission_grid_bids_one_inline() { run_row(true, 1) }

    #[test]
    fun admission_grid_bids_two_inline() { run_row(true, 2) }

    #[test]
    fun admission_grid_bids_one_below_capacity() { run_row(true, HOT_CAPACITY - 1) }

    #[test]
    fun admission_grid_bids_at_capacity() { run_row(true, HOT_CAPACITY) }

    // === Targeted properties the grid implies but does not name ===

    #[test]
    /// The window cannot be entered by spilling. `spill` leaves `HOT_SPILL_TARGET`
    /// orders behind, so however many times it fires the buffer never empties —
    /// which is what keeps branch W reachable only from removals.
    fun spill_never_opens_the_window() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 0;
        while (i < 200) {
            rest(&mut book, px(false, 200 - i), false);
            assert!(hot_len(&book, false) > 0, i);
            assert!(hot_len(&book, false) >= HOT_SPILL_TARGET || tree_len(&book, false) == 0, i);
            i = i + 1;
            if (i % 64 == 0) { test.next_tx(OWNER); };
        };

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The window opening and closing repeatedly on both sides. Each cycle sweeps
    /// the buffer away, re-admits through W, then fills the buffer back through
    /// branch C — so W is entered from a tree that grew deeper on every pass.
    fun repeated_window_cycles() {
        let mut is_bid = false;
        while (true) {
            let mut test = begin(OWNER);
            let mut book = coin_book::empty(test.ctx());

            // A tree deep enough that later cycles descend it.
            let mut i = 60;
            while (i > 0) {
                rest(&mut book, px(is_bid, i), is_bid);
                i = i - 1;
            };

            let mut cycle = 0;
            while (cycle < 5) {
                let hot = hot_len(&book, is_bid);
                assert!(hot > 0);

                // Sweep the buffer away: the window opens.
                let taker_price = if (is_bid) constants::min_price() else constants::max_price();
                let mut taker = order(
                    constants::immediate_or_cancel(),
                    taker_price,
                    qty() * hot,
                    !is_bid,
                );
                book.create_order(&mut taker, 0);
                assert!(hot_len(&book, is_bid) == 0);
                assert!(tree_len(&book, is_bid) > 0);

                let tree_before = tree_ids(&book, is_bid);
                let best_tree_px = book.get_order(tree_before[0]).price();

                // Rejected through W, then accepted through W.
                rest(&mut book, worsen(is_bid, best_tree_px, stride() / 2), is_bid);
                assert!(hot_len(&book, is_bid) == 0);
                rest(&mut book, improve(is_bid, best_tree_px, stride() / 2), is_bid);
                assert!(hot_len(&book, is_bid) == 1);

                // Then refill through branch C without touching the tree.
                let tree_now = tree_len(&book, is_bid);
                let mut k = 1;
                while (k < 6) {
                    rest(
                        &mut book,
                        improve(is_bid, best_tree_px, stride() / 2 + k * stride()),
                        is_bid,
                    );
                    assert!(hot_len(&book, is_bid) == 1 + k);
                    assert!(tree_len(&book, is_bid) == tree_now);
                    k = k + 1;
                };

                assert_no_promotion(&tree_before, &hot_ids(&book, is_bid), cycle);
                cycle = cycle + 1;
                test.next_tx(OWNER);
            };

            book.drop_for_testing();
            test.end();

            if (is_bid) break;
            is_bid = true;
        };
    }

    #[test]
    /// The conservative gap, stated as its own case because it is the one place the
    /// implementation is deliberately weaker than the invariant requires: an order
    /// worse than the buffer's worst but better than the tree's best goes to the
    /// tree, even with the buffer far from full. It costs a tree write and breaks
    /// nothing, and the read order is unaffected.
    fun orders_in_the_gap_go_behind_a_half_empty_buffer() {
        let mut is_bid = false;
        while (true) {
            let mut test = begin(OWNER);
            let (mut book, mut keys) = build(&mut test, is_bid, 2, 4);

            let hot = hot_ids(&book, is_bid);
            let tree = tree_ids(&book, is_bid);
            let gap_price = worsen(is_bid, book.get_order(hot[0]).price(), stride() / 2);
            assert!(better_px(is_bid, gap_price, book.get_order(tree[0]).price()));

            let placed = rest(&mut book, gap_price, is_bid);
            keys.push_back(placed);

            // Buffer had room and the order beats the whole tree, yet it went behind.
            assert!(hot_len(&book, is_bid) == 2);
            assert!(tree_len(&book, is_bid) == 5);
            assert!(tree_ids(&book, is_bid)[0] == placed);
            // And it reads back in exactly the right place regardless.
            assert_side_matches(&book, is_bid, &keys, 0);
            assert!(side(&book, is_bid)[2] == placed);

            book.drop_for_testing();
            test.end();

            if (is_bid) break;
            is_bid = true;
        };
    }

    #[test]
    /// A newly placed order can itself be spilled by the very placement that
    /// admitted it: admitted just above the buffer's worst, then carried out with
    /// the rest of the tail when the buffer overflows. Legal — it is still the
    /// worst of what was inline — and worth pinning, because it is the one case
    /// where "admitted" and "ends up in the buffer" differ.
    fun a_placement_can_spill_itself() {
        let mut test = begin(OWNER);
        let (mut book, mut keys) = build(&mut test, false, HOT_CAPACITY, 0);

        let hot = hot_ids(&book, false);
        // Just better than the buffer's worst, so it is admitted at index 1 and
        // sits inside the tail the spill takes.
        let price = improve(false, book.get_order(hot[0]).price(), stride() / 2);
        let placed = rest(&mut book, price, false);
        keys.push_back(placed);

        assert!(hot_len(&book, false) == HOT_SPILL_TARGET);
        assert!(tree_ids(&book, false).contains(&placed));
        assert_side_matches(&book, false, &keys, 0);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The minimal window: a tree of exactly one order. `max_slice` / `min_slice`
    /// have to report that single element as the tree's best, on a tree that has
    /// never split a leaf.
    fun window_over_a_single_tree_order() {
        let mut is_bid = false;
        while (true) {
            let mut sweep = false;
            while (true) {
                let mut test = begin(OWNER);
                let (mut book, mut keys) = build_window(&mut test, is_bid, 1, sweep);
                assert!(tree_len(&book, is_bid) == 1);

                let only = tree_ids(&book, is_bid)[0];
                let only_px = book.get_order(only).price();

                // Worse: stays behind the single tree order.
                keys.push_back(rest(&mut book, worsen(is_bid, only_px, stride()), is_bid));
                assert!(hot_len(&book, is_bid) == 0);
                assert!(tree_len(&book, is_bid) == 2);

                // Equal price, later arrival: still behind.
                keys.push_back(rest(&mut book, only_px, is_bid));
                assert!(hot_len(&book, is_bid) == 0);
                assert!(tree_len(&book, is_bid) == 3);

                // Better: admitted.
                keys.push_back(rest(&mut book, improve(is_bid, only_px, stride()), is_bid));
                assert!(hot_len(&book, is_bid) == 1);
                assert!(tree_len(&book, is_bid) == 3);

                assert_side_matches(&book, is_bid, &keys, 0);

                book.drop_for_testing();
                test.end();

                if (sweep) break;
                sweep = true;
            };
            if (is_bid) break;
            is_bid = true;
        };
    }
}
