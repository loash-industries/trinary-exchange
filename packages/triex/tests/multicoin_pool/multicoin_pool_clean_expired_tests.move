/// `clean_expired_orders` (TRIEX-159): anyone can retire expired orders, and the
/// owner is credited exactly as when a taker's match expires them.
#[test_only]
module triex::integration_multicoin_pool_clean_expired_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test;
    use sui::{clock::Clock, event, test_scenario::{Scenario, begin, end, return_shared}};
    use triex::{
        constants,
        fee_policy::FeePolicy,
        integration_multicoin_test_utils as mc_utils,
        multicoin_pool::MultiCoinPool,
        order_info::{Self, OrderInfo},
        quote_fee,
        trading_account::TradingAccount,
        trading_account_tests::USDC,
        vault
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;
    /// Holds no trading account: the cleanup caller is a stranger to every order.
    const CHARLIE: address = @0xCCCC;

    const ASSET_GOLD: u64 = 1;
    const PRICE: u64 = 2_000_000_000;
    const QUANTITY: u64 = 100;
    /// Genesis cancel retention, which an expiry splits on too.
    const RETENTION_BPS: u64 = 2000;

    public struct Fixture has drop {
        pool_id: ID,
        alice: ID,
        bob: ID,
    }

    /// A multicoin pool with Alice funded in quote and Bob in quote and GOLD.
    fun setup(test: &mut Scenario): (Fixture, CollectionCap) {
        let (registry_id, collection_id, collection_cap) = mc_utils::setup_registry_with_multicoin(
            test,
        );
        let pool_id = mc_utils::setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            test,
        );
        let funds = 1_000_000 * constants::float_scaling();
        let alice = mc_utils::create_trading_account_with_funds(ALICE, funds, funds, test);
        let bob = mc_utils::create_trading_account_with_funds(BOB, funds, funds, test);

        test.next_tx(OWNER);
        {
            let mut collection = test.take_shared<Collection>();
            let gold = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                ASSET_GOLD,
                funds,
                test.ctx(),
            );
            return_shared(collection);
            transfer::public_transfer(gold, BOB);
        };
        test.next_tx(BOB);
        {
            let mut ta = test.take_shared_by_id<TradingAccount>(bob);
            let gold = test.take_from_sender<multicoin::Balance>();
            ta.deposit_multicoin(gold, test.ctx());
            return_shared(ta);
        };

        (Fixture { pool_id, alice, bob }, collection_cap)
    }

    fun now(test: &mut Scenario): u64 {
        mc_utils::get_time(test)
    }

    fun set_clock(ms: u64, test: &mut Scenario) {
        test.next_tx(OWNER);
        let mut clock = test.take_shared<Clock>();
        clock.set_for_testing(ms);
        return_shared(clock);
    }

    fun place(
        test: &mut Scenario,
        sender: address,
        pool_id: ID,
        trading_account_id: ID,
        price: u64,
        is_bid: bool,
        expire_timestamp: u64,
    ): OrderInfo {
        place_sized(
            test,
            sender,
            pool_id,
            trading_account_id,
            price,
            QUANTITY,
            is_bid,
            expire_timestamp,
        )
    }

    fun place_sized(
        test: &mut Scenario,
        sender: address,
        pool_id: ID,
        trading_account_id: ID,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire_timestamp: u64,
    ): OrderInfo {
        test.next_tx(sender);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let proof = ta.generate_proof_as_owner(test.ctx());
        let order_info = pool.place_limit_order(
            &policy,
            &mut ta,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &clock,
            test.ctx(),
        );
        return_shared(ta);
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);

        order_info
    }

    /// Run the cleanup as CHARLIE in its own transaction, so the events it
    /// emitted are the only ones `events_by_type` sees until the next one.
    fun clean(test: &mut Scenario, pool_id: ID, order_ids: vector<u128>): u64 {
        test.next_tx(CHARLIE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let removed = pool.clean_expired_orders(&policy, order_ids, &clock, test.ctx());
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);

        removed
    }

    fun is_resting(test: &mut Scenario, pool_id: ID, trading_account_id: ID, order_id: u128): bool {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let resting = pool.account_open_orders(&ta).contains(&order_id);
        return_shared(ta);
        return_shared(pool);

        resting
    }

    /// The owner's settled (base, quote) on the pool, before any withdraw.
    fun settled(test: &mut Scenario, pool_id: ID, trading_account_id: ID): (u64, u64) {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let balances = pool.account(&ta).settled_balances();
        return_shared(ta);
        return_shared(pool);

        (balances.base(), balances.quote())
    }

    /// The `[fee_refunded, fee_retained]` of each `OrderExpired` emitted in the
    /// current transaction.
    fun expired_events(): vector<vector<u64>> {
        event::events_by_type<order_info::OrderExpired>().map!(|e| {
            let (_, refunded, retained) = e.expired_event_parts();
            vector[refunded, retained]
        })
    }

    /// A bid retired by the cleanup pays its owner exactly what a match would:
    /// two identical bids, one cleaned and one expired by a crossing ask, settle
    /// the same refund, report the same split, and leave only the retention.
    #[test]
    fun cleaned_bid_settles_like_a_matched_expiry() {
        let mut test = begin(OWNER);
        let (f, collection_cap) = setup(&mut test);
        let expire = now(&mut test) + 100;

        let cleaned = place(&mut test, ALICE, f.pool_id, f.alice, PRICE, true, expire);
        let matched = place(&mut test, ALICE, f.pool_id, f.alice, PRICE, true, expire);
        let escrow = cleaned.maker_fees();
        assert!(escrow > 0 && matched.maker_fees() == escrow);
        let (refund, retained) = quote_fee::split_released_fee(escrow, RETENTION_BPS);
        let (_, quote_before) = settled(&mut test, f.pool_id, f.alice);

        set_clock(expire + 1, &mut test);
        assert!(clean(&mut test, f.pool_id, vector[cleaned.order_id()]) == 1);
        let refunds = event::events_by_type<vault::PoolFeesRefunded>();
        assert!(refunds.length() == 1);
        let (refund_order_id, refund_amount, refund_ta) = vault::refunded_event_parts(&refunds[0]);
        assert!(refund_order_id == cleaned.order_id());
        assert!(refund_amount == refund);
        assert!(refund_ta == f.alice);
        let cleaned_events = expired_events();
        assert!(cleaned_events.length() == 1);
        assert!(cleaned_events[0][0] == refund && cleaned_events[0][1] == retained);
        let (_, quote_after_clean) = settled(&mut test, f.pool_id, f.alice);
        let principal = QUANTITY * PRICE;
        assert!(quote_after_clean - quote_before == principal + refund);
        assert!(!is_resting(&mut test, f.pool_id, f.alice, cleaned.order_id()));
        assert!(is_resting(&mut test, f.pool_id, f.alice, matched.order_id()));

        // Bob's crossing ask expires the twin through the match path.
        place(&mut test, BOB, f.pool_id, f.bob, PRICE, false, constants::max_u64());
        let matched_events = expired_events();
        assert!(matched_events.length() == 1);
        assert!(matched_events[0] == cleaned_events[0]);
        let (_, quote_after_match) = settled(&mut test, f.pool_id, f.alice);
        assert!(quote_after_match - quote_after_clean == principal + refund);

        // No escrow outstanding; the reserve holds only the two retentions,
        // split through the genesis share class exactly as the match path does.
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(f.pool_id);
            assert!(pool.locked_maker_fees() == 0);
            let reserve = pool.quote_fee_reserve_balance();
            assert!(reserve == 2 * retained);
            let operator_cut = retained * 2000 / 10_000;
            assert!(pool.operator_owed() == 2 * operator_cut);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// An expired ask returns its base and releases no escrow, since asks lock none.
    #[test]
    fun cleaned_ask_returns_base() {
        let mut test = begin(OWNER);
        let (f, collection_cap) = setup(&mut test);
        let expire = now(&mut test) + 100;

        let ask = place(&mut test, BOB, f.pool_id, f.bob, PRICE, false, expire);
        let (base_before, _) = settled(&mut test, f.pool_id, f.bob);

        set_clock(expire + 1, &mut test);
        assert!(clean(&mut test, f.pool_id, vector[ask.order_id()]) == 1);
        assert!(event::events_by_type<vault::PoolFeesRefunded>().is_empty());
        let events = expired_events();
        assert!(events.length() == 1);
        assert!(events[0] == vector[0, 0]);
        let (base_after, _) = settled(&mut test, f.pool_id, f.bob);
        assert!(base_after - base_before == QUANTITY);
        assert!(!is_resting(&mut test, f.pool_id, f.bob, ask.order_id()));

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// One call over expired, live, repeated and unknown ids removes only the
    /// expired orders, each once, and aborts on none of the rest.
    #[test]
    fun mixed_batch_removes_only_expired_orders() {
        let mut test = begin(OWNER);
        let (f, collection_cap) = setup(&mut test);
        let expire = now(&mut test) + 100;

        let expired_bid = place(&mut test, ALICE, f.pool_id, f.alice, PRICE, true, expire);
        let live_bid = place(
            &mut test,
            ALICE,
            f.pool_id,
            f.alice,
            PRICE,
            true,
            constants::max_u64(),
        );
        // Priced above the bids, so the two sides never cross.
        let expired_ask = place(&mut test, BOB, f.pool_id, f.bob, 2 * PRICE, false, expire);

        set_clock(expire + 1, &mut test);
        let unknown = expired_bid.order_id() - 1_000;
        let removed = clean(
            &mut test,
            f.pool_id,
            vector[
                expired_bid.order_id(),
                live_bid.order_id(),
                expired_bid.order_id(),
                unknown,
                expired_ask.order_id(),
            ],
        );
        assert!(removed == 2);
        assert!(expired_events().length() == 2);
        assert!(!is_resting(&mut test, f.pool_id, f.alice, expired_bid.order_id()));
        assert!(!is_resting(&mut test, f.pool_id, f.bob, expired_ask.order_id()));
        assert!(is_resting(&mut test, f.pool_id, f.alice, live_bid.order_id()));

        // A second sweep of the same ids finds nothing left to do.
        assert!(
            clean(&mut test, f.pool_id, vector[expired_bid.order_id(), expired_ask.order_id()]) == 0,
        );
        assert!(clean(&mut test, f.pool_id, vector[]) == 0);

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// An order is live on its expiry instant, as in matching; it can be cleaned
    /// one millisecond later.
    #[test]
    fun order_is_not_removed_at_its_expire_timestamp() {
        let mut test = begin(OWNER);
        let (f, collection_cap) = setup(&mut test);
        let expire = now(&mut test) + 100;

        let bid = place(&mut test, ALICE, f.pool_id, f.alice, PRICE, true, expire);

        set_clock(expire, &mut test);
        assert!(clean(&mut test, f.pool_id, vector[bid.order_id()]) == 0);
        assert!(expired_events().is_empty());
        assert!(is_resting(&mut test, f.pool_id, f.alice, bid.order_id()));

        set_clock(expire + 1, &mut test);
        assert!(clean(&mut test, f.pool_id, vector[bid.order_id()]) == 1);
        assert!(!is_resting(&mut test, f.pool_id, f.alice, bid.order_id()));

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// Orders that are still valid are never touched, however they are passed in:
    /// a bid and an ask with expiries still ahead, and a partially filled bid. The
    /// call removes nothing, emits nothing, and leaves the orders, their escrow
    /// and their owners' balances exactly as they were.
    #[test]
    fun live_orders_are_left_untouched() {
        let mut test = begin(OWNER);
        let (f, collection_cap) = setup(&mut test);
        let expire = now(&mut test) + 1_000;

        // Half filled first, by an ask that leaves nothing resting.
        let partial = place(
            &mut test,
            ALICE,
            f.pool_id,
            f.alice,
            PRICE,
            true,
            constants::max_u64(),
        );
        place_sized(
            &mut test,
            BOB,
            f.pool_id,
            f.bob,
            PRICE,
            QUANTITY / 2,
            false,
            constants::max_u64(),
        );
        let bid = place(&mut test, ALICE, f.pool_id, f.alice, PRICE / 2, true, expire);
        // Priced above the bids, so the two sides never cross.
        let ask = place(&mut test, BOB, f.pool_id, f.bob, 2 * PRICE, false, expire);
        let ids = vector[bid.order_id(), ask.order_id(), partial.order_id()];

        test.next_tx(OWNER);
        let (orders_before, locked_before, reserve_before) = {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(f.pool_id);
            let orders = ids.map_ref!(|id| pool.get_order(*id));
            assert!(orders[2].filled_quantity() == QUANTITY / 2);
            let locked = pool.locked_maker_fees();
            let reserve = pool.quote_fee_reserve_balance();
            return_shared(pool);
            (orders, locked, reserve)
        };
        let (alice_base, alice_quote) = settled(&mut test, f.pool_id, f.alice);
        let (bob_base, bob_quote) = settled(&mut test, f.pool_id, f.bob);

        // Well before expiry, and again on the expiry instant itself.
        assert!(clean(&mut test, f.pool_id, ids) == 0);
        assert!(expired_events().is_empty());
        assert!(event::events_by_type<vault::PoolFeesRefunded>().is_empty());
        set_clock(expire, &mut test);
        assert!(clean(&mut test, f.pool_id, ids) == 0);
        assert!(expired_events().is_empty());
        assert!(event::events_by_type<vault::PoolFeesRefunded>().is_empty());

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(f.pool_id);
            let mut i = 0;
            while (i < ids.length()) {
                let order = pool.get_order(ids[i]);
                assert!(order.quantity() == orders_before[i].quantity());
                assert!(order.filled_quantity() == orders_before[i].filled_quantity());
                assert!(order.status() == orders_before[i].status());
                i = i + 1;
            };
            assert!(pool.locked_maker_fees() == locked_before);
            assert!(pool.quote_fee_reserve_balance() == reserve_before);
            return_shared(pool);
        };
        let (alice_base_after, alice_quote_after) = settled(&mut test, f.pool_id, f.alice);
        assert!(alice_base_after == alice_base && alice_quote_after == alice_quote);
        let (bob_base_after, bob_quote_after) = settled(&mut test, f.pool_id, f.bob);
        assert!(bob_base_after == bob_base && bob_quote_after == bob_quote);
        assert!(is_resting(&mut test, f.pool_id, f.alice, bid.order_id()));
        assert!(is_resting(&mut test, f.pool_id, f.bob, ask.order_id()));
        assert!(is_resting(&mut test, f.pool_id, f.alice, partial.order_id()));

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test, expected_failure(abort_code = ::triex::multicoin_pool::ETooManyOrders)]
    fun batch_above_max_fills_aborts() {
        let mut test = begin(OWNER);
        let (f, _collection_cap) = setup(&mut test);
        let order_ids = vector::tabulate!(constants::max_fills() + 1, |i| i as u128);

        clean(&mut test, f.pool_id, order_ids);

        abort 0
    }
}
