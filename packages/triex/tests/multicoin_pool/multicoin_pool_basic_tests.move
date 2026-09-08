// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_multicoin_pool_basic_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test;
    use sui::{
        clock::{Self, Clock},
        coin::{Self, mint_for_testing},
        test_scenario::{Scenario, begin, end, return_shared}
    };
    use token::cred::CRED;
    use triexbook::{
        constants,
        fill::Fill,
        integration_multicoin_test_utils::{Self as mc_utils, USDC},
        math,
        multicoin_pool::{Self, MultiCoinPool},
        order_info::OrderInfo,
        pool::{Self, Pool},
        registry::{Self, Registry},
        trading_account::{Self, TradingAccount, TradeCap, DepositCap, WithdrawCap}
    };

    // Test addresses
    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;
    const CHARLIE: address = @0xCCCC;

    // Test asset IDs
    const ASSET_GOLD: u64 = 1;
    const ASSET_SILVER: u64 = 2;
    const ASSET_IRON: u64 = 3;

    // === Shared Helpers (delegated to integration_multicoin_test_utils) ===

    #[test_only]
    fun get_time(test: &mut Scenario): u64 { mc_utils::get_time(test) }

    #[test_only]
    fun set_time(current_time: u64, test: &mut Scenario) { mc_utils::set_time(current_time, test) }

    #[test_only]
    fun share_clock(test: &mut Scenario) { mc_utils::share_clock(test) }

    #[test_only]
    fun share_registry_for_testing(test: &mut Scenario): ID {
        mc_utils::share_registry_for_testing(test)
    }

    #[test_only]
    fun add_approved_quote_currencies(owner: address, registry_id: ID, test: &mut Scenario) {
        mc_utils::add_approved_quote_currencies(owner, registry_id, test)
    }

    #[test_only]
    fun setup_registry_with_multicoin(test: &mut Scenario): (ID, ID, CollectionCap) {
        mc_utils::setup_registry_with_multicoin(test)
    }

    #[test_only]
    fun create_trading_account_with_funds(
        sender: address,
        usdc_amount: u64,
        cred_amount: u64,
        test: &mut Scenario,
    ): ID {
        mc_utils::create_trading_account_with_funds(sender, usdc_amount, cred_amount, test)
    }

    #[test_only]
    fun setup_multicoin_pool(
        sender: address,
        registry_id: ID,
        collection_id: ID,
        asset_id: u64,
        test: &mut Scenario,
    ): ID {
        mc_utils::setup_multicoin_pool(
            sender,
            registry_id,
            collection_id,
            asset_id,
            test,
        )
    }

    #[test_only]
    fun setup_cred_usdc_reference_pool(
        sender: address,
        registry_id: ID,
        trading_account_id: ID,
        test: &mut Scenario,
    ): ID {
        mc_utils::setup_cred_usdc_reference_pool(sender, registry_id, trading_account_id, test)
    }

    #[test_only]
    fun setup_multicoin_pool_with_cred_pricing(
        sender: address,
        registry_id: ID,
        collection_id: ID,
        asset_id: u64,
        trading_account_id: ID,
        test: &mut Scenario,
    ): (ID, ID) {
        mc_utils::setup_multicoin_pool_with_cred_pricing(
            sender,
            registry_id,
            collection_id,
            asset_id,
            trading_account_id,
            test,
        )
    }

    // === MultiCoinPool Tests ===

    #[test]
    fun test_create_multicoin_pool_ok() {
        let mut test = begin(OWNER);

        // Setup registry with multicoin
        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        // Create pool
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        // Verify pool exists and can be accessed
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        assert!(pool.collection_id() == collection_id, 0);
        assert!(pool.asset_id() == ASSET_GOLD, 1);
        return_shared(pool);

        // Verify pool is registered
        test.next_tx(OWNER);
        let registry = test.take_shared_by_id<Registry>(registry_id);
        assert!(registry.multicoin_pool_exists<USDC>(collection_id, ASSET_GOLD), 2);
        return_shared(registry);

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test, expected_failure(abort_code = registry::EMulticoinPoolAlreadyExists)]
    fun test_create_duplicate_multicoin_pool_e() {
        let mut test = begin(OWNER);

        // Setup registry with multicoin
        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        // Create first pool
        let _pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        // Try to create duplicate pool - should fail
        let _pool_id2 = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        unit_test::destroy(collection_cap);
        abort 0
    }

    #[test, expected_failure(abort_code = ::triexbook::trading_account::EMultiCoinBalanceTooLow)]
    fun test_multicoin_pool_place_order_wrong_asset_id_e() {
        let mut test = begin(OWNER);

        // Setup registry with multicoin collection
        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        // Create a pool for GOLD asset
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        // Create trading account for ALICE
        let ta_id = create_trading_account_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(), // USDC
            1_000_000 * constants::float_scaling(), // CRED
            &mut test,
        );

        // Mint SILVER (not GOLD) and give to ALICE
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let silver = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_SILVER, // Wrong asset!
            500_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(silver, ALICE);

        // ALICE deposits SILVER into trading account
        test.next_tx(ALICE);
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let silver = test.take_from_sender<multicoin::Balance>();
        ta.deposit_multicoin(silver, test.ctx());
        return_shared(ta);

        // Try to place order in GOLD pool - should fail because ALICE has no GOLD
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let clock = test.take_shared<Clock>();
        let trade_proof = ta.generate_proof_as_owner(test.ctx());

        // This should fail with EMultiCoinBalanceTooLow when trying to withdraw GOLD for an ask order
        // (Ask order = selling GOLD, so user needs GOLD balance)
        let _order_info = pool.place_limit_order(
            &mut ta,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            5_000 * constants::float_scaling(), // price
            100, // quantity
            false, // is_bid = false (ASK order - selling GOLD)
            constants::max_u64(), // expire_timestamp
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(ta);
        return_shared(clock);
        unit_test::destroy(collection_cap);

        abort 0
    }

    #[test]
    fun test_multicoin_pool_place_limit_order_ok() {
        let mut test = begin(OWNER);

        // Setup
        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        // Create trading account with USDC and CRED, share immediately
        test.next_tx(ALICE);
        let mut trading_account = trading_account::new(test.ctx());
        trading_account.deposit(
            mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        trading_account.deposit(
            mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        let trade_cap = trading_account.mint_trade_cap(test.ctx());
        let ta_id = object::id(&trading_account);
        transfer::public_share_object(trading_account);
        transfer::public_transfer(trade_cap, ALICE);

        // Mint MultiCoin for ask orders
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, ALICE);

        // Deposit MultiCoin into trading account
        test.next_tx(ALICE);
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        ta.deposit_multicoin(gold, test.ctx());
        return_shared(ta);

        // Place a limit bid order
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = ta.generate_proof_as_trader(&trade_cap, test.ctx());

        ta.deposit(
            mint_for_testing<USDC>(1_000_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );

        ta.deposit(
            mint_for_testing<USDC>(1_000_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );

        // Top up quote to cover quote-denominated maker fees before cancel
        ta.deposit(
            mint_for_testing<USDC>(1_000_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );

        // Top up quote to cover quote-denominated maker fees before cancel
        ta.deposit(
            mint_for_testing<USDC>(1_000_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );

        let order_info = pool.place_limit_order(
            &mut ta,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(), // price
            100, // quantity
            true, // is_bid
            constants::max_u64(), // expire_timestamp
            &clock,
            test.ctx(),
        );

        assert!(order_info.status() == constants::live(), 0);

        return_shared(pool);
        return_shared(clock);
        return_shared(ta);
        test.return_to_sender(trade_cap);
        unit_test::destroy(collection_cap);

        end(test);
    }

    #[test]
    fun test_multicoin_pool_place_and_match_orders_ok() {
        let mut test = begin(OWNER);

        // Setup
        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        // Create trading account for ALICE with USDC for bids
        let alice_bm_id = create_trading_account_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(), // USDC
            1_000_000 * constants::float_scaling(), // CRED
            &mut test,
        );

        // Create trading account for BOB with USDC and CRED, share immediately
        test.next_tx(BOB);
        let mut bob_bm = trading_account::new(test.ctx());
        bob_bm.deposit(
            mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bob_bm.deposit(
            mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        let bob_trade_cap = bob_bm.mint_trade_cap(test.ctx());
        let bob_bm_id = object::id(&bob_bm);
        transfer::public_share_object(bob_bm);
        transfer::public_transfer(bob_trade_cap, BOB);

        // Mint MultiCoin for Bob
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, BOB);

        // Bob deposits MultiCoin
        test.next_tx(BOB);
        let mut bob_bm = test.take_shared_by_id<TradingAccount>(bob_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        bob_bm.deposit_multicoin(gold, test.ctx());
        return_shared(bob_bm);

        // ALICE places a bid at price 2
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<TradingAccount>(alice_bm_id);
        let alice_trade_cap = test.take_from_sender<TradeCap>();
        let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

        alice_bm.deposit(
            mint_for_testing<USDC>(1_000_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );

        // Top up quote to cover quote-denominated maker fees before cancel
        alice_bm.deposit(
            mint_for_testing<USDC>(1_000_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );

        // Top up quote to cover quote-denominated maker fees before cancel
        alice_bm.deposit(
            mint_for_testing<USDC>(1_000_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );

        let alice_order = pool.place_limit_order(
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(), // price
            100, // quantity
            true, // is_bid
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        assert!(alice_order.status() == constants::live(), 0);

        return_shared(pool);
        return_shared(clock);
        return_shared(alice_bm);
        test.return_to_sender(alice_trade_cap);

        // BOB places an ask at price 2 (should match with ALICE's bid)
        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut bob_bm = test.take_shared_by_id<TradingAccount>(bob_bm_id);
        let bob_trade_cap = test.take_from_sender<TradeCap>();
        let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

        let bob_order = pool.place_limit_order(
            &mut bob_bm,
            &bob_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(), // price - matches Alice's bid
            100, // quantity
            false, // is_bid (ask)
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        // Bob's order should be filled
        assert!(bob_order.status() == constants::filled(), 1);

        return_shared(pool);
        return_shared(clock);
        return_shared(bob_bm);
        test.return_to_sender(bob_trade_cap);

        // Alice needs to withdraw her settled amounts (as maker) to get the MultiCoin credited
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let mut alice_bm = test.take_shared_by_id<TradingAccount>(alice_bm_id);
        let alice_trade_cap = test.take_from_sender<TradeCap>();
        let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());
        pool.withdraw_settled_amounts(&mut alice_bm, &alice_proof, test.ctx());
        return_shared(pool);
        return_shared(alice_bm);
        test.return_to_sender(alice_trade_cap);

        // Verify Alice received MultiCoin (base)
        test.next_tx(ALICE);
        let alice_bm = test.take_shared_by_id<TradingAccount>(alice_bm_id);
        let alice_gold_balance = alice_bm.multicoin_balance(collection_id, ASSET_GOLD);
        assert!(alice_gold_balance > 0, 2); // Alice should have received gold
        return_shared(alice_bm);

        // Verify Bob has less gold than initial deposit (sold some)
        test.next_tx(BOB);
        let bob_bm = test.take_shared_by_id<TradingAccount>(bob_bm_id);
        let bob_gold_balance = bob_bm.multicoin_balance(collection_id, ASSET_GOLD);
        assert!(bob_gold_balance < 1_000_000 * constants::float_scaling(), 3);
        return_shared(bob_bm);

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_multicoin_pool_cancel_order_ok() {
        let mut test = begin(OWNER);

        // Setup
        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        // Create trading account with funds
        let ta_id = create_trading_account_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Place a limit order
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = ta.generate_proof_as_trader(&trade_cap, test.ctx());

        let order_info = pool.place_limit_order(
            &mut ta,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            100,
            true, // bid
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        let order_id = order_info.order_id();

        // Cancel the order
        pool.cancel_order(&mut ta, &trade_proof, order_id, &clock, test.ctx());

        // Order was successfully cancelled - we don't need to verify it's removed
        // since get_order would abort if called on a non-existent order

        return_shared(pool);
        return_shared(clock);
        return_shared(ta);
        test.return_to_sender(trade_cap);
        unit_test::destroy(collection_cap);

        end(test);
    }

    #[test]
    fun test_multicoin_bid_with_quote_fees_updates_vault_reserve() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        let alice_bm_id = create_trading_account_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let bob_bm_id = create_trading_account_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, ALICE);

        test.next_tx(ALICE);
        let mut alice_bm = test.take_shared_by_id<TradingAccount>(alice_bm_id);
        let gold_balance = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold_balance, test.ctx());
        return_shared(alice_bm);

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut alice_bm = test.take_shared_by_id<TradingAccount>(alice_bm_id);
            let trade_proof = alice_bm.generate_proof_as_owner(test.ctx());

            pool.place_limit_order(
                &mut alice_bm,
                &trade_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                2 * constants::float_scaling(),
                100,
                false,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );

            return_shared(alice_bm);
            return_shared(clock);
            return_shared(pool);
        };

        test.next_tx(BOB);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut bob_bm = test.take_shared_by_id<TradingAccount>(bob_bm_id);
            let trade_proof = bob_bm.generate_proof_as_owner(test.ctx());

            let reserve_before = pool.quote_fee_reserve_balance();
            let order_info = pool.place_limit_order_with_quote_fees(
                &mut bob_bm,
                &trade_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                2 * constants::float_scaling(),
                100,
                true,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );
            let reserve_after = pool.quote_fee_reserve_balance();
            // The ask maker's fee (0.9% of the filled quote) is deducted from
            // their proceeds and lands in the same reserve as Bob's taker fee.
            let ask_maker_fee = order_info.cumulative_quote_quantity() * 90 / 10_000;
            let expected_fee = order_info.paid_fees() + order_info.maker_fees() + ask_maker_fee;
            assert!(expected_fee > 0, 0);
            assert!(reserve_after >= reserve_before, 0);
            assert!(reserve_after - reserve_before == expected_fee, 0);

            return_shared(bob_bm);
            return_shared(clock);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_multicoin_pool_mid_price_ok() {
        let mut test = begin(OWNER);

        // Setup
        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        // Create trading account with funds and share immediately
        test.next_tx(ALICE);
        let mut ta = trading_account::new(test.ctx());
        ta.deposit(
            mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        ta.deposit(
            mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        let trade_cap = ta.mint_trade_cap(test.ctx());
        let ta_id = object::id(&ta);
        transfer::public_share_object(ta);
        transfer::public_transfer(trade_cap, ALICE);

        // Mint MultiCoin for ask orders
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, ALICE);

        // Deposit MultiCoin
        test.next_tx(ALICE);
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        ta.deposit_multicoin(gold, test.ctx());
        return_shared(ta);

        // Place bid at price 1
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = ta.generate_proof_as_trader(&trade_cap, test.ctx());

        pool.place_limit_order(
            &mut ta,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            1 * constants::float_scaling(),
            100,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        // Place ask at price 2
        pool.place_limit_order(
            &mut ta,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            100,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        // Mid price should be (1 + 2) / 2 = 1.5
        let mid_price = pool.mid_price(&clock);
        assert!(mid_price == 15 * constants::float_scaling() / 10, 0);

        return_shared(pool);
        return_shared(clock);
        return_shared(ta);
        test.return_to_sender(trade_cap);
        unit_test::destroy(collection_cap);

        end(test);
    }
}
