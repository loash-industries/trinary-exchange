/// End-to-end tests for trade hub revenue share, eager-split design.
///
/// The unit suites cover the reserve arithmetic (`multicoin_vault_tests`) and
/// the staged rate pair and beneficiary mapping
/// (`fee_policy_operator_share_tests`). These drive the whole thing through
/// real orders, because the two failure modes that matter most are only
/// reachable that way: a credit that counts the same fee twice (or counts
/// refundable escrow at all), and a payout that reaches the wrong party or
/// strands the other's.
#[test_only]
module triex::integration_hub_revenue_share_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test;
    use sui::{clock::Clock, coin::Coin, test_scenario::{Scenario, begin, end, return_shared}};
    use token::cred::CRED;
    use triex::{
        constants,
        fee_policy::FeePolicy,
        integration_multicoin_test_utils as mc_utils,
        multicoin_pool::MultiCoinPool,
        pool_test_utils,
        quote_fee,
        registry::{Self, Registry},
        trading_account::TradingAccount,
        trading_account_tests::USDC
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xA;
    const BOB: address = @0xB;
    /// The hub operator's payout address, registered through the adapter
    /// witness. Deliberately not a trader, and deliberately not the deployer:
    /// deployment pins nothing.
    const OPERATOR: address = @0x0B0B;
    /// The treasury's payout address. Deliberately not the admin who signs.
    const TREASURY: address = @0x77EA;

    const ASSET_GOLD: u64 = 1;
    const ASSET_SILVER: u64 = 2;
    const HUB_CLASS: u16 = 7;
    /// `fee_policy::GENESIS_OPERATOR_SHARE_BPS` — the launch rate class 0
    /// carries, mirrored here because the source constant is private.
    const GENESIS_SHARE_BPS: u64 = 2000;

    /// Stands in for the witness the audited adapter package mints after
    /// checking the caller's `OwnerCap<StorageUnit>` against the collection.
    public struct HubAdapterWitness has drop {}

    // === Helpers ===

    fun funds(): u64 {
        1_000_000 * constants::float_scaling()
    }

    /// Register `beneficiary` as `collection_id`'s payout address the way
    /// production does: the admin registers the adapter type once, and the
    /// adapter's witness authorizes the write.
    fun pin_beneficiary(collection_id: ID, beneficiary: address, test: &mut Scenario) {
        test.next_tx(OWNER);
        let mut policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.set_operator_adapter<HubAdapterWitness>(&cap);
        policy.register_operator_beneficiary_with_witness(
            collection_id,
            beneficiary,
            HubAdapterWitness {},
        );

        unit_test::destroy(cap);
        return_shared(policy);
    }

    /// A pool, an adapter-registered beneficiary (`OPERATOR` — deployment
    /// itself pins nothing), two funded accounts, gold in Bob's account, and
    /// the treasury pointed at a distinct address.
    ///
    /// Returns `(pool_id, collection_id, registry_id, alice_ta, bob_ta, cap)`.
    fun setup(test: &mut Scenario): (ID, ID, ID, ID, ID, CollectionCap) {
        let (registry_id, collection_id, collection_cap) = mc_utils::setup_registry_with_multicoin(
            test,
        );
        let pool_id = mc_utils::setup_multicoin_pool(
            OPERATOR,
            registry_id,
            collection_id,
            ASSET_GOLD,
            test,
        );
        pin_beneficiary(collection_id, OPERATOR, test);
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

        // The treasury leg of a claim pays a configured address, not the admin
        // who happens to sign — point it somewhere no other actor uses.
        test.next_tx(OWNER);
        {
            let mut reg = test.take_shared_by_id<Registry>(registry_id);
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            reg.set_treasury_address(TREASURY, &cap);
            unit_test::destroy(cap);
            return_shared(reg);
        };

        (pool_id, collection_id, registry_id, alice_ta, bob_ta, collection_cap)
    }

    /// Put `collection_id` in a class priced at `bps`, effective next epoch.
    /// The payout address needs no configuring here: `setup` already registered
    /// `OPERATOR` through the adapter witness.
    fun configure_hub(collection_id: ID, bps: u64, test: &mut Scenario) {
        test.next_tx(OWNER);
        let mut policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_operator_share_class(HUB_CLASS, bps, &cap, test.ctx());
        policy.assign_operator_share_class(collection_id, HUB_CLASS, &cap);

        unit_test::destroy(cap);
        return_shared(policy);
    }

    /// Admin-destroy the registered mapping, leaving the collection with a
    /// rate but no payout address.
    fun destroy_beneficiary(collection_id: ID, test: &mut Scenario) {
        test.next_tx(OWNER);
        let mut policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        policy.destroy_operator_beneficiary(collection_id, &cap);
        unit_test::destroy(cap);
        return_shared(policy);
    }

    /// Alice rests a bid. Returns (order_id, taker_fee_paid, maker_fee_escrowed).
    fun rest_a_bid(
        pool_id: ID,
        ta_id: ID,
        price: u64,
        qty: u64,
        test: &mut Scenario,
    ): (u64, u64, u64) {
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

    fun cancel_the_order(pool_id: ID, ta_id: ID, order_id: u64, test: &mut Scenario) {
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let proof = ta.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&policy, &mut ta, &proof, order_id, &clock, test.ctx());
        return_shared(ta);
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);
    }

    /// Alice pulls every quote she has resting, in one transaction.
    fun cancel_all_the_orders(pool_id: ID, ta_id: ID, test: &mut Scenario) {
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let proof = ta.generate_proof_as_owner(test.ctx());
        pool.cancel_all_orders(&policy, &mut ta, &proof, &clock, test.ctx());
        return_shared(ta);
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);
    }

    /// The same, by explicit id list — the other batch entry point.
    fun cancel_these_orders(pool_id: ID, ta_id: ID, order_ids: vector<u64>, test: &mut Scenario) {
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let proof = ta.generate_proof_as_owner(test.ctx());
        pool.cancel_orders(&policy, &mut ta, &proof, order_ids, &clock, test.ctx());
        return_shared(ta);
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);
    }

    /// A rate and an order size chosen so that one order's retained escrow is
    /// *below the flooring threshold*: `retained x 1 / 10000 < 1`. Recognized
    /// one order at a time, the hub is credited nothing at all, however many
    /// orders are pulled. Recognized once over the batch, it is credited the
    /// floor of the sum. The gap is the whole point of the batching, so the
    /// numbers are derived here and asserted by the callers rather than pinned
    /// as literals.
    ///
    /// Returns `(bps, price, num_orders)`.
    fun sub_threshold_quote_params(): (u64, u64, u64) {
        (1, 1_388_611, 8)
    }

    /// Escrow one `sub_threshold_quote_params` order retains when cancelled
    /// unfilled: the whole maker fee, narrowed by `cancel_retention_bps`.
    fun retained_per_order(maker_fee: u64): u64 {
        let (_, retained) = quote_fee::split_released_fee(
            maker_fee,
            pool_test_utils::default_cancel_retention_bps(),
        );
        retained
    }

    fun share_of(amount: u128, bps: u64): u64 {
        (amount * (bps as u128) / (quote_fee::fee_precision() as u128)) as u64
    }

    /// Solvency: the reserve covers both claims against it, always — asserted
    /// against the vault's own `encumbered()`, so this tests the invariant as
    /// defined, not a restatement that could drift from it.
    fun assert_solvent(pool_id: ID, test: &mut Scenario) {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        assert!((pool.quote_fee_reserve_balance() as u128) >= pool.encumbered());
        return_shared(pool);
    }

    /// The eager split floors per recognition, so over a round of recognitions
    /// the credit sits in `[exact − recognitions, exact]` where
    /// `exact = revenue × bps / fee_precision()`. Every test here makes at most
    /// four recognitions, so the band allows four units of flooring.
    fun assert_share_in_band(owed: u128, revenue: u128, bps: u64) {
        let exact = revenue * (bps as u128) / (quote_fee::fee_precision() as u128);
        assert!(owed <= exact);
        assert!(owed + 4 >= exact);
    }

    fun operator_owed(pool_id: ID, test: &mut Scenario): u64 {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let owed = pool.operator_owed();
        return_shared(pool);
        owed
    }

    /// Everything the system holds, in each asset: the vault's free balances,
    /// the fee reserve, and both traders' free balances. Settled amounts a
    /// trader has not yet withdrawn are coins sitting in the vault, so they are
    /// counted where the coins are. Returns `(gold, quote, cred)`.
    ///
    /// Trading only ever moves units between these places; only a fee payout
    /// removes any — so across placements, fills, cancels and settlement
    /// withdrawals this total is invariant, and after a claim it is short by
    /// exactly the two coins the claim minted.
    fun system_totals(
        pool_id: ID,
        collection_id: ID,
        trading_accounts: vector<ID>,
        test: &mut Scenario,
    ): (u64, u64, u64) {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let (vault_base, vault_quote, vault_cred) = pool.vault_balances();
        let mut base = vault_base;
        let mut quote = vault_quote + pool.quote_fee_reserve_balance();
        let mut cred = vault_cred;
        return_shared(pool);

        let mut i = 0;
        while (i < trading_accounts.length()) {
            let ta = test.take_shared_by_id<TradingAccount>(trading_accounts[i]);
            base = base + ta.multicoin_balance(collection_id, ASSET_GOLD);
            quote = quote + ta.balance<USDC>();
            cred = cred + ta.balance<CRED>();
            return_shared(ta);
            i = i + 1;
        };

        (base, quote, cred)
    }

    fun withdraw_settled(trader: address, pool_id: ID, ta_id: ID, test: &mut Scenario) {
        test.next_tx(trader);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let proof = ta.generate_proof_as_owner(test.ctx());
        pool.withdraw_settled_amounts(&mut ta, &proof, test.ctx());
        return_shared(ta);
        return_shared(pool);
    }

    // === Tests ===

    /// Regression: the hub is credited on recognized revenue exactly once, and
    /// never on refundable escrow.
    ///
    /// The band arithmetic is what makes this a strong exactly-once check
    /// without replaying per-fill flooring: each recognition credits
    /// `floor(amount × bps)`, so over `n` recognitions the total credit sits in
    /// `[R × bps/10000 − n, R × bps/10000]` where `R` is total recognized
    /// revenue. A double-counted site lands far above the band; a missed site
    /// far below; escrow counted at deposit shows up as a credit while the
    /// order is still open.
    #[test]
    fun operator_owed_counts_recognized_revenue_exactly_once() {
        let mut test = begin(OWNER);
        let (pool_id, collection_id, _, alice_ta, bob_ta, collection_cap) = setup(&mut test);

        // Ceiling rate, so any escrow miscount is as visible as possible.
        let bps = constants::max_operator_share_bps();
        configure_hub(collection_id, bps, &mut test);
        test.next_epoch(OWNER);

        let price = 2 * constants::float_scaling();

        // 1. A resting bid: the taker fee is zero (nothing filled) and the maker
        //    fee is refundable escrow. A credit that counted the deposit whole
        //    would already be wrong here.
        let (order_id, taker_fee, maker_fee) = rest_a_bid(
            pool_id,
            alice_ta,
            price,
            1000,
            &mut test,
        );
        assert!(taker_fee == 0);
        assert!(maker_fee > 0);
        assert!(operator_owed(pool_id, &mut test) == 0);
        assert_solvent(pool_id, &mut test);

        // 2. A partial fill earns out part of that escrow and charges the ask
        //    side out of proceeds — two recognitions in one transaction.
        sell_into_the_book(pool_id, bob_ta, price, 400, &mut test);
        assert_solvent(pool_id, &mut test);

        // 3. Cancelling the remainder refunds most of the leftover escrow and
        //    retains the rest as revenue — the third recognition.
        cancel_the_order(pool_id, alice_ta, order_id, &mut test);
        assert_solvent(pool_id, &mut test);

        // Everything has resolved: no escrow outstanding, so the reserve is
        // exactly the recognized revenue, and the credits must band around its
        // share. Four recognition events happened (bid escrow earn-out, ask
        // taker fee, ask maker charged nothing here — Bob was the taker — and
        // the cancel retention), so allow one unit of flooring per event.
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            assert!(pool.locked_maker_fees() == 0);
            let revenue = pool.quote_fee_reserve_balance() as u128;
            let owed = pool.operator_owed() as u128;
            assert_share_in_band(owed, revenue, bps);
            // And the treasury's view is the exact complement.
            assert!((pool.withdrawable_pool_fees() as u128) == revenue - owed);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// One permissionless claim pays both parties: the operator's accrued share
    /// to the beneficiary, the treasury's remainder to the treasury address.
    #[test]
    fun one_claim_pays_the_operator_and_the_treasury() {
        let mut test = begin(OWNER);
        let (pool_id, collection_id, registry_id, alice_ta, bob_ta, collection_cap) = setup(
            &mut test,
        );

        // 25% — a launch-partner rate, effective next epoch.
        configure_hub(collection_id, 2_500, &mut test);
        test.next_epoch(OWNER);

        let price = 2 * constants::float_scaling();
        rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        sell_into_the_book(pool_id, bob_ta, price, 1000, &mut test);

        let (revenue, share) = {
            test.next_tx(OWNER);
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            // A fully-filled bid leaves no escrow, so the reserve is all revenue.
            assert!(pool.locked_maker_fees() == 0);
            let revenue = pool.quote_fee_reserve_balance();
            let share = pool.operator_owed();
            assert!(revenue > 0);
            assert!(share > 0);
            return_shared(pool);
            (revenue, share)
        };

        // The claim: no capability, both destinations from configuration.
        test.next_tx(BOB); // any caller
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let triex_reg = test.take_shared_by_id<Registry>(registry_id);
            let clock = test.take_shared<Clock>();

            let (hub_paid, treasury_paid) = pool.claim_operator_share(
                &policy,
                &triex_reg,
                &clock,
                test.ctx(),
            );
            assert!(hub_paid == share);
            assert!(treasury_paid == revenue - share);
            assert!(pool.operator_owed() == 0);
            assert!(pool.quote_fee_reserve_balance() == 0);

            return_shared(clock);
            return_shared(triex_reg);
            return_shared(policy);
            return_shared(pool);
        };

        // The operator holds a coin for exactly its share — the operator, not
        // the caller who paid for the transaction.
        test.next_tx(OPERATOR);
        {
            let paid = test.take_from_sender<Coin<USDC>>();
            assert!(paid.value() == share);
            unit_test::destroy(paid);
        };

        // And the treasury address holds the remainder.
        test.next_tx(TREASURY);
        {
            let swept = test.take_from_sender<Coin<USDC>>();
            assert!(swept.value() == revenue - share);
            unit_test::destroy(swept);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// The admin sweep pays the operator in the same transaction, before the
    /// treasury takes anything.
    #[test]
    fun the_admin_sweep_pays_the_operator_in_the_same_transaction() {
        let mut test = begin(OWNER);
        let (pool_id, collection_id, _, alice_ta, bob_ta, collection_cap) = setup(&mut test);

        configure_hub(collection_id, 2_500, &mut test);
        test.next_epoch(OWNER);

        let price = 2 * constants::float_scaling();
        rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        sell_into_the_book(pool_id, bob_ta, price, 1000, &mut test);

        test.next_tx(OWNER);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let cap = registry::get_admin_cap_for_testing(test.ctx());

            let share = pool.operator_owed();
            let remainder = pool.withdrawable_pool_fees();
            assert!(share > 0);

            let swept = pool.withdraw_pool_fees(&policy, &cap, remainder, &clock, test.ctx());
            assert!(swept.value() == remainder);
            assert!(pool.operator_owed() == 0);
            assert!(pool.quote_fee_reserve_balance() == 0);

            unit_test::destroy(swept);
            unit_test::destroy(cap);
            return_shared(clock);
            return_shared(policy);
            return_shared(pool);

            // The operator's coin arrived in the same transaction.
            test.next_tx(OPERATOR);
            let paid = test.take_from_sender<Coin<USDC>>();
            assert!(paid.value() == share);
            unit_test::destroy(paid);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// A staged rate change applies only to revenue recognized from the next
    /// epoch on. Revenue already credited is untouched — there is nothing left
    /// to re-price.
    #[test]
    fun a_staged_rate_change_applies_only_from_the_next_epoch() {
        let mut test = begin(OWNER);
        let (pool_id, collection_id, _, alice_ta, bob_ta, collection_cap) = setup(&mut test);

        // 30% from epoch 1.
        configure_hub(collection_id, 3_000, &mut test);
        test.next_epoch(OWNER);

        let price = 2 * constants::float_scaling();
        rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        sell_into_the_book(pool_id, bob_ta, price, 1000, &mut test);

        let (revenue_1, owed_1) = {
            test.next_tx(OWNER);
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let r = pool.quote_fee_reserve_balance();
            let o = pool.operator_owed();
            return_shared(pool);
            (r as u128, o as u128)
        };
        // Credited at 30%, banded for per-recognition flooring.
        assert_share_in_band(owed_1, revenue_1, 3_000);

        // Cut the rate to 5%. The already-credited 30% is history the cut
        // cannot reach; only new revenue prices at 5%.
        test.next_tx(OWNER);
        {
            let mut policy = test.take_shared<FeePolicy>();
            let cap = registry::get_admin_cap_for_testing(test.ctx());
            policy.stage_operator_share_class(HUB_CLASS, 500, &cap, test.ctx());
            unit_test::destroy(cap);
            return_shared(policy);
        };
        test.next_epoch(OWNER);

        rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        sell_into_the_book(pool_id, bob_ta, price, 1000, &mut test);

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let revenue_2 = (pool.quote_fee_reserve_balance() as u128) - revenue_1;
            let owed_2 = (pool.operator_owed() as u128) - owed_1;
            // The second round credited at 5%, not 30% and not a blend.
            assert_share_in_band(owed_2, revenue_2, 500);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// An unconfigured hub accrues nothing, cancels still work, and the whole
    /// reserve is immediately the treasury's — deploying this changes nothing
    /// until someone opts a hub in, with no settle step in front of the sweep.
    #[test]
    fun an_unconfigured_hub_accrues_at_the_genesis_rate_and_never_blocks() {
        let mut test = begin(OWNER);
        let (pool_id, _, _, alice_ta, bob_ta, collection_cap) = setup(&mut test);

        let price = 2 * constants::float_scaling();
        let (order_id, _, _) = rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        sell_into_the_book(pool_id, bob_ta, price, 400, &mut test);
        // Cancellation resolves the rate too, and must not abort on the absent
        // configuration.
        cancel_the_order(pool_id, alice_ta, order_id, &mut test);

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let revenue = pool.quote_fee_reserve_balance();
            assert!(revenue > 0);
            // No class is assigned to this collection, so it resolves through
            // the genesis default — which is live, not zero. An unconfigured
            // hub accrues from the first fill; opting in is about *where* the
            // share is paid, not whether it is earned.
            let owed = pool.operator_owed();
            assert!(owed > 0);
            assert_share_in_band(owed as u128, revenue as u128, GENESIS_SHARE_BPS);
            // And it is withheld from the treasury until there is someone to
            // pay it to: encumbered, not banked and not lost.
            // `claiming_without_a_beneficiary_aborts` pins that the claim
            // refuses rather than reassigning it.
            assert!(pool.withdrawable_pool_fees() == revenue - owed);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// A pool with nothing owed and nothing earned claims to zero rather than
    /// demanding a beneficiary — even after the admin has destroyed the
    /// mapping. A payout cron batches many pools into one PTB and will meet
    /// plenty of idle ones; requiring an address there would let a single
    /// unconfigured pool abort the whole batch.
    #[test]
    fun claiming_an_idle_pool_is_a_noop_even_without_a_beneficiary() {
        let mut test = begin(OWNER);
        let (pool_id, collection_id, _, _alice_ta, _bob_ta, collection_cap) = setup(&mut test);

        destroy_beneficiary(collection_id, &mut test);

        test.next_tx(OWNER);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let triex_reg = test.take_shared<Registry>();
            let clock = test.take_shared<Clock>();

            assert!(policy.operator_beneficiary(collection_id).is_none());
            let (hub_paid, treasury_paid) = pool.claim_operator_share(
                &policy,
                &triex_reg,
                &clock,
                test.ctx(),
            );
            assert!(hub_paid == 0);
            assert!(treasury_paid == 0);

            return_shared(clock);
            return_shared(triex_reg);
            return_shared(policy);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// But once something *is* owed, a destroyed mapping aborts the claim
    /// rather than banking the share. `operator_owed` stays encumbered, so a
    /// redeployment restoring the mapping still pays.
    #[test]
    #[expected_failure(abort_code = triex::multicoin_pool::ENoOperatorBeneficiary)]
    fun claiming_without_a_beneficiary_aborts() {
        let mut test = begin(OWNER);
        let (pool_id, collection_id, _, alice_ta, bob_ta, collection_cap) = setup(&mut test);

        // A rate, but the payout mapping destroyed out from under it.
        configure_hub(collection_id, 1_000, &mut test);
        destroy_beneficiary(collection_id, &mut test);
        test.next_epoch(OWNER);

        let price = 2 * constants::float_scaling();
        rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        sell_into_the_book(pool_id, bob_ta, price, 1000, &mut test);

        test.next_tx(OWNER);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let triex_reg = test.take_shared<Registry>();
        let clock = test.take_shared<Clock>();

        pool.claim_operator_share(&policy, &triex_reg, &clock, test.ctx());

        return_shared(clock);
        return_shared(triex_reg);
        return_shared(policy);
        return_shared(pool);
        unit_test::destroy(collection_cap);
        end(test);
    }

    /// Cancel retention is revenue and is split like any other, so an operator
    /// is paid on it — at the rate live when the cancel lands. Flagged in the
    /// design doc as a product decision; pinned here so changing the answer has
    /// to be deliberate. Exact, not banded: a lone cancel is one recognition.
    #[test]
    fun cancel_retention_credits_the_hub() {
        let mut test = begin(OWNER);
        let (pool_id, collection_id, _, alice_ta, _bob_ta, collection_cap) = setup(&mut test);

        let bps = constants::max_operator_share_bps();
        configure_hub(collection_id, bps, &mut test);
        test.next_epoch(OWNER);

        let price = 2 * constants::float_scaling();
        let (order_id, _, maker_fee) = rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        cancel_the_order(pool_id, alice_ta, order_id, &mut test);

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let (_, retained) = quote_fee::split_released_fee(maker_fee, 2000);
            assert!(retained > 0);
            let expected =
                (
                    ((retained as u128) * (bps as u128)) / (quote_fee::fee_precision() as u128),
                ) as u64;
            assert!(pool.operator_owed() == expected);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test]
    fun a_cancel_batch_floors_once_not_once_per_order() {
        // The hub's share is computed where revenue is recognized, and it
        // floors. A cancel's retained escrow is the smallest figure the system
        // produces — one order's maker fee, already narrowed by
        // `cancel_retention_bps` — so recognizing each cancel separately floors
        // repeatedly on a number that is frequently below the rate's threshold.
        // A market maker pulling a book of quotes is exactly that case, and it
        // is not a rounding nuisance: the hub is credited *zero*, permanently,
        // on revenue the treasury banks in full.
        let mut test = begin(OWNER);
        let (pool_id, collection_id, _, alice_ta, _bob_ta, collection_cap) = setup(&mut test);

        let (bps, price, num_orders) = sub_threshold_quote_params();
        configure_hub(collection_id, bps, &mut test);
        test.next_epoch(OWNER);

        let mut maker_fee_each = 0;
        let mut i = 0;
        while (i < num_orders) {
            let (_, _, maker_fee) = rest_a_bid(pool_id, alice_ta, price, 1, &mut test);
            maker_fee_each = maker_fee;
            i = i + 1;
        };

        let retained_each = retained_per_order(maker_fee_each);
        let batch_total = (retained_each as u128) * (num_orders as u128);

        // The regime this test exists for: one order alone credits nothing, so
        // per-order recognition would credit nothing N times over.
        assert!(share_of(retained_each as u128, bps) == 0);
        // Batched, the same revenue clears the threshold.
        let expected = share_of(batch_total, bps);
        assert!(expected > 0);

        cancel_all_the_orders(pool_id, alice_ta, &mut test);

        assert!(operator_owed(pool_id, &mut test) == expected);
        assert_solvent(pool_id, &mut test);

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test]
    fun the_explicit_id_cancel_batch_floors_once_too() {
        // `cancel_orders` is the other batch entry point and must not be the
        // one that regresses: same rate, same orders, same credit.
        let mut test = begin(OWNER);
        let (pool_id, collection_id, _, alice_ta, _bob_ta, collection_cap) = setup(&mut test);

        let (bps, price, num_orders) = sub_threshold_quote_params();
        configure_hub(collection_id, bps, &mut test);
        test.next_epoch(OWNER);

        let mut order_ids = vector[];
        let mut maker_fee_each = 0;
        let mut i = 0;
        while (i < num_orders) {
            let (order_id, _, maker_fee) = rest_a_bid(pool_id, alice_ta, price, 1, &mut test);
            order_ids.push_back(order_id);
            maker_fee_each = maker_fee;
            i = i + 1;
        };

        let retained_each = retained_per_order(maker_fee_each);
        let expected = share_of((retained_each as u128) * (num_orders as u128), bps);
        assert!(share_of(retained_each as u128, bps) == 0);
        assert!(expected > 0);

        cancel_these_orders(pool_id, alice_ta, order_ids, &mut test);

        assert!(operator_owed(pool_id, &mut test) == expected);
        assert_solvent(pool_id, &mut test);

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test]
    fun batching_recognition_does_not_change_a_single_cancel() {
        // The deferral is a property of the batch entry points only. One cancel
        // recognizes on its own, at the same instant it always did, and credits
        // the same floor — so the batching cannot have moved the single-cancel
        // path's rounding in either direction.
        let mut test = begin(OWNER);
        let (pool_id, collection_id, _, alice_ta, _bob_ta, collection_cap) = setup(&mut test);

        let (bps, price, _) = sub_threshold_quote_params();
        configure_hub(collection_id, bps, &mut test);
        test.next_epoch(OWNER);

        let (order_id, _, maker_fee) = rest_a_bid(pool_id, alice_ta, price, 1, &mut test);
        let retained = retained_per_order(maker_fee);
        assert!(retained > 0);

        cancel_the_order(pool_id, alice_ta, order_id, &mut test);

        // Below the threshold on its own: the dust stays in the reserve as
        // treasury revenue rather than being credited or lost.
        assert!(operator_owed(pool_id, &mut test) == share_of(retained as u128, bps));
        assert_solvent(pool_id, &mut test);

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// Deploying a pool — first or otherwise, by anyone — pins nothing.
    /// Deployment is permissionless and proves nothing about who operates the
    /// hub, so the mapping stays absent until the adapter witness writes it;
    /// this is what closes the capture-by-first-deployment hole.
    #[test]
    fun pool_deployment_does_not_pin_a_beneficiary() {
        let mut test = begin(OWNER);
        let (registry_id, collection_id, collection_cap) = mc_utils::setup_registry_with_multicoin(
            &mut test,
        );

        mc_utils::setup_multicoin_pool(ALICE, registry_id, collection_id, ASSET_GOLD, &mut test);
        test.next_tx(OWNER);
        {
            let policy = test.take_shared<FeePolicy>();
            assert!(policy.operator_beneficiary(collection_id).is_none());
            return_shared(policy);
        };

        // The adapter-witnessed registration is what pins, and first write
        // wins: a later registration — here for a second pool's deployer —
        // leaves the mapping untouched. The contracts offer no re-point, so a
        // hub changing hands settles outside Triex.
        pin_beneficiary(collection_id, OPERATOR, &mut test);
        mc_utils::setup_multicoin_pool(ALICE, registry_id, collection_id, ASSET_SILVER, &mut test);
        pin_beneficiary(collection_id, ALICE, &mut test);
        test.next_tx(OWNER);
        {
            let policy = test.take_shared<FeePolicy>();
            assert!(policy.operator_beneficiary(collection_id) == option::some(OPERATOR));
            return_shared(policy);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// Acceptance: a complete lifecycle on the pool type that actually carries
    /// the revenue share accounts for every unit that entered — with the share
    /// active and every flooring site forced to floor.
    ///
    /// The suite's other conservation tests run on the coin `Pool`, whose vault
    /// has no `operator_owed`, and the claim test above drains the reserve to
    /// zero only because its clean full fill leaves no locked residue. This is
    /// the missing case: partial fills at a price with a raw-unit tail, a
    /// cancel of the remainder, both traders withdrawing everything they are
    /// owed, and one permissionless claim paying both parties — after which
    /// the vault must hold *nothing* except the residue its documentation
    /// admits to: up to one raw quote unit per escrow release, permanently
    /// counted as locked. Asserted three ways, so a leak cannot hide:
    /// destinations sum back to the baseline exactly, the vault's free
    /// balances are zero in all three assets, and the residue respects its
    /// documented per-release bound.
    #[test]
    fun full_lifecycle_leaves_nothing_behind_but_the_pinned_residue() {
        let mut test = begin(OWNER);
        let (pool_id, collection_id, registry_id, alice_ta, bob_ta, collection_cap) = setup(
            &mut test,
        );
        let trading_accounts = vector[alice_ta, bob_ta];

        // 33.33%, so the operator credit floors at every recognition rather
        // than dividing anything evenly.
        configure_hub(collection_id, 3_333, &mut test);
        test.next_epoch(OWNER);

        // A price with a raw-unit tail: no bite's notional, fee, split or
        // share credit lands on a whole number.
        let price = 3 * constants::float_scaling() + 7;
        let bites = vector[13u64, 7, 23, 11, 29, 17, 3, 41, 5, 19];
        let mut total_bites = 0;
        let mut b = 0;
        while (b < bites.length()) {
            total_bites = total_bites + bites[b];
            b = b + 1;
        };
        // Rest more than the bites will consume, so a remainder is left to
        // cancel and the cancel-retention leg recognizes revenue too.
        let quantity = total_bites + 20;

        // Baseline after all setup, so pool-creation costs sit outside the
        // window.
        let (base_before, quote_before, cred_before) = system_totals(
            pool_id,
            collection_id,
            trading_accounts,
            &mut test,
        );

        let (order_id, _, maker_fee) = rest_a_bid(pool_id, alice_ta, price, quantity, &mut test);
        assert!(maker_fee > 0);

        // Bob eats the bid down in ten uneven bites. Each fill recognizes
        // escrow and charges his taker fee out of proceeds; the reserve must
        // cover its claims at every step, and no fill may move value in or
        // out of the system.
        let mut i = 0;
        while (i < bites.length()) {
            sell_into_the_book(pool_id, bob_ta, price, bites[i], &mut test);
            assert_solvent(pool_id, &mut test);
            i = i + 1;
        };

        // Cancelling the remainder refunds the unfilled escrow's share and
        // retains the rest — the last recognition.
        cancel_the_order(pool_id, alice_ta, order_id, &mut test);
        assert_solvent(pool_id, &mut test);

        // Nothing has left the system yet: fills, the cancel and all the fee
        // reclassification only moved units between the traders, the vault
        // and the reserve.
        {
            let (base, quote, cred) = system_totals(
                pool_id,
                collection_id,
                trading_accounts,
                &mut test,
            );
            assert!(base == base_before, 0);
            assert!(quote == quote_before, 1);
            assert!(cred == cred_before, 2);
        };

        // Both traders drain every settled balance out of the vault.
        withdraw_settled(ALICE, pool_id, alice_ta, &mut test);
        withdraw_settled(BOB, pool_id, bob_ta, &mut test);

        // One permissionless claim pays the operator and the treasury.
        let (hub_paid, treasury_paid) = {
            test.next_tx(BOB); // any caller
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let triex_reg = test.take_shared_by_id<Registry>(registry_id);
            let clock = test.take_shared<Clock>();
            let (hub_paid, treasury_paid) = pool.claim_operator_share(
                &policy,
                &triex_reg,
                &clock,
                test.ctx(),
            );
            return_shared(clock);
            return_shared(triex_reg);
            return_shared(policy);
            return_shared(pool);
            (hub_paid, treasury_paid)
        };
        assert!(hub_paid > 0, 3);
        assert!(treasury_paid > 0, 4);

        // The vault is empty in all three assets, and the reserve holds
        // exactly the residue — still counted as locked, claimable by no one,
        // inside its documented bound of one raw unit per release (ten fills
        // plus the cancel).
        let residue = {
            test.next_tx(OWNER);
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let (vault_base, vault_quote, vault_cred) = pool.vault_balances();
            assert!(vault_base == 0, 5);
            assert!(vault_quote == 0, 6);
            assert!(vault_cred == 0, 7);

            let residue = pool.locked_maker_fees();
            assert!(residue > 0, 8); // the dusty case is actually exercised
            assert!(residue <= bites.length() + 1, 9);
            assert!(pool.quote_fee_reserve_balance() == residue, 10);
            assert!(pool.operator_owed() == 0, 11);
            assert!(pool.withdrawable_pool_fees() == 0, 12);
            return_shared(pool);
            residue
        };

        // The payout coins reached their configured destinations, at exactly
        // the claimed amounts.
        test.next_tx(OPERATOR);
        {
            let paid = test.take_from_sender<Coin<USDC>>();
            assert!(paid.value() == hub_paid, 13);
            unit_test::destroy(paid);
        };
        test.next_tx(TREASURY);
        {
            let swept = test.take_from_sender<Coin<USDC>>();
            assert!(swept.value() == treasury_paid, 14);
            unit_test::destroy(swept);
        };

        // Conservation, exactly: every quote unit that entered is now with a
        // trader, with the operator, with the treasury, or is the pinned
        // residue — and base and CRED never leaked at all.
        let (base_after, quote_after, cred_after) = system_totals(
            pool_id,
            collection_id,
            trading_accounts,
            &mut test,
        );
        assert!(base_after == base_before, 15);
        assert!(cred_after == cred_before, 16);
        assert!(quote_after + hub_paid + treasury_paid == quote_before, 17);
        // And what remains inside the system beyond the traders' own holdings
        // is the residue alone.
        let traders_quote = {
            test.next_tx(OWNER);
            let mut traders_quote = 0;
            let mut t = 0;
            while (t < trading_accounts.length()) {
                let ta = test.take_shared_by_id<TradingAccount>(trading_accounts[t]);
                traders_quote = traders_quote + ta.balance<USDC>();
                return_shared(ta);
                t = t + 1;
            };
            traders_quote
        };
        assert!(quote_after == traders_quote + residue, 18);

        unit_test::destroy(collection_cap);
        end(test);
    }
}
