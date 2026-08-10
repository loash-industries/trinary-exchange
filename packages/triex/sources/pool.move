// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Public-facing interface for the package.
module triexbook::pool;

use std::type_name;
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
    order::Order,
    order_info::{Self, OrderInfo},
    registry::{TriexbookAdminCap, Registry},
    state::{Self, State},
    vault::{Self, Vault}
};

// use fun df::add as UID.add;
// use fun df::borrow as UID.borrow;
// use fun df::borrow_mut as UID.borrow_mut;
// use fun df::exists_ as UID.exists_; // #feat:ewma

// === Errors ===
const EInvalidFee: u64 = 1;
const ESameBaseAndQuote: u64 = 2;
const EInvalidQuantityIn: u64 = 6;
const EInvalidOrderBalanceManager: u64 = 9;
const EPackageVersionDisabled: u64 = 11;
const EMinimumQuantityOutNotMet: u64 = 12;
// const EInvalidStake: u64 = 13; // #feat:stake - DISABLED
const EPoolNotRegistered: u64 = 14;
const EPoolCannotBeBothWhitelistedAndStable: u64 = 15;
// const EInvalidReferralMultiplier: u64 = 16;
// const EInvalidEWMAAlpha: u64 = 17;
// const EInvalidZScoreThreshold: u64 = 18;
// const EInvalidAdditionalTakerFee: u64 = 19;
const EQuoteNotApproved: u64 = 20;

// === Structs ===
public struct Pool<phantom BaseAsset, phantom QuoteAsset> has key {
    id: UID,
    inner: Versioned,
}

public struct PoolInner<phantom BaseAsset, phantom QuoteAsset> has store {
    allowed_versions: VecSet<u64>,
    pool_id: ID,
    book: Book,
    state: State,
    vault: Vault<BaseAsset, QuoteAsset>,
    registered_pool: bool,
}

public struct PoolCreated<phantom BaseAsset, phantom QuoteAsset> has copy, drop, store {
    pool_id: ID,
    // #feat:fees
    // taker_fee: u64,
    // maker_fee: u64,
    fee: u64,
    whitelisted_pool: bool,
    treasury_address: address,
}

public struct CredBurned<phantom BaseAsset, phantom QuoteAsset> has copy, drop, store {
    pool_id: ID,
    cred_burned: u64,
}

// #feat:refer
// public struct ReferralRewards<phantom BaseAsset, phantom QuoteAsset> has store {
//     multiplier: u64,
//     base: Balance<BaseAsset>,
//     quote: Balance<QuoteAsset>,
//     cred: Balance<CRED>,
// }

// #[deprecated, allow(unused_field)]
// public struct ReferralClaimedEvent<phantom BaseAsset, phantom QuoteAsset> has copy, drop, store {
//     referral_id: ID,
//     owner: address,
//     base_amount: u64,
//     quote_amount: u64,
//     cred_amount: u64,
// }

// #feat:refer
// public struct ReferralClaimed has copy, drop, store {
//     pool_id: ID,
//     referral_id: ID,
//     owner: address,
//     base_amount: u64,
//     quote_amount: u64,
//     cred_amount: u64,
// }

// #feat:refer
// public struct ReferralFeeEvent has copy, drop, store {
//     pool_id: ID,
//     referral_id: ID,
//     base_fee: u64,
//     quote_fee: u64,
//     cred_fee: u64,
// }

// === Public-Mutative Functions * POOL CREATION * ===
/// Create a new pool. The pool is registered in the registry.
/// Checks are performed to ensure the tick size, lot size,
/// and min size are valid.
/// The creation fee is transferred to the treasury address.
/// Returns the id of the pool created
/// #ref:functions
public fun create_permissionless_pool<BaseAsset, QuoteAsset>(
    registry: &mut Registry,
    creation_fee: Coin<CRED>,
    ctx: &mut TxContext,
): ID {
    assert!(creation_fee.value() == constants::pool_creation_fee(), EInvalidFee);
    let base_type = type_name::with_defining_ids<BaseAsset>();
    let quote_type = type_name::with_defining_ids<QuoteAsset>();
    let whitelisted_pool = false;
    let stable_pool = registry.is_stablecoin(base_type) && registry.is_stablecoin(quote_type);

    create_pool<BaseAsset, QuoteAsset>(
        registry,
        creation_fee,
        whitelisted_pool,
        stable_pool,
        ctx,
    )
}

// === Public-Mutative Functions * EXCHANGE * ===
/// Place a limit order. Quantity is in base asset terms.
/// Fees are quote-denominated; pay_with_cred is ignored.
/// #ref:functions
public fun place_limit_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &TxContext,
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

public fun place_limit_order_with_quote_fees<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &TxContext,
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

/// Place a market order. Quantity is in base asset terms. Calls
/// place_limit_order with
/// a price of MAX_PRICE for bids and MIN_PRICE for asks. Any quantity not
/// filled is cancelled.
/// #ref:functions
public fun place_market_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    clock: &Clock,
    ctx: &TxContext,
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

public fun place_market_order_with_quote_fees<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    clock: &Clock,
    ctx: &TxContext,
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

/// Swap exact base quantity without needing a `balance_manager`.
/// Returns base, quote, and cred coins; cred input is returned unchanged.
/// Some base quantity may be left over if the input quantity is not divisible by lot size.
/// #ref:functions
public fun swap_exact_base_for_quote<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    base_in: Coin<BaseAsset>,
    cred_in: Coin<CRED>,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<CRED>) {
    let quote_in = coin::zero(ctx);

    self.swap_exact_quantity(
        base_in,
        quote_in,
        cred_in,
        min_quote_out,
        clock,
        ctx,
    )
}

/// Swap exact base for quote with a `balance_manager`.
/// Fees are quote-denominated.
/// #ref:functions
public fun swap_exact_base_for_quote_with_manager<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_cap: &TradeCap,
    deposit_cap: &DepositCap,
    withdraw_cap: &WithdrawCap,
    base_in: Coin<BaseAsset>,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let quote_in = coin::zero(ctx);

    self.swap_exact_quantity_with_manager(
        balance_manager,
        trade_cap,
        deposit_cap,
        withdraw_cap,
        base_in,
        quote_in,
        min_quote_out,
        clock,
        ctx,
    )
}

/// Swap exact quote quantity without needing a `balance_manager`.
/// Returns base, quote, and cred coins; cred input is returned unchanged.
/// Some quote quantity may be left over if the input quantity is not divisible by lot size.
/// #ref:functions
public fun swap_exact_quote_for_base<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    quote_in: Coin<QuoteAsset>,
    cred_in: Coin<CRED>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<CRED>) {
    let base_in = coin::zero(ctx);

    self.swap_exact_quantity(
        base_in,
        quote_in,
        cred_in,
        min_base_out,
        clock,
        ctx,
    )
}

/// Swap exact quote for base with a `balance_manager`.
/// Fees are quote-denominated.
/// #ref:functions
public fun swap_exact_quote_for_base_with_manager<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_cap: &TradeCap,
    deposit_cap: &DepositCap,
    withdraw_cap: &WithdrawCap,
    quote_in: Coin<QuoteAsset>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let base_in = coin::zero(ctx);

    self.swap_exact_quantity_with_manager(
        balance_manager,
        trade_cap,
        deposit_cap,
        withdraw_cap,
        base_in,
        quote_in,
        min_base_out,
        clock,
        ctx,
    )
}

/// Swap exact quantity without needing a balance_manager.
/// #ref:functions
public fun swap_exact_quantity<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    base_in: Coin<BaseAsset>,
    quote_in: Coin<QuoteAsset>,
    cred_in: Coin<CRED>,
    min_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<CRED>) {
    let mut base_quantity = base_in.value();
    let quote_quantity = quote_in.value();
    assert!((base_quantity > 0) != (quote_quantity > 0), EInvalidQuantityIn);
    let is_bid = quote_quantity > 0;
    if (is_bid) {
        (base_quantity, _) = self.get_quantity_out_input_fee(0, quote_quantity, clock)
    };

    let mut temp_balance_manager = balance_manager::new(ctx);
    let trade_proof = temp_balance_manager.generate_proof_as_owner(ctx);
    temp_balance_manager.deposit(base_in, ctx);
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

    let base_out = temp_balance_manager.withdraw_all<BaseAsset>(ctx);
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

/// Swap exact quantity with a `balance_manager` using quote-denominated fees.
/// #ref:functions
public fun swap_exact_quantity_with_manager<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_cap: &TradeCap,
    deposit_cap: &DepositCap,
    withdraw_cap: &WithdrawCap,
    base_in: Coin<BaseAsset>,
    quote_in: Coin<QuoteAsset>,
    min_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    let mut adjusted_base_quantity = base_in.value();
    let base_quantity = base_in.value();
    let quote_quantity = quote_in.value();
    assert!((adjusted_base_quantity > 0) != (quote_quantity > 0), EInvalidQuantityIn);

    let is_bid = quote_quantity > 0;
    if (is_bid) {
        (adjusted_base_quantity, _) = self.get_quantity_out_input_fee(0, quote_quantity, clock)
    } else {
        // Query how much base will actually be consumed when selling base for quote
        // get_quantity_out returns (base_remaining, quote_out, cred_fee) for is_bid=false
        let (base_remaining, _) = self.get_quantity_out_input_fee(base_quantity, 0, clock);
        adjusted_base_quantity = base_quantity - base_remaining;
    };

    balance_manager.deposit_with_cap(deposit_cap, base_in, ctx);
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
        (base_left, order_info.cumulative_quote_quantity())
    };

    let base_out = balance_manager.withdraw_with_cap(withdraw_cap, base_out, ctx);
    let quote_out = balance_manager.withdraw_with_cap(withdraw_cap, quote_out, ctx);

    if (is_bid) {
        assert!(base_out.value() >= min_out, EMinimumQuantityOutNotMet);
    } else {
        assert!(quote_out.value() >= min_out, EMinimumQuantityOutNotMet);
    };

    (base_out, quote_out)
}

/// Modifies an order given order_id and new_quantity.
/// New quantity must be less than the original quantity and more
/// than the filled quantity. Order must not have already expired.
/// #ref:functions
public fun modify_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_id: u64,
    new_quantity: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    let previous_quantity = self.get_order(order_id).quantity();

    let self = self.load_inner_mut();
    let (cancel_quantity, order) = self
        .book
        .modify_order(order_id, new_quantity, clock.timestamp_ms());
    assert!(order.balance_manager_id() == balance_manager.id(), EInvalidOrderBalanceManager);
    let (settled, owed) = self
        .state
        .process_modify(
            balance_manager.id(),
            cancel_quantity,
            order,
            self.pool_id,
            self.book.price_scaling(),
            ctx,
        );
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof, option::none());

    order.emit_order_modified(
        self.pool_id,
        previous_quantity,
        ctx.sender(),
        clock.timestamp_ms(),
    );
}

/// Cancel an order. The order must be owned by the balance_manager.
/// The order is removed from the book and the balance_manager's open orders.
/// The balance_manager's balance is updated with the order's remaining
/// quantity.
/// Order canceled event is emitted.
/// #ref:functions
public fun cancel_order<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_id: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    let self = self.load_inner_mut();
    let mut order = self.book.cancel_order(order_id);
    assert!(order.balance_manager_id() == balance_manager.id(), EInvalidOrderBalanceManager);
    let (settled, owed) = self
        .state
        .process_cancel(
            &mut order,
            balance_manager.id(),
            self.pool_id,
            self.book.price_scaling(),
            ctx,
        );
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof, option::none());

    order.emit_order_canceled(
        self.pool_id,
        ctx.sender(),
        clock.timestamp_ms(),
    );
}

/// Cancel multiple orders within a vector. The orders must be owned by the
/// balance_manager.
/// The orders are removed from the book and the balance_manager's open orders.
/// Order canceled events are emitted.
/// If any order fails to cancel, no orders will be cancelled.
/// #ref:functions
public fun cancel_orders<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    order_ids: vector<u64>,
    clock: &Clock,
    ctx: &TxContext,
) {
    let mut i = 0;
    let num_orders = order_ids.length();
    while (i < num_orders) {
        let order_id = order_ids[i];
        self.cancel_order(balance_manager, trade_proof, order_id, clock, ctx);
        i = i + 1;
    }
}

/// Cancel all open orders placed by the balance manager in the pool.
/// #ref:functions
public fun cancel_all_orders<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &TxContext,
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

/// Withdraw settled amounts to the `balance_manager`.
/// #ref:functions
public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
) {
    let self = self.load_inner_mut();
    let (settled, owed) = self.state.withdraw_settled_amounts(balance_manager.id());
    self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof, option::none());
}

/// Withdraw settled amounts permissionlessly to the `balance_manager`.
public fun withdraw_settled_amounts_permissionless<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    balance_manager: &mut BalanceManager,
) {
    let self = self.load_inner_mut();
    let (settled, owed) = self.state.withdraw_settled_amounts(balance_manager.id());
    self.vault.settle_balance_manager_permissionless(settled, owed, balance_manager);
}

// === Public-Mutative Functions * GOVERNANCE * ===
// Stake CRED tokens to the pool. The balance_manager must have enough CRED
// tokens.
// The balance_manager's data is updated with the staked amount.
// #ref:functions #feat:stake - DISABLED
// public fun stake<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     balance_manager: &mut BalanceManager,
//     trade_proof: &TradeProof,
//     amount: u64,
//     ctx: &TxContext,
// ) {
//     assert!(amount > 0, EInvalidStake);
//     let self = self.load_inner_mut();
//     let (settled, owed) = self.state.process_stake(self.pool_id, balance_manager.id(), amount, ctx);
//     self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
// }

// Unstake CRED tokens from the pool. The balance_manager must have enough
// staked CRED tokens.
// The balance_manager's data is updated with the unstaked amount.
// Balance is transferred to the balance_manager immediately.
// #ref:functions #feat:stake - DISABLED
// public fun unstake<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     balance_manager: &mut BalanceManager,
//     trade_proof: &TradeProof,
//     ctx: &TxContext,
// ) {
//     let self = self.load_inner_mut();
//     let (settled, owed) = self.state.process_unstake(self.pool_id, balance_manager.id(), ctx);
//     self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
// }

// Submit a proposal to change the taker fee, maker fee, and stake required.
// The balance_manager must have enough staked CRED tokens to participate.
// Each balance_manager can only submit one proposal per epoch.
// If the maximum proposal is reached, the proposal with the lowest vote is
// removed.
// If the balance_manager has less voting power than the lowest voted proposal,
// the proposal is not added.
// #ref:functions #feat:gov #feat:stake - DISABLED
// public fun submit_proposal<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     balance_manager: &mut BalanceManager,
//     trade_proof: &TradeProof,
//     // taker_fee: u64,
//     // maker_fee: u64,
//     // stake_required: u64, // #feat:fee_gov
//     fee: u64,
//     ctx: &TxContext,
// ) {
//     let self = self.load_inner_mut();
//     balance_manager.validate_proof(trade_proof);
//     self
//         .state
//         .process_proposal(
//             self.pool_id,
//             balance_manager.id(),
//             // taker_fee,
//             // maker_fee, // #feat:fee_gov
//             fee,
//             ctx,
//         );
// }

// Vote on a proposal. The balance_manager must have enough staked CRED tokens
// to participate.
// Full voting power of the balance_manager is used.
// Voting for a new proposal will remove the vote from the previous proposal.
// #ref:functions #feat:gov #feat:stake - DISABLED
// public fun vote<BaseAsset, QuoteAsset>
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     balance_manager: &mut BalanceManager,
//     trade_proof: &TradeProof,
//     proposal_id: ID,
//     ctx: &TxContext,
// ) {
//     let self = self.load_inner_mut();
//     balance_manager.validate_proof(trade_proof);
//     self.state.process_vote(self.pool_id, balance_manager.id(), proposal_id, ctx);
// }

// Claim the rewards for the balance_manager. The balance_manager must have
// rewards to claim.
// The balance_manager's data is updated with the claimed rewards.
// #ref:functions #feat:rebate - DISABLED
// public fun claim_rebates<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     balance_manager: &mut BalanceManager,
//     trade_proof: &TradeProof,
//     ctx: &TxContext,
// ) {
//     let self = self.load_inner_mut();
//     let (settled, owed) = self
//         .state
//         .process_claim_rebates<BaseAsset, QuoteAsset>(
//             self.pool_id,
//             balance_manager,
//             ctx,
//         );
//     self.vault.settle_balance_manager(settled, owed, balance_manager, trade_proof);
// }

/// Admin function to set the fee for the next epoch.
/// Replaces the proposal/voting system with direct admin control.
/// #ref:functions
public fun set_next_epoch_fee<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    fee: u64,
    _cap: &TriexbookAdminCap,
) {
    let self = self.load_inner_mut();
    self.state.set_next_epoch_fee(fee);
}

// #feat:flashloan - DISABLED
// === Public-Mutative Functions * FLASHLOAN * ===
// /// Borrow base assets from the Pool. A hot potato is returned,
// /// forcing the borrower to return the assets within the same transaction.
// /// #ref:functions
// public fun borrow_flashloan_base<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     base_amount: u64,
//     ctx: &mut TxContext,
// ): (Coin<BaseAsset>, FlashLoan) {
//     let self = self.load_inner_mut();
//     self.vault.borrow_flashloan_base(self.pool_id, base_amount, ctx)
// }
//
// /// Borrow quote assets from the Pool. A hot potato is returned,
// /// forcing the borrower to return the assets within the same transaction.
// /// #ref:functions
// public fun borrow_flashloan_quote<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     quote_amount: u64,
//     ctx: &mut TxContext,
// ): (Coin<QuoteAsset>, FlashLoan) {
//     let self = self.load_inner_mut();
//     self.vault.borrow_flashloan_quote(self.pool_id, quote_amount, ctx)
// }
//
// /// Return the flashloaned base assets to the Pool.
// /// FlashLoan object will only be unwrapped if the assets are returned,
// /// otherwise the transaction will fail.
// /// #ref:functions
// public fun return_flashloan_base<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     coin: Coin<BaseAsset>,
//     flash_loan: FlashLoan,
// ) {
//     let self = self.load_inner_mut();
//     self.vault.return_flashloan_base(self.pool_id, coin, flash_loan);
// }
//
// /// Return the flashloaned quote assets to the Pool.
// /// FlashLoan object will only be unwrapped if the assets are returned,
// /// otherwise the transaction will fail.
// /// #ref:functions
// public fun return_flashloan_quote<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     coin: Coin<QuoteAsset>,
//     flash_loan: FlashLoan,
// ) {
//     let self = self.load_inner_mut();
//     self.vault.return_flashloan_quote(self.pool_id, coin, flash_loan);
// }

// === Public-Mutative Functions * OPERATIONAL * ===

/// Burns CRED tokens from the pool. Amount to burn is within history
/// #feat:rebate
public fun burn_cred<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    treasury_cap: &mut ProtectedTreasury,
    ctx: &mut TxContext,
): u64 {
    let self = self.load_inner_mut();
    let balance_to_burn = self.state.history_mut().reset_balance_to_burn();
    let cred_to_burn = self.vault.withdraw_cred_to_burn(balance_to_burn).into_coin(ctx);
    let amount_burned = cred_to_burn.value();
    token::cred::burn(treasury_cap, cred_to_burn);

    event::emit(CredBurned<BaseAsset, QuoteAsset> {
        pool_id: self.pool_id,
        cred_burned: amount_burned,
    });

    amount_burned
}

// #feat:refer
// /// Mint a TriexBookReferral and set the additional bps for the referral.
// public fun mint_referral<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     multiplier: u64,
//     ctx: &mut TxContext,
// ): ID {
//     assert!(multiplier <= constants::referral_max_multiplier(), EInvalidReferralMultiplier);
//     assert!(multiplier % constants::referral_multiplier() == 0, EInvalidReferralMultiplier);
//     let _ = self.load_inner();
//     let referral_id = balance_manager::mint_referral(ctx);
//     self
//         .id
//         .add(
//             referral_id,
//             ReferralRewards<BaseAsset, QuoteAsset> {
//                 multiplier,
//                 base: balance::zero(),
//                 quote: balance::zero(),
//                 cred: balance::zero(),
//             },
//         );

//     referral_id
// }

// #feat:refer
// /// Update the multiplier for the referral.
// public fun update_referral_multiplier<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     referral: &TriexBookReferral,
//     multiplier: u64,
//     ctx: &TxContext,
// ) {
//     let _ = self.load_inner();
//     referral.assert_referral_owner(ctx);
//     assert!(multiplier <= constants::referral_max_multiplier(), EInvalidReferralMultiplier);
//     assert!(multiplier % constants::referral_multiplier() == 0, EInvalidReferralMultiplier);
//     let referral_id = object::id(referral);
//     let referral_rewards: &mut ReferralRewards<BaseAsset, QuoteAsset> = self
//         .id
//         .borrow_mut(referral_id);
//     referral_rewards.multiplier = multiplier;
// }

// #feat:refer
// /// Claim the rewards for the referral.
// public fun claim_referral_rewards<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     referral: &TriexBookReferral,
//     ctx: &mut TxContext,
// ): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<CRED>) {
//     let _ = self.load_inner();
//     referral.assert_referral_owner(ctx);
//     let referral_id = object::id(referral);
//     let referral_rewards: &mut ReferralRewards<BaseAsset, QuoteAsset> = self
//         .id
//         .borrow_mut(referral_id);
//     let base = referral_rewards.base.withdraw_all().into_coin(ctx);
//     let quote = referral_rewards.quote.withdraw_all().into_coin(ctx);
//     let cred = referral_rewards.cred.withdraw_all().into_coin(ctx);

//     event::emit(ReferralClaimed {
//         pool_id: self.id(),
//         referral_id,
//         owner: ctx.sender(),
//         base_amount: base.value(),
//         quote_amount: quote.value(),
//         cred_amount: cred.value(),
//     });

//     (base, quote, cred)
// }

// === Public-Mutative Functions * ADMIN * ===
/// Create a new pool. The pool is registered in the registry.
/// Checks are performed to ensure the tick size, lot size, and min size are
/// valid.
/// Returns the id of the pool created
public fun create_pool_admin<BaseAsset, QuoteAsset>(
    registry: &mut Registry,
    whitelisted_pool: bool,
    stable_pool: bool,
    _cap: &TriexbookAdminCap,
    ctx: &mut TxContext,
): ID {
    let creation_fee = coin::zero(ctx);
    create_pool<BaseAsset, QuoteAsset>(
        registry,
        creation_fee,
        whitelisted_pool,
        stable_pool,
        ctx,
    )
}

/// Unregister a pool in case it needs to be redeployed.
public fun unregister_pool_admin<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    registry: &mut Registry,
    _cap: &TriexbookAdminCap,
) {
    let self = self.load_inner_mut();
    assert!(self.registered_pool, EPoolNotRegistered);
    self.registered_pool = false;
    registry.unregister_pool<BaseAsset, QuoteAsset>();
}

/// Takes the registry and updates the allowed version within pool
/// Only admin can update the allowed versions
/// This function does not have version restrictions
public fun update_allowed_versions<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    registry: &Registry,
    _cap: &TriexbookAdminCap,
) {
    let allowed_versions = registry.allowed_versions();
    let inner: &mut PoolInner<BaseAsset, QuoteAsset> = self.inner.load_value_mut();
    inner.allowed_versions = allowed_versions;
}

/// Takes the registry and updates the allowed version within pool
/// Permissionless equivalent of `update_allowed_versions`
/// This function does not have version restrictions
public fun update_pool_allowed_versions<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
    registry: &Registry,
) {
    let allowed_versions = registry.allowed_versions();
    let inner: &mut PoolInner<BaseAsset, QuoteAsset> = self.inner.load_value_mut();
    inner.allowed_versions = allowed_versions;
}

/// Withdraw accumulated quote fees into a Coin for treasury custody
public fun withdraw_pool_fees<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
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

// // #feat:ewma
// /// Enable the EWMA state for the pool. This allows the pool to use
// /// the EWMA state for volatility calculations and additional taker fees.
// public fun enable_ewma_state<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     _cap: &TriexbookAdminCap,
//     enable: bool,
//     clock: &Clock,
//     ctx: &mut TxContext,
// ) {
//     let _ = self.load_inner_mut();
//     let ewma_state = self.update_ewma_state(clock, ctx);
//     if (enable) {
//         ewma_state.enable();
//     } else {
//         ewma_state.disable();
//     }
// }

// #feat:ewma
// /// Set the EWMA parameters for the pool.
// /// Only admin can set the parameters.
// public fun set_ewma_params<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     _cap: &TriexbookAdminCap,
//     alpha: u64,
//     z_score_threshold: u64,
//     additional_taker_fee: u64,
//     clock: &Clock,
//     ctx: &mut TxContext,
// ) {
//     assert!(alpha <= constants::max_ewma_alpha(), EInvalidEWMAAlpha);
//     assert!(z_score_threshold <= constants::max_z_score_threshold(), EInvalidZScoreThreshold);
//     assert!(
//         additional_taker_fee <= constants::max_additional_taker_fee(),
//         EInvalidAdditionalTakerFee,
//     );
//     let _ = self.load_inner_mut();
//     let ewma_state = self.update_ewma_state(clock, ctx);
//     ewma_state.set_alpha(alpha);
//     ewma_state.set_z_score_threshold(z_score_threshold);
//     ewma_state.set_additional_taker_fee(additional_taker_fee);
// }

// === Public-View Functions ===
/// Accessor to check if the pool is whitelisted.
public fun whitelisted<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): bool {
    self.load_inner().state.governance().whitelisted()
}

// #feat:fee_gov
// /// Accessor to check if the pool is a stablecoin pool.
// public fun stable_pool<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): bool {
//     self.load_inner().state.governance().stable()
// }

public fun registered_pool<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): bool {
    self.load_inner().registered_pool
}

/// Dry run to determine the quote quantity out for a given base quantity using quote-denominated fees.
public fun get_quote_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    clock: &Clock,
): (u64, u64) {
    self.get_quantity_out_input_fee(base_quantity, 0, clock)
}

/// Dry run to determine the base quantity out for a given quote quantity using quote-denominated fees.
public fun get_base_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64) {
    self.get_quantity_out_input_fee(0, quote_quantity, clock)
}

/// Dry run to determine the quote quantity out for a given base quantity using quote-denominated fees.
public fun get_quote_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    clock: &Clock,
): (u64, u64) {
    self.get_quantity_out_input_fee(base_quantity, 0, clock)
}

/// Dry run to determine the base quantity out for a given quote quantity using quote-denominated fees.
public fun get_base_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64) {
    self.get_quantity_out_input_fee(0, quote_quantity, clock)
}

/// Dry run to determine the quantity out for a given base or quote quantity.
/// Only one out of base or quote quantity should be non-zero.
/// Returns the (base_quantity_out, quote_quantity_out, cred_quantity_required).
/// Uses quote-denominated fees.
public fun get_quantity_out<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64) {
    self.get_quantity_out_input_fee(base_quantity, quote_quantity, clock)
}

/// Dry run to determine the quantity out for a given base or quote quantity.
/// Only one out of base or quote quantity should be non-zero.
/// Returns the (base_quantity_out, quote_quantity_out) using quote-denominated fees.
public fun get_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    base_quantity: u64,
    quote_quantity: u64,
    clock: &Clock,
): (u64, u64) {
    let self = self.load_inner();
    let params = self.state.governance().trade_params();
    // #feat:fees
    // let taker_fee = params.taker_fee();
    let trade_specific_taker_fee = if (quote_quantity   > 0) {
        params.taker_fee_for_user(true)
    } else {
        params.taker_fee_for_user(false)
    };
    self
        .book
        .get_quantity_out(
            base_quantity,
            quote_quantity,
            trade_specific_taker_fee,
            clock.timestamp_ms(),
        )
}

/// Returns the mid price of the pool.
public fun mid_price<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    clock: &Clock,
): u64 {
    self.load_inner().book.mid_price(clock.timestamp_ms())
}

/// Returns the order_id for all open order for the balance_manager in the pool.
public fun account_open_orders<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): VecSet<u64> {
    let self = self.load_inner();

    if (!self.state.account_exists(balance_manager.id())) {
        return vec_set::empty()
    };

    self.state.account(balance_manager.id()).open_orders()
}

/// Returns the (price_vec, quantity_vec) for the level2 order book.
/// The price_low and price_high are inclusive, all orders within the range are
/// returned.
/// is_bid is true for bids and false for asks.
public fun get_level2_range<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
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

/// Returns the (price_vec, quantity_vec) for the level2 order book.
/// Ticks are the maximum number of ticks to return starting from best bid and
/// best ask.
/// (bid_price, bid_quantity, ask_price, ask_quantity) are returned as 4
/// vectors.
/// The price vectors are sorted in descending order for bids and ascending
/// order for asks.
public fun get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    ticks: u64,
    clock: &Clock,
): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) {
    let self = self.load_inner();
    let (bid_price, bid_quantity) = self
        .book
        .get_level2_range_and_ticks(
            constants::min_price(),
            constants::max_price(),
            ticks,
            true,
            clock.timestamp_ms(),
        );
    let (ask_price, ask_quantity) = self
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

/// Get all balances held in this pool.
public fun vault_balances<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): (u64, u64, u64) {
    self.load_inner().vault.balances()
}

/// Get the accumulated quote-denominated fee reserve held in this pool's vault.
public fun quote_fee_reserve_balance<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): u64 {
    self.load_inner().vault.quote_fee_reserve_balance()
}

/// Get the ID of the pool given the asset types.
public fun get_pool_id_by_asset<BaseAsset, QuoteAsset>(registry: &Registry): ID {
    registry.get_pool_id<BaseAsset, QuoteAsset>()
}

/// Get the Order struct
public fun get_order<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    order_id: u64,
): Order {
    self.load_inner().book.get_order(order_id)
}

/// Get multiple orders given a vector of order_ids.
public fun get_orders<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    order_ids: vector<u64>,
): vector<Order> {
    let mut orders = vector[];
    let mut i = 0;
    let num_orders = order_ids.length();
    while (i < num_orders) {
        let order_id = order_ids[i];
        orders.push_back(self.get_order(order_id));
        i = i + 1;
    };

    orders
}

/// Return a copy of all orders that are in the book for this account.
public fun get_account_order_details<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): vector<Order> {
    let acct_open_orders = self.account_open_orders(balance_manager).into_keys();

    self.get_orders(acct_open_orders)
}

/// Returns the locked balance for the balance_manager in the pool
/// Returns (base_quantity, quote_quantity, cred_quantity)
public fun locked_balance<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): (u64, u64, u64) {
    let account_orders = self.get_account_order_details(balance_manager);
    let self = self.load_inner();
    if (!self.state.account_exists(balance_manager.id())) {
        return (0, 0, 0)
    };

    let mut base_quantity = 0;
    let mut quote_quantity = 0;
    let mut cred_quantity = 0;

    account_orders.do_ref!(|order| {
        let fee_rate = self.state.history().historic_fee_rate(order.epoch());
        let fee_rate_applied = if (order.is_bid()) {
            fee_rate
        } else {
            0
        };
        let locked_balance = order.locked_balance(fee_rate_applied, self.book.price_scaling());
        base_quantity = base_quantity + locked_balance.base();
        quote_quantity = quote_quantity + locked_balance.quote();
        cred_quantity = cred_quantity + locked_balance.cred();
    });

    let settled_balances = self.state.account(balance_manager.id()).settled_balances();
    base_quantity = base_quantity + settled_balances.base();
    quote_quantity = quote_quantity + settled_balances.quote();
    cred_quantity = cred_quantity + settled_balances.cred();

    (base_quantity, quote_quantity, cred_quantity)
}
// // #feat:fees
// /// Returns the trade params for the pool.
// public fun pool_trade_params<BaseAsset, QuoteAsset>(
//     self: &Pool<BaseAsset, QuoteAsset>,
// ): (u64, u64, u64) {
//     let self = self.load_inner();
//     let trade_params = self.state.governance().trade_params();
//     let taker_fee = trade_params.taker_fee();
//     let maker_fee = trade_params.maker_fee();
//     let stake_required = trade_params.stake_required();

//     (taker_fee, maker_fee, stake_required)
// }
// /// Returns the currently leading trade params for the next epoch for the pool
// public fun pool_trade_params_next<BaseAsset, QuoteAsset>(
//     self: &Pool<BaseAsset, QuoteAsset>,
// ): (u64, u64, u64) {
//     let self = self.load_inner();
//     let trade_params = self.state.governance().next_trade_params();
//     let taker_fee = trade_params.taker_fee();
//     let maker_fee = trade_params.maker_fee();
//     let stake_required = trade_params.stake_required();

//     (taker_fee, maker_fee, stake_required)
// }

public fun pool_trade_params<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): u64 {
    let self = self.load_inner();
    let trade_params = self.state.governance().trade_params();
    trade_params.fee()
}

public fun pool_trade_params_next<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): u64 {
    let self = self.load_inner();
    let trade_params = self.state.governance().next_trade_params();
    trade_params.fee()
}

public fun account<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
    balance_manager: &BalanceManager,
): Account {
    let self = self.load_inner();

    *self.state.account(balance_manager.id())
}

// Returns the quorum needed to pass proposal in the current epoch
// #feat:gov - DISABLED
// public fun quorum<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): u64 {
//     self.load_inner().state.governance().quorum()
// }

public fun id<BaseAsset, QuoteAsset>(self: &Pool<BaseAsset, QuoteAsset>): ID {
    self.load_inner().pool_id
}

// #feat:refer
// public fun get_referral_balances<BaseAsset, QuoteAsset>(
//     self: &Pool<BaseAsset, QuoteAsset>,
//     referral: &TriexBookReferral,
// ): (u64, u64, u64) {
//     let referral_id = object::id(referral);
//     let referral_rewards: &ReferralRewards<BaseAsset, QuoteAsset> = self.id.borrow(referral_id);
//     let base = referral_rewards.base.value();
//     let quote = referral_rewards.quote.value();
//     let cred = referral_rewards.cred.value();

//     (base, quote, cred)
// }

// === Public-Package Functions ===
public(package) fun create_pool<BaseAsset, QuoteAsset>(
    registry: &mut Registry,
    creation_fee: Coin<CRED>,
    whitelisted_pool: bool,
    stable_pool: bool,
    ctx: &mut TxContext,
): ID {
    assert!(!(whitelisted_pool && stable_pool), EPoolCannotBeBothWhitelistedAndStable);
    assert!(
        type_name::with_defining_ids<BaseAsset>() != type_name::with_defining_ids<QuoteAsset>(),
        ESameBaseAndQuote,
    );

    // Check if quote currency is approved for pool creation
    let quote_type = type_name::with_defining_ids<QuoteAsset>();
    assert!(registry.is_quote_approved(quote_type), EQuoteNotApproved);

    let pool_id = object::new(ctx);
    let pool_inner = PoolInner<BaseAsset, QuoteAsset> {
        allowed_versions: registry.allowed_versions(),
        pool_id: pool_id.to_inner(),
        book: book::empty(ctx),
        state: state::empty(whitelisted_pool, stable_pool, ctx),
        vault: vault::empty(),
        registered_pool: true,
    };
    let params = pool_inner.state.governance().trade_params();
    // #feat:fees
    // let taker_fee = params.taker_fee();
    // let maker_fee = params.maker_fee();
    let fee = params.fee();
    let treasury_address = registry.treasury_address();
    let pool = Pool<BaseAsset, QuoteAsset> {
        id: pool_id,
        inner: versioned::create(constants::current_version(), pool_inner, ctx),
    };
    let pool_id = object::id(&pool);
    registry.register_pool<BaseAsset, QuoteAsset>(pool_id);
    event::emit(PoolCreated<BaseAsset, QuoteAsset> {
        pool_id,
        // #feat:fees
        // taker_fee,
        // maker_fee,
        fee,
        whitelisted_pool,
        treasury_address,
    });

    transfer::public_transfer(creation_fee, treasury_address);
    transfer::share_object(pool);

    pool_id
}

public(package) fun bids<BaseAsset, QuoteAsset>(
    self: &PoolInner<BaseAsset, QuoteAsset>,
    // ): &BigVector<Order> { // #feat:bv
): &vector<Order> {
    self.book.bids()
}

public(package) fun asks<BaseAsset, QuoteAsset>(
    self: &PoolInner<BaseAsset, QuoteAsset>,
    // ): &BigVector<Order> { // #feat:bv
): &vector<Order> {
    self.book.asks()
}

public(package) fun load_inner<BaseAsset, QuoteAsset>(
    self: &Pool<BaseAsset, QuoteAsset>,
): &PoolInner<BaseAsset, QuoteAsset> {
    let inner: &PoolInner<BaseAsset, QuoteAsset> = self.inner.load_value();
    let package_version = constants::current_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionDisabled);

    inner
}

public(package) fun load_inner_mut<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
): &mut PoolInner<BaseAsset, QuoteAsset> {
    let inner: &mut PoolInner<BaseAsset, QuoteAsset> = self.inner.load_value_mut();
    let package_version = constants::current_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionDisabled);

    inner
}

// #feat:ewma
// public(package) fun load_ewma_state<BaseAsset, QuoteAsset>(
//     self: &Pool<BaseAsset, QuoteAsset>,
// ): EWMAState {
//     *self.id.borrow(constants::ewma_df_key())
// }

// === Private Functions ===
fun place_order_int<BaseAsset, QuoteAsset>(
    self: &mut Pool<BaseAsset, QuoteAsset>,
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
    ctx: &TxContext,
): OrderInfo {
    // #feat:ewma
    // self.update_ewma_state(clock, ctx);
    // let ewma_state = self.load_ewma_state();
    let order_info = {
        let pool_inner = self.load_inner_mut();

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
            expire_timestamp,
            market_order,
            clock.timestamp_ms(),
            pool_inner.book.price_scaling(),
        );
        pool_inner.book.create_order(&mut order_info, clock.timestamp_ms());
        let (settled, owed) = pool_inner
            .state
            .process_create(
                &mut order_info,
                // &ewma_state, // #feat:ewma
                pool_inner.pool_id,
                ctx,
            );
        let quote_fee_amount = order_info.paid_fees() + order_info.maker_fees();
        let fee_deposit = if (quote_fee_amount > 0) {
            option::some(
                vault::new_quote_fee_deposit(
                    pool_inner.pool_id,
                    balance_manager.id(),
                    quote_fee_amount,
                    clock.timestamp_ms(),
                ),
            )
        } else {
            option::none()
        };
        pool_inner
            .vault
            .settle_balance_manager(settled, owed, balance_manager, trade_proof, fee_deposit);
        order_info.emit_order_info();
        order_info.emit_orders_filled(clock.timestamp_ms());
        order_info.emit_order_fully_filled_if_filled(clock.timestamp_ms());

        order_info
    };

    // #feat:refer
    // self.process_referral_fees<BaseAsset, QuoteAsset>(
    //     &order_info,
    //     balance_manager,
    //     trade_proof,
    // );

    order_info
}

// #feat:refer
// fun process_referral_fees<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     order_info: &OrderInfo,
//     balance_manager: &mut BalanceManager,
//     trade_proof: &TradeProof,
// ) {
//     let referral_id = balance_manager.get_referral_id();
//     if (referral_id.is_some()) {
//         let referral_id = referral_id.destroy_some();
//         let referral_rewards: &mut ReferralRewards<BaseAsset, QuoteAsset> = self
//             .id
//             .borrow_mut(referral_id);
//         let referral_multiplier = referral_rewards.multiplier;
//         let referral_fee = math::mul(order_info.paid_fees(), referral_multiplier);
//         if (referral_fee == 0) {
//             return
//         };
//         let mut base_fee = 0;
//         let mut quote_fee = 0;
//         // Referral fees are quote-denominated in the unified fee model.
//         if (!order_info.is_bid()) {
//             referral_rewards
//                 .base
//                 .join(balance_manager.withdraw_with_proof(trade_proof, referral_fee, false));
//             base_fee = referral_fee;
//         } else {
//             referral_rewards
//                 .quote
//                 .join(balance_manager.withdraw_with_proof(trade_proof, referral_fee, false));
//             quote_fee = referral_fee;
//         };

//         event::emit(ReferralFeeEvent {
//             pool_id: self.id(),
//             referral_id,
//             base_fee,
//             quote_fee,
//             cred_fee,
//         });
//     };
// }

// #feat:ewma
// fun update_ewma_state<BaseAsset, QuoteAsset>(
//     self: &mut Pool<BaseAsset, QuoteAsset>,
//     clock: &Clock,
//     ctx: &TxContext,
// ): &mut EWMAState {
//     if (!self.id.exists_(constants::ewma_df_key())) {
//         self.id.add(constants::ewma_df_key(), init_ewma_state(ctx));
//     };

//     let ewma_state: &mut EWMAState = self
//         .id
//         .borrow_mut(
//             constants::ewma_df_key(),
//         );
//     ewma_state.update(clock, ctx);

//     ewma_state
// }
