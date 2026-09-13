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
    use sui::{
        clock::Clock,
        coin::Coin,
        test_scenario::{Scenario, begin, end, return_shared}
    };
    use triex::{
        constants,
        fee_policy::FeePolicy,
        integration_multicoin_test_utils as mc_utils,
        multicoin_pool::MultiCoinPool,
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
    fun setup(test: &mut Scenario): (ID, ID, ID, CollectionCap) {
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

        (pool_id, alice_ta, bob_ta, collection_cap)
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

    /// Solvency: the reserve covers both claims against it, always.
    fun assert_solvent(pool_id: ID, test: &mut Scenario) {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        assert!(
            (pool.quote_fee_reserve_balance() as u128)
                >= (pool.locked_maker_fees() as u128) + (pool.operator_owed() as u128),
        );
        return_shared(pool);
    }

    fun operator_owed(pool_id: ID, test: &mut Scenario): u64 {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let owed = pool.operator_owed();
        return_shared(pool);
        owed
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
        let (pool_id, alice_ta, bob_ta, collection_cap) = setup(&mut test);
        let collection_id = {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let id = pool.collection_id();
            return_shared(pool);
            id
        };

        // Ceiling rate, so any escrow miscount is as visible as possible.
        let bps = constants::max_operator_share_bps();
        configure_hub(collection_id, bps, &mut test);
        test.next_epoch(OWNER);

        let price = 2 * constants::float_scaling();

        // 1. A resting bid: the taker fee is zero (nothing filled) and the maker
        //    fee is refundable escrow. A credit that counted the deposit whole
        //    would already be wrong here.
        let (order_id, taker_fee, maker_fee) = rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
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
            let exact_share = revenue * (bps as u128) / 10_000;
            assert!(owed <= exact_share);
            assert!(owed + 4 >= exact_share);
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
        let (pool_id, alice_ta, bob_ta, collection_cap) = setup(&mut test);
        let (registry_id, collection_id) = {
            test.next_tx(OWNER);
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let id = pool.collection_id();
            return_shared(pool);
            let reg = test.take_shared<Registry>();
            let rid = object::id(&reg);
            return_shared(reg);
            (rid, id)
        };

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
        let (pool_id, alice_ta, bob_ta, collection_cap) = setup(&mut test);
        let collection_id = {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let id = pool.collection_id();
            return_shared(pool);
            id
        };

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
        assert!(owed_1 <= revenue_1 * 3_000 / 10_000);
        assert!(owed_1 + 4 >= revenue_1 * 3_000 / 10_000);

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
            assert!(owed_2 <= revenue_2 * 500 / 10_000);
            assert!(owed_2 + 4 >= revenue_2 * 500 / 10_000);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// An unconfigured hub accrues nothing, cancels still work, and the whole
    /// reserve is immediately the treasury's — deploying this changes nothing
    /// until someone opts a hub in, with no settle step in front of the sweep.
    #[test]
    fun an_unconfigured_hub_accrues_nothing_and_never_blocks() {
        let mut test = begin(OWNER);
        let (pool_id, alice_ta, bob_ta, collection_cap) = setup(&mut test);

        let price = 2 * constants::float_scaling();
        let (order_id, _, _) = rest_a_bid(pool_id, alice_ta, price, 1000, &mut test);
        sell_into_the_book(pool_id, bob_ta, price, 400, &mut test);
        // Cancellation resolves the rate too — zero — and must not abort on the
        // absent configuration.
        cancel_the_order(pool_id, alice_ta, order_id, &mut test);

        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let revenue = pool.quote_fee_reserve_balance();
            assert!(revenue > 0);
            assert!(pool.operator_owed() == 0);
            assert!(pool.withdrawable_pool_fees() == revenue);
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
        let (pool_id, _alice_ta, _bob_ta, collection_cap) = setup(&mut test);
        let collection_id = {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let id = pool.collection_id();
            return_shared(pool);
            id
        };

        destroy_beneficiary(collection_id, &mut test);

        test.next_tx(OWNER);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let triex_reg = test.take_shared<Registry>();
            let clock = test.take_shared<Clock>();

            assert!(!policy.has_operator_beneficiary(collection_id));
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
        let (pool_id, alice_ta, bob_ta, collection_cap) = setup(&mut test);
        let collection_id = {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let id = pool.collection_id();
            return_shared(pool);
            id
        };

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
        let (pool_id, alice_ta, _bob_ta, collection_cap) = setup(&mut test);
        let collection_id = {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let id = pool.collection_id();
            return_shared(pool);
            id
        };

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
            let expected = (((retained as u128) * (bps as u128)) / 10_000) as u64;
            assert!(pool.operator_owed() == expected);
            return_shared(pool);
        };

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
}
