// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_multicoin_registry_balance_manager_tests;

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

// === BalanceManager MultiCoin Tests ===

#[test]
fun test_deposit_multicoin_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

    // Create balance manager
    test.next_tx(ALICE);
    let mut balance_manager = balance_manager::new(test.ctx());
    let bm_id = object::id(&balance_manager);
    transfer::public_share_object(balance_manager);

    // Mint MultiCoin to deposit
    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let multicoin_balance = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        1000,
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(multicoin_balance, ALICE);

    // Deposit MultiCoin into balance manager
    test.next_tx(ALICE);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(bm_id);
    let multicoin_balance = test.take_from_sender<multicoin::Balance>();
    balance_manager.deposit_multicoin(multicoin_balance, test.ctx());

    // Verify balance
    let balance = balance_manager.multicoin_balance(collection_id, ASSET_GOLD);
    assert!(balance == 1000, 0);

    return_shared(balance_manager);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_withdraw_multicoin_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (_registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

    // Create balance manager and share immediately
    test.next_tx(ALICE);
    let balance_manager = balance_manager::new(test.ctx());
    let bm_id = object::id(&balance_manager);
    transfer::public_share_object(balance_manager);

    // Mint MultiCoin
    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let multicoin_balance = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        1000,
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(multicoin_balance, ALICE);

    // Deposit MultiCoin
    test.next_tx(ALICE);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(bm_id);
    let multicoin_balance = test.take_from_sender<multicoin::Balance>();
    balance_manager.deposit_multicoin(multicoin_balance, test.ctx());
    return_shared(balance_manager);

    // Withdraw some MultiCoin
    test.next_tx(ALICE);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(bm_id);
    let withdrawn = balance_manager.withdraw_multicoin(
        collection_id,
        ASSET_GOLD,
        400,
        test.ctx(),
    );

    // Verify balances
    assert!(withdrawn.value() == 400, 0);
    assert!(balance_manager.multicoin_balance(collection_id, ASSET_GOLD) == 600, 0);

    transfer::public_transfer(withdrawn, ALICE);
    return_shared(balance_manager);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_withdraw_all_multicoin_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (_registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

    // Create balance manager and share immediately
    test.next_tx(ALICE);
    let balance_manager = balance_manager::new(test.ctx());
    let bm_id = object::id(&balance_manager);
    transfer::public_share_object(balance_manager);

    // Mint MultiCoin
    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let multicoin_balance = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        1000,
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(multicoin_balance, ALICE);

    // Deposit MultiCoin
    test.next_tx(ALICE);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(bm_id);
    let multicoin_balance = test.take_from_sender<multicoin::Balance>();
    balance_manager.deposit_multicoin(multicoin_balance, test.ctx());
    return_shared(balance_manager);

    // Withdraw all MultiCoin
    test.next_tx(ALICE);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(bm_id);
    let withdrawn = balance_manager.withdraw_all_multicoin(
        collection_id,
        ASSET_GOLD,
        test.ctx(),
    );

    // Verify balances
    assert!(withdrawn.value() == 1000, 0);
    assert!(balance_manager.multicoin_balance(collection_id, ASSET_GOLD) == 0, 0);

    transfer::public_transfer(withdrawn, ALICE);
    return_shared(balance_manager);
    unit_test::destroy(collection_cap);

    end(test);
}

#[test]
fun test_multiple_multicoin_assets_ok() {
    let mut test = begin(OWNER);

    // Setup
    let (_registry_id, collection_id, collection_cap) = setup_registry_with_multicoin(&mut test);

    // Create balance manager and share immediately
    test.next_tx(ALICE);
    let balance_manager = balance_manager::new(test.ctx());
    let bm_id = object::id(&balance_manager);
    transfer::public_share_object(balance_manager);

    // Mint multiple assets
    test.next_tx(OWNER);
    let mut collection = test.take_shared<Collection>();
    let gold = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_GOLD,
        1000,
        test.ctx(),
    );
    let silver = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_SILVER,
        500,
        test.ctx(),
    );
    let iron = multicoin::mint_and_keep(
        &collection_cap,
        &mut collection,
        ASSET_IRON,
        2000,
        test.ctx(),
    );
    return_shared(collection);
    transfer::public_transfer(gold, ALICE);
    transfer::public_transfer(silver, ALICE);
    transfer::public_transfer(iron, ALICE);

    // Deposit all assets
    test.next_tx(ALICE);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(bm_id);
    let gold = test.take_from_sender<multicoin::Balance>();
    let silver = test.take_from_sender<multicoin::Balance>();
    let iron = test.take_from_sender<multicoin::Balance>();
    balance_manager.deposit_multicoin(gold, test.ctx());
    balance_manager.deposit_multicoin(silver, test.ctx());
    balance_manager.deposit_multicoin(iron, test.ctx());

    // Verify balances
    assert!(balance_manager.multicoin_balance(collection_id, ASSET_GOLD) == 1000, 0);
    assert!(balance_manager.multicoin_balance(collection_id, ASSET_SILVER) == 500, 1);
    assert!(balance_manager.multicoin_balance(collection_id, ASSET_IRON) == 2000, 2);

    return_shared(balance_manager);
    unit_test::destroy(collection_cap);

    end(test);
}
