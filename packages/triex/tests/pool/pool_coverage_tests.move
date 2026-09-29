#[test_only]
module triex::pool_coverage_tests {
    use std::unit_test::{assert_eq, destroy};
    use sui::{
        clock::Clock,
        coin::{Self, Coin, mint_for_testing},
        coin_registry::Currency,
        sui::SUI,
        test_scenario::{Scenario, begin, end, return_shared}
    };
    use token::cred::CRED;
    use triex::{
        coin_dec15::{Self, COIN_DEC15},
        coin_dec6::{Self, COIN_DEC6},
        constants,
        fee_policy::{Self, FeePolicy},
        pool::{Self, Pool},
        pool_test_utils,
        registry::{Self, Registry},
        trading_account::{TradingAccount, TradeCap, DepositCap, WithdrawCap},
        trading_account_tests::{create_acct_and_share_with_funds, create_caps, USDC}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    /// Registry, clock and policy, one SUI/USDC pool, and a funded account for ALICE.
    fun setup_pool(test: &mut Scenario): (ID, ID, ID) {
        let registry_id = pool_test_utils::setup_test(OWNER, test);
        let alice_id = create_acct_and_share_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees<SUI, USDC>(
            OWNER,
            registry_id,
            test,
        );
        (registry_id, pool_id, alice_id)
    }

    fun place_alice_order(pool_id: ID, alice_id: ID, is_bid: bool, test: &mut Scenario): u128 {
        pool_test_utils::place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            alice_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            1 * constants::float_scaling(),
            is_bid,
            constants::max_u64(),
            test,
        ).order_id()
    }

    /// A registry approving `COIN_DEC6` as a quote, and a policy pricing it.
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

    fun create_permissionless_from_currency(fee: u64, test: &mut Scenario): ID {
        let registry_id = setup_currency_registry(test);
        test.next_tx(OWNER);
        let base_currency: Currency<COIN_DEC15> = coin_dec15::currency(test.ctx());
        let quote_currency: Currency<COIN_DEC6> = coin_dec6::currency(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let policy = test.take_shared<FeePolicy>();
        let pool_id = pool::create_permissionless_pool<COIN_DEC15, COIN_DEC6>(
            &mut registry,
            &policy,
            &base_currency,
            &quote_currency,
            mint_for_testing<CRED>(fee, test.ctx()),
            test.ctx(),
        );
        assert_eq!(pool::get_pool_id_by_asset<COIN_DEC15, COIN_DEC6>(&registry), pool_id);
        return_shared(registry);
        return_shared(policy);
        destroy(base_currency);
        destroy(quote_currency);
        pool_id
    }

    #[test]
    /// The permissionless path registers the pool and pays the fee to the treasury.
    fun create_permissionless_pool_from_currency_ok() {
        let mut test = begin(OWNER);
        let pool_id = create_permissionless_from_currency(
            constants::pool_creation_fee(),
            &mut test,
        );

        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<Pool<COIN_DEC15, COIN_DEC6>>(pool_id);
        assert_eq!(pool.id(), pool_id);
        assert_eq!(pool.pool_fee_class(), 0);
        assert!(pool.registered_pool());
        return_shared(pool);
        let fee = test.take_from_address<Coin<CRED>>(OWNER);
        assert_eq!(fee.value(), constants::pool_creation_fee());
        destroy(fee);
        end(test);
    }

    #[test, expected_failure(abort_code = pool::EInvalidFee)]
    fun create_permissionless_pool_wrong_fee_e() {
        let mut test = begin(OWNER);
        create_permissionless_from_currency(constants::pool_creation_fee() + 1, &mut test);
        end(test);
    }

    #[test, expected_failure(abort_code = pool::ESameBaseAndQuote)]
    fun create_pool_same_base_and_quote_e() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        pool_test_utils::setup_pool_with_default_fees<USDC, USDC>(OWNER, registry_id, &mut test);
        end(test);
    }

    #[test]
    /// Reassigning the class switches the entry rung the pool quotes.
    fun set_pool_fee_class_ok() {
        let mut test = begin(OWNER);
        let (_, pool_id, _) = setup_pool(&mut test);

        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        assert_eq!(pool.pool_fee_class(), pool_test_utils::standard_class<USDC>());
        pool.set_pool_fee_class(&policy, pool_test_utils::multicoin_class<USDC>(), &admin_cap);
        assert_eq!(pool.pool_fee_class(), pool_test_utils::multicoin_class<USDC>());
        let (taker, maker) = pool.pool_trade_params(&policy, test.ctx());
        assert_eq!(taker, pool_test_utils::default_taker_fee_multicoin());
        assert_eq!(maker, pool_test_utils::default_maker_fee_multicoin());
        return_shared(pool);
        return_shared(policy);
        destroy(admin_cap);
        end(test);
    }

    #[test]
    /// A pool halted by the kill switch resumes once the version is re-enabled.
    fun update_allowed_versions_recovers_pool() {
        let mut test = begin(OWNER);
        let (registry_id, pool_id, _) = setup_pool(&mut test);

        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        registry.disable_version(constants::current_version(), &admin_cap);
        pool.update_allowed_versions(&registry, &admin_cap);
        registry.enable_version(constants::current_version(), &admin_cap);
        pool.update_allowed_versions(&registry, &admin_cap);
        assert_eq!(pool.id(), pool_id);
        return_shared(registry);
        return_shared(pool);
        destroy(admin_cap);
        end(test);
    }

    #[test, expected_failure(abort_code = pool::EPackageVersionDisabled)]
    fun mutating_a_disabled_pool_e() {
        let mut test = begin(OWNER);
        let (registry_id, pool_id, _) = setup_pool(&mut test);

        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        registry.disable_version(constants::current_version(), &admin_cap);
        pool.update_allowed_versions(&registry, &admin_cap);
        pool.set_pool_fee_class(&policy, pool_test_utils::standard_class<USDC>(), &admin_cap);
        abort 0
    }

    #[test, expected_failure(abort_code = pool::EPoolNotRegistered)]
    fun unregister_pool_twice_e() {
        let mut test = begin(OWNER);
        let (registry_id, pool_id, _) = setup_pool(&mut test);
        pool_test_utils::unregister_pool<SUI, USDC>(pool_id, registry_id, &mut test);
        pool_test_utils::unregister_pool<SUI, USDC>(pool_id, registry_id, &mut test);
        end(test);
    }

    #[test]
    /// A lone ask rests in the inline buffer, leaving the cold ask tree empty.
    fun single_ask_stays_out_of_cold_tree() {
        let mut test = begin(OWNER);
        let (_, pool_id, alice_id) = setup_pool(&mut test);
        place_alice_order(pool_id, alice_id, false, &mut test);

        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let inner = pool.load_inner();
        assert_eq!(inner.asks().length(), 0);
        assert_eq!(inner.book().side_length(false), 1);
        return_shared(pool);
        end(test);
    }

    #[test, expected_failure(abort_code = pool::EInvalidQuantityIn)]
    fun swap_exact_quantity_with_no_input_e() {
        let mut test = begin(OWNER);
        let (_, pool_id, _) = setup_pool(&mut test);

        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let (base, quote, cred) = pool.swap_exact_quantity(
            &policy,
            coin::zero<SUI>(test.ctx()),
            coin::zero<USDC>(test.ctx()),
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

    #[test, expected_failure(abort_code = pool::EInvalidQuantityIn)]
    fun swap_exact_quantity_with_trading_account_both_inputs_e() {
        let mut test = begin(OWNER);
        let (_, pool_id, alice_id) = setup_pool(&mut test);
        create_caps(ALICE, alice_id, &mut test);

        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut account = test.take_shared_by_id<TradingAccount>(alice_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let deposit_cap = test.take_from_sender<DepositCap>();
        let withdraw_cap = test.take_from_sender<WithdrawCap>();
        let (base, quote) = pool.swap_exact_quantity_with_trading_account(
            &policy,
            &mut account,
            &trade_cap,
            &deposit_cap,
            &withdraw_cap,
            mint_for_testing<SUI>(constants::float_scaling(), test.ctx()),
            mint_for_testing<USDC>(constants::float_scaling(), test.ctx()),
            0,
            &clock,
            test.ctx(),
        );
        destroy(base);
        destroy(quote);
        abort 0
    }

    #[test, expected_failure(abort_code = pool::EInvalidOrderTradingAccount)]
    fun cancel_order_of_another_account_e() {
        let mut test = begin(OWNER);
        let (_, pool_id, alice_id) = setup_pool(&mut test);
        let bob_id = create_acct_and_share_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let order_id = place_alice_order(pool_id, alice_id, true, &mut test);
        pool_test_utils::cancel_order<SUI, USDC>(BOB, pool_id, bob_id, order_id, &mut test);
        end(test);
    }

    #[test, expected_failure(abort_code = pool::EInvalidOrderTradingAccount)]
    fun modify_order_of_another_account_e() {
        let mut test = begin(OWNER);
        let (_, pool_id, alice_id) = setup_pool(&mut test);
        let bob_id = create_acct_and_share_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let order_id = place_alice_order(pool_id, alice_id, true, &mut test);
        pool_test_utils::modify_order<SUI, USDC>(
            BOB,
            pool_id,
            bob_id,
            order_id,
            constants::float_scaling() / 2,
            &mut test,
        );
        end(test);
    }
}
