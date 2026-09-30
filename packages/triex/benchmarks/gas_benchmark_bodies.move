/// Bodies of the gas benchmarks in `benchmarks/gas_benchmarks.move`.
///
/// Kept out of `tests/` so they stay out of the default test build, which is
/// close to the Move VM's per-package arena limit. `build_scripts/gas-benchmark.sh`
/// copies this directory into a scratch copy of the package before measuring.
#[test_only]
module triex::gas_benchmark_bodies {
    use std::unit_test::destroy;
    use sui::{
        clock::Clock,
        coin::mint_for_testing,
        sui::SUI,
        test_scenario::{begin, end, return_shared}
    };
    use token::cred::CRED;
    use triex::{
        constants,
        fee_policy::FeePolicy,
        pool::Pool,
        pool_test_utils,
        trading_account::TradingAccount,
        trading_account_tests::{USDC, create_acct_and_share_with_funds}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    // === Gas benchmarks ===
    //
    // These are not correctness tests. Each one performs a fixed amount of work so
    // that `build_scripts/gas-benchmark.sh` can binary-search the smallest
    // `--gas-limit` it survives, which is a deterministic measure of the Move VM
    // gas that work costs.
    //
    // Read them differentially: subtract a benchmark from the one that does
    // strictly more work, and what remains is the cost of the difference. Absolute
    // numbers here are Move VM gas, not Sui computation + storage fees, so they are
    // for comparing operations against each other and for detecting growth with
    // book depth — not for predicting a mainnet fee.
    //
    // Bids are placed at ascending prices, so each new order is the best bid and
    // lands at the end of the book vector. That keeps `vector::insert` at O(1) and
    // isolates the O(depth) rescan in `match_against_book`.

    /// Pool and two funded accounts, no orders. Subtract this from every other
    /// benchmark to remove fixture cost.
    public(package) fun bench_baseline() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        pool_test_utils::setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        end(test);
    }

    /// Rest `count` bids at ascending prices from one account.
    fun bench_place_bids(count: u64) {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        let quantity = 1 * constants::float_scaling();
        let mut i = 0;
        while (i < count) {
            pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                (i + 1) * constants::float_scaling(),
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            i = i + 1;
        };

        end(test);
    }

    /// Build a book `count` bids deep, spreading the orders over as many trading
    /// accounts as `MAX_OPEN_ORDERS` requires. The single-account `bench_place_bids`
    /// above tops out at 100, which is inside one or two `BigVector` slices —
    /// nowhere near the depth where a keyed book is supposed to beat a flat vector.
    /// This is how that regime gets measured at all.
    fun bench_place_bids_deep(count: u64) {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let first_account = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            first_account,
            &mut test,
        );

        let quantity = 1 * constants::float_scaling();
        // Stay clear of the per-account cap so the placement itself is what is
        // being timed, not an account rollover.
        let per_account = 75;
        let mut placed = 0;
        let mut account = first_account;
        let mut trader = ALICE;
        while (placed < count) {
            if (placed > 0 && placed % per_account == 0) {
                // Distinct sender per batch so each gets its own trading account.
                trader = sui::address::from_u256(0x10000 + ((placed / per_account) as u256));
                account =
                    create_acct_and_share_with_funds(
                        trader,
                        1000000 * constants::float_scaling(),
                        &mut test,
                    );
            };
            pool_test_utils::place_limit_order<SUI, USDC>(
                trader,
                pool_id,
                account,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                (placed + 1) * constants::float_scaling(),
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            placed = placed + 1;
        };

        end(test);
    }

    /// Build a book `depth` bids deep, then churn at the inside market: each cycle
    /// places a new best bid and cancels it again, both in one transaction.
    ///
    /// This is the shape real book activity has — quotes cluster at the top of book
    /// and are requoted constantly — where `bench_place_bids_deep` builds a
    /// monotonic price ladder that touches every part of the book once. The two
    /// storage designs have opposite strengths here, so the comparison only means
    /// something when measured on this pattern: a sorted vector appends and pops at
    /// its end in O(1), while a B+ tree pays a root-to-leaf descent per operation no
    /// matter where the key lands.
    fun bench_top_of_book_churn(depth: u64, cycles: u64) {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let churner = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            churner,
            &mut test,
        );

        let quantity = 1 * constants::float_scaling();
        // Resting depth goes on other accounts so the churning account keeps its full
        // MAX_OPEN_ORDERS headroom and the loop below never trips the cap.
        let per_account = 75;
        let mut placed = 0;
        let mut resting_account = churner;
        let mut resting_trader = ALICE;
        while (placed < depth) {
            if (placed % per_account == 0) {
                resting_trader =
                    sui::address::from_u256(0x20000 + ((placed / per_account) as u256));
                resting_account =
                    create_acct_and_share_with_funds(
                        resting_trader,
                        1000000 * constants::float_scaling(),
                        &mut test,
                    );
            };
            pool_test_utils::place_limit_order<SUI, USDC>(
                resting_trader,
                pool_id,
                resting_account,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                (placed + 1) * constants::float_scaling(),
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            placed = placed + 1;
        };

        // One price above every resting bid, so each placement is the new best bid:
        // the maximum key on its side, and the end of the vector in the old design.
        let top_price = (depth + 1) * constants::float_scaling();
        let mut cycle = 0;
        while (cycle < cycles) {
            test.next_tx(ALICE);
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut trading_account = test.take_shared_by_id<TradingAccount>(churner);
            let policy = test.take_shared<FeePolicy>();
            let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

            let order_info = pool.place_limit_order<SUI, USDC>(
                &policy,
                &mut trading_account,
                &trade_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                top_price,
                quantity,
                true,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );
            pool.cancel_order<SUI, USDC>(
                &mut trading_account,
                &trade_proof,
                order_info.order_id(),
                &clock,
                test.ctx(),
            );

            return_shared(policy);
            return_shared(trading_account);
            return_shared(clock);
            return_shared(pool);
            cycle = cycle + 1;
        };

        end(test);
    }

    /// Churn at the inside market of a book too shallow to have split a slice.
    public(package) fun bench_churn_at_depth_40() { bench_top_of_book_churn(40, 20) }

    /// The same churn against a book several slices deep. The resting depth is not
    /// touched by the loop — only the tree descent gets longer — so the delta
    /// between this and the shallow case isolates what depth costs the hot path.
    public(package) fun bench_churn_at_depth_300() { bench_top_of_book_churn(300, 20) }

    /// Cancel the *best*-priced of 80 resting bids: the end of the vector, and the
    /// maximum key of the tree. Contrast with `bench_cancel_at_depth_80`, which
    /// cancels the worst-priced one. The pair measures how much each design cares
    /// about *where* in the book an operation lands.
    public(package) fun bench_cancel_at_top_of_book_depth_80() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        let quantity = 1 * constants::float_scaling();
        let mut best_order_id = 0;
        let mut i = 0;
        while (i < 80) {
            let order_info = pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                (i + 1) * constants::float_scaling(),
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            // Ascending prices, so the last placed is the best bid.
            best_order_id = order_info.order_id();
            i = i + 1;
        };

        pool_test_utils::cancel_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            best_order_id,
            &mut test,
        );

        end(test);
    }

    /// Same churn at twice the cycle count. Differencing this against the 20-cycle
    /// variant at the same depth cancels the shared book-construction cost, leaving
    /// the marginal price of one inside-market place+cancel. That difference is the
    /// only number that actually answers whether the hot path degrades with depth.
    public(package) fun bench_churn_at_depth_40_x40() { bench_top_of_book_churn(40, 40) }

    public(package) fun bench_churn_at_depth_300_x40() { bench_top_of_book_churn(300, 40) }

    public(package) fun bench_depth_10() { bench_place_bids(10) }

    public(package) fun bench_depth_40() { bench_place_bids(40) }

    public(package) fun bench_depth_80() { bench_place_bids(80) }

    /// Past the 64-order slice size: several slices, so cross-slice work counts.
    public(package) fun bench_depth_300() { bench_place_bids_deep(300) }

    /// 80 resting bids, then cancel the *worst-priced* one — the order furthest
    /// from the top of the book. On the vector book this was the worst case: a
    /// full scan to find it, then a memmove of every element past it. On the
    /// keyed coin book it is an ordinary O(log n) remove, so this benchmark now
    /// measures the difference that made rather than a pathological case.
    public(package) fun bench_cancel_at_depth_80() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        let quantity = 1 * constants::float_scaling();
        let mut first_order_id = 0;
        let mut i = 0;
        while (i < 80) {
            let order_info = pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                (i + 1) * constants::float_scaling(),
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            if (i == 0) first_order_id = order_info.order_id();
            i = i + 1;
        };

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id_alice,
            );
            let trade_proof = trading_account.generate_proof_as_owner(test.ctx());
            pool.cancel_order(
                &mut trading_account,
                &trade_proof,
                first_order_id,
                &clock,
                test.ctx(),
            );
            return_shared(trading_account);
            return_shared(clock);
            return_shared(pool);
        };

        end(test);
    }

    /// `makers` resting bids at one price, then a single ask that sweeps all of
    /// them. Isolates the per-fill cost, including each maker's account touch.
    fun bench_taker_sweeps(makers: u64) {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        let trading_account_id_bob = create_acct_and_share_with_funds(
            BOB,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let mut i = 0;
        while (i < makers) {
            pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            i = i + 1;
        };

        pool_test_utils::place_limit_order<SUI, USDC>(
            BOB,
            pool_id,
            trading_account_id_bob,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity * makers,
            false,
            constants::max_u64(),
            &mut test,
        );

        end(test);
    }

    public(package) fun bench_taker_sweeps_01() { bench_taker_sweeps(1) }

    public(package) fun bench_taker_sweeps_10() { bench_taker_sweeps(10) }

    /// Rest 10 bids under a ladder of `tiers` rungs. Comparing the one-rung and
    /// eight-rung variants prices the tier resolution TRIEX-137 added: both set a
    /// schedule and roll an epoch, so everything except the ladder length cancels.
    fun bench_place_bids_under_ladder(tiers: u64) {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        // Thresholds far above anything these orders accrue, so every placement
        // walks the whole ladder without ever promoting — the worst case for
        // resolution, and identical work per order across both variants.
        let mut min_turnovers = vector[];
        let mut taker_fees = vector[];
        let mut maker_fees = vector[];
        let mut t = 0;
        while (t < tiers) {
            min_turnovers.push_back((t as u128) * 1_000_000_000_000_000);
            taker_fees.push_back(22_000_000 - (t * 100_000));
            maker_fees.push_back(18_000_000 - (t * 100_000));
            t = t + 1;
        };

        pool_test_utils::set_next_epoch_fee_schedule_for_testing<USDC>(
            min_turnovers,
            taker_fees,
            maker_fees,
            2000,
            &mut test,
        );
        test.next_epoch(OWNER);

        let quantity = 1 * constants::float_scaling();
        let mut i = 0;
        while (i < 10) {
            pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                (i + 1) * constants::float_scaling(),
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            i = i + 1;
        };

        end(test);
    }

    public(package) fun bench_ladder_1_tier() { bench_place_bids_under_ladder(1) }

    public(package) fun bench_ladder_8_tiers() { bench_place_bids_under_ladder(8) }

    /// Ten bids resting at one price. Baseline for the benchmarks below that then
    /// consume this book, so their differentials price the consuming call alone.
    public(package) fun bench_makers_10() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let mut i = 0u64;
        while (i < 10) {
            pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            i = i + 1;
        };

        end(test);
    }

    /// Same book as `bench_makers_10`, consumed by a market order instead of a
    /// crossing limit order. Differencing the two against that baseline prices the
    /// market-order path against the limit path.
    public(package) fun bench_market_sweeps_10() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        let trading_account_id_bob = create_acct_and_share_with_funds(
            BOB,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let mut i = 0u64;
        while (i < 10) {
            pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            i = i + 1;
        };

        test.next_tx(BOB);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id_bob,
            );
            let trade_proof = trading_account.generate_proof_as_owner(test.ctx());
            let policy = test.take_shared<FeePolicy>();
            pool.place_market_order(
                &policy,
                &mut trading_account,
                &trade_proof,
                constants::self_matching_allowed(),
                quantity * 10,
                false,
                &clock,
                test.ctx(),
            );
            return_shared(policy);
            return_shared(trading_account);
            return_shared(clock);
            return_shared(pool);
        };

        end(test);
    }

    /// Same book again, consumed by the trading_account-less swap. That path mints a
    /// temporary trading account, trades, withdraws and deletes it, so the
    /// differential is what anonymous flow pays for the convenience.
    public(package) fun bench_swap_base_for_quote_10() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let mut i = 0u64;
        while (i < 10) {
            pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            i = i + 1;
        };

        test.next_tx(BOB);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let policy = test.take_shared<FeePolicy>();
            let (base_out, quote_out, cred_out) = pool.swap_exact_base_for_quote<SUI, USDC>(
                &policy,
                mint_for_testing<SUI>(quantity * 10, test.ctx()),
                mint_for_testing<CRED>(0, test.ctx()),
                0,
                &clock,
                test.ctx(),
            );
            return_shared(policy);
            destroy(base_out);
            destroy(quote_out);
            destroy(cred_out);
            return_shared(clock);
            return_shared(pool);
        };

        end(test);
    }

    /// 80 resting bids, then modify the worst-priced one down. Like the cancel
    /// benchmark this hits the linear scan over both book sides, and it releases
    /// escrow on cancel terms — the path a modify-to-minimum would take.
    public(package) fun bench_modify_at_depth_80() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        // Same quantity as `bench_depth_80`, so subtracting that baseline leaves
        // only the modify.
        let quantity = 1 * constants::float_scaling();
        let mut first_order_id = 0;
        let mut i = 0;
        while (i < 80) {
            let order_info = pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                (i + 1) * constants::float_scaling(),
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            if (i == 0) first_order_id = order_info.order_id();
            i = i + 1;
        };

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id_alice,
            );
            let trade_proof = trading_account.generate_proof_as_owner(test.ctx());
            pool.modify_order(
                &mut trading_account,
                &trade_proof,
                first_order_id,
                quantity / 2,
                &clock,
                test.ctx(),
            );
            return_shared(trading_account);
            return_shared(clock);
            return_shared(pool);
        };

        end(test);
    }

    /// 80 resting bids, then cancel every one of them in a single call.
    /// `cancel_all_orders` loops the account's open orders and each iteration runs
    /// an O(depth) `cancel_order`, so this is the most expensive user-facing call
    /// the pool exposes.
    public(package) fun bench_cancel_all_at_depth_80() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

        let quantity = 1 * constants::float_scaling();
        let mut i = 0;
        while (i < 80) {
            pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                (i + 1) * constants::float_scaling(),
                quantity,
                true,
                constants::max_u64(),
                &mut test,
            );
            i = i + 1;
        };

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id_alice,
            );
            let trade_proof = trading_account.generate_proof_as_owner(test.ctx());
            pool.cancel_all_orders(&mut trading_account, &trade_proof, &clock, test.ctx());
            return_shared(trading_account);
            return_shared(clock);
            return_shared(pool);
        };

        end(test);
    }
}
