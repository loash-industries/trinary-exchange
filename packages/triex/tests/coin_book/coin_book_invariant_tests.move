/// Randomised property tests for the coin book's buffer/tree invariant, and
/// depth tests that push the tree past one leaf slice.
///
/// The design rests on one invariant — *every order in a side's buffer is
/// better-priced than every order in that side's tree* — and under one-way spill
/// nothing repairs it once broken, because there is no refill path to shuffle
/// orders back into place. It is maintained by exactly three pieces of code: the
/// admission test in `inject_limit_order`, `spill`, and the branch that admits
/// over a populated tree. `book_hot_buffer_tests` reaches each of them with a
/// named case; this module attacks the same three from the other direction, with
/// a workload nobody chose, and re-checks the invariant after every operation.
///
/// The generator is a plain LCG seeded per test, so a failure is reproducible
/// from its seed alone. Prices are drawn from a band wide enough that placements
/// land inside, at, and behind the seam, and the operation mix keeps both sides
/// alive while the buffer repeatedly overflows and drains.
///
/// Depth matters here too: `MAX_SLICE_SIZE` is 16 and `MAX_FAN_OUT` is 64, so a
/// tree holding more than 16 orders spans several leaves and the cursor has to hop
/// between them via `next_slice` / `prev_slice`. The `deep_` tests sit well above
/// that, and `tree_gains_a_level` pushes past 1,024 to make the tree taller than
/// one level rather than merely wider.
#[test_only]
module triex::coin_book_invariant_tests {
    use sui::test_scenario::begin;
    use triex::{
        big_vector::slice_borrow,
        coin_book::{Self, Book},
        coin_order_info::{Self, OrderInfo},
        constants
    };

    const OWNER: address = @0x1;
    const HOT_CAPACITY: u64 = 32;
    const HOT_SPILL_TARGET: u64 = 24;

    fun scaling(): u64 { constants::float_scaling() }

    fun qty(): u64 { 1 * scaling() }

    /// Mid of the price band the workload quotes around. Coin pools price through
    /// `FLOAT_SCALING`, so the band is scaled to keep quotes clear of zero.
    fun mid(): u64 { 100 * scaling() }

    fun tick(): u64 { scaling() / 100 }

    fun next(seed: &mut u64): u64 {
        let s = (*seed as u128) * 6364136223846793005u128 + 1442695040888963407u128;
        *seed = ((s & 0xFFFFFFFFFFFFFFFFu128) as u64);
        *seed
    }

    fun draw(seed: &mut u64, n: u64): u64 { next(seed) % n }

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

    /// Rest an order that must not cross. Returns `none` if it would have.
    fun try_rest(book: &mut Book, price: u64, is_bid: bool): Option<u128> {
        let mut info = order(constants::no_restriction(), price, qty(), is_bid);
        book.create_order(&mut info, 0);
        if (info.order_inserted()) option::some(info.order_id()) else option::none()
    }

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

    /// The whole contract of the split, asserted from both stores at once:
    /// the buffer is bounded and internally ordered, it sits entirely in front of
    /// the tree, the tree is internally ordered, and the side reads back as the
    /// concatenation of the two with nothing lost or duplicated.
    fun assert_side(book: &Book, is_bid: bool) {
        let hot = if (is_bid) book.hot_bids() else book.hot_asks();
        assert!(hot.length() <= HOT_CAPACITY);

        let mut i = 1;
        while (i < hot.length()) {
            assert!(better(is_bid, hot[i].order_id(), hot[i - 1].order_id()));
            i = i + 1;
        };

        let tree = read_tree(book, is_bid);
        let mut j = 1;
        while (j < tree.length()) {
            assert!(better(is_bid, tree[j - 1], tree[j]));
            j = j + 1;
        };

        // The seam itself.
        if (hot.length() > 0 && tree.length() > 0) {
            assert!(better(is_bid, hot[0].order_id(), tree[0]));
        };

        assert!(book.side_length(is_bid) == hot.length() + tree.length());

        // And the view every caller actually sees: one strictly ordered sequence
        // of exactly the right length.
        let mut seen = 0;
        let mut prev = option::none<u128>();
        let mut cur = book.cursor_begin(is_bid);
        while (!cur.cursor_is_null()) {
            let id = book.cursor_borrow(is_bid, &cur).order_id();
            if (prev.is_some()) {
                assert!(better(is_bid, *prev.borrow(), id));
            };
            prev = option::some(id);
            seen = seen + 1;
            cur = book.cursor_next(is_bid, cur);
        };
        assert!(seen == hot.length() + tree.length());
    }

    /// One randomised place / cancel / sweep workload, invariant checked after
    /// every operation on both sides.
    fun churn(seed_init: u64, ops: u64, band: u64) {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());
        let mut seed = seed_init;

        let mut live_bids = vector[];
        let mut live_asks = vector[];

        // Seed both sides past the buffer before the random workload starts.
        // Without this the churn's mix of placements and cancels never drives the
        // buffer over `HOT_CAPACITY`, so the spill path is never taken and the
        // invariant is checked against an inline vector — the test passes while
        // exercising none of the machinery it is named for. Asserted below.
        let mut seed_i = 0;
        while (seed_i < HOT_CAPACITY + 8) {
            live_bids.push_back(try_rest(
                &mut book,
                mid() - (HOT_CAPACITY + 8 - seed_i) * tick(),
                true,
            ).destroy_some());
            live_asks.push_back(try_rest(
                &mut book,
                mid() + (HOT_CAPACITY + 8 - seed_i) * tick(),
                false,
            ).destroy_some());
            seed_i = seed_i + 1;
        };
        assert!(!book.bids().is_empty());
        assert!(!book.asks().is_empty());
        assert!(book.hot_bids().length() > 0);
        assert!(book.hot_asks().length() > 0);
        let mut straddled = false;

        let mut op = 0;
        while (op < ops) {
            let roll = draw(&mut seed, 100);
            let is_bid = draw(&mut seed, 2) == 0;

            if (roll < 60) {
                // Place. Bids quote at or below mid, asks at or above, so the two
                // sides only cross when the band is deliberately narrow.
                let off = draw(&mut seed, band) * tick();
                let price = if (is_bid) mid() - off else mid() + tick() + off;
                let id = try_rest(&mut book, price, is_bid);
                if (id.is_some()) {
                    let id = id.destroy_some();
                    if (is_bid) live_bids.push_back(id) else live_asks.push_back(id);
                };
            } else if (roll < 85) {
                // Cancel a live order at random, which hits the buffer, the tree
                // and the seam in proportion to how full each is.
                let live = if (is_bid) &mut live_bids else &mut live_asks;
                if (!live.is_empty()) {
                    let at = draw(&mut seed, live.length());
                    let id = live.remove(at);
                    book.cancel_order(id);
                };
            } else {
                // Sweep. Sized to straddle the buffer boundary so some sweeps end
                // inside it and some run off into the tree.
                let n = 1 + draw(&mut seed, HOT_CAPACITY + 8);
                let taker_is_bid = draw(&mut seed, 2) == 0;
                let target = if (taker_is_bid) &mut live_asks else &mut live_bids;
                if (!target.is_empty()) {
                    let price = if (taker_is_bid) constants::max_price()
                    else constants::min_price();
                    let mut info = order(
                        constants::immediate_or_cancel(),
                        price,
                        qty() * n,
                        taker_is_bid,
                    );
                    book.create_order(&mut info, 0);
                    // Whatever the sweep retired is no longer live; rebuild the
                    // side's list from what the book still reports.
                    let mut still = vector[];
                    target.do_ref!(|id| {
                        if (book.side_length(!taker_is_bid) > 0 && contains(&book, *id)) {
                            still.push_back(*id);
                        };
                    });
                    *target = still;
                };
            };

            assert_side(&book, true);
            assert_side(&book, false);
            if (
                (book.hot_bids().length() > 0 && !book.bids().is_empty()) ||
                (book.hot_asks().length() > 0 && !book.asks().is_empty())
            ) {
                straddled = true;
            };
            op = op + 1;
        };

        // At some point in the run a side held orders in *both* stores, so the
        // invariant checked after every operation had a seam to be about. A run
        // that never straddles is testing an inline vector.
        assert!(straddled);

        book.drop_for_testing();
        test.end();
    }

    /// Is `id` still resting? Walks the side it belongs to rather than calling
    /// `get_order`, which aborts on an absent key.
    fun contains(book: &Book, id: u128): bool {
        let is_bid = id < (1u128 << 127);
        let mut cur = book.cursor_begin(is_bid);
        while (!cur.cursor_is_null()) {
            if (book.cursor_borrow(is_bid, &cur).order_id() == id) return true;
            cur = book.cursor_next(is_bid, cur);
        };

        false
    }

    #[test]
    /// A wide band: most placements land behind the buffer, so the tree grows and
    /// the seam moves slowly.
    fun churn_wide_band() { churn(0x5EED_0001_0000_0001, 400, 64) }

    #[test]
    /// A narrow band: nearly every placement is competitive, so the buffer
    /// overflows constantly and the spill path runs on most operations.
    fun churn_narrow_band() { churn(0x5EED_0002_0000_0002, 400, 6) }

    #[test]
    /// A second seed over the narrow band, because the spill path is the one with
    /// the least slack and the operation mix is what decides how often it runs.
    fun churn_narrow_band_alt_seed() { churn(0xC0FFEE_1234_5678, 400, 6) }

    #[test]
    /// A band of one: every order on a side shares a price, so ordering is decided
    /// entirely by the sequence half of the key and the seam lands mid-level.
    fun churn_single_price_level() { churn(0x5EED_0003_0000_0003, 300, 1) }

    // === Depth ===

    #[test]
    /// A side deep enough to span many leaf slices, built best-price-last so the
    /// buffer ends up holding the top of the book — the shape a contested book
    /// settles into (whitepaper §B.2).
    fun deep_side_best_price_last() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 0;
        while (i < 300) {
            try_rest(&mut book, mid() + (300 - i) * tick(), false).destroy_some();
            i = i + 1;
        };

        assert_side(&book, false);
        assert!(book.side_length(false) == 300);
        // Every placement was competitive, so the buffer stayed in its working
        // band — between the spill target it drops to and the capacity it
        // overflows at — rather than being pinned at either end.
        let hot = book.hot_asks().length();
        assert!(hot >= HOT_SPILL_TARGET && hot <= HOT_CAPACITY, hot);
        assert!(book.asks().length() == 300 - hot);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The same depth built the other way, which leaves the buffer holding one
    /// order and the whole side served from the tree.
    fun deep_side_worst_price_last() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let mut i = 0;
        while (i < 300) {
            try_rest(&mut book, mid() + (i + 1) * tick(), false).destroy_some();
            i = i + 1;
        };

        assert_side(&book, false);
        assert!(book.side_length(false) == 300);
        assert!(book.hot_asks().length() == 1);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// Past `MAX_SLICE_SIZE * MAX_FAN_OUT` (1,024), where the tree gains a level
    /// and interior-node traversal starts mattering. This is also the depth the
    /// flat vector this book replaced could not have reached much beyond.
    fun tree_gains_a_level() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        // Flush the transaction periodically: a thousand `OrderPlaced` events
        // held in one transaction exhaust the Move test harness's memory limit
        // long before the book does anything interesting.
        let mut i = 0;
        while (i < 1_100) {
            try_rest(&mut book, mid() + (i + 1) * tick(), false).destroy_some();
            i = i + 1;
            if (i % 64 == 0) { test.next_tx(OWNER); };
        };

        let (_, _, ask_depth, ask_len) = book.shape();
        assert!(ask_len == 1_100);
        assert!(ask_depth > 1, ask_depth as u64);
        assert_side(&book, false);

        book.drop_for_testing();
        test.end();
    }
}
