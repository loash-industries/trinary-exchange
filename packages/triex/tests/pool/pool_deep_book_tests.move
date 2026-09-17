/// Pool-layer behaviour on a book deeper than the inline buffer.
///
/// Every other module under `tests/pool/` works on a handful of orders, so the
/// whole side lives inline and the `BigVector` behind it is never touched. That is
/// fine for what those suites test — fee arithmetic, escrow, settlement — but it
/// means the layer where money moves has no coverage of the buffer/tree seam at
/// all. A probe confirms it: instrumenting `coin_book::spill` to abort makes no
/// `tests/pool/` test fail, at any buffer capacity.
///
/// This module closes that gap, and it does so by asserting one property rather
/// than re-deriving fee arithmetic that `pool_fee_tests` already pins:
///
///   **store invariance** — the economic outcome of an operation must not depend on
///   whether the order sat in the inline buffer or in the tree.
///
/// Escrow released on cancel, escrow released on modify-down, and settlement across
/// a sweep are all things a trader can observe and none of them may vary with an
/// implementation detail of where the order was stored. Each test therefore runs
/// the same operation twice at the same price and quantity — once against a
/// buffer resident, once against a tree resident — and requires the two to agree.
///
/// Books here are built at one price on purpose. Equal price means a later arrival
/// is strictly worse, so it never displaces the buffer's resident: the first order
/// stays inline and every one after it goes to the tree. That gives a buffer
/// resident and a tree resident that are identical in every respect a fee
/// calculation can see, which is exactly what store invariance needs.
#[test_only]
module triex::pool_deep_book_tests {
    use sui::{coin::mint_for_testing, sui::SUI, test_scenario::{begin, return_shared, Scenario}};
    use token::cred::CRED;
    use triex::{
        constants,
        pool::Pool,
        pool_test_utils,
        trading_account::TradingAccount,
        trading_account_tests::{create_acct_and_share_with_funds, USDC}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    /// Comfortably past `coin_book`'s `HOT_CAPACITY`, and inside `MAX_OPEN_ORDERS`
    /// (100) so one account can hold the whole side.
    const DEEP: u64 = 80;

    fun quantity(): u64 { 1 * constants::float_scaling() }

    fun price(): u64 { 2 * constants::float_scaling() }

    fun setup(test: &mut Scenario): (ID, ID) {
        let registry_id = pool_test_utils::setup_test(OWNER, test);
        let trading_account_id = create_acct_and_share_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(ALICE, registry_id, trading_account_id, test);

        (pool_id, trading_account_id)
    }

    /// `DEEP` bids at one price, in placement order. The first is the buffer's only
    /// resident; every later one is strictly worse in key order and lands behind it.
    fun build_one_level(pool_id: ID, trading_account_id: ID, test: &mut Scenario): vector<u128> {
        let mut ids = vector[];
        let mut i = 0;
        while (i < DEEP) {
            ids.push_back(pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price(),
                quantity(),
                true,
                constants::max_u64(),
                test,
            ).order_id());
            i = i + 1;
        };

        ids
    }

    /// `DEEP` bids on ascending price levels, best price last, so every placement
    /// beats the buffer's worst and is admitted inline — which drives the buffer to
    /// capacity and makes it spill repeatedly. The one-price build above never
    /// spills (an equal price is strictly worse, so nothing displaces the resident),
    /// so without this the pool layer would still have no coverage of the spill path.
    fun build_ladder(pool_id: ID, trading_account_id: ID, test: &mut Scenario): vector<u128> {
        let mut ids = vector[];
        let mut i = 0u64;
        while (i < DEEP) {
            ids.push_back(pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                (i + 1) * constants::float_scaling(),
                quantity(),
                true,
                constants::max_u64(),
                test,
            ).order_id());
            i = i + 1;
        };

        ids
    }

    /// The book really is split across both stores. Without this the tests below
    /// would pass on a book that never left the buffer, which is the failure mode
    /// this whole module exists to rule out.
    fun assert_straddles_seam(pool_id: ID, test: &mut Scenario) {
        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let inner = pool.load_inner();
        assert!(inner.book().hot_bids().length() > 0);
        assert!(!inner.bids().is_empty());
        return_shared(pool);
    }

    /// `(quote fee reserve, locked maker fees)` — the two pool-level balances a
    /// release moves.
    fun escrow(pool_id: ID, test: &mut Scenario): (u64, u64) {
        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let reserve = pool.quote_fee_reserve_balance();
        let locked = pool.locked_maker_fees();
        return_shared(pool);

        (reserve, locked)
    }

    fun side_length(pool_id: ID, test: &mut Scenario): u64 {
        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let n = pool.load_inner().book().side_length(true);
        return_shared(pool);

        n
    }

    // === Cancel ===

    #[test]
    /// Cancelling a buffer resident and cancelling a tree resident must release
    /// exactly the same escrow. The two orders are the same price, the same
    /// quantity and the same account — only their storage differs, and that must be
    /// invisible in the money.
    fun cancel_releases_the_same_escrow_from_buffer_and_tree() {
        let mut test = begin(OWNER);
        let (pool_id, acct) = setup(&mut test);
        let ids = build_one_level(pool_id, acct, &mut test);
        assert_straddles_seam(pool_id, &mut test);

        // ids[0] is the buffer's resident; anything later is behind it in the tree.
        let in_buffer = ids[0];
        let in_tree = ids[DEEP / 2];

        let (reserve_before, locked_before) = escrow(pool_id, &mut test);
        pool_test_utils::cancel_order<SUI, USDC>(ALICE, pool_id, acct, in_buffer, &mut test);
        let (reserve_mid, locked_mid) = escrow(pool_id, &mut test);

        pool_test_utils::cancel_order<SUI, USDC>(ALICE, pool_id, acct, in_tree, &mut test);
        let (reserve_after, locked_after) = escrow(pool_id, &mut test);

        // Both releases moved the same amounts.
        assert!(reserve_before - reserve_mid == reserve_mid - reserve_after);
        assert!(locked_before - locked_mid == locked_mid - locked_after);
        // And both actually released something, so the equality is not 0 == 0.
        assert!(locked_before > locked_mid);

        assert!(side_length(pool_id, &mut test) == DEEP - 2);

        test.end();
    }

    #[test]
    /// The same for modify-down: cutting a resting order's quantity releases escrow
    /// proportionally, and the proportion cannot depend on which store held it.
    fun modify_down_releases_the_same_escrow_from_buffer_and_tree() {
        let mut test = begin(OWNER);
        let (pool_id, acct) = setup(&mut test);
        let ids = build_one_level(pool_id, acct, &mut test);
        assert_straddles_seam(pool_id, &mut test);

        let in_buffer = ids[0];
        let in_tree = ids[DEEP / 2];
        let half = quantity() / 2;

        let (reserve_before, locked_before) = escrow(pool_id, &mut test);
        pool_test_utils::modify_order<SUI, USDC>(ALICE, pool_id, acct, in_buffer, half, &mut test);
        let (reserve_mid, locked_mid) = escrow(pool_id, &mut test);

        pool_test_utils::modify_order<SUI, USDC>(ALICE, pool_id, acct, in_tree, half, &mut test);
        let (reserve_after, locked_after) = escrow(pool_id, &mut test);

        assert!(reserve_before - reserve_mid == reserve_mid - reserve_after);
        assert!(locked_before - locked_mid == locked_mid - locked_after);
        assert!(locked_before > locked_mid);
        // Neither order left the book.
        assert!(side_length(pool_id, &mut test) == DEEP);

        test.end();
    }

    // === Fill ===

    #[test]
    /// A taker large enough to run out of the buffer and into the tree. Every maker
    /// it consumes is settled, in price-time order, regardless of which store held
    /// it — and the escrow released tracks the orders that actually left.
    fun taker_crosses_the_seam_and_settles_every_maker() {
        let mut test = begin(OWNER);
        let (pool_id, acct) = setup(&mut test);
        let ids = build_one_level(pool_id, acct, &mut test);
        assert_straddles_seam(pool_id, &mut test);

        let bob = create_acct_and_share_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Well past the buffer, so the walk has to continue into the tree.
        let take = 40u64;
        let info = pool_test_utils::place_limit_order<SUI, USDC>(
            BOB,
            pool_id,
            bob,
            constants::immediate_or_cancel(),
            constants::self_matching_allowed(),
            price(),
            quantity() * take,
            false,
            constants::max_u64(),
            &mut test,
        );

        assert!(info.executed_quantity() == quantity() * take);
        let fills = info.fills();
        assert!(fills.length() == take);

        // Consumed strictly from the front, in placement order, straight through the
        // seam — the makers behind the buffer are reached in the order they queued.
        let mut k = 0u64;
        while (k < take) {
            assert!(fills[k].maker_order_id() == ids[k]);
            k = k + 1;
        };

        assert!(side_length(pool_id, &mut test) == DEEP - take);

        // And the buffer is left *empty*, with the remainder served from the tree.
        // Spill is one-way: nothing is pulled forward to replace what the sweep
        // consumed, and the side goes on quoting correctly from the tree until a
        // competitive maker rebuilds the buffer. A refilling design would show a
        // repopulated buffer here.
        test.next_tx(ALICE);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let inner = pool.load_inner();
            assert!(inner.book().hot_bids().length() == 0);
            assert!(!inner.bids().is_empty());
            return_shared(pool);
        };

        // A competitive maker rebuilds it inline, without touching the tree.
        pool_test_utils::place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            acct,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price() + constants::float_scaling(),
            quantity(),
            true,
            constants::max_u64(),
            &mut test,
        );
        assert_straddles_seam(pool_id, &mut test);

        test.end();
    }

    #[test]
    /// A laddered book that spills. Every placement is a new best bid, so the buffer
    /// fills to capacity and pushes its worst residents into the tree — the path the
    /// one-price builds never take. Then a taker walks the whole thing, best price
    /// first, straight across the seam.
    fun spilled_ladder_fills_in_price_order_across_the_seam() {
        let mut test = begin(OWNER);
        let (pool_id, acct) = setup(&mut test);
        let ids = build_ladder(pool_id, acct, &mut test);
        assert_straddles_seam(pool_id, &mut test);

        // The buffer really did fill rather than trailing at one order, which is
        // what distinguishes this build from the one-price one.
        test.next_tx(ALICE);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let inner = pool.load_inner();
            assert!(inner.book().hot_bids().length() > 1);
            assert!(inner.bids().length() > 1);
            return_shared(pool);
        };

        let bob = create_acct_and_share_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Sell into it at the bottom of the ladder, taking more than the buffer
        // holds so the walk continues into the tree.
        let take = 40u64;
        let info = pool_test_utils::place_limit_order<SUI, USDC>(
            BOB,
            pool_id,
            bob,
            constants::immediate_or_cancel(),
            constants::self_matching_allowed(),
            constants::float_scaling(),
            quantity() * take,
            false,
            constants::max_u64(),
            &mut test,
        );
        assert!(info.executed_quantity() == quantity() * take);

        // Best bid first: the ladder was built worst-price-first, so the taker
        // consumes it in reverse placement order, through the seam without a break.
        let fills = info.fills();
        assert!(fills.length() == take);
        let mut k = 0u64;
        while (k < take) {
            assert!(fills[k].maker_order_id() == ids[DEEP - 1 - k]);
            k = k + 1;
        };

        assert!(side_length(pool_id, &mut test) == DEEP - take);

        test.end();
    }

    // === Bulk drain ===

    #[test]
    /// Cancelling a whole book deeper than the buffer, in batches, through the real
    /// `cancel_orders` entry point. At the end the side is empty in both stores and
    /// every last unit of escrow has been released.
    fun cancel_orders_drains_a_book_deeper_than_the_buffer() {
        let mut test = begin(OWNER);
        let (pool_id, acct) = setup(&mut test);
        let mut ids = build_one_level(pool_id, acct, &mut test);
        assert_straddles_seam(pool_id, &mut test);

        let (_, locked_before) = escrow(pool_id, &mut test);
        assert!(locked_before > 0);

        // Batched: one top-up per batch, because each cancel refunds into the
        // account and the helper's per-call mint overflows it on a long run.
        while (!ids.is_empty()) {
            let mut batch = vector[];
            let mut n = 0u64;
            while (n < 20 && !ids.is_empty()) {
                batch.push_back(ids.pop_back());
                n = n + 1;
            };

            test.next_tx(ALICE);
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<sui::clock::Clock>();
            let mut trading_account = test.take_shared_by_id<TradingAccount>(acct);
            let top_up = mint_for_testing<USDC>(
                1_000 * constants::float_scaling(),
                test.ctx(),
            );
            trading_account.deposit(top_up, test.ctx());
            let trade_proof = trading_account.generate_proof_as_owner(test.ctx());
            pool.cancel_orders<SUI, USDC>(
                &mut trading_account,
                &trade_proof,
                batch,
                &clock,
                test.ctx(),
            );
            return_shared(trading_account);
            return_shared(clock);
            return_shared(pool);
        };

        assert!(side_length(pool_id, &mut test) == 0);
        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let inner = pool.load_inner();
        assert!(inner.book().hot_bids().length() == 0);
        assert!(inner.bids().is_empty());
        assert!(pool.locked_maker_fees() == 0);
        return_shared(pool);

        test.end();
    }

    #[test]
    /// The account's open-order set tracks a book deeper than the buffer. It is the
    /// only record of what a trader still has resting, and it is maintained by the
    /// state layer rather than the book, so a seam it cannot see must not desync it.
    fun account_open_orders_tracks_a_book_deeper_than_the_buffer() {
        let mut test = begin(OWNER);
        let (pool_id, acct) = setup(&mut test);
        let ids = build_one_level(pool_id, acct, &mut test);
        assert_straddles_seam(pool_id, &mut test);

        test.next_tx(ALICE);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let trading_account = test.take_shared_by_id<TradingAccount>(acct);
            let open = pool.account_open_orders(&trading_account);
            assert!(open.length() == DEEP);
            let mut i = 0u64;
            while (i < DEEP) {
                assert!(open.contains(&ids[i]));
                i = i + 1;
            };
            return_shared(trading_account);
            return_shared(pool);
        };

        // Retire one from each store and the set follows.
        pool_test_utils::cancel_order<SUI, USDC>(ALICE, pool_id, acct, ids[0], &mut test);
        pool_test_utils::cancel_order<SUI, USDC>(ALICE, pool_id, acct, ids[DEEP / 2], &mut test);

        test.next_tx(ALICE);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let trading_account = test.take_shared_by_id<TradingAccount>(acct);
            let open = pool.account_open_orders(&trading_account);
            assert!(open.length() == DEEP - 2);
            assert!(!open.contains(&ids[0]));
            assert!(!open.contains(&ids[DEEP / 2]));
            return_shared(trading_account);
            return_shared(pool);
        };

        test.end();
    }
}
