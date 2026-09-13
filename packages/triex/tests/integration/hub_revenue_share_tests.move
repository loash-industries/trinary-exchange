/// End-to-end tests for trade hub revenue share.
///
/// The unit suites cover the ring (`fee_basis_tests`), the reserve arithmetic
/// (`multicoin_vault_tests`), the rate ladder (`fee_policy_hub_share_tests`) and
/// the beneficiary table (`hub_registry_tests`). These drive the whole thing
/// through real orders, because the two failure modes that matter most are only
/// reachable that way: a basis that counts the same fee twice, and a rate that
/// depends on when someone chose to settle.
#[test_only]
module triex::integration_hub_revenue_share_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test;
    use sui::{
        clock::Clock,
        coin::Coin,
        test_scenario::{Scenario, begin, end, return_shared}
    };
    use triex::{
        constants,
        fee_policy::{Self, FeePolicy},
        hub_registry::{Self, HubRegistry},
        integration_multicoin_test_utils as mc_utils,
        multicoin_pool::MultiCoinPool,
        quote_fee,
        registry,
        trading_account::TradingAccount,
        trading_account_tests::USDC
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xA;
    const BOB: address = @0xB;
    /// The hub operator's payout address. Deliberately not a trader.
    const OPERATOR: address = @0x0B0B;

    const ASSET_GOLD: u64 = 1;
    const HUB_CLASS: u16 = 7;

    // === Helpers ===

    fun funds(): u64 {
        1_000_000 * constants::float_scaling()
    }

    /// A pool, two funded accounts, gold in Bob's account, and a shared registry.
    fun setup(test: &mut Scenario): (ID, ID, ID, CollectionCap) {
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
        let alice_ta = mc_utils::create_trading_account_with_funds(ALICE, funds(), funds(), test);
        let bob_ta = mc_utils::create_trading_account_with_funds(BOB, funds(), funds(), test);

        // Bob needs gold to sell.
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            funds(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, BOB);

        test.next_tx(BOB);
        let mut bob = test.take_shared_by_id<TradingAccount>(bob_ta);
        let gold = test.take_from_sender<multicoin::Balance>();
        bob.deposit_multicoin(gold, test.ctx());
        return_shared(bob);

        hub_registry::init_for_testing(test.ctx());

        (pool_id, alice_ta, bob_ta, collection_cap)
    }

    /// Put `collection_id` in a class priced at `bps`, effective next epoch, and
    /// point its payouts at `OPERATOR`.
    fun configure_hub(collection_id: ID, bps: u64, test: &mut Scenario) {
        test.next_tx(OWNER);
        let mut policy = test.take_shared<FeePolicy>();
        let mut reg = test.take_shared<HubRegistry>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_hub_share_class(HUB_CLASS, bps, &cap, test.ctx());
        policy.assign_hub_share_class(collection_id, HUB_CLASS, &cap);
        reg.set_beneficiary(collection_id, OPERATOR, &cap);

        unit_test::destroy(cap);
        return_shared(reg);
        return_shared(policy);
    }

    /// Alice rests a bid. Returns (order_id, taker_fee_paid, maker_fee_escrowed).
    fun rest_a_bid(pool_id: ID, ta_id: ID, price: u64, qty: u64, test: &mut Scenario): (u64, u64, u64) {
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let proof = ta.generate_proof_as_owner(test.ctx());

        let order = pool.place_limit_order(
            &policy,
            &mut ta,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        let order_id = order.order_id();
        let taker_fee = order.paid_fees();
        let maker_fee = order.maker_fees();

        return_shared(ta);
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);
        (order_id, taker_fee, maker_fee)
    }

    /// Bob sells into the book, filling `qty` of whatever is resting.
    fun sell_into_the_book(pool_id: ID, ta_id: ID, price: u64, qty: u64, test: &mut Scenario) {
        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let proof = ta.generate_proof_as_owner(test.ctx());

        pool.place_limit_order(
            &policy,
            &mut ta,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        return_shared(ta);
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);
    }

    /// The identity that makes a basis trustworthy.
    ///
    /// With nothing settled, withdrawn or claimed, the recognized revenue sitting
    /// in the reserve is exactly `reserve - locked_maker_fees`, and the basis must
    /// equal it. Deposits add escrow and revenue together, refunds remove escrow
    /// from both sides, and recognition moves value between them — so any
    /// double-count shows up here immediately, and so does any missed site.
    fun assert_basis_matches_revenue(pool_id: ID, test: &mut Scenario) {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let revenue = pool.quote_fee_reserve_balance() - pool.locked_maker_fees();
        assert!(pool.hub_unsettled_basis() == (revenue as u128));
        // And solvency: the reserve covers every claim against it.
        assert!(
            (pool.quote_fee_reserve_balance() as u128)
                >= (pool.locked_maker_fees() as u128)
                    + (pool.hub_owed() as u128)
                    + pool.hub_holdback(),
        );
        return_shared(pool);
    }

    // === Tests ===

    /// Regression: the basis must count recognized revenue exactly once.
    ///
    /// `move_quote_to_fee_reserve` is the shared deposit primitive, reached both by
    /// the ask-proceeds loop with earned revenue and by `settle_trading_account`
    /// with a bid's `taker + maker`. Treating it as a recognition site on its own —
    /// and also crediting the taker half, and also the escrow at earn-out — counts
    /// one bid three times. That is not a rounding error: the holdback is a slice
    /// of the basis subtracted from the reserve, so an inflated basis becomes a
    /// claim on coins that were never collected, `withdrawable_pool_fees` underflows
    /// and aborts, and both the admin sweep and every future claim are dead for
    /// that pool. Trading keeps working, so nothing surfaces until someone tries to
    /// take money out.
    #[test]
    fun basis_counts_recognized_revenue_exactly_once() {
        let mut test = begin(OWNER);
        let (pool_id, alice_ta, bob_ta, collection_cap) = setup(&mut test);
        let price = 2 * constants::float_scaling();

        // 1. A resting bid: taker fee is revenue, maker fee is escrow. A basis that
        //    counted the deposit whole would already be wrong here.
        let (order_id, _, maker_fee) = rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        assert!(maker_fee > 0);
        assert_basis_matches_revenue(pool_id, &mut test);

        // 2. A partial fill earns out part of that escrow and charges the ask side
        //    out of proceeds — two recognition points in one transaction.
        sell_into_the_book(pool_id, bob_ta, price, 400, &mut test);
        assert_basis_matches_revenue(pool_id, &mut test);

        // 3. Cancelling the remainder refunds most of the leftover escrow and
        //    retains the rest as revenue.
        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut ta = test.take_shared_by_id<TradingAccount>(alice_ta);
            let proof = ta.generate_proof_as_owner(test.ctx());
            pool.cancel_order(&mut ta, &proof, order_id, &clock, test.ctx());
            return_shared(ta);
            return_shared(clock);
            return_shared(pool);
        };
        assert_basis_matches_revenue(pool_id, &mut test);

        // No escrow left outstanding, so the basis is now the whole reserve.
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            assert!(pool.locked_maker_fees() == 0);
            assert!(pool.hub_unsettled_basis() == (pool.quote_fee_reserve_balance() as u128));
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// The operator is paid its configured share, and the treasury keeps the rest.
    #[test]
    fun operator_is_paid_its_share_and_the_treasury_keeps_the_rest() {
        let mut test = begin(OWNER);
        let (pool_id, alice_ta, bob_ta, collection_cap) = setup(&mut test);
        let collection_id = {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let id = pool.collection_id();
            return_shared(pool);
            id
        };

        // 25% — a launch-partner rate, effective next epoch.
        configure_hub(collection_id, 2_500, &mut test);
        test.next_epoch(OWNER);

        let price = 2 * constants::float_scaling();
        rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        sell_into_the_book(pool_id, bob_ta, price, 1000, &mut test);

        let revenue;
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            // A fully-filled bid leaves no escrow, so the reserve is all revenue.
            assert!(pool.locked_maker_fees() == 0);
            revenue = pool.quote_fee_reserve_balance();
            assert!(revenue > 0);
            return_shared(pool);
        };

        // Settle, then claim.
        let expected_share = ((revenue as u128) * 2_500 / 10_000) as u64;
        test.next_tx(OWNER);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let reg = test.take_shared<HubRegistry>();
            let clock = test.take_shared<Clock>();

            assert!(pool.settle_hub_share(&policy, test.ctx()) == expected_share);
            assert!(pool.hub_owed() == expected_share);
            // Settling replaced a ceiling-rate holdback with the real figure, so the
            // treasury's share went up, not down.
            assert!(pool.withdrawable_pool_fees() == revenue - expected_share);

            assert!(pool.claim_hub_share(&policy, &reg, &clock, test.ctx()) == expected_share);
            assert!(pool.hub_owed() == 0);
            assert!(pool.quote_fee_reserve_balance() == revenue - expected_share);
            assert!(pool.withdrawable_pool_fees() == revenue - expected_share);

            return_shared(clock);
            return_shared(reg);
            return_shared(policy);
            return_shared(pool);
        };

        // The operator holds a coin for exactly its share — and it is the operator
        // who holds it, not the caller who paid for the transaction.
        test.next_tx(OPERATOR);
        {
            let paid = test.take_from_sender<Coin<USDC>>();
            assert!(paid.value() == expected_share);
            unit_test::destroy(paid);
        };

        // And the treasury can now sweep everything that is left, with no holdback
        // standing in the way.
        test.next_tx(OWNER);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let cap = registry::get_admin_cap_for_testing(test.ctx());

            let swept = pool.withdraw_pool_fees(&cap, revenue - expected_share, &clock, test.ctx());
            assert!(swept.value() == revenue - expected_share);
            assert!(pool.quote_fee_reserve_balance() == 0);

            unit_test::destroy(swept);
            unit_test::destroy(cap);
            return_shared(clock);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// A late settlement pays the rate of the epoch that earned the revenue, not
    /// whatever is live when someone gets round to calling it.
    ///
    /// This is what stops permissionless settlement from being a free option. If
    /// the rate were resolved at settle time, an operator would wait out a cut and
    /// rush ahead of a rise, and the admin would do the reverse — and since either
    /// may call it, whoever gains would always call first.
    #[test]
    fun a_late_settlement_uses_the_rate_of_the_epoch_that_earned_it() {
        let mut test = begin(OWNER);
        let (pool_id, alice_ta, bob_ta, collection_cap) = setup(&mut test);
        let collection_id = {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let id = pool.collection_id();
            return_shared(pool);
            id
        };

        // 30% from epoch 1.
        configure_hub(collection_id, 3_000, &mut test);
        test.next_epoch(OWNER);
        let earning_epoch = test.ctx().epoch();

        let price = 2 * constants::float_scaling();
        rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        sell_into_the_book(pool_id, bob_ta, price, 1000, &mut test);

        let revenue;
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            revenue = pool.quote_fee_reserve_balance();
            assert!(pool.hub_basis_at(earning_epoch) == revenue);
            return_shared(pool);
        };

        // Now cut the rate to 5%, twice over, so a two-slot ladder would have lost
        // the 30% entirely.
        test.next_tx(OWNER);
        {
            let mut policy = test.take_shared<FeePolicy>();
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            policy.stage_hub_share_class(HUB_CLASS, 500, &cap, test.ctx());
            unit_test::destroy(cap);
            return_shared(policy);
        };
        test.next_epoch(OWNER);
        test.next_tx(OWNER);
        {
            let mut policy = test.take_shared<FeePolicy>();
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            policy.stage_hub_share_class(HUB_CLASS, 100, &cap, test.ctx());
            unit_test::destroy(cap);
            return_shared(policy);
        };
        test.next_epoch(OWNER);

        // Settled two epochs late, and still priced at 30%.
        let expected_share = ((revenue as u128) * 3_000 / 10_000) as u64;
        test.next_tx(OWNER);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            assert!(pool.settle_hub_share(&policy, test.ctx()) == expected_share);
            return_shared(policy);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// An unconfigured hub settles to nothing, which is what makes deploying this
    /// a no-op until someone opts a hub in.
    #[test]
    fun an_unconfigured_hub_settles_to_nothing() {
        let mut test = begin(OWNER);
        let (pool_id, alice_ta, bob_ta, collection_cap) = setup(&mut test);

        let price = 2 * constants::float_scaling();
        rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        sell_into_the_book(pool_id, bob_ta, price, 1000, &mut test);

        test.next_tx(OWNER);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let revenue = pool.quote_fee_reserve_balance();

            assert!(pool.settle_hub_share(&policy, test.ctx()) == 0);
            assert!(pool.hub_owed() == 0);
            // And the holdback is gone, so the treasury gets the lot.
            assert!(pool.hub_holdback() == 0);
            assert!(pool.withdrawable_pool_fees() == revenue);

            return_shared(policy);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// A pool with nothing owed claims to zero rather than demanding a beneficiary.
    /// A payout cron batches many pools into one PTB and will meet plenty of idle
    /// ones; requiring an address there would let a single unconfigured pool abort
    /// the whole batch.
    #[test]
    fun claiming_an_idle_pool_is_a_noop_even_unconfigured() {
        let mut test = begin(OWNER);
        let (pool_id, _alice_ta, _bob_ta, collection_cap) = setup(&mut test);

        test.next_tx(OWNER);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let reg = test.take_shared<HubRegistry>();
            let clock = test.take_shared<Clock>();

            assert!(!reg.has_beneficiary(pool.collection_id()));
            assert!(pool.claim_hub_share(&policy, &reg, &clock, test.ctx()) == 0);

            return_shared(clock);
            return_shared(reg);
            return_shared(policy);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// But once something *is* owed, an absent beneficiary is a misconfiguration
    /// and aborts rather than banking the share. `hub_owed` stays encumbered, so
    /// setting an address later still pays.
    #[test]
    #[expected_failure(abort_code = triex::multicoin_pool::ENoHubBeneficiary)]
    fun claiming_without_a_beneficiary_aborts() {
        let mut test = begin(OWNER);
        let (pool_id, alice_ta, bob_ta, collection_cap) = setup(&mut test);
        let collection_id = {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let id = pool.collection_id();
            return_shared(pool);
            id
        };

        // A rate, but no payout address.
        test.next_tx(OWNER);
        {
            let mut policy = test.take_shared<FeePolicy>();
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            policy.stage_hub_share_class(HUB_CLASS, 1_000, &cap, test.ctx());
            policy.assign_hub_share_class(collection_id, HUB_CLASS, &cap);
            unit_test::destroy(cap);
            return_shared(policy);
        };
        test.next_epoch(OWNER);

        let price = 2 * constants::float_scaling();
        rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        sell_into_the_book(pool_id, bob_ta, price, 1000, &mut test);

        test.next_tx(OWNER);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let reg = test.take_shared<HubRegistry>();
        let clock = test.take_shared<Clock>();

        pool.claim_hub_share(&policy, &reg, &clock, test.ctx());

        return_shared(clock);
        return_shared(reg);
        return_shared(policy);
        return_shared(pool);
        unit_test::destroy(collection_cap);
        end(test);
    }

    /// Cancel retention is revenue and accrues like any other, so an operator is
    /// paid on it. Flagged in the design doc as a product decision; pinned here so
    /// changing the answer has to be deliberate.
    #[test]
    fun cancel_retention_accrues_to_the_hub() {
        let mut test = begin(OWNER);
        let (pool_id, alice_ta, _bob_ta, collection_cap) = setup(&mut test);
        let price = 2 * constants::float_scaling();

        let (order_id, _, maker_fee) = rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut ta = test.take_shared_by_id<TradingAccount>(alice_ta);
            let proof = ta.generate_proof_as_owner(test.ctx());
            pool.cancel_order(&mut ta, &proof, order_id, &clock, test.ctx());
            return_shared(ta);
            return_shared(clock);
            return_shared(pool);
        };

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let (_, retained) = quote_fee::split_released_fee(maker_fee, 2000);
            assert!(retained > 0);
            assert!(pool.hub_basis_at(test.ctx().epoch()) == retained);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }
}
