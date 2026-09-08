// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `Fill` struct represents the results of a match between two orders.
module triexbook::fill {
    use triexbook::{balances::{Self, Balances}, quote_fee};

    // === Structs ===
    /// Fill struct represents the results of a match between two orders.
    /// It is used to update the state.
    public struct Fill has copy, drop, store {
        // ID of the maker order
        maker_order_id: u64,
        // Execution price
        execution_price: u64,
        // account_id of the maker order
        balance_manager_id: ID,
        // Whether the maker order is expired
        expired: bool,
        // Whether the maker order is fully filled
        completed: bool,
        // Original maker quantity
        original_maker_quantity: u64,
        // Quantity filled
        base_quantity: u64,
        // Quantity of quote currency filled
        quote_quantity: u64,
        // Whether the taker is bid
        taker_is_bid: bool,
        // Maker epoch
        maker_epoch: u64,
        // Maker fee rate snapshotted on the maker order at placement
        maker_fee_rate: u64,
        // Cancel-retention rate snapshotted on the maker order at placement,
        // applied when an expiry releases the escrow held against this fill
        cancel_retention_bps: u64,
        // Taker fee paid for fill
        taker_fee: u64,
        // Maker fee paid for fill
        maker_fee: u64,
    }

    // === Public-View Functions ===
    public fun maker_order_id(self: &Fill): u64 {
        self.maker_order_id
    }

    public fun execution_price(self: &Fill): u64 {
        self.execution_price
    }

    public fun balance_manager_id(self: &Fill): ID {
        self.balance_manager_id
    }

    public fun expired(self: &Fill): bool {
        self.expired
    }

    public fun completed(self: &Fill): bool {
        self.completed
    }

    public fun original_maker_quantity(self: &Fill): u64 {
        self.original_maker_quantity
    }

    public fun base_quantity(self: &Fill): u64 {
        self.base_quantity
    }

    public fun taker_is_bid(self: &Fill): bool {
        self.taker_is_bid
    }

    public fun quote_quantity(self: &Fill): u64 {
        self.quote_quantity
    }

    public fun maker_epoch(self: &Fill): u64 {
        self.maker_epoch
    }

    public fun maker_fee_rate(self: &Fill): u64 {
        self.maker_fee_rate
    }

    public fun cancel_retention_bps(self: &Fill): u64 {
        self.cancel_retention_bps
    }

    public fun taker_fee(self: &Fill): u64 {
        self.taker_fee
    }

    public fun maker_fee(self: &Fill): u64 {
        self.maker_fee
    }

    // === Public-Package Functions ===
    public(package) fun new(
        maker_order_id: u64,
        execution_price: u64,
        balance_manager_id: ID,
        expired: bool,
        completed: bool,
        original_maker_quantity: u64,
        base_quantity: u64,
        quote_quantity: u64,
        taker_is_bid: bool,
        maker_epoch: u64,
        maker_fee_rate: u64,
        cancel_retention_bps: u64,
    ): Fill {
        Fill {
            maker_order_id,
            execution_price,
            balance_manager_id,
            expired,
            completed,
            original_maker_quantity,
            base_quantity,
            quote_quantity,
            taker_is_bid,
            maker_epoch,
            maker_fee_rate,
            cancel_retention_bps,
            taker_fee: 0,
            maker_fee: 0,
        }
    }

    /// The bid-maker escrow this fill resolves: the fee priced on the quote it
    /// covers, at the rate snapshotted on the maker's order at placement. A live
    /// fill charges this; an expired one returns the principal untouched but
    /// still releases the escrow that was held against it.
    public(package) fun maker_fee_escrowed(self: &Fill): u64 {
        quote_fee::fee_from_scaled_rate(self.maker_fee_rate, self.quote_quantity)
    }

    /// Fee the maker owes on this fill. Derived from the fill's own fields so
    /// settlement can never depend on `set_fill_maker_fee` having run first.
    /// Expired fills are not charged.
    public(package) fun maker_fee_charged(self: &Fill): u64 {
        if (self.expired) {
            0
        } else {
            self.maker_fee_escrowed()
        }
    }

    /// The escrow an expiry hands back to a bid maker, and the share the protocol
    /// keeps, at the retention rate snapshotted on their order. An expiry is a
    /// cancellation the maker did not have to send, so it splits on the same
    /// terms — otherwise spam orders would dodge the retention by carrying a
    /// near-term `expire_timestamp` and never cancelling. Non-expired fills and
    /// ask makers release nothing here: the former earn their escrow out, the
    /// latter never locked any.
    public(package) fun maker_fee_refunded(self: &Fill): u64 {
        let (refund, _retained) = self.expiry_fee_split();

        refund
    }

    public(package) fun maker_fee_retained(self: &Fill): u64 {
        let (_refund, retained) = self.expiry_fee_split();

        retained
    }

    fun expiry_fee_split(self: &Fill): (u64, u64) {
        if (!self.expired || self.taker_is_bid) return (0, 0);

        quote_fee::split_released_fee(self.maker_fee_escrowed(), self.cancel_retention_bps)
    }

    /// Calculate the quantities to settle for the maker.
    /// Bid makers locked their fee in quote at placement, so their (base) fills
    /// settle without deductions. Ask makers lock nothing — their fee comes out
    /// of the quote proceeds here, at the rate recorded on the fill. Expired
    /// fills return principal, plus the refundable share of the escrow held
    /// against it for a bid maker.
    public(package) fun get_settled_maker_quantities(self: &Fill): Balances {
        let (base, quote) = if (self.expired) {
            if (self.taker_is_bid) {
                (self.base_quantity, 0)
            } else {
                (0, self.quote_quantity + self.maker_fee_refunded())
            }
        } else {
            if (self.taker_is_bid) {
                (0, self.quote_quantity - self.maker_fee_charged())
            } else {
                (self.base_quantity, 0)
            }
        };

        balances::new(base, quote, 0)
    }

    /// Record the maker fee charged for this fill on the fill itself, for the
    /// `OrderFilled` event and fee accounting. For ask makers this is the amount
    /// `get_settled_maker_quantities` deducts from their quote proceeds; for bid
    /// makers it is the portion of their placement-locked fee this fill
    /// recognizes. Settlement derives the same value itself, so this is
    /// bookkeeping rather than an input to it.
    public(package) fun set_fill_maker_fee(self: &mut Fill, fee: &Balances) {
        self.maker_fee = fee.non_zero_value();
    }

    public(package) fun set_fill_taker_fee(self: &mut Fill, fee: &Balances) {
        self.taker_fee = fee.non_zero_value();
    }
}
