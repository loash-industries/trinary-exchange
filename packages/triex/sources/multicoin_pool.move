// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// MultiCoinPool implements trading pools where:
/// - Base asset: MultiCoin Balance identified by (collection_id, asset_id)
/// - Quote asset: Traditional Sui Coin<QuoteAsset>
///
/// This is the MultiCoin equivalent of Pool<BaseAsset, QuoteAsset>.
module triexbook::multicoin_pool;

use multicoin::multicoin::{Self, Collection};
use std::type_name::{Self, TypeName};
use sui::{
    clock::Clock,
    coin::{Self, Coin},
    event,
    vec_set::{Self, VecSet},
    versioned::{Self, Versioned}
};
use token::cred::{CRED, ProtectedTreasury};
use triexbook::{
    account::Account,
    balance_manager::{Self, BalanceManager, TradeProof, TradeCap, DepositCap, WithdrawCap},
    book::{Self, Book},
    constants,
    fee_schedule::{Self, FeeSchedule},
    multicoin_vault::{Self, MultiCoinVault},
    order::Order,
    order_info::{Self, OrderInfo},
    registry::{TriexbookAdminCap, Registry},
    state::{Self, State},
    vault
};

// === Errors ===
const EInvalidFee: u64 = 1;
const EInvalidQuantityIn: u64 = 8;
const EInvalidOrderBalanceManager: u64 = 9;
const EPackageVersionDisabled: u64 = 11;
const EMinimumQuantityOutNotMet: u64 = 13;
const EPoolNotRegistered: u64 = 14;
const EQuoteNotApproved: u64 = 20;
// qty × price (raw) would exceed u64::MAX — lower the quantity or price.

// === Structs ===

/// MultiCoinPool for trading MultiCoin assets against Coin<QuoteAsset>.
/// Unlike Pool<Base, Quote>, base asset is identified at runtime by collection_id + asset_id.
public struct MultiCoinPool<phantom QuoteAsset> has key {
    id: UID,
    inner: Versioned,
}

public struct MultiCoinPoolInner<phantom QuoteAsset> has store {
    allowed_versions: VecSet<u64>,
    pool_id: ID,
    /// The MultiCoin collection this pool trades
    collection_id: ID,
    /// The specific asset_id within the collection
    asset_id: u64,
    /// Quote currency type name (for registry/validation)
    quote_type: TypeName,
    book: Book,
    state: State,
    vault: MultiCoinVault<QuoteAsset>,
    registered_pool: bool,
}

public struct MultiCoinPoolCreated<phantom QuoteAsset> has copy, drop, store {
    pool_id: ID,
    collection_id: ID,
    asset_id: u64,
    taker_fee: u64,
    maker_fee: u64,
    treasury_address: address,
}

public struct MultiCoinCredBurned<phantom QuoteAsset> has copy, drop, store {
    pool_id: ID,
    cred_burned: u64,
}

// === Public-Mutative Functions * POOL CREATION * ===

/// Create a new permissionless MultiCoin pool with a creation fee.
/// Returns the id of the pool created.
/// #ref:functions
public fun create_permissionless_pool<QuoteAsset>(
    registry: &mut Registry,
    collection: &Collection,
    asset_id: u64,
    creation_fee: Coin<CRED>,
    ctx: &mut TxContext,
): ID {
    assert!(creation_fee.value() == constants::pool_creation_fee(), EInvalidFee);
    create_pool<QuoteAsset>(
        registry,
        collection,
        asset_id,
        creation_fee,
        ctx,
    )
}

/// Create a new MultiCoin pool (package-level).
/// Returns the id of the pool created.
/// #ref:functions
public(package) fun create_pool<QuoteAsset>(
    registry: &mut Registry,
    collection: &Collection,
    asset_id: u64,
    creation_fee: Coin<CRED>,
    ctx: &mut TxContext,
): ID {
    // Derive collection_id from the on-chain Collection object — any collection is valid.
    let collection_id = object::id(collection);

    // Check if quote currency is approved for pool creation
    let quote_type = type_name::with_defining_ids<QuoteAsset>();
    assert!(registry.is_quote_approved(quote_type), EQuoteNotApproved);

    let pool_id = object::new(ctx);
    let pool_inner = MultiCoinPoolInner<QuoteAsset> {
        allowed_versions: registry.allowed_versions(),
        pool_id: pool_id.to_inner(),
        collection_id,
        asset_id,
        quote_type,
        book: book::empty_multicoin(ctx),
        state: state::empty_multicoin(ctx),
        vault: multicoin_vault::empty(collection_id, asset_id, ctx),
        registered_pool: true,
    };
    let params = pool_inner.state.governance().trade_params();
    let taker_fee = params.taker_fee();
    let maker_fee = params.maker_fee();
    let treasury_address = registry.treasury_address();
    let pool = MultiCoinPool<QuoteAsset> {
        id: pool_id,
        inner: versioned::create(constants::current_version(), pool_inner, ctx),
    };
    let pool_id = object::id(&pool);

    // Register the pool in the registry
    registry.register_multicoin_pool<QuoteAsset>(collection_id, asset_id, pool_id, ctx);

    event::emit(MultiCoinPoolCreated<QuoteAsset> {
        pool_id,
        collection_id,
        asset_id,
        taker_fee,
        maker_fee,
        treasury_address,
    });

    transfer::public_transfer(creation_fee, treasury_address);
    transfer::share_object(pool);

    pool_id
}

/// Admin version of create_pool (no creation fee).
/// #ref:functions
public fun create_pool_admin<QuoteAsset>(
    registry: &mut Registry,
    collection: &Collection,
    asset_id: u64,
    _cap: &TriexbookAdminCap,
    ctx: &mut TxContext,
): ID {
    let creation_fee = coin::zero(ctx);
    create_pool<QuoteAsset>(
        registry,
        collection,
        asset_id,
        creation_fee,
        ctx,
    )
}

// === Public-Mutative Functions * EXCHANGE * ===

/// Place a limit order. Quantity is in base asset (MultiCoin) terms.
/// Fees are quote-denominated.
/// #ref:functions
public fun place_limit_order<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    self.place_limit_order_with_quote_fees(
        balance_manager,
        trade_proof,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        expire_timestamp,
        clock,
        ctx,
    )
}

public fun place_limit_order_with_quote_fees<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    self.place_order_int(
        balance_manager,
        trade_proof,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        expire_timestamp,
        clock,
        false,
        ctx,
    )
}

/// Place a market order. Quantity is in base asset (MultiCoin) terms.
/// #ref:functions
public fun place_market_order<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    self.place_market_order_with_quote_fees(
        balance_manager,
        trade_proof,
        self_matching_option,
        quantity,
        is_bid,
        clock,
        ctx,
    )
}

public fun place_market_order_with_quote_fees<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo {
    self.place_order_int(
        balance_manager,
        trade_proof,
        constants::immediate_or_cancel(),
        self_matching_option,
        if (is_bid) constants::max_price() else constants::min_price(),
        quantity,
        is_bid,
        clock.timestamp_ms(),
        clock,
        true,
        ctx,
    )
}

// === Public-Mutative Functions * SWAP * ===

/// Swap exact base (MultiCoin) for quote without needing a balance_manager.
/// Returns the leftover MultiCoin base, quote Coin received, and leftover CRED (returned unchanged).
/// #ref:functions
public fun swap_exact_base_for_quote<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    base_in: multicoin::Balance,
    cred_in: Coin<CRED>,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (multicoin::Balance, Coin<QuoteAsset>, Coin<CRED>) {
    let quote_in = coin::zero(ctx);
    let collection_id = self.load_inner().collection_id;
    let asset_id = self.load_inner().asset_id;

    self.swap_exact_quantity(
        base_in,
        quote_in,
        cred_in,
        min_quote_out,
        collection_id,
        asset_id,
        clock,
        ctx,
    )
}

/// Swap exact base (MultiCoin) for quote with a balance_manager.
/// Fees are quote-denominated.
/// #ref:functions
public fun swap_exact_base_for_quote_with_manager<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_cap: &TradeCap,
    deposit_cap: &DepositCap,
    withdraw_cap: &WithdrawCap,
    base_in: multicoin::Balance,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (multicoin::Balance, Coin<QuoteAsset>) {
    let quote_in = coin::zero(ctx);
    let collection_id = self.load_inner().collection_id;
    let asset_id = self.load_inner().asset_id;

    self.swap_exact_quantity_with_manager(
        balance_manager,
        trade_cap,
        deposit_cap,
        withdraw_cap,
        base_in,
        quote_in,
        min_quote_out,
        collection_id,
        asset_id,
        clock,
        ctx,
    )
}

/// Swap exact quote quantity for base (MultiCoin) without needing a balance_manager.
/// Returns leftover MultiCoin base, leftover quote, and leftover CRED (returned unchanged).
/// #ref:functions
public fun swap_exact_quote_for_base<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    quote_in: Coin<QuoteAsset>,
    cred_in: Coin<CRED>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (multicoin::Balance, Coin<QuoteAsset>, Coin<CRED>) {
    let collection_id = self.load_inner().collection_id;
    let asset_id = self.load_inner().asset_id;
    let base_in = multicoin::zero(collection_id, asset_id, ctx);

    self.swap_exact_quantity(
        base_in,
        quote_in,
        cred_in,
        min_base_out,
        collection_id,
        asset_id,
        clock,
        ctx,
    )
}

/// Swap exact quote for base (MultiCoin) with a balance_manager.
/// Fees are quote-denominated.
/// #ref:functions
public fun swap_exact_quote_for_base_with_manager<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_cap: &TradeCap,
    deposit_cap: &DepositCap,
    withdraw_cap: &WithdrawCap,
    quote_in: Coin<QuoteAsset>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (multicoin::Balance, Coin<QuoteAsset>) {
    let collection_id = self.load_inner().collection_id;
    let asset_id = self.load_inner().asset_id;
    let base_in = multicoin::zero(collection_id, asset_id, ctx);

    self.swap_exact_quantity_with_manager(
        balance_manager,
        trade_cap,
        deposit_cap,
        withdraw_cap,
        base_in,
        quote_in,
        min_base_out,
        collection_id,
        asset_id,
        clock,
        ctx,
    )
}

/// Swap exact quantity without needing a balance_manager.
/// #ref:functions
fun swap_exact_quantity<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    base_in: multicoin::Balance,
    quote_in: Coin<QuoteAsset>,
    cred_in: Coin<CRED>,
    min_out: u64,
    collection_id: ID,
    asset_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (multicoin::Balance, Coin<QuoteAsset>, Coin<CRED>) {
    let mut base_quantity = base_in.value();
    let quote_quantity = quote_in.value();
    assert!((base_quantity > 0) != (quote_quantity > 0), EInvalidQuantityIn);

    let is_bid = quote_quantity > 0;
    if (is_bid) {
        (base_quantity, _) = self.get_quantity_out_input_fee(0, quote_quantity, clock)
    };

    let mut temp_balance_manager = balance_manager::new(ctx);
    let trade_proof = temp_balance_manager.generate_proof_as_owner(ctx);
    temp_balance_manager.deposit_multicoin(base_in, ctx);
    temp_balance_manager.deposit(quote_in, ctx);
    temp_balance_manager.deposit(cred_in, ctx);

    self.place_market_order(
        &mut temp_balance_manager,
        &trade_proof,
        constants::self_matching_allowed(),
        base_quantity,
        is_bid,
        clock,
        ctx,
    );

    let base_out = temp_balance_manager.withdraw_all_multicoin(collection_id, asset_id, ctx);
    let quote_out = temp_balance_manager.withdraw_all<QuoteAsset>(ctx);
    let cred_out = temp_balance_manager.withdraw_all<CRED>(ctx);

    if (is_bid) {
        assert!(base_out.value() >= min_out, EMinimumQuantityOutNotMet);
    } else {
        assert!(quote_out.value() >= min_out, EMinimumQuantityOutNotMet);
    };

    temp_balance_manager.delete();

    (base_out, quote_out, cred_out)
}

/// Swap exact quantity with a balance_manager using quote-denominated fees.
/// #ref:functions
fun swap_exact_quantity_with_manager<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_cap: &TradeCap,
    deposit_cap: &DepositCap,
    withdraw_cap: &WithdrawCap,
    base_in: multicoin::Balance,
    quote_in: Coin<QuoteAsset>,
    min_out: u64,
    collection_id: ID,
    asset_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (multicoin::Balance, Coin<QuoteAsset>) {
    let mut adjusted_base_quantity = base_in.value();
    let base_quantity = base_in.value();
    let quote_quantity = quote_in.value();
    assert!((adjusted_base_quantity > 0) != (quote_quantity > 0), EInvalidQuantityIn);

    let is_bid = quote_quantity > 0;
    if (is_bid) {
        // Sized at this account's own taker rate — see the twin in `pool`.
        (adjusted_base_quantity, _) =
            self.get_quantity_out_for_account(
                balance_manager,
                0,
                quote_quantity,
                clock,
                ctx,
            )
    } else {
        let (base_remaining, _) = self.get_quantity_out_for_account(
            balance_manager,
            base_quantity,
            0,
            clock,
            ctx,
        );
        adjusted_base_quantity = base_quantity - base_remaining;
    };

    balance_manager.deposit_multicoin_with_cap(deposit_cap, base_in, ctx);
    balance_manager.deposit_with_cap(deposit_cap, quote_in, ctx);
    let trade_proof = balance_manager.generate_proof_as_trader(trade_cap, ctx);
    let order_info = self.place_market_order(
        balance_manager,
        &trade_proof,
        constants::self_matching_allowed(),
        adjusted_base_quantity,
        is_bid,
        clock,
        ctx,
    );

    let (base_out, quote_out) = if (is_bid) {
        let quote_left =
            quote_quantity
            - order_info.cumulative_quote_quantity()
            - order_info.paid_fees();
        (order_info.executed_quantity(), quote_left)
    } else {
        let base_left = base_quantity - order_info.executed_quantity();
        // Ask-taker fees come out of the quote proceeds
        (base_left, order_info.cumulative_quote_quantity() - order_info.paid_fees())
    };

    let base_out = balance_manager.withdraw_multicoin_with_cap(
        withdraw_cap,
        collection_id,
        asset_id,
        base_out,
        ctx,
    );
    let quote_out = balance_manager.withdraw_with_cap(withdraw_cap, quote_out, ctx);

    if (is_bid) {
        assert!(base_out.value() >= min_out, EMinimumQuantityOutNotMet);
    } else {
        assert!(quote_out.value() >= min_out, EMinimumQuantityOutNotMet);
    };

    (base_out, quote_out)
}

/// Modify an existing order's quantity.
/// New quantity must be less than the original.
/// #ref:functions #ref:order_modify
public fun modify_order<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_id: u64,
    new_quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let previous_quantity = self.get_order(order_id).quantity();

    let pool_inner = self.load_inner_mut();
    let (cancel_quantity, order) = pool_inner
        .book
        .modify_order(order_id, new_quantity, clock.timestamp_ms());
    assert!(order.balance_manager_id() == balance_manager.id(), EInvalidOrderBalanceManager);
    let (settled, owed, fee_release) = pool_inner
        .state
        .process_modify(
            balance_manager.id(),
            cancel_quantity,
            order,
            pool_inner.pool_id,
            pool_inner.book.price_scaling(),
            ctx,
        );
    // The refund is already in `settled`, so it must reach the pool balance
    // before settlement pays it out.
    pool_inner
        .vault
        .unlock_quote_fees(
            pool_inner.pool_id,
            order_id,
            balance_manager.id(),
            fee_release.release_refunded(),
            clock.timestamp_ms(),
        );
    pool_inner
        .vault
        .settle_balance_manager(settled, owed, balance_manager, trade_proof, option::none(), ctx);
    // A modify-down retains its share on the same terms as a cancel, so
    // requoting down cannot dodge the retention.
    pool_inner.vault.recognize_locked_maker_fees(fee_release.release_retained());

    order.emit_order_modified(
        pool_inner.pool_id,
        previous_quantity,
        ctx.sender(),
        fee_release.release_refunded(),
        fee_release.release_retained(),
        clock.timestamp_ms(),
    );
}

/// Cancel an order by order_id.
/// #ref:functions #ref:order_cancel
public fun cancel_order<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let pool_inner = self.load_inner_mut();
    let mut order = pool_inner.book.cancel_order(order_id);
    assert!(order.balance_manager_id() == balance_manager.id(), EInvalidOrderBalanceManager);
    let (settled, owed, fee_release) = pool_inner
        .state
        .process_cancel(
            &mut order,
            balance_manager.id(),
            pool_inner.pool_id,
            pool_inner.book.price_scaling(),
            ctx,
        );
    // The refund is already in `settled`, so it must reach the pool balance
    // before settlement pays it out.
    pool_inner
        .vault
        .unlock_quote_fees(
            pool_inner.pool_id,
            order_id,
            balance_manager.id(),
            fee_release.release_refunded(),
            clock.timestamp_ms(),
        );
    pool_inner
        .vault
        .settle_balance_manager(settled, owed, balance_manager, trade_proof, option::none(), ctx);
    // The retained share stops being a user claim and becomes revenue the
    // admin may sweep.
    pool_inner.vault.recognize_locked_maker_fees(fee_release.release_retained());

    order.emit_order_canceled(
        pool_inner.pool_id,
        ctx.sender(),
        fee_release.release_refunded(),
        fee_release.release_retained(),
        clock.timestamp_ms(),
    );
}

/// Cancel all orders for a balance_manager.
/// #ref:functions #ref:order_cancel
public fun cancel_all_orders<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let inner = self.load_inner_mut();
    let mut open_orders = vector[];
    if (inner.state.account_exists(balance_manager.id())) {
        open_orders = inner.state.account(balance_manager.id()).open_orders().into_keys();
    };

    let mut i = 0;
    let num_orders = open_orders.length();
    while (i < num_orders) {
        let order_id = open_orders[i];
        self.cancel_order(balance_manager, trade_proof, order_id, clock, ctx);
        i = i + 1;
    }
}

/// Cancel multiple orders within a vector. The orders must be owned by the balance_manager.
/// If any order fails to cancel, no orders will be cancelled.
/// #ref:functions #ref:order_cancel
public fun cancel_orders<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_ids: vector<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let mut i = 0;
    let num_orders = order_ids.length();
    while (i < num_orders) {
        let order_id = order_ids[i];
        self.cancel_order(balance_manager, trade_proof, order_id, clock, ctx);
        i = i + 1;
    }
}

/// Withdraw settled amounts to the balance_manager.
/// #ref:functions
public fun withdraw_settled_amounts<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    ctx: &mut TxContext,
) {
    let pool_inner = self.load_inner_mut();
    let (settled, owed) = pool_inner.state.withdraw_settled_amounts(balance_manager.id());
    pool_inner
        .vault
        .settle_balance_manager(settled, owed, balance_manager, trade_proof, option::none(), ctx);
}

/// Withdraw settled amounts permissionlessly to the `balance_manager`.
public fun withdraw_settled_amounts_permissionless<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    ctx: &mut TxContext,
) {
    let self = self.load_inner_mut();
    let (settled, owed) = self.state.withdraw_settled_amounts(balance_manager.id());
    self.vault.settle_balance_manager_permissionless(settled, owed, balance_manager, ctx);
}

// === Public-Mutative Functions * ADMIN * ===

/// Admin function to set the fees for the next epoch.
/// #ref:functions
public fun set_next_epoch_fee<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    taker_fee: u64,
    maker_fee: u64,
    cancel_retention_bps: u64,
    _cap: &TriexbookAdminCap,
) {
    let pool_inner = self.load_inner_mut();
    pool_inner.state.set_next_epoch_fee(taker_fee, maker_fee, cancel_retention_bps);
}

/// Admin function to set the tier ladder for the next epoch.
///
/// Takes columns rather than tier structs because entry functions cannot accept
/// Move structs as arguments. `fee_schedule::validate` rejects schedules that
/// are empty, do not start at zero turnover, have non-ascending thresholds, or
/// price more turnover higher on either side.
/// #ref:functions
public fun set_next_epoch_fee_schedule<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    min_turnovers: vector<u128>,
    taker_fees: vector<u64>,
    maker_fees: vector<u64>,
    cancel_retention_bps: u64,
    _cap: &TriexbookAdminCap,
) {
    let schedule = fee_schedule::from_vectors(min_turnovers, taker_fees, maker_fees);
    let pool_inner = self.load_inner_mut();
    pool_inner.state.set_next_fee_schedule(schedule, cancel_retention_bps);
}

/// Unregister a pool in case it needs to be redeployed.
public fun unregister_pool_admin<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    registry: &mut Registry,
    _cap: &TriexbookAdminCap,
) {
    let pool_inner = self.load_inner_mut();
    assert!(pool_inner.registered_pool, EPoolNotRegistered);
    pool_inner.registered_pool = false;
    let collection_id = pool_inner.collection_id;
    let asset_id = pool_inner.asset_id;
    registry.unregister_multicoin_pool<QuoteAsset>(collection_id, asset_id);
}

/// Update allowed versions from registry.
public fun update_allowed_versions<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    registry: &Registry,
    _cap: &TriexbookAdminCap,
) {
    let allowed_versions = registry.allowed_versions();
    let inner: &mut MultiCoinPoolInner<QuoteAsset> = self.inner.load_value_mut();
    inner.allowed_versions = allowed_versions;
}

/// Permissionless version of update_allowed_versions.
public fun update_pool_allowed_versions<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    registry: &Registry,
) {
    let allowed_versions = registry.allowed_versions();
    let inner: &mut MultiCoinPoolInner<QuoteAsset> = self.inner.load_value_mut();
    inner.allowed_versions = allowed_versions;
}

/// Withdraw accumulated quote fees into a Coin for treasury custody
public fun withdraw_pool_fees<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    _cap: &TriexbookAdminCap,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<QuoteAsset> {
    let pool_inner = self.load_inner_mut();
    let fee_coin = pool_inner.vault.withdraw_quote_fees(amount, ctx);
    vault::emit_pool_fees_withdrawn<QuoteAsset>(
        pool_inner.pool_id,
        amount,
        clock.timestamp_ms(),
    );
    fee_coin
}

/// Burns CRED tokens from the pool.
/// #feat:rebate
public fun burn_cred<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    treasury_cap: &mut ProtectedTreasury,
    ctx: &mut TxContext,
): u64 {
    let pool_inner = self.load_inner_mut();
    let balance_to_burn = pool_inner.state.history_mut().reset_balance_to_burn();
    let cred_to_burn = pool_inner.vault.withdraw_cred_to_burn(balance_to_burn).into_coin(ctx);
    let amount_burned = cred_to_burn.value();
    token::cred::burn(treasury_cap, cred_to_burn);

    event::emit(MultiCoinCredBurned<QuoteAsset> {
        pool_id: pool_inner.pool_id,
        cred_burned: amount_burned,
    });

    amount_burned
}

// === Public-View Functions ===

public fun registered_pool<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): bool {
    self.load_inner().registered_pool
}

/// Returns the collection_id this pool trades.
public fun collection_id<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): ID {
    self.load_inner().collection_id
}

/// Returns the asset_id this pool trades.
public fun asset_id<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): u64 {
    self.load_inner().asset_id
}

/// Returns the mid price of the pool.
/// #ref:mid_price
public fun mid_price<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>, clock: &Clock): u64 {
    self.load_inner().book.mid_price(clock.timestamp_ms())
}

/// Dry run to determine the quantity out for a given base or quote quantity.
/// Only one out of base or quote quantity should be non-zero.
/// Returns the (base_quantity_out, quote_quantity_out, cred_quantity_required).
/// Uses quote-denominated fees.
public fun get_quantity_out<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    base_quantity: u64,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64) {
    self.get_quantity_out_input_fee(base_quantity, quote_quantity, clock)
}

/// Dry run to determine the quantity out for a given base or quote quantity.
/// Only one out of base or quote quantity should be non-zero.
/// Returns the (base_quantity_out, quote_quantity_out, cred_quantity_required) using quote-denominated fees.
public fun get_quantity_out_input_fee<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    base_quantity: u64,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64) {
    let self_inner = self.load_inner();
    let params = self_inner.state.governance().trade_params();
    let trade_specific_taker_fee = params.taker_fee();
    self_inner
        .book
        .get_quantity_out(
            base_quantity,
            quote_quantity,
            trade_specific_taker_fee,
            clock.timestamp_ms(),
        )
}

/// Dry run priced at the rate this balance manager actually trades at, rather
/// than the entry rung. See `pool::get_quantity_out_for_account`.
public fun get_quantity_out_for_account<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    balance_manager: &BalanceManager,
    base_quantity: u64,
    quote_quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
): (u64, u64) {
    let self_inner = self.load_inner();
    let (_tier, taker_fee, _maker_fee) = self_inner
        .state
        .account_tier_rates(balance_manager.id(), ctx);
    self_inner
        .book
        .get_quantity_out(
            base_quantity,
            quote_quantity,
            taker_fee,
            clock.timestamp_ms(),
        )
}

/// Returns the order_id for all open orders for the balance_manager in the pool.
public fun account_open_orders<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    balance_manager: &BalanceManager,
): VecSet<u64> {
    let pool_inner = self.load_inner();
    if (!pool_inner.state.account_exists(balance_manager.id())) {
        return vec_set::empty()
    };
    pool_inner.state.account(balance_manager.id()).open_orders()
}

/// Returns the (price_vec, quantity_vec) for the level2 order book.
/// #ref:level2
public fun get_level2_range<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    price_low: u64,
    price_high: u64,
    is_bid: bool,
    clock: &Clock,
): (vector<u64>, vector<u64>) {
    self
        .load_inner()
        .book
        .get_level2_range_and_ticks(
            price_low,
            price_high,
            constants::max_u64(),
            is_bid,
            clock.timestamp_ms(),
        )
}

/// Returns level2 data from mid price.
/// #ref:level2
public fun get_level2_ticks_from_mid<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    ticks: u64,
    clock: &Clock,
): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) {
    let pool_inner = self.load_inner();
    let (bid_price, bid_quantity) = pool_inner
        .book
        .get_level2_range_and_ticks(
            constants::min_price(),
            constants::max_price(),
            ticks,
            true,
            clock.timestamp_ms(),
        );
    let (ask_price, ask_quantity) = pool_inner
        .book
        .get_level2_range_and_ticks(
            constants::min_price(),
            constants::max_price(),
            ticks,
            false,
            clock.timestamp_ms(),
        );
    (bid_price, bid_quantity, ask_price, ask_quantity)
}

/// Get all balances held in this pool's vault.
public fun vault_balances<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): (u64, u64, u64) {
    self.load_inner().vault.balances()
}

/// Get the accumulated quote-denominated fee reserve held in this pool's vault.
public fun quote_fee_reserve_balance<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): u64 {
    self.load_inner().vault.quote_fee_reserve_balance()
}

/// The part of the fee reserve that is bid-maker escrow rather than revenue:
/// held against open orders and refundable, so not sweepable.
public fun locked_maker_fees<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): u64 {
    self.load_inner().vault.locked_maker_fees()
}

/// Earned fee revenue in the reserve: the ceiling on `withdraw_pool_fees`.
public fun withdrawable_pool_fees<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): u64 {
    self.load_inner().vault.withdrawable_quote_fees()
}

/// Get the Order struct.
/// #ref:order_query
public fun get_order<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>, order_id: u64): Order {
    self.load_inner().book.get_order(order_id)
}

/// Get multiple orders given a vector of order_ids.
/// #ref:order_query
public fun get_orders<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    order_ids: vector<u64>,
): vector<Order> {
    let mut orders = vector[];
    order_ids.do_ref!(|order_id| {
        orders.push_back(self.get_order(*order_id));
    });
    orders
}

/// Return a copy of all orders that are in the book for this account.
/// #ref:order_query
public fun get_account_order_details<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    balance_manager: &BalanceManager,
): vector<Order> {
    let acct_open_orders = self.account_open_orders(balance_manager).into_keys();
    self.get_orders(acct_open_orders)
}

/// Returns the locked balance for the balance_manager in the pool.
/// Returns (base_quantity, quote_quantity, cred_quantity)
public fun locked_balance<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    balance_manager: &BalanceManager,
): (u64, u64, u64) {
    let account_orders = self.get_account_order_details(balance_manager);
    let pool_inner = self.load_inner();
    if (!pool_inner.state.account_exists(balance_manager.id())) {
        return (0, 0, 0)
    };

    let mut base_quantity = 0;
    let mut quote_quantity = 0;
    let mut cred_quantity = 0;

    account_orders.do_ref!(|order| {
        let locked_balance = order.locked_balance(
            order.maker_fee_rate(),
            pool_inner.book.price_scaling(),
        );
        base_quantity = base_quantity + locked_balance.base();
        quote_quantity = quote_quantity + locked_balance.quote();
        cred_quantity = cred_quantity + locked_balance.cred();
    });

    let settled_balances = pool_inner.state.account(balance_manager.id()).settled_balances();
    base_quantity = base_quantity + settled_balances.base();
    quote_quantity = quote_quantity + settled_balances.quote();
    cred_quantity = cred_quantity + settled_balances.cred();

    (base_quantity, quote_quantity, cred_quantity)
}

/// Returns the (taker_fee, maker_fee) trade params for the pool.
public fun pool_trade_params<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): (u64, u64) {
    let pool_inner = self.load_inner();
    let trade_params = pool_inner.state.governance().trade_params();

    (trade_params.taker_fee(), trade_params.maker_fee())
}

/// Returns the (taker_fee, maker_fee) trade params for the next epoch.
public fun pool_trade_params_next<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): (u64, u64) {
    let pool_inner = self.load_inner();
    let trade_params = pool_inner.state.governance().next_trade_params();

    (trade_params.taker_fee(), trade_params.maker_fee())
}

/// Returns the pool's current tier ladder.
public fun pool_fee_schedule<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): FeeSchedule {
    let pool_inner = self.load_inner();

    *pool_inner.state.fee_schedule()
}

/// Returns the tier ladder taking effect next epoch.
public fun pool_fee_schedule_next<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): FeeSchedule {
    let pool_inner = self.load_inner();

    *pool_inner.state.next_fee_schedule()
}

/// Returns the (taker_fee, maker_fee) this balance manager currently trades at.
/// `pool_trade_params` reports the entry rung, which is what an account with no
/// turnover pays; this reports what *this* account pays.
public fun trade_params_for_account<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    balance_manager: &BalanceManager,
    ctx: &TxContext,
): (u64, u64) {
    let pool_inner = self.load_inner();
    let (_tier, taker_fee, maker_fee) = pool_inner
        .state
        .account_tier_rates(balance_manager.id(), ctx);

    (taker_fee, maker_fee)
}

/// The tier index this balance manager currently occupies.
public fun account_fee_tier<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    balance_manager: &BalanceManager,
    ctx: &TxContext,
): u64 {
    let pool_inner = self.load_inner();

    pool_inner.state.account_fee_tier(balance_manager.id(), ctx)
}

/// Fees this balance manager has paid across the trailing window — the metric
/// tiers resolve against.
public fun account_fee_turnover<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    balance_manager: &BalanceManager,
    ctx: &TxContext,
): u128 {
    let pool_inner = self.load_inner();

    pool_inner.state.account_fee_turnover(balance_manager.id(), ctx)
}

public fun account<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
    balance_manager: &BalanceManager,
): Account {
    let pool_inner = self.load_inner();
    *pool_inner.state.account(balance_manager.id())
}

public fun id<QuoteAsset>(self: &MultiCoinPool<QuoteAsset>): ID {
    self.load_inner().pool_id
}

// === Public-Package Functions ===

public(package) fun bids<QuoteAsset>(self: &MultiCoinPoolInner<QuoteAsset>): &vector<Order> {
    self.book.bids()
}

public(package) fun asks<QuoteAsset>(self: &MultiCoinPoolInner<QuoteAsset>): &vector<Order> {
    self.book.asks()
}

public(package) fun load_inner<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
): &MultiCoinPoolInner<QuoteAsset> {
    let inner: &MultiCoinPoolInner<QuoteAsset> = self.inner.load_value();
    let package_version = constants::current_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionDisabled);
    inner
}

public(package) fun load_inner_mut<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
): &mut MultiCoinPoolInner<QuoteAsset> {
    let inner: &mut MultiCoinPoolInner<QuoteAsset> = self.inner.load_value_mut();
    let package_version = constants::current_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionDisabled);
    inner
}

// === Private Functions ===

fun place_order_int<QuoteAsset>(
    self: &mut MultiCoinPool<QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    expire_timestamp: u64,
    clock: &Clock,
    market_order: bool,
    ctx: &mut TxContext,
): OrderInfo {
    let order_info = {
        let pool_inner = self.load_inner_mut();

        // Resolve this trader's tier rates before the order is built, so the
        // maker rate snapshotted onto it is the one they actually pay. This
        // rolls governance into the current epoch as a side effect, which is
        // what makes an order placed on an epoch-boundary transaction use the
        // freshly promoted schedule rather than last epoch's.
        let (taker_fee_rate, maker_fee_rate) = pool_inner
            .state
            .resolve_trade_rates(balance_manager.id(), ctx);
        let cancel_retention_bps = pool_inner
            .state
            .governance_mut(ctx)
            .trade_params()
            .cancel_retention_bps();
        let mut order_info = order_info::new(
            pool_inner.pool_id,
            balance_manager.id(),
            ctx.sender(),
            order_type,
            self_matching_option,
            price,
            quantity,
            is_bid,
            ctx.epoch(),
            maker_fee_rate,
            cancel_retention_bps,
            expire_timestamp,
            market_order,
            clock.timestamp_ms(),
            pool_inner.book.price_scaling(),
        );
        pool_inner.book.create_order(&mut order_info, clock.timestamp_ms());
        let (settled, owed, fee_flows) = pool_inner
            .state
            .process_create(
                &mut order_info,
                taker_fee_rate,
                maker_fee_rate,
                pool_inner.pool_id,
                ctx,
            );
        // Makers whose orders expired during this match get the refundable
        // share of their escrow credited to settled balances, so it has to
        // leave the reserve for the pool balance that pays settlements out.
        let refunds = fee_flows.refunded();
        let mut refund_idx = 0;
        while (refund_idx < refunds.length()) {
            let refund = &refunds[refund_idx];
            pool_inner
                .vault
                .unlock_quote_fees(
                    pool_inner.pool_id,
                    refund.refund_order_id(),
                    refund.refund_balance_manager_id(),
                    refund.refund_amount(),
                    clock.timestamp_ms(),
                );
            refund_idx = refund_idx + 1;
        };
        // Bid fees ride in with the quote the user pays (fee deposit); ask
        // fees were carved out of quote proceeds and are moved to the
        // reserve after settlement below.
        let (taker_fee_amount, maker_fee_amount) = if (order_info.is_bid()) {
            (order_info.paid_fees(), order_info.maker_fees())
        } else {
            (0, 0)
        };
        let fee_deposit = if (taker_fee_amount + maker_fee_amount > 0) {
            option::some(
                vault::new_quote_fee_deposit(
                    pool_inner.pool_id,
                    balance_manager.id(),
                    taker_fee_amount,
                    maker_fee_amount,
                    clock.timestamp_ms(),
                ),
            )
        } else {
            option::none()
        };
        pool_inner
            .vault
            .settle_balance_manager(settled, owed, balance_manager, trade_proof, fee_deposit, ctx);
        // One deposit per account charged, so each reaches the reserve
        // attributed to whoever paid it: the ask taker for their own fee,
        // each ask maker for the fee taken out of their fill proceeds.
        let proceeds_fees = fee_flows.proceeds();
        let mut fee_idx = 0;
        while (fee_idx < proceeds_fees.length()) {
            let proceeds_fee = &proceeds_fees[fee_idx];
            pool_inner
                .vault
                .move_quote_to_fee_reserve(
                    pool_inner.pool_id,
                    proceeds_fee.balance_manager_id(),
                    proceeds_fee.amount(),
                    clock.timestamp_ms(),
                );
            fee_idx = fee_idx + 1;
        };
        // Escrow these fills earned out, plus the share retained from any
        // expiries, is revenue now and sweepable.
        pool_inner.vault.recognize_locked_maker_fees(fee_flows.recognized());
        order_info.emit_order_info();
        order_info.emit_orders_filled(clock.timestamp_ms());
        order_info.emit_order_fully_filled_if_filled(clock.timestamp_ms());

        order_info
    };

    order_info
}
