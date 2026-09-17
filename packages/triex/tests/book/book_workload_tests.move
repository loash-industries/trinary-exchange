/// The same measured mainnet workload, run against the **multicoin** book.
///
/// Companion to `coin_book_workload_tests`, which runs the identical distribution
/// against the coin pools' book. The two answered whether multicoin's flat
/// `vector<Order>` should adopt `BigVector` too, rather than settling it by
/// analogy; it has, and this module now measures the design that replaced it —
/// `BigVector` keyed by encoded `u128` ids behind a 16-order inline hot buffer
/// that spills one way.
///
/// The workload, book shape and draw sequence are copied verbatim from that module
/// so the two remain directly comparable. What differs now is only what the two
/// stacks still differ in — price scaling, and matching that returns `bool` here
/// against a three-state outcome there.
///
/// One caveat this harness cannot escape: the Move test meter prices computation
/// and not storage, and storage is the whole reason for the layout under test. The
/// storage figures live in `docs/plans/multicoin-book-storage-whitepaper.md`, which
/// measured them on a running node. What this module can still show is the
/// computation side: the flat vector's O(depth x fills) removal scan, which keyed
/// removal eliminates, and which was the largest single number in that experiment.
#[test_only]
module triex::book_workload_tests {
    use std::unit_test::destroy;
    use sui::test_scenario::begin;
    use triex::{book::{Self, Book}, constants, order_info};

    const OWNER: address = @0x1;
    const BASE_PRICE: u64 = 724_050;
    const TICK: u64 = 10;
    const QTY: u64 = 1_000_000_000;

    const DEEP_TAIL: u64 = 1_108;
    const DEEP_BAND: u64 = 28;
    const SHALLOW_TAIL: u64 = 12;
    const SHALLOW_BAND: u64 = 14;
    const OPS: u64 = 200;
    const FLUSH_EVERY: u64 = 64;

    fun next(seed: &mut u64): u64 {
        let s = (*seed as u128) * 6364136223846793005u128 + 1442695040888963407u128;
        *seed = ((s & 0xFFFFFFFFFFFFFFFFu128) as u64);
        *seed
    }

    fun roll(seed: &mut u64, n: u64): u64 {
        (next(seed) >> 11) % n
    }

    fun draw_placement_ticks(seed: &mut u64): u64 {
        let r = roll(seed, 1000);
        if (r < 20) 0
        else if (r < 21) 1
        else if (r < 22) 2
        else if (r < 26) 5
        else if (r < 37) 10
        else if (r < 94) 25
        else if (r < 215) 50
        else if (r < 391) 100
        else if (r < 612) 250
        else if (r < 855) 1_000
        else 8_000
    }

    fun draw_taker_reach(seed: &mut u64): u64 {
        let r = roll(seed, 10000);
        if (r < 5918) 1
        else if (r < 8850) 2
        else if (r < 9481) 3
        else if (r < 9685) 4
        else if (r < 9796) 5
        else if (r < 9870) 6
        else if (r < 9907) 7
        else if (r < 9944) 9
        else if (r < 9963) 10
        else if (r < 9981) 12
        else 14
    }

    /// `price_scaling` is 1 here, matching `book::empty_multicoin`: multicoin prices
    /// are already quote-unit denominated, so the conversion is a bare product.
    fun place(b: &mut Book, price: u64, quantity: u64, is_bid: bool, ts: u64): u128 {
        let mut info = order_info::new(
            object::id_from_address(@0xB00C),
            object::id_from_address(@0xACC7),
            OWNER,
            constants::no_restriction(),
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
            1,
        );
        b.create_order(&mut info, ts);

        info.order_id()
    }

    fun take(b: &mut Book, reach: u64, ts: u64) {
        let mut info = order_info::new(
            object::id_from_address(@0xB00C),
            object::id_from_address(@0xACC7),
            OWNER,
            constants::immediate_or_cancel(),
            constants::self_matching_allowed(),
            BASE_PRICE - 1_000 * TICK,
            reach * QTY,
            false,
            0,
            0,
            0,
            constants::max_u64(),
            false,
            ts,
            1,
        );
        b.create_order(&mut info, ts);
    }

    fun band_price(slot: u64): u64 {
        BASE_PRICE - (slot + 1) * TICK
    }

    fun seed(
        b: &mut Book,
        tail: u64,
        band_size: u64,
        test: &mut sui::test_scenario::Scenario,
    ): vector<u128> {
        // Seed the tail from the worst price upward, so the sorted-vector book
        // appends rather than memmoving the whole array on every insert. Setup order
        // is arbitrary in reality, and handing one engine its worst case would
        // measure the fixture instead of the workload.
        //
        // This choice matters more than it looks. Seeding in *descending* price, or
        // scattered across levels, makes every vector insert land mid-array: the
        // deep vector fixture then exceeds the test runner's wall clock entirely,
        // while every BigVector geometry still completes. It also inflates the
        // apparent gap between slice sizes, because in-leaf memmove is what slice
        // size actually bounds. Ascending is the fixture that flatters neither.
        let mut i = 0;
        while (i < tail) {
            let level = (tail - 1 - i) / 13;
            let price = BASE_PRICE - (70_000 + level * 20) * TICK;
            place(b, price, QTY, true, 1);
            i = i + 1;
            if (i % FLUSH_EVERY == 0) { test.next_tx(OWNER); };
        };

        let mut band = vector[];
        let mut j = 0;
        while (j < band_size) {
            band.push_back(place(b, band_price(j), QTY, true, 1));
            j = j + 1;
        };
        test.next_tx(OWNER);

        band
    }

    fun run(tail: u64, band_size: u64, ops: u64) {
        let mut test = begin(OWNER);
        let mut b = book::empty_multicoin(test.ctx());

        let mut band = seed(&mut b, tail, band_size, &mut test);
        assert!(b.side_length(true) == tail + band_size);

        let mut placed = vector[];
        let mut seed_state = 0x5EED_1234_5678_9ABC;
        let mut op = 0;
        while (op < ops) {
            if (op % 45 == 44) {
                let reach = draw_taker_reach(&mut seed_state);
                let reach = if (reach > band_size / 2) band_size / 2 else reach;
                take(&mut b, reach, 2);
                let mut k = 0;
                while (k < reach) {
                    *&mut band[k] = place(&mut b, band_price(k), QTY, true, 2);
                    k = k + 1;
                };
            } else {
                let ticks = draw_placement_ticks(&mut seed_state);
                let price = BASE_PRICE - (band_size + ticks + 1) * TICK;
                placed.push_back(place(&mut b, price, QTY, true, 2));
                if (placed.length() > band_size) {
                    let o = b.cancel_order(placed.remove(0));
                    destroy(o);
                };
            };
            op = op + 1;
            if (op % FLUSH_EVERY == 0) { test.next_tx(OWNER); };
        };

        destroy(b);
        test.end();
    }

    #[test]
    fun workload_deep() { run(DEEP_TAIL, DEEP_BAND, OPS) }

    #[test]
    fun workload_shallow() { run(SHALLOW_TAIL, SHALLOW_BAND, OPS) }

    // === Crossover sweep (mirror of the coin book's sweep) ===
    const SWEEP_BAND: u64 = 14;
    const SWEEP_LO: u64 = 100;
    const SWEEP_HI: u64 = 200;

    #[test]
    fun sweep_mc_40_lo() { run(12, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_40_hi() { run(12, SWEEP_BAND, SWEEP_HI) }

    #[test]
    fun sweep_mc_100_lo() { run(72, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_100_hi() { run(72, SWEEP_BAND, SWEEP_HI) }

    #[test]
    fun sweep_mc_200_lo() { run(172, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_200_hi() { run(172, SWEEP_BAND, SWEEP_HI) }

    #[test]
    fun sweep_mc_300_lo() { run(272, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_300_hi() { run(272, SWEEP_BAND, SWEEP_HI) }

    #[test]
    fun sweep_mc_500_lo() { run(472, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_500_hi() { run(472, SWEEP_BAND, SWEEP_HI) }

    #[test]
    fun sweep_mc_800_lo() { run(772, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_800_hi() { run(772, SWEEP_BAND, SWEEP_HI) }

    #[test]
    fun sweep_mc_1150_lo() { run(1122, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_1150_hi() { run(1122, SWEEP_BAND, SWEEP_HI) }

    #[test]
    fun sweep_mc_110_lo() { run(82, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_110_hi() { run(82, SWEEP_BAND, SWEEP_HI) }

    #[test]
    fun sweep_mc_120_lo() { run(92, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_120_hi() { run(92, SWEEP_BAND, SWEEP_HI) }

    #[test]
    fun sweep_mc_130_lo() { run(102, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_130_hi() { run(102, SWEEP_BAND, SWEEP_HI) }

    #[test]
    fun sweep_mc_150_lo() { run(122, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_150_hi() { run(122, SWEEP_BAND, SWEEP_HI) }

    #[test]
    fun sweep_mc_175_lo() { run(147, SWEEP_BAND, SWEEP_LO) }

    #[test]
    fun sweep_mc_175_hi() { run(147, SWEEP_BAND, SWEEP_HI) }
}
