// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Shared helpers for MultiCoin pool integration tests.
#[test_only]
module triexbook::integration_multicoin_test_utils;

use multicoin::multicoin::{Self, Collection, CollectionCap};
use std::unit_test;
use sui::{clock::{Self, Clock}, coin::mint_for_testing, test_scenario::{Scenario, return_shared}};
use token::cred::CRED;
use triexbook::{
    balance_manager::{Self as balance_manager, BalanceManager, TradeCap},
    constants,
    multicoin_pool as multicoin_pool,
    pool::{Self as pool, Pool},
    registry::{Self as registry, Registry}
};

// Test addresses
const OWNER: address = @0x1;

public fun owner(): address { OWNER }

// Test asset IDs
const ASSET_GOLD: u64 = 1;
const ASSET_SILVER: u64 = 2;
const ASSET_IRON: u64 = 3;

public fun asset_gold(): u64 { ASSET_GOLD }

public fun asset_silver(): u64 { ASSET_SILVER }

public fun asset_iron(): u64 { ASSET_IRON }

// Quote currency for testing
public struct USDC has store {}

public fun get_time(test: &mut Scenario): u64 {
    test.next_tx(OWNER);
    {
        let clock = test.take_shared<Clock>();
        let time = clock.timestamp_ms();
        return_shared(clock);
        time
    }
}

public fun set_time(current_time: u64, test: &mut Scenario) {
    test.next_tx(OWNER);
    let mut clock = test.take_shared<Clock>();
    clock.set_for_testing(1_000_000 + current_time);
    return_shared(clock);
}

public fun share_clock(test: &mut Scenario) {
    test.next_tx(OWNER);
    clock::create_for_testing(test.ctx()).share_for_testing();
}

public fun share_registry_for_testing(test: &mut Scenario): ID {
    test.next_tx(OWNER);
    registry::test_registry(test.ctx())
}

public fun add_approved_quote_currencies(owner: address, registry_id: ID, test: &mut Scenario) {
    test.next_tx(owner);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    registry.add_approved_quote_unchecked<USDC>(&admin_cap);
    registry.add_approved_quote_unchecked<CRED>(&admin_cap);
    return_shared(registry);
    unit_test::destroy(admin_cap);
}

/// Initialize registry with MultiCoin collection.
public fun setup_registry_with_multicoin(test: &mut Scenario): (ID, ID, CollectionCap) {
    test.next_tx(OWNER);
    share_clock(test);
    let registry_id = share_registry_for_testing(test);
    add_approved_quote_currencies(OWNER, registry_id, test);

    test.next_tx(OWNER);
    let (collection, collection_cap) = multicoin::new_collection(test.ctx());
    let collection_id = object::id(&collection);
    sui::transfer::public_share_object(collection);

    (registry_id, collection_id, collection_cap)
}

/// Create a BalanceManager with USDC and CRED funds.
public fun create_balance_manager_with_funds(
    sender: address,
    usdc_amount: u64,
    cred_amount: u64,
    test: &mut Scenario,
): ID {
    test.next_tx(sender);
    let mut balance_manager = balance_manager::new(test.ctx());
    balance_manager.deposit(mint_for_testing<USDC>(usdc_amount, test.ctx()), test.ctx());
    balance_manager.deposit(mint_for_testing<CRED>(cred_amount, test.ctx()), test.ctx());
    let trade_cap = balance_manager.mint_trade_cap(test.ctx());
    transfer::public_transfer(trade_cap, sender);
    let id = object::id(&balance_manager);
    transfer::public_share_object(balance_manager);
    id
}

/// Create a MultiCoin pool for testing.
public fun setup_multicoin_pool(
    sender: address,
    registry_id: ID,
    collection_id: ID,
    asset_id: u64,
    whitelisted_pool: bool,
    stable_pool: bool,
    test: &mut Scenario,
): ID {
    test.next_tx(sender);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let collection = test.take_shared<Collection>();

    let pool_id = multicoin_pool::create_pool_admin<USDC>(
        &mut registry,
        &collection,
        asset_id,
        whitelisted_pool,
        stable_pool,
        &admin_cap,
        test.ctx(),
    );

    return_shared(registry);
    return_shared(collection);
    unit_test::destroy(admin_cap);
    pool_id
}

/// Set up a CRED/USDC reference pool for CRED pricing.
/// Creates a whitelisted Pool<CRED, USDC> with bid/ask orders to establish mid price.
public fun setup_cred_usdc_reference_pool(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    test: &mut Scenario,
): ID {
    test.next_tx(sender);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);

    let reference_pool_id = pool::create_pool_admin<USDC, CRED>(
        &mut registry,
        true,
        false,
        &admin_cap,
        test.ctx(),
    );

    return_shared(registry);
    unit_test::destroy(admin_cap);

    let cred_multiplier = constants::cred_multiplier();
    let bid_price = cred_multiplier - 80 * constants::float_scaling();
    let ask_price = cred_multiplier + 80 * constants::float_scaling();

    test.next_tx(sender);
    {
        let mut pool = test.take_shared_by_id<Pool<USDC, CRED>>(reference_pool_id);
        let clock = test.take_shared<Clock>();
        let mut bm = test.take_shared_by_id<BalanceManager>(balance_manager_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = bm.generate_proof_as_trader(&trade_cap, test.ctx());

        pool.place_limit_order(
            &mut bm,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            bid_price,
            1 * constants::float_scaling(),
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(clock);
        return_shared(bm);
        test.return_to_sender(trade_cap);
    };

    test.next_tx(sender);
    {
        let mut pool = test.take_shared_by_id<Pool<USDC, CRED>>(reference_pool_id);
        let clock = test.take_shared<Clock>();
        let mut bm = test.take_shared_by_id<BalanceManager>(balance_manager_id);
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = bm.generate_proof_as_trader(&trade_cap, test.ctx());

        pool.place_limit_order(
            &mut bm,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            ask_price,
            1 * constants::float_scaling(),
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(clock);
        return_shared(bm);
        test.return_to_sender(trade_cap);
    };

    reference_pool_id
}

/// Set up a multicoin pool with CRED pricing from a reference pool.
/// Returns (multicoin_pool_id, reference_pool_id)
public fun setup_multicoin_pool_with_cred_pricing(
    sender: address,
    registry_id: ID,
    collection_id: ID,
    asset_id: u64,
    balance_manager_id: ID,
    test: &mut Scenario,
): (ID, ID) {
    let multicoin_pool_id = setup_multicoin_pool(
        sender,
        registry_id,
        collection_id,
        asset_id,
        false,
        false,
        test,
    );

    let reference_pool_id = setup_cred_usdc_reference_pool(
        sender,
        registry_id,
        balance_manager_id,
        test,
    );

    set_time(0, test);

    (multicoin_pool_id, reference_pool_id)
}
