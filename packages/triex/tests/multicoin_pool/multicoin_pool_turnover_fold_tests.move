/// Pending maker turnover reaches the exchange-wide ring on every pool touch.
///
/// A maker's fee credit is queued in the pool it was earned on, so until it folds
/// only trades on that pool see it — the trader's tier depends on where they
/// trade. These pin that withdraw (the client's sweep), the permissionless
/// withdraw, cancel, modify and a self-match all land the credit in the ring, so
/// every other pool sharing the quote prices against it.
#[test_only]
module triex::multicoin_pool_turnover_fold_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test::{assert_eq, destroy};
    use sui::{clock::Clock, test_scenario::{Scenario, begin, end, return_shared}};
    use triex::{
        constants,
        fee_policy::FeePolicy,
        integration_multicoin_test_utils as mc_utils,
        multicoin_pool::MultiCoinPool,
        trading_account::TradingAccount,
        trading_account_tests::USDC
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    const ASSET_GOLD: u64 = 1;
    const ASSET_SILVER: u64 = 2;

    const QUANTITY: u64 = 100;

    /// Two pools on one quote, Alice and Bob funded, Bob holding gold to sell.
    /// Returns (gold pool, silver pool, alice, bob, collection cap).
    fun setup(test: &mut Scenario): (ID, ID, ID, ID, CollectionCap) {
        let (registry_id, collection_id, collection_cap) = mc_utils::setup_registry_with_multicoin(
            test,
        );
        let gold_pool = mc_utils::setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            test,
        );
        let silver_pool = mc_utils::setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_SILVER,
            test,
        );
        let funds = 1_000_000 * constants::float_scaling();
        let alice = mc_utils::create_trading_account_with_funds(ALICE, funds, funds, test);
        let bob = mc_utils::create_trading_account_with_funds(BOB, funds, funds, test);
        give_gold(&collection_cap, BOB, bob, test);
        give_gold(&collection_cap, ALICE, alice, test);

        (gold_pool, silver_pool, alice, bob, collection_cap)
    }

    fun give_gold(cap: &CollectionCap, owner: address, trading_account_id: ID, test: &mut Scenario) {
        test.next_tx(OWNER);
        {
            let mut collection = test.take_shared<Collection>();
            let gold = multicoin::mint_and_keep(
                cap,
                &mut collection,
                ASSET_GOLD,
                1_000_000 * constants::float_scaling(),
                test.ctx(),
            );
            return_shared(collection);
            transfer::public_transfer(gold, owner);
        };
        test.next_tx(owner);
        {
            let mut ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
            let gold = test.take_from_sender<multicoin::Balance>();
            ta.deposit_multicoin(gold, test.ctx());
            return_shared(ta);
        };
    }

    fun place(
        trader: address,
        pool_id: ID,
        trading_account_id: ID,
        quantity: u64,
        is_bid: bool,
        test: &mut Scenario,
    ): (u128, u64) {
        test.next_tx(trader);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let proof = ta.generate_proof_as_owner(test.ctx());
        let order = pool.place_limit_order(
            &policy,
            &mut ta,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            quantity,
            is_bid,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        return_shared(ta);
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);

        (order.order_id(), order.paid_fees())
    }

    /// Alice rests a bid on gold and Bob sells `fill` into it, so Alice holds a
    /// pending maker credit on the gold pool. Returns (order id, credit).
    fun alice_earns_maker_credit(
        gold_pool: ID,
        alice: ID,
        bob: ID,
        fill: u64,
        test: &mut Scenario,
    ): (u128, u128) {
        let (order_id, _) = place(ALICE, gold_pool, alice, QUANTITY, true, test);
        place(BOB, gold_pool, bob, fill, false, test);

        let credit = pool_turnover(gold_pool, alice, test) - ring(alice, test);
        assert!(credit > 0);
        (order_id, credit)
    }

    /// The exchange-wide ring on the trading account, with no pool's pending.
    fun ring(trading_account_id: ID, test: &mut Scenario): u128 {
        test.next_tx(OWNER);
        let ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let turnover = ta.fee_turnover<USDC>(test.ctx());
        return_shared(ta);
        turnover
    }

    /// What the next trade on `pool_id` resolves against: ring + that pool's pending.
    fun pool_turnover(pool_id: ID, trading_account_id: ID, test: &mut Scenario): u128 {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let turnover = pool.account_fee_turnover(&ta, test.ctx());
        return_shared(ta);
        return_shared(pool);
        turnover
    }

    #[test]
    fun pending_maker_credit_is_invisible_to_other_pools_until_folded() {
        let mut test = begin(OWNER);
        let (gold, silver, alice, bob, cap) = setup(&mut test);
        let (_, credit) = alice_earns_maker_credit(gold, alice, bob, QUANTITY, &mut test);

        // The gap this change closes: only the gold pool can see the credit.
        assert_eq!(ring(alice, &mut test), 0);
        assert_eq!(pool_turnover(gold, alice, &mut test), credit);
        assert_eq!(pool_turnover(silver, alice, &mut test), 0);

        destroy(cap);
        end(test);
    }

    #[test]
    fun withdraw_settled_amounts_folds_pending_turnover() {
        let mut test = begin(OWNER);
        let (gold, silver, alice, bob, cap) = setup(&mut test);
        let (_, credit) = alice_earns_maker_credit(gold, alice, bob, QUANTITY, &mut test);

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(gold);
            let mut ta = test.take_shared_by_id<TradingAccount>(alice);
            let proof = ta.generate_proof_as_owner(test.ctx());
            pool.withdraw_settled_amounts(&mut ta, &proof, test.ctx());
            return_shared(ta);
            return_shared(pool);
        };

        assert_eq!(ring(alice, &mut test), credit);
        // Exchange-wide now: the silver pool prices against it too ...
        assert_eq!(pool_turnover(silver, alice, &mut test), credit);
        // ... and the gold pool's view does not count it twice.
        assert_eq!(pool_turnover(gold, alice, &mut test), credit);

        destroy(cap);
        end(test);
    }

    #[test]
    fun permissionless_withdraw_folds_pending_turnover() {
        let mut test = begin(OWNER);
        let (gold, silver, alice, bob, cap) = setup(&mut test);
        let (_, credit) = alice_earns_maker_credit(gold, alice, bob, QUANTITY, &mut test);

        // Anyone may sweep Alice's proceeds to her account, and the fold rides along.
        test.next_tx(BOB);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(gold);
            let mut ta = test.take_shared_by_id<TradingAccount>(alice);
            pool.withdraw_settled_amounts_permissionless(&mut ta, test.ctx());
            return_shared(ta);
            return_shared(pool);
        };

        assert_eq!(ring(alice, &mut test), credit);
        assert_eq!(pool_turnover(silver, alice, &mut test), credit);

        destroy(cap);
        end(test);
    }

    #[test]
    fun withdraw_on_an_untouched_pool_leaves_turnover_alone() {
        let mut test = begin(OWNER);
        let (gold, _silver, alice, _bob, cap) = setup(&mut test);

        // Alice has never traded on gold: no pool account, nothing to fold. (The
        // permissionless variant aborts on an empty settlement, so only the
        // owner's withdraw reaches this case.)
        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(gold);
            let mut ta = test.take_shared_by_id<TradingAccount>(alice);
            let proof = ta.generate_proof_as_owner(test.ctx());
            pool.withdraw_settled_amounts(&mut ta, &proof, test.ctx());
            return_shared(ta);
            return_shared(pool);
        };

        assert_eq!(ring(alice, &mut test), 0);
        assert_eq!(pool_turnover(gold, alice, &mut test), 0);

        destroy(cap);
        end(test);
    }

    #[test]
    fun cancel_folds_pending_turnover() {
        let mut test = begin(OWNER);
        let (gold, silver, alice, bob, cap) = setup(&mut test);
        // A partial fill leaves the rest of Alice's bid resting to cancel.
        let (order_id, credit) = alice_earns_maker_credit(
            gold,
            alice,
            bob,
            QUANTITY / 2,
            &mut test,
        );

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(gold);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut ta = test.take_shared_by_id<TradingAccount>(alice);
            let proof = ta.generate_proof_as_owner(test.ctx());
            pool.cancel_order(&policy, &mut ta, &proof, order_id, &clock, test.ctx());
            return_shared(ta);
            return_shared(clock);
            return_shared(policy);
            return_shared(pool);
        };

        // Only the earned credit folds — cancel retention is revenue, not turnover.
        assert_eq!(ring(alice, &mut test), credit);
        assert_eq!(pool_turnover(silver, alice, &mut test), credit);

        destroy(cap);
        end(test);
    }

    #[test]
    fun modify_folds_pending_turnover() {
        let mut test = begin(OWNER);
        let (gold, silver, alice, bob, cap) = setup(&mut test);
        let (order_id, credit) = alice_earns_maker_credit(
            gold,
            alice,
            bob,
            QUANTITY / 2,
            &mut test,
        );

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(gold);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut ta = test.take_shared_by_id<TradingAccount>(alice);
            let proof = ta.generate_proof_as_owner(test.ctx());
            pool.modify_order(
                &policy,
                &mut ta,
                &proof,
                order_id,
                QUANTITY * 3 / 4,
                &clock,
                test.ctx(),
            );
            return_shared(ta);
            return_shared(clock);
            return_shared(policy);
            return_shared(pool);
        };

        assert_eq!(ring(alice, &mut test), credit);
        assert_eq!(pool_turnover(silver, alice, &mut test), credit);

        destroy(cap);
        end(test);
    }

    #[test]
    fun self_match_maker_credit_folds_in_the_same_order() {
        let mut test = begin(OWNER);
        let (gold, silver, alice, _bob, cap) = setup(&mut test);

        // Alice rests an ask, then crosses it herself.
        place(ALICE, gold, alice, QUANTITY, false, &mut test);
        let (_, taker_fee) = place(ALICE, gold, alice, QUANTITY, true, &mut test);

        // Both sides of the fill are hers and both are already in the ring:
        // nothing is left pending on gold, and silver sees the same total.
        let total = ring(alice, &mut test);
        assert_eq!(pool_turnover(gold, alice, &mut test), total);
        assert_eq!(pool_turnover(silver, alice, &mut test), total);
        // And the total is taker + maker, not just the taker fee.
        assert!(taker_fee > 0);
        assert!(total > (taker_fee as u128));

        destroy(cap);
        end(test);
    }
}
