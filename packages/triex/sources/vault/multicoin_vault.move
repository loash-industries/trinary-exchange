/// MultiCoinVault implements the Dual Storage pattern for MultiCoin/Coin pools.
/// - Base assets: MultiCoin Balance objects stored via dynamic object fields
/// - Quote assets: Traditional Sui Balance<QuoteAsset>
/// - CRED: Traditional Sui Balance<CRED> for fee payments
module triex::multicoin_vault {
    use multicoin::multicoin::{Self, Balance as MultiCoinBalance};
    use sui::{
        balance::{Self, Balance},
        coin::{Self, Coin},
        dynamic_object_field as dof,
        event
    };
    use token::cred::CRED;
    use triex::{
        balances::Balances,
        constants,
        quote_fee,
        trading_account::{TradeProof, TradingAccount},
        vault
    };

    // === Errors ===
    const EInsufficientBaseBalance: u64 = 1;
    const EInsufficientQuoteBalance: u64 = 2;
    const EInsufficientCredBalance: u64 = 3;
    const EInsufficientFeeReserve: u64 = 5;
    const EFeesLocked: u64 = 6;
    const ENoBalanceToSettle: u64 = 7;
    const EHasOwedBalances: u64 = 8;
    const EOperatorShareAboveCeiling: u64 = 9;

    // === Events ===
    /// `operator_owed` paid out to the beneficiary configured for the collection.
    public struct OperatorShareClaimed has copy, drop {
        pool_id: ID,
        collection_id: ID,
        beneficiary: address,
        amount: u64,
        timestamp: u64,
    }

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
        /// The portion of `quote_fee_reserve` a hub operator may claim. Written
        /// eagerly, at the moment revenue is recognized: each recognition credits
        /// `floor(recognized × bps / 10000)` at the rate the policy resolves for
        /// the current epoch.
        ///
        /// Settled at all times — there is no provisional or unsettled state
        /// between a trade and a claim. That is a statement about *timing*, not
        /// about amount: the credit floors per recognition event, of which a
        /// single transaction can produce one per fill, so the figure sits below
        /// `bps` of the recognized total by up to one raw unit per event. The
        /// remainder stays in the reserve as treasury revenue — the share is
        /// never paid out of fees that were not collected.
        operator_owed: u64,
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
            operator_owed: 0,
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

    public(package) fun quote_fee_reserve_balance<QuoteAsset>(
        self: &MultiCoinVault<QuoteAsset>,
    ): u64 {
        self.quote_fee_reserve.value()
    }

    /// Bid-maker escrow currently held in the reserve, not yet earned.
    public(package) fun locked_maker_fees<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): u64 {
        self.locked_maker_fees
    }

    /// The hub operator's accrued, claimable share.
    public(package) fun operator_owed<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): u64 {
        self.operator_owed
    }

    /// Everything in the reserve that is claimed by someone other than the
    /// treasury: a maker's refundable escrow and the operator's accrued share.
    ///
    /// Every read of `quote_fee_reserve` that gates a payout goes through this.
    /// The invariant `reserve >= encumbered()` is what makes both claims
    /// payable, and it is maintained by construction: a fee deposit raises the
    /// reserve by at least the hub credit it produces (`floor(amount × bps)` with
    /// `bps ≤ 10000`), recognition moves value from `locked` into a fraction of
    /// itself, an escrow refund lowers reserve and `locked` by the same amount,
    /// and every withdrawal is capped by the difference.
    public(package) fun encumbered<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): u128 {
        (self.locked_maker_fees as u128) + (self.operator_owed as u128)
    }

    /// Earned revenue in the reserve: what an admin sweep may take.
    ///
    /// Saturates at zero rather than aborting if the encumbrance ever exceeds the
    /// reserve. That should be unreachable — every claim is matched by coins that
    /// entered the reserve — but this figure is also a public view and the cap on
    /// the admin sweep, and the two failure modes are not comparable: saturating
    /// can only make the treasury take *less*, while aborting would take the view
    /// and `withdraw_pool_fees` down permanently for the pool and leave indexers
    /// reading a reverting getter.
    ///
    /// A genuine shortfall still surfaces, in the one place where it must: the
    /// assert in `claim_operator_share`, where an operator would otherwise be paid coins
    /// the reserve does not hold. Failing loudly on the claim and quietly on the
    /// sweep puts the alarm on the side that would lose money.
    public(package) fun withdrawable_quote_fees<QuoteAsset>(
        self: &MultiCoinVault<QuoteAsset>,
    ): u64 {
        let reserve = self.quote_fee_reserve.value() as u128;
        let encumbered = self.encumbered();
        if (encumbered >= reserve) return 0;

        (reserve - encumbered) as u64
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
    /// funds are already in the reserve; only their classification changes, and
    /// the hub is credited its share of what was actually recognized.
    ///
    /// The credit is computed off the *actual* decrement, not `amount`. The two
    /// differ: recognition floors per fill while the lock floors once over the
    /// whole order, so a request can exceed what is still locked. Crediting the
    /// request would turn the residue drift documented on `locked_maker_fees`
    /// into a hub claim on revenue that was never recognized.
    public(package) fun recognize_locked_maker_fees<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        amount: u64,
        operator_bps: u64,
    ) {
        let recognized = amount.min(self.locked_maker_fees);
        self.locked_maker_fees = self.locked_maker_fees - recognized;
        self.credit_operator_share(recognized, operator_bps);
    }

    // === Operator share ===

    /// Credit the hub its share of revenue recognized this instant, at the rate
    /// the caller resolved from `&FeePolicy` for the current epoch.
    ///
    /// This is the only writer of `operator_owed` besides `claim_operator_share`, and it
    /// must be called with **recognized revenue only** — never a deposit that
    /// still contains refundable escrow. The three callers are the bid-taker fee
    /// after settlement, each proceeds fee, and the actual decrement inside
    /// `recognize_locked_maker_fees`.
    ///
    /// Deliberately emits nothing. A per-recognition event would land on the
    /// hottest path in the exchange — a fill with `N` maker matches recognizes
    /// `N + 1` times — for a feature that is off for every hub by default.
    /// `operator_owed()` is a published view and `OperatorShareClaimed` records every
    /// payout; deposit-level telemetry already exists in `PoolFeesDeposited`.
    ///
    /// **`owed <= amount` is what `reserve >= encumbered()` rests on**, and the
    /// clamp below is what makes it structural rather than inherited. Every
    /// caller credits against money that entered the reserve in the same call,
    /// so the invariant survives a credit exactly when the credit cannot exceed
    /// the deposit that funded it — which holds only while the rate is at most
    /// 100%. Nothing else in the codebase enforces that: it is the arithmetic
    /// relationship `MAX_OPERATOR_SHARE_BPS <= FEE_PRECISION` between two
    /// constants declared in two modules, and raising the ceiling past 100%
    /// reads like a configuration change while silently minting claims on coins
    /// that were never collected. That failure is unrecoverable and invisible:
    /// `withdrawable_quote_fees` saturates to zero, every claim and every sweep
    /// for the pool aborts, and trading carries on producing more of it.
    ///
    /// Clamped rather than asserted because an abort here lands on the fill
    /// path, and `fee_from_scaled_rate` and `operator_share_bps_at` both already
    /// clamp rather than abort on an out-of-range rate. The ceiling assert
    /// stays: it is the *policy* check, and the two are not the same bound —
    /// `max_operator_share_bps()` is a trust commitment that may be set anywhere
    /// at or below 100%, while `fee_precision()` is the solvency limit. A build
    /// that lets them cross is caught in `multicoin_vault_tests`, so the clamp
    /// is never reached in a correct build.
    public(package) fun credit_operator_share<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        amount: u64,
        operator_bps: u64,
    ) {
        if (amount == 0 || operator_bps == 0) return;
        // Belt over the policy's write-time assert and read-time clamp: a rate
        // above the ceiling must not mint a claim above it. Checked only when a
        // claim would actually be minted, so the default feature-off path
        // (bps = 0) pays nothing for it.
        assert!(operator_bps <= constants::max_operator_share_bps(), EOperatorShareAboveCeiling);

        let precision = quote_fee::fee_precision();
        let bps = operator_bps.min(precision);
        let owed = (((amount as u128) * (bps as u128)) / (precision as u128)) as u64;
        self.operator_owed = self.operator_owed + owed;
    }

    /// Pay the settled share out of the reserve. Zeroes `operator_owed` first so the
    /// split is measured against an already-decremented encumbrance.
    public(package) fun claim_operator_share<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        pool_id: ID,
        beneficiary: address,
        timestamp: u64,
        ctx: &mut TxContext,
    ): Coin<QuoteAsset> {
        let amount = self.operator_owed;
        self.operator_owed = 0;
        // Guaranteed by `reserve >= encumbered()`, which counts `operator_owed` in
        // full. Asserted rather than assumed: it is the invariant's payout edge.
        assert!(self.quote_fee_reserve.value() >= amount, EInsufficientFeeReserve);
        let share = self.quote_fee_reserve.split(amount);

        event::emit(OperatorShareClaimed {
            pool_id,
            collection_id: self.collection_id,
            beneficiary,
            amount,
            timestamp,
        });

        coin::from_balance(share, ctx)
    }

    /// Returns the collection_id this vault is associated with.
    public(package) fun collection_id<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): ID {
        self.collection_id
    }

    /// Returns the asset_id this vault is associated with.
    public(package) fun asset_id<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): u64 {
        self.asset_id
    }

    /// Transfer any settled amounts for the `trading_account`.
    /// Uses Balances struct for accounting (base/quote/cred as u64 deltas).
    public(package) fun settle_trading_account<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        balances_out: Balances,
        balances_in: Balances,
        trading_account: &mut TradingAccount,
        trade_proof: &TradeProof,
        quote_fee_deposit: Option<vault::QuoteFeeDeposit>,
        ctx: &mut TxContext,
    ) {
        trading_account.validate_proof(trade_proof);

        let key = MultiCoinBaseKey {
            collection_id: self.collection_id,
            asset_id: self.asset_id,
        };

        // === BASE (MultiCoin) settlements ===
        if (balances_out.base() > balances_in.base()) {
            // Vault owes user base tokens: split from vault, deposit to trading_account
            let amount = balances_out.base() - balances_in.base();
            let vault_base: &mut MultiCoinBalance = dof::borrow_mut(&mut self.id, key);
            assert!(vault_base.value() >= amount, EInsufficientBaseBalance);
            let to_deposit = vault_base.split(amount, ctx);
            trading_account.deposit_multicoin_with_proof(trade_proof, to_deposit, ctx);
        };
        if (balances_in.base() > balances_out.base()) {
            // User owes vault base tokens: withdraw from trading_account, join to vault
            let amount = balances_in.base() - balances_out.base();
            let withdrawn = trading_account.withdraw_multicoin_with_proof(
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
            trading_account.deposit_with_proof(trade_proof, to_deposit);
        };
        if (balances_in.quote() > balances_out.quote()) {
            let amount = balances_in.quote() - balances_out.quote();
            let withdrawn: Balance<QuoteAsset> = trading_account.withdraw_with_proof(
                trade_proof,
                amount,
                false,
            );
            self.quote_balance.join(withdrawn);
        };
        // Fee escrow is carved out of the pool's quote balance rather than out of
        // the marginal withdrawal above. The quote a user owes (fees included) is
        // retained by the pool either way — withdrawn from their trading account,
        // or netted against settled balances the pool therefore never paid out —
        // so the fee is covered even when prior settled balances cover the order
        // outright and nothing is withdrawn at all.
        if (option::is_some(&quote_fee_deposit)) {
            let deposit = quote_fee_deposit.destroy_some();
            let (
                pool_id,
                trading_account_id,
                taker_fee_amount,
                maker_fee_amount,
                timestamp,
            ) = vault::quote_fee_deposit_into_parts(deposit);
            self.move_quote_to_fee_reserve(
                pool_id,
                trading_account_id,
                taker_fee_amount + maker_fee_amount,
                timestamp,
            );
            // Only the maker portion is escrow; the taker fee is earned on
            // execution and immediately sweepable. The hub's share of the taker
            // half is credited by the pool right after this returns — the split
            // between the two halves is drawn here, the rate is the pool's to
            // resolve.
            self.locked_maker_fees = self.locked_maker_fees + maker_fee_amount;
        } else {
            option::destroy_none(quote_fee_deposit);
        };

        // === CRED settlements ===
        if (balances_out.cred() > balances_in.cred()) {
            let amount = balances_out.cred() - balances_in.cred();
            assert!(self.cred_balance.value() >= amount, EInsufficientCredBalance);
            let to_deposit = self.cred_balance.split(amount);
            trading_account.deposit_with_proof(trade_proof, to_deposit);
        };
        if (balances_in.cred() > balances_out.cred()) {
            let amount = balances_in.cred() - balances_out.cred();
            let withdrawn: Balance<CRED> = trading_account.withdraw_with_proof(
                trade_proof,
                amount,
                false,
            );
            self.cred_balance.join(withdrawn);
        };
    }

    /// Transfer any settled amounts for the `trading_account`.
    public(package) fun settle_trading_account_permissionless<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        balances_out: Balances,
        balances_in: Balances,
        trading_account: &mut TradingAccount,
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
            trading_account.deposit_multicoin_permissionless(to_deposit, ctx);
        };
        if (balances_out.quote() > 0) {
            let amount = balances_out.quote();
            assert!(self.quote_balance.value() >= amount, EInsufficientQuoteBalance);
            let balance = self.quote_balance.split(amount);
            trading_account.deposit_permissionless(balance);
        };
        if (balances_out.cred() > 0) {
            let amount = balances_out.cred();
            assert!(self.cred_balance.value() >= amount, EInsufficientCredBalance);
            let balance = self.cred_balance.split(amount);
            trading_account.deposit_permissionless(balance);
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
    ///
    /// This is the shared *deposit* primitive, not a recognition point — it
    /// credits no operator share. Two callers reach it with different money: the
    /// ask-proceeds loop moves fees already earned (and credits the hub itself,
    /// via `credit_operator_share`), while `settle_trading_account` moves a bid's
    /// `taker + maker` deposit, of which only the taker half is revenue. From in
    /// here the two are indistinguishable, which is exactly why the credit
    /// happens at the callers that know what the money is.
    public(package) fun move_quote_to_fee_reserve<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        pool_id: ID,
        trading_account_id: ID,
        amount: u64,
        timestamp: u64,
    ) {
        if (amount == 0) return;
        let fee_balance = self.quote_balance.split(amount);
        self.quote_fee_reserve.join(fee_balance);
        vault::emit_pool_fees_deposited<QuoteAsset>(
            pool_id,
            amount,
            trading_account_id,
            timestamp,
        );
    }

    #[test_only]
    /// Join quote straight into the fee reserve, bypassing both the escrow lock
    /// and the hub credit. No production caller — kept for the suites that need
    /// to stand up reserve balances without a trade, and `#[test_only]` so wiring
    /// it into a real path cannot silently under-credit an operator.
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
        trading_account_id: ID,
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
            trading_account_id,
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
}
