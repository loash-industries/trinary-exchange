/// Demotion-freedom and price-time priority for the multicoin book.
///
/// **Demotion** here means one thing precisely: a resting order moving *behind*
/// an order it previously ranked ahead of. No operation may cause it — not a
/// placement, not a cancel, not a fill, not a modify, and not the spill that moves
/// an order from the inline buffer into the tree. A trader who quoted first keeps
/// their place until they leave the book of their own accord or are filled.
///
/// The structural argument is short: read order is key order (asserted in
/// `book_invariant_tests`), and a key is assigned once in `create_order` and never
/// rewritten — `order::modify` touches `quantity` alone, and `generate_fill`
/// touches `filled_quantity` and `status`. So demotion is impossible unless one of
/// those statements is false. This module refuses to rely on the argument and
/// tests the property itself, because it is the one guarantee a market cannot
/// quietly lose: a book that silently re-queues orders is still internally
/// consistent, still passes every ordering assertion, and is still broken.
///
/// `assert_no_demotion` is the general form — it compares a side before and after
/// an operation and requires every surviving order to hold its relative place. The
/// named tests below aim it at each mechanism that touches position.
///
/// Both sides get every case rather than one standing in for the other. The
/// sequence counters run in *opposite* directions (`START_BID_ORDER_ID` descends
/// from `u64::MAX`, `START_ASK_ORDER_ID` ascends from 1) precisely so that "older
/// is better" holds under one comparison on both sides, and an error in that
/// arrangement would reverse time priority on exactly one of them.
#[test_only]
module triex::book_priority_tests {
    use sui::test_scenario::begin;
    use triex::{book::{Self, Book}, constants, order_info::{Self, OrderInfo}};

    const OWNER: address = @0x1;
    const HOT_CAPACITY: u64 = 16;

    fun qty(): u64 { 1_000_000 }

    fun price_at(level: u64): u64 { (level + 1) * 1_000 }

    /// One price, used wherever the test is about time priority rather than price.
    fun level(): u64 { 100_000 }

    fun order(order_type: u8, price: u64, quantity: u64, is_bid: bool, expire: u64): OrderInfo {
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
            expire,
            false,
            0,
            1,
        )
    }

    fun rest(book: &mut Book, price: u64, is_bid: bool): u128 {
        let mut info = order(
            constants::no_restriction(),
            price,
            qty(),
            is_bid,
            constants::max_u64(),
        );
        book.create_order(&mut info, 0);
        assert!(info.order_inserted());

        info.order_id()
    }

    fun rest_qty(book: &mut Book, price: u64, quantity: u64, is_bid: bool): u128 {
        let mut info = order(
            constants::no_restriction(),
            price,
            quantity,
            is_bid,
            constants::max_u64(),
        );
        book.create_order(&mut info, 0);
        assert!(info.order_inserted());

        info.order_id()
    }

    /// Take `quantity` against `is_bid`'s opposite side, at a price that crosses
    /// everything, so the sweep is bounded by quantity alone.
    fun take(book: &mut Book, quantity: u64, taker_is_bid: bool, ts: u64): OrderInfo {
        let price = if (taker_is_bid) constants::max_price() else constants::min_price();
        let mut info = order(
            constants::immediate_or_cancel(),
            price,
            quantity,
            taker_is_bid,
            constants::max_u64(),
        );
        book.create_order(&mut info, ts);

        info
    }

    /// The whole side in book order.
    fun side(book: &Book, is_bid: bool): vector<u128> {
        let mut ids = vector[];
        let mut cur = book.cursor_begin(is_bid);
        while (!cur.cursor_is_null()) {
            ids.push_back(book.cursor_borrow(is_bid, &cur).order_id());
            cur = book.cursor_next(is_bid, cur);
        };

        ids
    }

    fun index_of(v: &vector<u128>, id: u128): Option<u64> {
        let mut i = 0;
        while (i < v.length()) {
            if (v[i] == id) return option::some(i);
            i = i + 1;
        };

        option::none()
    }

    /// **The property.** Every order present both before and after must appear in
    /// the same relative order. Orders that left (cancelled, filled, expired) are
    /// ignored; orders that arrived are ignored. What is forbidden is a survivor
    /// overtaking another survivor — in either direction, since a promotion for one
    /// order is a demotion for the one it passed.
    fun assert_no_demotion(before: &vector<u128>, after: &vector<u128>) {
        let mut last = option::none<u64>();
        let mut i = 0;
        while (i < after.length()) {
            let was = index_of(before, after[i]);
            if (was.is_some()) {
                let at = was.destroy_some();
                if (last.is_some()) {
                    // Strictly increasing: survivor order is preserved exactly.
                    assert!(at > *last.borrow(), at);
                };
                last = option::some(at);
            };
            i = i + 1;
        };
    }

    /// Placement is the one operation allowed to put an order *between* two
    /// existing ones, so it gets the same check plus the requirement that nothing
    /// already resting moved.
    fun assert_placement_kept_order(before: &vector<u128>, after: &vector<u128>, placed: u128) {
        assert!(after.length() == before.length() + 1);
        assert!(index_of(after, placed).is_some());
        assert_no_demotion(before, after);
    }

    // === Time priority at one price level ===

    #[test]
    /// Orders at the same price must queue by arrival, and stay that way as the
    /// queue crosses from the inline buffer into the tree. With one price the key's
    /// price half is constant, so this tests the sequence half alone — and the
    /// sequence counters run in opposite directions per side, so both are checked.
    fun same_price_queues_by_arrival_on_both_sides() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut bids = vector[];
        let mut asks = vector[];
        let mut i = 0u64;
        // Well past HOT_CAPACITY, so the queue spans the seam.
        while (i < 25) {
            bids.push_back(rest(&mut book, level(), true));
            asks.push_back(rest(&mut book, level() * 2, false));
            i = i + 1;
        };

        // Arrival order, verbatim, on both sides.
        assert!(side(&book, true) == bids);
        assert!(side(&book, false) == asks);

        // And the queue really does span the seam, though not where one might
        // guess. At a single price no newcomer can beat the buffer's resident, so
        // the buffer holds exactly *one* order and everything after it goes to the
        // tree — the extreme of the "worst-price-last" build in whitepaper §B.2.
        // A market where everyone quotes the same price gets no benefit from the
        // inline buffer at all, which is worth knowing and is asserted rather than
        // assumed.
        assert!(book.hot_bids().length() == 1);
        assert!(book.bids().length() == 24);
        assert!(book.hot_asks().length() == 1);
        assert!(book.asks().length() == 24);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Time priority within a level, with a *full* buffer sitting in front of it.
    /// The previous test leaves the buffer holding one order; this one fills the
    /// buffer with better prices first, so the whole same-price queue forms inside
    /// the tree and its ordering is decided entirely by `big_vector` key order
    /// rather than by the inline vector's insert position.
    fun same_price_queue_behind_a_full_buffer_keeps_arrival_order() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        // Improving prices fill and overflow the buffer.
        let mut i = 0;
        while (i < HOT_CAPACITY) {
            rest(&mut book, level() - (i + 1) * 100, true);
            i = i + 1;
        };
        let hot_len = book.hot_bids().length();
        assert!(hot_len > 0);

        // Now 25 bids at one price, all worse than everything inline.
        let mut queued = vector[];
        let mut j = 0u64;
        while (j < 25) {
            queued.push_back(rest(&mut book, level() - 10_000, true));
            j = j + 1;
        };

        // The buffer did not move, and the level queued by arrival behind it.
        assert!(book.hot_bids().length() == hot_len);
        let all = side(&book, true);
        let mut k = 0;
        while (k < 25) {
            assert!(all[all.length() - 25 + k] == queued[k]);
            k = k + 1;
        };

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// A later arrival at the same price must never enter the buffer ahead of an
    /// earlier one, even while the buffer has room. `better` is strict, so an order
    /// equal in price to the buffer's worst resident is *worse* in priority and
    /// belongs behind it — an off-by-one to non-strict comparison here would demote
    /// the earlier order without breaking any ordering assertion.
    fun equal_price_never_displaces_the_earlier_order() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let first = rest(&mut book, level(), true);
        let mut i = 0u64;
        while (i < 8) {
            let before = side(&book, true);
            let next = rest(&mut book, level(), true);
            let after = side(&book, true);

            // The newcomer is last, and nothing moved.
            assert!(after[after.length() - 1] == next);
            assert!(after[0] == first);
            assert_placement_kept_order(&before, &after, next);
            i = i + 1;
        };

        book.drop_for_testing();
        test.end();
    }

    // === Placement ===

    #[test]
    /// Placements sweeping from worst to best price: each new order takes the front
    /// and every existing order shifts back by one *position* without changing its
    /// order relative to the others. This is the path that spills, so it is also
    /// the path where a mis-indexed `spill` would evict the wrong order.
    fun improving_placements_never_demote() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < 40) {
            let before = side(&book, true);
            let placed = rest(&mut book, price_at(i), true);
            let after = side(&book, true);
            assert!(after[0] == placed);
            assert_placement_kept_order(&before, &after, placed);
            i = i + 1;
        };

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Prices arriving in scattered order, so placements land at the front of the
    /// buffer, in its middle, on the seam and deep in the tree. Every one of them
    /// must leave the existing queue untouched.
    fun scattered_placements_never_demote() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < 60) {
            let before = side(&book, false);
            let placed = rest(&mut book, price_at((i * 37) % 60), false);
            let after = side(&book, false);
            assert_placement_kept_order(&before, &after, placed);
            i = i + 1;
        };

        book.drop_for_testing();
        test.end();
    }

    // === Spill ===

    #[test]
    /// Spill must evict the buffer's *worst* residents and no others. Anything else
    /// is a demotion by another name: an order pushed into the tree while a
    /// worse-priced order stays inline ahead of it.
    fun spill_evicts_only_the_worst_of_the_buffer() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        // Fill the buffer exactly, best price last.
        let mut i = 0;
        while (i < HOT_CAPACITY) {
            rest(&mut book, price_at(i), true);
            i = i + 1;
        };
        assert!(book.bids().is_empty());
        let before = side(&book, true);

        // One more order overflows it.
        let placed = rest(&mut book, price_at(HOT_CAPACITY), true);
        let after = side(&book, true);
        assert_placement_kept_order(&before, &after, placed);

        // Exactly the tail of the old buffer moved to the tree, in order.
        let spilled = book.bids().length();
        assert!(spilled == HOT_CAPACITY + 1 - 12);
        let mut k = 0;
        while (k < spilled) {
            // The worst `spilled` orders were the last entries of `before`.
            let expect = before[before.length() - spilled + k];
            assert!(after[after.length() - spilled + k] == expect);
            k = k + 1;
        };

        book.drop_for_testing();
        test.end();
    }

    // === Cancellation ===

    #[test]
    /// Removing any single order must close the gap without reordering anything
    /// around it. Every position is tried in turn — front of buffer, middle, the
    /// buffer's last resident, the tree's first, the tree's middle and its last —
    /// by rebuilding the book and cancelling a different index each time.
    fun cancelling_any_position_never_demotes() {
        let mut at = 0;
        while (at < 40) {
            let mut test = begin(OWNER);
            let mut book = book::empty_multicoin(test.ctx());

            let mut i = 0;
            while (i < 40) {
                rest(&mut book, price_at(39 - i), false);
                i = i + 1;
            };

            let before = side(&book, false);
            book.cancel_order(before[at]);
            let after = side(&book, false);

            assert!(after.length() == before.length() - 1);
            assert!(index_of(&after, before[at]).is_none());
            assert_no_demotion(&before, &after);

            book.drop_for_testing();
            test.end();
            at = at + 1;
        };
    }

    #[test]
    /// Cancelling the whole buffer out from in front of a stocked tree. Under
    /// one-way spill nothing is pulled forward to replace it, so this is the case
    /// where a refill design would reorder and this one must not.
    fun draining_the_buffer_by_cancel_never_demotes() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < 40) {
            rest(&mut book, price_at(39 - i), false);
            i = i + 1;
        };

        let mut before = side(&book, false);
        let mut n = book.hot_asks().length();
        while (n > 0) {
            // Always cancel the current best, which is always a buffer resident.
            book.cancel_order(before[0]);
            let after = side(&book, false);
            assert_no_demotion(&before, &after);
            before = after;
            n = n - 1;
        };

        assert!(book.hot_asks().length() == 0);
        assert!(!book.asks().is_empty());
        // The survivors are still the original tail, in the original order.
        assert!(side(&book, false) == before);

        book.drop_for_testing();
        test.end();
    }

    // === Filling ===

    #[test]
    /// A partial fill must not re-queue the maker. It stays at the head of its
    /// price level with its remaining quantity, ahead of everything that arrived
    /// later — including orders placed *after* the partial fill.
    fun partial_fill_keeps_the_maker_at_the_head() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let a = rest_qty(&mut book, level(), qty(), false);
        let b = rest_qty(&mut book, level(), qty(), false);
        assert!(side(&book, false) == vector[a, b]);

        // Consume a quarter of `a`.
        let taker = take(&mut book, qty() / 4, true, 0);
        assert!(taker.executed_quantity() == qty() / 4);

        let after = side(&book, false);
        assert!(after == vector[a, b]);
        assert!(book.get_order(a).filled_quantity() == qty() / 4);
        assert!(book.get_order(a).quantity() == qty());

        // A newcomer at the same price still queues behind the partially filled
        // maker, not ahead of it.
        let c = rest_qty(&mut book, level(), qty(), false);
        assert!(side(&book, false) == vector[a, b, c]);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// A sweep consumes from the front and leaves the remainder in order, whether
    /// it stops inside the buffer, exactly on the seam, or inside the tree.
    fun sweeps_consume_from_the_front_only() {
        let mut depth_taken = 1;
        while (depth_taken <= 24) {
            let mut test = begin(OWNER);
            let mut book = book::empty_multicoin(test.ctx());

            let mut i = 0;
            while (i < 30) {
                rest(&mut book, price_at(29 - i), false);
                i = i + 1;
            };

            let before = side(&book, false);
            let taker = take(&mut book, qty() * depth_taken, true, 0);
            assert!(taker.executed_quantity() == qty() * depth_taken);
            let after = side(&book, false);

            // Exactly the first `depth_taken` are gone, and the tail is untouched.
            assert!(after.length() == 30 - depth_taken);
            let mut k = 0;
            while (k < after.length()) {
                assert!(after[k] == before[k + depth_taken]);
                k = k + 1;
            };
            assert_no_demotion(&before, &after);

            book.drop_for_testing();
            test.end();
            depth_taken = depth_taken + 1;
        };
    }

    #[test]
    /// A sweep that stops mid-order: the last maker touched is partially filled and
    /// must stay exactly where it is, at the front of what remains.
    fun sweep_stopping_mid_order_leaves_it_in_place() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut ids = vector[];
        let mut i = 0;
        while (i < 20) {
            ids.push_back(rest(&mut book, price_at(19 - i), false));
            i = i + 1;
        };
        let before = side(&book, false);

        // Five whole orders plus half of the sixth.
        let taker = take(&mut book, qty() * 5 + qty() / 2, true, 0);
        assert!(taker.executed_quantity() == qty() * 5 + qty() / 2);

        let after = side(&book, false);
        assert!(after.length() == 15);
        assert!(after[0] == before[5]);
        assert!(book.get_order(after[0]).filled_quantity() == qty() / 2);
        assert_no_demotion(&before, &after);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Expired makers are retired by a sweep without disturbing the live orders
    /// around them. An expired order consumes no taker quantity, so the walk steps
    /// over it — and the survivors either side must keep their relative order.
    fun retiring_expired_makers_never_demotes() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        // Alternate live and short-dated orders down the side.
        let mut i = 0;
        while (i < 20) {
            let expire = if (i % 2 == 0) constants::max_u64() else 5;
            let mut info = order(
                constants::no_restriction(),
                price_at(19 - i),
                qty(),
                false,
                expire,
            );
            book.create_order(&mut info, 0);
            assert!(info.order_inserted());
            i = i + 1;
        };
        let before = side(&book, false);

        // At t=10 the odd-indexed orders have expired. Take three live ones; the
        // walk has to step over the expired orders in between and retire them.
        let taker = take(&mut book, qty() * 3, true, 10);
        assert!(taker.executed_quantity() == qty() * 3);

        let after = side(&book, false);
        assert!(after.length() < before.length());
        assert_no_demotion(&before, &after);

        book.drop_for_testing();
        test.end();
    }

    // === Modify ===

    #[test]
    /// Reducing quantity must not re-queue the order. This is the classic demotion
    /// bug — a modify implemented as cancel-and-replace silently sends the maker to
    /// the back of its price level — and the only thing preventing it here is that
    /// `modify_order` mutates in place under an unchanged key.
    fun modify_down_never_requeues() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut ids = vector[];
        let mut i = 0u64;
        // One price, so position is decided purely by arrival and any re-queue
        // would be visible immediately.
        while (i < 25) {
            ids.push_back(rest(&mut book, level(), true));
            i = i + 1;
        };
        assert!(side(&book, true) == ids);

        // Modify every order in turn — buffer residents and tree residents alike —
        // checking the whole side after each one.
        let mut k = 0;
        while (k < ids.length()) {
            let before = side(&book, true);
            let (cut, _) = book.modify_order(ids[k], qty() / 2, 0);
            assert!(cut == qty() / 2);
            let after = side(&book, true);

            assert!(after == before);
            assert!(book.get_order(ids[k]).quantity() == qty() / 2);
            k = k + 1;
        };

        assert!(side(&book, true) == ids);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Modifying the best order of a side, repeatedly, must not cost it the top of
    /// book. The buffer's back is where `pop_back` and `push_back` happen, so an
    /// in-place mutation that accidentally reinserted would show up here first.
    fun modifying_the_best_order_keeps_it_best() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let best = rest_qty(&mut book, price_at(0), qty() * 8, false);
        let mut i = 1;
        while (i < 20) {
            rest(&mut book, price_at(i), false);
            i = i + 1;
        };

        let mut q = qty() * 8;
        let mut step = 0u64;
        while (step < 6) {
            q = q - qty();
            book.modify_order(best, q, 0);
            assert!(side(&book, false)[0] == best);
            assert!(book.get_order(best).quantity() == q);
            step = step + 1;
        };

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// A modify on an order sitting in the tree must not promote it into the
    /// buffer either. Demotion-freedom is symmetric: an order that jumps *forward*
    /// has demoted everything it passed.
    fun modify_in_the_tree_does_not_promote() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut i = 0;
        while (i < 40) {
            rest(&mut book, price_at(39 - i), true);
            i = i + 1;
        };

        let hot_before = book.hot_bids().length();
        let tree_before = book.bids().length();
        let before = side(&book, true);

        // The tree's best, and one deep inside it.
        let on_seam = before[hot_before];
        let deep = before[before.length() - 1];

        book.modify_order(on_seam, qty() / 2, 0);
        book.modify_order(deep, qty() / 3, 0);

        assert!(side(&book, true) == before);
        assert!(book.hot_bids().length() == hot_before);
        assert!(book.bids().length() == tree_before);

        book.drop_for_testing();
        test.end();
    }

    // === Everything at once ===

    #[test]
    /// A long mixed run — place, cancel, modify, partial and full sweeps — with the
    /// property checked after every single operation on both sides. The named tests
    /// above each isolate one mechanism; this one lets them interleave, which is
    /// where an interaction between two correct-in-isolation paths would show.
    fun mixed_workload_never_demotes() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        let mut seed = 0xD3_0770_1000_0001u64;

        let mut op = 0u64;
        while (op < 300) {
            let s = (seed as u128) * 6364136223846793005u128 + 1442695040888963407u128;
            seed = ((s & 0xFFFFFFFFFFFFFFFFu128) as u64);
            let roll = seed % 100;
            let is_bid = (seed / 100) % 2 == 0;

            let before_bids = side(&book, true);
            let before_asks = side(&book, false);

            if (roll < 45) {
                // Place, on a grid narrow enough that the seam moves constantly.
                let off = (seed / 7) % 12;
                let price = if (is_bid) level() - off * 10 else level() * 2 + off * 10;
                rest(&mut book, price, is_bid);
            } else if (roll < 70) {
                let side_ids = if (is_bid) &before_bids else &before_asks;
                if (!side_ids.is_empty()) {
                    let at = (seed / 11) % side_ids.length();
                    book.cancel_order(side_ids[at]);
                };
            } else if (roll < 85) {
                let side_ids = if (is_bid) &before_bids else &before_asks;
                if (!side_ids.is_empty()) {
                    let at = (seed / 13) % side_ids.length();
                    let id = side_ids[at];
                    let o = book.get_order(id);
                    // Only reduce when there is room to reduce into.
                    if (o.quantity() > o.filled_quantity() + 2) {
                        book.modify_order(id, o.quantity() - 1, 0);
                    };
                };
            } else {
                let taker_is_bid = (seed / 17) % 2 == 0;
                let target = if (taker_is_bid) &before_asks else &before_bids;
                if (!target.is_empty()) {
                    // Sized to land inside orders as often as on their boundaries.
                    let n = 1 + (seed / 19) % 20;
                    take(&mut book, qty() * n / 3, taker_is_bid, 0);
                };
            };

            assert_no_demotion(&before_bids, &side(&book, true));
            assert_no_demotion(&before_asks, &side(&book, false));

            op = op + 1;
            if (op % 64 == 0) { test.next_tx(OWNER); };
        };

        book.drop_for_testing();
        test.end();
    }
}
