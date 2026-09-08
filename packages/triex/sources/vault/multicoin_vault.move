// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// MultiCoinVault implements the Dual Storage pattern for MultiCoin/Coin pools.
/// - Base assets: MultiCoin Balance objects stored via dynamic object fields
/// - Quote assets: Traditional Sui Balance<QuoteAsset>
/// - CRED: Traditional Sui Balance<CRED> for fee payments
module triexbook::multicoin_vault;

use multicoin::multicoin::{Self, Balance as MultiCoinBalance};
use sui::{balance::{Self, Balance}, coin::{Self, Coin}, dynamic_object_field as dof};
use token::cred::CRED;
use triexbook::{balance_manager::{TradeProof, BalanceManager}, balances::Balances, vault};

// === Errors ===
const EInsufficientBaseBalance: u64 = 1;
const EInsufficientQuoteBalance: u64 = 2;
const EInsufficientCredBalance: u64 = 3;
const EInsufficientFeeReserve: u64 = 5;
const EFeesLocked: u64 = 6;
const ENoBalanceToSettle: u64 = 7;
const EHasOwedBalances: u64 = 8;

// === Structs ===

/// Key for storing MultiCoin base balance in dynamic object fields.
public struct MultiCoinBaseKey has copy, drop, store {
    collection_id: ID,
    asset_id: u64,
}

/// Dual Storage vault for MultiCoin/Coin pools.
/// - Base: MultiCoin Balance stored as dynamic object field (keyed by collection_id + asset_id)
/// - Quote: Traditional Balance<QuoteAsset>
/// - CRED: Traditional Balance<CRED>
public struct MultiCoinVault<phantom QuoteAsset> has key, store {
    id: UID,
    /// The MultiCoin collection ID this vault is associated with
    collection_id: ID,
    /// The specific asset_id within the collection
    asset_id: u64,
    /// Quote currency balance (Coin-based)
    quote_balance: Balance<QuoteAsset>,
    /// CRED balance for fee payments
    cred_balance: Balance<CRED>,
    /// Quote fee reserve (quote-denominated fees collected during settlement)
    quote_fee_reserve: Balance<QuoteAsset>,
    /// The portion of `quote_fee_reserve` that is a bid maker's escrow rather
    /// than earned revenue: locked when the order is placed, then drawn down
    /// as the order resolves — recognized as revenue by fills and by the
    /// retained share of a cancel, unlocked back to the maker by the refunded
    /// share. Admin withdrawals are capped at the unlocked remainder so a
    /// sweep can never spend an open order's escrow.
    ///
    /// Recognition floors per fill while the lock floors once over the whole
    /// order, so a resolved order can leave a few units still counted as
    /// locked. This counter is pool-lifetime and only ever decrements, so
    /// those residues accumulate: `withdrawable_quote_fees` drifts
    /// permanently below the reserve, by at most one raw quote unit per
    /// release, and nothing reconciles it. That errs toward under-withdrawing
    /// rather than toward spending escrow, which is the safe direction here,
    /// and it is deliberately left uncorrected — clearing it would need
    /// per-order residue tracking the vault does not keep.
    locked_maker_fees: u64,
}

// === Public-Package Functions ===

/// Create an empty MultiCoinVault for the given collection and asset.
public(package) fun empty<QuoteAsset>(
    collection_id: ID,
    asset_id: u64,
    ctx: &mut TxContext,
): MultiCoinVault<QuoteAsset> {
    let mut vault = MultiCoinVault {
        id: object::new(ctx),
        collection_id,
        asset_id,
        quote_balance: balance::zero(),
        cred_balance: balance::zero(),
        quote_fee_reserve: balance::zero(),
        locked_maker_fees: 0,
    };

    // Initialize with a zero MultiCoin balance
    let key = MultiCoinBaseKey { collection_id, asset_id };
    let zero_balance = multicoin::zero(collection_id, asset_id, ctx);
    dof::add(&mut vault.id, key, zero_balance);

    vault
}

/// Returns (base_balance, quote_balance, cred_balance) amounts.
public(package) fun balances<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): (u64, u64, u64) {
    let key = MultiCoinBaseKey {
        collection_id: self.collection_id,
        asset_id: self.asset_id,
    };
    let base_bal: &MultiCoinBalance = dof::borrow(&self.id, key);
    (base_bal.value(), self.quote_balance.value(), self.cred_balance.value())
}

public(package) fun quote_fee_reserve_balance<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): u64 {
    self.quote_fee_reserve.value()
}

/// Bid-maker escrow currently held in the reserve, not yet earned.
public(package) fun locked_maker_fees<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): u64 {
    self.locked_maker_fees
}

/// Earned revenue in the reserve: what an admin sweep may take.
public(package) fun withdrawable_quote_fees<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): u64 {
    self.quote_fee_reserve.value() - self.locked_maker_fees
}

#[test_only]
/// Mark quote already in the reserve as bid-maker escrow, standing in for a
/// placement, so the locked-fee arithmetic can be exercised directly.
public(package) fun lock_maker_fees_for_testing<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    amount: u64,
) {
    self.locked_maker_fees = self.locked_maker_fees + amount;
}

/// Recognize bid-maker escrow as earned revenue once the order fills. The
/// funds are already in the reserve; only their classification changes.
public(package) fun recognize_locked_maker_fees<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    amount: u64,
) {
    self.locked_maker_fees = self.locked_maker_fees - amount.min(self.locked_maker_fees);
}

/// Returns the collection_id this vault is associated with.
public(package) fun collection_id<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): ID {
    self.collection_id
}

/// Returns the asset_id this vault is associated with.
public(package) fun asset_id<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): u64 {
    self.asset_id
}

/// Transfer any settled amounts for the `balance_manager`.
/// Uses Balances struct for accounting (base/quote/cred as u64 deltas).
public(package) fun settle_balance_manager<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    balances_out: Balances,
    balances_in: Balances,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    quote_fee_deposit: Option<vault::QuoteFeeDeposit>,
    ctx: &mut TxContext,
) {
    balance_manager.validate_proof(trade_proof);

    let key = MultiCoinBaseKey {
        collection_id: self.collection_id,
        asset_id: self.asset_id,
    };

    // === BASE (MultiCoin) settlements ===
    if (balances_out.base() > balances_in.base()) {
        // Vault owes user base tokens: split from vault, deposit to balance_manager
        let amount = balances_out.base() - balances_in.base();
        let vault_base: &mut MultiCoinBalance = dof::borrow_mut(&mut self.id, key);
        assert!(vault_base.value() >= amount, EInsufficientBaseBalance);
        let to_deposit = vault_base.split(amount, ctx);
        balance_manager.deposit_multicoin_with_proof(trade_proof, to_deposit, ctx);
    };
    if (balances_in.base() > balances_out.base()) {
        // User owes vault base tokens: withdraw from balance_manager, join to vault
        let amount = balances_in.base() - balances_out.base();
        let withdrawn = balance_manager.withdraw_multicoin_with_proof(
            trade_proof,
            self.collection_id,
            self.asset_id,
            amount,
            false,
            ctx,
        );
        let vault_base: &mut MultiCoinBalance = dof::borrow_mut(&mut self.id, key);
        vault_base.join(withdrawn, ctx);
    };

    // === QUOTE (Coin) settlements ===
    if (balances_out.quote() > balances_in.quote()) {
        let amount = balances_out.quote() - balances_in.quote();
        assert!(self.quote_balance.value() >= amount, EInsufficientQuoteBalance);
        let to_deposit = self.quote_balance.split(amount);
        balance_manager.deposit_with_proof(trade_proof, to_deposit);
    };
    if (balances_in.quote() > balances_out.quote()) {
        let amount = balances_in.quote() - balances_out.quote();
        let withdrawn: Balance<QuoteAsset> = balance_manager.withdraw_with_proof(
            trade_proof,
            amount,
            false,
        );
        self.quote_balance.join(withdrawn);
    };
    // Fee escrow is carved out of the pool's quote balance rather than out of
    // the marginal withdrawal above. The quote a user owes (fees included) is
    // retained by the pool either way — withdrawn from their balance manager,
    // or netted against settled balances the pool therefore never paid out —
    // so the fee is covered even when prior settled balances cover the order
    // outright and nothing is withdrawn at all.
    if (option::is_some(&quote_fee_deposit)) {
        let deposit = quote_fee_deposit.destroy_some();
        let (
            pool_id,
            balance_manager_id,
            taker_fee_amount,
            maker_fee_amount,
            timestamp,
        ) = vault::quote_fee_deposit_into_parts(deposit);
        self.move_quote_to_fee_reserve(
            pool_id,
            balance_manager_id,
            taker_fee_amount + maker_fee_amount,
            timestamp,
        );
        // Only the maker portion is escrow; the taker fee is earned on
        // execution and immediately sweepable.
        self.locked_maker_fees = self.locked_maker_fees + maker_fee_amount;
    } else {
        option::destroy_none(quote_fee_deposit);
    };

    // === CRED settlements ===
    if (balances_out.cred() > balances_in.cred()) {
        let amount = balances_out.cred() - balances_in.cred();
        assert!(self.cred_balance.value() >= amount, EInsufficientCredBalance);
        let to_deposit = self.cred_balance.split(amount);
        balance_manager.deposit_with_proof(trade_proof, to_deposit);
    };
    if (balances_in.cred() > balances_out.cred()) {
        let amount = balances_in.cred() - balances_out.cred();
        let withdrawn: Balance<CRED> = balance_manager.withdraw_with_proof(
            trade_proof,
            amount,
            false,
        );
        self.cred_balance.join(withdrawn);
    };
}

/// Transfer any settled amounts for the `balance_manager`.
public(package) fun settle_balance_manager_permissionless<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    balances_out: Balances,
    balances_in: Balances,
    balance_manager: &mut BalanceManager,
    ctx: &mut TxContext,
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
        let key = MultiCoinBaseKey {
            collection_id: self.collection_id,
            asset_id: self.asset_id,
        };
        let amount = balances_out.base();
        let vault_base: &mut MultiCoinBalance = dof::borrow_mut(&mut self.id, key);
        assert!(vault_base.value() >= amount, EInsufficientBaseBalance);
        let to_deposit = vault_base.split(amount, ctx);
        balance_manager.deposit_multicoin_permissionless(to_deposit, ctx);
    };
    if (balances_out.quote() > 0) {
        let amount = balances_out.quote();
        assert!(self.quote_balance.value() >= amount, EInsufficientQuoteBalance);
        let balance = self.quote_balance.split(amount);
        balance_manager.deposit_permissionless(balance);
    };
    if (balances_out.cred() > 0) {
        let amount = balances_out.cred();
        assert!(self.cred_balance.value() >= amount, EInsufficientCredBalance);
        let balance = self.cred_balance.split(amount);
        balance_manager.deposit_permissionless(balance);
    };
}

/// Withdraw CRED for burning (rebates feature).
public(package) fun withdraw_cred_to_burn<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    amount_to_burn: u64,
): Balance<CRED> {
    self.cred_balance.split(amount_to_burn)
}

/// Deposit base MultiCoin directly into vault (used during pool creation or direct deposits).
public(package) fun deposit_base<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    to_deposit: MultiCoinBalance,
    ctx: &TxContext,
) {
    assert!(to_deposit.collection_id() == self.collection_id, EInsufficientBaseBalance);
    assert!(to_deposit.asset_id() == self.asset_id, EInsufficientBaseBalance);

    let key = MultiCoinBaseKey {
        collection_id: self.collection_id,
        asset_id: self.asset_id,
    };
    let vault_base: &mut MultiCoinBalance = dof::borrow_mut(&mut self.id, key);
    vault_base.join(to_deposit, ctx);
}

/// Deposit quote Coin directly into vault.
public(package) fun deposit_quote<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    to_deposit: Balance<QuoteAsset>,
) {
    self.quote_balance.join(to_deposit);
}

/// Move already-held quote from the pool balance into the fee reserve.
/// Used for fees charged out of quote proceeds (ask-taker and ask-maker
/// fees), which never pass through a user withdrawal.
public(package) fun move_quote_to_fee_reserve<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    pool_id: ID,
    balance_manager_id: ID,
    amount: u64,
    timestamp: u64,
) {
    if (amount == 0) return;
    let fee_balance = self.quote_balance.split(amount);
    self.quote_fee_reserve.join(fee_balance);
    vault::emit_pool_fees_deposited<QuoteAsset>(
        pool_id,
        amount,
        balance_manager_id,
        timestamp,
    );
}

public(package) fun deposit_quote_fees<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    fee_balance: Balance<QuoteAsset>,
) {
    self.quote_fee_reserve.join(fee_balance);
}

/// Release bid-maker escrow back to the pool balance so it can settle out to
/// the maker. Mirror of `vault::unlock_quote_fees`; see there for why the
/// funds must move buckets rather than just crediting settled balances.
public(package) fun unlock_quote_fees<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    pool_id: ID,
    order_id: u64,
    balance_manager_id: ID,
    amount: u64,
    timestamp: u64,
) {
    if (amount == 0) return;
    assert!(self.quote_fee_reserve.value() >= amount, EInsufficientFeeReserve);
    let refund_balance = self.quote_fee_reserve.split(amount);
    self.quote_balance.join(refund_balance);
    // The refund leaves the reserve entirely, so it stops being escrow too.
    self.locked_maker_fees = self.locked_maker_fees - amount.min(self.locked_maker_fees);
    vault::emit_pool_fees_refunded<QuoteAsset>(
        pool_id,
        order_id,
        amount,
        balance_manager_id,
        timestamp,
    );
}

/// Deposit CRED directly into vault.
public(package) fun deposit_cred<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    to_deposit: Balance<CRED>,
) {
    self.cred_balance.join(to_deposit);
}

public(package) fun withdraw_quote_fees<QuoteAsset>(
    self: &mut MultiCoinVault<QuoteAsset>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<QuoteAsset> {
    assert!(self.quote_fee_reserve.value() >= amount, EInsufficientFeeReserve);
    // Escrow backing open bid orders is not revenue and cannot be swept.
    assert!(amount <= self.withdrawable_quote_fees(), EFeesLocked);
    let fee_balance = self.quote_fee_reserve.split(amount);
    coin::from_balance(fee_balance, ctx)
}
