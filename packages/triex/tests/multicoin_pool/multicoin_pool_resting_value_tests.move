/// The resting-value bound through a real multicoin pool (TRIEX-153).
///
/// `book_resting_value_tests` pins the bound on the book. These go through
/// `place_limit_order`, where the report came from: three units of an item at
/// `MAX_PRICE` rested, and from then on every taker that reached them aborted,
/// while neither a match nor `clean_expired_orders` could retire them once
/// expired. One unit past the bound is now rejected at placement, and the
/// largest ask that can still rest is cleaned up like any other order, with its
/// base returned to its owner.
#[test_only]
module triex::integration_multicoin_pool_resting_value_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test;
    use sui::{clock::Clock, test_scenario::{Scenario, begin, end, return_shared}};
    use triex::{
        constants,
        fee_policy::FeePolicy,
        integration_multicoin_test_utils as mc_utils,
        multicoin_pool::MultiCoinPool,
        order_info::OrderInfo,
        trading_account::TradingAccount,
        trading_account_tests::USDC
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;
    /// Holds no trading account: the cleanup caller is a stranger to the order.
    const CHARLIE: address = @0xCCCC;

    const ASSET_GOLD: u64 = 1;

    /// The most base that can be valued at `MAX_PRICE` on a multicoin pool:
    /// 2 x (2^63 - 1) = 2^64 - 2.
    const MAX_QTY_AT_MAX_PRICE: u64 = 2;

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
            constants::max_price(),
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

    fun is_resting(test: &mut Scenario, pool_id: ID, trading_account_id: ID, order_id: u128): bool {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let resting = pool.account_open_orders(&ta).contains(&order_id);
        return_shared(ta);
        return_shared(pool);

        resting
    }

    /// The owner's settled base on the pool, before any withdraw.
    fun settled_base(test: &mut Scenario, pool_id: ID, trading_account_id: ID): u64 {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let base = pool.account(&ta).settled_balances().base();
        return_shared(ta);
        return_shared(pool);

        base
    }

    #[test, expected_failure(abort_code = triex::order_info::EOrderValueOverflow)]
    /// The order from the report. Bob holds the base and asks nothing unusual of
    /// the pool except the price, and the placement is refused.
    fun ask_past_the_bound_is_rejected_at_placement() {
        let mut test = begin(OWNER);
        let (f, _collection_cap) = setup(&mut test);

        place(
            &mut test,
            BOB,
            f.pool_id,
            f.bob,
            MAX_QTY_AT_MAX_PRICE + 1,
            false,
            constants::max_u64(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = triex::order_info::EOrderValueOverflow)]
    /// A bid past the bound stops at the same check, before the pool tries to
    /// lock quote for it. It used to abort there instead, inside `math`.
    fun bid_past_the_bound_is_rejected_at_placement() {
        let mut test = begin(OWNER);
        let (f, _collection_cap) = setup(&mut test);

        place(
            &mut test,
            ALICE,
            f.pool_id,
            f.alice,
            MAX_QTY_AT_MAX_PRICE + 1,
            true,
            constants::max_u64(),
        );

        abort 0
    }

    #[test]
    /// The largest ask that can rest at `MAX_PRICE` is an ordinary order from then
    /// on: once it expires a stranger can clean it up, and its base is credited
    /// back to its owner. An ask one unit larger aborted this same call, because
    /// the expiry path values the whole remainder.
    fun largest_valued_ask_rests_and_is_cleaned_up() {
        let mut test = begin(OWNER);
        let (f, collection_cap) = setup(&mut test);
        let expire = mc_utils::get_time(&mut test) + 100;

        let ask = place(&mut test, BOB, f.pool_id, f.bob, MAX_QTY_AT_MAX_PRICE, false, expire);
        assert!(ask.status() == constants::live());
        assert!(ask.order_inserted());
        assert!(is_resting(&mut test, f.pool_id, f.bob, ask.order_id()));
        let base_before = settled_base(&mut test, f.pool_id, f.bob);

        set_clock(expire + 1, &mut test);
        test.next_tx(CHARLIE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(f.pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let removed = pool.clean_expired_orders(
                &policy,
                vector[ask.order_id()],
                &clock,
                test.ctx(),
            );
            assert!(removed == 1);
            return_shared(clock);
            return_shared(policy);
            return_shared(pool);
        };

        assert!(!is_resting(&mut test, f.pool_id, f.bob, ask.order_id()));
        assert!(settled_base(&mut test, f.pool_id, f.bob) - base_before == MAX_QTY_AT_MAX_PRICE);

        unit_test::destroy(collection_cap);
        end(test);
    }
}
