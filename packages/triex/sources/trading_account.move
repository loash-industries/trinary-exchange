/// The TradingAccount is a shared object that holds all of the balances for different assets. A combination of `TradingAccount` and
/// `TradeProof` are passed into a pool to perform trades. A `TradeProof` can be generated in two ways: by the
/// owner directly, or by any `TradeCap` owner. The owner can generate a `TradeProof` without the risk of
/// equivocation. The `TradeCap` owner, due to it being an owned object, risks equivocation when generating
/// a `TradeProof`. Generally, a high frequency trading engine will trade as the default owner.
module triex::trading_account {
    use multicoin::multicoin::{Self, Balance as MultiCoinBalance};
    use std::type_name::{Self, TypeName};
    use sui::{
        bag::{Self, Bag},
        balance::{Self, Balance},
        coin::Coin,
        dynamic_field as df,
        dynamic_object_field as dof,
        event,
        vec_set::{Self, VecSet}
    };
    use triex::{fee_turnover::{Self, EpochAmount, FeeTurnover}, registry::Registry};

    // use fun df::borrow as UID.borrow;
    // use fun df::exists_ as UID.exists_;
    // use fun df::remove_if_exists as UID.remove_if_exists;
    // use fun df::add as UID.add;

    // === Errors ===
    const EInvalidOwner: u64 = 0;
    const EInvalidTrader: u64 = 1;
    const EInvalidProof: u64 = 2;
    const ETradingAccountBalanceTooLow: u64 = 3;
    const EMaxCapsReached: u64 = 4;
    const ECapNotInList: u64 = 5;
    // #feat:refer
    // const EInvalidReferralOwner: u64 = 6;
    const EMultiCoinBalanceTooLow: u64 = 7;

    // === Constants ===
    const MAX_TRADE_CAPS: u64 = 1000;

    // === Structs ===
    /// A shared object that is passed into pools for placing orders.
    public struct TradingAccount has key, store {
        id: UID,
        owner: address,
        balances: Bag,
        allow_listed: VecSet<ID>,
    }

    /// Event emitted when a new trading_account is created.
    public struct TradingAccountEvent has copy, drop {
        trading_account_id: ID,
        owner: address,
    }

    /// Event emitted when a deposit or withdrawal occurs.
    public struct BalanceEvent has copy, drop {
        trading_account_id: ID,
        asset: TypeName,
        amount: u64,
        deposit: bool,
    }

    /// Event emitted when a MultiCoin deposit or withdrawal occurs.
    public struct MultiCoinBalanceEvent has copy, drop {
        trading_account_id: ID,
        collection_id: ID,
        asset_id: u64,
        amount: u64,
        deposit: bool,
    }

    /// Balance identifier for Coin types.
    public struct BalanceKey<phantom T> has copy, drop, store {}

    /// Balance identifier for MultiCoin assets, keyed by (collection_id, asset_id).
    public struct MultiCoinBalanceKey has copy, drop, store {
        collection_id: ID,
        asset_id: u64,
    }

    /// Owners of a `TradeCap` need to get a `TradeProof` to trade across pools in a single PTB (drops after).
    public struct TradeCap has key, store {
        id: UID,
        trading_account_id: ID,
    }

    /// `DepositCap` is used to deposit funds to a trading_account by a non-owner.
    public struct DepositCap has key, store {
        id: UID,
        trading_account_id: ID,
    }

    /// WithdrawCap is used to withdraw funds from a trading_account by a non-owner.
    public struct WithdrawCap has key, store {
        id: UID,
        trading_account_id: ID,
    }

    // #feat:refer
    // public struct TriexReferral has key, store {
    //     id: UID,
    //     owner: address,
    // }

    // #feat:refer
    // public struct TriexReferralCreatedEvent has copy, drop {
    //     referral_id: ID,
    //     owner: address,
    // }

    // #feat:refer
    // public struct TriexReferralSetEvent has copy, drop {
    //     referral_id: ID,
    //     trading_account_id: ID,
    // }

    /// TradingAccount owner and `TradeCap` owners can generate a `TradeProof`.
    /// `TradeProof` is used to validate the trading_account when trading on Triex.
    public struct TradeProof has drop {
        trading_account_id: ID,
        trader: address,
    }

    /// Key for the trailing fee-turnover ring this trading_account keeps per quote asset.
    ///
    /// The `TradingAccount` is the trader's exchange-wide identity — the same
    /// object enters every pool they trade on — so hosting the ring here is what
    /// makes tier progress exchange-wide: taker fees on any pool raise the
    /// trader's tier on every pool sharing that quote. One ring per quote asset,
    /// because turnover is a quote-unit sum and summing across quotes would be
    /// meaningless; the registry's quote-approval gate keeps the ring count small.
    ///
    /// The ring travels with the trading_account. A transferred trading_account carries its tier —
    /// deliberate: tier status is an asset of the trading_account, not the address.
    public struct TurnoverKey has copy, drop, store {
        quote: TypeName,
    }

    // === Public-Mutative Functions ===
    /// #ref:functions
    public fun new(ctx: &mut TxContext): TradingAccount {
        let id = object::new(ctx);
        event::emit(TradingAccountEvent {
            trading_account_id: id.to_inner(),
            owner: ctx.sender(),
        });

        TradingAccount {
            id,
            owner: ctx.sender(),
            balances: bag::new(ctx),
            allow_listed: vec_set::empty(),
        }
    }

    // #[deprecated(note = b"This function is deprecated, use `new_with_custom_owner` instead.")]
    // public fun new_with_owner(_ctx: &mut TxContext, _owner: address): TradingAccount {
    //     abort 1337
    // }

    /// Create a new trading account with an owner.
    /// #ref:functions
    public fun new_with_custom_owner(owner: address, ctx: &mut TxContext): TradingAccount {
        let id = object::new(ctx);
        event::emit(TradingAccountEvent {
            trading_account_id: id.to_inner(),
            owner,
        });

        TradingAccount {
            id,
            owner,
            balances: bag::new(ctx),
            allow_listed: vec_set::empty(),
        }
    }

    /// #ref:functions
    public fun new_with_custom_owner_and_caps(
        owner: address,
        ctx: &mut TxContext,
    ): (TradingAccount, DepositCap, WithdrawCap, TradeCap) {
        let mut trading_account = new_with_custom_owner(owner, ctx);

        let deposit_cap = mint_deposit_cap_internal(&mut trading_account, ctx);
        let withdraw_cap = mint_withdraw_cap_internal(&mut trading_account, ctx);
        let trade_cap = mint_trade_cap_internal(&mut trading_account, ctx);

        (trading_account, deposit_cap, withdraw_cap, trade_cap)
    }

    // #feat:refer
    // /// Set the referral for the trading account.
    // /// #ref:functions
    // public fun set_referral(
    //     trading_account: &mut TradingAccount,
    //     referral: &TriexReferral,
    //     trade_cap: &TradeCap,
    // ) {
    //     trading_account.validate_trader(trade_cap);
    //     let _: Option<ID> = trading_account.id.remove_if_exists(constants::referral_df_key());
    //     trading_account.id.add(constants::referral_df_key(), referral.id.to_inner());

    //     event::emit(TriexReferralSetEvent {
    //         referral_id: referral.id.to_inner(),
    //         trading_account_id: trading_account.id.to_inner(),
    //     });
    // }

    // #feat:refer
    // /// Unset the referral for the trading account.
    // /// #ref:functions
    // public fun unset_referral(trading_account: &mut TradingAccount, trade_cap: &TradeCap) {
    //     trading_account.validate_trader(trade_cap);
    //     let _: Option<ID> = trading_account.id.remove_if_exists(constants::referral_df_key());

    //     event::emit(TriexReferralSetEvent {
    //         referral_id: id_from_address(@0x0),
    //         trading_account_id: trading_account.id.to_inner(),
    //     });
    // }

    /// Returns the balance of a Coin in a trading account.
    public fun balance<T>(trading_account: &TradingAccount): u64 {
        let key = BalanceKey<T> {};
        if (!trading_account.balances.contains(key)) {
            0
        } else {
            let acc_balance: &Balance<T> = &trading_account.balances[key];
            acc_balance.value()
        }
    }

    /// Returns the balance of a MultiCoin asset in a trading account.
    public fun multicoin_balance(
        trading_account: &TradingAccount,
        collection_id: ID,
        asset_id: u64,
    ): u64 {
        let key = MultiCoinBalanceKey { collection_id, asset_id };
        if (!dof::exists_(&trading_account.id, key)) {
            0
        } else {
            let bal: &MultiCoinBalance = dof::borrow(&trading_account.id, key);
            bal.value()
        }
    }

    /// Mint a `TradeCap`, only owner can mint a `TradeCap`.
    /// #ref:functions
    public fun mint_trade_cap(trading_account: &mut TradingAccount, ctx: &mut TxContext): TradeCap {
        trading_account.validate_owner(ctx);
        trading_account.mint_trade_cap_internal(ctx)
    }

    /// Mint a `DepositCap`, only owner can mint.
    /// #ref:functions
    public fun mint_deposit_cap(
        trading_account: &mut TradingAccount,
        ctx: &mut TxContext,
    ): DepositCap {
        trading_account.validate_owner(ctx);
        trading_account.mint_deposit_cap_internal(ctx)
    }

    /// Mint a `WithdrawCap`, only owner can mint.
    /// #ref:functions
    public fun mint_withdraw_cap(
        trading_account: &mut TradingAccount,
        ctx: &mut TxContext,
    ): WithdrawCap {
        trading_account.validate_owner(ctx);
        trading_account.mint_withdraw_cap_internal(ctx)
    }

    /// Revoke a `TradeCap`. Only the owner can revoke a `TradeCap`.
    /// Can also be used to revoke `DepositCap` and `WithdrawCap`.
    /// #ref:functions
    public fun revoke_trade_cap(
        trading_account: &mut TradingAccount,
        trade_cap_id: &ID,
        ctx: &TxContext,
    ) {
        trading_account.validate_owner(ctx);

        assert!(trading_account.allow_listed.contains(trade_cap_id), ECapNotInList);
        trading_account.allow_listed.remove(trade_cap_id);
    }

    /// Generate a `TradeProof` by the owner. The owner does not require a capability
    /// and can generate TradeProofs without the risk of equivocation.
    /// #ref:functions
    public fun generate_proof_as_owner(
        trading_account: &mut TradingAccount,
        ctx: &TxContext,
    ): TradeProof {
        trading_account.validate_owner(ctx);

        TradeProof {
            trading_account_id: object::id(trading_account),
            trader: ctx.sender(),
        }
    }

    /// Generate a `TradeProof` with a `TradeCap`.
    /// Risk of equivocation since `TradeCap` is an owned object.
    /// #ref:functions
    public fun generate_proof_as_trader(
        trading_account: &mut TradingAccount,
        trade_cap: &TradeCap,
        ctx: &TxContext,
    ): TradeProof {
        trading_account.validate_trader(trade_cap);

        TradeProof {
            trading_account_id: object::id(trading_account),
            trader: ctx.sender(),
        }
    }

    /// Deposit funds to a trading account. Only owner can call this directly.
    /// #ref:functions
    public fun deposit<T>(
        trading_account: &mut TradingAccount,
        coin: Coin<T>,
        ctx: &mut TxContext,
    ) {
        trading_account.emit_balance_event(
            type_name::with_defining_ids<T>(),
            coin.value(),
            true,
        );

        let proof = trading_account.generate_proof_as_owner(ctx);
        trading_account.deposit_with_proof(&proof, coin.into_balance());
    }

    /// Deposit funds into a trading account by a `DepositCap` owner.
    /// #ref:functions
    public fun deposit_with_cap<T>(
        trading_account: &mut TradingAccount,
        deposit_cap: &DepositCap,
        coin: Coin<T>,
        ctx: &TxContext,
    ) {
        trading_account.emit_balance_event(
            type_name::with_defining_ids<T>(),
            coin.value(),
            true,
        );

        let proof = trading_account.generate_proof_as_depositor(deposit_cap, ctx);
        trading_account.deposit_with_proof(&proof, coin.into_balance());
    }

    /// Withdraw funds from a trading account by a `WithdrawCap` owner.
    /// #ref:functions
    public fun withdraw_with_cap<T>(
        trading_account: &mut TradingAccount,
        withdraw_cap: &WithdrawCap,
        withdraw_amount: u64,
        ctx: &mut TxContext,
    ): Coin<T> {
        let proof = trading_account.generate_proof_as_withdrawer(
            withdraw_cap,
            ctx,
        );
        let coin = trading_account
            .withdraw_with_proof(&proof, withdraw_amount, false)
            .into_coin(ctx);
        trading_account.emit_balance_event(
            type_name::with_defining_ids<T>(),
            coin.value(),
            false,
        );

        coin
    }

    /// Withdraw funds from a trading_account. Only owner can call this directly.
    /// If withdraw_all is true, amount is ignored and full balance withdrawn.
    /// If withdraw_all is false, withdraw_amount will be withdrawn.
    /// #ref:functions
    public fun withdraw<T>(
        trading_account: &mut TradingAccount,
        withdraw_amount: u64,
        ctx: &mut TxContext,
    ): Coin<T> {
        let proof = generate_proof_as_owner(trading_account, ctx);
        let coin = trading_account
            .withdraw_with_proof(&proof, withdraw_amount, false)
            .into_coin(ctx);
        trading_account.emit_balance_event(
            type_name::with_defining_ids<T>(),
            coin.value(),
            false,
        );

        coin
    }

    /// #ref:functions
    public fun withdraw_all<T>(trading_account: &mut TradingAccount, ctx: &mut TxContext): Coin<T> {
        let proof = generate_proof_as_owner(trading_account, ctx);
        let coin = trading_account.withdraw_with_proof(&proof, 0, true).into_coin(ctx);
        trading_account.emit_balance_event(
            type_name::with_defining_ids<T>(),
            coin.value(),
            false,
        );

        coin
    }

    // === MultiCoin Functions ===

    /// Deposit a MultiCoin Balance to a trading account. Only owner can call this directly.
    /// #ref:functions
    public fun deposit_multicoin(
        trading_account: &mut TradingAccount,
        multicoin_balance: MultiCoinBalance,
        ctx: &mut TxContext,
    ) {
        trading_account.emit_multicoin_balance_event(
            multicoin_balance.collection_id(),
            multicoin_balance.asset_id(),
            multicoin_balance.value(),
            true,
        );

        let proof = trading_account.generate_proof_as_owner(ctx);
        trading_account.deposit_multicoin_with_proof(&proof, multicoin_balance, ctx);
    }

    /// Deposit a MultiCoin Balance into a trading account by a `DepositCap` owner.
    /// #ref:functions
    public fun deposit_multicoin_with_cap(
        trading_account: &mut TradingAccount,
        deposit_cap: &DepositCap,
        multicoin_balance: MultiCoinBalance,
        ctx: &mut TxContext,
    ) {
        trading_account.emit_multicoin_balance_event(
            multicoin_balance.collection_id(),
            multicoin_balance.asset_id(),
            multicoin_balance.value(),
            true,
        );

        let proof = trading_account.generate_proof_as_depositor(deposit_cap, ctx);
        trading_account.deposit_multicoin_with_proof(&proof, multicoin_balance, ctx);
    }

    /// Withdraw a MultiCoin Balance from a trading account. Only owner can call this directly.
    /// #ref:functions
    public fun withdraw_multicoin(
        trading_account: &mut TradingAccount,
        collection_id: ID,
        asset_id: u64,
        withdraw_amount: u64,
        ctx: &mut TxContext,
    ): MultiCoinBalance {
        let proof = generate_proof_as_owner(trading_account, ctx);
        let bal = trading_account.withdraw_multicoin_with_proof(
            &proof,
            collection_id,
            asset_id,
            withdraw_amount,
            false,
            ctx,
        );
        trading_account.emit_multicoin_balance_event(
            collection_id,
            asset_id,
            bal.value(),
            false,
        );

        bal
    }

    /// Withdraw all MultiCoin Balance from a trading account. Only owner can call this directly.
    /// #ref:functions
    public fun withdraw_all_multicoin(
        trading_account: &mut TradingAccount,
        collection_id: ID,
        asset_id: u64,
        ctx: &mut TxContext,
    ): MultiCoinBalance {
        let proof = generate_proof_as_owner(trading_account, ctx);
        let bal = trading_account.withdraw_multicoin_with_proof(
            &proof,
            collection_id,
            asset_id,
            0,
            true,
            ctx,
        );
        trading_account.emit_multicoin_balance_event(
            collection_id,
            asset_id,
            bal.value(),
            false,
        );

        bal
    }

    /// Withdraw a MultiCoin Balance from a trading account by a `WithdrawCap` owner.
    /// #ref:functions
    public fun withdraw_multicoin_with_cap(
        trading_account: &mut TradingAccount,
        withdraw_cap: &WithdrawCap,
        collection_id: ID,
        asset_id: u64,
        withdraw_amount: u64,
        ctx: &mut TxContext,
    ): MultiCoinBalance {
        let proof = trading_account.generate_proof_as_withdrawer(withdraw_cap, ctx);
        let bal = trading_account.withdraw_multicoin_with_proof(
            &proof,
            collection_id,
            asset_id,
            withdraw_amount,
            false,
            ctx,
        );
        trading_account.emit_multicoin_balance_event(
            collection_id,
            asset_id,
            bal.value(),
            false,
        );

        bal
    }

    /// #ref:functions
    public fun register_trading_account(trading_account: &TradingAccount, registry: &mut Registry) {
        let owner = trading_account.owner();
        let trading_account_id = trading_account.id();
        registry.add_trading_account(owner, trading_account_id);
    }

    public fun validate_proof(trading_account: &TradingAccount, proof: &TradeProof) {
        assert!(object::id(trading_account) == proof.trading_account_id, EInvalidProof);
    }

    /// Returns the owner of the trading_account.
    public fun owner(trading_account: &TradingAccount): address {
        trading_account.owner
    }

    /// Returns the owner of the trading_account.
    public fun id(trading_account: &TradingAccount): ID {
        trading_account.id.to_inner()
    }

    // #feat:refer
    // public fun referral_owner(referral: &TriexReferral): address {
    //     referral.owner
    // }

    // === Public-Package Functions ===
    /// Fold pending maker-fee credits into this trading_account's ring for `QuoteAsset`
    /// and return the trailing turnover total. Every trade calls this before
    /// pricing, so the total it returns is exactly what the tier resolves against.
    ///
    /// Rolls the ring to the current epoch first, then lands each entry in the
    /// bucket of the epoch it was earned in — folding is exact, not approximate.
    /// Entries that already aged out of the window are dropped inside `record_at`.
    public(package) fun fold_fee_turnover<QuoteAsset>(
        trading_account: &mut TradingAccount,
        pending: vector<EpochAmount>,
        ctx: &TxContext,
    ): u128 {
        let ring = trading_account.turnover_ring_mut<QuoteAsset>(ctx);
        ring.roll(ctx.epoch());
        pending.do_ref!(|entry| ring.record_at(entry.entry_epoch(), entry.entry_amount()));

        ring.total()
    }

    /// Credit taker fees the moment they are recognized — the taker's own
    /// transaction carries this trading_account, so no pending step is needed. Called
    /// after pricing, which is what keeps an order from discounting itself.
    public(package) fun record_fee_turnover<QuoteAsset>(
        trading_account: &mut TradingAccount,
        amount: u64,
        ctx: &TxContext,
    ) {
        if (amount == 0) return;

        let ring = trading_account.turnover_ring_mut<QuoteAsset>(ctx);
        ring.roll(ctx.epoch());
        ring.record(amount);
    }

    /// Trailing turnover in `QuoteAsset` units as of the current epoch, without
    /// mutating. A trading_account that has never been credited has none. Read-only
    /// callers get the aged view via `total_at`, so a dormant trading_account is not
    /// reported holding a tier that has already rolled off.
    public fun fee_turnover<QuoteAsset>(trading_account: &TradingAccount, ctx: &TxContext): u128 {
        let key = TurnoverKey { quote: type_name::with_defining_ids<QuoteAsset>() };
        if (!df::exists_(&trading_account.id, key)) return 0;

        let ring: &FeeTurnover = df::borrow(&trading_account.id, key);
        ring.total_at(ctx.epoch())
    }

    /// Detach the ring for `QuoteAsset`, for the trading_account-less swap path: the
    /// temporary trading_account it mints is deleted at the end of the transaction, and a
    /// dynamic field left attached would leak.
    public(package) fun remove_fee_turnover<QuoteAsset>(trading_account: &mut TradingAccount) {
        let key = TurnoverKey { quote: type_name::with_defining_ids<QuoteAsset>() };
        if (df::exists_(&trading_account.id, key)) {
            let _ring: FeeTurnover = df::remove(&mut trading_account.id, key);
        };
    }

    fun turnover_ring_mut<QuoteAsset>(
        trading_account: &mut TradingAccount,
        ctx: &TxContext,
    ): &mut FeeTurnover {
        let key = TurnoverKey { quote: type_name::with_defining_ids<QuoteAsset>() };
        if (!df::exists_(&trading_account.id, key)) {
            df::add(&mut trading_account.id, key, fee_turnover::empty(ctx.epoch()));
        };

        df::borrow_mut(&mut trading_account.id, key)
    }

    // #feat:refer
    // /// Mint a `TriexReferral` and share it.
    // public(package) fun mint_referral(ctx: &mut TxContext): ID {
    //     let id = object::new(ctx);
    //     let referral_id = id.to_inner();
    //     let referral = TriexReferral {
    //         id,
    //         owner: ctx.sender(),
    //     };

    //     event::emit(TriexReferralCreatedEvent {
    //         referral_id,
    //         owner: ctx.sender(),
    //     });

    //     transfer::share_object(referral);

    //     referral_id
    // }

    // #feat:refer
    // /// Get the referral id from the trading account.
    // public(package) fun get_referral_id(trading_account: &TradingAccount): Option<ID> {
    //     let ref_key = constants::referral_df_key();
    //     if (!trading_account.id.exists_(ref_key)) {
    //         return option::none()
    //     };
    //     let referral_id: &ID = trading_account.id.borrow(ref_key);

    //     option::some(*referral_id)
    // }

    // #feat:refer
    // public(package) fun assert_referral_owner(referral: &TriexReferral, ctx: &TxContext) {
    //     assert!(ctx.sender() == referral.owner, EInvalidReferralOwner);
    // }

    /// Deposit funds to a trading_account. Pool will call this to deposit funds.
    public(package) fun deposit_with_proof<T>(
        trading_account: &mut TradingAccount,
        proof: &TradeProof,
        to_deposit: Balance<T>,
    ) {
        trading_account.validate_proof(proof);

        let key = BalanceKey<T> {};

        if (trading_account.balances.contains(key)) {
            let balance: &mut Balance<T> = &mut trading_account.balances[key];
            balance.join(to_deposit);
        } else {
            trading_account.balances.add(key, to_deposit);
        }
    }

    /// Deposit funds to a trading_account. Pool will call this to deposit funds.
    /// This function is used by withdraw_settled_amounts_permissionless to deposit funds.
    public(package) fun deposit_permissionless<T>(
        trading_account: &mut TradingAccount,
        to_deposit: Balance<T>,
    ) {
        let key = BalanceKey<T> {};

        if (trading_account.balances.contains(key)) {
            let balance: &mut Balance<T> = &mut trading_account.balances[key];
            balance.join(to_deposit);
        } else {
            trading_account.balances.add(key, to_deposit);
        }
    }

    /// Deposit MultiCoin funds to a trading_account.
    /// This function is used by MultiCoinPool permissionless settlement.
    public(package) fun deposit_multicoin_permissionless(
        trading_account: &mut TradingAccount,
        to_deposit: MultiCoinBalance,
        ctx: &TxContext,
    ) {
        let collection_id = to_deposit.collection_id();
        let asset_id = to_deposit.asset_id();
        let key = MultiCoinBalanceKey { collection_id, asset_id };

        if (dof::exists_(&trading_account.id, key)) {
            let existing: &mut MultiCoinBalance = dof::borrow_mut(&mut trading_account.id, key);
            existing.join(to_deposit, ctx);
        } else {
            dof::add(&mut trading_account.id, key, to_deposit);
        };
    }

    /// Generate a `TradeProof` by a `DepositCap` owner.
    public(package) fun generate_proof_as_depositor(
        trading_account: &TradingAccount,
        deposit_cap: &DepositCap,
        ctx: &TxContext,
    ): TradeProof {
        trading_account.validate_deposit_cap(deposit_cap);

        TradeProof {
            trading_account_id: object::id(trading_account),
            trader: ctx.sender(),
        }
    }

    /// Generate a `TradeProof` by a `WithdrawCap` owner.
    public(package) fun generate_proof_as_withdrawer(
        trading_account: &TradingAccount,
        withdraw_cap: &WithdrawCap,
        ctx: &TxContext,
    ): TradeProof {
        trading_account.validate_withdraw_cap(withdraw_cap);

        TradeProof {
            trading_account_id: object::id(trading_account),
            trader: ctx.sender(),
        }
    }

    /// Withdraw funds from a trading_account. Pool will call this to withdraw funds.
    public(package) fun withdraw_with_proof<T>(
        trading_account: &mut TradingAccount,
        proof: &TradeProof,
        withdraw_amount: u64,
        withdraw_all: bool,
    ): Balance<T> {
        trading_account.validate_proof(proof);

        let key = BalanceKey<T> {};
        let key_exists = trading_account.balances.contains(key);
        if (withdraw_all) {
            if (key_exists) {
                trading_account.balances.remove(key)
            } else {
                balance::zero()
            }
        } else {
            assert!(key_exists, ETradingAccountBalanceTooLow);
            let acc_balance: &mut Balance<T> = &mut trading_account.balances[key];
            let acc_value = acc_balance.value();
            assert!(acc_value >= withdraw_amount, ETradingAccountBalanceTooLow);
            if (withdraw_amount == acc_value) {
                trading_account.balances.remove(key)
            } else {
                acc_balance.split(withdraw_amount)
            }
        }
    }

    /// Deletes a trading_account.
    /// This is used for deleting temporary trading_accounts for direct swap with pool.
    public(package) fun delete(trading_account: TradingAccount) {
        let TradingAccount {
            id,
            owner: _,
            balances,
            allow_listed: _,
        } = trading_account;

        id.delete();
        balances.destroy_empty();
    }

    public(package) fun trader(trade_proof: &TradeProof): address {
        trade_proof.trader
    }

    public(package) fun emit_balance_event(
        trading_account: &TradingAccount,
        asset: TypeName,
        amount: u64,
        deposit: bool,
    ) {
        event::emit(BalanceEvent {
            trading_account_id: trading_account.id(),
            asset,
            amount,
            deposit,
        });
    }

    public(package) fun emit_multicoin_balance_event(
        trading_account: &TradingAccount,
        collection_id: ID,
        asset_id: u64,
        amount: u64,
        deposit: bool,
    ) {
        event::emit(MultiCoinBalanceEvent {
            trading_account_id: trading_account.id(),
            collection_id,
            asset_id,
            amount,
            deposit,
        });
    }

    /// Deposit a MultiCoin Balance to a trading_account. Pool will call this to deposit funds.
    public(package) fun deposit_multicoin_with_proof(
        trading_account: &mut TradingAccount,
        proof: &TradeProof,
        to_deposit: MultiCoinBalance,
        ctx: &TxContext,
    ) {
        trading_account.validate_proof(proof);

        let collection_id = to_deposit.collection_id();
        let asset_id = to_deposit.asset_id();
        let key = MultiCoinBalanceKey { collection_id, asset_id };

        if (dof::exists_(&trading_account.id, key)) {
            let existing: &mut MultiCoinBalance = dof::borrow_mut(&mut trading_account.id, key);
            existing.join(to_deposit, ctx);
        } else {
            dof::add(&mut trading_account.id, key, to_deposit);
        }
    }

    /// Withdraw a MultiCoin Balance from a trading_account. Pool will call this to withdraw funds.
    public(package) fun withdraw_multicoin_with_proof(
        trading_account: &mut TradingAccount,
        proof: &TradeProof,
        collection_id: ID,
        asset_id: u64,
        withdraw_amount: u64,
        withdraw_all: bool,
        ctx: &mut TxContext,
    ): MultiCoinBalance {
        trading_account.validate_proof(proof);

        let key = MultiCoinBalanceKey { collection_id, asset_id };
        let key_exists = dof::exists_(&trading_account.id, key);

        if (withdraw_all) {
            if (key_exists) {
                dof::remove(&mut trading_account.id, key)
            } else {
                multicoin::zero(collection_id, asset_id, ctx)
            }
        } else {
            assert!(key_exists, EMultiCoinBalanceTooLow);
            let acc_balance: &mut MultiCoinBalance = dof::borrow_mut(&mut trading_account.id, key);
            let acc_value = acc_balance.value();
            assert!(acc_value >= withdraw_amount, EMultiCoinBalanceTooLow);
            if (withdraw_amount == acc_value) {
                dof::remove(&mut trading_account.id, key)
            } else {
                acc_balance.split(withdraw_amount, ctx)
            }
        }
    }

    // === Private Functions ===
    fun mint_trade_cap_internal(
        trading_account: &mut TradingAccount,
        ctx: &mut TxContext,
    ): TradeCap {
        assert!(trading_account.allow_listed.length() < MAX_TRADE_CAPS, EMaxCapsReached);

        let id = object::new(ctx);
        trading_account.allow_listed.insert(id.to_inner());

        TradeCap {
            id,
            trading_account_id: object::id(trading_account),
        }
    }

    fun mint_deposit_cap_internal(
        trading_account: &mut TradingAccount,
        ctx: &mut TxContext,
    ): DepositCap {
        assert!(trading_account.allow_listed.length() < MAX_TRADE_CAPS, EMaxCapsReached);

        let id = object::new(ctx);
        trading_account.allow_listed.insert(id.to_inner());

        DepositCap {
            id,
            trading_account_id: object::id(trading_account),
        }
    }

    fun mint_withdraw_cap_internal(
        trading_account: &mut TradingAccount,
        ctx: &mut TxContext,
    ): WithdrawCap {
        assert!(trading_account.allow_listed.length() < MAX_TRADE_CAPS, EMaxCapsReached);

        let id = object::new(ctx);
        trading_account.allow_listed.insert(id.to_inner());

        WithdrawCap {
            id,
            trading_account_id: object::id(trading_account),
        }
    }

    fun validate_owner(trading_account: &TradingAccount, ctx: &TxContext) {
        assert!(ctx.sender() == trading_account.owner(), EInvalidOwner);
    }

    fun validate_trader(trading_account: &TradingAccount, trade_cap: &TradeCap) {
        assert!(
            trading_account.allow_listed.contains(object::borrow_id(trade_cap)),
            EInvalidTrader,
        );
    }

    fun validate_deposit_cap(trading_account: &TradingAccount, deposit_cap: &DepositCap) {
        assert!(
            trading_account.allow_listed.contains(object::borrow_id(deposit_cap)),
            EInvalidTrader,
        );
    }

    fun validate_withdraw_cap(trading_account: &TradingAccount, withdraw_cap: &WithdrawCap) {
        assert!(
            trading_account.allow_listed.contains(object::borrow_id(withdraw_cap)),
            EInvalidTrader,
        );
    }
}
