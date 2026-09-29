#[test_only]
module triex::multicoin_pool_coverage_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test::{assert_eq, destroy};
    use sui::{
        clock::Clock,
        coin::{Self, mint_for_testing},
        test_scenario::{Scenario, begin, end, return_shared}
    };
    use token::cred::CRED;
    use triex::{
        constants,
        fee_policy::FeePolicy,
        integration_multicoin_test_utils as mc_utils,
        multicoin_pool::{Self, MultiCoinPool},
        pool_test_utils,
        registry::{Self, Registry},
        trading_account::{TradingAccount, TradeCap, DepositCap, WithdrawCap},
        trading_account_tests::{create_caps, USDC}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    const ASSET_GOLD: u64 = 1;
    const QTY: u64 = 100;

    public struct Env has drop {
        registry_id: ID,
        collection_id: ID,
        pool_id: ID,
        alice_id: ID,
        bob_id: ID,
    }

    /// A USDC multicoin pool with funded accounts for ALICE and BOB.
    fun setup(test: &mut Scenario): (Env, CollectionCap) {
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
        let alice_id = mc_utils::create_trading_account_with_funds(ALICE, funds, funds, test);
        let bob_id = mc_utils::create_trading_account_with_funds(BOB, funds, funds, test);
        (Env { registry_id, collection_id, pool_id, alice_id, bob_id }, collection_cap)
    }

    fun deposit_gold(
        owner: address,
        account_id: ID,
        amount: u64,
        collection_cap: &CollectionCap,
        test: &mut Scenario,
    ) {
        test.next_tx(owner);
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            collection_cap,
            &mut collection,
            ASSET_GOLD,
            amount,
            test.ctx(),
        );
        let mut account = test.take_shared_by_id<TradingAccount>(account_id);
        account.deposit_multicoin(gold, test.ctx());
        return_shared(account);
        return_shared(collection);
    }

    fun place(trader: address, env: &Env, account_id: ID, is_bid: bool, test: &mut Scenario): u128 {
        test.next_tx(trader);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut account = test.take_shared_by_id<TradingAccount>(account_id);
        let proof = account.generate_proof_as_owner(test.ctx());
        let order_id = pool
            .place_limit_order(
                &policy,
                &mut account,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                2 * constants::float_scaling(),
                QTY,
                is_bid,
                constants::max_u64(),
                &clock,
                test.ctx(),
            )
            .order_id();
        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(account);
        order_id
    }

    #[test]
    /// Read-side getters on a pool holding a single resting bid.
    fun getters_reflect_resting_bid() {
        let mut test = begin(OWNER);
        let (env, collection_cap) = setup(&mut test);
        let order_id = place(ALICE, &env, env.alice_id, true, &mut test);

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let alice = test.take_shared_by_id<TradingAccount>(env.alice_id);

        assert_eq!(pool.id(), env.pool_id);
        assert_eq!(pool.pool_fee_class(), pool_test_utils::multicoin_class<USDC>());
        let (taker, maker) = pool.pool_trade_params(&policy, test.ctx());
        assert_eq!(taker, pool_test_utils::default_taker_fee_multicoin());
        assert_eq!(maker, pool_test_utils::default_maker_fee_multicoin());
        assert!(pool.account(&alice).open_orders().contains(&order_id));

        let (low, high) = (constants::min_price(), constants::max_price());
        let (prices, quantities) = pool.get_level2_range(low, high, true, &clock);
        assert_eq!(prices, vector[2 * constants::float_scaling()]);
        assert_eq!(quantities, vector[QTY]);
        let (prices, _) = pool.get_level2_range(low, high, false, &clock);
        assert!(prices.is_empty());

        let inner = pool.load_inner();
        assert_eq!(inner.bids().length(), 0);
        assert_eq!(inner.asks().length(), 0);
        assert_eq!(inner.book().side_length(true), 1);

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(alice);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    /// An account that never touched the pool has no orders and nothing locked.
    fun untouched_account_has_no_orders_or_locked_balance() {
        let mut test = begin(OWNER);
        let (env, collection_cap) = setup(&mut test);

        test.next_tx(BOB);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        let bob = test.take_shared_by_id<TradingAccount>(env.bob_id);
        assert!(pool.account_open_orders(&bob).is_empty());
        let (base, quote, cred) = pool.locked_balance(&bob);
        assert_eq!(base, 0);
        assert_eq!(quote, 0);
        assert_eq!(cred, 0);
        return_shared(pool);
        return_shared(bob);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    /// Anyone can sweep a filled maker's settled base into their account.
    fun withdraw_settled_amounts_permissionless_ok() {
        let mut test = begin(OWNER);
        let (env, collection_cap) = setup(&mut test);
        place(ALICE, &env, env.alice_id, true, &mut test);
        deposit_gold(BOB, env.bob_id, QTY, &collection_cap, &mut test);
        place(BOB, &env, env.bob_id, false, &mut test);

        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        let mut alice = test.take_shared_by_id<TradingAccount>(env.alice_id);
        assert_eq!(alice.multicoin_balance(env.collection_id, ASSET_GOLD), 0);
        pool.withdraw_settled_amounts_permissionless(&mut alice, test.ctx());
        assert_eq!(alice.multicoin_balance(env.collection_id, ASSET_GOLD), QTY);
        let (base, _, _) = pool.locked_balance(&alice);
        assert_eq!(base, 0);
        return_shared(pool);
        return_shared(alice);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    /// Reassigning the class switches the entry rung the pool quotes.
    fun set_pool_fee_class_ok() {
        let mut test = begin(OWNER);
        let (env, collection_cap) = setup(&mut test);

        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        let policy = test.take_shared<FeePolicy>();
        pool.set_pool_fee_class(&policy, pool_test_utils::standard_class<USDC>(), &admin_cap);
        assert_eq!(pool.pool_fee_class(), pool_test_utils::standard_class<USDC>());
        let (taker, maker) = pool.pool_trade_params(&policy, test.ctx());
        assert_eq!(taker, pool_test_utils::default_taker_fee());
        assert_eq!(maker, pool_test_utils::default_maker_fee());
        return_shared(pool);
        return_shared(policy);
        destroy(admin_cap);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    /// Halted permissionlessly, restored by the admin once the version is re-enabled.
    fun update_allowed_versions_recovers_pool() {
        let mut test = begin(OWNER);
        let (env, collection_cap) = setup(&mut test);

        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(env.registry_id);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        registry.disable_version(constants::current_version(), &admin_cap);
        pool.update_pool_allowed_versions(&registry);
        registry.enable_version(constants::current_version(), &admin_cap);
        pool.update_allowed_versions(&registry, &admin_cap);
        assert_eq!(pool.id(), env.pool_id);
        return_shared(registry);
        return_shared(pool);
        destroy(admin_cap);
        destroy(collection_cap);
        end(test);
    }

    fun disable_pool(env: &Env, test: &mut Scenario) {
        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(env.registry_id);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        registry.disable_version(constants::current_version(), &admin_cap);
        pool.update_pool_allowed_versions(&registry);
        return_shared(registry);
        return_shared(pool);
        destroy(admin_cap);
    }

    #[test, expected_failure(abort_code = multicoin_pool::EPackageVersionDisabled)]
    fun reading_a_disabled_pool_e() {
        let mut test = begin(OWNER);
        let (env, _collection_cap) = setup(&mut test);
        disable_pool(&env, &mut test);

        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        pool.id();
        abort 0
    }

    #[test, expected_failure(abort_code = multicoin_pool::EPackageVersionDisabled)]
    fun mutating_a_disabled_pool_e() {
        let mut test = begin(OWNER);
        let (env, _collection_cap) = setup(&mut test);
        disable_pool(&env, &mut test);

        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        let policy = test.take_shared<FeePolicy>();
        pool.set_pool_fee_class(&policy, pool_test_utils::standard_class<USDC>(), &admin_cap);
        abort 0
    }

    #[test, expected_failure(abort_code = multicoin_pool::EInvalidQuantityIn)]
    fun swap_exact_base_for_quote_zero_input_e() {
        let mut test = begin(OWNER);
        let (env, _collection_cap) = setup(&mut test);

        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let (base, quote, cred) = pool.swap_exact_base_for_quote(
            &policy,
            multicoin::zero(env.collection_id, ASSET_GOLD, test.ctx()),
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

    #[test, expected_failure(abort_code = multicoin_pool::EInvalidQuantityIn)]
    fun swap_exact_quote_for_base_with_trading_account_zero_input_e() {
        let mut test = begin(OWNER);
        let (env, _collection_cap) = setup(&mut test);
        create_caps(ALICE, env.alice_id, &mut test);

        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut alice = test.take_shared_by_id<TradingAccount>(env.alice_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let deposit_cap = test.take_from_sender<DepositCap>();
        let withdraw_cap = test.take_from_sender<WithdrawCap>();
        let (base, quote) = pool.swap_exact_quote_for_base_with_trading_account(
            &policy,
            &mut alice,
            &trade_cap,
            &deposit_cap,
            &withdraw_cap,
            mint_for_testing<USDC>(0, test.ctx()),
            0,
            &clock,
            test.ctx(),
        );
        destroy(base);
        destroy(quote);
        abort 0
    }

    #[test, expected_failure(abort_code = multicoin_pool::EInvalidOrderTradingAccount)]
    fun cancel_order_of_another_account_e() {
        let mut test = begin(OWNER);
        let (env, _collection_cap) = setup(&mut test);
        let order_id = place(ALICE, &env, env.alice_id, true, &mut test);

        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut bob = test.take_shared_by_id<TradingAccount>(env.bob_id);
        let proof = bob.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&policy, &mut bob, &proof, order_id, &clock, test.ctx());
        abort 0
    }

    #[test, expected_failure(abort_code = multicoin_pool::EInvalidOrderTradingAccount)]
    fun modify_order_of_another_account_e() {
        let mut test = begin(OWNER);
        let (env, _collection_cap) = setup(&mut test);
        let order_id = place(ALICE, &env, env.alice_id, true, &mut test);

        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut bob = test.take_shared_by_id<TradingAccount>(env.bob_id);
        let proof = bob.generate_proof_as_owner(test.ctx());
        pool.modify_order(&policy, &mut bob, &proof, order_id, QTY / 2, &clock, test.ctx());
        abort 0
    }

    #[test]
    /// Batch cancels of asks retain nothing, so they skip fee recognition entirely.
    fun batch_cancels_without_retention() {
        let mut test = begin(OWNER);
        let (env, collection_cap) = setup(&mut test);
        deposit_gold(ALICE, env.alice_id, 2 * QTY, &collection_cap, &mut test);
        let first = place(ALICE, &env, env.alice_id, false, &mut test);
        place(ALICE, &env, env.alice_id, false, &mut test);

        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(env.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut alice = test.take_shared_by_id<TradingAccount>(env.alice_id);
        let proof = alice.generate_proof_as_owner(test.ctx());
        let locked_before = pool.locked_maker_fees();

        pool.cancel_orders(&policy, &mut alice, &proof, vector[], &clock, test.ctx());
        assert_eq!(pool.account_open_orders(&alice).length(), 2);

        pool.cancel_orders(&policy, &mut alice, &proof, vector[first], &clock, test.ctx());
        assert_eq!(pool.account_open_orders(&alice).length(), 1);

        pool.cancel_all_orders(&policy, &mut alice, &proof, &clock, test.ctx());
        assert!(pool.account_open_orders(&alice).is_empty());
        assert_eq!(pool.locked_maker_fees(), locked_before);
        assert_eq!(pool.withdrawable_pool_fees(), 0);

        pool.withdraw_settled_amounts(&mut alice, &proof, test.ctx());
        assert_eq!(alice.multicoin_balance(env.collection_id, ASSET_GOLD), 2 * QTY);

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(alice);
        destroy(collection_cap);
        end(test);
    }
}
