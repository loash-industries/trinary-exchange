/// Exhaustive verification of the admission decision, and of the claim that
/// **promotion cannot happen**, shared by `book_admission_window_tests` (multicoin
/// price scaling) and `coin_book_admission_window_tests` (coin-pool price scaling).
/// Both run the same `triex::book` module; a `Fixture` carries the only things that
/// differ between them — the constructor and the price grid.
///
/// ## What is being verified
///
/// Under one-way spill an order may travel buffer → tree and never back. The
/// buffer is therefore populated only by *admission* of newly placed orders, and
/// `inject_limit_order` is the whole of that logic. It has three branches, taken
/// in this order:
///
/// ```text
///   tree empty && hot_len < HOT_CAPACITY
///                                   -> ADMIT at its sorted position        (branch E)
///   hot_len == 0 && tree non-empty  -> ADMIT iff better(key, best_cold)    (W)
///   better(key, worst_hot)          -> ADMIT, then spill if over capacity  (branch C)
/// ```
///
/// Anything not admitted goes to the tree.
///
/// Branch **E** keeps a thin book entirely inline: with nothing behind the buffer,
/// every order — a side's first, a new best, or one behind the worst — beats the
/// (empty) tree, so admitting it is sound and saves minting the side's first tree
/// slice. Once the tree holds anything E is closed, and reopens only when the tree
/// drains back to empty.
///
/// Branch **W** is the promotion window: the only place in the module that reads
/// the tree in order to decide buffer membership. It opens whenever the buffer
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
/// Branch C then inherits soundness from E and W by induction: `worst_hot` beats
/// `best_cold`, so anything beating `worst_hot` beats the whole tree.
///
/// Rejection with a stocked tree is *conservative*: an order worse than
/// `worst_hot` but better than `best_cold` is sent to the tree even though the
/// buffer has room and the invariant would permit it inline. That costs a tree
/// write and never breaks anything. It is asserted below (`GAP`) so the behaviour
/// is pinned rather than assumed.
///
/// ## Promotion is structurally impossible
///
/// Every write into a hot buffer in `book.move` is one of three `push_back` /
/// `insert` calls in `inject_limit_order` (branches E, W and C), and all three
/// write the same local `order`, bound once from `order_info.to_order()`. No value
/// read out of a `BigVector` ever reaches a hot-buffer write: `spill` moves buffer
/// → tree, `remove_order` returns to its caller, and `borrow_mut` mutates in place.
/// That is an exhaustive argument over write sites, and `assert_no_promotion`
/// below is its observable form — after every operation, no id that was in the
/// tree is in the buffer.
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
#[test_only]
module triex::admission_window_test_utils {
    use sui::test_scenario::{begin, Scenario};
    use triex::{
        big_vector::slice_borrow,
        book::{Self, Book, hot_capacity, hot_spill_target},
        constants,
        order_info::{Self, OrderInfo}
    };

    const OWNER: address = @0x1;

    /// Which book is under test and the price grid it is driven on. Prices are laid
    /// out on a grid `stride` apart so that a "strictly between two adjacent ranks"
    /// price always exists.
    public struct Fixture has copy, drop {
        coin: bool,
        scaling: u64,
        base: u64,
        stride: u64,
        qty: u64,
    }

    /// The multicoin book, which prices with a scaling of 1.
    public fun multicoin(): Fixture {
        Fixture { coin: false, scaling: 1, base: 1_000_000, stride: 100, qty: 1_000_000 }
    }

    /// The coin book. Coin pools price through `FLOAT_SCALING`, so the grid is scaled
    /// to keep every level's quote far clear of the zero-quote bound.
    public fun coin(): Fixture {
        let s = constants::float_scaling();
        Fixture { coin: true, scaling: s, base: 1_000 * s, stride: s, qty: s }
    }

    fun new_book(f: Fixture, ctx: &mut TxContext): Book {
        if (f.coin) book::empty(ctx) else book::empty_multicoin(ctx)
    }

    // === Price helpers, written once and reused per side ===

    /// Rank 0 is the best price of a side; higher ranks are progressively worse.
    fun px(f: Fixture, is_bid: bool, rank: u64): u64 {
        if (is_bid) f.base - rank * f.stride else f.base + rank * f.stride
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

    fun order(f: Fixture, order_type: u8, price: u64, quantity: u64, is_bid: bool): OrderInfo {
        order_info::new(
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
            f.scaling,
        )
    }

    fun rest(f: Fixture, book: &mut Book, price: u64, is_bid: bool): u128 {
        let mut info = order(f, constants::no_restriction(), price, f.qty, is_bid);
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
        assert!(hot.length() <= hot_capacity(), case);

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
    /// ranks `h .. h+t-1`, so adjacent ranks are always `stride` apart.
    ///
    /// The buffer is built worst-price-first so every placement beats the current
    /// worst resident and is admitted. A tree order only goes behind once the
    /// buffer is full or the tree is already stocked (branch E admits it inline
    /// otherwise), so the buffer is first topped up to capacity with fillers priced
    /// just better than rank `h`, the tree is built from prices worse than all of
    /// them, and the fillers are cancelled. Every step goes through the public
    /// placement and cancel paths, and none spills, which is asserted, because a
    /// construction that spilled would not produce the occupancy it claims.
    fun build(f: Fixture, test: &mut Scenario, is_bid: bool, h: u64, t: u64): (Book, vector<u128>) {
        let mut book = new_book(f, test.ctx());
        let mut keys = vector[];

        let mut i = h;
        while (i > 0) {
            i = i - 1;
            keys.push_back(rest(f, &mut book, px(f, is_bid, i), is_bid));
        };
        assert!(hot_len(&book, is_bid) == h);
        assert!(tree_len(&book, is_bid) == 0);
        if (t == 0) return (book, keys);

        // One unit apart and short of rank `h` by less than a stride, so they beat
        // every tree order and sit behind every inline one. Measured up from rank
        // `h` rather than down from rank `h-1`, so `h == 0` needs no special case.
        let mut fillers = vector[];
        while (hot_len(&book, is_bid) < hot_capacity()) {
            let offset = fillers.length() + 1;
            let price = improve(is_bid, px(f, is_bid, h), f.stride - offset);
            fillers.push_back(rest(f, &mut book, price, is_bid));
        };

        let mut j = 0;
        while (j < t) {
            keys.push_back(rest(f, &mut book, px(f, is_bid, h + j), is_bid));
            j = j + 1;
        };
        assert!(hot_len(&book, is_bid) == hot_capacity());
        assert!(tree_len(&book, is_bid) == t);

        fillers.do!(|id| book.cancel_order(id));
        assert!(hot_len(&book, is_bid) == h);
        assert!(tree_len(&book, is_bid) == t);

        (book, keys)
    }

    /// The window state itself: buffer empty, tree holding `t`. Built by putting one
    /// order inline over a tree of `t` and then removing it — by cancel or by a
    /// taker sweep, because those are the two ways the window opens in practice and
    /// they reach it through different code.
    fun build_window(
        f: Fixture,
        test: &mut Scenario,
        is_bid: bool,
        t: u64,
        by_sweep: bool,
    ): (Book, vector<u128>) {
        let (mut book, mut keys) = build(f, test, is_bid, 1, t);
        let inline = keys.remove(0);

        if (by_sweep) {
            let taker_price = if (is_bid) constants::min_price() else constants::max_price();
            let mut taker = order(
                f,
                constants::immediate_or_cancel(),
                taker_price,
                f.qty,
                !is_bid,
            );
            book.create_order(&mut taker, 0);
            assert!(taker.executed_quantity() == f.qty);
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
    fun class_price(f: Fixture, book: &Book, is_bid: bool, class: u64): u64 {
        let all = side(book, is_bid);
        if (class == ABOVE_ALL) {
            if (all.is_empty()) return px(f, is_bid, 0);
            return improve(is_bid, book.get_order(all[0]).price(), f.stride)
        };
        if (class == BELOW_ALL) {
            if (all.is_empty()) return px(f, is_bid, 0);
            return worsen(is_bid, book.get_order(all[all.length() - 1]).price(), f.stride)
        };
        let hot = hot_ids(book, is_bid);
        let tree = tree_ids(book, is_bid);
        if (class == BUFFER_INTERIOR) {
            // Strictly between the buffer's worst and its next-best.
            return improve(is_bid, book.get_order(hot[0]).price(), f.stride / 2)
        };
        if (class == TIE_HOT_WORST) {
            return book.get_order(hot[0]).price()
        };
        if (class == GAP) {
            // Strictly between the buffer's worst and the tree's best.
            return worsen(is_bid, book.get_order(hot[0]).price(), f.stride / 2)
        };
        // TIE_TREE_BEST
        book.get_order(tree[0]).price()
    }

    /// The specification, written from the invariant rather than from the code: an
    /// order belongs inline exactly when it beats everything already inline, or —
    /// with an empty buffer — when it beats the whole tree, or when there is no
    /// tree at all and the buffer has room for it. Equal price means later arrival,
    /// which is strictly worse, so every comparison here is strict.
    fun spec_admits(book: &Book, is_bid: bool, h: u64, t: u64, price: u64): bool {
        if (h == 0 && t == 0) return true;
        if (h == 0) {
            let tree = tree_ids(book, is_bid);
            return better_px(is_bid, price, book.get_order(tree[0]).price())
        };
        if (t == 0 && h < hot_capacity()) return true;
        let hot = hot_ids(book, is_bid);

        better_px(is_bid, price, book.get_order(hot[0]).price())
    }

    /// One cell of the table: build the state, place one order of the given class,
    /// and check the outcome against the specification and against every invariant.
    fun check_cell(
        f: Fixture,
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
            build_window(f, test, is_bid, t, window_by_sweep)
        } else {
            build(f, test, is_bid, h, t)
        };

        let tree_before = tree_ids(&book, is_bid);
        let price = class_price(f, &book, is_bid, class);
        let expect_hot = spec_admits(&book, is_bid, h, t, price);

        let placed = rest(f, &mut book, price, is_bid);
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
            if (h + 1 > hot_capacity()) {
                // Admission overflowed the buffer, so the spill fired. The spilled
                // orders are the buffer's worst, which may include the newcomer
                // itself — `assert_side_matches` has already confirmed the result is
                // correctly ordered either way.
                assert!(hot_after == hot_spill_target(), case);
                assert!(tree_after == h + t + 1 - hot_spill_target(), case);
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
    /// class, both window entry paths.
    public fun run_row(f: Fixture, is_bid: bool, h: u64) {
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
                    check_cell(f, &mut test, is_bid, h, t, class, true);
                    test.end();
                    let mut test2 = begin(OWNER);
                    check_cell(f, &mut test2, is_bid, h, t, class, false);
                    test2.end();
                } else {
                    let mut test = begin(OWNER);
                    check_cell(f, &mut test, is_bid, h, t, class, false);
                    test.end();
                };
                class = class + 1;
            };
            ti = ti + 1;
        };
    }

    /// The whole grid for one side: every buffer occupancy, via `run_row`.
    public fun run_grid(f: Fixture, is_bid: bool) {
        let occupancies = vector[0u64, 1, 2, hot_capacity() - 1, hot_capacity()];
        occupancies.do!(|h| run_row(f, is_bid, h));
    }

    // === Targeted properties the grid implies but does not name ===

    /// The window cannot be entered by spilling. `spill` leaves `HOT_SPILL_TARGET`
    /// orders behind, so however many times it fires the buffer never empties —
    /// which is what keeps branch W reachable only from removals.
    public fun spill_never_opens_the_window(f: Fixture) {
        let mut test = begin(OWNER);
        let mut book = new_book(f, test.ctx());

        let mut i = 0;
        while (i < 200) {
            rest(f, &mut book, px(f, false, 200 - i), false);
            assert!(hot_len(&book, false) > 0, i);
            assert!(hot_len(&book, false) >= hot_spill_target() || tree_len(&book, false) == 0, i);
            i = i + 1;
            if (i % 64 == 0) { test.next_tx(OWNER); };
        };

        book.drop_for_testing();
        test.end();
    }

    /// The window opening and closing repeatedly on both sides. Each cycle sweeps
    /// the buffer away, re-admits through W, then fills the buffer back through
    /// branch C — so W is entered from a tree that grew deeper on every pass.
    public fun repeated_window_cycles(f: Fixture) {
        let mut is_bid = false;
        while (true) {
            let mut test = begin(OWNER);
            let mut book = new_book(f, test.ctx());

            // A tree deep enough that later cycles descend it.
            let mut i = 60;
            while (i > 0) {
                rest(f, &mut book, px(f, is_bid, i), is_bid);
                i = i - 1;
            };

            let mut cycle = 0;
            while (cycle < 5) {
                let hot = hot_len(&book, is_bid);
                assert!(hot > 0);

                // Sweep the buffer away: the window opens.
                let taker_price = if (is_bid) constants::min_price() else constants::max_price();
                let mut taker = order(
                    f,
                    constants::immediate_or_cancel(),
                    taker_price,
                    f.qty * hot,
                    !is_bid,
                );
                book.create_order(&mut taker, 0);
                assert!(hot_len(&book, is_bid) == 0);
                assert!(tree_len(&book, is_bid) > 0);

                let tree_before = tree_ids(&book, is_bid);
                let best_tree_px = book.get_order(tree_before[0]).price();

                // Rejected through W, then accepted through W.
                rest(f, &mut book, worsen(is_bid, best_tree_px, f.stride / 2), is_bid);
                assert!(hot_len(&book, is_bid) == 0);
                rest(f, &mut book, improve(is_bid, best_tree_px, f.stride / 2), is_bid);
                assert!(hot_len(&book, is_bid) == 1);

                // Then refill through branch C without touching the tree.
                let tree_now = tree_len(&book, is_bid);
                let mut k = 1;
                while (k < 6) {
                    rest(
                        f,
                        &mut book,
                        improve(is_bid, best_tree_px, f.stride / 2 + k * f.stride),
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

    /// The conservative gap, stated as its own case because it is the one place the
    /// implementation is deliberately weaker than the invariant requires: an order
    /// worse than the buffer's worst but better than the tree's best goes to the
    /// tree, even with the buffer far from full. It costs a tree write and breaks
    /// nothing, and the read order is unaffected.
    public fun orders_in_the_gap_go_behind_a_half_empty_buffer(f: Fixture) {
        let mut is_bid = false;
        while (true) {
            let mut test = begin(OWNER);
            let (mut book, mut keys) = build(f, &mut test, is_bid, 2, 4);

            let hot = hot_ids(&book, is_bid);
            let tree = tree_ids(&book, is_bid);
            let gap_price = worsen(is_bid, book.get_order(hot[0]).price(), f.stride / 2);
            assert!(better_px(is_bid, gap_price, book.get_order(tree[0]).price()));

            let placed = rest(f, &mut book, gap_price, is_bid);
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

    /// A newly placed order can itself be spilled by the very placement that
    /// admitted it: admitted just above the buffer's worst, then carried out with
    /// the rest of the tail when the buffer overflows. Legal — it is still the
    /// worst of what was inline — and worth pinning, because it is the one case
    /// where "admitted" and "ends up in the buffer" differ.
    public fun a_placement_can_spill_itself(f: Fixture) {
        let mut test = begin(OWNER);
        let (mut book, mut keys) = build(f, &mut test, false, hot_capacity(), 0);

        let hot = hot_ids(&book, false);
        // Just better than the buffer's worst, so it is admitted at index 1 and
        // sits inside the tail the spill takes.
        let price = improve(false, book.get_order(hot[0]).price(), f.stride / 2);
        let placed = rest(f, &mut book, price, false);
        keys.push_back(placed);

        assert!(hot_len(&book, false) == hot_spill_target());
        assert!(tree_ids(&book, false).contains(&placed));
        assert_side_matches(&book, false, &keys, 0);

        book.drop_for_testing();
        test.end();
    }

    /// The minimal window: a tree of exactly one order. `max_slice` / `min_slice`
    /// have to report that single element as the tree's best, on a tree that has
    /// never split a leaf.
    public fun window_over_a_single_tree_order(f: Fixture) {
        let mut is_bid = false;
        while (true) {
            let mut sweep = false;
            while (true) {
                let mut test = begin(OWNER);
                let (mut book, mut keys) = build_window(f, &mut test, is_bid, 1, sweep);
                assert!(tree_len(&book, is_bid) == 1);

                let only = tree_ids(&book, is_bid)[0];
                let only_px = book.get_order(only).price();

                // Worse: stays behind the single tree order.
                keys.push_back(rest(f, &mut book, worsen(is_bid, only_px, f.stride), is_bid));
                assert!(hot_len(&book, is_bid) == 0);
                assert!(tree_len(&book, is_bid) == 2);

                // Equal price, later arrival: still behind.
                keys.push_back(rest(f, &mut book, only_px, is_bid));
                assert!(hot_len(&book, is_bid) == 0);
                assert!(tree_len(&book, is_bid) == 3);

                // Better: admitted.
                keys.push_back(rest(f, &mut book, improve(is_bid, only_px, f.stride), is_bid));
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

    // === Branch E ===

    /// The thin-book case branch E exists for: orders behind the best, on a side
    /// whose tree is empty, rest inline rather than creating the side's first tree
    /// slice — including an equal price, which arrives later and so sits behind the
    /// order it ties with.
    public fun behind_the_best_on_an_empty_tree_stays_inline(f: Fixture) {
        let mut is_bid = false;
        while (true) {
            let mut test = begin(OWNER);
            let mut book = new_book(f, test.ctx());

            let best = rest(f, &mut book, px(f, is_bid, 0), is_bid);
            let behind = rest(f, &mut book, px(f, is_bid, 5), is_bid);
            let tied = rest(f, &mut book, px(f, is_bid, 5), is_bid);
            let keys = vector[best, behind, tied];
            assert!(hot_len(&book, is_bid) == 3);
            assert!(tree_len(&book, is_bid) == 0);
            assert!(side(&book, is_bid) == keys);
            assert_side_matches(&book, is_bid, &keys, 0);

            book.drop_for_testing();
            test.end();

            if (is_bid) break;
            is_bid = true;
        };
    }

    /// Once the tree holds anything, a placement behind the buffer goes to the tree
    /// even with room inline: admitting it would need the tree's best key to prove
    /// it still beats the tree, a read this path deliberately does not pay.
    public fun behind_the_buffer_with_a_stocked_tree_goes_to_the_tree(f: Fixture) {
        let mut is_bid = false;
        while (true) {
            let mut test = begin(OWNER);
            let mut book = new_book(f, test.ctx());
            let mut keys = vector[];

            // Worsening prices fill the buffer from the back, then one more lands in
            // the tree.
            let mut rank = 0;
            while (rank <= hot_capacity()) {
                keys.push_back(rest(f, &mut book, px(f, is_bid, rank), is_bid));
                rank = rank + 1;
            };
            assert!(hot_len(&book, is_bid) == hot_capacity());
            assert!(tree_len(&book, is_bid) == 1);

            // Free a slot by cancelling the best order, then quote behind the buffer.
            let best = keys.remove(0);
            book.cancel_order(best);
            assert!(hot_len(&book, is_bid) == hot_capacity() - 1);

            let placed = rest(f, &mut book, px(f, is_bid, 2 * hot_capacity()), is_bid);
            keys.push_back(placed);
            assert!(hot_len(&book, is_bid) == hot_capacity() - 1);
            assert!(tree_len(&book, is_bid) == 2);
            assert!(tree_ids(&book, is_bid)[1] == placed);
            assert_side_matches(&book, is_bid, &keys, 0);

            book.drop_for_testing();
            test.end();

            if (is_bid) break;
            is_bid = true;
        };
    }

    /// Branch E reopening. Every other E case starts from a side whose tree was
    /// never used; here the tree first grows past one leaf slice, so it has a root
    /// above its leaves, and is then drained back to empty — by cancelling every
    /// tree order under a stocked buffer, or by a taker sweep through both stores.
    /// The tree's `is_empty` has to report the drained tree as empty, or orders
    /// behind the worst would keep minting tree slices; on the swept side a stale
    /// emptiness would send the first new order to W, to read the best key of a
    /// tree with nothing in it.
    public fun a_drained_tree_reopens_branch_e(f: Fixture) {
        let mut is_bid = false;
        while (true) {
            let mut by_sweep = false;
            while (true) {
                let mut test = begin(OWNER);
                let (mut book, keys) = build(f, &mut test, is_bid, 2, 40);
                let (bid_depth, _, ask_depth, _) = book.shape();
                assert!((if (is_bid) bid_depth else ask_depth) > 0);

                if (by_sweep) {
                    let total = keys.length() * f.qty;
                    let mut taker = order(
                        f,
                        constants::immediate_or_cancel(),
                        if (is_bid) constants::min_price() else constants::max_price(),
                        total,
                        !is_bid,
                    );
                    book.create_order(&mut taker, 0);
                    assert!(taker.executed_quantity() == total);
                    assert!(hot_len(&book, is_bid) == 0);
                } else {
                    tree_ids(&book, is_bid).do!(|id| book.cancel_order(id));
                    assert!(hot_len(&book, is_bid) == 2);
                };
                assert!(tree_len(&book, is_bid) == 0);
                assert!((if (is_bid) book.bids() else book.asks()).is_empty());

                // Behind everything still resting, then a tie with that: both inline.
                let mut keys = hot_ids(&book, is_bid);
                let h = keys.length();
                let behind_px = if (h == 0) px(f, is_bid, 0)
                else worsen(is_bid, book.get_order(keys[0]).price(), f.stride);
                let behind = rest(f, &mut book, behind_px, is_bid);
                let tied = rest(f, &mut book, behind_px, is_bid);
                keys.push_back(behind);
                keys.push_back(tied);

                assert!(hot_len(&book, is_bid) == h + 2);
                assert!(tree_len(&book, is_bid) == 0);
                let read = side(&book, is_bid);
                assert!(read[h] == behind && read[h + 1] == tied);
                assert_side_matches(&book, is_bid, &keys, 0);

                book.drop_for_testing();
                test.end();

                if (by_sweep) break;
                by_sweep = true;
            };
            if (is_bid) break;
            is_bid = true;
        };
    }
}
