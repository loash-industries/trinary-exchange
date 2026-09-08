// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::multicoin_vault_tests;

use multicoin::multicoin::{Self, Balance as MultiCoinBalance, Collection, CollectionCap};
use std::unit_test::destroy;
use sui::{coin::mint_for_testing, test_scenario::{Scenario, next_tx, begin, end, return_shared}};
use token::cred::CRED;
use triexbook::{
    balance_manager::{Self, BalanceManager},
    balance_manager_tests::USDC,
    balances,
    constants,
    multicoin_vault
};

const OWNER: address = @0xF;
const ALICE: address = @0xA;
const BOB: address = @0xB;

// Test asset ID
const TEST_ASSET_ID: u64 = 42;

// === Helper Functions ===

/// Setup a MultiCoin collection for testing
fun setup_collection(test: &mut Scenario): (ID, CollectionCap) {
    test.next_tx(OWNER);
    let (collection, collection_cap) = multicoin::new_collection(test.ctx());
    let collection_id = object::id(&collection);
    sui::transfer::public_share_object(collection);
    (collection_id, collection_cap)
}

/// Create a balance manager with both Coin and MultiCoin funds
fun create_multicoin_acct_and_share_with_funds(
    sender: address,
    coin_amount: u64,
    collection_cap: &CollectionCap,
    multicoin_asset_id: u64,
    multicoin_amount: u64,
    test: &mut Scenario,
): ID {
    test.next_tx(sender);
    let mut balance_manager = balance_manager::new(test.ctx());

    // Deposit Coin-based assets
    balance_manager.deposit(
        mint_for_testing<USDC>(coin_amount, test.ctx()),
        test.ctx(),
    );
    balance_manager.deposit(
        mint_for_testing<CRED>(coin_amount, test.ctx()),
        test.ctx(),
    );

    // Deposit MultiCoin balance
    if (multicoin_amount > 0) {
        // Mint MultiCoin using collection
        let mut collection = test.take_shared<Collection>();
        let multicoin_balance = multicoin::mint_and_keep(
            collection_cap,
            &mut collection,
            multicoin_asset_id,
            multicoin_amount,
            test.ctx(),
        );
        return_shared(collection);

        // Transfer to sender first, then deposit
        transfer::public_transfer(multicoin_balance, sender);
    };

    let trade_cap = balance_manager.mint_trade_cap(test.ctx());
    transfer::public_transfer(trade_cap, sender);
    let id = object::id(&balance_manager);
    transfer::public_share_object(balance_manager);

    // If we minted multicoin, deposit it now
    if (multicoin_amount > 0) {
        test.next_tx(sender);
        let mut balance_manager_mut = test.take_shared_by_id<BalanceManager>(id);
        let multicoin_bal = test.take_from_sender<MultiCoinBalance>();
        balance_manager_mut.deposit_multicoin(multicoin_bal, test.ctx());
        return_shared(balance_manager_mut);
    };

    id
}

// === Tests ===

#[test]
fun test_empty_vault_creation() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());

    let (base, quote, cred) = vault.balances();
    assert!(base == 0, 0);
    assert!(quote == 0, 1);
    assert!(cred == 0, 2);
    assert!(vault.collection_id() == collection_id, 3);
    assert!(vault.asset_id() == TEST_ASSET_ID, 4);

    destroy(vault);
    destroy(collection_cap);
    test.end();
}

#[test]
fun test_owed_equals_settled_ok() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let settled_balances = balances::new(1000, 1000, 1000);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // Move funds into the vault (equal amounts in and out should be no-op)
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    destroy(vault);
    destroy(balance_manager);
    destroy(collection_cap);
    test.end();
}

#[test]
#[expected_failure(abort_code = balance_manager::EInvalidProof)]
fun test_owed_equals_settled_invalid_proof_e() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id_alice = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let balance_manager_id_bob = create_multicoin_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let settled_balances = balances::new(1000, 1000, 1000);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut balance_manager_alice = test.take_shared_by_id<BalanceManager>(
        balance_manager_id_alice,
    );
    let mut balance_manager_bob = test.take_shared_by_id<BalanceManager>(
        balance_manager_id_bob,
    );
    let trade_proof = balance_manager_alice.generate_proof_as_owner(test.ctx());

    // Try to use Alice's proof with Bob's balance_manager (should fail)
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager_bob,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    destroy(vault);
    destroy(balance_manager_bob);
    destroy(balance_manager_alice);
    destroy(collection_cap);
    test.end();
}

#[test]
fun test_withdraw_cred_to_burn() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // Put CRED in vault
    let owed = balances::new(0, 0, 10000);
    let settled = balances::new(0, 0, 0);
    vault.settle_balance_manager(
        settled,
        owed,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Withdraw 3000 CRED for burning
    let cred_to_burn = vault.withdraw_cred_to_burn(3000);
    assert!(cred_to_burn.value() == 3000, 0);

    // Vault should have 7000 CRED left
    let (_base, _quote, cred) = vault.balances();
    assert!(cred == 7000, 1);

    destroy(cred_to_burn);
    destroy(vault);
    destroy(balance_manager);
    destroy(collection_cap);
    test.end();
}

#[test]
fun test_settle_vault_owes_base_to_user() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // First, put some base tokens into the vault
    let initial_owed = balances::new(5000, 0, 0);
    let initial_settled = balances::new(0, 0, 0);
    vault.settle_balance_manager(
        initial_settled,
        initial_owed,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Verify vault has 5000 base
    let (base, quote, cred) = vault.balances();
    assert!(base == 5000, 0);
    assert!(quote == 0, 1);
    assert!(cred == 0, 2);

    // Now vault owes user 2000 base (settled > owed)
    let settled_balances = balances::new(2000, 0, 0);
    let owed_balances = balances::new(0, 0, 0);
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Vault should have 3000 base left
    let (base_after, quote_after, cred_after) = vault.balances();
    assert!(base_after == 3000, 3);
    assert!(quote_after == 0, 4);
    assert!(cred_after == 0, 5);

    destroy(vault);
    destroy(balance_manager);
    destroy(collection_cap);
    test.end();
}

#[test]
fun test_settle_user_owes_base_to_vault() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // User owes vault 3000 base (owed > settled)
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(3000, 0, 0);
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Vault should have 3000 base
    let (base, quote, cred) = vault.balances();
    assert!(base == 3000, 0);
    assert!(quote == 0, 1);
    assert!(cred == 0, 2);

    destroy(vault);
    destroy(balance_manager);
    destroy(collection_cap);
    test.end();
}

#[test]
fun test_settle_vault_owes_quote_to_user() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // First, put some quote tokens into the vault
    let initial_owed = balances::new(0, 5000, 0);
    let initial_settled = balances::new(0, 0, 0);
    vault.settle_balance_manager(
        initial_settled,
        initial_owed,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Verify vault has 5000 quote
    let (base, quote, cred) = vault.balances();
    assert!(base == 0, 0);
    assert!(quote == 5000, 1);
    assert!(cred == 0, 2);

    // Now vault owes user 2000 quote
    let settled_balances = balances::new(0, 2000, 0);
    let owed_balances = balances::new(0, 0, 0);
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Vault should have 3000 quote left
    let (base_after, quote_after, cred_after) = vault.balances();
    assert!(base_after == 0, 3);
    assert!(quote_after == 3000, 4);
    assert!(cred_after == 0, 5);

    destroy(vault);
    destroy(balance_manager);
    destroy(collection_cap);
    test.end();
}

#[test]
fun test_settle_user_owes_quote_to_vault() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // User owes vault 3000 quote
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(0, 3000, 0);
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Vault should have 3000 quote
    let (base, quote, cred) = vault.balances();
    assert!(base == 0, 0);
    assert!(quote == 3000, 1);
    assert!(cred == 0, 2);

    destroy(vault);
    destroy(balance_manager);
    destroy(collection_cap);
    test.end();
}

#[test]
fun test_settle_vault_owes_cred_to_user() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // First, put some CRED tokens into the vault
    let initial_owed = balances::new(0, 0, 5000);
    let initial_settled = balances::new(0, 0, 0);
    vault.settle_balance_manager(
        initial_settled,
        initial_owed,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Verify vault has 5000 CRED
    let (base, quote, cred) = vault.balances();
    assert!(base == 0, 0);
    assert!(quote == 0, 1);
    assert!(cred == 5000, 2);

    // Now vault owes user 2000 CRED
    let settled_balances = balances::new(0, 0, 2000);
    let owed_balances = balances::new(0, 0, 0);
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Vault should have 3000 CRED left
    let (base_after, quote_after, cred_after) = vault.balances();
    assert!(base_after == 0, 3);
    assert!(quote_after == 0, 4);
    assert!(cred_after == 3000, 5);

    destroy(vault);
    destroy(balance_manager);
    destroy(collection_cap);
    test.end();
}

#[test]
fun test_settle_user_owes_cred_to_vault() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // User owes vault 3000 CRED
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(0, 0, 3000);
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Vault should have 3000 CRED
    let (base, quote, cred) = vault.balances();
    assert!(base == 0, 0);
    assert!(quote == 0, 1);
    assert!(cred == 3000, 2);

    destroy(vault);
    destroy(balance_manager);
    destroy(collection_cap);
    test.end();
}

#[test]
fun test_settle_complex_multi_asset() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // Complex settlement: user owes base and quote, vault owes CRED
    // First put CRED in vault
    let setup_owed = balances::new(0, 0, 5000);
    let setup_settled = balances::new(0, 0, 0);
    vault.settle_balance_manager(
        setup_settled,
        setup_owed,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Now: user owes 1000 base + 2000 quote, vault owes 1500 CRED
    let settled_balances = balances::new(0, 0, 1500);
    let owed_balances = balances::new(1000, 2000, 0);
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    // Vault should have: 1000 base, 2000 quote, 3500 CRED (5000 - 1500)
    let (base, quote, cred) = vault.balances();
    assert!(base == 1000, 0);
    assert!(quote == 2000, 1);
    assert!(cred == 3500, 2);

    destroy(vault);
    destroy(balance_manager);
    destroy(collection_cap);
    test.end();
}

#[test]
#[expected_failure(abort_code = multicoin_vault::EInsufficientBaseBalance)]
fun test_settle_insufficient_base_e() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // Try to settle more base than vault has (vault owes 1000 base but has 0)
    let settled_balances = balances::new(1000, 0, 0);
    let owed_balances = balances::new(0, 0, 0);
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    abort (0)
}

#[test]
#[expected_failure(abort_code = multicoin_vault::EInsufficientQuoteBalance)]
fun test_settle_insufficient_quote_e() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // Try to settle more quote than vault has
    let settled_balances = balances::new(0, 1000, 0);
    let owed_balances = balances::new(0, 0, 0);
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    abort (0)
}

#[test]
#[expected_failure(abort_code = multicoin_vault::EInsufficientCredBalance)]
fun test_settle_insufficient_cred_e() {
    let mut test = begin(OWNER);

    let (collection_id, collection_cap) = setup_collection(&mut test);
    let balance_manager_id = create_multicoin_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &collection_cap,
        TEST_ASSET_ID,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(ALICE);
    let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // Try to settle more CRED than vault has
    let settled_balances = balances::new(0, 0, 1000);
    let owed_balances = balances::new(0, 0, 0);
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
        test.ctx(),
    );

    abort (0)
}
