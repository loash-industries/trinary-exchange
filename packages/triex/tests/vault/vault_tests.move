// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::vault_tests;

use std::unit_test::destroy;
use sui::{balance, test_scenario::{next_tx, begin, end}};
use triexbook::{
    balance_manager::{Self, BalanceManager},
    balance_manager_tests::{USDC, SPAM, create_acct_and_share_with_funds},
    balances,
    constants,
    vault
};

const OWNER: address = @0xF;
const ALICE: address = @0xA;
const BOB: address = @0xB;

/*
 * #feat:flashloan - DISABLED
 */

/*
#[test]
fun borrow_flashloan_ok() {
    let mut test = begin(OWNER);

    let balance_manager_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(
        balance_manager_id,
    );
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
    );

    // borrow flashloan
    let (base, base_loan) = vault.borrow_flashloan_base(
        id_from_address(@0x1),
        1000,
        test.ctx(),
    );
    let (quote, quote_loan) = vault.borrow_flashloan_quote(
        id_from_address(@0x1),
        1000,
        test.ctx(),
    );
    vault.return_flashloan_base(id_from_address(@0x1), base, base_loan);
    vault.return_flashloan_quote(id_from_address(@0x1), quote, quote_loan);

    destroy(vault);
    destroy(balance_manager);
    test.end();
}

#[test]
fun borrow_flashloan_single_ok() {
    let mut test = begin(OWNER);

    let balance_manager_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(
        balance_manager_id,
    );
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
    );

    // borrow flashloan
    let (quote, loan) = vault.borrow_flashloan_quote(
        id_from_address(@0x1),
        1000,
        test.ctx(),
    );
    vault.return_flashloan_quote(id_from_address(@0x1), quote, loan);

    destroy(vault);
    destroy(balance_manager);
    test.end();
}

#[test, expected_failure(abort_code = vault::ENotEnoughBaseForLoan)]
fun borrow_flashloan_not_enough_base_e() {
    let mut test = begin(OWNER);

    let balance_manager_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(
        balance_manager_id,
    );
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
    );

    // borrow flashloan
    let (_base, _loan) = vault.borrow_flashloan_base(
        id_from_address(@0x1),
        1001,
        test.ctx(),
    );
    let (_quote, _loan) = vault.borrow_flashloan_quote(
        id_from_address(@0x1),
        1000,
        test.ctx(),
    );

    abort (0)
}

#[test, expected_failure(abort_code = vault::ENotEnoughQuoteForLoan)]
fun borrow_flashloan_not_enough_quote_e() {
    let mut test = begin(OWNER);

    let balance_manager_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(
        balance_manager_id,
    );
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
    );

    // borrow flashloan
    let (_base, _loan) = vault.borrow_flashloan_base(
        id_from_address(@0x1),
        1000,
        test.ctx(),
    );
    let (_quote, _loan) = vault.borrow_flashloan_quote(
        id_from_address(@0x1),
        1001,
        test.ctx(),
    );

    abort 0
}

#[test, expected_failure(abort_code = vault::EIncorrectLoanPool)]
fun borrow_flashloan_incorrect_pool_id_e() {
    let mut test = begin(OWNER);

    let balance_manager_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(
        balance_manager_id,
    );
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
    );

    // borrow flashloan
    let (base, base_loan) = vault.borrow_flashloan_base(
        id_from_address(@0x1),
        1000,
        test.ctx(),
    );
    vault.return_flashloan_base(id_from_address(@0x2), base, base_loan);

    abort (0)
}

#[test, expected_failure(abort_code = vault::EIncorrectQuantityReturned)]
fun borrow_flashloan_incorrect_return_base_e() {
    let mut test = begin(OWNER);

    let balance_manager_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(
        balance_manager_id,
    );
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
    );

    // borrow flashloan
    let (mut base, loan) = vault.borrow_flashloan_base(
        id_from_address(@0x1),
        1000,
        test.ctx(),
    );
    let return_base = base.split(999, test.ctx());
    vault.return_flashloan_base(id_from_address(@0x1), return_base, loan);

    abort (0)
}

#[test, expected_failure(abort_code = vault::EIncorrectQuantityReturned)]
fun borrow_flashloan_incorrect_return_quote_e() {
    let mut test = begin(OWNER);

    let balance_manager_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(
        balance_manager_id,
    );
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
    );

    // borrow flashloan
    let (mut quote, loan) = vault.borrow_flashloan_quote(
        id_from_address(@0x1),
        1000,
        test.ctx(),
    );
    let return_quote = quote.split(999, test.ctx());
    vault.return_flashloan_quote(id_from_address(@0x1), return_quote, loan);

    abort (0)
}

*/

#[test]
fun owed_equals_settled_ok() {
    let mut test = begin(OWNER);

    let balance_manager_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(1000, 1000, 1000);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(
        balance_manager_id,
    );
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
    );

    destroy(vault);
    destroy(balance_manager);
    test.end();
}

#[test, expected_failure(abort_code = balance_manager::EInvalidProof)]
fun owed_equals_settled_e() {
    let mut test = begin(OWNER);

    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(1000, 1000, 1000);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut balance_manager_alice = test.take_shared_by_id<BalanceManager>(
        balance_manager_id_alice,
    );
    let mut balance_manager_bob = test.take_shared_by_id<BalanceManager>(
        balance_manager_id_bob,
    );
    let trade_proof = balance_manager_alice.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager_bob,
        &trade_proof,
        option::none(),
    );

    destroy(vault);
    destroy(balance_manager_bob);
    destroy(balance_manager_alice);
    test.end();
}

// === Quote Fee Reserve Tests ===

#[test]
fun test_deposit_quote_fees() {
    let mut vault = vault::empty<SPAM, USDC>();
    let fee_balance = balance::create_for_testing<USDC>(10_000);

    vault.deposit_quote_fees(fee_balance);

    assert!(vault.quote_fee_reserve_balance() == 10_000);

    destroy(vault);
}

#[test]
fun test_deposit_multiple_quote_fees() {
    let mut vault = vault::empty<SPAM, USDC>();

    // First deposit
    let fee_balance1 = balance::create_for_testing<USDC>(5_000);
    vault.deposit_quote_fees(fee_balance1);
    assert!(vault.quote_fee_reserve_balance() == 5_000);

    // Second deposit (accumulates)
    let fee_balance2 = balance::create_for_testing<USDC>(3_000);
    vault.deposit_quote_fees(fee_balance2);
    assert!(vault.quote_fee_reserve_balance() == 8_000);

    destroy(vault);
}

#[test]
fun test_withdraw_quote_fees() {
    let mut test = begin(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();

    // Deposit fees first
    let fee_balance = balance::create_for_testing<USDC>(10_000);
    vault.deposit_quote_fees(fee_balance);

    // Withdraw some fees
    let fee_coin = vault.withdraw_quote_fees(6_000, test.ctx());
    assert!(fee_coin.value() == 6_000);
    assert!(vault.quote_fee_reserve_balance() == 4_000);

    destroy(fee_coin);
    destroy(vault);
    test.end();
}

#[test]
fun test_withdraw_all_quote_fees() {
    let mut test = begin(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();

    // Deposit fees
    let fee_balance = balance::create_for_testing<USDC>(10_000);
    vault.deposit_quote_fees(fee_balance);

    // Withdraw all
    let fee_coin = vault.withdraw_quote_fees(10_000, test.ctx());
    assert!(fee_coin.value() == 10_000);
    assert!(vault.quote_fee_reserve_balance() == 0);

    destroy(fee_coin);
    destroy(vault);
    test.end();
}

#[test]
#[expected_failure(abort_code = vault::EInsufficientFeeReserve)]
fun test_withdraw_exceeds_reserve_e() {
    let mut test = begin(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();

    // Deposit fees
    let fee_balance = balance::create_for_testing<USDC>(5_000);
    vault.deposit_quote_fees(fee_balance);

    // Try to withdraw more than available
    let fee_coin = vault.withdraw_quote_fees(6_000, test.ctx());

    destroy(fee_coin);
    destroy(vault);
    test.end();
}

#[test]
#[expected_failure(abort_code = vault::EInsufficientFeeReserve)]
fun test_withdraw_from_empty_reserve_e() {
    let mut test = begin(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();

    // Try to withdraw from empty reserve
    let fee_coin = vault.withdraw_quote_fees(1_000, test.ctx());

    destroy(fee_coin);
    destroy(vault);
    test.end();
}

#[test]
fun test_fee_reserve_separate_from_quote_balance() {
    let mut test = begin(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();

    // Setup balance manager with funds
    let balance_manager_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);

    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(0, 50_000, 0);
    let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id);
    let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

    // Move quote funds into vault
    vault.settle_balance_manager(
        settled_balances,
        owed_balances,
        &mut balance_manager,
        &trade_proof,
        option::none(),
    );

    let (_, quote_balance, _) = vault.balances();
    assert!(quote_balance == 50_000);
    assert!(vault.quote_fee_reserve_balance() == 0);

    // Add fee reserve
    let fee_balance = balance::create_for_testing<USDC>(10_000);
    vault.deposit_quote_fees(fee_balance);

    // Verify they're separate
    let (_, quote_balance_after, _) = vault.balances();
    assert!(quote_balance_after == 50_000); // Unchanged
    assert!(vault.quote_fee_reserve_balance() == 10_000);

    destroy(vault);
    destroy(balance_manager);
    test.end();
}
