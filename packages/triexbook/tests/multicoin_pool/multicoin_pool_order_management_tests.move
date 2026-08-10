// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_multicoin_pool_order_management_tests;

use multicoin::multicoin::{Self, Collection, CollectionCap};
use std::unit_test;
use sui::{
    clock::{Self, Clock},
    coin::{Self, mint_for_testing},
    test_scenario::{Scenario, begin, end, return_shared}
};
use token::cred::CRED;
use triexbook::{
    balance_manager::{Self, BalanceManager, TradeCap, DepositCap, WithdrawCap},
    constants,
    fill::Fill,
    integration_multicoin_test_utils::{Self as mc_utils, USDC},
    math,
    multicoin_pool::{Self, MultiCoinPool},
    order_info::OrderInfo,
    pool::{Self, Pool},
    registry::{Self, Registry}
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
    whitelisted_pool: bool,
    stable_pool: bool,
    test: &mut Scenario,
): ID {
    mc_utils::setup_multicoin_pool(
        sender,
        registry_id,
        collection_id,
        asset_id,
        whitelisted_pool,
        stable_pool,
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

// === Modify Order Tests ===

#[test]
fun test_multicoin_pool_modify_order_bid_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // ALICE places bid for 100 units
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    assert!(order_info.status() == constants::live(), 0);
    let order_id = order_info.order_id();

    // Modify to decrease quantity to 50
    pool.modify_order(
        &mut alice_bm,
        &alice_proof,
        order_id,
        50,
        &clock,
        test.ctx(),
    );

    // Verify order was modified
    let modified_order = pool.get_order(order_id);
    assert!(modified_order.quantity() == 50, 1);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_multicoin_pool_modify_order_ask_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    // ALICE balance manager with MultiCoin
    test.next_tx(ALICE);
    let mut alice_bm = balance_manager::new(test.ctx());
    alice_bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    alice_bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let alice_trade_cap = alice_bm.mint_trade_cap(test.ctx());
    let alice_bm_id = object::id(&alice_bm);
    transfer::public_share_object(alice_bm);
    transfer::public_transfer(alice_trade_cap, ALICE);

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
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    alice_bm.deposit_multicoin(gold, test.ctx());
    return_shared(alice_bm);

    // ALICE places ask for 100 units
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    assert!(order_info.status() == constants::live(), 0);
    let order_id = order_info.order_id();

    // Modify to decrease quantity to 50
    pool.modify_order(
        &mut alice_bm,
        &alice_proof,
        order_id,
        50,
        &clock,
        test.ctx(),
    );

    // Verify order was modified
    let modified_order = pool.get_order(order_id);
    assert!(modified_order.quantity() == 50, 1);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test, expected_failure(abort_code = ::triexbook::book::ENewQuantityMustBeLessThanOriginal)]
fun test_multicoin_pool_modify_order_increase_e() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // ALICE places bid for 100 units
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    let order_id = order_info.order_id();

    // Try to increase quantity - should fail
    pool.modify_order(
        &mut alice_bm,
        &alice_proof,
        order_id,
        150,
        &clock,
        test.ctx(),
    );

    abort 0
}

// === Cancel All Orders Tests ===

#[test]
fun test_multicoin_pool_cancel_all_orders_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    // ALICE balance manager with USDC and MultiCoin
    test.next_tx(ALICE);
    let mut alice_bm = balance_manager::new(test.ctx());
    alice_bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    alice_bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let alice_trade_cap = alice_bm.mint_trade_cap(test.ctx());
    let alice_bm_id = object::id(&alice_bm);
    transfer::public_share_object(alice_bm);
    transfer::public_transfer(alice_trade_cap, ALICE);

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
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    alice_bm.deposit_multicoin(gold, test.ctx());
    return_shared(alice_bm);

    // ALICE places multiple orders
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    // Place 3 bids at different prices
    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        10,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        20,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3 * constants::float_scaling(),
        30,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Verify Alice has 3 open orders
    let open_orders = pool.account_open_orders(&alice_bm);
    assert!(open_orders.length() == 3, 0);

    // Cancel all orders
    // Quote fee reserve retains maker fees on cancel; ensure enough quote exists for any fee adjustments
    alice_bm.deposit(
        mint_for_testing<USDC>(10_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    pool.cancel_all_orders(&mut alice_bm, &alice_proof, &clock, test.ctx());

    // Verify no open orders
    let open_orders_after = pool.account_open_orders(&alice_bm);
    assert!(open_orders_after.length() == 0, 1);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === Price Priority Tests ===

#[test]
fun test_multicoin_pool_price_priority_bid_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
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

    // Setup Charlie with MultiCoin for ask
    test.next_tx(CHARLIE);
    let mut charlie_bm = balance_manager::new(test.ctx());
    charlie_bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    charlie_bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let charlie_trade_cap = charlie_bm.mint_trade_cap(test.ctx());
    let charlie_bm_id = object::id(&charlie_bm);
    transfer::public_share_object(charlie_bm);
    transfer::public_transfer(charlie_trade_cap, CHARLIE);

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
    transfer::public_transfer(gold, CHARLIE);

    test.next_tx(CHARLIE);
    let mut charlie_bm = test.take_shared_by_id<BalanceManager>(charlie_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    charlie_bm.deposit_multicoin(gold, test.ctx());
    return_shared(charlie_bm);

    // ALICE places bid at price 1
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // BOB places bid at price 2 (better price)
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // CHARLIE places ask for 50 units - should match with BOB's better price first
    test.next_tx(CHARLIE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut charlie_bm = test.take_shared_by_id<BalanceManager>(charlie_bm_id);
    let charlie_trade_cap = test.take_from_sender<TradeCap>();
    let charlie_proof = charlie_bm.generate_proof_as_trader(&charlie_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut charlie_bm,
        &charlie_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        50,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Charlie's ask should be filled
    assert!(order_info.status() == constants::filled(), 0);
    // Charlie matched at Bob's price (2), not Alice's price (1)
    // So Charlie receives 50 * 2 = 100 quote
    assert!(order_info.cumulative_quote_quantity() == 100 * constants::float_scaling(), 1);

    return_shared(pool);
    return_shared(clock);
    return_shared(charlie_bm);
    test.return_to_sender(charlie_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_multicoin_pool_price_priority_ask_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    // Setup Alice with MultiCoin for ask
    test.next_tx(ALICE);
    let mut alice_bm = balance_manager::new(test.ctx());
    alice_bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    alice_bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let alice_trade_cap = alice_bm.mint_trade_cap(test.ctx());
    let alice_bm_id = object::id(&alice_bm);
    transfer::public_share_object(alice_bm);
    transfer::public_transfer(alice_trade_cap, ALICE);

    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let gold1 = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        1_000_000 * constants::float_scaling(),
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(gold1, ALICE);

    test.next_tx(ALICE);
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    alice_bm.deposit_multicoin(gold, test.ctx());
    return_shared(alice_bm);

    // Setup Bob with MultiCoin for ask
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

    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let gold2 = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        1_000_000 * constants::float_scaling(),
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(gold2, BOB);

    test.next_tx(BOB);
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    bob_bm.deposit_multicoin(gold, test.ctx());
    return_shared(bob_bm);

    let charlie_bm_id = create_balance_manager_with_funds(
        CHARLIE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // ALICE places ask at price 3 (higher price)
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // BOB places ask at price 2 (better/lower price for buyer)
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // CHARLIE places bid for 50 units at price 5 - should match with BOB's lower price first
    test.next_tx(CHARLIE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut charlie_bm = test.take_shared_by_id<BalanceManager>(charlie_bm_id);
    let charlie_trade_cap = test.take_from_sender<TradeCap>();
    let charlie_proof = charlie_bm.generate_proof_as_trader(&charlie_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut charlie_bm,
        &charlie_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        5 * constants::float_scaling(),
        50,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Charlie's bid should be filled
    assert!(order_info.status() == constants::filled(), 0);
    // Charlie matched at Bob's price (2), not Alice's price (3)
    // So Charlie pays 50 * 2 = 100 quote (plus fees)
    assert!(order_info.cumulative_quote_quantity() == 100 * constants::float_scaling(), 1);

    return_shared(pool);
    return_shared(clock);
    return_shared(charlie_bm);
    test.return_to_sender(charlie_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === Level 2 Book Data Tests ===

#[test]
fun test_multicoin_pool_get_level2_range_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Setup Bob with MultiCoin for asks
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

    // ALICE places bids
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        200,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // BOB places asks
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3 * constants::float_scaling(),
        300,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        4 * constants::float_scaling(),
        400,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Get Level2 data using get_level2_ticks_from_mid which returns both sides
    let (bid_prices, bid_quantities, ask_prices, ask_quantities) = pool.get_level2_ticks_from_mid(
        10, // ticks
        &clock,
    );

    // Verify bids (sorted best to worst: 2, 1)
    assert!(bid_prices.length() == 2, 0);
    assert!(*bid_prices.borrow(0) == 2 * constants::float_scaling(), 1);
    assert!(*bid_prices.borrow(1) == 1 * constants::float_scaling(), 2);
    assert!(*bid_quantities.borrow(0) == 200, 3);
    assert!(*bid_quantities.borrow(1) == 100, 4);

    // Verify asks (sorted best to worst: 3, 4)
    assert!(ask_prices.length() == 2, 5);
    assert!(*ask_prices.borrow(0) == 3 * constants::float_scaling(), 6);
    assert!(*ask_prices.borrow(1) == 4 * constants::float_scaling(), 7);
    assert!(*ask_quantities.borrow(0) == 300, 8);
    assert!(*ask_quantities.borrow(1) == 400, 9);

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === Account Open Orders Tests ===

#[test]
fun test_multicoin_pool_account_open_orders_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // ALICE places multiple orders
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order1 = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        10,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    let order2 = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        20,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Query open orders
    let open_orders = pool.account_open_orders(&alice_bm);
    assert!(open_orders.length() == 2, 0);
    assert!(open_orders.contains(&order1.order_id()), 1);
    assert!(open_orders.contains(&order2.order_id()), 2);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === Withdraw Settled Amounts Tests ===

#[test]
fun test_multicoin_pool_withdraw_settled_amounts_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Setup Bob with MultiCoin for ask
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

    // ALICE places bid
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // BOB places matching ask
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // Alice withdraws settled amounts (the MultiCoin she received)
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.withdraw_settled_amounts(&mut alice_bm, &alice_proof, test.ctx());

    return_shared(pool);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === High Priority: Expired Order Removal ===

#[test, expected_failure(abort_code = ::triexbook::book::EBookOrderNotFound)]
fun test_multicoin_pool_expired_order_removed_bid_e() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Setup Bob with MultiCoin for ask
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

    // ALICE places bid with short expiration
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let mut clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let current_time = clock.timestamp_ms();
    let expire_timestamp = current_time + 100; // Expires in 100ms

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        expire_timestamp,
        &clock,
        test.ctx(),
    );
    assert!(order_info.status() == constants::live(), 0);
    let alice_order_id = order_info.order_id();

    // Advance time past expiration
    clock.increment_for_testing(200);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // BOB places ask that would match - but Alice's order is expired
    // The expired order should be removed during matching, Bob's order goes on book
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    // Bob places ask at price 1 (would cross with Alice's bid at 2, but it's expired)
    let bob_order = pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Bob's order should be live (no match because Alice's order expired)
    assert!(bob_order.status() == constants::live(), 1);

    // Alice's expired order should no longer exist on book
    let _alice_order = pool.get_order(alice_order_id);

    abort 0
}

#[test, expected_failure(abort_code = ::triexbook::book::EBookOrderNotFound)]
fun test_multicoin_pool_expired_order_removed_ask_e() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let bob_bm_id = create_balance_manager_with_funds(
        BOB,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Setup Alice with MultiCoin for ask
    test.next_tx(ALICE);
    let mut alice_bm = balance_manager::new(test.ctx());
    alice_bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    alice_bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let alice_trade_cap = alice_bm.mint_trade_cap(test.ctx());
    let alice_bm_id = object::id(&alice_bm);
    transfer::public_share_object(alice_bm);
    transfer::public_transfer(alice_trade_cap, ALICE);

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
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    alice_bm.deposit_multicoin(gold, test.ctx());
    return_shared(alice_bm);

    // ALICE places ask with short expiration
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let mut clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let current_time = clock.timestamp_ms();
    let expire_timestamp = current_time + 100;

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        false,
        expire_timestamp,
        &clock,
        test.ctx(),
    );
    assert!(order_info.status() == constants::live(), 0);
    let alice_order_id = order_info.order_id();

    // Advance time past expiration
    clock.increment_for_testing(200);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // BOB places bid that would match - but Alice's ask is expired
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    // Bob places bid at price 3 (would cross with Alice's ask at 2, but it's expired)
    let bob_order = pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Bob's order should be live (no match because Alice's order expired)
    assert!(bob_order.status() == constants::live(), 1);

    // Alice's expired order should no longer exist on book
    let _alice_order = pool.get_order(alice_order_id);

    abort 0
}

// === High Priority: Queue/FIFO Priority ===

#[test]
fun test_multicoin_pool_fifo_priority_bid_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
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

    // Setup Charlie with MultiCoin for ask
    test.next_tx(CHARLIE);
    let mut charlie_bm = balance_manager::new(test.ctx());
    charlie_bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    charlie_bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let charlie_trade_cap = charlie_bm.mint_trade_cap(test.ctx());
    let charlie_bm_id = object::id(&charlie_bm);
    transfer::public_share_object(charlie_bm);
    transfer::public_transfer(charlie_trade_cap, CHARLIE);

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
    transfer::public_transfer(gold, CHARLIE);

    test.next_tx(CHARLIE);
    let mut charlie_bm = test.take_shared_by_id<BalanceManager>(charlie_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    charlie_bm.deposit_multicoin(gold, test.ctx());
    return_shared(charlie_bm);

    // ALICE places bid first at price 2
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let alice_order = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // BOB places bid second at SAME price 2
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    let bob_order = pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    let bob_order_id = bob_order.order_id();

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // CHARLIE places ask for 100 units - should match with ALICE first (FIFO)
    test.next_tx(CHARLIE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut charlie_bm = test.take_shared_by_id<BalanceManager>(charlie_bm_id);
    let charlie_trade_cap = test.take_from_sender<TradeCap>();
    let charlie_proof = charlie_bm.generate_proof_as_trader(&charlie_trade_cap, test.ctx());

    let charlie_order = pool.place_limit_order(
        &mut charlie_bm,
        &charlie_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Charlie's order should be fully filled (matched with Alice's order, which was first due to FIFO)
    assert!(charlie_order.status() == constants::filled(), 0);
    assert!(charlie_order.executed_quantity() == 100, 1);

    // Bob's order should still be on the book (unfilled) - Alice's was matched first
    let bob_order_after = pool.get_order(bob_order_id);
    assert!(bob_order_after.filled_quantity() == 0, 2);

    return_shared(pool);
    return_shared(clock);
    return_shared(charlie_bm);
    test.return_to_sender(charlie_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_multicoin_pool_fifo_priority_ask_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let charlie_bm_id = create_balance_manager_with_funds(
        CHARLIE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Setup Alice with MultiCoin for ask
    test.next_tx(ALICE);
    let mut alice_bm = balance_manager::new(test.ctx());
    alice_bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    alice_bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let alice_trade_cap = alice_bm.mint_trade_cap(test.ctx());
    let alice_bm_id = object::id(&alice_bm);
    transfer::public_share_object(alice_bm);
    transfer::public_transfer(alice_trade_cap, ALICE);

    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let gold1 = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        1_000_000 * constants::float_scaling(),
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(gold1, ALICE);

    test.next_tx(ALICE);
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    alice_bm.deposit_multicoin(gold, test.ctx());
    return_shared(alice_bm);

    // Setup Bob with MultiCoin for ask
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

    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let gold2 = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        1_000_000 * constants::float_scaling(),
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(gold2, BOB);

    test.next_tx(BOB);
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    bob_bm.deposit_multicoin(gold, test.ctx());
    return_shared(bob_bm);

    // ALICE places ask first at price 2
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let alice_order = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // BOB places ask second at SAME price 2
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    let bob_order = pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    let bob_order_id = bob_order.order_id();

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // CHARLIE places bid for 100 units - should match with ALICE first (FIFO)
    test.next_tx(CHARLIE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut charlie_bm = test.take_shared_by_id<BalanceManager>(charlie_bm_id);
    let charlie_trade_cap = test.take_from_sender<TradeCap>();
    let charlie_proof = charlie_bm.generate_proof_as_trader(&charlie_trade_cap, test.ctx());

    let charlie_order = pool.place_limit_order(
        &mut charlie_bm,
        &charlie_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Charlie's order should be fully filled (matched with Alice's order, which was first due to FIFO)
    assert!(charlie_order.status() == constants::filled(), 0);
    assert!(charlie_order.executed_quantity() == 100, 1);

    // Bob's order should still be on the book (unfilled) - Alice's was matched first
    let bob_order_after = pool.get_order(bob_order_id);
    assert!(bob_order_after.filled_quantity() == 0, 2);

    return_shared(pool);
    return_shared(clock);
    return_shared(charlie_bm);
    test.return_to_sender(charlie_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === High Priority: Crossing Multiple Orders ===

#[test]
fun test_multicoin_pool_crossing_multiple_orders_bid_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Setup Bob with MultiCoin for asks
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

    // BOB places 3 asks at price 2 (100 units each)
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // ALICE places bid for 300 units - should cross all 3 orders
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        300,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Should be fully filled
    assert!(order_info.status() == constants::filled(), 0);
    assert!(order_info.executed_quantity() == 300, 1);
    // 300 base * 2 price = 600 quote
    assert!(order_info.cumulative_quote_quantity() == 600 * constants::float_scaling(), 2);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_multicoin_pool_crossing_multiple_orders_ask_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
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

    // Setup Charlie with MultiCoin for ask
    test.next_tx(CHARLIE);
    let mut charlie_bm = balance_manager::new(test.ctx());
    charlie_bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    charlie_bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let charlie_trade_cap = charlie_bm.mint_trade_cap(test.ctx());
    let charlie_bm_id = object::id(&charlie_bm);
    transfer::public_share_object(charlie_bm);
    transfer::public_transfer(charlie_trade_cap, CHARLIE);

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
    transfer::public_transfer(gold, CHARLIE);

    test.next_tx(CHARLIE);
    let mut charlie_bm = test.take_shared_by_id<BalanceManager>(charlie_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    charlie_bm.deposit_multicoin(gold, test.ctx());
    return_shared(charlie_bm);

    // ALICE places 3 bids at price 2 (100 units each)
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // CHARLIE places ask for 300 units - should cross all 3 bids
    test.next_tx(CHARLIE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut charlie_bm = test.take_shared_by_id<BalanceManager>(charlie_bm_id);
    let charlie_trade_cap = test.take_from_sender<TradeCap>();
    let charlie_proof = charlie_bm.generate_proof_as_trader(&charlie_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut charlie_bm,
        &charlie_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        300,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Should be fully filled
    assert!(order_info.status() == constants::filled(), 0);
    assert!(order_info.executed_quantity() == 300, 1);
    // 300 base * 2 price = 600 quote
    assert!(order_info.cumulative_quote_quantity() == 600 * constants::float_scaling(), 2);

    return_shared(pool);
    return_shared(clock);
    return_shared(charlie_bm);
    test.return_to_sender(charlie_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === High Priority: Price Validation ===

#[test, expected_failure(abort_code = ::triexbook::order_info::EOrderInvalidPrice)]
fun test_multicoin_pool_price_above_max_e() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Try to place order with max_u64 price (invalid)
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::max_u64(),
        100 * constants::float_scaling(),
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    abort 0
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EOrderInvalidPrice)]
fun test_multicoin_pool_price_below_min_e() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Try to place order with 0 price (invalid)
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        0,
        100 * constants::float_scaling(),
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    abort 0
}

#[test]
fun test_multicoin_pool_price_at_max_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    // Setup Alice with MultiCoin for ask at max price
    test.next_tx(ALICE);
    let mut alice_bm = balance_manager::new(test.ctx());
    alice_bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    alice_bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let alice_trade_cap = alice_bm.mint_trade_cap(test.ctx());
    let alice_bm_id = object::id(&alice_bm);
    transfer::public_share_object(alice_bm);
    transfer::public_transfer(alice_trade_cap, ALICE);

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
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    alice_bm.deposit_multicoin(gold, test.ctx());
    return_shared(alice_bm);

    // Place ask order at max valid price (asks only need base, not quote * price)
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::max_price(),
        1 * constants::float_scaling(),
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    assert!(order_info.status() == constants::live(), 0);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_multicoin_pool_price_at_min_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    // Setup Alice with MultiCoin for ask at min price
    test.next_tx(ALICE);
    let mut alice_bm = balance_manager::new(test.ctx());
    alice_bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    alice_bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let alice_trade_cap = alice_bm.mint_trade_cap(test.ctx());
    let alice_bm_id = object::id(&alice_bm);
    transfer::public_share_object(alice_bm);
    transfer::public_transfer(alice_trade_cap, ALICE);

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
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    alice_bm.deposit_multicoin(gold, test.ctx());
    return_shared(alice_bm);

    // Place ask at min valid price
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::min_price(),
        1 * constants::float_scaling(),
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    assert!(order_info.status() == constants::live(), 0);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === Medium Priority: Get Order/Orders Query ===

#[test]
fun test_multicoin_pool_get_order_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Place order
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    let order_id = order_info.order_id();

    // Query order and verify all fields
    let order = pool.get_order(order_id);
    assert!(order.order_id() == order_id, 0);
    assert!(order.balance_manager_id() == alice_bm_id, 2);
    assert!(order.quantity() == 100, 3);
    assert!(order.filled_quantity() == 0, 4);
    assert!(order.status() == constants::live(), 5);
    assert!(order.expire_timestamp() == constants::max_u64(), 6);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_multicoin_admin_withdraws_quote_fee_reserve() {
    let mut test = begin(OWNER);

    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
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
        transfer::public_transfer(gold, ALICE);
    };

    test.next_tx(ALICE);
    {
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold_balance = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold_balance, test.ctx());
        return_shared(alice_bm);
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
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
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
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
        let expected_fee = order_info.paid_fees() + order_info.maker_fees();
        assert!(expected_fee > 0, 0);
        assert!(reserve_after - reserve_before == expected_fee, 1);

        return_shared(bob_bm);
        return_shared(clock);
        return_shared(pool);
    };

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let reserve_before = pool.quote_fee_reserve_balance();
        assert!(reserve_before > 0, 2);
        let fee_coin = pool.withdraw_pool_fees(
            &admin_cap,
            reserve_before,
            &clock,
            test.ctx(),
        );
        assert!(fee_coin.value() == reserve_before, 3);
        assert!(pool.quote_fee_reserve_balance() == 0, 4);

        unit_test::destroy(fee_coin);
        return_shared(clock);
        return_shared(pool);
        unit_test::destroy(admin_cap);
    };

    unit_test::destroy(collection_cap);
    end(test);
}

#[test]
fun test_multicoin_pool_get_orders_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Place multiple orders
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info_1 = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    let order_info_2 = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3 * constants::float_scaling(),
        200,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    let order_info_3 = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        4 * constants::float_scaling(),
        300,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Query multiple orders
    let mut order_ids = vector[];
    order_ids.push_back(order_info_1.order_id());
    order_ids.push_back(order_info_2.order_id());
    order_ids.push_back(order_info_3.order_id());

    let orders = pool.get_orders(order_ids);
    assert!(orders.length() == 3, 0);

    // Verify each order
    assert!(orders[0].order_id() == order_info_1.order_id(), 1);
    assert!(orders[0].quantity() == 100, 2);
    assert!(orders[1].order_id() == order_info_2.order_id(), 3);
    assert!(orders[1].quantity() == 200, 4);
    assert!(orders[2].order_id() == order_info_3.order_id(), 5);
    assert!(orders[2].quantity() == 300, 6);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test, expected_failure(abort_code = ::triexbook::book::EBookOrderNotFound)]
fun test_multicoin_pool_get_order_not_found_e() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    // Try to query non-existent order
    test.next_tx(OWNER);
    let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);

    let _order = pool.get_order(999999);

    abort 0
}

// === Medium Priority: Modify Order After Partial Fill ===

#[test]
fun test_multicoin_pool_modify_order_after_partial_fill_bid_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Setup Bob with MultiCoin for ask
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

    // Alice places bid for 200 units
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        200,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    let alice_order_id = order_info.order_id();

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // Bob partially fills Alice's order (50 units)
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        50,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // Verify Alice's order is partially filled (200 - 50 = 150 remaining)
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_before = pool.get_order(alice_order_id);
    assert!(order_before.filled_quantity() == 50, 0);

    // Modify to reduce to 100 (still above filled 50)
    pool.modify_order(
        &mut alice_bm,
        &alice_proof,
        alice_order_id,
        100,
        &clock,
        test.ctx(),
    );

    // Verify modified quantity
    let order_after = pool.get_order(alice_order_id);
    assert!(order_after.quantity() == 100, 1);
    assert!(order_after.filled_quantity() == 50, 2);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test, expected_failure(abort_code = ::triexbook::order::EInvalidNewQuantity)]
fun test_multicoin_pool_modify_order_after_partial_fill_below_filled_e() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Setup Bob with MultiCoin for ask
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

    // Alice places bid for 200 units
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        200,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    let alice_order_id = order_info.order_id();

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // Bob partially fills Alice's order (100 units)
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // Try to modify to 50 (below filled 100) - should fail
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.modify_order(
        &mut alice_bm,
        &alice_proof,
        alice_order_id,
        50,
        &clock,
        test.ctx(),
    );

    abort 0
}

// === Medium Priority: Order Limit Per Price Level ===

#[test]
fun test_multicoin_pool_multiple_orders_same_price_bid_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
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

    // Alice places 10 orders at same price
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let mut i = 0;
    while (i < 10) {
        pool.place_limit_order(
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            10,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        i = i + 1;
    };

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // Bob places 10 more orders at same price
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    let mut j = 0;
    while (j < 10) {
        pool.place_limit_order(
            &mut bob_bm,
            &bob_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            10,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        j = j + 1;
    };

    // Verify Bob has open orders
    let bob_open = pool.account_open_orders(&bob_bm);
    assert!(bob_open.length() == 10, 0);

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // Verify Alice has open orders in separate tx
    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);

    let alice_open = pool.account_open_orders(&alice_bm);
    assert!(alice_open.length() == 10, 1);

    return_shared(pool);
    return_shared(alice_bm);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_multicoin_pool_multiple_orders_same_price_ask_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    // Setup Alice with MultiCoin for asks
    test.next_tx(ALICE);
    let mut alice_bm = balance_manager::new(test.ctx());
    alice_bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    alice_bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let alice_trade_cap = alice_bm.mint_trade_cap(test.ctx());
    let alice_bm_id = object::id(&alice_bm);
    transfer::public_share_object(alice_bm);
    transfer::public_transfer(alice_trade_cap, ALICE);

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
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    alice_bm.deposit_multicoin(gold, test.ctx());
    return_shared(alice_bm);

    // Alice places 10 ask orders at same price
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let mut i = 0;
    while (i < 10) {
        pool.place_limit_order(
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            10,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        i = i + 1;
    };

    // Verify all orders are open
    let alice_open = pool.account_open_orders(&alice_bm);
    assert!(alice_open.length() == 10, 0);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === Medium Priority: Invalid Operations ===

#[test, expected_failure(abort_code = ::triexbook::book::EBookOrderNotFound)]
fun test_multicoin_pool_cancel_already_canceled_e() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Place order
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    let order_id = order_info.order_id();

    // Cancel once - should succeed
    pool.cancel_order(&mut alice_bm, &alice_proof, order_id, &clock, test.ctx());

    // Cancel again - should fail
    pool.cancel_order(&mut alice_bm, &alice_proof, order_id, &clock, test.ctx());

    abort 0
}

#[test, expected_failure(abort_code = ::triexbook::book::EBookOrderNotFound)]
fun test_multicoin_pool_cancel_nonexistent_order_e() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Try to cancel non-existent order
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.cancel_order(&mut alice_bm, &alice_proof, 999999, &clock, test.ctx());

    abort 0
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EInvalidOrderType)]
fun test_multicoin_pool_invalid_order_type_e() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Try to place order with invalid order type (> max_restriction)
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::max_restriction() + 1,
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    abort 0
}

#[test, expected_failure(abort_code = ::triexbook::book::EBookOrderNotFound)]
fun test_multicoin_pool_modify_nonexistent_order_e() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Try to modify non-existent order
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    pool.modify_order(
        &mut alice_bm,
        &alice_proof,
        999999,
        50,
        &clock,
        test.ctx(),
    );

    abort 0
}

// === Cancel Batch Orders Tests ===

#[test]
fun test_multicoin_pool_cancel_orders_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);
    let pool_id = setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    // Create balance manager with funds for ALICE
    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Mint and deposit MultiCoin for ALICE
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
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    alice_bm.deposit_multicoin(gold, test.ctx());
    return_shared(alice_bm);

    // Place 3 orders
    let mut order_ids: vector<u64> = vector[];

    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order1 = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    order_ids.push_back(order1.order_id());

    let order2 = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    order_ids.push_back(order2.order_id());

    let order3 = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3 * constants::float_scaling(),
        100,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    order_ids.push_back(order3.order_id());

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // Verify we have 3 open orders
    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let open_orders = pool.account_open_orders(&alice_bm);
    assert!(open_orders.length() == 3, 0);
    return_shared(pool);
    return_shared(alice_bm);

    // Cancel orders using batch cancel
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    // Top up quote to cover quote-denominated maker fees before cancel
    alice_bm.deposit(
        mint_for_testing<USDC>(10_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );

    pool.cancel_orders(&mut alice_bm, &alice_proof, order_ids, &clock, test.ctx());

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // Verify all orders are cancelled
    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let open_orders = pool.account_open_orders(&alice_bm);
    assert!(open_orders.length() == 0, 1);
    return_shared(pool);
    return_shared(alice_bm);

    unit_test::destroy(collection_cap);
    end(test);
}
