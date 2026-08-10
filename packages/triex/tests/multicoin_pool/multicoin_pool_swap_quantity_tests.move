// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_multicoin_pool_swap_quantity_tests;

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

// === Swap Functions Tests ===

#[test]
fun test_multicoin_pool_swap_exact_base_for_quote_ok() {
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

    // BOB provides liquidity - places bid at price 2 (buying base with quote)
    let bob_bm_id = create_balance_manager_with_funds(
        BOB,
        10_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(BOB);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let bob_trade_cap = test.take_from_sender<TradeCap>();
    let bob_proof = bob_bm.generate_proof_as_trader(&bob_trade_cap, test.ctx());

    // BOB places bid order - willing to buy 1000 base at price 2
    pool.place_limit_order(
        &mut bob_bm,
        &bob_proof,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        1000,
        true,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // ALICE mints MultiCoin to swap
    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let gold = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        100,
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(gold, ALICE);

    // ALICE swaps base for quote
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let base_in = test.take_from_sender<multicoin::Balance>();
    let cred_in = mint_for_testing<CRED>(0, test.ctx()); // No cred (fee paid from output)

    let (base_out, quote_out, cred_out) = pool.swap_exact_base_for_quote(
        base_in,
        cred_in,
        0, // min_quote_out
        &clock,
        test.ctx(),
    );

    // Selling 100 base at price 2 = 200 quote (minus fees)
    assert!(base_out.value() == 0, 0); // All base should be consumed
    assert!(quote_out.value() > 0, 1); // Should receive quote

    transfer::public_transfer(base_out, ALICE);
    transfer::public_transfer(quote_out, ALICE);
    transfer::public_transfer(cred_out, ALICE);

    return_shared(pool);
    return_shared(clock);
    unit_test::destroy(collection_cap);
    end(test);
}

#[test]
fun test_multicoin_pool_swap_exact_quote_for_base_ok() {
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

    // BOB provides liquidity - places ask at price 2 (selling base for quote)
    let bob_bm_id = create_balance_manager_with_funds(
        BOB,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Mint and deposit MultiCoin for BOB
    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let gold = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        10_000 * constants::float_scaling(),
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(gold, BOB);

    test.next_tx(BOB);
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    bob_bm.deposit_multicoin(gold, test.ctx());
    return_shared(bob_bm);

    // BOB places ask order - selling 1000 base at price 2
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
        2000000,
        100 * constants::sui_unit(),
        false,
        constants::max_u64(),
        &clock,
        test.ctx(), // is_bid=false (ask)
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // ALICE swaps quote for base
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let quote_in = mint_for_testing<USDC>(1000 * constants::usdc_unit(), test.ctx());
    let cred_in = mint_for_testing<CRED>(10_000 * constants::float_scaling(), test.ctx()); // CRED for fees

    let (base_out, quote_out, cred_out) = pool.swap_exact_quote_for_base(
        quote_in,
        cred_in,
        0, // min_base_out
        &clock,
        test.ctx(),
    );

    // Should receive some base
    assert!(base_out.value() > 0, 0); // Should receive base

    transfer::public_transfer(base_out, ALICE);
    transfer::public_transfer(quote_out, ALICE);
    transfer::public_transfer(cred_out, ALICE);

    return_shared(pool);
    return_shared(clock);
    unit_test::destroy(collection_cap);
    end(test);
}

#[test, expected_failure(abort_code = ::triexbook::multicoin_pool::EMinimumQuantityOutNotMet)]
fun test_multicoin_pool_swap_exact_quote_for_base_min_not_met_e() {
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

    // BOB provides liquidity - places ask at price 2
    let bob_bm_id = create_balance_manager_with_funds(
        BOB,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Mint and deposit MultiCoin for BOB
    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let gold = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        10_000 * constants::float_scaling(),
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(gold, BOB);

    test.next_tx(BOB);
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    bob_bm.deposit_multicoin(gold, test.ctx());
    return_shared(bob_bm);

    // BOB places ask order - selling 100 base at price 2
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
        2000000,
        100 * constants::sui_unit(),
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // ALICE swaps quote for base but requires too much base output
    test.next_tx(ALICE);
    let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();
    let quote_in = mint_for_testing<USDC>(1000 * constants::usdc_unit(), test.ctx());
    let cred_in = mint_for_testing<CRED>(10_000 * constants::float_scaling(), test.ctx());

    // Expecting way more base than possible - should fail
    let (base_out, quote_out, cred_out) = pool.swap_exact_quote_for_base(
        quote_in,
        cred_in,
        200 * constants::sui_unit(), // min_base_out - too high!
        &clock,
        test.ctx(),
    );

    transfer::public_transfer(base_out, ALICE);
    transfer::public_transfer(quote_out, ALICE);
    transfer::public_transfer(cred_out, ALICE);

    abort 0
}

// === Get Quantity Out Tests ===

#[test]
fun test_multicoin_pool_get_quantity_out_ok() {
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

    // BOB provides liquidity
    let bob_bm_id = create_balance_manager_with_funds(
        BOB,
        10_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Mint and deposit MultiCoin for BOB
    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let gold = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        10_000 * constants::float_scaling(),
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(gold, BOB);

    test.next_tx(BOB);
    let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    bob_bm.deposit_multicoin(gold, test.ctx());
    return_shared(bob_bm);

    // BOB places ask at price 2
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
        1000,
        false,
        constants::max_u64(),
        &clock,
        test.ctx(),
    );

    return_shared(pool);
    return_shared(clock);
    return_shared(bob_bm);
    test.return_to_sender(bob_trade_cap);

    // Query get_quantity_out
    test.next_tx(ALICE);
    let pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
    let clock = test.take_shared<Clock>();

    // Query: if I put in 200 quote, how much base do I get?
    let (base_out, quote_remaining) = pool.get_quantity_out(
        0, // base_quantity (0 since we're buying with quote)
        200 * constants::float_scaling(), // quote_quantity
        &clock,
    );

    // At price 2, 200 quote buys 100 base
    assert!(base_out > 0, 0);

    return_shared(pool);
    return_shared(clock);
    unit_test::destroy(collection_cap);
    end(test);
}
