/// Nothing re-prices a live pool without notice, and nothing prices above the
/// cap (TRIEX-151).
///
/// The report: `set_pool_fee_class` applied at once, so moving a coin pool into
/// its quote's multicoin class doubled its fees inside one transaction, and the
/// ceiling on a rate was 100%. Separately, `update_class` staged its ladder but
/// applied its cancel retention immediately.
///
/// Three things are pinned here.
///
/// - **The cap.** A rate is accepted at exactly 20% and rejected one basis point
///   above it, for takers and makers, on creation and on re-pricing.
/// - **Retention is staged with the ladder.** An order placed before the staged
///   epoch is held to the old retention; one placed from it on, to the new.
/// - **A class move is announced before it can land.** Staging changes nothing:
///   trades in that epoch still pay the old class's rates. The move cannot be
///   applied until the next epoch, lands only when it is applied, and never
///   touches an order already resting. Both pool kinds.
#[test_only]
module triex::fee_staging_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test::{assert_eq, destroy};
    use sui::{clock::Clock, event, sui::SUI, test_scenario::{Scenario, begin, end, return_shared}};
    use triex::{
        constants,
        fee_policy::{Self, FeePolicy, PoolFeeClassSet, PoolFeeClassStaged},
        integration_multicoin_test_utils as mc_utils,
        math,
        multicoin_pool::MultiCoinPool,
        order_info::OrderInfo,
        pool::Pool,
        pool_test_utils::{Self, multicoin_class, standard_class},
        quote_fee,
        registry::{Self, TriexAdminCap},
        trading_account::TradingAccount,
        trading_account_tests::{create_acct_and_share_with_funds, USDC, USDT}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    /// `fee_policy`'s cap on a taker or maker rate: 2,000 basis points.
    const CAP: u64 = 200_000_000;
    const ONE_BP: u64 = 100_000;
    /// The ceiling the cap replaced.
    const FULL_FEE: u64 = 1_000_000_000;

    /// A class id clear of the ones the shared test policy seeds (0 to 9).
    const CLASS: u16 = 77;
    const RETENTION: u64 = 2_000;

    // === The cap ===

    fun new_policy(test: &mut Scenario): (FeePolicy, TriexAdminCap) {
        (
            fee_policy::create_for_testing(test.ctx()),
            registry::get_admin_cap_for_testing(test.ctx()),
        )
    }

    fun create_flat(
        policy: &mut FeePolicy,
        taker: u64,
        maker: u64,
        retention: u64,
        cap: &TriexAdminCap,
        test: &mut Scenario,
    ) {
        policy.create_class<USDC>(
            CLASS,
            vector[0],
            vector[taker],
            vector[maker],
            retention,
            cap,
            test.ctx(),
        );
    }

    fun restage_flat(
        policy: &mut FeePolicy,
        taker: u64,
        maker: u64,
        retention: u64,
        cap: &TriexAdminCap,
        test: &mut Scenario,
    ) {
        policy.update_class(
            CLASS,
            vector[0],
            vector[taker],
            vector[maker],
            retention,
            cap,
            test.ctx(),
        );
    }

    #[test]
    /// Exactly at the cap is a legal rate on both sides, by both routes.
    fun a_rate_exactly_at_the_cap_is_accepted() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);

        create_flat(&mut policy, CAP, CAP, RETENTION, &cap, &mut test);
        let (_, taker, maker) = policy.resolve(CLASS, 0, test.ctx().epoch());
        assert_eq!(taker, CAP);
        assert_eq!(maker, CAP);

        // Re-pricing a class that already trades below the cap up to it.
        restage_flat(&mut policy, 11_000_000, 9_000_000, RETENTION, &cap, &mut test);
        test.next_epoch(OWNER);
        restage_flat(&mut policy, CAP, CAP, RETENTION, &cap, &mut test);
        let (_, taker, maker) = policy.resolve(CLASS, 0, test.ctx().epoch() + 1);
        assert_eq!(taker, CAP);
        assert_eq!(maker, CAP);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test, expected_failure(abort_code = triex::fee_schedule::EInvalidTakerFee)]
    fun creating_a_class_one_bp_over_the_taker_cap_aborts() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        create_flat(&mut policy, CAP + ONE_BP, 0, RETENTION, &cap, &mut test);
        abort 0
    }

    #[test, expected_failure(abort_code = triex::fee_schedule::EInvalidMakerFee)]
    fun creating_a_class_one_bp_over_the_maker_cap_aborts() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        create_flat(&mut policy, CAP, CAP + ONE_BP, RETENTION, &cap, &mut test);
        abort 0
    }

    #[test, expected_failure(abort_code = triex::fee_schedule::EInvalidTakerFee)]
    /// Re-pricing is the route that reaches pools already trading, so the cap
    /// has to hold there too.
    fun repricing_a_class_one_bp_over_the_taker_cap_aborts() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        create_flat(&mut policy, 11_000_000, 9_000_000, RETENTION, &cap, &mut test);
        restage_flat(&mut policy, CAP + ONE_BP, 9_000_000, RETENTION, &cap, &mut test);
        abort 0
    }

    #[test, expected_failure(abort_code = triex::fee_schedule::EInvalidMakerFee)]
    fun repricing_a_class_one_bp_over_the_maker_cap_aborts() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        create_flat(&mut policy, 11_000_000, 9_000_000, RETENTION, &cap, &mut test);
        restage_flat(&mut policy, CAP, CAP + ONE_BP, RETENTION, &cap, &mut test);
        abort 0
    }

    #[test, expected_failure(abort_code = triex::fee_schedule::EInvalidTakerFee)]
    /// The ceiling from the report. At 100% an ask taker delivers base and
    /// receives nothing; it is no longer a rate the policy will hold.
    fun the_old_full_fee_ceiling_is_rejected() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        create_flat(&mut policy, FULL_FEE, 0, RETENTION, &cap, &mut test);
        abort 0
    }

    #[test, expected_failure(abort_code = triex::fee_schedule::EInvalidMakerFee)]
    fun the_old_full_maker_fee_ceiling_is_rejected() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        create_flat(&mut policy, CAP, FULL_FEE, RETENTION, &cap, &mut test);
        abort 0
    }

    #[test]
    /// Launch pricing has to fit under the cap with room to move: the highest
    /// genesis rate is the multicoin entry taker rate, 2.20%.
    fun launch_pricing_sits_well_under_the_cap() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        let payouts = fee_policy::create_pinned_payouts_for_testing(&cap, test.ctx());
        policy.bootstrap_quote<USDC>(&payouts, 1, 2, 1_000_000, &cap, test.ctx());

        let epoch = test.ctx().epoch();
        let (_, coin_taker, coin_maker) = policy.resolve(1, 0, epoch);
        let (_, multicoin_taker, multicoin_maker) = policy.resolve(2, 0, epoch);
        assert_eq!(multicoin_taker, 22_000_000);
        assert!(coin_taker < multicoin_taker && coin_maker < multicoin_maker);
        assert!(multicoin_maker < multicoin_taker);
        // Nine times the highest launch rate still fits.
        assert!(9 * multicoin_taker <= CAP);

        destroy(payouts);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    // === Retention is staged with the ladder ===

    #[test]
    /// A re-priced retention waits for the same epoch as the ladder it was
    /// staged with. Both the view and the pricing path agree, at both epochs.
    fun restaged_retention_takes_effect_with_the_ladder() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        create_flat(&mut policy, 11_000_000, 9_000_000, RETENTION, &cap, &mut test);
        let epoch = test.ctx().epoch();
        // A new class is live at once: there is nobody trading in it to surprise.
        assert_eq!(policy.cancel_retention_bps(CLASS, epoch), RETENTION);

        restage_flat(&mut policy, 12_000_000, 9_000_000, 5_000, &cap, &mut test);

        assert_eq!(policy.cancel_retention_bps(CLASS, epoch), RETENTION);
        let (_, taker, _, retention) = policy.resolve_with_retention(CLASS, 0, epoch);
        assert_eq!(taker, 11_000_000);
        assert_eq!(retention, RETENTION);

        assert_eq!(policy.cancel_retention_bps(CLASS, epoch + 1), 5_000);
        let (_, taker, _, retention) = policy.resolve_with_retention(CLASS, 0, epoch + 1);
        assert_eq!(taker, 12_000_000);
        assert_eq!(retention, 5_000);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    /// Staging twice inside one epoch replaces the future and leaves the present
    /// alone: the first staged value never applies to anything.
    fun restaging_retention_twice_only_replaces_the_future() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        create_flat(&mut policy, 11_000_000, 9_000_000, RETENTION, &cap, &mut test);
        let epoch = test.ctx().epoch();

        restage_flat(&mut policy, 11_000_000, 9_000_000, 5_000, &cap, &mut test);
        restage_flat(&mut policy, 11_000_000, 9_000_000, 7_000, &cap, &mut test);

        assert_eq!(policy.cancel_retention_bps(CLASS, epoch), RETENTION);
        assert_eq!(policy.cancel_retention_bps(CLASS, epoch + 1), 7_000);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    /// A staged retention that has come due is the running one. Staging again
    /// promotes it first, so the new stage replaces the future and never reaches
    /// back over an epoch that is already trading on it.
    fun a_due_retention_is_promoted_before_the_next_stage() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        create_flat(&mut policy, 11_000_000, 9_000_000, RETENTION, &cap, &mut test);
        restage_flat(&mut policy, 11_000_000, 9_000_000, 5_000, &cap, &mut test);

        test.next_epoch(OWNER);
        let epoch = test.ctx().epoch();
        assert_eq!(policy.cancel_retention_bps(CLASS, epoch), 5_000);

        restage_flat(&mut policy, 11_000_000, 9_000_000, 7_000, &cap, &mut test);
        assert_eq!(policy.cancel_retention_bps(CLASS, epoch), 5_000);
        assert_eq!(policy.cancel_retention_bps(CLASS, epoch + 1), 7_000);
        let (_, _, _, retention) = policy.resolve_with_retention(CLASS, 0, epoch);
        assert_eq!(retention, 5_000);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    // === A coin pool ===

    public struct Market has drop {
        pool_id: ID,
        alice: ID,
        bob: ID,
    }

    /// A SUI/USDC pool, born into the standard USDC class, with two funded
    /// accounts.
    fun coin_market(test: &mut Scenario): Market {
        let registry_id = pool_test_utils::setup_test(OWNER, test);
        let funds = 1_000_000 * constants::float_scaling();
        let alice = create_acct_and_share_with_funds(ALICE, funds, test);
        let bob = create_acct_and_share_with_funds(BOB, funds, test);
        let pool_id = pool_test_utils::setup_pool_with_default_fees<SUI, USDC>(
            OWNER,
            registry_id,
            test,
        );

        Market { pool_id, alice, bob }
    }

    const PRICE: u64 = 2_000_000_000;
    const QUANTITY: u64 = 1_000_000_000;

    /// The quote one `QUANTITY` at `PRICE` trades for on the coin pool.
    fun coin_quote(): u64 { math::mul(QUANTITY, PRICE) }

    fun coin_order(
        test: &mut Scenario,
        trader: address,
        m: &Market,
        account: ID,
        is_bid: bool,
    ): OrderInfo {
        pool_test_utils::place_limit_order<SUI, USDC>(
            trader,
            m.pool_id,
            account,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            PRICE,
            QUANTITY,
            is_bid,
            constants::max_u64(),
            test,
        )
    }

    /// Alice rests an ask and Bob takes it. Returns (the rate Alice's order
    /// snapshotted as a maker, the taker fee Bob was charged).
    fun coin_trade(test: &mut Scenario, m: &Market): (u64, u64) {
        let ask = coin_order(test, ALICE, m, m.alice, false);
        assert!(ask.order_inserted());
        let bid = coin_order(test, BOB, m, m.bob, true);
        assert_eq!(bid.executed_quantity(), QUANTITY);

        (ask.maker_fee_rate(), bid.paid_fees())
    }

    fun coin_stage(test: &mut Scenario, pool_id: ID, class_id: u16) {
        test.next_tx(OWNER);
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let mut policy = test.take_shared<FeePolicy>();
        pool.stage_pool_fee_class(&mut policy, class_id, &cap, test.ctx());
        return_shared(policy);
        return_shared(pool);
        destroy(cap);
    }

    fun coin_apply(test: &mut Scenario, pool_id: ID) {
        test.next_tx(OWNER);
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let mut policy = test.take_shared<FeePolicy>();
        pool.apply_pool_fee_class(&mut policy, &cap, test.ctx());
        return_shared(policy);
        return_shared(pool);
        destroy(cap);
    }

    /// (current class, staged class, epoch the staged class can be applied
    /// from, entry taker rate, entry maker rate).
    fun coin_view(test: &mut Scenario, pool_id: ID): (u16, u16, u64, u64, u64) {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let class_id = pool.pool_fee_class();
        let (next_class, next_epoch) = pool.pool_fee_class_next(&policy);
        let (taker, maker) = pool.pool_trade_params(&policy, test.ctx());
        return_shared(policy);
        return_shared(pool);

        (class_id, next_class, next_epoch, taker, maker)
    }

    #[test]
    /// The trigger from the report. Staging the move of a coin pool into its
    /// quote's multicoin class, which charges double, changes nothing: the pool
    /// reports its old class and old rates, and a trade in the same epoch pays
    /// the old taker rate and snapshots the old maker rate.
    fun staging_a_class_move_does_not_reprice_the_pool() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        let staged_in = test.ctx().epoch();

        coin_stage(&mut test, m.pool_id, multicoin_class<USDC>());

        // Announced, with the epoch it can land from, and not reported as set.
        let staged = event::events_by_type<PoolFeeClassStaged>();
        assert_eq!(staged.length(), 1);
        let (id, class_id, effective_epoch) = staged[0].pool_fee_class_staged_parts();
        assert_eq!(id, m.pool_id);
        assert_eq!(class_id, multicoin_class<USDC>());
        assert_eq!(effective_epoch, staged_in + 1);
        assert!(event::events_by_type<PoolFeeClassSet>().is_empty());

        let (class_id, next_class, next_epoch, taker, maker) = coin_view(&mut test, m.pool_id);
        assert_eq!(class_id, standard_class<USDC>());
        assert_eq!(next_class, multicoin_class<USDC>());
        assert_eq!(next_epoch, staged_in + 1);
        assert_eq!(taker, pool_test_utils::default_taker_fee());
        assert_eq!(maker, pool_test_utils::default_maker_fee());

        let (maker_rate, taker_fee) = coin_trade(&mut test, &m);
        assert_eq!(maker_rate, pool_test_utils::default_maker_fee());
        assert_eq!(
            taker_fee,
            quote_fee::fee_from_scaled_rate(pool_test_utils::default_taker_fee(), coin_quote()),
        );
        // Not the doubled rate the move will bring.
        assert!(
            taker_fee < quote_fee::fee_from_scaled_rate(
                pool_test_utils::default_taker_fee_multicoin(),
                coin_quote(),
            ),
        );

        end(test);
    }

    #[test, expected_failure(abort_code = fee_policy::EPoolFeeClassNotYetEffective)]
    /// The gate that makes the announcement mean something: in the epoch it was
    /// staged, a move cannot be applied.
    fun a_staged_move_cannot_be_applied_in_the_epoch_it_was_staged() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);

        coin_stage(&mut test, m.pool_id, multicoin_class<USDC>());
        coin_apply(&mut test, m.pool_id);

        abort 0
    }

    #[test]
    /// From the next epoch the move can be applied, and it lands when it is —
    /// not on the boundary by itself. Until then the pool still trades under its
    /// old class; afterwards under the new one.
    fun a_staged_move_lands_only_when_applied() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        coin_stage(&mut test, m.pool_id, multicoin_class<USDC>());

        test.next_epoch(OWNER);

        // The epoch has arrived but nobody has applied the move.
        let (class_id, next_class, _, taker, _) = coin_view(&mut test, m.pool_id);
        assert_eq!(class_id, standard_class<USDC>());
        assert_eq!(next_class, multicoin_class<USDC>());
        assert_eq!(taker, pool_test_utils::default_taker_fee());
        let (maker_rate, taker_fee) = coin_trade(&mut test, &m);
        assert_eq!(maker_rate, pool_test_utils::default_maker_fee());
        assert_eq!(
            taker_fee,
            quote_fee::fee_from_scaled_rate(pool_test_utils::default_taker_fee(), coin_quote()),
        );

        coin_apply(&mut test, m.pool_id);
        let set = event::events_by_type<PoolFeeClassSet>();
        assert_eq!(set.length(), 1);
        let (id, class_id) = set[0].pool_fee_class_set_parts();
        assert_eq!(id, m.pool_id);
        assert_eq!(class_id, multicoin_class<USDC>());

        // Applied: the new class, nothing left staged, and the new rates.
        let (class_id, next_class, next_epoch, taker, maker) = coin_view(&mut test, m.pool_id);
        assert_eq!(class_id, multicoin_class<USDC>());
        assert_eq!(next_class, multicoin_class<USDC>());
        assert_eq!(next_epoch, 0);
        assert_eq!(taker, pool_test_utils::default_taker_fee_multicoin());
        assert_eq!(maker, pool_test_utils::default_maker_fee_multicoin());
        let (maker_rate, taker_fee) = coin_trade(&mut test, &m);
        assert_eq!(maker_rate, pool_test_utils::default_maker_fee_multicoin());
        assert_eq!(
            taker_fee,
            quote_fee::fee_from_scaled_rate(
                pool_test_utils::default_taker_fee_multicoin(),
                coin_quote(),
            ),
        );

        end(test);
    }

    #[test]
    /// A class move never reaches back to an order already resting: the maker
    /// keeps the rate it snapshotted at placement, while the taker that fills it
    /// after the move pays the new class's rate.
    fun resting_orders_keep_their_rate_across_a_class_move() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);

        let ask = coin_order(&mut test, ALICE, &m, m.alice, false);
        assert_eq!(ask.maker_fee_rate(), pool_test_utils::default_maker_fee());

        coin_stage(&mut test, m.pool_id, multicoin_class<USDC>());
        test.next_epoch(OWNER);
        coin_apply(&mut test, m.pool_id);

        // Still resting, still at the rate it was placed under.
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            assert_eq!(
                pool.get_order(ask.order_id()).maker_fee_rate(),
                pool_test_utils::default_maker_fee(),
            );
            return_shared(pool);
        };

        let bid = coin_order(&mut test, BOB, &m, m.bob, true);
        assert_eq!(bid.executed_quantity(), QUANTITY);
        assert_eq!(
            bid.paid_fees(),
            quote_fee::fee_from_scaled_rate(
                pool_test_utils::default_taker_fee_multicoin(),
                coin_quote(),
            ),
        );
        let fills = bid.fills();
        assert_eq!(fills.length(), 1);
        assert_eq!(fills[0].maker_fee_rate(), pool_test_utils::default_maker_fee());

        end(test);
    }

    #[test, expected_failure(abort_code = fee_policy::ENoStagedPoolFeeClass)]
    fun applying_with_nothing_staged_aborts() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        coin_apply(&mut test, m.pool_id);
        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::ENoStagedPoolFeeClass)]
    /// Applying consumes the announcement, so one announcement moves a pool once.
    fun a_staged_move_can_only_be_applied_once() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        coin_stage(&mut test, m.pool_id, multicoin_class<USDC>());
        test.next_epoch(OWNER);
        coin_apply(&mut test, m.pool_id);
        coin_apply(&mut test, m.pool_id);
        abort 0
    }

    #[test]
    /// A pending move can be corrected, and correcting it restarts the clock: it
    /// can never be brought forward by re-announcing.
    fun restaging_replaces_the_pending_move_and_restarts_its_clock() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        let first_epoch = test.ctx().epoch();

        // A class of its own for the pool, a little above the standard rate.
        test.next_tx(OWNER);
        {
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            let mut policy = test.take_shared<FeePolicy>();
            policy.create_class<USDC>(
                CLASS,
                vector[0],
                vector[15_000_000],
                vector[10_000_000],
                RETENTION,
                &cap,
                test.ctx(),
            );
            return_shared(policy);
            destroy(cap);
        };

        coin_stage(&mut test, m.pool_id, multicoin_class<USDC>());
        test.next_epoch(OWNER);
        coin_stage(&mut test, m.pool_id, CLASS);

        let (class_id, next_class, next_epoch, _, _) = coin_view(&mut test, m.pool_id);
        assert_eq!(class_id, standard_class<USDC>());
        assert_eq!(next_class, CLASS);
        assert_eq!(next_epoch, first_epoch + 2);

        test.next_epoch(OWNER);
        coin_apply(&mut test, m.pool_id);
        let (class_id, _, _, taker, maker) = coin_view(&mut test, m.pool_id);
        assert_eq!(class_id, CLASS);
        assert_eq!(taker, 15_000_000);
        assert_eq!(maker, 10_000_000);

        end(test);
    }

    #[test, expected_failure(abort_code = fee_policy::EPoolFeeClassNotYetEffective)]
    /// The control for the test above: after a re-announcement, the first
    /// announcement's epoch no longer opens the gate.
    fun restaging_does_not_inherit_the_earlier_epoch() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);

        coin_stage(&mut test, m.pool_id, multicoin_class<USDC>());
        test.next_epoch(OWNER);
        // The first announcement is due now, but it has been replaced.
        coin_stage(&mut test, m.pool_id, multicoin_class<USDC>());
        coin_apply(&mut test, m.pool_id);

        abort 0
    }

    #[test]
    /// Staging the class a pool is already in is how a pending move is called
    /// off: applying it leaves the pool where it was.
    fun staging_the_current_class_calls_a_pending_move_off() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);

        coin_stage(&mut test, m.pool_id, multicoin_class<USDC>());
        coin_stage(&mut test, m.pool_id, standard_class<USDC>());
        test.next_epoch(OWNER);
        coin_apply(&mut test, m.pool_id);

        let (class_id, next_class, next_epoch, taker, _) = coin_view(&mut test, m.pool_id);
        assert_eq!(class_id, standard_class<USDC>());
        assert_eq!(next_class, standard_class<USDC>());
        assert_eq!(next_epoch, 0);
        assert_eq!(taker, pool_test_utils::default_taker_fee());

        end(test);
    }

    #[test, expected_failure(abort_code = fee_policy::EClassQuoteMismatch)]
    /// A pool can only be moved to a class priced in its own quote.
    fun staging_a_class_of_another_quote_aborts() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        coin_stage(&mut test, m.pool_id, standard_class<USDT>());
        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EClassDoesNotExist)]
    fun staging_a_class_that_does_not_exist_aborts() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        coin_stage(&mut test, m.pool_id, 999);
        abort 0
    }

    #[test]
    /// A class created mid-epoch is live at once, which is safe because it is
    /// empty: the only way a trading pool reaches it is a staged move. So a new
    /// class at the cap plus a move into it, all in one epoch, still leaves that
    /// epoch's trades on the old rate.
    fun a_new_class_cannot_reprice_a_pool_in_the_epoch_it_is_created() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);

        test.next_tx(OWNER);
        {
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            let mut policy = test.take_shared<FeePolicy>();
            policy.create_class<USDC>(
                CLASS,
                vector[0],
                vector[CAP],
                vector[CAP],
                RETENTION,
                &cap,
                test.ctx(),
            );
            return_shared(policy);
            destroy(cap);
        };
        coin_stage(&mut test, m.pool_id, CLASS);

        let (maker_rate, taker_fee) = coin_trade(&mut test, &m);
        assert_eq!(maker_rate, pool_test_utils::default_maker_fee());
        assert_eq!(
            taker_fee,
            quote_fee::fee_from_scaled_rate(pool_test_utils::default_taker_fee(), coin_quote()),
        );

        end(test);
    }

    #[test]
    /// `pool_fee_schedule_next` is where a trader looks for what is coming. It
    /// reports the pool's own class when nothing is staged, and the destination
    /// class's ladder, with the epoch the move can land from, when one is.
    fun schedule_next_reports_a_staged_move() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        let epoch = test.ctx().epoch();

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let policy = test.take_shared<FeePolicy>();
            let (schedule, _) = pool.pool_fee_schedule_next(&policy);
            assert_eq!(schedule.tier_at(0).taker_fee(), pool_test_utils::default_taker_fee());
            // Nothing staged: this is the pool's class, exactly as the policy has it.
            let (own, own_epoch) = policy.next_schedule(standard_class<USDC>());
            let (reported, reported_epoch) = pool.pool_fee_schedule_next(&policy);
            assert_eq!(reported.tier_at(0).taker_fee(), own.tier_at(0).taker_fee());
            assert_eq!(reported_epoch, own_epoch);
            return_shared(policy);
            return_shared(pool);
        };

        coin_stage(&mut test, m.pool_id, multicoin_class<USDC>());

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let policy = test.take_shared<FeePolicy>();
            let (schedule, from_epoch) = pool.pool_fee_schedule_next(&policy);
            assert_eq!(
                schedule.tier_at(0).taker_fee(),
                pool_test_utils::default_taker_fee_multicoin(),
            );
            assert_eq!(
                schedule.tier_at(0).maker_fee(),
                pool_test_utils::default_maker_fee_multicoin(),
            );
            assert_eq!(from_epoch, epoch + 1);
            // The running ladder is still the old one.
            let now = pool.pool_fee_schedule(&policy, test.ctx());
            assert_eq!(now.tier_at(0).taker_fee(), pool_test_utils::default_taker_fee());
            return_shared(policy);
            return_shared(pool);
        };

        end(test);
    }

    #[test]
    /// When the destination class is itself being re-priced later than the move
    /// can land, the later of the two epochs is the one reported: that is when
    /// the reported ladder actually prices this pool.
    fun schedule_next_reports_the_later_of_the_two_staged_epochs() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);
        let epoch = test.ctx().epoch();

        coin_stage(&mut test, m.pool_id, multicoin_class<USDC>());
        test.next_epoch(OWNER);

        // Re-price the destination class one epoch after the move was staged.
        test.next_tx(OWNER);
        {
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            let mut policy = test.take_shared<FeePolicy>();
            policy.update_class(
                multicoin_class<USDC>(),
                vector[0],
                vector[30_000_000],
                vector[20_000_000],
                RETENTION,
                &cap,
                test.ctx(),
            );
            return_shared(policy);
            destroy(cap);
        };

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            let policy = test.take_shared<FeePolicy>();
            let (schedule, from_epoch) = pool.pool_fee_schedule_next(&policy);
            assert_eq!(schedule.tier_at(0).taker_fee(), 30_000_000);
            // The move was due at `epoch + 1`; the re-pricing at `epoch + 2`.
            assert_eq!(from_epoch, epoch + 2);
            return_shared(policy);
            return_shared(pool);
        };

        end(test);
    }

    #[test]
    /// Retention through a real pool. An order placed in the epoch a new
    /// retention was staged snapshots the old one; an order placed in the next
    /// epoch snapshots the new one. Before this the first order got the new
    /// retention at once, mid-epoch.
    fun an_order_is_held_to_the_retention_of_the_epoch_it_was_placed_in() {
        let mut test = begin(OWNER);
        let m = coin_market(&mut test);

        pool_test_utils::set_next_epoch_fee_for_testing<USDC>(
            pool_test_utils::default_taker_fee(),
            pool_test_utils::default_maker_fee(),
            7_500,
            &mut test,
        );

        let before = coin_order(&mut test, ALICE, &m, m.alice, true);
        assert!(before.order_inserted());
        assert_eq!(before.cancel_retention_bps(), pool_test_utils::default_cancel_retention_bps());

        test.next_epoch(OWNER);

        let after = coin_order(&mut test, ALICE, &m, m.alice, true);
        assert_eq!(after.cancel_retention_bps(), 7_500);

        // And the earlier order still carries the one it was placed under.
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(m.pool_id);
            assert_eq!(
                pool.get_order(before.order_id()).cancel_retention_bps(),
                pool_test_utils::default_cancel_retention_bps(),
            );
            return_shared(pool);
        };

        end(test);
    }

    // === A multicoin pool ===

    const ASSET_GOLD: u64 = 1;
    const MC_PRICE: u64 = 2_000_000_000;
    const MC_QUANTITY: u64 = 100;

    /// A multicoin pool, born into the multicoin USDC class, with Alice funded
    /// in quote and Bob in quote and GOLD.
    fun multicoin_market(test: &mut Scenario): (Market, CollectionCap) {
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

        (Market { pool_id, alice, bob }, collection_cap)
    }

    fun multicoin_order(
        test: &mut Scenario,
        trader: address,
        m: &Market,
        account: ID,
        is_bid: bool,
    ): OrderInfo {
        test.next_tx(trader);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
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
            MC_PRICE,
            MC_QUANTITY,
            is_bid,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        return_shared(ta);
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);

        order_info
    }

    /// Bob rests an ask of GOLD and Alice takes it. Returns (the rate Bob's
    /// order snapshotted as a maker, the taker fee Alice was charged).
    fun multicoin_trade(test: &mut Scenario, m: &Market): (u64, u64) {
        let ask = multicoin_order(test, BOB, m, m.bob, false);
        assert!(ask.order_inserted());
        let bid = multicoin_order(test, ALICE, m, m.alice, true);
        assert_eq!(bid.executed_quantity(), MC_QUANTITY);

        (ask.maker_fee_rate(), bid.paid_fees())
    }

    fun multicoin_stage(test: &mut Scenario, pool_id: ID, class_id: u16) {
        test.next_tx(OWNER);
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let mut policy = test.take_shared<FeePolicy>();
        pool.stage_pool_fee_class(&mut policy, class_id, &cap, test.ctx());
        return_shared(policy);
        return_shared(pool);
        destroy(cap);
    }

    fun multicoin_apply(test: &mut Scenario, pool_id: ID) {
        test.next_tx(OWNER);
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let mut policy = test.take_shared<FeePolicy>();
        pool.apply_pool_fee_class(&mut policy, &cap, test.ctx());
        return_shared(policy);
        return_shared(pool);
        destroy(cap);
    }

    fun multicoin_view(test: &mut Scenario, pool_id: ID): (u16, u16, u64, u64, u64) {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let class_id = pool.pool_fee_class();
        let (next_class, next_epoch) = pool.pool_fee_class_next(&policy);
        let (taker, maker) = pool.pool_trade_params(&policy, test.ctx());
        return_shared(policy);
        return_shared(pool);

        (class_id, next_class, next_epoch, taker, maker)
    }

    /// The quote `MC_QUANTITY` items at `MC_PRICE` trade for: an undivided
    /// product on a multicoin pool.
    fun multicoin_quote(): u64 { MC_QUANTITY * MC_PRICE }

    #[test]
    /// The same rules on a multicoin pool, end to end: staged, unchanged for the
    /// rest of that epoch, unchanged in the next until applied, then re-priced.
    /// The move here is downward, to the standard class at half the rate.
    fun multicoin_class_move_is_staged_then_lands_when_applied() {
        let mut test = begin(OWNER);
        let (m, collection_cap) = multicoin_market(&mut test);
        let staged_in = test.ctx().epoch();
        let old_taker = pool_test_utils::default_taker_fee_multicoin();
        let new_taker = pool_test_utils::default_taker_fee();

        multicoin_stage(&mut test, m.pool_id, standard_class<USDC>());
        let staged = event::events_by_type<PoolFeeClassStaged>();
        assert_eq!(staged.length(), 1);
        let (id, class_id, effective_epoch) = staged[0].pool_fee_class_staged_parts();
        assert_eq!(id, m.pool_id);
        assert_eq!(class_id, standard_class<USDC>());
        assert_eq!(effective_epoch, staged_in + 1);
        assert!(event::events_by_type<PoolFeeClassSet>().is_empty());

        let (class_id, next_class, next_epoch, taker, _) = multicoin_view(&mut test, m.pool_id);
        assert_eq!(class_id, multicoin_class<USDC>());
        assert_eq!(next_class, standard_class<USDC>());
        assert_eq!(next_epoch, staged_in + 1);
        assert_eq!(taker, old_taker);
        let (maker_rate, taker_fee) = multicoin_trade(&mut test, &m);
        assert_eq!(maker_rate, pool_test_utils::default_maker_fee_multicoin());
        assert_eq!(taker_fee, quote_fee::fee_from_scaled_rate(old_taker, multicoin_quote()));

        test.next_epoch(OWNER);
        let (_, taker_fee) = multicoin_trade(&mut test, &m);
        assert_eq!(taker_fee, quote_fee::fee_from_scaled_rate(old_taker, multicoin_quote()));

        multicoin_apply(&mut test, m.pool_id);
        let set = event::events_by_type<PoolFeeClassSet>();
        assert_eq!(set.length(), 1);
        let (id, class_id) = set[0].pool_fee_class_set_parts();
        assert_eq!(id, m.pool_id);
        assert_eq!(class_id, standard_class<USDC>());

        let (class_id, next_class, next_epoch, taker, maker) = multicoin_view(
            &mut test,
            m.pool_id,
        );
        assert_eq!(class_id, standard_class<USDC>());
        assert_eq!(next_class, standard_class<USDC>());
        assert_eq!(next_epoch, 0);
        assert_eq!(taker, new_taker);
        assert_eq!(maker, pool_test_utils::default_maker_fee());
        let (maker_rate, taker_fee) = multicoin_trade(&mut test, &m);
        assert_eq!(maker_rate, pool_test_utils::default_maker_fee());
        assert_eq!(taker_fee, quote_fee::fee_from_scaled_rate(new_taker, multicoin_quote()));

        destroy(collection_cap);
        end(test);
    }

    #[test, expected_failure(abort_code = fee_policy::EPoolFeeClassNotYetEffective)]
    fun multicoin_staged_move_cannot_be_applied_in_the_epoch_it_was_staged() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);
        multicoin_stage(&mut test, m.pool_id, standard_class<USDC>());
        multicoin_apply(&mut test, m.pool_id);
        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::ENoStagedPoolFeeClass)]
    fun multicoin_applying_with_nothing_staged_aborts() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);
        multicoin_apply(&mut test, m.pool_id);
        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EClassQuoteMismatch)]
    fun multicoin_staging_a_class_of_another_quote_aborts() {
        let mut test = begin(OWNER);
        let (m, _collection_cap) = multicoin_market(&mut test);
        multicoin_stage(&mut test, m.pool_id, multicoin_class<USDT>());
        abort 0
    }

    #[test]
    fun multicoin_schedule_next_reports_a_staged_move() {
        let mut test = begin(OWNER);
        let (m, collection_cap) = multicoin_market(&mut test);
        let epoch = test.ctx().epoch();

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
            let policy = test.take_shared<FeePolicy>();
            let (schedule, _) = pool.pool_fee_schedule_next(&policy);
            assert_eq!(
                schedule.tier_at(0).taker_fee(),
                pool_test_utils::default_taker_fee_multicoin(),
            );
            return_shared(policy);
            return_shared(pool);
        };

        multicoin_stage(&mut test, m.pool_id, standard_class<USDC>());

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(m.pool_id);
            let policy = test.take_shared<FeePolicy>();
            let (schedule, from_epoch) = pool.pool_fee_schedule_next(&policy);
            assert_eq!(schedule.tier_at(0).taker_fee(), pool_test_utils::default_taker_fee());
            assert_eq!(from_epoch, epoch + 1);
            let now = pool.pool_fee_schedule(&policy, test.ctx());
            assert_eq!(now.tier_at(0).taker_fee(), pool_test_utils::default_taker_fee_multicoin());
            return_shared(policy);
            return_shared(pool);
        };

        destroy(collection_cap);
        end(test);
    }
}
