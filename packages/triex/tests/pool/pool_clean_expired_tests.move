/// Coin-pool twin of `multicoin_pool_clean_expired_tests`: `clean_expired_orders`
/// (TRIEX-159) retires expired orders on anyone's call and credits the owner
/// exactly as a matched expiry does.
#[test_only]
module triex::pool_clean_expired_tests {
    use sui::{clock::Clock, event, sui::SUI, test_scenario::{Scenario, begin, end, return_shared}};
    use token::cred::CRED;
    use triex::{
        constants,
        order_info::{Self, OrderInfo},
        pool::Pool,
        pool_test_utils,
        quote_fee,
        trading_account::TradingAccount,
        trading_account_tests::{USDC, create_acct_and_share_with_funds},
        vault
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;
    /// Holds no trading account: the cleanup caller is a stranger to every order.
    const CHARLIE: address = @0xCCCC;

    const RETENTION_BPS: u64 = 2000;

    public struct Fixture has drop {
        pool_id: ID,
        alice: ID,
        bob: ID,
    }

    fun setup(test: &mut Scenario): Fixture {
        let registry_id = pool_test_utils::setup_test(OWNER, test);
        let funds = 1000000 * constants::float_scaling();
        let alice = create_acct_and_share_with_funds(ALICE, funds, test);
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(ALICE, registry_id, alice, test);
        let bob = create_acct_and_share_with_funds(BOB, funds, test);

        Fixture { pool_id, alice, bob }
    }

    fun price(): u64 { 2 * constants::float_scaling() }

    fun quantity(): u64 { 100 * constants::float_scaling() }

    fun set_clock(ms: u64, test: &mut Scenario) {
        test.next_tx(OWNER);
        let mut clock = test.take_shared<Clock>();
        clock.set_for_testing(ms);
        return_shared(clock);
    }

    fun place(
        test: &mut Scenario,
        sender: address,
        f: &Fixture,
        trading_account_id: ID,
        price: u64,
        is_bid: bool,
        expire_timestamp: u64,
    ): OrderInfo {
        pool_test_utils::place_limit_order<SUI, USDC>(
            sender,
            f.pool_id,
            trading_account_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity(),
            is_bid,
            expire_timestamp,
            test,
        )
    }

    /// Run the cleanup as CHARLIE in its own transaction, so the events it
    /// emitted are the only ones `events_by_type` sees until the next one.
    fun clean(test: &mut Scenario, f: &Fixture, order_ids: vector<u128>): u64 {
        test.next_tx(CHARLIE);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(f.pool_id);
        let clock = test.take_shared<Clock>();
        let removed = pool.clean_expired_orders(order_ids, &clock, test.ctx());
        return_shared(clock);
        return_shared(pool);

        removed
    }

    fun is_resting(test: &mut Scenario, f: &Fixture, trading_account_id: ID, order_id: u128): bool {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(f.pool_id);
        let ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let resting = pool.account_open_orders(&ta).contains(&order_id);
        return_shared(ta);
        return_shared(pool);

        resting
    }

    /// The owner's settled (base, quote) on the pool, before any withdraw.
    fun settled(test: &mut Scenario, f: &Fixture, trading_account_id: ID): (u64, u64) {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(f.pool_id);
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

    /// Two identical bids, one cleaned and one expired by a crossing ask, settle
    /// the same refund and report the same split.
    #[test]
    fun cleaned_bid_settles_like_a_matched_expiry() {
        let mut test = begin(OWNER);
        let f = setup(&mut test);
        let expire = pool_test_utils::get_time(&mut test) + 100;

        let cleaned = place(&mut test, ALICE, &f, f.alice, price(), true, expire);
        let matched = place(&mut test, ALICE, &f, f.alice, price(), true, expire);
        let escrow = cleaned.maker_fees();
        assert!(escrow > 0 && matched.maker_fees() == escrow);
        let (refund, retained) = quote_fee::split_released_fee(escrow, RETENTION_BPS);
        let (_, quote_before) = settled(&mut test, &f, f.alice);

        set_clock(expire + 1, &mut test);
        assert!(clean(&mut test, &f, vector[cleaned.order_id()]) == 1);
        let refunds = event::events_by_type<vault::PoolFeesRefunded>();
        assert!(refunds.length() == 1);
        let (refund_order_id, refund_amount, refund_ta) = vault::refunded_event_parts(&refunds[0]);
        assert!(refund_order_id == cleaned.order_id());
        assert!(refund_amount == refund);
        assert!(refund_ta == f.alice);
        let cleaned_events = expired_events();
        assert!(cleaned_events == vector[vector[refund, retained]]);
        let (_, quote_after_clean) = settled(&mut test, &f, f.alice);
        // 100 at a price of 2.
        let principal = 200 * constants::float_scaling();
        assert!(quote_after_clean - quote_before == principal + refund);
        assert!(!is_resting(&mut test, &f, f.alice, cleaned.order_id()));

        place(&mut test, BOB, &f, f.bob, price(), false, constants::max_u64());
        assert!(expired_events() == cleaned_events);
        let (_, quote_after_match) = settled(&mut test, &f, f.alice);
        assert!(quote_after_match - quote_after_clean == principal + refund);

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(f.pool_id);
            assert!(pool.locked_maker_fees() == 0);
            assert!(pool.quote_fee_reserve_balance() == 2 * retained);
            return_shared(pool);
        };

        end(test);
    }

    /// Expired, live, repeated and unknown ids in one call: only the expired bid
    /// and ask are removed, each once. The ask returns its base and releases no
    /// escrow. An order on its exact expiry instant is still live.
    #[test]
    fun mixed_batch_removes_only_expired_orders() {
        let mut test = begin(OWNER);
        let f = setup(&mut test);
        let expire = pool_test_utils::get_time(&mut test) + 100;

        let expired_bid = place(&mut test, ALICE, &f, f.alice, price(), true, expire);
        let live_bid = place(&mut test, ALICE, &f, f.alice, price(), true, constants::max_u64());
        // Priced above the bids, so the two sides never cross. Expires 1ms later
        // than the rest, so it is exactly on its expiry when they have passed theirs.
        let boundary_ask = place(&mut test, BOB, &f, f.bob, 2 * price(), false, expire + 1);
        let (base_before, _) = settled(&mut test, &f, f.bob);

        set_clock(expire + 1, &mut test);
        let unknown = expired_bid.order_id() - 1_000;
        let removed = clean(
            &mut test,
            &f,
            vector[
                expired_bid.order_id(),
                live_bid.order_id(),
                expired_bid.order_id(),
                unknown,
                boundary_ask.order_id(),
            ],
        );
        assert!(removed == 1);
        assert!(expired_events().length() == 1);
        assert!(!is_resting(&mut test, &f, f.alice, expired_bid.order_id()));
        assert!(is_resting(&mut test, &f, f.alice, live_bid.order_id()));
        assert!(is_resting(&mut test, &f, f.bob, boundary_ask.order_id()));

        set_clock(expire + 2, &mut test);
        assert!(clean(&mut test, &f, vector[boundary_ask.order_id()]) == 1);
        assert!(event::events_by_type<vault::PoolFeesRefunded>().is_empty());
        assert!(expired_events() == vector[vector[0, 0]]);
        let (base_after, _) = settled(&mut test, &f, f.bob);
        assert!(base_after - base_before == quantity());
        assert!(!is_resting(&mut test, &f, f.bob, boundary_ask.order_id()));

        end(test);
    }

    /// An order is live on its expiry instant, as in matching, so a call that
    /// finds nothing expired removes nothing; one millisecond later it is cleaned.
    #[test]
    fun order_is_not_removed_at_its_expire_timestamp() {
        let mut test = begin(OWNER);
        let f = setup(&mut test);
        let expire = pool_test_utils::get_time(&mut test) + 100;

        let bid = place(&mut test, ALICE, &f, f.alice, price(), true, expire);

        set_clock(expire, &mut test);
        assert!(clean(&mut test, &f, vector[bid.order_id()]) == 0);
        assert!(expired_events().is_empty());
        assert!(event::events_by_type<vault::PoolFeesRefunded>().is_empty());
        assert!(is_resting(&mut test, &f, f.alice, bid.order_id()));

        set_clock(expire + 1, &mut test);
        assert!(clean(&mut test, &f, vector[bid.order_id()]) == 1);
        assert!(!is_resting(&mut test, &f, f.alice, bid.order_id()));

        end(test);
    }

    #[test, expected_failure(abort_code = ::triex::pool::ETooManyOrders)]
    fun batch_above_max_fills_aborts() {
        let mut test = begin(OWNER);
        let f = setup(&mut test);
        let order_ids = vector::tabulate!(constants::max_fills() + 1, |i| i as u128);

        clean(&mut test, &f, order_ids);

        abort 0
    }
}
