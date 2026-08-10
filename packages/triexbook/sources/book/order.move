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
    balance_manager_id: ID,
    order_id: u64,
    price: u64,
    is_bid: bool,
    quantity: u64,
    filled_quantity: u64,
    epoch: u64,
    status: u8,
    expire_timestamp: u64,
}

/// Emitted when a maker order is canceled.
public struct OrderCanceled has copy, drop, store {
    balance_manager_id: ID,
    pool_id: ID,
    order_id: u64,
    trader: address,
    price: u64,
    is_bid: bool,
    original_quantity: u64,
    base_asset_quantity_canceled: u64,
    timestamp: u64,
}

/// Emitted when a maker order is modified.
public struct OrderModified has copy, drop, store {
    balance_manager_id: ID,
    pool_id: ID,
    order_id: u64,
    trader: address,
    price: u64,
    is_bid: bool,
    previous_quantity: u64,
    filled_quantity: u64,
    new_quantity: u64,
    timestamp: u64,
}

// === Public-View Functions ===
public fun balance_manager_id(self: &Order): ID {
    self.balance_manager_id
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
    balance_manager_id: ID,
    price: u64,
    is_bid: bool,
    quantity: u64,
    filled_quantity: u64,
    epoch: u64,
    status: u8,
    expire_timestamp: u64,
): Order {
    Order {
        order_id,
        balance_manager_id,
        price,
        is_bid,
        quantity,
        filled_quantity,
        epoch,
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
    let balance_manager_id = self.balance_manager_id;
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
        balance_manager_id,
        expired,
        self.quantity == self.filled_quantity,
        self.quantity,
        base_quantity,
        quote_quantity,
        is_bid,
        self.epoch,
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

/// Calculate the refund for a canceled order. The refund is any
/// unfilled quantity and the maker fee. If the cancel quantity is
/// not provided, the remaining quantity is used. Cancel quantity is
/// provided when modifying an order, so that the refund can be calculated
/// based on the quantity that's reduced.
public(package) fun calculate_cancel_refund(
    self: &Order,
    _maker_fee: u64,
    cancel_quantity: Option<u64>,
    price_scaling: u64,
): Balances {
    let cancel_quantity = cancel_quantity.get_with_default(
        self.quantity - self.filled_quantity,
    );
    let mut base_out = 0;
    let mut quote_out = 0;
    if (self.is_bid()) {
        quote_out = math::qty_to_quote(cancel_quantity, self.price(), price_scaling);
    } else {
        base_out = cancel_quantity;
    };

    // Bid cancellations leave quote-denominated maker fees in the fee reserve; no refund of
    // previously locked fees is issued on cancel.
    balances::new(base_out, quote_out, 0)
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
        let maker_fee_bps = quote_fee::scaled_to_bps(maker_fee);
        let mut fee_info = quote_fee::new(maker_fee_bps);
        let maker_fee_amount = fee_info.calculate_maker_fee(quote_quantity);

        let mut balances = balances::new(0, quote_quantity, 0);
        if (maker_fee_amount > 0) {
            balances.add_quote(maker_fee_amount);
        };

        balances
    } else {
        balances::new(base_quantity, quote_quantity, 0)
    }
}

public(package) fun emit_order_canceled(
    self: &Order,
    pool_id: ID,
    trader: address,
    timestamp: u64,
) {
    let is_bid = self.is_bid();
    let price = self.price();
    let remaining_quantity = self.quantity - self.filled_quantity;
    event::emit(OrderCanceled {
        pool_id,
        order_id: self.order_id,
        balance_manager_id: self.balance_manager_id,
        is_bid,
        trader,
        original_quantity: self.quantity,
        base_asset_quantity_canceled: remaining_quantity,
        timestamp,
        price,
    });
}

public(package) fun emit_order_modified(
    self: &Order,
    pool_id: ID,
    previous_quantity: u64,
    trader: address,
    timestamp: u64,
) {
    let is_bid = self.is_bid();
    let price = self.price();
    event::emit(OrderModified {
        order_id: self.order_id,
        pool_id,
        balance_manager_id: self.balance_manager_id,
        trader,
        price,
        is_bid,
        previous_quantity,
        filled_quantity: self.filled_quantity,
        new_quantity: self.quantity,
        timestamp,
    });
}

public(package) fun emit_cancel_maker(
    balance_manager_id: ID,
    pool_id: ID,
    order_id: u64,
    trader: address,
    price: u64,
    is_bid: bool,
    original_quantity: u64,
    base_asset_quantity_canceled: u64,
    timestamp: u64,
) {
    event::emit(OrderCanceled {
        balance_manager_id,
        pool_id,
        order_id,
        trader,
        price,
        is_bid,
        original_quantity,
        base_asset_quantity_canceled,
        timestamp,
    });
}

/// Copy the order struct.
public(package) fun copy_order(order: &Order): Order {
    Order {
        order_id: order.order_id,
        balance_manager_id: order.balance_manager_id,
        price: order.price,
        is_bid: order.is_bid,
        quantity: order.quantity,
        filled_quantity: order.filled_quantity,
        epoch: order.epoch,
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
