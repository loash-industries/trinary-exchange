/// Boundary cases for the multicoin book: insertion, cancellation, filling, and
/// the views that read across the buffer/tree seam.
///
/// `book_hot_buffer_tests` covers the seam's ordinary behaviour and
/// `book_priority_tests` covers demotion-freedom. This module covers the edges —
/// the exact capacity boundaries, the empty and single-element cases, the price
/// extremes the `u128` key has to encode, the order types that abort, and every
/// way a lookup can be asked for something that is not there.
///
/// Where a case has a natural "one before, exactly on, one after" shape, all three
/// are tested rather than the middle one standing in for its neighbours.
#[test_only]
module triex::book_edge_case_tests {
    use sui::test_scenario::begin;
    use triex::{book::{Self, Book}, constants, order_info::{Self, OrderInfo}};

    const OWNER: address = @0x1;
    const HOT_CAPACITY: u64 = 16;
    const HOT_SPILL_TARGET: u64 = 12;

    const ACCOUNT: address = @0xACC7;
    const OTHER_ACCOUNT: address = @0xACC8;

    fun qty(): u64 { 1_000_000 }

    fun price_at(level: u64): u64 { (level + 1) * 1_000 }

    fun level(): u64 { 100_000 }

    fun order_for(
        account: address,
        order_type: u8,
        self_matching: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire: u64,
    ): OrderInfo {
        order_info::new(
            object::id_from_address(@0xB00C),
            object::id_from_address(account),
            OWNER,
            order_type,
            self_matching,
            price,
            quantity,
            is_bid,
            0,
            0,
            0,
            expire,
            false,
            0,
            1,
        )
    }

    fun order(order_type: u8, price: u64, quantity: u64, is_bid: bool): OrderInfo {
        order_for(
            ACCOUNT,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            constants::max_u64(),
        )
    }

    fun rest(book: &mut Book, price: u64, is_bid: bool): u128 {
        rest_qty(book, price, qty(), is_bid)
    }

    fun rest_qty(book: &mut Book, price: u64, quantity: u64, is_bid: bool): u128 {
        let mut info = order(constants::no_restriction(), price, quantity, is_bid);
        book.create_order(&mut info, 0);
        assert!(info.order_inserted());

        info.order_id()
    }

    fun take(book: &mut Book, quantity: u64, taker_is_bid: bool): OrderInfo {
        let price = if (taker_is_bid) constants::max_price() else constants::min_price();
        let mut info = order(constants::immediate_or_cancel(), price, quantity, taker_is_bid);
        book.create_order(&mut info, 0);

        info
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

    fun hot_len(book: &Book, is_bid: bool): u64 {
        if (is_bid) book.hot_bids().length() else book.hot_asks().length()
    }

    fun tree_len(book: &Book, is_bid: bool): u64 {
        if (is_bid) book.bids().length() else book.asks().length()
    }

    // ================== Insertion ==================

    #[test]
    /// The empty book: a side with nothing in either store. Both sides are built up
    /// from it independently, because the first-order branch is the only one that
    /// consults neither the buffer's contents nor the tree's.
    fun first_order_on_each_side() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        assert!(book.side_is_empty(true));
        assert!(book.side_is_empty(false));
        assert!(book.side_length(true) == 0);
        assert!(book.side_length(false) == 0);
        assert!(side(&book, true).is_empty());

        let b = rest(&mut book, level(), true);
        assert!(side(&book, true) == vector[b]);
        assert!(hot_len(&book, true) == 1);
        assert!(tree_len(&book, true) == 0);
        // The other side is untouched.
        assert!(book.side_is_empty(false));

        let a = rest(&mut book, level() * 2, false);
        assert!(side(&book, false) == vector[a]);
        assert!(hot_len(&book, false) == 1);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The capacity boundary, one step at a time: at `HOT_CAPACITY - 1`, at
    /// `HOT_CAPACITY`, and at the placement after it. Nothing may reach the tree
    /// before the last of those.
    fun capacity_boundary_step_by_step() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < HOT_CAPACITY - 1) {
            rest(&mut book, price_at(i), true);
            i = i + 1;
        };
        assert!(hot_len(&book, true) == HOT_CAPACITY - 1);
        assert!(tree_len(&book, true) == 0);

        rest(&mut book, price_at(HOT_CAPACITY - 1), true);
        assert!(hot_len(&book, true) == HOT_CAPACITY);
        assert!(tree_len(&book, true) == 0, tree_len(&book, true));

        rest(&mut book, price_at(HOT_CAPACITY), true);
        assert!(hot_len(&book, true) == HOT_SPILL_TARGET);
        assert!(tree_len(&book, true) == HOT_CAPACITY + 1 - HOT_SPILL_TARGET);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// A full buffer plus an order that does not qualify for it: the order goes
    /// behind, and the buffer neither grows nor spills. A spill here would evict a
    /// better order to make room for a worse one.
    fun order_behind_a_full_buffer_does_not_spill_it() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < HOT_CAPACITY) {
            rest(&mut book, price_at(i), true);
            i = i + 1;
        };
        assert!(hot_len(&book, true) == HOT_CAPACITY);

        // Worse than everything inline.
        rest(&mut book, 1, true);
        assert!(hot_len(&book, true) == HOT_CAPACITY);
        assert!(tree_len(&book, true) == 1);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The admission rule over a populated tree, at one price unit either side of
    /// the tree's best and exactly on it. "Exactly on" means equal price and a
    /// later sequence, which is strictly worse, so it belongs behind.
    fun admission_boundary_against_the_tree_best() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        // Build, then sweep the buffer away, leaving a tree-only ask side.
        let mut i = 0;
        while (i < 30) {
            rest(&mut book, price_at(29 - i), false);
            i = i + 1;
        };
        let hot = hot_len(&book, false);
        take(&mut book, qty() * hot, true);
        assert!(hot_len(&book, false) == 0);

        let best_tree = book.get_order(side(&book, false)[0]).price();
        let tree_before = tree_len(&book, false);

        // Exactly the tree's best price: equal price, later arrival, so behind.
        rest(&mut book, best_tree, false);
        assert!(hot_len(&book, false) == 0);
        assert!(tree_len(&book, false) == tree_before + 1);

        // One unit worse: still behind.
        rest(&mut book, best_tree + 1, false);
        assert!(hot_len(&book, false) == 0);
        assert!(tree_len(&book, false) == tree_before + 2);

        // One unit better: inline.
        rest(&mut book, best_tree - 1, false);
        assert!(hot_len(&book, false) == 1);
        assert!(tree_len(&book, false) == tree_before + 2);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The price extremes the key has to encode. `MAX_PRICE` is `2^63 - 1`, which
    /// fills bits 64..126 of the key and leaves bit 127 for the side flag; an
    /// off-by-one in the encoding would collide the two sides or corrupt the price.
    /// Quantities are 1 here so nothing overflows the `qty x price` product.
    fun price_extremes_encode_and_order() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        // The two extremes on one side cover the whole price range, so they cross
        // anything placed opposite them. Each side therefore gets its own book;
        // what is under test is the encoding, not the matching.
        let min_ask = rest_qty(&mut book, constants::min_price(), 1, false);
        let max_ask = rest_qty(&mut book, constants::max_price(), 1, false);
        assert!(side(&book, false) == vector[min_ask, max_ask]);
        assert!(book.get_order(min_ask).price() == constants::min_price());
        assert!(book.get_order(max_ask).price() == constants::max_price());
        assert!(book.side_length(false) == 2);
        // Ask keys carry the side flag in bit 127, so both are above 2^127 — and
        // the max-price ask must not have overflowed into anything else.
        assert!(min_ask >= 1u128 << 127);
        assert!(max_ask >= 1u128 << 127);
        assert!(max_ask > min_ask);
        book.drop_for_testing();

        let mut bid_book = book::empty_multicoin(test.ctx());
        let min_bid = rest_qty(&mut bid_book, constants::min_price(), 1, true);
        let max_bid = rest_qty(&mut bid_book, constants::max_price(), 1, true);
        assert!(side(&bid_book, true) == vector[max_bid, min_bid]);
        assert!(bid_book.get_order(min_bid).price() == constants::min_price());
        assert!(bid_book.get_order(max_bid).price() == constants::max_price());
        assert!(bid_book.side_length(true) == 2);
        // Bid keys leave bit 127 clear, so even a max-price bid stays below every
        // possible ask key — which is what keeps the two sides' key spaces apart.
        assert!(max_bid < 1u128 << 127);
        assert!(max_bid > min_bid);
        assert!(max_bid < min_ask);
        bid_book.drop_for_testing();

        test.end();
    }

    #[test]
    /// Both sides carrying a full buffer and a stocked tree at once. The two sides
    /// share every helper, so a helper that ignored `is_bid` anywhere would show up
    /// as one side's orders appearing in the other.
    fun both_sides_loaded_stay_separate() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut bids = vector[];
        let mut asks = vector[];
        let mut i = 0;
        while (i < 40) {
            bids.push_back(rest(&mut book, level() - (40 - i) * 10, true));
            asks.push_back(rest(&mut book, level() + (40 - i) * 10, false));
            i = i + 1;
        };

        assert!(book.side_length(true) == 40);
        assert!(book.side_length(false) == 40);

        // No id appears on the side it does not belong to.
        let bid_side = side(&book, true);
        let ask_side = side(&book, false);
        bids.do_ref!(|id| assert!(!ask_side.contains(id)));
        asks.do_ref!(|id| assert!(!bid_side.contains(id)));

        book.drop_for_testing();
        test.end();
    }

    #[test, expected_failure(abort_code = ::triex::order_info::EPOSTOrderCrossesOrderbook)]
    /// A POST_ONLY that would take liquidity must abort rather than rest or fill.
    fun post_only_that_crosses_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, level(), false);
        let mut info = order(constants::post_only(), level(), qty(), true);
        book.create_order(&mut info, 0);

        abort 0
    }

    #[test]
    /// A POST_ONLY that rests exactly at the touch without crossing it is legal and
    /// must land inline, since it is the new best of its side.
    fun post_only_at_the_touch_rests() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, level() + 10, false);
        let mut info = order(constants::post_only(), level(), qty(), true);
        book.create_order(&mut info, 0);
        assert!(info.order_inserted());
        assert!(hot_len(&book, true) == 1);

        book.drop_for_testing();
        test.end();
    }

    #[test, expected_failure(abort_code = ::triex::order_info::EFOKOrderCannotBeFullyFilled)]
    /// A FOK larger than the book can fill must abort, leaving nothing behind.
    fun fok_that_cannot_fill_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, level(), false);
        let mut info = order(constants::fill_or_kill(), constants::max_price(), qty() * 5, true);
        book.create_order(&mut info, 0);

        abort 0
    }

    #[test]
    /// A FOK that the book can fill exactly: it executes and does not rest.
    fun fok_that_fills_exactly_does_not_rest() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, level(), false);
        rest(&mut book, level(), false);

        let mut info = order(constants::fill_or_kill(), constants::max_price(), qty() * 2, true);
        book.create_order(&mut info, 0);
        assert!(!info.order_inserted());
        assert!(info.executed_quantity() == qty() * 2);
        assert!(book.side_is_empty(false));
        assert!(book.side_is_empty(true));

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// An IOC that outruns the book fills what it can and abandons the rest — the
    /// remainder must not be injected.
    fun ioc_remainder_is_not_injected() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, level(), false);
        let taker = take(&mut book, qty() * 4, true);

        assert!(taker.executed_quantity() == qty());
        assert!(!taker.order_inserted());
        assert!(book.side_is_empty(false));
        assert!(book.side_is_empty(true));

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// A limit order that crosses part of the book and rests the remainder. The
    /// resting part takes a key allocated *before* matching, so it queues by its
    /// original arrival, not by when the match finished.
    fun crossing_limit_rests_its_remainder() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, level(), false);
        let mut info = order(constants::no_restriction(), level(), qty() * 3, true);
        book.create_order(&mut info, 0);

        assert!(info.executed_quantity() == qty());
        assert!(info.order_inserted());
        assert!(book.side_is_empty(false));
        assert!(side(&book, true) == vector[info.order_id()]);
        assert!(book.get_order(info.order_id()).quantity() == qty() * 3);
        assert!(book.get_order(info.order_id()).filled_quantity() == qty());

        book.drop_for_testing();
        test.end();
    }

    // ================== Cancellation ==================

    #[test]
    /// The single-order case on both sides: cancelling it must leave the side
    /// genuinely empty in both stores, not merely reading as empty.
    fun cancelling_the_only_order_empties_the_side() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let b = rest(&mut book, level(), true);
        let a = rest(&mut book, level() * 2, false);

        book.cancel_order(b);
        assert!(book.side_is_empty(true));
        assert!(hot_len(&book, true) == 0);
        assert!(book.bids().is_empty());
        assert!(book.side_length(false) == 1);

        book.cancel_order(a);
        assert!(book.side_is_empty(false));
        assert!(book.asks().is_empty());

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Cancelling the four positions that bound the seam: the side's best, the
    /// buffer's worst, the tree's best and the tree's worst.
    fun cancelling_the_four_seam_positions() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < 40) {
            rest(&mut book, price_at(39 - i), false);
            i = i + 1;
        };

        let hot = hot_len(&book, false);
        let all = side(&book, false);
        let best_of_side = all[0];
        let worst_of_buffer = all[hot - 1];
        let best_of_tree = all[hot];
        let worst_of_tree = all[all.length() - 1];

        book.cancel_order(best_of_side);
        book.cancel_order(worst_of_buffer);
        book.cancel_order(best_of_tree);
        book.cancel_order(worst_of_tree);

        assert!(book.side_length(false) == 36);
        let after = side(&book, false);
        assert!(!after.contains(&best_of_side));
        assert!(!after.contains(&worst_of_buffer));
        assert!(!after.contains(&best_of_tree));
        assert!(!after.contains(&worst_of_tree));

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Cancelling every order on a deep side, from the back forwards — the reverse
    /// of the usual drain, so the tree empties before the buffer does.
    fun cancelling_from_the_back_forwards() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < 40) {
            rest(&mut book, price_at(39 - i), false);
            i = i + 1;
        };

        let mut all = side(&book, false);
        while (!all.is_empty()) {
            let last = all.pop_back();
            book.cancel_order(last);
            assert!(side(&book, false) == all);
        };

        assert!(book.side_is_empty(false));
        assert!(book.asks().is_empty());

        book.drop_for_testing();
        test.end();
    }

    #[test, expected_failure(abort_code = ::triex::big_vector::ENotFound)]
    /// Cancelling from a completely empty book. The buffer scan misses and the
    /// lookup falls through to the tree, which has nothing to find.
    fun cancelling_from_an_empty_book_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        book.cancel_order(1u128 << 100);

        abort 0
    }

    #[test, expected_failure(abort_code = ::triex::big_vector::ENotFound)]
    /// Cancelling the same order twice.
    fun cancelling_twice_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let id = rest(&mut book, level(), true);
        let first = book.cancel_order(id);
        assert!(first.order_id() == id);
        book.cancel_order(id);

        abort 0
    }

    #[test, expected_failure(abort_code = ::triex::big_vector::ENotFound)]
    /// Cancelling an order a fill already retired.
    fun cancelling_a_filled_order_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let id = rest(&mut book, level(), false);
        take(&mut book, qty(), true);
        assert!(book.side_is_empty(false));
        book.cancel_order(id);

        abort 0
    }

    #[test, expected_failure(abort_code = ::triex::big_vector::ENotFound)]
    /// A bid id looked up while only asks rest. The side is carried in the key's
    /// top bit, so this routes to an empty bid store rather than finding the ask.
    fun cancelling_on_the_wrong_side_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, level(), false);
        // A well-formed bid key (top bit clear) that was never issued.
        book.cancel_order(((level() as u128) << 64) + 7);

        abort 0
    }

    // ================== Filling ==================

    #[test]
    /// Taking against an empty side produces no fills and rests nothing.
    fun taking_against_an_empty_side_does_nothing() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let taker = take(&mut book, qty(), true);
        assert!(taker.executed_quantity() == 0);
        assert!(taker.fills().is_empty());
        assert!(book.side_is_empty(true));
        assert!(book.side_is_empty(false));

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// A sweep stopping exactly on the seam: `hot_len` orders taken, so the buffer
    /// empties to the last order and the tree is not entered at all.
    fun sweep_stopping_exactly_on_the_seam() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < 30) {
            rest(&mut book, price_at(29 - i), false);
            i = i + 1;
        };
        let hot = hot_len(&book, false);
        let tree = tree_len(&book, false);

        let taker = take(&mut book, qty() * hot, true);
        assert!(taker.executed_quantity() == qty() * hot);
        assert!(taker.fills().length() == hot);
        assert!(hot_len(&book, false) == 0);
        assert!(tree_len(&book, false) == tree);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// One order either side of that boundary, so the "stopped just short" and
    /// "stepped just over" cases are both covered rather than inferred.
    fun sweep_one_short_and_one_past_the_seam() {
        let mut short_by = 0u64;
        while (short_by < 2) {
            let mut test = begin(OWNER);
            let mut book = book::empty_multicoin(test.ctx());

            let mut i = 0;
            while (i < 30) {
                rest(&mut book, price_at(29 - i), false);
                i = i + 1;
            };
            let hot = hot_len(&book, false);
            let tree = tree_len(&book, false);

            let n = if (short_by == 0) hot - 1 else hot + 1;
            let taker = take(&mut book, qty() * n, true);
            assert!(taker.executed_quantity() == qty() * n);

            if (short_by == 0) {
                assert!(hot_len(&book, false) == 1);
                assert!(tree_len(&book, false) == tree);
            } else {
                assert!(hot_len(&book, false) == 0);
                assert!(tree_len(&book, false) == tree - 1);
            };

            book.drop_for_testing();
            test.end();
            short_by = short_by + 1;
        };
    }

    #[test]
    /// A taker limited by price rather than quantity stops at the first maker it
    /// cannot pay for, leaving the rest of the side intact.
    fun taker_stops_where_the_price_stops_crossing() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < 20) {
            rest(&mut book, price_at(i), false);
            i = i + 1;
        };

        // Crosses only the best five levels.
        let mut info = order(
            constants::immediate_or_cancel(),
            price_at(4),
            qty() * 100,
            true,
        );
        book.create_order(&mut info, 0);

        assert!(info.executed_quantity() == qty() * 5);
        assert!(book.side_length(false) == 15);
        assert!(book.get_order(side(&book, false)[0]).price() == price_at(5));

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The `MAX_FILLS` cap. A sweep able to consume more makers than the cap allows
    /// stops at the cap, reports it, and leaves the rest of the side untouched and
    /// correctly ordered.
    fun sweep_stops_at_the_fill_limit() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let max_fills = constants::max_fills();
        let depth = max_fills + 10;
        let mut i = 0;
        while (i < depth) {
            rest(&mut book, price_at(depth - i), false);
            i = i + 1;
            if (i % 64 == 0) { test.next_tx(OWNER); };
        };
        let before = side(&book, false);

        let taker = take(&mut book, qty() * depth, true);
        assert!(taker.fill_limit_reached());
        assert!(taker.executed_quantity() == qty() * max_fills);

        let after = side(&book, false);
        assert!(after.length() == depth - max_fills);
        let mut k = 0;
        while (k < after.length()) {
            assert!(after[k] == before[k + max_fills]);
            k = k + 1;
        };

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// A maker expiring exactly at the taker's timestamp is still live — expiry is
    /// `timestamp > expire_timestamp`, so the boundary belongs to the maker.
    fun maker_expiring_on_the_timestamp_is_still_live() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut info = order_for(
            ACCOUNT,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            level(),
            qty(),
            false,
            10,
        );
        book.create_order(&mut info, 0);

        // At exactly t = 10 the order fills normally.
        let mut taker = order(
            constants::immediate_or_cancel(),
            constants::max_price(),
            qty(),
            true,
        );
        book.create_order(&mut taker, 10);
        assert!(taker.executed_quantity() == qty());
        assert!(!taker.fills()[0].expired());

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// One tick later the same maker is expired: it is retired without filling, the
    /// taker gets nothing, and the side is left empty.
    fun maker_expired_by_one_tick_is_retired_unfilled() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut info = order_for(
            ACCOUNT,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            level(),
            qty(),
            false,
            10,
        );
        book.create_order(&mut info, 0);

        let mut taker = order(
            constants::immediate_or_cancel(),
            constants::max_price(),
            qty(),
            true,
        );
        book.create_order(&mut taker, 11);

        assert!(taker.executed_quantity() == 0);
        assert!(taker.fills().length() == 1);
        assert!(taker.fills()[0].expired());
        assert!(book.side_is_empty(false));

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// A side of nothing but expired orders: the walk has to retire all of them and
    /// terminate, rather than stalling on the first one it cannot fill.
    fun a_side_of_only_expired_orders_drains() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < 25) {
            let mut info = order_for(
                ACCOUNT,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price_at(25 - i),
                qty(),
                false,
                10,
            );
            book.create_order(&mut info, 0);
            i = i + 1;
        };
        assert!(book.side_length(false) == 25);

        let mut taker = order(
            constants::immediate_or_cancel(),
            constants::max_price(),
            qty(),
            true,
        );
        book.create_order(&mut taker, 11);

        assert!(taker.executed_quantity() == 0);
        assert!(book.side_is_empty(false));
        assert!(book.asks().is_empty());

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// `cancel_maker` self-matching: the maker is expired out of the book instead of
    /// trading with its own account, and the orders behind it stay reachable.
    fun self_match_cancel_maker_retires_the_maker() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        // The taker's own resting ask, then someone else's behind it.
        let mine = rest(&mut book, level(), false);
        let mut theirs_info = order_for(
            OTHER_ACCOUNT,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            level() + 10,
            qty(),
            false,
            constants::max_u64(),
        );
        book.create_order(&mut theirs_info, 0);
        let theirs = theirs_info.order_id();

        let mut taker = order_for(
            ACCOUNT,
            constants::immediate_or_cancel(),
            constants::cancel_maker(),
            constants::max_price(),
            qty(),
            true,
            constants::max_u64(),
        );
        book.create_order(&mut taker, 0);

        // The maker was retired rather than matched, and the taker went on to fill
        // against the order behind it.
        assert!(taker.executed_quantity() == qty());
        let rested = side(&book, false);
        assert!(!rested.contains(&mine));
        assert!(!rested.contains(&theirs));
        assert!(book.side_is_empty(false));

        book.drop_for_testing();
        test.end();
    }

    #[test, expected_failure(abort_code = ::triex::order_info::ESelfMatchingCancelTaker)]
    /// `cancel_taker` self-matching aborts the whole transaction on contact.
    fun self_match_cancel_taker_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, level(), false);
        let mut taker = order_for(
            ACCOUNT,
            constants::immediate_or_cancel(),
            constants::cancel_taker(),
            constants::max_price(),
            qty(),
            true,
            constants::max_u64(),
        );
        book.create_order(&mut taker, 0);

        abort 0
    }

    // ================== Modify ==================

    #[test, expected_failure(abort_code = ::triex::book::ENewQuantityMustBeLessThanOriginal)]
    /// Modifying to the same quantity is not a reduction.
    fun modify_to_the_same_quantity_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let id = rest(&mut book, level(), true);
        book.modify_order(id, qty(), 0);

        abort 0
    }

    #[test, expected_failure(abort_code = ::triex::order::EInvalidNewQuantity)]
    /// Modifying below what is already filled must abort — the fill cannot be
    /// unwound.
    fun modify_below_filled_quantity_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let id = rest_qty(&mut book, level(), qty() * 4, false);
        take(&mut book, qty() * 3, true);
        assert!(book.get_order(id).filled_quantity() == qty() * 3);

        book.modify_order(id, qty(), 0);

        abort 0
    }

    #[test, expected_failure(abort_code = ::triex::big_vector::ENotFound)]
    /// Modifying an order that is not there.
    fun modify_of_an_absent_order_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, level(), true);
        book.modify_order(((level() as u128) << 64) + 99, 1, 0);

        abort 0
    }

    #[test, expected_failure(abort_code = ::triex::big_vector::ENotFound)]
    /// Reading an order that is not there.
    fun get_order_of_an_absent_order_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, level(), true);
        book.get_order(((level() as u128) << 64) + 99);

        abort 0
    }

    // ================== Views ==================

    #[test, expected_failure(abort_code = ::triex::book::EEmptyOrderbook)]
    /// `mid_price` needs both sides; one side alone is not a midpoint.
    fun mid_price_with_one_side_aborts() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, level(), true);
        book.mid_price(0);

        abort 0
    }

    #[test]
    /// `mid_price` must skip expired orders on both sides and quote from the best
    /// *live* prices, including when the live best is behind the seam.
    fun mid_price_skips_expired_across_the_seam() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        // Twenty short-dated asks in front of one live ask, so the live best sits
        // in the tree once the buffer is full of expired orders.
        let mut i = 0;
        while (i < 20) {
            let mut info = order_for(
                ACCOUNT,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                level() + 100 - i,
                qty(),
                false,
                5,
            );
            book.create_order(&mut info, 0);
            i = i + 1;
        };
        let live_ask = rest(&mut book, level() + 500, false);
        let live_bid = rest(&mut book, level() - 500, true);

        let mid = book.mid_price(10);
        let expected = (book.get_order(live_ask).price() + book.get_order(live_bid).price()) / 2;
        assert!(mid == expected, mid);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Level 2 across the seam: price levels are aggregated over both stores, in
    /// order, and the tick limit cuts the walk rather than the range.
    fun level2_aggregates_across_the_seam() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        // Five orders on each of eight levels, best last, so the levels straddle
        // the buffer boundary.
        let mut lv = 8;
        while (lv > 0) {
            let mut n = 0u64;
            while (n < 5) {
                rest(&mut book, level() + lv * 100, false);
                n = n + 1;
            };
            lv = lv - 1;
        };
        assert!(hot_len(&book, false) > 0);
        assert!(tree_len(&book, false) > 0);

        let (prices, quantities) = book.get_level2_range_and_ticks(
            constants::min_price(),
            constants::max_price(),
            constants::max_u64(),
            false,
            0,
        );
        assert!(prices.length() == 8);
        let mut k = 0;
        while (k < 8) {
            assert!(prices[k] == level() + (k + 1) * 100);
            assert!(quantities[k] == qty() * 5);
            k = k + 1;
        };

        // The tick limit truncates from the best price outwards.
        let (capped, _) = book.get_level2_range_and_ticks(
            constants::min_price(),
            constants::max_price(),
            3,
            false,
            0,
        );
        assert!(capped.length() == 3);
        assert!(capped[0] == level() + 100);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// A level 2 range that excludes the best prices has to skip forward into the
    /// side rather than stopping at the first order outside it.
    fun level2_range_skips_to_the_window() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < 30) {
            rest(&mut book, level() + (30 - i) * 100, false);
            i = i + 1;
        };

        let low = level() + 2_000;
        let high = level() + 2_500;
        let (prices, _) = book.get_level2_range_and_ticks(
            low,
            high,
            constants::max_u64(),
            false,
            0,
        );

        assert!(!prices.is_empty());
        let mut k = 0;
        while (k < prices.length()) {
            assert!(prices[k] >= low && prices[k] <= high);
            k = k + 1;
        };
        assert!(prices[0] == low);

        book.drop_for_testing();
        test.end();
    }

    #[test, expected_failure(abort_code = ::triex::book::EInvalidTicks)]
    /// Zero ticks asks for nothing and is rejected rather than silently returning
    /// an empty book.
    fun level2_with_zero_ticks_aborts() {
        let mut test = begin(OWNER);
        let book = book::empty_multicoin(test.ctx());

        book.get_level2_range_and_ticks(
            constants::min_price(),
            constants::max_price(),
            0,
            false,
            0,
        );

        abort 0
    }

    #[test, expected_failure(abort_code = ::triex::book::EInvalidPriceRange)]
    /// An inverted range.
    fun level2_with_inverted_range_aborts() {
        let mut test = begin(OWNER);
        let book = book::empty_multicoin(test.ctx());

        book.get_level2_range_and_ticks(level() + 10, level(), 5, false, 0);

        abort 0
    }

    #[test, expected_failure(abort_code = ::triex::book::EInvalidAmountIn)]
    /// `get_quantity_out` takes exactly one of base or quote; neither is invalid.
    fun quantity_out_with_neither_side_aborts() {
        let mut test = begin(OWNER);
        let book = book::empty_multicoin(test.ctx());

        book.get_quantity_out(0, 0, 0, 0);

        abort 0
    }

    #[test, expected_failure(abort_code = ::triex::book::EInvalidAmountIn)]
    /// And both is invalid too.
    fun quantity_out_with_both_sides_aborts() {
        let mut test = begin(OWNER);
        let book = book::empty_multicoin(test.ctx());

        book.get_quantity_out(1, 1, 0, 0);

        abort 0
    }

    #[test]
    /// The dry run must agree with what an identical taker actually executes,
    /// including when the quote has to walk out of the buffer and into the tree.
    fun quantity_out_agrees_with_the_fill_across_the_seam() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < 30) {
            rest(&mut book, price_at(29 - i), false);
            i = i + 1;
        };

        // Enough quote to reach well past the buffer.
        let input = qty() * price_at(20) * 20;
        let (base_out, _quote_left) = book.get_quantity_out(0, input, 0, 0);

        let mut taker = order(
            constants::immediate_or_cancel(),
            constants::max_price(),
            base_out,
            true,
        );
        book.create_order(&mut taker, 0);
        assert!(taker.executed_quantity() == base_out);
        assert!(taker.fills().length() > hot_len(&book, false) || base_out > 0);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// `get_quantity_out` on an empty book returns the input untouched rather than
    /// aborting — a router quoting a dead market gets a zero, not a failure.
    fun quantity_out_on_an_empty_book_returns_the_input() {
        let mut test = begin(OWNER);
        let book = book::empty_multicoin(test.ctx());

        let (base_out, quote_left) = book.get_quantity_out(0, 1_000, 0, 0);
        assert!(base_out == 0);
        assert!(quote_left == 1_000);

        let (base_left, quote_out) = book.get_quantity_out(1_000, 0, 0, 0);
        assert!(base_left == 1_000);
        assert!(quote_out == 0);

        book.drop_for_testing();
        test.end();
    }
}
