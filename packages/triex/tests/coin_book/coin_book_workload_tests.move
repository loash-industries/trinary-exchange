/// Slice-size benchmark against the *measured* DeepBook v3 mainnet workload.
///
/// Every distribution below was taken from live mainnet on 2026-09-14: 25,000
/// `OrderInfo` events (order creations) over a 19-minute window, plus the complete
/// SUI/USDC book reconstructed from its `BigVector` slices. Nothing here is guessed.
///
///   role split          97.4% rest as makers, 2.2% execute, 0.5% killed
///   taker reach         59.2% consume 1 maker, 88.5% <= 2, 98.0% <= 5, max 14
///   maker placement     by depth rank: 9.4% within ~1 resting order of the touch,
///                       39.1% within ~8, 85.5% within ~28
///   book shape          1,136 bids: a thin live surface (~28 orders inside 1,000
///                       ticks) over a deep parked tail at 70,000+ ticks out
///   leaf occupancy      35.5 orders per 64-slot slice (55%)
///
/// The benchmark drives `coin_book` directly rather than going through `pool`.
/// Two reasons: an earlier measurement showed book work is only ~7% of a full order
/// round trip, so pool/state/vault overhead drowns the signal; and the book layer
/// has no `MAX_OPEN_ORDERS` cap, so the real 1,136-order shape can be seeded at all.
///
/// Each `#[test]` runs an identical workload and differs only in `BigVector`
/// geometry, so `sui move test coin_book_workload --statistics` reads off as a
/// direct slice-size comparison. Capacity before the tree gains a level is
/// `slice x fan_out`: 4,096 at 64, 2,048 at 32, 1,024 at 16, 512 at 8 — so at the
/// real book size of ~1,136 the 16 and 8 cases are expected to sit one level
/// deeper, which is exactly the trade being measured.
#[test_only]
module triex::coin_book_workload_tests {
    use sui::test_scenario::begin;
    use triex::{coin_book::{Self, Book}, coin_order_info, constants};

    const OWNER: address = @0x1;

    /// Live SUI/USDC mid at the time of capture, and its configured tick.
    const BASE_PRICE: u64 = 724_050;
    const TICK: u64 = 10;
    /// One unit of base. Far above the zero-quote floor at every price used here.
    const QTY: u64 = 1_000_000_000;

    /// Measured deep book: 1,136 resting bids, ~28 of them inside 1,000 ticks.
    /// This is SUI/USDC, the deepest pool on mainnet and an outlier — 1 of 87.
    const DEEP_TAIL: u64 = 1_108;
    const DEEP_BAND: u64 = 28;

    /// The *typical* pool. 82.8% of the 87 live mainnet pools rest fewer than 50
    /// orders and the median holds 6, so this regime is the common case by pool
    /// count even though the deep pools carry most of the order flow. Steady state
    /// here is tail + band + in-flight placements = 12 + 14 + 14 = 40.
    const SHALLOW_TAIL: u64 = 12;
    const SHALLOW_BAND: u64 = 14;
    /// Operations per run. Each is one placement plus, in steady state, one cancel,
    /// with a taker every ~45th op — the measured 97.4 / 2.2 ratio.
    const OPS: u64 = 200;

    /// `create_order` emits a placement event per order, and the per-transaction
    /// event buffer will not hold a whole book's worth. Flushing on a fixed cadence
    /// keeps the runs comparable: every geometry pays the identical boundary cost.
    const FLUSH_EVERY: u64 = 64;

    // === Deterministic draws ===
    // Move has no RNG and a benchmark must be reproducible, so draws come from an
    // LCG. u64 multiply would abort on overflow; widen and mask instead.
    fun next(seed: &mut u64): u64 {
        let s = (*seed as u128) * 6364136223846793005u128 + 1442695040888963407u128;
        *seed = ((s & 0xFFFFFFFFFFFFFFFFu128) as u64);
        *seed
    }

    fun roll(seed: &mut u64, n: u64): u64 {
        (next(seed) >> 11) % n
    }

    /// Maker placement depth, in ticks from the touch, drawn from the measured CDF.
    /// Percentages are cumulative shares of the 13,497 placements observed.
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

    /// Makers a taker consumes, drawn from the measured CDF over 539 taker orders.
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

    fun place(book: &mut Book, price: u64, quantity: u64, is_bid: bool, ts: u64, ps: u64): u128 {
        let mut info = coin_order_info::new(
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
            ps,
        );
        book.create_order(&mut info, ts);

        info.order_id()
    }

    /// An ask priced through the live surface, sized to consume exactly `reach`
    /// makers. IOC so any unmatched remainder never rests.
    fun take(book: &mut Book, reach: u64, ts: u64, ps: u64) {
        let mut info = coin_order_info::new(
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
            ps,
        );
        book.create_order(&mut info, ts);
    }

    /// Seed the measured book shape: a deep parked tail, then a band of
    /// best-priced orders for takers to consume.
    ///
    /// The taker band sits at one order per distinct price, so "the taker ate the
    /// best `reach` orders" identifies exactly which ids left the book — there is no
    /// ambiguity from two live orders sharing a price. Workload placements all land
    /// *below* the band, so they are never what a taker consumes and a cancel can
    /// never target an already-filled id.
    fun seed(
        book: &mut Book,
        tail: u64,
        band_size: u64,
        ps: u64,
        test: &mut sui::test_scenario::Scenario,
    ): vector<u128> {
        // Parked tail: 70,000+ ticks below the touch, spread over ~84 price levels
        // at ~13 orders per level, matching the observed bid ladder.
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
            place(book, price, QTY, true, 1, ps);
            i = i + 1;
            if (i % FLUSH_EVERY == 0) { test.next_tx(OWNER); };
        };

        // Taker band: slot j holds the single order at price BASE - (j+1) * TICK.
        let mut band = vector[];
        let mut j = 0;
        while (j < band_size) {
            band.push_back(place(book, band_price(j), QTY, true, 1, ps));
            j = j + 1;
        };
        test.next_tx(OWNER);

        band
    }

    fun band_price(slot: u64): u64 {
        BASE_PRICE - (slot + 1) * TICK
    }

    /// Identical workload at every geometry: seed the measured book, then churn at
    /// the measured mix of placements, cancels and takers.
    fun run(
        max_slice_size: u64,
        max_fan_out: u64,
        tail: u64,
        band_size: u64,
        ops: u64,
        expected_end_depth: u8, // 255 = do not check
    ) {
        run_scaled(
            max_slice_size,
            max_fan_out,
            tail,
            band_size,
            ops,
            expected_end_depth,
            constants::float_scaling(),
        )
    }

    fun run_scaled(
        max_slice_size: u64,
        max_fan_out: u64,
        tail: u64,
        band_size: u64,
        ops: u64,
        expected_end_depth: u8,
        price_scaling: u64,
    ) {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty_with_geometry_scaled(
            max_slice_size,
            max_fan_out,
            price_scaling,
            test.ctx(),
        );

        let mut band = seed(&mut book, tail, band_size, price_scaling, &mut test);
        let (_, bid_len, _, _) = book.shape();
        assert!(bid_len == tail + band_size);

        let mut placed = vector[];
        let mut seed_state = 0x5EED_1234_5678_9ABC;
        let mut op = 0;
        while (op < ops) {
            // 2.2% of creations execute rather than rest.
            if (op % 45 == 44) {
                let reach = draw_taker_reach(&mut seed_state);
                // Never reach past the band into the tail: no taker in the 25,000
                // observed creations hit the fill limit.
                let reach = if (reach > band_size / 2) band_size / 2 else reach;
                take(&mut book, reach, 2, price_scaling);
                // The band's best `reach` slots were consumed; refill them so the
                // top of book is restored, as a real quoter would.
                let mut k = 0;
                while (k < reach) {
                    *&mut band[k] = place(&mut book, band_price(k), QTY, true, 2, price_scaling);
                    k = k + 1;
                };
            } else {
                let ticks = draw_placement_ticks(&mut seed_state);
                let price = BASE_PRICE - (band_size + ticks + 1) * TICK;
                placed.push_back(place(&mut book, price, QTY, true, 2, price_scaling));
                // Steady state: the book held ~1,500 orders across 470M lifetime
                // placements, so a placement is matched by a cancel.
                if (placed.length() > band_size) {
                    book.cancel_order(placed.remove(0));
                };
            };
            op = op + 1;
            if (op % FLUSH_EVERY == 0) { test.next_tx(OWNER); };
        };

        // Pin the regime each geometry actually lands in, because it is not the
        // nominal `slice * fan_out` capacity. B+ tree leaves sit around half full
        // (35.5 of 64 on the live book), so depth-1 capacity is only ~55% of
        // nominal: ~2,250 at slice 64 but only ~1,126 at slice 32. At this book
        // size that puts 64 at depth 1 and every smaller geometry at depth 2 —
        // so the measurement below is "one extra tree level" versus "4x the
        // in-leaf vector work", not a like-for-like depth comparison.
        let (d_end, _, _, _) = book.shape();
        if (expected_end_depth != 255) { assert!(d_end == expected_end_depth); };

        book.drop_for_testing();
        test.end();
    }

    // === Deep regime: the SUI/USDC book (1,164 steady state) ===
    // Leaves sit ~55% full, so depth-1 capacity is ~55% of nominal `slice * fan_out`:
    // ~2,250 at slice 64 but only ~1,126 at slice 32. Hence 64 alone stays at
    // depth 1 here and every smaller geometry pays an extra level.

    #[test]
    fun workload_deep_slice_64() { run(64, 64, DEEP_TAIL, DEEP_BAND, OPS, 1) }

    #[test]
    fun workload_deep_slice_32() { run(32, 64, DEEP_TAIL, DEEP_BAND, OPS, 2) }

    #[test]
    fun workload_deep_slice_16() { run(16, 64, DEEP_TAIL, DEEP_BAND, OPS, 2) }

    #[test]
    fun workload_deep_slice_8() { run(8, 64, DEEP_TAIL, DEEP_BAND, OPS, 2) }

    // === Shallow regime: the typical pool (40 steady state, under 50) ===
    // A 40-order book fits one 64-slot leaf, so slice 64 has no interior node at
    // all — no descent, just a direct leaf borrow. Every smaller geometry has to
    // build a tree to hold the same 40 orders. Below ~8 orders (the median pool
    // holds 6) all four collapse to a single partly-filled leaf and geometry
    // stops mattering entirely.

    #[test]
    fun workload_shallow_slice_64() { run(64, 64, SHALLOW_TAIL, SHALLOW_BAND, OPS, 0) }

    // Depth 0 rather than 1: the inline top-of-book buffer holds the best 16 orders
    // of the side, so a ~26-order book leaves only ~10-16 in the tree — one leaf at
    // slice 32, where all 26 needed two.
    #[test]
    fun workload_shallow_slice_32() { run(32, 64, SHALLOW_TAIL, SHALLOW_BAND, OPS, 0) }

    #[test]
    fun workload_shallow_slice_16() { run(16, 64, SHALLOW_TAIL, SHALLOW_BAND, OPS, 1) }

    #[test]
    fun workload_shallow_slice_8() { run(8, 64, SHALLOW_TAIL, SHALLOW_BAND, OPS, 1) }

    // === Crossover sweep ===
    // Same workload at a fixed band, varying only total book size. Each size is
    // run at two op counts; differencing them cancels the book-construction cost
    // and leaves the marginal price of one steady-state operation. Slice stays at
    // the production 64.
    const SWEEP_BAND: u64 = 14;
    const SWEEP_LO: u64 = 100;
    const SWEEP_HI: u64 = 200;

    #[test]
    fun sweep_bv_40_lo() { run(64, 64, 12, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_40_hi() { run(64, 64, 12, SWEEP_BAND, SWEEP_HI, 255) }

    #[test]
    fun sweep_bv_100_lo() { run(64, 64, 72, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_100_hi() { run(64, 64, 72, SWEEP_BAND, SWEEP_HI, 255) }

    #[test]
    fun sweep_bv_200_lo() { run(64, 64, 172, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_200_hi() { run(64, 64, 172, SWEEP_BAND, SWEEP_HI, 255) }

    #[test]
    fun sweep_bv_300_lo() { run(64, 64, 272, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_300_hi() { run(64, 64, 272, SWEEP_BAND, SWEEP_HI, 255) }

    #[test]
    fun sweep_bv_500_lo() { run(64, 64, 472, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_500_hi() { run(64, 64, 472, SWEEP_BAND, SWEEP_HI, 255) }

    #[test]
    fun sweep_bv_800_lo() { run(64, 64, 772, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_800_hi() { run(64, 64, 772, SWEEP_BAND, SWEEP_HI, 255) }

    #[test]
    fun sweep_bv_1150_lo() { run(64, 64, 1122, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_1150_hi() { run(64, 64, 1122, SWEEP_BAND, SWEEP_HI, 255) }

    #[test]
    fun sweep_bv_110_lo() { run(64, 64, 82, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_110_hi() { run(64, 64, 82, SWEEP_BAND, SWEEP_HI, 255) }

    #[test]
    fun sweep_bv_120_lo() { run(64, 64, 92, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_120_hi() { run(64, 64, 92, SWEEP_BAND, SWEEP_HI, 255) }

    #[test]
    fun sweep_bv_130_lo() { run(64, 64, 102, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_130_hi() { run(64, 64, 102, SWEEP_BAND, SWEEP_HI, 255) }

    #[test]
    fun sweep_bv_150_lo() { run(64, 64, 122, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_150_hi() { run(64, 64, 122, SWEEP_BAND, SWEEP_HI, 255) }

    #[test]
    fun sweep_bv_175_lo() { run(64, 64, 147, SWEEP_BAND, SWEEP_LO, 255) }

    #[test]
    fun sweep_bv_175_hi() { run(64, 64, 147, SWEEP_BAND, SWEEP_HI, 255) }

    // === Ablation: BigVector with multicoin's price_scaling, isolating storage ===
    #[test]
    fun ablate_bv_ps1_40_lo() { run_scaled(64, 64, 12, SWEEP_BAND, SWEEP_LO, 255, 1) }

    #[test]
    fun ablate_bv_ps1_40_hi() { run_scaled(64, 64, 12, SWEEP_BAND, SWEEP_HI, 255, 1) }

    #[test]
    fun ablate_bv_ps1_100_lo() { run_scaled(64, 64, 72, SWEEP_BAND, SWEEP_LO, 255, 1) }

    #[test]
    fun ablate_bv_ps1_100_hi() { run_scaled(64, 64, 72, SWEEP_BAND, SWEEP_HI, 255, 1) }

    #[test]
    fun ablate_bv_ps1_110_lo() { run_scaled(64, 64, 82, SWEEP_BAND, SWEEP_LO, 255, 1) }

    #[test]
    fun ablate_bv_ps1_110_hi() { run_scaled(64, 64, 82, SWEEP_BAND, SWEEP_HI, 255, 1) }

    #[test]
    fun ablate_bv_ps1_200_lo() { run_scaled(64, 64, 172, SWEEP_BAND, SWEEP_LO, 255, 1) }

    #[test]
    fun ablate_bv_ps1_200_hi() { run_scaled(64, 64, 172, SWEEP_BAND, SWEEP_HI, 255, 1) }
}
