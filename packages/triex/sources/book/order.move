// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Order module defines the order struct and its methods.
/// All order matching happens in this module.
module triexbook::order;

use sui::event;
use triexbook::{balances::{Self, Balances}, constants, fill::{Self, Fill}, math, quote_fee};

// === Errors ===
const EInvalidNewQuantity: u64 = 0;
const EOrderExpired: u64 = 1;

// === Structs ===
/// Order struct represents the order in the order book. It is optimized for space.
public struct Order has drop, store {
    trading_account_id: ID,
    order_id: u64,
    price: u64,
    is_bid: bool,
    quantity: u64,
    filled_quantity: u64,
    epoch: u64,
    /// Maker fee rate snapshotted at placement. Cancel/modify/locked-balance
    /// and fill-time maker fees read this instead of replaying a global
    /// per-epoch rate, so the order settles at its placement rate even after
    /// rates change.
    maker_fee_rate: u64,
    /// Cancel-retention rate snapshotted at placement, in basis points. The
    /// share of released escrow the protocol keeps on cancel/modify-down/
    /// expiry; the rest is refunded. Snapshotted for the same reason the fee
    /// rate is — an admin policy change must not re-price a resting order.
    cancel_retention_bps: u64,
    status: u8,
    expire_timestamp: u64,
}

/// Emitted when a maker order is canceled.
///
/// `fee_refunded` / `fee_retained` are the two halves of the maker fee escrow
/// this cancellation released, so an indexer reads the whole outcome off one
/// event. The refund also surfaces as a `PoolFeesRefunded` carrying this same
/// `order_id`, which is where the vault-side movement is recorded. Both are
/// zero for asks, which never escrow a fee.
public struct OrderCanceled has copy, drop, store {
    trading_account_id: ID,
    pool_id: ID,
    order_id: u64,
    trader: address,
    price: u64,
    is_bid: bool,
    original_quantity: u64,
    base_asset_quantity_canceled: u64,
    fee_refunded: u64,
    fee_retained: u64,
    timestamp: u64,
}

/// Emitted when a maker order is modified. A modify-down releases escrow on
/// the quantity removed, split on the same terms as a cancel; see
/// `OrderCanceled` for how the two halves relate to `PoolFeesRefunded`.
public struct OrderModified has copy, drop, store {
    trading_account_id: ID,
    pool_id: ID,
    order_id: u64,
    trader: address,
    price: u64,
    is_bid: bool,
    previous_quantity: u64,
    filled_quantity: u64,
    new_quantity: u64,
    fee_refunded: u64,
    fee_retained: u64,
    timestamp: u64,
}

// === Public-View Functions ===
public fun trading_account_id(self: &Order): ID {
    self.trading_account_id
}

public fun order_id(self: &Order): u64 {
    self.order_id
}

public fun quantity(self: &Order): u64 {
    self.quantity
}

public fun filled_quantity(self: &Order): u64 {
    self.filled_quantity
}

public fun epoch(self: &Order): u64 {
    self.epoch
}

public fun maker_fee_rate(self: &Order): u64 {
    self.maker_fee_rate
}

public fun cancel_retention_bps(self: &Order): u64 {
    self.cancel_retention_bps
}

public fun status(self: &Order): u8 {
    self.status
}

public fun expire_timestamp(self: &Order): u64 {
    self.expire_timestamp
}

public fun price(self: &Order): u64 {
    self.price
}

// === Public-Package Functions ===
/// initialize the order struct.
public(package) fun new(
    order_id: u64,
    trading_account_id: ID,
    price: u64,
    is_bid: bool,
    quantity: u64,
    filled_quantity: u64,
    epoch: u64,
    maker_fee_rate: u64,
    cancel_retention_bps: u64,
    status: u8,
    expire_timestamp: u64,
): Order {
    Order {
        order_id,
        trading_account_id,
        price,
        is_bid,
        quantity,
        filled_quantity,
        epoch,
        maker_fee_rate,
        cancel_retention_bps,
        status,
        expire_timestamp,
    }
}

/// Generate a fill for the resting order given the timestamp,
/// quantity and whether the order is a bid.
public(package) fun generate_fill(
    self: &mut Order,
    timestamp: u64,
    quantity: u64,
    is_bid: bool,
    expire_maker: bool,
    price_scaling: u64,
): Fill {
    let remaining_quantity = self.quantity - self.filled_quantity;
    let mut base_quantity = remaining_quantity.min(quantity);
    let mut quote_quantity = math::qty_to_quote(base_quantity, self.price(), price_scaling);

    let order_id = self.order_id;
    let trading_account_id = self.trading_account_id;
    let expired = timestamp > self.expire_timestamp || expire_maker;

    if (expired) {
        self.status = constants::expired();
        base_quantity = remaining_quantity;
        quote_quantity = math::qty_to_quote(base_quantity, self.price(), price_scaling);
    } else {
        self.filled_quantity = self.filled_quantity + base_quantity;
        self.status = if (self.quantity == self.filled_quantity) constants::filled()
        else constants::partially_filled();
    };

    fill::new(
        order_id,
        self.price(),
        trading_account_id,
        expired,
        self.quantity == self.filled_quantity,
        self.quantity,
        base_quantity,
        quote_quantity,
        is_bid,
        self.epoch,
        self.maker_fee_rate,
        self.cancel_retention_bps,
    )
}

/// Modify the order with a new quantity. The new quantity must be greater
/// than the filled quantity and less than the original quantity. The
/// timestamp must be less than the expire timestamp.
public(package) fun modify(self: &mut Order, new_quantity: u64, timestamp: u64) {
    assert!(
        new_quantity > self.filled_quantity &&
        new_quantity < self.quantity,
        EInvalidNewQuantity,
    );
    assert!(timestamp <= self.expire_timestamp, EOrderExpired);
    self.quantity = new_quantity;
}

/// Calculate the refund for a canceled order: the unfilled principal plus
/// the refundable share of the maker fee escrowed against it. If the cancel
/// quantity is not provided, the remaining quantity is used. Cancel quantity
/// is provided when modifying an order, so that the refund can be calculated
/// based on the quantity that's reduced.
///
/// The fee half only ever applies to bids — asks lock nothing. The caller
/// must move the same quote out of the fee reserve before settling, since
/// settled quote is paid from the pool balance.
public(package) fun calculate_cancel_refund(
    self: &Order,
    maker_fee: u64,
    cancel_quantity: Option<u64>,
    price_scaling: u64,
): Balances {
    let (fee_refund, _retained) = self.released_fee_split(
        maker_fee,
        cancel_quantity,
        price_scaling,
    );
    let cancel_quantity = cancel_quantity.get_with_default(
        self.quantity - self.filled_quantity,
    );
    let mut base_out = 0;
    let mut quote_out = 0;
    if (self.is_bid()) {
        quote_out = math::qty_to_quote(cancel_quantity, self.price(), price_scaling) + fee_refund;
    } else {
        base_out = cancel_quantity;
    };

    balances::new(base_out, quote_out, 0)
}

/// Split the escrow this cancel/modify-down releases into the part refunded
/// to the maker and the part the protocol retains as revenue, at the
/// retention rate snapshotted on the order. The two always sum to
/// `locked_fee_released`, so the caller can decrement `locked_maker_fees` by
/// the whole released amount.
public(package) fun released_fee_split(
    self: &Order,
    maker_fee: u64,
    cancel_quantity: Option<u64>,
    price_scaling: u64,
): (u64, u64) {
    let basis = self.locked_fee_released(maker_fee, cancel_quantity, price_scaling);

    quote_fee::split_released_fee(basis, self.cancel_retention_bps)
}

/// The maker fee escrowed against the portion of this order being released,
/// priced at the rate snapshotted on the order at placement. Asks lock
/// nothing, so they release nothing. `cancel_quantity` is the modify-down
/// delta when given, the whole unfilled remainder otherwise — matching
/// `calculate_cancel_refund`.
public(package) fun locked_fee_released(
    self: &Order,
    maker_fee: u64,
    cancel_quantity: Option<u64>,
    price_scaling: u64,
): u64 {
    if (!self.is_bid()) return 0;

    let cancel_quantity = cancel_quantity.get_with_default(
        self.quantity - self.filled_quantity,
    );
    let quote_quantity = math::qty_to_quote(cancel_quantity, self.price(), price_scaling);

    quote_fee::fee_from_scaled_rate(maker_fee, quote_quantity)
}

public(package) fun locked_balance(self: &Order, maker_fee: u64, price_scaling: u64): Balances {
    let is_bid = self.is_bid();
    let order_price = self.price();
    let mut base_quantity = 0;
    let mut quote_quantity = 0;
    let remaining_base_quantity = self.quantity() - self.filled_quantity();
    let remaining_quote_quantity = math::qty_to_quote(
        remaining_base_quantity,
        order_price,
        price_scaling,
    );

    if (is_bid) {
        quote_quantity = quote_quantity + remaining_quote_quantity;
    } else {
        base_quantity = base_quantity + remaining_base_quantity;
    };

    if (is_bid) {
        let maker_fee_amount = quote_fee::fee_from_scaled_rate(maker_fee, quote_quantity);

        let mut balances = balances::new(0, quote_quantity, 0);
        if (maker_fee_amount > 0) {
            balances.add_quote(maker_fee_amount);
        };

        balances
    } else {
        balances::new(base_quantity, quote_quantity, 0)
    }
}

#[test_only]
/// Fields of an `OrderCanceled` for tests asserting the fee split reported on
/// the cancellation matches the refund the vault emitted.
public fun canceled_event_parts(self: &OrderCanceled): (u64, u64, u64) {
    (self.order_id, self.fee_refunded, self.fee_retained)
}

public(package) fun emit_order_canceled(
    self: &Order,
    pool_id: ID,
    trader: address,
    fee_refunded: u64,
    fee_retained: u64,
    timestamp: u64,
) {
    let is_bid = self.is_bid();
    let price = self.price();
    let remaining_quantity = self.quantity - self.filled_quantity;
    event::emit(OrderCanceled {
        pool_id,
        order_id: self.order_id,
        trading_account_id: self.trading_account_id,
        is_bid,
        trader,
        original_quantity: self.quantity,
        base_asset_quantity_canceled: remaining_quantity,
        fee_refunded,
        fee_retained,
        timestamp,
        price,
    });
}

public(package) fun emit_order_modified(
    self: &Order,
    pool_id: ID,
    previous_quantity: u64,
    trader: address,
    fee_refunded: u64,
    fee_retained: u64,
    timestamp: u64,
) {
    let is_bid = self.is_bid();
    let price = self.price();
    event::emit(OrderModified {
        order_id: self.order_id,
        pool_id,
        trading_account_id: self.trading_account_id,
        trader,
        price,
        is_bid,
        previous_quantity,
        filled_quantity: self.filled_quantity,
        new_quantity: self.quantity,
        fee_refunded,
        fee_retained,
        timestamp,
    });
}

public(package) fun emit_cancel_maker(
    trading_account_id: ID,
    pool_id: ID,
    order_id: u64,
    trader: address,
    price: u64,
    is_bid: bool,
    original_quantity: u64,
    base_asset_quantity_canceled: u64,
    fee_refunded: u64,
    fee_retained: u64,
    timestamp: u64,
) {
    event::emit(OrderCanceled {
        trading_account_id,
        pool_id,
        order_id,
        trader,
        price,
        is_bid,
        original_quantity,
        base_asset_quantity_canceled,
        fee_refunded,
        fee_retained,
        timestamp,
    });
}

/// Copy the order struct.
public(package) fun copy_order(order: &Order): Order {
    Order {
        order_id: order.order_id,
        trading_account_id: order.trading_account_id,
        price: order.price,
        is_bid: order.is_bid,
        quantity: order.quantity,
        filled_quantity: order.filled_quantity,
        epoch: order.epoch,
        maker_fee_rate: order.maker_fee_rate,
        cancel_retention_bps: order.cancel_retention_bps,
        status: order.status,
        expire_timestamp: order.expire_timestamp,
    }
}

/// Update the order status to canceled.
public(package) fun set_canceled(self: &mut Order) {
    self.status = constants::canceled();
}

public(package) fun is_bid(self: &Order): bool {
    self.is_bid
}
