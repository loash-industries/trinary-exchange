// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The vault holds all of the assets for this pool. At the end of all
/// transaction processing, the vault is used to settle the balances for the user.
module triexbook::vault {
    use std::type_name::{Self, TypeName};
    use sui::{balance::{Self, Balance}, coin::{Self, Coin}, event};
    use token::cred::CRED;
    use triexbook::{balance_manager::{TradeProof, BalanceManager}, balances::Balances};

    // === Errors ===
    const EInsufficientFeeReserve: u64 = 0;
    const EFeesLocked: u64 = 1;
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

    /// Metadata describing a quote fee deposit into the reserve bucket.
    /// The taker portion is earned revenue on execution; the maker portion is a
    /// bid maker's fee locked at placement, which stays refundable escrow until
    /// the order fills.
    public struct QuoteFeeDeposit has copy, drop {
        pool_id: ID,
        balance_manager_id: ID,
        taker_fee_amount: u64,
        maker_fee_amount: u64,
        timestamp: u64,
    }

    public(package) fun new_quote_fee_deposit(
        pool_id: ID,
        balance_manager_id: ID,
        taker_fee_amount: u64,
        maker_fee_amount: u64,
        timestamp: u64,
    ): QuoteFeeDeposit {
        QuoteFeeDeposit {
            pool_id,
            balance_manager_id,
            taker_fee_amount,
            maker_fee_amount,
            timestamp,
        }
    }

    public(package) fun quote_fee_deposit_into_parts(
        deposit: QuoteFeeDeposit,
    ): (ID, ID, u64, u64, u64) {
        let QuoteFeeDeposit {
            pool_id,
            balance_manager_id,
            taker_fee_amount,
            maker_fee_amount,
            timestamp,
        } = deposit;
        (pool_id, balance_manager_id, taker_fee_amount, maker_fee_amount, timestamp)
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

    #[test_only]
    /// Fields of a `PoolFeesRefunded` for tests asserting that a refund is
    /// attributable to the order and maker it belongs to.
    public fun refunded_event_parts(self: &PoolFeesRefunded): (u64, u64, ID) {
        (self.order_id, self.amount, self.balance_manager_id)
    }

    public(package) fun emit_pool_fees_refunded<QuoteAsset>(
        pool_id: ID,
        order_id: u64,
        amount: u64,
        balance_manager_id: ID,
        timestamp: u64,
    ) {
        event::emit(PoolFeesRefunded {
            pool_id,
            quote_type: type_name::with_defining_ids<QuoteAsset>(),
            order_id,
            amount,
            balance_manager_id,
            timestamp,
        });
    }

    public(package) fun emit_pool_fees_withdrawn<QuoteAsset>(
        pool_id: ID,
        amount: u64,
        timestamp: u64,
    ) {
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

    /// Emitted when escrowed maker fees leave the reserve back to the maker on a
    /// cancel, modify-down or expiry. Carries the refunded amount only; the
    /// retained share stays in the reserve and is not re-emitted here.
    ///
    /// `order_id` ties this to the `OrderCanceled`, `OrderModified` or
    /// `OrderExpired` emitted for the same release, which carry both halves of the
    /// split. One order can produce several of these across its life: a
    /// modify-down each time it is cut, then a final cancel or expiry.
    public struct PoolFeesRefunded has copy, drop {
        pool_id: ID,
        quote_type: TypeName,
        order_id: u64,
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

    /// Bid-maker escrow currently held in the reserve, not yet earned.
    public(package) fun locked_maker_fees<BaseAsset, QuoteAsset>(
        self: &Vault<BaseAsset, QuoteAsset>,
    ): u64 {
        self.locked_maker_fees
    }

    /// Earned revenue in the reserve: what an admin sweep may take.
    public(package) fun withdrawable_quote_fees<BaseAsset, QuoteAsset>(
        self: &Vault<BaseAsset, QuoteAsset>,
    ): u64 {
        self.quote_fee_reserve.value() - self.locked_maker_fees
    }

    #[test_only]
    /// Mark quote already in the reserve as bid-maker escrow, standing in for a
    /// placement, so the locked-fee arithmetic can be exercised directly.
    public(package) fun lock_maker_fees_for_testing<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
        amount: u64,
    ) {
        self.locked_maker_fees = self.locked_maker_fees + amount;
    }

    /// Recognize bid-maker escrow as earned revenue once the order fills. The
    /// funds are already in the reserve; only their classification changes.
    public(package) fun recognize_locked_maker_fees<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
        amount: u64,
    ) {
        self.locked_maker_fees = self.locked_maker_fees - amount.min(self.locked_maker_fees);
    }

    /// Release bid-maker escrow back to the pool balance so it can settle out to
    /// the maker on a cancel, modify-down or expiry. The funds move
    /// `quote_fee_reserve` -> `quote_balance`, which is what makes the refund
    /// payable: settled quote comes from the pool balance, so crediting settled
    /// balances alone would pay the refund out of other users' principal.
    ///
    /// Must run before `settle_balance_manager` for the same transaction. The
    /// reserve is guaranteed to cover this — `locked_maker_fees` never exceeds
    /// the reserve, and the amount released never exceeds what the order locked.
    public(package) fun unlock_quote_fees<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
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
        emit_pool_fees_refunded<QuoteAsset>(
            pool_id,
            order_id,
            amount,
            balance_manager_id,
            timestamp,
        );
    }

    public(package) fun empty<BaseAsset, QuoteAsset>(): Vault<BaseAsset, QuoteAsset> {
        Vault {
            base_balance: balance::zero(),
            quote_balance: balance::zero(),
            cred_balance: balance::zero(),
            quote_fee_reserve: balance::zero(),
            locked_maker_fees: 0,
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
            let balance = balance_manager.withdraw_with_proof(
                trade_proof,
                balances_in.quote() - balances_out.quote(),
                false,
            );
            self.quote_balance.join(balance);
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
            ) = quote_fee_deposit_into_parts(deposit);
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

    /// Move already-held quote from the pool balance into the fee reserve.
    /// Used for fees charged out of quote proceeds (ask-taker and ask-maker
    /// fees), which never pass through a user withdrawal.
    public(package) fun move_quote_to_fee_reserve<BaseAsset, QuoteAsset>(
        self: &mut Vault<BaseAsset, QuoteAsset>,
        pool_id: ID,
        balance_manager_id: ID,
        amount: u64,
        timestamp: u64,
    ) {
        if (amount == 0) return;
        let fee_balance = self.quote_balance.split(amount);
        self.quote_fee_reserve.join(fee_balance);
        emit_pool_fees_deposited<QuoteAsset>(pool_id, amount, balance_manager_id, timestamp);
    }

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
        // Escrow backing open bid orders is not revenue and cannot be swept.
        assert!(amount <= self.withdrawable_quote_fees(), EFeesLocked);
        let fee_balance = self.quote_fee_reserve.split(amount);
        coin::from_balance(fee_balance, ctx)
    }
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
