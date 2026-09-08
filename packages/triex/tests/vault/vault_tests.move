// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::vault_tests;

use std::unit_test::destroy;
use sui::{balance, object::id_from_address, test_scenario::{next_tx, begin, end}};
use triexbook::{
    trading_account::{Self, TradingAccount},
    trading_account_tests::{USDC, SPAM, create_acct_and_share_with_funds},
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

    let trading_account_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut trading_account = test.take_shared_by_id<TradingAccount>(
        trading_account_id,
    );
    let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_trading_account(
        settled_balances,
        owed_balances,
        &mut trading_account,
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
    destroy(trading_account);
    test.end();
}

#[test]
fun borrow_flashloan_single_ok() {
    let mut test = begin(OWNER);

    let trading_account_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut trading_account = test.take_shared_by_id<TradingAccount>(
        trading_account_id,
    );
    let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_trading_account(
        settled_balances,
        owed_balances,
        &mut trading_account,
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
    destroy(trading_account);
    test.end();
}

#[test, expected_failure(abort_code = vault::ENotEnoughBaseForLoan)]
fun borrow_flashloan_not_enough_base_e() {
    let mut test = begin(OWNER);

    let trading_account_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut trading_account = test.take_shared_by_id<TradingAccount>(
        trading_account_id,
    );
    let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_trading_account(
        settled_balances,
        owed_balances,
        &mut trading_account,
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

    let trading_account_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut trading_account = test.take_shared_by_id<TradingAccount>(
        trading_account_id,
    );
    let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_trading_account(
        settled_balances,
        owed_balances,
        &mut trading_account,
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

    let trading_account_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut trading_account = test.take_shared_by_id<TradingAccount>(
        trading_account_id,
    );
    let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_trading_account(
        settled_balances,
        owed_balances,
        &mut trading_account,
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

    let trading_account_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut trading_account = test.take_shared_by_id<TradingAccount>(
        trading_account_id,
    );
    let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_trading_account(
        settled_balances,
        owed_balances,
        &mut trading_account,
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

    let trading_account_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut trading_account = test.take_shared_by_id<TradingAccount>(
        trading_account_id,
    );
    let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_trading_account(
        settled_balances,
        owed_balances,
        &mut trading_account,
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

    let trading_account_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(1000, 1000, 1000);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut trading_account = test.take_shared_by_id<TradingAccount>(
        trading_account_id,
    );
    let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_trading_account(
        settled_balances,
        owed_balances,
        &mut trading_account,
        &trade_proof,
        option::none(),
    );

    destroy(vault);
    destroy(trading_account);
    test.end();
}

#[test, expected_failure(abort_code = trading_account::EInvalidProof)]
fun owed_equals_settled_e() {
    let mut test = begin(OWNER);

    let trading_account_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let trading_account_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    let settled_balances = balances::new(1000, 1000, 1000);
    let owed_balances = balances::new(1000, 1000, 1000);
    let mut trading_account_alice = test.take_shared_by_id<TradingAccount>(
        trading_account_id_alice,
    );
    let mut trading_account_bob = test.take_shared_by_id<TradingAccount>(
        trading_account_id_bob,
    );
    let trade_proof = trading_account_alice.generate_proof_as_owner(test.ctx());

    // move funds into the vault
    vault.settle_trading_account(
        settled_balances,
        owed_balances,
        &mut trading_account_bob,
        &trade_proof,
        option::none(),
    );

    destroy(vault);
    destroy(trading_account_bob);
    destroy(trading_account_alice);
    test.end();
}

// === Quote Fee Reserve Tests ===

#[test]
fun test_withdrawable_excludes_locked_escrow() {
    let mut vault = vault::empty<SPAM, USDC>();
    vault.deposit_quote_fees(balance::create_for_testing<USDC>(10_000));
    vault.lock_maker_fees_for_testing(4_000);

    assert!(vault.quote_fee_reserve_balance() == 10_000);
    assert!(vault.locked_maker_fees() == 4_000);
    assert!(vault.withdrawable_quote_fees() == 6_000);

    destroy(vault);
}

#[test]
fun test_recognizing_escrow_moves_it_to_withdrawable() {
    let mut vault = vault::empty<SPAM, USDC>();
    vault.deposit_quote_fees(balance::create_for_testing<USDC>(10_000));
    vault.lock_maker_fees_for_testing(4_000);

    // Recognition reclassifies without moving funds.
    vault.recognize_locked_maker_fees(1_500);
    assert!(vault.quote_fee_reserve_balance() == 10_000);
    assert!(vault.locked_maker_fees() == 2_500);
    assert!(vault.withdrawable_quote_fees() == 7_500);

    destroy(vault);
}

#[test]
fun test_recognizing_more_than_locked_saturates_at_zero() {
    let mut vault = vault::empty<SPAM, USDC>();
    vault.deposit_quote_fees(balance::create_for_testing<USDC>(10_000));
    vault.lock_maker_fees_for_testing(1_000);

    // Per-fill flooring can never exceed the once-floored lock, but the
    // counter saturates rather than underflowing if it ever did.
    vault.recognize_locked_maker_fees(4_000);
    assert!(vault.locked_maker_fees() == 0);
    assert!(vault.withdrawable_quote_fees() == 10_000);

    destroy(vault);
}

#[test]
fun test_withdraw_exactly_unlocked_ok() {
    let mut test = begin(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    vault.deposit_quote_fees(balance::create_for_testing<USDC>(10_000));
    vault.lock_maker_fees_for_testing(4_000);

    let fee_coin = vault.withdraw_quote_fees(6_000, test.ctx());
    assert!(fee_coin.value() == 6_000);
    // The escrow is untouched and still fully backed.
    assert!(vault.quote_fee_reserve_balance() == 4_000);
    assert!(vault.locked_maker_fees() == 4_000);
    assert!(vault.withdrawable_quote_fees() == 0);

    destroy(fee_coin);
    destroy(vault);
    test.end();
}

#[test]
#[expected_failure(abort_code = vault::EFeesLocked)]
fun test_withdraw_one_above_unlocked_e() {
    let mut test = begin(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    vault.deposit_quote_fees(balance::create_for_testing<USDC>(10_000));
    vault.lock_maker_fees_for_testing(4_000);

    let fee_coin = vault.withdraw_quote_fees(6_001, test.ctx());

    destroy(fee_coin);
    destroy(vault);
    test.end();
}

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

    // Setup trading account with funds
    let trading_account_id = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    test.next_tx(ALICE);

    let settled_balances = balances::new(0, 0, 0);
    let owed_balances = balances::new(0, 50_000, 0);
    let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
    let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

    // Move quote funds into vault
    vault.settle_trading_account(
        settled_balances,
        owed_balances,
        &mut trading_account,
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
    destroy(trading_account);
    test.end();
}

// === unlock_quote_fees ===
// The refund primitive. Unlike recognition, this moves real funds out of the
// reserve, so it has to keep the `reserve >= locked` invariant intact.

#[test]
fun test_unlock_quote_fees_moves_funds_and_clears_escrow() {
    let mut test = begin(ALICE);
    let mut vault = vault::empty<SPAM, USDC>();
    vault.deposit_quote_fees(balance::create_for_testing<USDC>(10_000));
    vault.lock_maker_fees_for_testing(4_000);

    // A cancel releasing 1_000 of escrow refunds 800 of it.
    vault.unlock_quote_fees(id_from_address(@0x1), 1, id_from_address(ALICE), 800, 0);

    // The refund left the reserve entirely — it is not revenue.
    assert!(vault.quote_fee_reserve_balance() == 9_200);
    assert!(vault.locked_maker_fees() == 3_200);
    // Recognizing the retained 200 leaves the remaining 3_000 of escrow locked.
    vault.recognize_locked_maker_fees(200);
    assert!(vault.locked_maker_fees() == 3_000);
    assert!(vault.withdrawable_quote_fees() == 6_200);

    destroy(vault);
    test.end();
}

#[test]
fun test_unlock_quote_fees_zero_is_noop() {
    let mut vault = vault::empty<SPAM, USDC>();
    vault.deposit_quote_fees(balance::create_for_testing<USDC>(10_000));
    vault.lock_maker_fees_for_testing(4_000);

    // Ask cancels release nothing, so this is the common case.
    vault.unlock_quote_fees(id_from_address(@0x1), 1, id_from_address(ALICE), 0, 0);

    assert!(vault.quote_fee_reserve_balance() == 10_000);
    assert!(vault.locked_maker_fees() == 4_000);

    destroy(vault);
}

#[test]
fun test_unlock_preserves_reserve_covers_locked() {
    let mut vault = vault::empty<SPAM, USDC>();
    vault.deposit_quote_fees(balance::create_for_testing<USDC>(5_000));
    vault.lock_maker_fees_for_testing(5_000);

    // Refunding the whole escrow drains exactly as much as it unlocks, so a
    // fully-escrowed reserve stays solvent rather than going negative.
    vault.unlock_quote_fees(id_from_address(@0x1), 1, id_from_address(ALICE), 4_000, 0);
    assert!(vault.quote_fee_reserve_balance() == 1_000);
    assert!(vault.locked_maker_fees() == 1_000);
    assert!(vault.withdrawable_quote_fees() == 0);

    destroy(vault);
}

#[test]
#[expected_failure(abort_code = vault::EInsufficientFeeReserve)]
fun test_unlock_more_than_reserve_e() {
    let mut vault = vault::empty<SPAM, USDC>();
    vault.deposit_quote_fees(balance::create_for_testing<USDC>(1_000));
    vault.lock_maker_fees_for_testing(1_000);

    vault.unlock_quote_fees(id_from_address(@0x1), 1, id_from_address(ALICE), 1_001, 0);

    destroy(vault);
}
