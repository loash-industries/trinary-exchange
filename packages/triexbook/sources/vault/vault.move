// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The vault holds all of the assets for this pool. At the end of all
/// transaction processing, the vault is used to settle the balances for the user.
module triexbook::vault;

use std::type_name::{Self, TypeName};
use sui::{balance::{Self, Balance}, coin::{Self, Coin}, event};
use token::cred::CRED;
use triexbook::{balance_manager::{TradeProof, BalanceManager}, balances::Balances};

// === Errors ===
const EInsufficientFeeReserve: u64 = 0;
const EInvalidQuoteFeeAmount: u64 = 1;
const ENoBalanceToSettle: u64 = 7;
const EHasOwedBalances: u64 = 8;
// #feat:flashloan - DISABLED
// const ENotEnoughBaseForLoan: u64 = 1;
// const ENotEnoughQuoteForLoan: u64 = 2;
// const EInvalidLoanQuantity: u64 = 3;
// const EIncorrectLoanPool: u64 = 4;
// const EIncorrectTypeReturned: u64 = 5;
// const EIncorrectQuantityReturned: u64 = 6;

// === Structs ===
public struct Vault<phantom BaseAsset, phantom QuoteAsset> has store {
    base_balance: Balance<BaseAsset>,
    quote_balance: Balance<QuoteAsset>,
    cred_balance: Balance<CRED>,
    quote_fee_reserve: Balance<QuoteAsset>,
}

/// Metadata describing a quote fee deposit into the reserve bucket
public struct QuoteFeeDeposit has copy, drop {
    pool_id: ID,
    balance_manager_id: ID,
    amount: u64,
    timestamp: u64,
}

public(package) fun new_quote_fee_deposit(
    pool_id: ID,
    balance_manager_id: ID,
    amount: u64,
    timestamp: u64,
): QuoteFeeDeposit {
    QuoteFeeDeposit {
        pool_id,
        balance_manager_id,
        amount,
        timestamp,
    }
}

public(package) fun quote_fee_deposit_into_parts(deposit: QuoteFeeDeposit): (ID, ID, u64, u64) {
    let QuoteFeeDeposit { pool_id, balance_manager_id, amount, timestamp } = deposit;
    (pool_id, balance_manager_id, amount, timestamp)
}

public(package) fun destroy_zero_quote_fee_deposit(deposit: QuoteFeeDeposit) {
    let (_, _, amount, _) = quote_fee_deposit_into_parts(deposit);
    assert!(amount == 0, EInvalidQuoteFeeAmount);
}

public(package) fun emit_pool_fees_deposited<QuoteAsset>(
    pool_id: ID,
    amount: u64,
    balance_manager_id: ID,
    timestamp: u64,
) {
    event::emit(PoolFeesDeposited {
        pool_id,
        quote_type: type_name::with_defining_ids<QuoteAsset>(),
        amount,
        balance_manager_id,
        timestamp,
    });
}

public(package) fun emit_pool_fees_withdrawn<QuoteAsset>(pool_id: ID, amount: u64, timestamp: u64) {
    event::emit(PoolFeesWithdrawn {
        pool_id,
        quote_type: type_name::with_defining_ids<QuoteAsset>(),
        amount,
        timestamp,
    });
}

/// Emitted when quote fees are deposited into pool vault during settlement
public struct PoolFeesDeposited has copy, drop {
    pool_id: ID,
    quote_type: TypeName,
    amount: u64,
    balance_manager_id: ID,
    timestamp: u64,
}

/// Emitted when admin withdraws accumulated fees from pool vault
public struct PoolFeesWithdrawn has copy, drop {
    pool_id: ID,
    quote_type: TypeName,
    amount: u64,
    timestamp: u64,
}

// #feat:flashloan - DISABLED
// public struct FlashLoan {
//     pool_id: ID,
//     borrow_quantity: u64,
//     type_name: TypeName,
// }
//
// public struct FlashLoanBorrowed has copy, drop {
//     pool_id: ID,
//     borrow_quantity: u64,
//     type_name: TypeName,
// }

// === Public-Package Functions ===
public(package) fun balances<BaseAsset, QuoteAsset>(
    self: &Vault<BaseAsset, QuoteAsset>,
): (u64, u64, u64) {
    (self.base_balance.value(), self.quote_balance.value(), self.cred_balance.value())
}

public(package) fun quote_fee_reserve_balance<BaseAsset, QuoteAsset>(
    self: &Vault<BaseAsset, QuoteAsset>,
): u64 {
    self.quote_fee_reserve.value()
}

public(package) fun empty<BaseAsset, QuoteAsset>(): Vault<BaseAsset, QuoteAsset> {
    Vault {
        base_balance: balance::zero(),
        quote_balance: balance::zero(),
        cred_balance: balance::zero(),
        quote_fee_reserve: balance::zero(),
    }
}

/// Transfer any settled amounts for the `balance_manager`.
public(package) fun settle_balance_manager<BaseAsset, QuoteAsset>(
    self: &mut Vault<BaseAsset, QuoteAsset>,
    balances_out: Balances,
    balances_in: Balances,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    quote_fee_deposit: Option<QuoteFeeDeposit>,
) {
    balance_manager.validate_proof(trade_proof);
    if (balances_out.base() > balances_in.base()) {
        let balance = self.base_balance.split(balances_out.base() - balances_in.base());
        balance_manager.deposit_with_proof(trade_proof, balance);
    };
    if (balances_out.quote() > balances_in.quote()) {
        let balance = self.quote_balance.split(balances_out.quote() - balances_in.quote());
        balance_manager.deposit_with_proof(trade_proof, balance);
    };
    if (balances_out.cred() > balances_in.cred()) {
        let balance = self.cred_balance.split(balances_out.cred() - balances_in.cred());
        balance_manager.deposit_with_proof(trade_proof, balance);
    };
    if (balances_in.base() > balances_out.base()) {
        let balance = balance_manager.withdraw_with_proof(
            trade_proof,
            balances_in.base() - balances_out.base(),
            false,
        );
        self.base_balance.join(balance);
    };
    if (balances_in.quote() > balances_out.quote()) {
        let mut balance = balance_manager.withdraw_with_proof(
            trade_proof,
            balances_in.quote() - balances_out.quote(),
            false,
        );
        if (option::is_some(&quote_fee_deposit)) {
            let deposit = quote_fee_deposit.destroy_some();
            let QuoteFeeDeposit { pool_id, balance_manager_id, amount, timestamp } = deposit;
            assert!(amount <= balance.value(), EInvalidQuoteFeeAmount);
            if (amount > 0) {
                let fee_balance = balance.split(amount);
                self.quote_fee_reserve.join(fee_balance);
                event::emit(PoolFeesDeposited {
                    pool_id,
                    quote_type: type_name::with_defining_ids<QuoteAsset>(),
                    amount,
                    balance_manager_id,
                    timestamp,
                });
            };
        } else {
            option::destroy_none(quote_fee_deposit);
        };
        self.quote_balance.join(balance);
    };
    if (balances_in.cred() > balances_out.cred()) {
        let balance = balance_manager.withdraw_with_proof(
            trade_proof,
            balances_in.cred() - balances_out.cred(),
            false,
        );
        self.cred_balance.join(balance);
    };
}

/// Transfer any settled amounts for the `balance_manager`.
public(package) fun settle_balance_manager_permissionless<BaseAsset, QuoteAsset>(
    self: &mut Vault<BaseAsset, QuoteAsset>,
    balances_out: Balances,
    balances_in: Balances,
    balance_manager: &mut BalanceManager,
) {
    assert!(
        balances_in.base() == 0 && balances_in.quote() == 0 && balances_in.cred() == 0,
        EHasOwedBalances,
    );
    let has_settled_balances =
        balances_out.base() > 0
        || balances_out.quote() > 0
        || balances_out.cred() > 0;
    assert!(has_settled_balances, ENoBalanceToSettle);

    if (balances_out.base() > 0) {
        let balance = self.base_balance.split(balances_out.base());
        balance_manager.deposit_permissionless(balance);
    };
    if (balances_out.quote() > 0) {
        let balance = self.quote_balance.split(balances_out.quote());
        balance_manager.deposit_permissionless(balance);
    };
    if (balances_out.cred() > 0) {
        let balance = self.cred_balance.split(balances_out.cred());
        balance_manager.deposit_permissionless(balance);
    };
}

// #feat:rebate
public(package) fun withdraw_cred_to_burn<BaseAsset, QuoteAsset>(
    self: &mut Vault<BaseAsset, QuoteAsset>,
    amount_to_burn: u64,
): Balance<CRED> {
    self.cred_balance.split(amount_to_burn)
}

// #feat:flashloan - DISABLED
// public(package) fun borrow_flashloan_base<BaseAsset, QuoteAsset>(
//     self: &mut Vault<BaseAsset, QuoteAsset>,
//     pool_id: ID,
//     borrow_quantity: u64,
//     ctx: &mut TxContext,
// ): (Coin<BaseAsset>, FlashLoan) {
//     assert!(borrow_quantity > 0, EInvalidLoanQuantity);
//     assert!(self.base_balance.value() >= borrow_quantity, ENotEnoughBaseForLoan);
//     let borrow_type_name = type_name::with_defining_ids<BaseAsset>();
//     let borrow: Coin<BaseAsset> = self.base_balance.split(borrow_quantity).into_coin(ctx);
//
//     let flash_loan = FlashLoan {
//         pool_id,
//         borrow_quantity,
//         type_name: borrow_type_name,
//     };
//
//     event::emit(FlashLoanBorrowed {
//         pool_id,
//         borrow_quantity,
//         type_name: borrow_type_name,
//     });
//
//     (borrow, flash_loan)
// }
//
// public(package) fun borrow_flashloan_quote<BaseAsset, QuoteAsset>(
//     self: &mut Vault<BaseAsset, QuoteAsset>,
//     pool_id: ID,
//     borrow_quantity: u64,
//     ctx: &mut TxContext,
// ): (Coin<QuoteAsset>, FlashLoan) {
//     assert!(borrow_quantity > 0, EInvalidLoanQuantity);
//     assert!(self.quote_balance.value() >= borrow_quantity, ENotEnoughQuoteForLoan);
//     let borrow_type_name = type_name::with_defining_ids<QuoteAsset>();
//     let borrow: Coin<QuoteAsset> = self.quote_balance.split(borrow_quantity).into_coin(ctx);
//
//     let flash_loan = FlashLoan {
//         pool_id,
//         borrow_quantity,
//         type_name: borrow_type_name,
//     };
//
//     event::emit(FlashLoanBorrowed {
//         pool_id,
//         borrow_quantity,
//         type_name: borrow_type_name,
//     });
//
//     (borrow, flash_loan)
// }
//
// public(package) fun return_flashloan_base<BaseAsset, QuoteAsset>(
//     self: &mut Vault<BaseAsset, QuoteAsset>,
//     pool_id: ID,
//     coin: Coin<BaseAsset>,
//     flash_loan: FlashLoan,
// ) {
//     assert!(pool_id == flash_loan.pool_id, EIncorrectLoanPool);
//     assert!(
//         type_name::with_defining_ids<BaseAsset>() == flash_loan.type_name,
//         EIncorrectTypeReturned,
//     );
//     assert!(coin.value() == flash_loan.borrow_quantity, EIncorrectQuantityReturned);
//
//     self.base_balance.join(coin.into_balance<BaseAsset>());
//
//     let FlashLoan {
//         pool_id: _,
//         borrow_quantity: _,
//         type_name: _,
//     } = flash_loan;
// }

/// Deposit quote fees into the fee reserve bucket
public(package) fun deposit_quote_fees<BaseAsset, QuoteAsset>(
    self: &mut Vault<BaseAsset, QuoteAsset>,
    fee_balance: Balance<QuoteAsset>,
) {
    self.quote_fee_reserve.join(fee_balance);
}

/// Withdraw accumulated quote fees (admin only, called from pool)
public(package) fun withdraw_quote_fees<BaseAsset, QuoteAsset>(
    self: &mut Vault<BaseAsset, QuoteAsset>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<QuoteAsset> {
    assert!(self.quote_fee_reserve.value() >= amount, EInsufficientFeeReserve);
    let fee_balance = self.quote_fee_reserve.split(amount);
    coin::from_balance(fee_balance, ctx)
}
//         type_name: _,
//     } = flash_loan;
// }
//
// public(package) fun return_flashloan_quote<BaseAsset, QuoteAsset>(
//     self: &mut Vault<BaseAsset, QuoteAsset>,
//     pool_id: ID,
//     coin: Coin<QuoteAsset>,
//     flash_loan: FlashLoan,
// ) {
//     assert!(pool_id == flash_loan.pool_id, EIncorrectLoanPool);
//     assert!(
//         type_name::with_defining_ids<QuoteAsset>() == flash_loan.type_name,
//         EIncorrectTypeReturned,
//     );
//     assert!(coin.value() == flash_loan.borrow_quantity, EIncorrectQuantityReturned);
//
//     self.quote_balance.join(coin.into_balance<QuoteAsset>());
//
//     let FlashLoan {
//         pool_id: _,
//         borrow_quantity: _,
//         type_name: _,
//     } = flash_loan;
// }
