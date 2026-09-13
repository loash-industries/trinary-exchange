/// Depth tests for the coin book's `BigVector` storage.
///
/// `MAX_SLICE_SIZE` is 64, so a side holding more than 64 resting orders is
/// stored across several leaf slices. Everything the book does then depends on
/// slice-boundary traversal — `next_slice` / `prev_slice` hopping leaves, removal
/// rebalancing or merging them — which a book of a handful of orders never
/// exercises. These tests deliberately sit above that threshold.
///
/// `MAX_OPEN_ORDERS` caps one trading account at 100 open orders, so the deep
/// books here use 80 per side: enough to force a split and cross-slice walking,
/// within what a single account may hold.
#[test_only]
module triex::coin_book_slice_tests {
    use sui::{
        coin::mint_for_testing,
        sui::SUI,
        test_scenario::{begin, end, return_shared, Scenario}
    };
    use token::cred::CRED;
    use triex::{
        coin_order_query::iter_orders,
        constants,
        pool::Pool,
        pool_test_utils,
        trading_account::TradingAccount,
        trading_account_tests::{create_acct_and_share_with_funds, USDC}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    /// Above `MAX_SLICE_SIZE` (64) so the side spans more than one leaf, and below
    /// `MAX_OPEN_ORDERS` (100) so one account can hold it all.
    const DEEP: u64 = 80;

    fun quantity(): u64 { 1 * constants::float_scaling() }

    /// Spread the deep book over several price levels so the tests cover grouping
    /// by level as well as raw depth. 8 levels × 10 orders straddles the 64-order
    /// slice boundary in the middle of a level, which is the interesting case.
    const LEVELS: u64 = 8;
    const PER_LEVEL: u64 = 10;

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

    /// Place `DEEP` bids across `LEVELS` price levels, returning their ids in
    /// placement order. Bid prices climb as the level index rises.
    fun fill_bid_side(pool_id: ID, trading_account_id: ID, test: &mut Scenario): vector<u128> {
        let mut ids = vector[];
        let mut level = 0;
        while (level < LEVELS) {
            let price = (level + 1) * constants::float_scaling();
            let mut n = 0;
            while (n < PER_LEVEL) {
                let id = pool_test_utils::place_limit_order<SUI, USDC>(
                    ALICE,
                    pool_id,
                    trading_account_id,
                    constants::no_restriction(),
                    constants::self_matching_allowed(),
                    price,
                    quantity(),
                    true,
                    constants::max_u64(),
                    test,
                ).order_id();
                ids.push_back(id);
                n = n + 1;
            };
            level = level + 1;
        };

        ids
    }

    /// Cancel many orders in one transaction.
    ///
    /// `pool_test_utils::cancel_order` mints a large quote top-up per call, which
    /// overflows a trading account's balance after about eighteen calls — fine for
    /// the handful of cancels other suites do, not for draining a deep book. This
    /// batches through `cancel_orders` with a single top-up instead.
    fun cancel_many(
        pool_id: ID,
        trading_account_id: ID,
        order_ids: vector<u128>,
        test: &mut Scenario,
    ) {
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<sui::clock::Clock>();
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let top_up = mint_for_testing<USDC>(1_000 * constants::float_scaling(), test.ctx());
        trading_account.deposit(top_up, test.ctx());
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());
        pool.cancel_orders<SUI, USDC>(
            &mut trading_account,
            &trade_proof,
            order_ids,
            &clock,
            test.ctx(),
        );
        return_shared(trading_account);
        return_shared(clock);
        return_shared(pool);
    }

    /// Read the whole bid side in book order. `limit` is above `DEEP`, so this is
    /// one page spanning every slice.
    fun read_all_bids(pool_id: ID, test: &mut Scenario): vector<u128> {
        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let page = iter_orders(&pool, option::none(), option::none(), option::none(), 1000, true);
        let mut ids = vector[];
        page.orders().do_ref!(|order| ids.push_back(order.order_id()));
        return_shared(pool);

        ids
    }

    #[test]
    /// A side deeper than one slice still reads back best-price-first, FIFO within
    /// a level — the traversal has to hop leaves to do it.
    fun test_deep_bid_side_iterates_in_priority_order_across_slices() {
        let mut test = begin(OWNER);
        let (pool_id, trading_account_id) = setup(&mut test);
        let placed = fill_bid_side(pool_id, trading_account_id, &mut test);
        assert!(placed.length() == DEEP);

        let seen = read_all_bids(pool_id, &mut test);
        assert!(seen.length() == DEEP);

        // Expected order: highest level first; within a level, placement order.
        // `placed` is grouped by ascending level, so the levels reverse but each
        // level's run keeps its order.
        let mut expected = vector[];
        let mut level = LEVELS;
        while (level > 0) {
            level = level - 1;
            let mut n = 0;
            while (n < PER_LEVEL) {
                expected.push_back(placed[level * PER_LEVEL + n]);
                n = n + 1;
            };
        };
        assert!(seen == expected);

        end(test);
    }

    #[test]
    /// Removing an order from the interior of a multi-slice side leaves every other
    /// order in place and in order. With the vector book this was an O(n) memmove;
    /// here it is a keyed remove that may rebalance the leaf.
    fun test_cancel_from_middle_slice_preserves_the_rest() {
        let mut test = begin(OWNER);
        let (pool_id, trading_account_id) = setup(&mut test);
        let placed = fill_bid_side(pool_id, trading_account_id, &mut test);

        // Order 40 of 80 — comfortably inside the second slice's territory and in
        // the middle of a price level.
        let victim = placed[39];
        pool_test_utils::cancel_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id,
            victim,
            &mut test,
        );

        let seen = read_all_bids(pool_id, &mut test);
        assert!(seen.length() == DEEP - 1);
        assert!(!seen.contains(&victim));

        // Relative order of the survivors is untouched.
        let mut expected = vector[];
        let mut level = LEVELS;
        while (level > 0) {
            level = level - 1;
            let mut n = 0;
            while (n < PER_LEVEL) {
                let id = placed[level * PER_LEVEL + n];
                if (id != victim) expected.push_back(id);
                n = n + 1;
            };
        };
        assert!(seen == expected);

        end(test);
    }

    #[test]
    /// Draining most of a multi-slice side takes the leaves back below their
    /// half-full threshold, which is what drives `BigVector`'s steal and merge
    /// fix-ups. The survivors must still read back in order afterwards.
    fun test_draining_side_merges_slices_and_keeps_order() {
        let mut test = begin(OWNER);
        let (pool_id, trading_account_id) = setup(&mut test);
        let placed = fill_bid_side(pool_id, trading_account_id, &mut test);

        // Cancel the first 60 placed (the six lowest price levels), leaving 20
        // spread over the top two — fewer than one slice holds, so the tree must
        // collapse back down.
        let mut victims = vector[];
        let mut i = 0;
        while (i < 60) {
            victims.push_back(placed[i]);
            i = i + 1;
        };
        cancel_many(pool_id, trading_account_id, victims, &mut test);

        let seen = read_all_bids(pool_id, &mut test);
        assert!(seen.length() == 20);

        let mut expected = vector[];
        let mut level = LEVELS;
        while (level > 6) {
            level = level - 1;
            let mut n = 0;
            while (n < PER_LEVEL) {
                expected.push_back(placed[level * PER_LEVEL + n]);
                n = n + 1;
            };
        };
        assert!(seen == expected);

        end(test);
    }

    #[test]
    /// A modify-down reaches an order in the interior of a deep side by key and
    /// mutates it in place.
    fun test_modify_order_in_middle_slice() {
        let mut test = begin(OWNER);
        let (pool_id, trading_account_id) = setup(&mut test);
        let placed = fill_bid_side(pool_id, trading_account_id, &mut test);

        let target = placed[39];
        let new_quantity = quantity() / 2;
        pool_test_utils::modify_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id,
            target,
            new_quantity,
            &mut test,
        );

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let order = pool.get_order(target);
        assert!(order.quantity() == new_quantity);
        return_shared(pool);

        // Still 80 orders: a modify-down does not remove the order.
        assert!(read_all_bids(pool_id, &mut test).length() == DEEP);

        end(test);
    }

    #[test]
    /// A taker sweeping a side deeper than one slice has to cross a leaf boundary
    /// mid-match, and each order it consumes is removed by key. `MAX_FILLS` is 100,
    /// above the 70 makers here, so the whole sweep happens in one transaction.
    fun test_taker_sweep_crosses_slice_boundary() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let maker_account = create_acct_and_share_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let taker_account = create_acct_and_share_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(ALICE, registry_id, maker_account, &mut test);

        // 70 asks at one price: more than one slice holds, all equally priced so
        // the sweep must consume them in placement order.
        let price = 2 * constants::float_scaling();
        let makers = 70;
        let mut n = 0;
        while (n < makers) {
            pool_test_utils::place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                maker_account,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity(),
                false,
                constants::max_u64(),
                &mut test,
            );
            n = n + 1;
        };

        let order_info = pool_test_utils::place_market_order<SUI, USDC>(
            BOB,
            pool_id,
            taker_account,
            constants::self_matching_allowed(),
            makers * quantity(),
            true,
            &mut test,
        );
        assert!(order_info.executed_quantity() == makers * quantity());

        // Every maker was consumed, so the ask side is empty again.
        test.next_tx(BOB);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let page = iter_orders(&pool, option::none(), option::none(), option::none(), 1000, false);
        assert!(page.orders().length() == 0);
        return_shared(pool);

        end(test);
    }

    #[test]
    /// Level2 aggregation seeds its walk from a key derived from the price bound,
    /// then hops slices. Every level of a deep book must still be reported once,
    /// with the whole level's resting quantity summed.
    fun test_level2_spans_slices() {
        let mut test = begin(OWNER);
        let (pool_id, trading_account_id) = setup(&mut test);
        fill_bid_side(pool_id, trading_account_id, &mut test);

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<sui::clock::Clock>();
        let (prices, quantities) = pool.get_level2_range(
            constants::min_price(),
            constants::max_price(),
            true,
            &clock,
        );
        assert!(prices.length() == LEVELS);
        assert!(quantities.length() == LEVELS);

        // Bids report best price first, and each level holds PER_LEVEL orders.
        let mut i = 0;
        while (i < LEVELS) {
            assert!(prices[i] == (LEVELS - i) * constants::float_scaling());
            assert!(quantities[i] == PER_LEVEL * quantity());
            i = i + 1;
        };

        return_shared(clock);
        return_shared(pool);
        end(test);
    }

    #[test]
    /// Paging with a limit that lands exactly on the slice boundary is the case a
    /// page-break bug would hide in: the cursor has to carry across leaves without
    /// repeating or dropping the order either side of the seam.
    fun test_pagination_page_break_at_slice_edge() {
        let mut test = begin(OWNER);
        let (pool_id, trading_account_id) = setup(&mut test);
        fill_bid_side(pool_id, trading_account_id, &mut test);
        let all = read_all_bids(pool_id, &mut test);

        let slice_size = constants::max_slice_size();
        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        // First page: exactly one slice worth.
        let first = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::none(),
            slice_size,
            true,
        );
        assert!(first.orders().length() == slice_size);
        assert!(first.has_next_page() == true);

        // Second page anchored on the first page's last id, which is exclusive.
        let last_of_first = first.orders()[slice_size - 1].order_id();
        let second = iter_orders(
            &pool,
            option::some(last_of_first),
            option::none(),
            option::none(),
            1000,
            true,
        );
        assert!(second.orders().length() == DEEP - slice_size);
        assert!(second.has_next_page() == false);

        // Concatenating the pages reproduces the single-page read exactly: no
        // repeat at the seam, nothing skipped.
        let mut paged = vector[];
        first.orders().do_ref!(|order| paged.push_back(order.order_id()));
        second.orders().do_ref!(|order| paged.push_back(order.order_id()));
        assert!(paged == all);

        return_shared(pool);
        end(test);
    }

    #[test]
    /// `mid_price` reads the extreme key of each side. With a deep book those sit
    /// in different leaves from each other, and the walk that skips expired orders
    /// has to be able to leave its starting slice.
    fun test_mid_price_on_deep_book() {
        let mut test = begin(OWNER);
        let (pool_id, trading_account_id) = setup(&mut test);
        fill_bid_side(pool_id, trading_account_id, &mut test);

        // Asks above every bid, also more than one slice deep. They go on a second
        // account: `MAX_OPEN_ORDERS` caps one account at 100, and the bid side
        // already holds 80.
        let ask_account = create_acct_and_share_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let mut n = 0;
        while (n < 70) {
            pool_test_utils::place_limit_order<SUI, USDC>(
                BOB,
                pool_id,
                ask_account,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                (10 + n) * constants::float_scaling(),
                quantity(),
                false,
                constants::max_u64(),
                &mut test,
            );
            n = n + 1;
        };

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<sui::clock::Clock>();
        // Best bid is the top level (8), best ask the lowest ask (10).
        let expected = (8 * constants::float_scaling() + 10 * constants::float_scaling()) / 2;
        assert!(pool.mid_price(&clock) == expected);
        return_shared(clock);
        return_shared(pool);

        end(test);
    }
}
