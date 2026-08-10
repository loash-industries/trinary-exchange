// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_multicoin_pool_order_types_tests;

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

// === High Priority: Ask Order Placement ===

#[test]
fun test_multicoin_pool_place_ask_order_ok() {
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

    // Create balance manager and share immediately
    test.next_tx(ALICE);
    let mut bm = balance_manager::new(test.ctx());
    bm.deposit(
        mint_for_testing<USDC>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    bm.deposit(
        mint_for_testing<CRED>(1_000_000 * constants::float_scaling(), test.ctx()),
        test.ctx(),
    );
    let trade_cap = bm.mint_trade_cap(test.ctx());
    let bm_id = object::id(&bm);
    transfer::public_share_object(bm);
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
    let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    bm.deposit_multicoin(gold, test.ctx());
    return_shared(bm);

    // Place an ask order (selling MultiCoin for USDC)
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bm = test.take_shared_by_id<BalanceManager>(bm_id);
    let trade_cap = test.take_from_sender<TradeCap>();
    let trade_proof = bm.generate_proof_as_trader(&trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut bm,
        &trade_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(), // price
        100, // quantity
        false, // is_bid = false (ask order)
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    assert!(order_info.status() == constants::live(), 0);
    assert!(order_info.is_bid() == false, 1);

    return_shared(pool);
    return_shared(clock);
    return_shared(bm);
    test.return_to_sender(trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === High Priority: Market Orders ===

#[test]
fun test_multicoin_pool_market_order_bid_ok() {
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

    // Create ALICE balance manager (will place market bid)
    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Create BOB balance manager with MultiCoin (will place limit ask)
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

    // Mint and deposit MultiCoin for Bob
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

    // BOB places a limit ask at price 2
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
    assert!(bob_order.status() == constants::live(), 0);

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // ALICE places a market bid (should match Bob's ask)
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let alice_order = pool.place_market_order(
        &mut alice_bm,
        &alice_proof,
        constants::self_matching_allowed(),
        50, // quantity
        true, // is_bid
        &clock,
        test.ctx(),
    );

    // Market order should be filled
    assert!(alice_order.status() == constants::filled(), 1);
    assert!(alice_order.executed_quantity() == 50, 2);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_multicoin_pool_market_order_ask_ok() {
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

    // Create ALICE balance manager (will place limit bid)
    let alice_bm_id = create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Create BOB balance manager with MultiCoin (will place market ask)
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

    // Mint and deposit MultiCoin for Bob
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

    // ALICE places a limit bid at price 2
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
    assert!(alice_order.status() == constants::live(), 0);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // BOB places a market ask (should match Alice's bid)
    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    let bob_order = pool.place_market_order(
        &mut bob_bm,
        &bob_proof,
        constants::self_matching_allowed(),
        50, // quantity
        false, // is_bid (ask)
        &clock,
        test.ctx(),
    );

    // Market order should be filled
    assert!(bob_order.status() == constants::filled(), 1);
    assert!(bob_order.executed_quantity() == 50, 2);

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === High Priority: IOC (Immediate or Cancel) Orders ===

#[test]
fun test_multicoin_pool_ioc_order_filled_ok() {
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

    // Create balance managers
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

    // BOB places limit ask
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

    // ALICE places IOC bid that should fill
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::immediate_or_cancel(), // IOC
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        50,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // IOC order should be filled (not live)
    assert!(order_info.status() == constants::filled(), 0);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_multicoin_pool_ioc_order_no_match_canceled_ok() {
    let mut test = begin(OWNER);

    // Setup (no liquidity on the book)
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

    // ALICE places IOC bid with no matching asks
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::immediate_or_cancel(), // IOC
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        50,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // IOC order with no match should be canceled
    assert!(order_info.status() == constants::canceled(), 0);
    assert!(order_info.executed_quantity() == 0, 1);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === High Priority: FOK (Fill or Kill) Orders ===

#[test]
fun test_multicoin_pool_fok_order_filled_ok() {
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

    // BOB places limit ask with enough quantity
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

    // ALICE places FOK bid that CAN be fully filled
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::fill_or_kill(), // FOK
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        50,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // FOK order should be fully filled
    assert!(order_info.status() == constants::filled(), 0);
    assert!(order_info.executed_quantity() == 50, 1);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EFOKOrderCannotBeFullyFilled)]
fun test_multicoin_pool_fok_order_insufficient_liquidity_e() {
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

    // BOB with MultiCoin - only 50 units
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

    // BOB places limit ask with only 50 units
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
        50, // Only 50 available
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // ALICE places FOK bid for 100 units - should fail
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    // This should fail - FOK needs 100 but only 50 available
    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::fill_or_kill(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100, // Wants 100
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    abort 0
}

// === High Priority: Post-Only Orders ===

#[test]
fun test_multicoin_pool_post_only_order_ok() {
    let mut test = begin(OWNER);

    // Setup (empty book)
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

    // ALICE places post-only bid on empty book (should succeed)
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let order_info = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::post_only(), // Post-only
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        50,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Post-only should be live on the book
    assert!(order_info.status() == constants::live(), 0);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EPOSTOrderCrossesOrderbook)]
fun test_multicoin_pool_post_only_crosses_e() {
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

    // BOB places limit ask at price 2
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

    // ALICE places post-only bid at price 2 (would cross) - should fail
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    // This should fail - post-only would cross the book
    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::post_only(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        50,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    abort 0
}

// === High Priority: Partial Fill Scenarios ===

#[test]
fun test_multicoin_pool_partial_fill_taker_ok() {
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

    // BOB places limit ask with 50 units
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
        50, // Only 50
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // ALICE places bid for 100 units - should partially fill (50) and rest goes on book
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
        100, // Wants 100
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Order should be partially filled and rest on book
    assert!(order_info.status() == constants::partially_filled(), 0); // Partially filled status
    assert!(order_info.executed_quantity() == 50, 1);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_multicoin_pool_partial_fill_maker_ok() {
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

    // ALICE places large bid (maker) for 100 units
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
        100, // 100 on book
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );
    assert!(alice_order.status() == constants::live(), 0);

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // BOB places small ask (taker) for 30 units - partially fills Alice's order
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
        30, // Only 30
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Bob's order should be fully filled
    assert!(bob_order.status() == constants::filled(), 1);

    // Alice's order should still be on the book with 70 remaining
    // quantity() = original quantity, filled_quantity() = amount filled
    let alice_order_on_book = pool.get_order(alice_order.order_id());
    assert!(alice_order_on_book.quantity() == 100, 2);
    assert!(alice_order_on_book.filled_quantity() == 30, 3);
    assert!(alice_order_on_book.status() == constants::partially_filled(), 4);

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);
    unit_test::destroy(collection_cap);

    end(test);
}

// === High Priority: Self-Matching ===

#[test, expected_failure(abort_code = ::triexbook::order_info::ESelfMatchingCancelTaker)]
fun test_multicoin_pool_self_matching_cancel_taker_e() {
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

    // ALICE places ask at price 2
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
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // ALICE tries to place bid at price 2 (would self-match) with cancel_taker option
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    // Should fail with ESelfMatchingCancelTaker
    pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::cancel_taker(), // Cancel taker on self-match
        2 * constants::float_scaling(),
        50,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    abort 0
}

// === Self-Matching Cancel Maker Tests ===

#[test, expected_failure(abort_code = ::triexbook::book::EBookOrderNotFound)]
fun test_multicoin_pool_self_matching_cancel_maker_bid_e() {
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

    // ALICE places bid at price 2
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
    let maker_order_id = order_info.order_id();

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // ALICE places ask at price 1 (crosses with bid) with cancel_maker
    // This should cancel the maker bid and place the ask
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let ask_order = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::cancel_maker(), // Cancel maker on self-match
        1 * constants::float_scaling(),
        50,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Ask should be placed successfully (on book)
    assert!(ask_order.status() == constants::live(), 1);

    // Try to get the original bid order - should fail because it was canceled
    let _maker_order = pool.get_order(maker_order_id);

    abort 0
}

#[test, expected_failure(abort_code = ::triexbook::book::EBookOrderNotFound)]
fun test_multicoin_pool_self_matching_cancel_maker_ask_e() {
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

    // ALICE places ask at price 2
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
    let maker_order_id = order_info.order_id();

    return_shared(pool);
    return_shared(clock);
    return_shared(alice_bm);
    test.return_to_sender(alice_trade_cap);

    // ALICE places bid at price 3 (crosses with ask) with cancel_maker
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
    let alice_trade_cap = test.take_from_sender<TradeCap>();
    let alice_proof = alice_bm.generate_proof_as_trader(&alice_trade_cap, test.ctx());

    let bid_order = pool.place_limit_order(
        &mut alice_bm,
        &alice_proof,
        constants::no_restriction(),
        constants::cancel_maker(), // Cancel maker on self-match
        3 * constants::float_scaling(),
        50,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    // Bid should be placed successfully
    assert!(bid_order.status() == constants::live(), 1);

    // Try to get the original ask order - should fail because it was canceled
    let _maker_order = pool.get_order(maker_order_id);

    abort 0
}
