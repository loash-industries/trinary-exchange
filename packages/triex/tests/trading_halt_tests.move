/// The exchange-wide halt (TRIEX-146).
///
/// The kill switch used to be `registry::disable_version`, which reaches a pool
/// only once that pool's cached version set is refreshed — one call per pool,
/// 518 multicoin pools on testnet. `fee_policy::halt_trading` is one admin
/// transaction, and every pool sees it at once because every order already
/// reads the shared `FeePolicy`.
///
/// Pinned here, on both pool kinds:
///
/// - **What a halt blocks:** limit and market orders, swaps with and without a
///   trading account, and permissionless pool creation.
/// - **What it leaves open:** cancel, modify down, cancel all, settled-balance
///   withdrawals (owner and permissionless), expired-order cleanup, turnover
///   folding, operator-share claims, the admin fee sweep, admin pool creation,
///   and read-only quotes. A halt must never trap anyone's funds.
/// - **Resume** reopens trading on the book that rested through the halt.
/// - The flag itself: off at genesis, idempotent, announced only on a change.
#[test_only]
module triex::trading_halt_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test::{assert_eq, destroy};
    use sui::{
        clock::Clock,
        coin::{Self, mint_for_testing},
        coin_registry::Currency,
        event,
        sui::SUI,
        test_scenario::{Scenario, begin, end, return_shared}
    };
    use token::cred::CRED;
    use triex::{
        coin_dec15::{Self, COIN_DEC15},
        coin_dec6::{Self, COIN_DEC6},
        constants,
        fee_policy::{Self, FeePolicy, TradingHaltChanged},
        integration_multicoin_test_utils as mc_utils,
        multicoin_pool::{Self, MultiCoinPool},
        order_info::OrderInfo,
        pool::{Self, Pool},
        pool_test_utils,
        registry::{Self, Registry},
        trading_account::{TradingAccount, TradeCap, DepositCap, WithdrawCap},
        trading_account_tests::{create_acct_and_share_with_funds, create_caps, USDC, USDT, SPAM}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;
    /// Holds no trading account: a stranger to every order.
    const CHARLIE: address = @0xCCCC;
    const HUB: address = @0xB0B;

    /// Expiry for the orders a test retires with `clean_expired_orders`, as an
    /// offset passed to the test utilities' `set_time`.
    const EXPIRE: u64 = 100;
    /// Both `set_time` helpers set the clock to `1_000_000 + t`, so an order's
    /// absolute expiry is this plus `EXPIRE`.
    const CLOCK_BASE: u64 = 1_000_000;

    // === The flag ===

    #[test]
    /// Off at genesis. Halting and resuming flip it, both are idempotent so a
    /// halt can never fail because someone already halted, and only a real
    /// change is announced.
    fun halt_and_resume_flip_the_flag_and_announce_only_changes() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        assert!(!policy.trading_halted());

        policy.halt_trading(&cap);
        assert!(policy.trading_halted());
        let changes = event::events_by_type<TradingHaltChanged>();
        assert_eq!(changes.length(), 1);
        assert!(changes[0].trading_halt_changed_halted());

        test.next_tx(OWNER);
        policy.halt_trading(&cap);
        assert!(policy.trading_halted());
        assert!(event::events_by_type<TradingHaltChanged>().is_empty());

        test.next_tx(OWNER);
        policy.resume_trading(&cap);
        assert!(!policy.trading_halted());
        let changes = event::events_by_type<TradingHaltChanged>();
        assert_eq!(changes.length(), 1);
        assert!(!changes[0].trading_halt_changed_halted());

        test.next_tx(OWNER);
        policy.resume_trading(&cap);
        assert!(!policy.trading_halted());
        assert!(event::events_by_type<TradingHaltChanged>().is_empty());

        destroy(cap);
        destroy(policy);
        end(test);
    }

    fun halt(test: &mut Scenario) {
        test.next_tx(OWNER);
        let mut policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        policy.halt_trading(&cap);
        return_shared(policy);
        destroy(cap);
    }

    fun resume(test: &mut Scenario) {
        test.next_tx(OWNER);
        let mut policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        policy.resume_trading(&cap);
        return_shared(policy);
        destroy(cap);
    }

    // === A coin pool ===

    public struct CoinMarket has drop {
        registry_id: ID,
        pool_id: ID,
        alice: ID,
        bob: ID,
    }

    const PRICE: u64 = 2_000_000_000;
    const QUANTITY: u64 = 1_000_000_000;

    /// A SUI/USDC pool and two accounts funded in every test coin.
    fun coin_market(test: &mut Scenario): CoinMarket {
        let registry_id = pool_test_utils::setup_test(OWNER, test);
        let funds = 1_000_000 * constants::float_scaling();
        let alice = create_acct_and_share_with_funds(ALICE, funds, test);
        let bob = create_acct_and_share_with_funds(BOB, funds, test);
        let pool_id = pool_test_utils::setup_pool_with_default_fees<SUI, USDC>(
            OWNER,
            registry_id,
            test,
        );

        CoinMarket { registry_id, pool_id, alice, bob }
    }

    fun coin_limit(
        test: &mut Scenario,
        trader: address,
        pool_id: ID,
        account: ID,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire: u64,
    ): OrderInfo {
        pool_test_utils::place_limit_order<SUI, USDC>(
            trader,
            pool_id,
            account,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            expire,
            test,
        )
    }

    fun coin_open_orders(test: &mut Scenario, pool_id: ID, account: ID): vector<u128> {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let ta = test.take_shared_by_id<TradingAccount>(account);
        let open = pool.account_open_orders(&ta).into_keys();
        return_shared(ta);
        return_shared(pool);

        open
    }

    #[test, expected_failure(abort_code = fee_policy::ETradingHalted)]
    fun halt_blocks_limit_orders_on_a_coin_pool() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        halt(&mut test);

        coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::ETradingHalted)]
    /// There is liquidity to take; the halt is what stops it.
    fun halt_blocks_market_orders_on_a_coin_pool() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE,
            QUANTITY,
            false,
            constants::max_u64(),
        );
        halt(&mut test);

        pool_test_utils::place_market_order<SUI, USDC>(
            BOB,
            m.pool_id,
            m.bob,
            constants::self_matching_allowed(),
            QUANTITY,
            true,
            &mut test,
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::ETradingHalted)]
    /// The account-less swap mints a temporary trading account and places a
    /// market order through it, so it meets the same check.
    fun halt_blocks_anonymous_swaps_on_a_coin_pool() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
        );
        halt(&mut test);

        test.next_tx(CHARLIE);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let (base, quote, cred) = pool.swap_exact_base_for_quote(
            &policy,
            mint_for_testing<SUI>(QUANTITY, test.ctx()),
            coin::zero<CRED>(test.ctx()),
            0,
            &clock,
            test.ctx(),
        );
        destroy(base);
        destroy(quote);
        destroy(cred);

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::ETradingHalted)]
    fun halt_blocks_swaps_through_a_trading_account_on_a_coin_pool() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
        );
        create_caps(BOB, m.bob, &mut test);
        halt(&mut test);

        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut bob = test.take_shared_by_id<TradingAccount>(m.bob);
        let trade_cap = test.take_from_sender<TradeCap>();
        let deposit_cap = test.take_from_sender<DepositCap>();
        let withdraw_cap = test.take_from_sender<WithdrawCap>();
        let (base, quote) = pool.swap_exact_base_for_quote_with_trading_account(
            &policy,
            &mut bob,
            &trade_cap,
            &deposit_cap,
            &withdraw_cap,
            mint_for_testing<SUI>(QUANTITY, test.ctx()),
            0,
            &clock,
            test.ctx(),
        );
        destroy(base);
        destroy(quote);

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::ETradingHalted)]
    /// One halt reaches a pool nothing touched since it was created: no refresh,
    /// no per-pool step. Here the second of two pools.
    fun one_halt_reaches_a_pool_it_never_touched() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        let second = pool_test_utils::setup_pool_with_default_fees<SPAM, USDC>(
            OWNER,
            m.registry_id,
            &mut test,
        );
        coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
        );
        halt(&mut test);

        pool_test_utils::place_limit_order<SPAM, USDC>(
            ALICE,
            second,
            m.alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
            &mut test,
        );

        abort 0
    }

    #[test]
    /// Why the halt exists. Disabling the running version reaches a pool only
    /// once that pool's cached version set is refreshed with
    /// `update_pool_allowed_versions`, one call per pool. Until then the pool
    /// keeps trading — exactly what the halt above does not allow.
    fun disabling_the_running_version_does_not_reach_an_unrefreshed_pool() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);

        test.next_tx(OWNER);
        {
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            let mut registry = test.take_shared_by_id<Registry>(m.registry_id);
            registry.disable_version(constants::current_version(), &cap);
            return_shared(registry);
            destroy(cap);
        };

        let ask = coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE,
            QUANTITY,
            false,
            constants::max_u64(),
        );
        assert!(ask.order_inserted());
        let bid = coin_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
        );
        assert_eq!(bid.executed_quantity(), QUANTITY);

        end(test);
    }

    /// A registry approving `COIN_DEC6` and a policy pricing it, for the
    /// permissionless `create_permissionless_pool`, which reads decimals off
    /// `Currency` objects.
    fun setup_currency_registry(test: &mut Scenario): ID {
        test.next_tx(OWNER);
        let registry_id = registry::test_registry(test.ctx());
        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        registry.add_approved_quote_unchecked<COIN_DEC6>(&admin_cap);
        return_shared(registry);

        let mut policy = fee_policy::create_for_testing(test.ctx());
        policy.create_class<COIN_DEC6>(
            0,
            vector[0],
            vector[11_000_000],
            vector[9_000_000],
            2_000,
            &admin_cap,
            test.ctx(),
        );
        policy.set_default_class<COIN_DEC6>(0, &admin_cap);
        fee_policy::share_for_testing(policy);
        destroy(admin_cap);
        registry_id
    }

    fun create_permissionless_coin_pool(registry_id: ID, test: &mut Scenario): ID {
        test.next_tx(ALICE);
        let base_currency: Currency<COIN_DEC15> = coin_dec15::currency(test.ctx());
        let quote_currency: Currency<COIN_DEC6> = coin_dec6::currency(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let policy = test.take_shared<FeePolicy>();
        let pool_id = pool::create_permissionless_pool<COIN_DEC15, COIN_DEC6>(
            &mut registry,
            &policy,
            &base_currency,
            &quote_currency,
            mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx()),
            test.ctx(),
        );
        return_shared(registry);
        return_shared(policy);
        destroy(base_currency);
        destroy(quote_currency);

        pool_id
    }

    #[test, expected_failure(abort_code = fee_policy::ETradingHalted)]
    /// A new pool is new exposure: permissionless creation stops with trading.
    fun halt_blocks_permissionless_coin_pool_creation() {
        let mut test = begin(OWNER);
        let registry_id = setup_currency_registry(&mut test);
        halt(&mut test);

        create_permissionless_coin_pool(registry_id, &mut test);

        abort 0
    }

    #[test]
    /// The control for the test above: after a resume the same creation goes
    /// through, so the abort was the halt and nothing else.
    fun resume_reopens_permissionless_coin_pool_creation() {
        let mut test = begin(OWNER);
        let registry_id = setup_currency_registry(&mut test);
        halt(&mut test);
        resume(&mut test);

        let pool_id = create_permissionless_coin_pool(registry_id, &mut test);
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<Pool<COIN_DEC15, COIN_DEC6>>(pool_id);
        assert!(pool.registered_pool());
        return_shared(pool);

        end(test);
    }

    #[test]
    /// A halt stops new exposure, not exits. With trading halted, on a coin pool:
    ///
    /// - a stranger can withdraw an owner's settled proceeds for them, and retire
    ///   an expired order;
    /// - the owner can cancel, modify down, cancel everything and fold turnover;
    /// - the admin can sweep fees and still create a pool;
    /// - read-only quotes still answer.
    fun exits_stay_open_on_a_coin_pool_while_halted() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        pool_test_utils::set_time(0, &mut test);

        // Before the halt: Alice rests an ask that Bob fills, so she has settled
        // proceeds in the pool and the pool has fee revenue, and four bids
        // below it.
        let filled = coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE,
            QUANTITY,
            false,
            constants::max_u64(),
        );
        let to_cancel = coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE / 2,
            QUANTITY,
            true,
            constants::max_u64(),
        );
        let to_modify = coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE / 2,
            2 * QUANTITY,
            true,
            constants::max_u64(),
        );
        let to_keep = coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE / 4,
            QUANTITY,
            true,
            constants::max_u64(),
        );
        let to_expire = coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE / 4,
            QUANTITY,
            true,
            CLOCK_BASE + EXPIRE,
        );
        let taker = coin_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
        );
        assert_eq!(taker.executed_quantity(), QUANTITY);

        let proceeds = {
            test.next_tx(OWNER);
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let alice = test.take_shared_by_id<TradingAccount>(m.alice);
            let settled = pool.account(&alice).settled_balances().quote();
            assert!(settled > 0);
            return_shared(alice);
            return_shared(pool);
            settled
        };

        halt(&mut test);

        // Reads still answer: a quote for selling into Alice's bids.
        test.next_tx(CHARLIE);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            assert!(policy.trading_halted());
            let (_, quote_out) = pool.get_quantity_out(&policy, QUANTITY, 0, &clock, test.ctx());
            assert!(quote_out > 0);
            return_shared(clock);
            return_shared(policy);
            return_shared(pool);
        };

        // A stranger withdraws Alice's settled proceeds into her account.
        test.next_tx(CHARLIE);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let mut alice = test.take_shared_by_id<TradingAccount>(m.alice);
            let before = alice.balance<USDC>();
            pool.withdraw_settled_amounts_permissionless(&mut alice);
            assert_eq!(alice.balance<USDC>() - before, proceeds);
            assert_eq!(pool.account(&alice).settled_balances().quote(), 0);
            return_shared(alice);
            return_shared(pool);
        };

        // The owner cancels one order and modifies another down.
        pool_test_utils::cancel_order<SUI, USDC>(
            ALICE,
            m.pool_id,
            m.alice,
            to_cancel.order_id(),
            &mut test,
        );
        pool_test_utils::modify_order<SUI, USDC>(
            ALICE,
            m.pool_id,
            m.alice,
            to_modify.order_id(),
            QUANTITY,
            &mut test,
        );
        let open = coin_open_orders(&mut test, m.pool_id, m.alice);
        assert!(!open.contains(&to_cancel.order_id()));
        assert!(open.contains(&to_modify.order_id()));
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            assert_eq!(pool.get_order(to_modify.order_id()).quantity(), QUANTITY);
            return_shared(pool);
        };

        // Once expired, a stranger retires the expiring bid.
        pool_test_utils::set_time(EXPIRE + 1, &mut test);
        test.next_tx(CHARLIE);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let clock = test.take_shared<Clock>();
            assert_eq!(
                pool.clean_expired_orders(vector[to_expire.order_id()], &clock, test.ctx()),
                1,
            );
            return_shared(clock);
            return_shared(pool);
        };

        // The owner folds turnover and cancels everything left.
        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let mut alice = test.take_shared_by_id<TradingAccount>(m.alice);
            pool.fold_pending_turnover(&mut alice, test.ctx());
            return_shared(alice);
            return_shared(pool);
        };
        pool_test_utils::cancel_all_orders<SUI, USDC>(m.pool_id, ALICE, m.alice, &mut test);
        assert!(coin_open_orders(&mut test, m.pool_id, m.alice).is_empty());
        let _ = filled;
        let _ = to_keep;

        // The admin sweeps the fee revenue and can still create a pool.
        test.next_tx(OWNER);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let clock = test.take_shared<Clock>();
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            let revenue = pool.withdrawable_pool_fees();
            assert!(revenue > 0);
            let fees = pool.withdraw_pool_fees(&cap, revenue, &clock, test.ctx());
            assert_eq!(fees.value(), revenue);
            destroy(fees);
            destroy(cap);
            return_shared(clock);
            return_shared(pool);
        };
        pool_test_utils::setup_pool_with_default_fees<SUI, USDT>(OWNER, m.registry_id, &mut test);

        end(test);
    }

    #[test]
    /// Resuming reopens trading on the book that rested through the halt.
    fun resume_reopens_trading_on_a_coin_pool() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        let ask = coin_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            PRICE,
            QUANTITY,
            false,
            constants::max_u64(),
        );
        halt(&mut test);
        resume(&mut test);

        let bid = coin_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
        );
        assert_eq!(bid.executed_quantity(), QUANTITY);
        assert!(!coin_open_orders(&mut test, m.pool_id, m.alice).contains(&ask.order_id()));

        end(test);
    }

    // === A multicoin pool ===

    public struct MulticoinMarket has drop {
        registry_id: ID,
        collection_id: ID,
        pool_id: ID,
        alice: ID,
        bob: ID,
    }

    const ASSET_GOLD: u64 = 1;
    const ASSET_IRON: u64 = 3;
    const MC_PRICE: u64 = 2_000_000_000;
    const MC_QUANTITY: u64 = 100;

    /// A multicoin GOLD pool quoted in USDC, with Alice funded in quote and Bob
    /// in quote and GOLD.
    fun multicoin_market(test: &mut Scenario): (MulticoinMarket, CollectionCap) {
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

        (MulticoinMarket { registry_id, collection_id, pool_id, alice, bob }, collection_cap)
    }

    fun mc_limit(
        test: &mut Scenario,
        trader: address,
        pool_id: ID,
        account: ID,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire: u64,
    ): OrderInfo {
        test.next_tx(trader);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(account);
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
            expire,
            &clock,
            test.ctx(),
        );
        return_shared(ta);
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);

        order_info
    }

    fun mc_open_orders(test: &mut Scenario, pool_id: ID, account: ID): vector<u128> {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let ta = test.take_shared_by_id<TradingAccount>(account);
        let open = pool.account_open_orders(&ta).into_keys();
        return_shared(ta);
        return_shared(pool);

        open
    }

    #[test, expected_failure(abort_code = fee_policy::ETradingHalted)]
    fun halt_blocks_limit_orders_on_a_multicoin_pool() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);
        halt(&mut test);

        mc_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            MC_PRICE,
            MC_QUANTITY,
            false,
            constants::max_u64(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::ETradingHalted)]
    fun halt_blocks_market_orders_on_a_multicoin_pool() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);
        mc_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            MC_PRICE,
            MC_QUANTITY,
            false,
            constants::max_u64(),
        );
        halt(&mut test);

        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(m.alice);
        let proof = ta.generate_proof_as_owner(test.ctx());
        pool.place_market_order(
            &policy,
            &mut ta,
            &proof,
            constants::self_matching_allowed(),
            MC_QUANTITY,
            true,
            &clock,
            test.ctx(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::ETradingHalted)]
    fun halt_blocks_anonymous_swaps_on_a_multicoin_pool() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);
        mc_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            MC_PRICE,
            MC_QUANTITY,
            false,
            constants::max_u64(),
        );
        halt(&mut test);

        test.next_tx(CHARLIE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let (base, quote, cred) = pool.swap_exact_quote_for_base(
            &policy,
            mint_for_testing<USDC>(1_000 * MC_PRICE, test.ctx()),
            coin::zero<CRED>(test.ctx()),
            0,
            &clock,
            test.ctx(),
        );
        destroy(base);
        destroy(quote);
        destroy(cred);

        abort 0
    }

    fun create_permissionless_multicoin_pool(registry_id: ID, test: &mut Scenario): ID {
        test.next_tx(ALICE);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let policy = test.take_shared<FeePolicy>();
        let collection = test.take_shared<Collection>();
        let pool_id = multicoin_pool::create_permissionless_pool<USDC>(
            &mut registry,
            &policy,
            &collection,
            ASSET_IRON,
            mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx()),
            test.ctx(),
        );
        return_shared(collection);
        return_shared(policy);
        return_shared(registry);

        pool_id
    }

    #[test, expected_failure(abort_code = fee_policy::ETradingHalted)]
    fun halt_blocks_permissionless_multicoin_pool_creation() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);
        halt(&mut test);

        create_permissionless_multicoin_pool(m.registry_id, &mut test);

        abort 0
    }

    #[test]
    fun resume_reopens_permissionless_multicoin_pool_creation() {
        let mut test = begin(OWNER);
        let (m, collection_cap) = multicoin_market(&mut test);
        halt(&mut test);
        resume(&mut test);

        let pool_id = create_permissionless_multicoin_pool(m.registry_id, &mut test);
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        assert!(pool.registered_pool());
        return_shared(pool);

        destroy(collection_cap);
        end(test);
    }

    #[test]
    /// The same exits on a multicoin pool, plus the hub operator's claim: with
    /// trading halted the accrued share still pays out to the registered
    /// beneficiary, and the treasury its remainder.
    fun exits_stay_open_on_a_multicoin_pool_while_halted() {
        let mut test = begin(OWNER);
        let (m, collection_cap) = multicoin_market(&mut test);
        mc_utils::set_time(0, &mut test);

        // Before the halt: Bob rests asks above the one Alice fills, so Bob has
        // settled proceeds, the hub has a share owed, and the pool has revenue.
        let _filled = mc_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            MC_PRICE,
            MC_QUANTITY,
            false,
            constants::max_u64(),
        );
        let to_cancel = mc_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            2 * MC_PRICE,
            MC_QUANTITY,
            false,
            constants::max_u64(),
        );
        let to_modify = mc_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            2 * MC_PRICE,
            2 * MC_QUANTITY,
            false,
            constants::max_u64(),
        );
        let _to_keep = mc_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            3 * MC_PRICE,
            MC_QUANTITY,
            false,
            constants::max_u64(),
        );
        let to_expire = mc_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            3 * MC_PRICE,
            MC_QUANTITY,
            false,
            CLOCK_BASE + EXPIRE,
        );
        let taker = mc_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            MC_PRICE,
            MC_QUANTITY,
            true,
            constants::max_u64(),
        );
        assert_eq!(taker.executed_quantity(), MC_QUANTITY);

        test.next_tx(OWNER);
        {
            let mut policy = test.take_shared<FeePolicy>();
            policy.register_operator_beneficiary_for_testing(m.collection_id, HUB);
            return_shared(policy);
        };
        let (proceeds, owed) = {
            test.next_tx(OWNER);
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
            let bob = test.take_shared_by_id<TradingAccount>(m.bob);
            let settled = pool.account(&bob).settled_balances().quote();
            let owed = pool.operator_owed();
            assert!(settled > 0);
            assert!(owed > 0);
            return_shared(bob);
            return_shared(pool);
            (settled, owed)
        };

        halt(&mut test);

        // A stranger withdraws Bob's settled proceeds into his account.
        test.next_tx(CHARLIE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
            let mut bob = test.take_shared_by_id<TradingAccount>(m.bob);
            let before = bob.balance<USDC>();
            pool.withdraw_settled_amounts_permissionless(&mut bob, test.ctx());
            assert_eq!(bob.balance<USDC>() - before, proceeds);
            return_shared(bob);
            return_shared(pool);
        };

        // The owner cancels one ask and modifies another down.
        test.next_tx(BOB);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bob = test.take_shared_by_id<TradingAccount>(m.bob);
            let proof = bob.generate_proof_as_owner(test.ctx());
            pool.cancel_order(&policy, &mut bob, &proof, to_cancel.order_id(), &clock, test.ctx());
            pool.modify_order(
                &policy,
                &mut bob,
                &proof,
                to_modify.order_id(),
                MC_QUANTITY,
                &clock,
                test.ctx(),
            );
            assert_eq!(pool.get_order(to_modify.order_id()).quantity(), MC_QUANTITY);
            return_shared(bob);
            return_shared(clock);
            return_shared(policy);
            return_shared(pool);
        };
        assert!(!mc_open_orders(&mut test, m.pool_id, m.bob).contains(&to_cancel.order_id()));

        // Once expired, a stranger retires the expiring ask.
        mc_utils::set_time(EXPIRE + 1, &mut test);
        test.next_tx(CHARLIE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let removed = pool.clean_expired_orders(
                &policy,
                vector[to_expire.order_id()],
                &clock,
                test.ctx(),
            );
            assert_eq!(removed, 1);
            return_shared(clock);
            return_shared(policy);
            return_shared(pool);
        };

        // The owner folds turnover and cancels everything left.
        test.next_tx(BOB);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bob = test.take_shared_by_id<TradingAccount>(m.bob);
            let proof = bob.generate_proof_as_owner(test.ctx());
            pool.fold_pending_turnover(&mut bob, test.ctx());
            pool.cancel_all_orders(&policy, &mut bob, &proof, &clock, test.ctx());
            return_shared(bob);
            return_shared(clock);
            return_shared(policy);
            return_shared(pool);
        };
        assert!(mc_open_orders(&mut test, m.pool_id, m.bob).is_empty());

        // Anyone runs the claim: the hub is paid what it was owed.
        test.next_tx(CHARLIE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
            let policy = test.take_shared<FeePolicy>();
            let registry = test.take_shared_by_id<Registry>(m.registry_id);
            let clock = test.take_shared<Clock>();
            let (hub_paid, treasury_paid) = pool.claim_operator_share(
                &policy,
                &registry,
                &clock,
                test.ctx(),
            );
            assert_eq!(hub_paid, owed);
            assert!(treasury_paid > 0);
            assert_eq!(pool.operator_owed(), 0);
            return_shared(clock);
            return_shared(registry);
            return_shared(policy);
            return_shared(pool);
        };

        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun resume_reopens_trading_on_a_multicoin_pool() {
        let mut test = begin(OWNER);
        let (m, collection_cap) = multicoin_market(&mut test);
        let ask = mc_limit(
            &mut test,
            BOB,
            m.pool_id,
            m.bob,
            MC_PRICE,
            MC_QUANTITY,
            false,
            constants::max_u64(),
        );
        halt(&mut test);
        resume(&mut test);

        let bid = mc_limit(
            &mut test,
            ALICE,
            m.pool_id,
            m.alice,
            MC_PRICE,
            MC_QUANTITY,
            true,
            constants::max_u64(),
        );
        assert_eq!(bid.executed_quantity(), MC_QUANTITY);
        assert!(!mc_open_orders(&mut test, m.pool_id, m.bob).contains(&ask.order_id()));

        destroy(collection_cap);
        end(test);
    }
}
