/// The version gate (TRIEX-146).
///
/// `FeePolicy` carries the set of package versions allowed past the gate, kept
/// equal to the registry's because `fee_policy::enable_version` and
/// `disable_version` are the only writers of either. Retiring a version stops,
/// in one transaction:
///
/// - every `TradingAccount` entry point that creates an account, moves funds,
///   mints or revokes a cap, or makes a proof;
/// - every write to `FeePolicy` except `halt_trading`;
/// - new exposure on every pool, refreshed or not: orders, swaps and
///   permissionless pool creation all pass `assert_trading_live`.
///
/// What a retired version keeps is a pool whose cached set has not been
/// refreshed: permissionless settlement and expired-order cleanup there, until
/// `update_pool_allowed_versions` runs for it. Views answer throughout.
///
/// A test runs one package version, so "retired" here always means the running
/// one: these tests see the exchange through the code an upgrade has left behind.
#[test_only]
module triex::version_gate_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test::{assert_eq, destroy};
    use sui::{
        clock::Clock,
        coin::{Self, mint_for_testing},
        coin_registry::Currency,
        sui::SUI,
        test_scenario::{Scenario, begin, end, return_shared},
        vec_set
    };
    use token::cred::CRED;
    use triex::{
        coin_dec15::{Self, COIN_DEC15},
        coin_dec6::{Self, COIN_DEC6},
        constants,
        fee_policy::{Self, FeePolicy, OperatorPayouts},
        integration_multicoin_test_utils as mc_utils,
        multicoin_pool::{Self, MultiCoinPool},
        pool::{Self, Pool},
        pool_test_utils,
        registry::{Self, Registry},
        trading_account::{Self, TradingAccount, TradeCap, DepositCap, WithdrawCap},
        trading_account_tests::{create_acct_and_share_with_funds, create_caps, USDC, USDT}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;
    /// Holds no trading account: a stranger to every order.
    const CHARLIE: address = @0xCCCC;

    const FUNDS: u64 = 1_000_000_000_000_000;
    const PRICE: u64 = 2_000_000_000;
    const QUANTITY: u64 = 1_000_000_000;

    // === Switches ===

    fun set_version(test: &mut Scenario, version: u64, enabled: bool) {
        test.next_tx(OWNER);
        let mut policy = test.take_shared<FeePolicy>();
        let mut registry = test.take_shared<Registry>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        if (enabled) policy.enable_version(&mut registry, version, &cap)
        else policy.disable_version(&mut registry, version, &cap);
        destroy(cap);
        return_shared(registry);
        return_shared(policy);
    }

    /// Retire the running version, as an upgrade's follow-up would retire the
    /// version it replaced.
    fun retire(test: &mut Scenario) {
        set_version(test, constants::current_version(), false);
    }

    fun assert_sets(test: &mut Scenario, expected: vector<u64>) {
        test.next_tx(OWNER);
        let policy = test.take_shared<FeePolicy>();
        let registry = test.take_shared<Registry>();
        assert_eq!(policy.allowed_versions().into_keys(), expected);
        assert_eq!(registry.allowed_versions().into_keys(), expected);
        return_shared(registry);
        return_shared(policy);
    }

    #[test]
    /// Both sets start at the running version and move together through every
    /// switch, including the ones made while the running version is retired —
    /// the switches are ungated, which is what makes retirement recoverable.
    fun the_switches_move_the_registry_and_policy_sets_together() {
        let mut test = begin(OWNER);
        pool_test_utils::setup_test(OWNER, &mut test);
        let v = constants::current_version();
        assert_sets(&mut test, vector[v]);

        set_version(&mut test, v + 1, true);
        assert_sets(&mut test, vector[v, v + 1]);
        set_version(&mut test, v, false);
        assert_sets(&mut test, vector[v + 1]);
        set_version(&mut test, v + 1, false);
        assert_sets(&mut test, vector[]);
        set_version(&mut test, v, true);
        assert_sets(&mut test, vector[v]);

        end(test);
    }

    #[test, expected_failure(abort_code = registry::EVersionAlreadyEnabled)]
    fun enabling_an_allowed_version_aborts() {
        let mut test = begin(OWNER);
        pool_test_utils::setup_test(OWNER, &mut test);
        set_version(&mut test, constants::current_version(), true);

        abort 0
    }

    #[test, expected_failure(abort_code = registry::EVersionNotEnabled)]
    fun disabling_a_version_never_allowed_aborts() {
        let mut test = begin(OWNER);
        pool_test_utils::setup_test(OWNER, &mut test);
        set_version(&mut test, constants::current_version() + 1, false);

        abort 0
    }

    #[test]
    /// Retiring some other version leaves the running one alone.
    fun retiring_another_version_leaves_this_one_running() {
        let mut test = begin(OWNER);
        let account = account_fixture(&mut test);
        let v = constants::current_version();
        set_version(&mut test, v + 1, true);
        set_version(&mut test, v + 1, false);

        test.next_tx(ALICE);
        let policy = test.take_shared<FeePolicy>();
        let mut ta = test.take_shared_by_id<TradingAccount>(account);
        ta.deposit(&policy, mint_for_testing<SUI>(1, test.ctx()), test.ctx());
        assert_eq!(ta.balance<SUI>(), FUNDS + 1);
        return_shared(ta);
        return_shared(policy);

        end(test);
    }

    // === TradingAccount ===

    /// A funded account for ALICE, with a trade, deposit and withdraw cap sent
    /// to her, made while the running version is still allowed.
    fun account_fixture(test: &mut Scenario): ID {
        pool_test_utils::setup_test(OWNER, test);
        let account = create_acct_and_share_with_funds(ALICE, FUNDS, test);
        create_caps(ALICE, account, test);
        account
    }

    /// ALICE's account and the shared policy, after the running version is
    /// retired.
    fun retired_account(test: &mut Scenario): (FeePolicy, TradingAccount) {
        let account = account_fixture(test);
        retire(test);
        test.next_tx(ALICE);
        (test.take_shared<FeePolicy>(), test.take_shared_by_id<TradingAccount>(account))
    }

    fun some_collection(): ID { object::id_from_address(@0xC011) }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    /// The same retirement under realistic conditions: the successor is allowed,
    /// so the set is not empty, and the retired code is still stopped.
    fun retiring_this_version_after_allowing_its_successor_stops_it() {
        let mut test = begin(OWNER);
        let account = account_fixture(&mut test);
        set_version(&mut test, constants::current_version() + 1, true);
        retire(&mut test);

        test.next_tx(ALICE);
        let policy = test.take_shared<FeePolicy>();
        let mut ta = test.take_shared_by_id<TradingAccount>(account);
        ta.deposit(&policy, mint_for_testing<SUI>(1, test.ctx()), test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_new() {
        let mut test = begin(OWNER);
        let (policy, _ta) = retired_account(&mut test);
        let _new = trading_account::new(&policy, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_new_with_custom_owner() {
        let mut test = begin(OWNER);
        let (policy, _ta) = retired_account(&mut test);
        let _new = trading_account::new_with_custom_owner(&policy, BOB, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_new_with_custom_owner_and_caps() {
        let mut test = begin(OWNER);
        let (policy, _ta) = retired_account(&mut test);
        let _new = trading_account::new_with_custom_owner_and_caps(&policy, BOB, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_new_with_uid_owner_and_caps() {
        let mut test = begin(OWNER);
        let (policy, _ta) = retired_account(&mut test);
        let mut owner = object::new(test.ctx());
        let (_new, _d, _w, _t) = trading_account::new_with_uid_owner_and_caps(
            &policy,
            &mut owner,
            test.ctx(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_mint_trade_cap() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let _cap = ta.mint_trade_cap(&policy, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_mint_deposit_cap() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let _cap = ta.mint_deposit_cap(&policy, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_mint_withdraw_cap() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let _cap = ta.mint_withdraw_cap(&policy, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_revoke_trade_cap() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let cap = test.take_from_sender<TradeCap>();
        ta.revoke_trade_cap(&policy, &object::id(&cap), test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_generate_proof_as_owner() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let _proof = ta.generate_proof_as_owner(&policy, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_generate_proof_as_trader() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let cap = test.take_from_sender<TradeCap>();
        let _proof = ta.generate_proof_as_trader(&policy, &cap, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_deposit() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        ta.deposit(&policy, mint_for_testing<SUI>(1, test.ctx()), test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_deposit_with_cap() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let cap = test.take_from_sender<DepositCap>();
        ta.deposit_with_cap(&policy, &cap, mint_for_testing<SUI>(1, test.ctx()), test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_withdraw() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let _coin = ta.withdraw<SUI>(&policy, 1, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_withdraw_all() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let _coin = ta.withdraw_all<SUI>(&policy, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_withdraw_with_cap() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let cap = test.take_from_sender<WithdrawCap>();
        let _coin = ta.withdraw_with_cap<SUI>(&policy, &cap, 1, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_deposit_multicoin() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let balance = multicoin::zero(some_collection(), 1, test.ctx());
        ta.deposit_multicoin(&policy, balance, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_deposit_multicoin_with_cap() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let cap = test.take_from_sender<DepositCap>();
        let balance = multicoin::zero(some_collection(), 1, test.ctx());
        ta.deposit_multicoin_with_cap(&policy, &cap, balance, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_withdraw_multicoin() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let _balance = ta.withdraw_multicoin(&policy, some_collection(), 1, 1, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_withdraw_all_multicoin() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let _balance = ta.withdraw_all_multicoin(&policy, some_collection(), 1, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_withdraw_multicoin_with_cap() {
        let mut test = begin(OWNER);
        let (policy, mut ta) = retired_account(&mut test);
        let cap = test.take_from_sender<WithdrawCap>();
        let _balance = ta.withdraw_multicoin_with_cap(
            &policy,
            &cap,
            some_collection(),
            1,
            1,
            test.ctx(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = registry::EPackageVersionNotEnabled)]
    /// Registration writes the registry, whose own gate reads the same set.
    fun retiring_stops_account_registration() {
        let mut test = begin(OWNER);
        let (_policy, ta) = retired_account(&mut test);
        let mut registry = test.take_shared<Registry>();
        ta.register_trading_account(&mut registry, test.ctx());

        abort 0
    }

    #[test]
    /// Reads take no policy and keep answering, so a retired version's
    /// balances stay visible to anyone deciding what to do about them. The
    /// proof is made before the retirement, in the same transaction.
    fun account_views_still_answer_while_retired() {
        let mut test = begin(OWNER);
        let account = account_fixture(&mut test);

        test.next_tx(ALICE);
        let mut policy = test.take_shared<FeePolicy>();
        let mut registry = test.take_shared<Registry>();
        let mut ta = test.take_shared_by_id<TradingAccount>(account);
        let proof = ta.generate_proof_as_owner(&policy, test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        policy.disable_version(&mut registry, constants::current_version(), &cap);

        assert_eq!(ta.balance<SUI>(), FUNDS);
        assert_eq!(ta.multicoin_balance(some_collection(), 1), 0);
        assert_eq!(ta.owner(), ALICE);
        assert_eq!(ta.id(), account);
        assert_eq!(ta.fee_turnover<USDC>(test.ctx()), 0);
        ta.validate_proof(&proof);

        destroy(cap);
        return_shared(ta);
        return_shared(registry);
        return_shared(policy);
        end(test);
    }

    #[test]
    /// Allowing the version again reopens every account path the gate closed.
    fun re_enabling_reopens_every_account_operation() {
        let mut test = begin(OWNER);
        let account = account_fixture(&mut test);
        retire(&mut test);
        set_version(&mut test, constants::current_version(), true);

        test.next_tx(ALICE);
        let policy = test.take_shared<FeePolicy>();
        let mut ta = test.take_shared_by_id<TradingAccount>(account);
        ta.deposit(&policy, mint_for_testing<SUI>(5, test.ctx()), test.ctx());
        let coin = ta.withdraw<SUI>(&policy, 5, test.ctx());
        assert_eq!(coin.value(), 5);
        destroy(coin);
        let cap = ta.mint_trade_cap(&policy, test.ctx());
        let _proof = ta.generate_proof_as_trader(&policy, &cap, test.ctx());
        ta.revoke_trade_cap(&policy, &object::id(&cap), test.ctx());
        let fresh = trading_account::new(&policy, test.ctx());
        transfer::public_share_object(fresh);
        destroy(cap);
        return_shared(ta);
        return_shared(policy);

        end(test);
    }

    // === FeePolicy ===

    /// The shared policy and an admin cap, after the running version is retired.
    fun retired_policy(test: &mut Scenario): (FeePolicy, registry::TriexAdminCap) {
        pool_test_utils::setup_test(OWNER, test);
        retire(test);
        test.next_tx(OWNER);
        (test.take_shared<FeePolicy>(), registry::get_admin_cap_for_testing(test.ctx()))
    }

    #[test]
    /// The halt is the one write that stays open: it can only stop trading,
    /// so it must work from whichever version the operator's tooling calls.
    fun the_halt_still_works_while_retired() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = retired_policy(&mut test);
        policy.halt_trading(&cap);
        assert!(policy.trading_halted());

        destroy(cap);
        return_shared(policy);
        end(test);
    }

    #[test]
    fun policy_views_still_answer_while_retired() {
        let mut test = begin(OWNER);
        let (policy, cap) = retired_policy(&mut test);
        let class = pool_test_utils::standard_class<USDC>();
        assert!(policy.class_exists(class));
        assert!(!policy.trading_halted());
        assert_eq!(policy.allowed_versions(), vec_set::empty());
        let (_, effective) = policy.next_schedule(class);
        let _ = policy.active_schedule(class, effective);
        assert_eq!(
            policy.cancel_retention_bps(class, effective),
            pool_test_utils::default_cancel_retention_bps(),
        );
        assert!(policy.operator_share_class_exists(0));

        destroy(cap);
        return_shared(policy);
        end(test);
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_resume_trading() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = retired_policy(&mut test);
        policy.resume_trading(&cap);

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_create_class() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = retired_policy(&mut test);
        policy.create_class<USDT>(
            999,
            vector[0],
            vector[11_000_000],
            vector[9_000_000],
            2_000,
            &cap,
            test.ctx(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_update_class() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = retired_policy(&mut test);
        policy.update_class(
            pool_test_utils::standard_class<USDC>(),
            vector[0],
            vector[11_000_000],
            vector[9_000_000],
            2_000,
            &cap,
            test.ctx(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_set_default_class() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = retired_policy(&mut test);
        policy.set_default_class<USDC>(pool_test_utils::standard_class<USDC>(), &cap);

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_set_multicoin_default_class() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = retired_policy(&mut test);
        let payouts = test.take_shared<OperatorPayouts>();
        policy.set_multicoin_default_class<USDC>(
            &payouts,
            pool_test_utils::multicoin_class<USDC>(),
            &cap,
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    /// Every write it makes goes through a gated setter.
    fun retiring_stops_bootstrap_quote() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = retired_policy(&mut test);
        let payouts = test.take_shared<OperatorPayouts>();
        policy.bootstrap_quote<USDT>(&payouts, 500, 501, 1_000_000, &cap, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_stage_operator_share_class() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = retired_policy(&mut test);
        policy.stage_operator_share_class(0, 1_000, &cap, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_assign_operator_share_class() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = retired_policy(&mut test);
        policy.assign_operator_share_class(some_collection(), 0, &cap);

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_set_default_operator_share_class() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = retired_policy(&mut test);
        policy.set_default_operator_share_class(0, &cap);

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_seed_operator_share_genesis() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = retired_policy(&mut test);
        policy.seed_operator_share_genesis(&cap, test.ctx());

        abort 0
    }

    // === Pools that were never refreshed ===
    //
    // The case TRIEX-146 was filed for: after the retirement, nothing has run
    // `update_pool_allowed_versions`, so each pool's own gate still lets the
    // retired version in.

    public struct CoinMarket has drop {
        registry_id: ID,
        pool_id: ID,
        alice: ID,
        bob: ID,
    }

    /// A SUI/USDC pool and two accounts funded in every test coin.
    fun coin_market(test: &mut Scenario): CoinMarket {
        let registry_id = pool_test_utils::setup_test(OWNER, test);
        let alice = create_acct_and_share_with_funds(ALICE, FUNDS, test);
        let bob = create_acct_and_share_with_funds(BOB, FUNDS, test);
        let pool_id = pool_test_utils::setup_pool_with_default_fees<SUI, USDC>(
            OWNER,
            registry_id,
            test,
        );

        CoinMarket { registry_id, pool_id, alice, bob }
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    /// The order itself is stopped, not just its proof: the proof is made
    /// before the retirement, in the same transaction.
    fun retiring_stops_new_orders_on_an_unrefreshed_coin_pool() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);

        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
        let mut policy = test.take_shared<FeePolicy>();
        let mut registry = test.take_shared<Registry>();
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(m.alice);
        let proof = ta.generate_proof_as_owner(&policy, test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        policy.disable_version(&mut registry, constants::current_version(), &cap);

        pool.place_limit_order(
            &policy,
            &mut ta,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_anonymous_swaps_on_an_unrefreshed_coin_pool() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        pool_test_utils::place_limit_order<SUI, USDC>(
            ALICE,
            m.pool_id,
            m.alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
            &mut test,
        );
        retire(&mut test);

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

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_permissionless_coin_pool_creation() {
        let mut test = begin(OWNER);
        let registry_id = setup_currency_registry(&mut test);
        retire(&mut test);

        test.next_tx(ALICE);
        let base_currency: Currency<COIN_DEC15> = coin_dec15::currency(test.ctx());
        let quote_currency: Currency<COIN_DEC6> = coin_dec6::currency(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let policy = test.take_shared<FeePolicy>();
        pool::create_permissionless_pool<COIN_DEC15, COIN_DEC6>(
            &mut registry,
            &policy,
            &base_currency,
            &quote_currency,
            mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx()),
            test.ctx(),
        );

        abort 0
    }

    /// Alice's ask, filled by Bob, leaves her settled quote in the pool; her
    /// bid below it expires at `expire_at`. Returns the bid's order id and her
    /// settled quote.
    fun settled_and_expiring(test: &mut Scenario, m: &CoinMarket, expire_at: u64): (u128, u64) {
        pool_test_utils::place_limit_order<SUI, USDC>(
            ALICE,
            m.pool_id,
            m.alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            PRICE,
            QUANTITY,
            false,
            constants::max_u64(),
            test,
        );
        let expiring = pool_test_utils::place_limit_order<SUI, USDC>(
            ALICE,
            m.pool_id,
            m.alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            PRICE / 2,
            QUANTITY,
            true,
            expire_at,
            test,
        );
        pool_test_utils::place_limit_order<SUI, USDC>(
            BOB,
            m.pool_id,
            m.bob,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
            test,
        );

        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
        let alice = test.take_shared_by_id<TradingAccount>(m.alice);
        let settled = pool.account(&alice).settled_balances().quote();
        assert!(settled > 0);
        return_shared(alice);
        return_shared(pool);

        (expiring.order_id(), settled)
    }

    #[test]
    /// What a retired version keeps on a pool nothing has refreshed: the
    /// permissionless exits. A stranger can still sweep an owner's settled
    /// proceeds into their account and retire an expired order.
    fun a_retired_version_still_settles_on_an_unrefreshed_pool() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        pool_test_utils::set_time(0, &mut test);
        let (expiring, settled) = settled_and_expiring(&mut test, &m, 1_000_000 + 100);
        retire(&mut test);

        test.next_tx(CHARLIE);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let mut alice = test.take_shared_by_id<TradingAccount>(m.alice);
            let before = alice.balance<USDC>();
            pool.withdraw_settled_amounts_permissionless(&mut alice);
            assert_eq!(alice.balance<USDC>() - before, settled);
            return_shared(alice);
            return_shared(pool);
        };

        pool_test_utils::set_time(101, &mut test);
        test.next_tx(CHARLIE);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let clock = test.take_shared<Clock>();
            assert_eq!(pool.clean_expired_orders(vector[expiring], &clock, test.ctx()), 1);
            return_shared(clock);
            return_shared(pool);
        };

        end(test);
    }

    #[test, expected_failure(abort_code = pool::EPackageVersionDisabled)]
    /// Refreshing the pool ends those exits too: its own gate now has the
    /// retired version off.
    fun refreshing_the_pool_ends_a_retired_versions_exits() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        pool_test_utils::set_time(0, &mut test);
        settled_and_expiring(&mut test, &m, constants::max_u64());
        retire(&mut test);

        test.next_tx(CHARLIE);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
        let registry = test.take_shared_by_id<Registry>(m.registry_id);
        pool.update_pool_allowed_versions(&registry);
        let mut alice = test.take_shared_by_id<TradingAccount>(m.alice);
        pool.withdraw_settled_amounts_permissionless(&mut alice);

        abort 0
    }

    #[test]
    /// Recovery needs no pool step when no pool was refreshed in between: the
    /// pools' own sets never changed, and the policy's is back.
    fun re_enabling_reopens_trading_without_touching_a_pool() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        retire(&mut test);
        set_version(&mut test, constants::current_version(), true);

        pool_test_utils::place_limit_order<SUI, USDC>(
            ALICE,
            m.pool_id,
            m.alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            PRICE,
            QUANTITY,
            false,
            constants::max_u64(),
            &mut test,
        );
        let bid = pool_test_utils::place_limit_order<SUI, USDC>(
            BOB,
            m.pool_id,
            m.bob,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            PRICE,
            QUANTITY,
            true,
            constants::max_u64(),
            &mut test,
        );
        assert_eq!(bid.executed_quantity(), QUANTITY);

        end(test);
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_staging_a_coin_pool_class_move() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        retire(&mut test);

        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
        let mut policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        pool.stage_pool_fee_class(
            &mut policy,
            pool_test_utils::standard_class<USDC>(),
            &cap,
            test.ctx(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    /// Staged while allowed, due, then retired: applying it is a write to the
    /// policy and stops too.
    fun retiring_stops_applying_a_coin_pool_class_move() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let mut policy = test.take_shared<FeePolicy>();
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            pool.stage_pool_fee_class(
                &mut policy,
                pool_test_utils::standard_class<USDC>(),
                &cap,
                test.ctx(),
            );
            destroy(cap);
            return_shared(policy);
            return_shared(pool);
        };
        test.next_epoch(OWNER);
        retire(&mut test);

        test.next_tx(OWNER);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
        let mut policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        pool.apply_pool_fee_class(&mut policy, &cap, test.ctx());

        abort 0
    }

    // === Multicoin pools that were never refreshed ===

    public struct MulticoinMarket has drop {
        registry_id: ID,
        pool_id: ID,
        alice: ID,
        bob: ID,
    }

    const ASSET_GOLD: u64 = 1;
    const ASSET_IRON: u64 = 3;
    const MC_QUANTITY: u64 = 100;

    /// A GOLD pool quoted in USDC, with Alice funded in quote and Bob in quote
    /// and GOLD.
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
        let alice = mc_utils::create_trading_account_with_funds(ALICE, FUNDS, FUNDS, test);
        let bob = mc_utils::create_trading_account_with_funds(BOB, FUNDS, FUNDS, test);

        test.next_tx(OWNER);
        {
            let mut collection = test.take_shared<Collection>();
            let gold = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                ASSET_GOLD,
                FUNDS,
                test.ctx(),
            );
            return_shared(collection);
            transfer::public_transfer(gold, BOB);
        };
        test.next_tx(BOB);
        {
            let policy = test.take_shared<FeePolicy>();
            let mut ta = test.take_shared_by_id<TradingAccount>(bob);
            let gold = test.take_from_sender<multicoin::Balance>();
            ta.deposit_multicoin(&policy, gold, test.ctx());
            return_shared(ta);
            return_shared(policy);
        };

        (MulticoinMarket { registry_id, pool_id, alice, bob }, collection_cap)
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    /// As on the coin pool, the proof predates the retirement, so it is the
    /// order that is refused.
    fun retiring_stops_new_orders_on_an_unrefreshed_multicoin_pool() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);

        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
        let mut policy = test.take_shared<FeePolicy>();
        let mut registry = test.take_shared_by_id<Registry>(m.registry_id);
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(m.bob);
        let proof = ta.generate_proof_as_owner(&policy, test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        policy.disable_version(&mut registry, constants::current_version(), &cap);

        pool.place_limit_order(
            &policy,
            &mut ta,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            PRICE,
            MC_QUANTITY,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_anonymous_swaps_on_an_unrefreshed_multicoin_pool() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);
        retire(&mut test);

        test.next_tx(CHARLIE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let (base, quote, cred) = pool.swap_exact_quote_for_base(
            &policy,
            mint_for_testing<USDC>(1_000 * PRICE, test.ctx()),
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

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_permissionless_multicoin_pool_creation() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);
        retire(&mut test);

        test.next_tx(ALICE);
        let mut registry = test.take_shared_by_id<Registry>(m.registry_id);
        let policy = test.take_shared<FeePolicy>();
        let collection = test.take_shared<Collection>();
        multicoin_pool::create_permissionless_pool<USDC>(
            &mut registry,
            &policy,
            &collection,
            ASSET_IRON,
            mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx()),
            test.ctx(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_staging_a_multicoin_pool_class_move() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);
        retire(&mut test);

        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
        let mut policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        pool.stage_pool_fee_class(
            &mut policy,
            pool_test_utils::multicoin_class<USDC>(),
            &cap,
            test.ctx(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EPackageVersionDisabled)]
    fun retiring_stops_applying_a_multicoin_pool_class_move() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
            let mut policy = test.take_shared<FeePolicy>();
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            pool.stage_pool_fee_class(
                &mut policy,
                pool_test_utils::multicoin_class<USDC>(),
                &cap,
                test.ctx(),
            );
            destroy(cap);
            return_shared(policy);
            return_shared(pool);
        };
        test.next_epoch(OWNER);
        retire(&mut test);

        test.next_tx(OWNER);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
        let mut policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        pool.apply_pool_fee_class(&mut policy, &cap, test.ctx());

        abort 0
    }
}
