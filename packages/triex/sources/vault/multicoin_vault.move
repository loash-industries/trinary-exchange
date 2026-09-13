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
        fee_basis::{Self, FeeBasis, EpochBasis},
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
    const EHubShareAboveCeiling: u64 = 9;

    // === Events ===
    /// A basis that aged out of the ring before anyone settled it. The amount
    /// stops being claimable and its holdback is released into the next treasury
    /// sweep — the settle-by deadline taking effect. Never silent: this is the
    /// record an operator reconciles a missing payment against.
    public struct HubBasisForfeited has copy, drop {
        pool_id: ID,
        collection_id: ID,
        epoch: u64,
        amount: u64,
    }

    /// One epoch's basis priced at that epoch's rate and moved into `hub_owed`.
    public struct HubShareSettled has copy, drop {
        pool_id: ID,
        collection_id: ID,
        epoch: u64,
        basis: u64,
        bps: u64,
        owed: u64,
    }

    /// `hub_owed` paid out to the beneficiary configured for the collection.
    public struct HubShareClaimed has copy, drop {
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
        /// The portion of `quote_fee_reserve` a hub operator has been priced into
        /// and may claim. Settled out of `hub_basis`, never written on a trade.
        hub_owed: u64,
        /// Revenue recognized on this pool that no one has priced into a share
        /// yet, bucketed by the epoch that earned it. Holds the basis rather than
        /// the split so the trading path never reads a rate — see `fee_basis`.
        hub_basis: FeeBasis,
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
            hub_owed: 0,
            hub_basis: fee_basis::empty(ctx.epoch()),
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

    /// Settled hub share awaiting a claim.
    public(package) fun hub_owed<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): u64 {
        self.hub_owed
    }

    /// Recognized revenue not yet priced into a share.
    public(package) fun hub_unsettled_basis<QuoteAsset>(
        self: &MultiCoinVault<QuoteAsset>,
    ): u128 {
        self.hub_basis.unsettled()
    }

    public(package) fun hub_basis_at<QuoteAsset>(
        self: &MultiCoinVault<QuoteAsset>,
        epoch: u64,
    ): u64 {
        self.hub_basis.basis_at(epoch)
    }

    /// What an unsettled basis could still turn into, priced at the ceiling.
    ///
    /// `withdraw_pool_fees` takes no `&FeePolicy` and so cannot know which slice
    /// of an unsettled basis is the operator's. It assumes the worst, at the
    /// compile-time bound. Rounded **up**: the settlement that consumes this
    /// basis rounds `owed` down, and the pair must not cross or
    /// `withdrawable_quote_fees` underflows by a unit. The over-lock disappears
    /// the moment anyone settles.
    public(package) fun hub_holdback<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): u128 {
        let unsettled = self.hub_basis.unsettled();
        if (unsettled == 0) return 0;

        let bps = constants::max_hub_share_bps() as u128;
        let precision = bps_precision();
        let product = unsettled * bps;
        // ceil, without a branch on the remainder being zero.
        (product + precision - 1) / precision
    }

    /// Everything in the reserve that is claimed by someone other than the
    /// treasury: a maker's refundable escrow, a settled hub share, and the
    /// provisional share of a basis nobody has settled yet.
    ///
    /// Every read of `quote_fee_reserve` that gates a payout goes through this.
    /// The invariant `reserve >= encumbered()` is what makes each of the three
    /// claims payable, and it is maintained by construction: a fee deposit raises
    /// the reserve by more than it raises this figure, recognition moves value
    /// from `locked` into a fraction of itself, an escrow refund lowers both by
    /// the same amount, settlement converts holdback into no more `hub_owed` than
    /// it releases, and every withdrawal is capped by the difference.
    public(package) fun encumbered<QuoteAsset>(self: &MultiCoinVault<QuoteAsset>): u128 {
        (self.locked_maker_fees as u128) + (self.hub_owed as u128) + self.hub_holdback()
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
    /// assert in `claim_hub_share`, where an operator would otherwise be paid coins
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

    fun bps_precision(): u128 {
        10000
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
    ///
    /// The hub basis is credited off the *actual* decrement, not `amount`. The two
    /// differ: recognition floors per fill while the lock floors once over the
    /// whole order, so a request can exceed what is still locked. Crediting the
    /// request would turn the residue drift documented on `locked_maker_fees` into
    /// a basis for revenue that was never recognized — an over-credit that
    /// compounds, and that the holdback would then subtract from a reserve that
    /// does not contain it.
    public(package) fun recognize_locked_maker_fees<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        pool_id: ID,
        amount: u64,
        epoch: u64,
    ) {
        let recognized = amount.min(self.locked_maker_fees);
        self.locked_maker_fees = self.locked_maker_fees - recognized;
        self.accrue_hub_basis(pool_id, recognized, epoch);
    }

    /// Credit recognized revenue to the epoch that earned it, and surface
    /// anything the roll forfeited. Every recognition point funnels through here.
    ///
    /// Deliberately emits nothing on the credit itself. An accrual event per
    /// recognition would land on the hottest path in the exchange — a fill with `N`
    /// maker matches recognizes `N + 1` times — for a feature that is off for every
    /// hub by default. Reconciliation does not need it: `HubShareSettled` carries
    /// each epoch's basis, rate and amount, `HubBasisForfeited` carries whatever
    /// aged out, and between them every unit of basis is accounted for exactly once.
    /// Deposit-level telemetry already exists in `PoolFeesDeposited`.
    fun accrue_hub_basis<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        pool_id: ID,
        amount: u64,
        epoch: u64,
    ) {
        let forfeited = self.hub_basis.accrue(epoch, amount);
        self.emit_forfeitures(pool_id, forfeited);
    }

    fun emit_forfeitures<QuoteAsset>(
        self: &MultiCoinVault<QuoteAsset>,
        pool_id: ID,
        forfeited: vector<EpochBasis>,
    ) {
        forfeited.do_ref!(|entry| event::emit(HubBasisForfeited {
            pool_id,
            collection_id: self.collection_id,
            epoch: entry.basis_epoch(),
            amount: entry.basis_amount(),
        }));
    }

    // === Hub share settlement ===

    /// Roll the basis ring forward without accruing, so a stale ring's
    /// forfeitures are recorded before a settlement reads it.
    public(package) fun roll_hub_basis<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        pool_id: ID,
        epoch: u64,
    ) {
        let forfeited = self.hub_basis.roll(epoch);
        self.emit_forfeitures(pool_id, forfeited);
    }

    /// Every epoch currently carrying basis, so the caller can price each at its
    /// own rate. The caller resolves rates; the vault holds no policy.
    public(package) fun pending_hub_basis<QuoteAsset>(
        self: &MultiCoinVault<QuoteAsset>,
    ): vector<EpochBasis> {
        self.hub_basis.pending()
    }

    /// Price one epoch's basis at that epoch's rate and move it into `hub_owed`.
    ///
    /// `owed` floors while `hub_holdback` ceils, so the holdback this releases is
    /// always at least the `hub_owed` it creates and `encumbered()` can only fall.
    /// That is the step the reserve invariant rests on.
    public(package) fun settle_hub_basis<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        pool_id: ID,
        epoch: u64,
        bps: u64,
    ): u64 {
        assert!(bps <= constants::max_hub_share_bps(), EHubShareAboveCeiling);

        let basis = self.hub_basis.take(epoch);
        if (basis == 0) return 0;

        let owed = (((basis as u128) * (bps as u128)) / bps_precision()) as u64;
        self.hub_owed = self.hub_owed + owed;

        event::emit(HubShareSettled {
            pool_id,
            collection_id: self.collection_id,
            epoch,
            basis,
            bps,
            owed,
        });

        owed
    }

    /// Pay the settled share out of the reserve. Zeroes `hub_owed` first so the
    /// split is measured against an already-decremented encumbrance.
    public(package) fun claim_hub_share<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        pool_id: ID,
        beneficiary: address,
        timestamp: u64,
        ctx: &mut TxContext,
    ): Coin<QuoteAsset> {
        let amount = self.hub_owed;
        self.hub_owed = 0;
        // Guaranteed by `reserve >= encumbered()`, which counts `hub_owed` in
        // full. Asserted rather than assumed: it is the invariant's payout edge.
        assert!(self.quote_fee_reserve.value() >= amount, EInsufficientFeeReserve);
        let share = self.quote_fee_reserve.split(amount);

        event::emit(HubShareClaimed {
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
            let epoch = ctx.epoch();
            self.move_quote_to_fee_reserve(
                pool_id,
                trading_account_id,
                taker_fee_amount + maker_fee_amount,
                epoch,
                timestamp,
            );
            // Only the maker portion is escrow; the taker fee is earned on
            // execution and immediately sweepable.
            self.locked_maker_fees = self.locked_maker_fees + maker_fee_amount;
            // The deposit above credited the whole fee to the basis, because from
            // inside it the escrow half is not distinguishable. Take it back out:
            // it re-enters through `recognize_locked_maker_fees` if and when the
            // order actually earns it. Same epoch, same transaction, so the bucket
            // it was just credited to is the one it comes out of.
            self.hub_basis.uncredit(epoch, maker_fee_amount);
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
    /// This is the shared *deposit* primitive, not a single recognition point.
    /// Two callers reach it with different money: the ask-proceeds loop moves fees
    /// already earned, while `settle_trading_account` moves a bid's
    /// `taker + maker` deposit, of which only the taker half is revenue. From in
    /// here the two are indistinguishable.
    ///
    /// So the basis is credited for the whole `amount`, and
    /// `settle_trading_account` takes the escrow half straight back out. Crediting
    /// only here and correcting at the one caller that knows better keeps a single
    /// rule — the basis moves where the reserve does — and means the ask path
    /// needs no instrumentation of its own.
    public(package) fun move_quote_to_fee_reserve<QuoteAsset>(
        self: &mut MultiCoinVault<QuoteAsset>,
        pool_id: ID,
        trading_account_id: ID,
        amount: u64,
        epoch: u64,
        timestamp: u64,
    ) {
        if (amount == 0) return;
        let fee_balance = self.quote_balance.split(amount);
        self.quote_fee_reserve.join(fee_balance);
        self.accrue_hub_basis(pool_id, amount, epoch);
        vault::emit_pool_fees_deposited<QuoteAsset>(
            pool_id,
            amount,
            trading_account_id,
            timestamp,
        );
    }

    #[test_only]
    /// Join quote straight into the fee reserve, bypassing both the escrow lock and
    /// the hub basis. No production caller — the reserve is only ever fed through
    /// `move_quote_to_fee_reserve`, which accrues. Kept for the suites that need to
    /// stand up reserve balances without a trade, and `#[test_only]` so wiring it
    /// into a real path cannot silently under-credit an operator.
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
