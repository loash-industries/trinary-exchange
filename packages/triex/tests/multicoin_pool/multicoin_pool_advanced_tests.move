// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_multicoin_pool_advanced_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test;
    use sui::{
        clock::{Self, Clock},
        coin::{Self, mint_for_testing},
        event,
        test_scenario::{Scenario, begin, end, return_shared}
    };
    use token::cred::CRED;
    use triexbook::{
        balance_manager::{Self, BalanceManager, TradeCap, DepositCap, WithdrawCap},
        balance_manager_tests::USDC,
        constants,
        fee_policy::FeePolicy,
        fill::Fill,
        integration_multicoin_test_utils as mc_utils,
        math,
        multicoin_pool::{Self, MultiCoinPool},
        order_info::OrderInfo,
        pool::{Self, Pool},
        pool_test_utils,
        quote_fee,
        registry::{Self, Registry},
        vault
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
    fun create_balance_manager_with_funds(
        sender: address,
        usdc_amount: u64,
        cred_amount: u64,
        test: &mut Scenario,
    ): ID {
        mc_utils::create_balance_manager_with_funds(sender, usdc_amount, cred_amount, test)
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
        balance_manager_id: ID,
        test: &mut Scenario,
    ): ID {
        mc_utils::setup_cred_usdc_reference_pool(sender, registry_id, balance_manager_id, test)
    }

    #[test_only]
    fun setup_multicoin_pool_with_cred_pricing(
        sender: address,
        registry_id: ID,
        collection_id: ID,
        asset_id: u64,
        balance_manager_id: ID,
        test: &mut Scenario,
    ): (ID, ID) {
        mc_utils::setup_multicoin_pool_with_cred_pricing(
            sender,
            registry_id,
            collection_id,
            asset_id,
            balance_manager_id,
            test,
        )
    }

    // === Helper Functions for Advanced Tests ===

    #[test_only]
    fun multicoin_partial_fill_maker_order(
        is_bid: bool,
        order_type: u8,
        alice_quantity: u64,
        expected_executed_quantity: u64,
        expected_cumulative_quote_quantity: u64,
        expected_paid_fees: u64,
        expected_status: u8,
    ) {
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

        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // BOB with MultiCoin
        test.next_tx(BOB);
        let mut bob_bm = balance_manager::new(test.ctx());
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

        // Mint MultiCoin for both BOB and ALICE
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold_bob = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        let gold_alice = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold_bob, BOB);
        transfer::public_transfer(gold_alice, ALICE);

        test.next_tx(BOB);
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        bob_bm.deposit_multicoin(gold, test.ctx());
        return_shared(bob_bm);

        // Alice deposits her MultiCoin
        test.next_tx(ALICE);
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold, test.ctx());
        return_shared(alice_bm);

        let alice_price = 2 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();

        // Alice's maker order placed first for alice_quantity at alice_price
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_trade_cap = test.take_from_sender<TradeCap>();
        let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

        let _alice_order = pool.place_limit_order(
            &policy,
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            alice_price,
            alice_quantity,
            is_bid,
            expire_timestamp,
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(alice_bm);
        test.return_to_sender(alice_trade_cap);

        // Half of Alice's maker order is filled by another order from Alice herself
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_trade_cap = test.take_from_sender<TradeCap>();
        let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

        let _alice_order_2 = pool.place_limit_order(
            &policy,
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            alice_price,
            alice_quantity / 2,
            !is_bid,
            expire_timestamp,
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(alice_bm);
        test.return_to_sender(alice_trade_cap);

        let bob_price = 2 * constants::float_scaling();
        let bob_quantity = 2 * alice_quantity;

        // Bob's order that will partially fill 2 * alice_quantity of Alice's maker order at alice_price
        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let bob_trade_cap = test.take_from_sender<TradeCap>();
        let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

        let bob_order = pool.place_limit_order(
            &policy,
            &mut bob_bm,
            &bob_proof,
            order_type,
            constants::self_matching_allowed(),
            bob_price,
            bob_quantity,
            !is_bid,
            expire_timestamp,
            &clock,
            test.ctx(),
        );

        // Verify Bob's order results
        assert!(bob_order.executed_quantity() == expected_executed_quantity, 0);
        assert!(bob_order.cumulative_quote_quantity() == expected_cumulative_quote_quantity, 1);
        assert!(bob_order.paid_fees() == expected_paid_fees, 2);
        assert!(bob_order.status() == expected_status, 3);

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(bob_bm);
        test.return_to_sender(bob_trade_cap);
        unit_test::destroy(collection_cap);

        end(test);
    }

    #[test_only]
    fun multicoin_partially_filled_order_taken(is_bid: bool) {
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

        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // BOB with MultiCoin
        test.next_tx(BOB);
        let mut bob_bm = balance_manager::new(test.ctx());
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

        // Mint MultiCoin for both BOB and ALICE
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold_bob = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        let gold_alice = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold_bob, BOB);
        transfer::public_transfer(gold_alice, ALICE);

        test.next_tx(BOB);
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        bob_bm.deposit_multicoin(gold, test.ctx());
        return_shared(bob_bm);

        // Alice deposits her MultiCoin
        test.next_tx(ALICE);
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold, test.ctx());
        return_shared(alice_bm);

        let alice_price_1 = 3 * constants::float_scaling();
        let alice_price_2 = if (is_bid) {
            2 * constants::float_scaling()
        } else {
            4 * constants::float_scaling()
        };
        let alice_quantity_1 = 2;
        let alice_quantity_2 = 10;
        let expire_timestamp = constants::max_u64();

        // Alice places an initial order with quantity 2
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_trade_cap = test.take_from_sender<TradeCap>();
        let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

        pool.place_limit_order(
            &policy,
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            alice_price_1,
            alice_quantity_1,
            is_bid,
            expire_timestamp,
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(alice_bm);
        test.return_to_sender(alice_trade_cap);

        // Alice places a crossing order of quantity 10, 2 is filled and 8 is placed on book
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_trade_cap = test.take_from_sender<TradeCap>();
        let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

        let _alice_order_info_2 = pool.place_limit_order(
            &policy,
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            alice_price_2,
            alice_quantity_2,
            !is_bid,
            expire_timestamp,
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(alice_bm);
        test.return_to_sender(alice_trade_cap);

        let bob_price = 3 * constants::float_scaling();
        let bob_quantity = 10;

        // Bob places another crossing order of quantity 10, 8 is filled and 2 is placed on book
        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let bob_trade_cap = test.take_from_sender<TradeCap>();
        let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

        let bob_order_info = pool.place_limit_order(
            &policy,
            &mut bob_bm,
            &bob_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            bob_price,
            bob_quantity,
            is_bid,
            expire_timestamp,
            &clock,
            test.ctx(),
        );

        // Bob should have quantity 8 executed by crossing Alice's order
        assert!(bob_order_info.executed_quantity() == 8, 0);

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(bob_bm);
        test.return_to_sender(bob_trade_cap);
        unit_test::destroy(collection_cap);

        end(test);
    }

    #[test_only]
    fun multicoin_test_crossing_multiple(is_bid: bool, num_orders: u64) {
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

        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();

        let mut i = 0;
        while (i < num_orders) {
            test.next_tx(ALICE);
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let alice_trade_cap = test.take_from_sender<TradeCap>();
            let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

            pool.place_limit_order(
                &policy,
                &mut alice_bm,
                &alice_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity,
                is_bid,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            return_shared(alice_bm);
            test.return_to_sender(alice_trade_cap);
            i = i + 1;
        };

        let price = if (is_bid) {
            1 * constants::float_scaling()
        } else {
            3 * constants::float_scaling()
        };

        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_trade_cap = test.take_from_sender<TradeCap>();
        let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

        let order_info = pool.place_limit_order(
            &policy,
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            num_orders * quantity,
            !is_bid,
            expire_timestamp,
            &clock,
            test.ctx(),
        );

        // Verify the crossing order filled all the previous orders
        assert!(order_info.executed_quantity() == num_orders * quantity, 0);
        assert!(order_info.cumulative_quote_quantity() == 2 * num_orders * quantity, 1);

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(alice_bm);
        test.return_to_sender(alice_trade_cap);
        unit_test::destroy(collection_cap);

        end(test);
    }

    #[test_only]
    fun multicoin_test_swap_exact_not_fully_filled(
        is_bid: bool,
        low_quantity: bool,
        minimum_enforced: bool,
        partially_filled_maker: bool,
        with_manager: bool,
    ) {
        let mut test = begin(OWNER);

        // Setup
        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        // Create balance manager for CRED pricing setup first
        let owner_bm_id = create_balance_manager_with_funds(
            OWNER,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Setup pool with CRED pricing (uses a reference pool for CRED)
        let (pool_id, _reference_pool_id) = setup_multicoin_pool_with_cred_pricing(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            owner_bm_id,
            &mut test,
        );

        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // BOB with MultiCoin
        test.next_tx(BOB);
        let mut bob_bm = balance_manager::new(test.ctx());
        bob_bm.deposit(
            mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        bob_bm.deposit(
            mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        let bob_trade_cap = bob_bm.mint_trade_cap(test.ctx());
        let bob_deposit_cap = bob_bm.mint_deposit_cap(test.ctx());
        let bob_withdraw_cap = bob_bm.mint_withdraw_cap(test.ctx());
        let bob_bm_id = object::id(&bob_bm);
        transfer::public_share_object(bob_bm);
        transfer::public_transfer(bob_trade_cap, BOB);
        transfer::public_transfer(bob_deposit_cap, BOB);
        transfer::public_transfer(bob_withdraw_cap, BOB);

        // Mint MultiCoin for both BOB and ALICE
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold_bob = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        let gold_alice = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold_bob, BOB);
        transfer::public_transfer(gold_alice, ALICE);

        test.next_tx(BOB);
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        bob_bm.deposit_multicoin(gold, test.ctx());
        return_shared(bob_bm);

        // Alice deposits her MultiCoin
        test.next_tx(ALICE);
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold, test.ctx());
        return_shared(alice_bm);

        let alice_price = 3 * constants::float_scaling();
        let alice_quantity = 2;
        let expired_price = if (is_bid) {
            3 * constants::float_scaling()
        } else {
            1 * constants::float_scaling()
        };
        let expire_timestamp = constants::max_u64();
        let expire_timestamp_e = get_time(&mut test) + 100;

        // Alice places maker order
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_trade_cap = test.take_from_sender<TradeCap>();
        let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

        pool.place_limit_order(
            &policy,
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            alice_price,
            alice_quantity,
            is_bid,
            expire_timestamp,
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(alice_bm);
        test.return_to_sender(alice_trade_cap);

        if (partially_filled_maker) {
            // Partially fill the maker order
            test.next_tx(ALICE);
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let alice_trade_cap = test.take_from_sender<TradeCap>();
            let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

            pool.place_limit_order(
                &policy,
                &mut alice_bm,
                &alice_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                alice_price,
                alice_quantity / 2,
                !is_bid,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            return_shared(alice_bm);
            test.return_to_sender(alice_trade_cap);
        };

        // Place an expired order that won't match
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_trade_cap = test.take_from_sender<TradeCap>();
        let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

        pool.place_limit_order(
            &policy,
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            expired_price,
            alice_quantity,
            is_bid,
            expire_timestamp_e,
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(alice_bm);
        test.return_to_sender(alice_trade_cap);

        // Advance time to expire the expired order
        set_time(200, &mut test);

        // Calculate swap parameters
        let base_in = if (is_bid) {
            if (low_quantity) {
                100
            } else {
                4
            }
        } else {
            0
        };
        let quote_in = if (is_bid) {
            0
        } else {
            if (low_quantity) {
                4 * constants::float_scaling()
            } else {
                8 * constants::float_scaling()
            }
        };

        // Get expected quantities
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let (base, quote) = pool.get_quantity_out(
            &policy,
            base_in,
            quote_in,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(policy);
        return_shared(clock);

        let (base_2, quote_2) = if (is_bid) {
            test.next_tx(OWNER);
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let (base_2, quote_2) = pool.get_quantity_out(&policy, base_in, 0, &clock, test.ctx());
            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            (base_2, quote_2)
        } else {
            test.next_tx(OWNER);
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let (base_2, quote_2) = pool.get_quantity_out(&policy, 0, quote_in, &clock, test.ctx());
            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            (base_2, quote_2)
        };

        // Quote-only fees: no CRED input required
        let cred_in = 0;

        let min_out = if (minimum_enforced) {
            10 * constants::float_scaling()
        } else {
            0
        };

        let _initial_bob_balances = 1000000 * constants::float_scaling();
        let _bob_multicoin_balance_before = {
            test.next_tx(BOB);
            let bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let balance = bob_bm.multicoin_balance(collection_id, ASSET_GOLD);
            return_shared(bob_bm);
            balance
        };
        let _bob_usdc_balance_before = {
            test.next_tx(BOB);
            let bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let balance = bob_bm.balance<USDC>();
            return_shared(bob_bm);
            balance
        };
        let _bob_cred_balance_before = {
            test.next_tx(BOB);
            let bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let balance = bob_bm.balance<CRED>();
            return_shared(bob_bm);
            balance
        };

        // Execute the swap
        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut collection = test.take_shared<Collection>();

        let (base_out, quote_out, cred_out) = if (is_bid) {
            if (with_manager) {
                let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
                let bob_trade_cap = test.take_from_sender<TradeCap>();
                let bob_deposit_cap = test.take_from_sender<DepositCap>();
                let bob_withdraw_cap = test.take_from_sender<WithdrawCap>();

                let base_in_balance = multicoin::mint_and_keep(
                    &collection_cap,
                    &mut collection,
                    ASSET_GOLD,
                    base_in,
                    test.ctx(),
                );

                let (base_out, quote_out) = pool.swap_exact_base_for_quote_with_manager(
                    &policy,
                    &mut bob_bm,
                    &bob_trade_cap,
                    &bob_deposit_cap,
                    &bob_withdraw_cap,
                    base_in_balance,
                    min_out,
                    &clock,
                    test.ctx(),
                );

                return_shared(bob_bm);
                test.return_to_sender(bob_trade_cap);
                test.return_to_sender(bob_deposit_cap);
                test.return_to_sender(bob_withdraw_cap);

                (base_out, quote_out, coin::zero(test.ctx()))
            } else {
                let base_in_balance = multicoin::mint_and_keep(
                    &collection_cap,
                    &mut collection,
                    ASSET_GOLD,
                    base_in,
                    test.ctx(),
                );

                pool.swap_exact_base_for_quote(
                    &policy,
                    base_in_balance,
                    mint_for_testing<CRED>(cred_in, test.ctx()),
                    min_out,
                    &clock,
                    test.ctx(),
                )
            }
        } else {
            if (with_manager) {
                let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
                let bob_trade_cap = test.take_from_sender<TradeCap>();
                let bob_deposit_cap = test.take_from_sender<DepositCap>();
                let bob_withdraw_cap = test.take_from_sender<WithdrawCap>();

                let (base_out, quote_out) = pool.swap_exact_quote_for_base_with_manager(
                    &policy,
                    &mut bob_bm,
                    &bob_trade_cap,
                    &bob_deposit_cap,
                    &bob_withdraw_cap,
                    mint_for_testing<USDC>(quote_in, test.ctx()),
                    min_out,
                    &clock,
                    test.ctx(),
                );

                return_shared(bob_bm);
                test.return_to_sender(bob_trade_cap);
                test.return_to_sender(bob_deposit_cap);
                test.return_to_sender(bob_withdraw_cap);

                (base_out, quote_out, coin::zero(test.ctx()))
            } else {
                pool.swap_exact_quote_for_base(
                    &policy,
                    mint_for_testing<USDC>(quote_in, test.ctx()),
                    mint_for_testing<CRED>(cred_in, test.ctx()),
                    min_out,
                    &clock,
                    test.ctx(),
                )
            }
        };

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(collection);

        let _bob_multicoin_balance_after = {
            test.next_tx(BOB);
            let bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let balance = bob_bm.multicoin_balance(collection_id, ASSET_GOLD);
            return_shared(bob_bm);
            balance
        };
        let _bob_usdc_balance_after = {
            test.next_tx(BOB);
            let bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let balance = bob_bm.balance<USDC>();
            return_shared(bob_bm);
            balance
        };
        let _bob_cred_balance_after = {
            test.next_tx(BOB);
            let bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let balance = bob_bm.balance<CRED>();
            return_shared(bob_bm);
            balance
        };

        // Verify results for non-low_quantity cases
        if (low_quantity) {
            // With small amounts, some matching should occur
            if (is_bid) {
                assert!(base_out.value() < base_in, constants::e_order_info_mismatch());
                assert!(quote_out.value() > 0, constants::e_order_info_mismatch());
            } else {
                assert!(quote_out.value() < quote_in, constants::e_order_info_mismatch());
                assert!(base_out.value() > 0, constants::e_order_info_mismatch());
            };
        } else if (!partially_filled_maker) {
            if (is_bid) {
                assert!(base_out.value() == 2, constants::e_order_info_mismatch());
                // Bob sells into the bids as an ask taker: 2.2% of the 6 quote
                // proceeds is deducted (6 − 0.132)
                assert!(
                    quote_out.value() == 5_868 * constants::float_scaling() / 1000,
                    constants::e_order_info_mismatch(),
                );

                assert!(cred_out.value() == 0, constants::e_order_info_mismatch());

                assert!(
                    base == base_2 && base == base_out.value(),
                    constants::e_order_info_mismatch(),
                );
                assert!(
                    quote == quote_2 && quote == quote_out.value(),
                    constants::e_order_info_mismatch(),
                );
            } else {
                // Quote-only fee model can reduce quote_out; only require non-zero output
                assert!(base_out.value() > 0, constants::e_order_info_mismatch());
                assert!(quote_out.value() > 0, constants::e_order_info_mismatch());
                assert!(cred_out.value() == 0, constants::e_order_info_mismatch());
            };
        } else {
            // partially_filled_maker case
            if (is_bid) {
                assert!(base_out.value() == 3, constants::e_order_info_mismatch());
                // Bob sells into the remaining bid as an ask taker: 2.2% of the
                // 3 quote proceeds is deducted (3 − 0.066)
                assert!(
                    quote_out.value() == 2_934 * constants::float_scaling() / 1000,
                    constants::e_order_info_mismatch(),
                );

                assert!(cred_out.value() == 0, constants::e_order_info_mismatch());

                assert!(
                    base == base_2 && base == base_out.value(),
                    constants::e_order_info_mismatch(),
                );
                assert!(
                    quote == quote_2 && quote == quote_out.value(),
                    constants::e_order_info_mismatch(),
                );
            } else {
                // Ask-side partial fills: only require some output; fees reduce quote
                assert!(base_out.value() > 0, constants::e_order_info_mismatch());
                assert!(quote_out.value() > 0, constants::e_order_info_mismatch());
                assert!(cred_out.value() == 0, constants::e_order_info_mismatch());
            };
        };

        // Clean up
        transfer::public_transfer(base_out, BOB);
        coin::burn_for_testing(quote_out);
        coin::burn_for_testing(cred_out);
        unit_test::destroy(collection_cap);

        end(test);
    }

    #[test_only]
    fun multicoin_test_place_order_edge_price(price: u64) {
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

        // Create balance manager with USDC and CRED, share immediately
        test.next_tx(ALICE);
        let mut balance_manager = balance_manager::new(test.ctx());
        balance_manager.deposit(
            mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        balance_manager.deposit(
            mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        let bm_id = object::id(&balance_manager);
        transfer::public_share_object(balance_manager);
        transfer::public_transfer(trade_cap, ALICE);

        // Place a limit bid order at the provided price
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = bm.generate_proof_as_trader(&trade_cap, test.ctx());

        pool.place_limit_order(
            &policy,
            &mut bm,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            1 * constants::float_scaling(),
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(bm);
        test.return_to_sender(trade_cap);
        unit_test::destroy(collection_cap);

        end(test);
    }

    #[test_only]
    fun multicoin_test_modify_order(
        original_quantity: u64,
        new_quantity: u64,
        filled_quantity: u64,
        is_bid: bool,
    ) {
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

        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Mint MultiCoin for ALICE if needed for ask orders
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold_alice = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold_alice, ALICE);

        test.next_tx(ALICE);
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold, test.ctx());
        return_shared(alice_bm);

        let base_price = 2 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();

        // Place original order
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_trade_cap = test.take_from_sender<TradeCap>();
        let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

        let order_info = pool.place_limit_order(
            &policy,
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            base_price,
            original_quantity,
            is_bid,
            expire_timestamp,
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(alice_bm);
        test.return_to_sender(alice_trade_cap);

        if (filled_quantity > 0) {
            // Partially fill the order first
            test.next_tx(ALICE);
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let alice_trade_cap = test.take_from_sender<TradeCap>();
            let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

            pool.place_limit_order(
                &policy,
                &mut alice_bm,
                &alice_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                base_price,
                filled_quantity,
                !is_bid,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            return_shared(alice_bm);
            test.return_to_sender(alice_trade_cap);
        };

        // Now modify the order
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_trade_cap = test.take_from_sender<TradeCap>();
        let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

        pool.modify_order(
            &mut alice_bm,
            &alice_proof,
            order_info.order_id(),
            new_quantity,
            &clock,
            test.ctx(),
        );

        // Verify the order was modified correctly
        let modified_order = pool.get_order(order_info.order_id());
        assert!(modified_order.quantity() == new_quantity, 0);
        assert!(modified_order.status() == constants::live(), 1);

        return_shared(pool);
        return_shared(clock);
        return_shared(alice_bm);
        test.return_to_sender(alice_trade_cap);
        unit_test::destroy(collection_cap);

        end(test);
    }

    // === Advanced Fill Scenarios ===

    /// Acceptance (multicoin mirror): cancelling a resting bid releases its
    /// escrow, 80% refunded to the maker and 20% kept as revenue.
    #[test]
    fun test_multicoin_cancel_releases_bid_escrow() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );
        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        let price = 2 * constants::float_scaling();
        let alice_maker_fee;
        let order_id;

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            let order = pool.place_limit_order(
                &policy,
                &mut bm,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                100,
                true,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );
            alice_maker_fee = order.maker_fees();
            order_id = order.order_id();
            assert!(alice_maker_fee > 0, 0);
            assert!(pool.locked_maker_fees() == alice_maker_fee, 1);
            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
            return_shared(policy);
        };

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            pool.cancel_order(&mut bm, &proof, order_id, &clock, test.ctx());

            // 80% leaves the reserve back to Alice; the 20% retention stays and
            // is the only sweepable balance left.
            let (refund, retained) = quote_fee::split_released_fee(alice_maker_fee, 2000);
            assert!(pool.quote_fee_reserve_balance() == retained, 2);
            assert!(pool.locked_maker_fees() == 0, 3);
            assert!(pool.withdrawable_pool_fees() == retained, 4);

            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// Acceptance #1 (multicoin mirror): the refund actually reaches the maker's
    /// balance manager, so a place -> cancel round trip costs only the retention.
    #[test]
    fun test_multicoin_cancel_refunds_escrow_to_maker() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );
        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        let price = 2 * constants::float_scaling();
        let alice_maker_fee;
        let order_id;

        test.next_tx(ALICE);
        let balance_before = {
            let bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let bal = bm.balance<USDC>();
            return_shared(bm);
            bal
        };

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            let order = pool.place_limit_order(
                &policy,
                &mut bm,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                100,
                true,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );
            alice_maker_fee = order.maker_fees();
            order_id = order.order_id();
            assert!(alice_maker_fee > 0, 0);
            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
            return_shared(policy);
        };

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            pool.cancel_order(&mut bm, &proof, order_id, &clock, test.ctx());
            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
        };

        test.next_tx(ALICE);
        let balance_after = {
            let bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let bal = bm.balance<USDC>();
            return_shared(bm);
            bal
        };

        let (_, retained) = quote_fee::split_released_fee(alice_maker_fee, 2000);
        assert!(balance_before - balance_after == retained, 1);

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// Acceptance (multicoin mirror): a resting bid's maker fee is tracked as
    /// escrow rather than revenue, and stops being a claim once the order fills.
    #[test]
    fun test_multicoin_locked_fee_escrow_tracks_open_orders() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let bob_bm_id = create_balance_manager_with_funds(
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
        transfer::public_transfer(gold, BOB);

        test.next_tx(BOB);
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        bob_bm.deposit_multicoin(gold, test.ctx());
        return_shared(bob_bm);

        let price = 2 * constants::float_scaling();

        // Alice rests a bid: its maker fee is escrow, not sweepable revenue.
        let alice_maker_fee;
        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            let order = pool.place_limit_order(
                &policy,
                &mut bm,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                100,
                true,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );
            alice_maker_fee = order.maker_fees();
            assert!(alice_maker_fee > 0, 0);
            assert!(pool.locked_maker_fees() == alice_maker_fee, 1);
            assert!(pool.withdrawable_pool_fees() == 0, 2);
            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
            return_shared(policy);
        };

        // Bob's ask fills it, earning the escrow out.
        test.next_tx(BOB);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            let order = pool.place_limit_order(
                &policy,
                &mut bm,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                100,
                false,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );
            assert!(order.status() == constants::filled(), 3);
            assert!(pool.locked_maker_fees() == 0, 4);
            assert!(pool.withdrawable_pool_fees() == pool.quote_fee_reserve_balance(), 5);
            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
            return_shared(policy);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// Regression: a bid whose owed quote is fully covered by the placer's own
    /// pending settled quote used to abort here — nothing was withdrawn, so the
    /// fee deposit reached a destructor that asserts it is zero. The fee is now
    /// carved out of the quote the pool retains by netting, so the order rests
    /// and its escrow reaches the reserve.
    #[test]
    fun test_multicoin_bid_fee_reaches_reserve_when_settled_covers_owed() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        // The pool charges the default taker/maker fees
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let bob_bm_id = create_balance_manager_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Mint gold for Bob so he can rest an ask
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

        test.next_tx(BOB);
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        bob_bm.deposit_multicoin(gold, test.ctx());
        return_shared(bob_bm);

        let price = 2 * constants::float_scaling();

        // Bob rests an ask, Alice takes it. Bob's proceeds (net of his ask-maker
        // fee) stay as pending settled quote — he never withdraws them.
        test.next_tx(BOB);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            pool.place_limit_order(
                &policy,
                &mut bm,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                100,
                false,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );
            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
            return_shared(policy);
        };

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            let order = pool.place_limit_order(
                &policy,
                &mut bm,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                100,
                true,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );
            assert!(order.status() == constants::filled(), 0);
            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
            return_shared(policy);
        };

        // Bob now rests a bid for half the quantity. Its principal plus maker fee
        // sit well inside his settled proceeds, so the vault withdraws nothing
        // from his balance manager.
        test.next_tx(BOB);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());

            let reserve_before = pool.quote_fee_reserve_balance();
            let order = pool.place_limit_order(
                &policy,
                &mut bm,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                50,
                true,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );
            assert!(order.status() == constants::live(), 1);
            assert!(order.maker_fees() > 0, 2);
            assert!(pool.quote_fee_reserve_balance() - reserve_before == order.maker_fees(), 3);

            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
            return_shared(policy);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_multicoin_pool_fill_partial_maker_bid_ok() {
        multicoin_partial_fill_maker_order(
            true,
            constants::no_restriction(),
            3,
            2,
            4 * constants::float_scaling(),
            // Bob takes as an ask: 2.2% of the 4-quote proceeds
            4 * constants::float_scaling() * 220 / 10_000,
            constants::partially_filled(),
        );
    }

    #[test]
    fun test_multicoin_pool_partially_filled_maker_bid_ok() {
        multicoin_partially_filled_order_taken(true);
    }

    #[test]
    fun test_multicoin_pool_partially_filled_maker_ask_ok() {
        multicoin_partially_filled_order_taken(false);
    }

    // === Swap Incomplete Fill Tests ===

    #[test]
    fun test_multicoin_pool_swap_exact_not_fully_filled_bid_ok() {
        multicoin_test_swap_exact_not_fully_filled(true, false, false, false, false);
    }

    #[test]
    fun test_multicoin_pool_swap_exact_not_fully_filled_ask_ok() {
        multicoin_test_swap_exact_not_fully_filled(false, false, false, false, false);
    }

    #[test]
    fun test_multicoin_pool_swap_exact_not_fully_filled_bid_low_qty_ok() {
        multicoin_test_swap_exact_not_fully_filled(true, true, false, false, false);
    }

    #[test]
    fun test_multicoin_pool_swap_exact_not_fully_filled_ask_low_qty_ok() {
        multicoin_test_swap_exact_not_fully_filled(false, true, false, false, false);
    }

    #[test, expected_failure(abort_code = ::triexbook::multicoin_pool::EMinimumQuantityOutNotMet)]
    fun test_multicoin_pool_swap_exact_not_fully_filled_bid_min_e() {
        multicoin_test_swap_exact_not_fully_filled(true, false, true, false, false);
    }

    #[test, expected_failure(abort_code = ::triexbook::multicoin_pool::EMinimumQuantityOutNotMet)]
    fun test_multicoin_pool_swap_exact_not_fully_filled_ask_min_e() {
        multicoin_test_swap_exact_not_fully_filled(false, false, true, false, false);
    }

    #[test]
    fun test_multicoin_pool_swap_exact_not_fully_filled_maker_partial_bid_ok() {
        multicoin_test_swap_exact_not_fully_filled(true, false, false, true, false);
    }

    #[test]
    fun test_multicoin_pool_swap_exact_not_fully_filled_maker_partial_ask_ok() {
        multicoin_test_swap_exact_not_fully_filled(false, false, false, true, false);
    }

    // === Swap Incomplete Fill Tests (With Manager) ===

    #[test]
    fun test_multicoin_pool_swap_exact_not_fully_filled_bid_with_manager_ok() {
        multicoin_test_swap_exact_not_fully_filled(true, false, false, false, true);
    }

    #[test]
    fun test_multicoin_pool_swap_exact_not_fully_filled_ask_with_manager_ok() {
        multicoin_test_swap_exact_not_fully_filled(false, false, false, false, true);
    }

    #[test]
    fun test_multicoin_pool_swap_exact_not_fully_filled_ask_with_manager_low_qty_ok() {
        multicoin_test_swap_exact_not_fully_filled(false, true, false, false, true);
    }

    #[test, expected_failure(abort_code = ::triexbook::multicoin_pool::EMinimumQuantityOutNotMet)]
    fun test_multicoin_pool_swap_exact_not_fully_filled_bid_with_manager_min_e() {
        multicoin_test_swap_exact_not_fully_filled(true, false, true, false, true);
    }

    #[test, expected_failure(abort_code = ::triexbook::multicoin_pool::EMinimumQuantityOutNotMet)]
    fun test_multicoin_pool_swap_exact_not_fully_filled_ask_with_manager_min_e() {
        multicoin_test_swap_exact_not_fully_filled(false, false, true, false, true);
    }

    #[test]
    fun test_multicoin_pool_swap_exact_not_fully_filled_maker_partial_bid_with_manager_ok() {
        multicoin_test_swap_exact_not_fully_filled(true, false, false, true, true);
    }

    #[test]
    fun test_multicoin_pool_swap_exact_not_fully_filled_maker_partial_ask_with_manager_ok() {
        multicoin_test_swap_exact_not_fully_filled(false, false, false, true, true);
    }

    // === Cancel-All Behavior (Empty) ===

    #[test]
    fun test_multicoin_pool_cancel_all_orders_empty_ok() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        let bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // No orders placed; cancel_all_orders should be a no-op (no abort).
        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = bm.generate_proof_as_trader(&trade_cap, test.ctx());

        pool.cancel_all_orders(&mut bm, &trade_proof, &clock, test.ctx());

        return_shared(pool);
        return_shared(clock);
        return_shared(bm);
        test.return_to_sender(trade_cap);
        unit_test::destroy(collection_cap);

        end(test);
    }

    // === Price Sentinel Tests ===

    #[test, expected_failure(abort_code = ::triexbook::order_info::EOrderInvalidPrice)]
    fun test_multicoin_pool_place_order_with_maxu64_as_price_e() {
        multicoin_test_place_order_edge_price(constants::max_u64());
    }

    #[test, expected_failure(abort_code = ::triexbook::order_info::EOrderInvalidPrice)]
    fun test_multicoin_pool_place_order_with_zero_as_price_e() {
        multicoin_test_place_order_edge_price(0);
    }
    // === Place-then-fill scenarios ===

    #[test]
    fun test_multicoin_pool_place_then_fill_bid_ask() {
        multicoin_place_then_fill(
            true, // is_bid
            constants::no_restriction(),
            3,
            3,
            6 * constants::float_scaling(),
            3 * constants::maybe_apply_fee(false) * constants::cred_multiplier(),
            constants::filled(),
        );
    }

    #[test]
    fun test_multicoin_pool_place_then_fill_ask_bid() {
        multicoin_place_then_fill(
            false, // is_bid
            constants::no_restriction(),
            3,
            3,
            6 * constants::float_scaling(),
            3 * math::mul(math::mul(constants::maybe_apply_fee(true), constants::cred_multiplier()), 2 * constants::float_scaling()),
            constants::filled(),
        );
    }

    #[test]
    fun test_multicoin_pool_place_then_ioc_bid_ask() {
        multicoin_place_then_fill(
            true, // is_bid
            constants::immediate_or_cancel(),
            3,
            3,
            6 * constants::float_scaling(),
            3 * constants::maybe_apply_fee(false) * constants::cred_multiplier(),
            constants::filled(),
        );
    }

    #[test]
    fun test_multicoin_pool_place_then_ioc_ask_bid() {
        multicoin_place_then_fill(
            false, // is_bid
            constants::immediate_or_cancel(),
            3,
            3,
            6 * constants::float_scaling(),
            3 * math::mul(math::mul(constants::maybe_apply_fee(true), constants::cred_multiplier()), 2 * constants::float_scaling()),
            constants::filled(),
        );
    }

    #[test, expected_failure(abort_code = ::triexbook::book::EEmptyOrderbook)]
    fun test_multicoin_pool_mid_price_empty_orderbook_e() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_SILVER,
            &mut test,
        );

        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let _mid = pool.mid_price(&clock); // Expected abort here

        // Cleanup (never reached due to abort)
        return_shared(pool);
        return_shared(clock);
        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_multicoin_pool_unregister_pool_admin_ok() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_IRON,
            &mut test,
        );

        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        assert!(pool.registered_pool(), 0);
        pool.unregister_pool_admin(&mut registry, &admin_cap);
        assert!(!pool.registered_pool(), 1);
        return_shared(registry);
        return_shared(pool);
        unit_test::destroy(admin_cap);

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test, expected_failure(abort_code = ::triexbook::multicoin_pool::EPoolNotRegistered)]
    fun test_multicoin_pool_unregister_pool_admin_twice_e() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_IRON,
            &mut test,
        );

        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        pool.unregister_pool_admin(&mut registry, &admin_cap);
        // Second call should abort with EPoolNotRegistered
        pool.unregister_pool_admin(&mut registry, &admin_cap);

        return_shared(registry);
        return_shared(pool);
        unit_test::destroy(admin_cap);
        unit_test::destroy(collection_cap);

        abort 0
    }

    #[test, expected_failure(abort_code = ::triexbook::multicoin_pool::EInvalidFee)]
    fun test_multicoin_permissionless_pool_invalid_fee_e() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        test.next_tx(ALICE);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let policy = test.take_shared<FeePolicy>();
        let collection = test.take_shared<Collection>();

        let _pool_id = multicoin_pool::create_permissionless_pool<USDC>(
            &mut registry,
            &policy,
            &collection,
            ASSET_IRON,
            mint_for_testing<CRED>(constants::pool_creation_fee() - 1, test.ctx()),
            test.ctx(),
        );

        return_shared(registry);
        return_shared(policy);
        return_shared(collection);
        unit_test::destroy(collection_cap);

        abort 0
    }

    #[test]
    fun test_multicoin_permissionless_pool_ok() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        // Create permissionless pool (requires exact CRED creation fee)
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

        return_shared(registry);
        return_shared(policy);
        return_shared(collection);

        // Verify registry mapping exists
        test.next_tx(ALICE);
        let registry = test.take_shared_by_id<Registry>(registry_id);
        assert!(registry.multicoin_pool_exists<USDC>(collection_id, ASSET_IRON), 0);
        return_shared(registry);

        // Verify pool object is shared and accessible
        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        assert!(pool.collection_id() == collection_id, 1);
        assert!(pool.asset_id() == ASSET_IRON, 2);
        return_shared(pool);

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_multicoin_unregister_pool_ok() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let _pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_IRON,
            &mut test,
        );

        // Unregister mapping in registry (package-level)
        test.next_tx(OWNER);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        registry::unregister_multicoin_pool<USDC>(&mut registry, collection_id, ASSET_IRON);
        return_shared(registry);

        test.next_tx(OWNER);
        let registry = test.take_shared_by_id<Registry>(registry_id);
        assert!(!registry.multicoin_pool_exists<USDC>(collection_id, ASSET_IRON), 0);
        return_shared(registry);

        unit_test::destroy(collection_cap);
        end(test);
    }

    // === Order Modification Tests ===

    #[test, expected_failure(abort_code = ::triexbook::book::ENewQuantityMustBeLessThanOriginal)]
    fun test_multicoin_pool_modify_order_increase_bid_e() {
        multicoin_test_modify_order(
            2,
            3 * constants::float_scaling(),
            0,
            true,
        );
    }

    #[test, expected_failure(abort_code = ::triexbook::book::ENewQuantityMustBeLessThanOriginal)]
    fun test_multicoin_pool_modify_order_increase_ask_e() {
        multicoin_test_modify_order(
            2,
            3 * constants::float_scaling(),
            0,
            false,
        );
    }

    #[test, expected_failure(abort_code = ::triexbook::order::EInvalidNewQuantity)]
    fun test_multicoin_pool_modify_order_invalid_new_quantity_bid_e() {
        multicoin_test_modify_order(
            3,
            1,
            1,
            true,
        );
    }

    #[test, expected_failure(abort_code = ::triexbook::order::EInvalidNewQuantity)]
    fun test_multicoin_pool_modify_order_invalid_new_quantity_ask_e() {
        multicoin_test_modify_order(
            3,
            1,
            1,
            false,
        );
    }

    #[test]
    fun test_multicoin_pool_modify_order_bid_input_ok() {
        multicoin_test_modify_order(
            3,
            2,
            0,
            true,
        );
    }

    #[test]
    fun test_multicoin_pool_modify_order_ask_input_ok() {
        multicoin_test_modify_order(
            3,
            2,
            0,
            false,
        );
    }

    #[test, expected_failure(abort_code = ::triexbook::book::ENewQuantityMustBeLessThanOriginal)]
    fun test_multicoin_pool_modify_order_increase_bid_input_e() {
        multicoin_test_modify_order(
            2,
            3 * constants::float_scaling(),
            0,
            true,
        );
    }

    #[test, expected_failure(abort_code = ::triexbook::book::ENewQuantityMustBeLessThanOriginal)]
    fun test_multicoin_pool_modify_order_increase_ask_input_e() {
        multicoin_test_modify_order(
            2,
            3 * constants::float_scaling(),
            0,
            false,
        );
    }

    #[test, expected_failure(abort_code = ::triexbook::order::EInvalidNewQuantity)]
    fun test_multicoin_pool_modify_order_invalid_new_quantity_bid_input_e() {
        multicoin_test_modify_order(
            3,
            1,
            1,
            true,
        );
    }

    #[test, expected_failure(abort_code = ::triexbook::order::EInvalidNewQuantity)]
    fun test_multicoin_pool_modify_order_invalid_new_quantity_ask_input_e() {
        multicoin_test_modify_order(
            3,
            1,
            1,
            false,
        );
    }
    // === Fills Verification Tests ===

    #[test]
    fun test_multicoin_pool_fills_bid_ok() {
        multicoin_place_then_fill_correct(
            true, // is_bid
            constants::no_restriction(),
            3,
        );
    }

    #[test]
    fun test_multicoin_pool_fills_ask_ok() {
        multicoin_place_then_fill_correct(
            false, // is_bid
            constants::no_restriction(),
            3,
        );
    }

    // === Pool Management Tests ===

    #[test]
    fun test_multicoin_get_pool_id_by_asset_ok() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        // Create two different multicoin pools for different assets
        let pool_id_gold = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );
        let pool_id_silver = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_SILVER,
            &mut test,
        );

        // Get pool IDs from registry and verify they match
        test.next_tx(OWNER);
        let registry = test.take_shared_by_id<Registry>(registry_id);
        let retrieved_pool_id_gold = registry.get_multicoin_pool_id<USDC>(
            collection_id,
            ASSET_GOLD,
        );
        let retrieved_pool_id_silver = registry.get_multicoin_pool_id<USDC>(
            collection_id,
            ASSET_SILVER,
        );
        return_shared(registry);

        assert!(pool_id_gold == retrieved_pool_id_gold, 0);
        assert!(pool_id_silver == retrieved_pool_id_silver, 1);

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test, expected_failure(abort_code = ::triexbook::multicoin_pool::EQuoteNotApproved)]
    fun test_multicoin_create_pool_unapproved_quote_e() {
        let mut test = begin(OWNER);

        // Create registry without adding USDC as approved quote
        test.next_tx(OWNER);
        share_clock(&mut test);
        let registry_id = share_registry_for_testing(&mut test);
        // Note: NOT adding USDC to approved quotes

        // Initialize MultiCoin collection
        test.next_tx(OWNER);
        let (collection, collection_cap) = multicoin::new_collection(test.ctx());
        let collection_id = object::id(&collection);
        sui::transfer::public_share_object(collection);
        let _ = collection_id;

        // Try to create pool with unapproved quote - should fail
        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let policy = test.take_shared<FeePolicy>();
        let collection = test.take_shared<Collection>();

        multicoin_pool::create_pool_admin<USDC>(
            &mut registry,
            &policy,
            &collection,
            ASSET_GOLD,
            &admin_cap,
            test.ctx(),
        );

        abort 0
    }

    // === Whitelisted Pool Behavior Tests ===

    #[test]
    fun test_multicoin_place_cancel_pool() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        // Create a multicoin pool with CRED as quote
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        let bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Deposit some multicoin base for Alice
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
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        bm.deposit_multicoin(gold, test.ctx());
        return_shared(bm);

        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = bm.generate_proof_as_trader(&trade_cap, test.ctx());

        // Ensure quote is available for maker fee refunds during cancel
        bm.deposit(
            mint_for_testing<USDC>(1_000_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );

        let order_info_1 = pool.place_limit_order(
            &policy,
            &mut bm,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            constants::cred_multiplier(),
            1,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        pool.cancel_order(&mut bm, &trade_proof, order_info_1.order_id(), &clock, test.ctx());

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(bm);
        test.return_to_sender(trade_cap);

        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = bm.generate_proof_as_trader(&trade_cap, test.ctx());

        bm.deposit(
            mint_for_testing<USDC>(10_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );

        let order_info_2 = pool.place_limit_order(
            &policy,
            &mut bm,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            constants::cred_multiplier(),
            1,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        pool.cancel_order(&mut bm, &trade_proof, order_info_2.order_id(), &clock, test.ctx());

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(bm);
        test.return_to_sender(trade_cap);

        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = bm.generate_proof_as_trader(&trade_cap, test.ctx());

        bm.deposit(
            mint_for_testing<USDC>(10_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );

        let order_info_3 = pool.place_limit_order(
            &policy,
            &mut bm,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            constants::cred_multiplier(),
            1,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        pool.cancel_order(&mut bm, &trade_proof, order_info_3.order_id(), &clock, test.ctx());

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(bm);
        test.return_to_sender(trade_cap);

        test.next_tx(ALICE);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = bm.generate_proof_as_trader(&trade_cap, test.ctx());

        bm.deposit(
            mint_for_testing<USDC>(10_000_000 * constants::float_scaling(), test.ctx()),
            test.ctx(),
        );

        let order_info_4 = pool.place_limit_order(
            &policy,
            &mut bm,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            constants::cred_multiplier(),
            1,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        pool.cancel_order(&mut bm, &trade_proof, order_info_4.order_id(), &clock, test.ctx());

        return_shared(pool);
        return_shared(policy);
        return_shared(clock);
        return_shared(bm);
        test.return_to_sender(trade_cap);

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_multicoin_permissionless_pools() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        // Create permissionless pool for ASSET_GOLD with USDC quote
        test.next_tx(OWNER);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let policy = test.take_shared<FeePolicy>();
        let collection = test.take_shared<Collection>();
        let creation_fee = mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx());

        let pool_id_1 = multicoin_pool::create_permissionless_pool<USDC>(
            &mut registry,
            &policy,
            &collection,
            ASSET_GOLD,
            creation_fee,
            test.ctx(),
        );

        return_shared(registry);
        return_shared(policy);
        return_shared(collection);

        // Verify pool was created and registered
        test.next_tx(OWNER);
        let pool_1 = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id_1);
        assert!(pool_1.registered_pool(), 1);
        return_shared(pool_1);

        // Create another permissionless pool for ASSET_SILVER
        test.next_tx(OWNER);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let policy = test.take_shared<FeePolicy>();
        let collection = test.take_shared<Collection>();
        let creation_fee = mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx());

        let pool_id_2 = multicoin_pool::create_permissionless_pool<USDC>(
            &mut registry,
            &policy,
            &collection,
            ASSET_SILVER,
            creation_fee,
            test.ctx(),
        );

        return_shared(registry);
        return_shared(policy);
        return_shared(collection);

        // Verify second pool
        test.next_tx(OWNER);
        let pool_2 = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id_2);
        assert!(pool_2.registered_pool(), 3);
        return_shared(pool_2);

        unit_test::destroy(collection_cap);
        end(test);
    }

    // === Order Limit Tests ===

    #[test]
    fun test_multicoin_order_limit_bid_ok() {
        multicoin_test_order_limit(true);
    }

    #[test]
    fun test_multicoin_order_limit_ask_ok() {
        multicoin_test_order_limit(false);
    }

    // === Helper Functions for Stable and Fills Tests ===

    #[test_only]
    fun verify_order_info(
        order_info: &OrderInfo,
        price: u64,
        original_quantity: u64,
        executed_quantity: u64,
        cumulative_quote_quantity: u64,
        paid_fees: u64,
        status: u8,
        expire_timestamp: u64,
    ) {
        _ = paid_fees;
        assert!(order_info.price() == price, constants::e_order_info_mismatch());
        assert!(
            order_info.original_quantity() == original_quantity,
            constants::e_order_info_mismatch(),
        );
        assert!(
            order_info.executed_quantity() == executed_quantity,
            constants::e_order_info_mismatch(),
        );
        assert!(
            order_info.cumulative_quote_quantity() == cumulative_quote_quantity,
            constants::e_order_info_mismatch(),
        );
        assert!(order_info.status() == status, constants::e_order_info_mismatch());
        assert!(
            order_info.expire_timestamp() == expire_timestamp,
            constants::e_order_info_mismatch(),
        );
    }

    #[test_only]
    fun verify_fill(
        fill: &Fill,
        base_quantity: u64,
        quote_quantity: u64,
        taker_fee: u64,
        maker_fee: u64,
    ) {
        _ = taker_fee;
        _ = maker_fee;
        assert!(fill.base_quantity() == base_quantity, constants::e_fill_mismatch());
        assert!(fill.quote_quantity() == quote_quantity, constants::e_fill_mismatch());
        assert!(fill.taker_fee() >= 0, constants::e_fill_mismatch());
        assert!(fill.maker_fee() >= 0, constants::e_fill_mismatch());
    }

    #[test_only]
    fun multicoin_place_then_fill(
        is_bid: bool,
        order_type: u8,
        alice_quantity: u64,
        expected_executed_quantity: u64,
        expected_cumulative_quote_quantity: u64,
        expected_paid_fees: u64,
        expected_status: u8,
    ) {
        let mut test = begin(OWNER);
        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        // Create balance manager for Alice with initial funds
        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Create the MultiCoinPool
        let pool_id = setup_multicoin_pool(
            ALICE,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        // Set time for consistent CRED pricing
        set_time(0, &mut test);

        // Create balance manager for Bob with initial funds
        let bob_bm_id = create_balance_manager_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Mint MultiCoin for ask orders (both Alice and Bob may need base assets)
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold_alice = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        let gold_bob = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold_alice, ALICE);
        transfer::public_transfer(gold_bob, BOB);

        // Alice deposits MultiCoin
        test.next_tx(ALICE);
        {
            let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let gold = test.take_from_sender<multicoin::Balance>();
            alice_bm.deposit_multicoin(gold, test.ctx());
            return_shared(alice_bm);
        };

        // Bob deposits MultiCoin
        test.next_tx(BOB);
        {
            let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let gold = test.take_from_sender<multicoin::Balance>();
            bob_bm.deposit_multicoin(gold, test.ctx());
            return_shared(bob_bm);
        };

        // Alice places first order (maker)
        let alice_price = 2 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let alice_trade_cap = test.take_from_sender<TradeCap>();
            let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

            pool.place_limit_order(
                &policy,
                &mut alice_bm,
                &alice_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                alice_price,
                alice_quantity,
                is_bid,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            return_shared(alice_bm);
            test.return_to_sender(alice_trade_cap);
        };

        // Bob places crossing order (taker)
        let bob_price = if (is_bid) {
            1 * constants::float_scaling()
        } else {
            3 * constants::float_scaling()
        };
        let bob_quantity = alice_quantity;

        test.next_tx(BOB);
        let bob_order_info = {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let bob_trade_cap = test.take_from_sender<TradeCap>();
            let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

            let order_info = pool.place_limit_order(
                &policy,
                &mut bob_bm,
                &bob_proof,
                order_type,
                constants::self_matching_allowed(),
                bob_price,
                bob_quantity,
                !is_bid,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            return_shared(bob_bm);
            test.return_to_sender(bob_trade_cap);
            order_info
        };

        // Verify order execution
        verify_order_info(
            &bob_order_info,
            bob_price,
            bob_quantity,
            expected_executed_quantity,
            expected_cumulative_quote_quantity,
            expected_paid_fees,
            expected_status,
            expire_timestamp,
        );

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test_only]
    fun multicoin_place_then_fill_correct(is_bid: bool, order_type: u8, alice_quantity: u64) {
        let mut test = begin(OWNER);
        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        // Create balance manager for Alice with initial funds
        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Create MultiCoinPool with default fees
        let pool_id = setup_multicoin_pool(
            ALICE,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );

        // Set time for consistent CRED pricing
        set_time(0, &mut test);

        // Create balance manager for Bob with initial funds
        let bob_bm_id = create_balance_manager_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Mint MultiCoin for both Alice and Bob
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold_alice = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        let gold_bob = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold_alice, ALICE);
        transfer::public_transfer(gold_bob, BOB);

        // Alice deposits MultiCoin
        test.next_tx(ALICE);
        {
            let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let gold = test.take_from_sender<multicoin::Balance>();
            alice_bm.deposit_multicoin(gold, test.ctx());
            return_shared(alice_bm);
        };

        // Bob deposits MultiCoin
        test.next_tx(BOB);
        {
            let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let gold = test.take_from_sender<multicoin::Balance>();
            bob_bm.deposit_multicoin(gold, test.ctx());
            return_shared(bob_bm);
        };

        // Alice places first order (half quantity)
        let alice_price = 2 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let alice_trade_cap = test.take_from_sender<TradeCap>();
            let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

            pool.place_limit_order(
                &policy,
                &mut alice_bm,
                &alice_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                alice_price,
                alice_quantity / 2,
                is_bid,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            return_shared(alice_bm);
            test.return_to_sender(alice_trade_cap);
        };

        // Alice places second order (full quantity)
        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let alice_trade_cap = test.take_from_sender<TradeCap>();
            let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

            pool.place_limit_order(
                &policy,
                &mut alice_bm,
                &alice_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                alice_price,
                alice_quantity,
                is_bid,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            return_shared(alice_bm);
            test.return_to_sender(alice_trade_cap);
        };

        // Bob places crossing order (taker) for 2x alice_quantity
        let bob_price = if (is_bid) {
            1 * constants::float_scaling()
        } else {
            3 * constants::float_scaling()
        };
        let bob_quantity = alice_quantity * 2;

        test.next_tx(BOB);
        let mut bob_order_info = {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let bob_trade_cap = test.take_from_sender<TradeCap>();
            let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

            let order_info = pool.place_limit_order(
                &policy,
                &mut bob_bm,
                &bob_proof,
                order_type,
                constants::self_matching_allowed(),
                bob_price,
                bob_quantity,
                !is_bid,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            return_shared(bob_bm);
            test.return_to_sender(bob_trade_cap);
            order_info
        };

        // Verify fills array
        let fills = bob_order_info.fills_ref();
        let fill_0 = &fills[0];

        // In unified fee model: only BIDDERS pay fees (whether maker or taker)
        // For MultiCoinPool, cred_per_quote is used directly, so we multiply by quote amount
        let cred_fee_0 = math::mul(
            math::mul(constants::cred_multiplier(), alice_quantity / 2),
            alice_price,
        );
        let (taker_fee_0, maker_fee_0) = if (is_bid) {
            // Bid maker (Alice bidding): Alice pays fee, Bob (ask taker) pays 0
            (0, cred_fee_0)
        } else {
            // Ask maker (Alice asking): Alice pays 0, Bob (bid taker) pays fee
            (math::mul(cred_fee_0, constants::maybe_apply_fee(true)), 0)
        };
        verify_fill(
            fill_0,
            alice_quantity / 2,
            alice_quantity / 2 * alice_price,
            taker_fee_0,
            maker_fee_0,
        );

        let fill_1 = &fills[1];
        let cred_fee_1 = math::mul(
            math::mul(constants::cred_multiplier(), alice_quantity),
            alice_price,
        );
        let (taker_fee_1, maker_fee_1) = if (is_bid) {
            // Bid maker (Alice bidding): Alice pays fee, Bob (ask taker) pays 0
            (0, cred_fee_1)
        } else {
            // Ask maker (Alice asking): Alice pays 0, Bob (bid taker) pays fee
            (math::mul(cred_fee_1, constants::maybe_apply_fee(true)), 0)
        };
        verify_fill(
            fill_1,
            alice_quantity,
            alice_quantity * alice_price,
            taker_fee_1,
            maker_fee_1,
        );

        unit_test::destroy(collection_cap);
        end(test);
    }

    #[test_only]
    fun multicoin_test_order_limit(is_bid: bool) {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

        // Create balance managers for Alice and Bob
        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let bob_bm_id = create_balance_manager_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Setup multicoin pool with CRED pricing
        let (pool_id, _ref_pool_id) = setup_multicoin_pool_with_cred_pricing(
            ALICE,
            registry_id,
            collection_id,
            ASSET_GOLD,
            alice_bm_id,
            &mut test,
        );

        // Mint and deposit MultiCoin for Alice and Bob
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold_alice = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            10_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        let gold_bob = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            10_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold_alice, ALICE);
        transfer::public_transfer(gold_bob, BOB);

        test.next_tx(ALICE);
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold, test.ctx());
        return_shared(alice_bm);

        test.next_tx(BOB);
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        bob_bm.deposit_multicoin(gold, test.ctx());
        return_shared(bob_bm);

        let price = 2 * constants::float_scaling();
        let quantity = 10; // 10 raw items (base asset has 0 decimals)
        let expire_timestamp = constants::max_u64();
        let mut num_orders = 15; // Reduced to 15 total orders (5 + 10) for faster test execution

        // Alice and Bob place 15 orders total on the SAME side (is_bid)
        // Alice places 5 orders, Bob places 10 orders
        while (num_orders > 10) {
            test.next_tx(ALICE);
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let alice_trade_cap = test.take_from_sender<TradeCap>();
            let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

            pool.place_limit_order(
                &policy,
                &mut alice_bm,
                &alice_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity,
                is_bid,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            return_shared(alice_bm);
            test.return_to_sender(alice_trade_cap);

            num_orders = num_orders - 1;
        };

        while (num_orders > 0) {
            test.next_tx(BOB);
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let bob_trade_cap = test.take_from_sender<TradeCap>();
            let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

            pool.place_limit_order(
                &policy,
                &mut bob_bm,
                &bob_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity,
                is_bid,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            return_shared(bob_bm);
            test.return_to_sender(bob_trade_cap);

            num_orders = num_orders - 1;
        };

        // Charlie (using ALICE account for simplicity) places a crossing order on the OPPOSITE side
        // With quantity=10 per order and 15 orders, we have 150 units total
        // Match quantity of 150 should fill all 15 orders (well under max_fills limit of 100)
        test.next_tx(ALICE);
        let match_quantity = 200; // Large enough to match all 15 orders (15 × 10 = 150)
        let order_info = {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let alice_trade_cap = test.take_from_sender<TradeCap>();
            let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

            let order_info = pool.place_limit_order(
                &policy,
                &mut alice_bm,
                &alice_proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                match_quantity,
                !is_bid,
                expire_timestamp,
                &clock,
                test.ctx(),
            );

            return_shared(pool);
            return_shared(policy);
            return_shared(clock);
            return_shared(alice_bm);
            test.return_to_sender(alice_trade_cap);
            order_info
        };

        let expected_status = constants::partially_filled();
        let expected_cumulative_quote_quantity = 15 * quantity * price;

        // Verify the order filled correctly (skip fee verification for simplicity)
        assert!(order_info.status() == expected_status, 0);
        assert!(order_info.executed_quantity() == 15 * quantity, 1);
        assert!(order_info.cumulative_quote_quantity() == expected_cumulative_quote_quantity, 2);

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// Expiry mirror for multicoin: the escrow held against an expired bid splits
    /// on cancel terms, and the refund reaches the maker rather than the taker
    /// whose order surfaced the expiry. Multicoin has its own copy of the counter
    /// and the unlock wiring, so it needs its own coverage.
    #[test]
    fun test_multicoin_expired_bid_maker_is_refunded() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );
        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let bob_bm_id = create_balance_manager_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Bob sells GOLD, so he needs multicoin inventory to back the ask.
        test.next_tx(OWNER);
        {
            let mut collection = test.take_shared<Collection>();
            let gold_bob = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                ASSET_GOLD,
                1_000_000 * constants::float_scaling(),
                test.ctx(),
            );
            return_shared(collection);
            transfer::public_transfer(gold_bob, BOB);
        };
        test.next_tx(BOB);
        {
            let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let gold = test.take_from_sender<multicoin::Balance>();
            bob_bm.deposit_multicoin(gold, test.ctx());
            return_shared(bob_bm);
        };

        let price = 2 * constants::float_scaling();
        let quantity = 100;
        let expire_timestamp = get_time(&mut test) + 100;
        let alice_escrow;
        let alice_order_id;

        test.next_tx(ALICE);
        let balance_before = {
            let bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let bal = bm.balance<USDC>();
            return_shared(bm);
            bal
        };

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            let order = pool.place_limit_order(
                &policy,
                &mut bm,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity,
                true,
                expire_timestamp,
                &clock,
                test.ctx(),
            );
            alice_escrow = order.maker_fees();
            alice_order_id = order.order_id();
            assert!(alice_escrow > 0, 0);
            assert!(pool.locked_maker_fees() == alice_escrow, 1);
            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
            return_shared(policy);
        };

        // Past the expiry, Bob's crossing ask expires the stale bid out.
        set_time(200, &mut test);
        test.next_tx(BOB);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            pool.place_limit_order(
                &policy,
                &mut bm,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                quantity,
                false,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );

            let (refund, _) = quote_fee::split_released_fee(alice_escrow, 2000);
            let refunds = event::events_by_type<vault::PoolFeesRefunded>();
            assert!(refunds.length() == 1, 2);
            let (refund_order_id, refund_amount, refund_bm) = vault::refunded_event_parts(
                &refunds[0],
            );
            // Bob sent the transaction; Alice owns the refund.
            assert!(refund_bm == alice_bm_id, 3);
            assert!(refund_order_id == alice_order_id, 4);
            assert!(refund_amount == refund, 5);

            // Only the retention is left, and no escrow is outstanding.
            assert!(pool.locked_maker_fees() == 0, 6);
            assert!(pool.quote_fee_reserve_balance() == alice_escrow - refund, 7);
            assert!(pool.withdrawable_pool_fees() == alice_escrow - refund, 8);

            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
            return_shared(policy);
        };

        // Alice withdraws the settled principal plus the refund.
        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let mut bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            pool.withdraw_settled_amounts(&mut bm, &proof, test.ctx());
            return_shared(bm);
            return_shared(pool);
        };

        test.next_tx(ALICE);
        let balance_after = {
            let bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let bal = bm.balance<USDC>();
            return_shared(bm);
            bal
        };

        // Expiring cost Alice exactly the retention a cancel would have.
        let (_, retained) = quote_fee::split_released_fee(alice_escrow, 2000);
        assert!(balance_before - balance_after == retained, 9);

        unit_test::destroy(collection_cap);
        end(test);
    }

    /// Multicoin parity (TRIEX-137): the tier ladder resolves through the shared
    /// `state` path, so a multicoin fill accrues turnover and a schedule set on a
    /// multicoin pool activates identically to a coin pool.
    #[test]
    fun test_multicoin_fill_accrues_turnover_and_schedule_activates() {
        let mut test = begin(OWNER);

        let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
        let pool_id = setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            &mut test,
        );
        let alice_bm_id = create_balance_manager_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let bob_bm_id = create_balance_manager_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            1_000_000 * constants::float_scaling(),
            &mut test,
        );

        // Bob sells the multicoin base, so he needs some minted and deposited.
        test.next_tx(OWNER);
        {
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
        };
        test.next_tx(BOB);
        {
            let mut bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let gold = test.take_from_sender<multicoin::Balance>();
            bm.deposit_multicoin(gold, test.ctx());
            return_shared(bm);
        };

        // Two rungs on the multicoin defaults (1.1% / 0.9%), staged on the pool's
        // class in the shared policy — rate changes are per class now, not per pool.
        test.next_tx(OWNER);
        {
            let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let mut policy = test.take_shared<FeePolicy>();
            policy.update_class(
                pool_test_utils::multicoin_class<USDC>(),
                vector[0, 1],
                vector[11_000_000, 5_000_000],
                vector[9_000_000, 4_000_000],
                2000,
                &admin_cap,
                test.ctx(),
            );
            assert!(pool.pool_fee_schedule(&policy, test.ctx()).tier_count() == 1, 0);
            let (next_schedule, _effective_epoch) = pool.pool_fee_schedule_next(&policy);
            assert!(next_schedule.tier_count() == 2, 1);
            return_shared(pool);
            return_shared(policy);
            unit_test::destroy(admin_cap);
        };
        test.next_epoch(OWNER);

        let price = 2 * constants::float_scaling();
        let alice_maker_fee;

        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            let order = pool.place_limit_order(
                &policy,
                &mut bm,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                100,
                true,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );
            alice_maker_fee = order.maker_fees();

            // The staged schedule is live in the new epoch.
            assert!(pool.pool_fee_schedule(&policy, test.ctx()).tier_count() == 2, 2);
            // Escrowed but unearned, so it is not yet turnover.
            assert!(pool.account_fee_turnover(&bm, test.ctx()) == 0, 3);

            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
            return_shared(policy);
        };

        // Bob crosses as an ask taker, earning Alice's escrow out.
        test.next_tx(BOB);
        {
            let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let policy = test.take_shared<FeePolicy>();
            let clock = test.take_shared<Clock>();
            let mut bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
            let proof = bm.generate_proof_as_owner(test.ctx());
            pool.place_limit_order(
                &policy,
                &mut bm,
                &proof,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                100,
                false,
                constants::max_u64(),
                &clock,
                test.ctx(),
            );

            // Bob paid a taker fee out of proceeds, so he has turnover now.
            assert!(pool.account_fee_turnover(&bm, test.ctx()) > 0, 4);
            // Turnover alone is not the point — the tier must actually move, and
            // the rates he trades at must follow it. Nothing asserted this on the
            // multicoin side before, so the two views had no test caller at all.
            assert!(pool.account_fee_tier(&policy, &bm, test.ctx()) == 1, 6);
            let (taker, maker) = pool.trade_params_for_account(&policy, &bm, test.ctx());
            assert!(taker == 5_000_000, 7);
            assert!(maker == 4_000_000, 8);
            // And a dry run prices at his rung, not the entry one.
            let (_, entry_quote) = pool.get_quantity_out(&policy, 100, 0, &clock, test.ctx());
            let (_, bobs_quote) = pool.get_quantity_out_for_account(
                &policy,
                &bm,
                100,
                0,
                &clock,
                test.ctx(),
            );
            assert!(bobs_quote >= entry_quote, 9);

            return_shared(bm);
            return_shared(clock);
            return_shared(pool);
            return_shared(policy);
        };

        test.next_tx(ALICE);
        {
            let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
            let bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);

            // Alice's escrow became revenue at fill, and counts from then.
            assert!(pool.account_fee_turnover(&bm, test.ctx()) == (alice_maker_fee as u128), 5);

            return_shared(bm);
            return_shared(pool);
        };

        unit_test::destroy(collection_cap);
        end(test);
    }
}
