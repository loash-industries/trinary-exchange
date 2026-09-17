/// Order module defines the order struct and its methods.
/// All order matching happens in this module.
///
/// Coin-pool fork of `triex::order`. The difference is `order_id`: here it is the
/// encoded `u128` key its `BigVector` book is stored under, carrying side and
/// price in its high bits, where a multicoin order id is an opaque `u64` serial.
/// Escrow, refund and fee-split logic is shared verbatim with `triex::order` —
/// any change to it must land in both files.
module triex::coin_order {
    use sui::event;
    use triex::{balances::{Self, Balances}, coin_fill::{Self, Fill}, constants, math, quote_fee};

    // === Errors ===
    const EInvalidNewQuantity: u64 = 0;
    const EOrderExpired: u64 = 1;
    /// A modify-down that would leave a remainder too small to ever settle for a
    /// non-zero quote. Mirrors `coin_order_info::EOrderBelowMinimumSize`, which
    /// applies the same bound at placement.
    const EOrderBelowMinimumSize: u64 = 2;
    /// A snapshotted rate was out of range, or finer than the whole basis point
    /// the order stores. The real bounds are enforced where the rates are set, in
    /// `triex::fee_policy`; these are the backstop that keeps the encoding total.
    const EMakerFeeRateTooWide: u64 = 3;
    const ECancelRetentionTooWide: u64 = 4;

    /// Widths of the two snapshotted rates. A coin book spreads its orders across
    /// `BigVector` slices, so a wider order costs a slice rewrite rather than a
    /// whole-book one — but the encoding is shared with `triex::order`, where it
    /// is paid on every order in the book, so both sides encode to the bound.
    /// `fee_policy` caps a maker rate at 1e9 (100%, scaled) and a retention at
    /// 10,000 bps, which fit `u32` and `u16` with room to spare.
    /// Scaled units per basis point. Rates arrive from `triex::fee_policy` in the
    /// 1e9 scale, but the schedule admits nothing finer than a whole basis point
    /// (`FEE_MULTIPLE`), so the order stores bps and converts on the way in and
    /// out. Exact in both directions for any rate the policy can produce.
    const SCALED_PER_BPS: u64 = 100_000;
    /// 10,000 bps is 100%, the widest rate the policy allows — and it fits `u16`,
    /// so storing bps costs no range at all.
    const MAX_MAKER_FEE_BPS: u64 = 10_000;
    const MAX_CANCEL_RETENTION: u64 = 10_000;

    // === Structs ===
    /// Order struct represents the order in the order book. It is optimized for space.
    public struct Order has drop, store {
        trading_account_id: ID,
        order_id: u128,
        price: u64,
        is_bid: bool,
        quantity: u64,
        filled_quantity: u64,
        epoch: u64,
        /// Maker fee rate snapshotted at placement. Cancel/modify/locked-balance
        /// and fill-time maker fees read this instead of replaying a global
        /// per-epoch rate, so the order settles at its placement rate even after
        /// rates change. Stored in whole basis points — see `SCALED_PER_BPS`.
        maker_fee_rate: u16,
        /// Cancel-retention rate snapshotted at placement, in basis points. The
        /// share of released escrow the protocol keeps on cancel/modify-down/
        /// expiry; the rest is refunded. Snapshotted for the same reason the fee
        /// rate is — an admin policy change must not re-price a resting order.
        /// Already in basis points, and bounded by `MAX_CANCEL_RETENTION`.
        cancel_retention_bps: u16,
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
        order_id: u128,
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
        order_id: u128,
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

    public fun order_id(self: &Order): u128 {
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
        (self.maker_fee_rate as u64) * SCALED_PER_BPS
    }

    public fun cancel_retention_bps(self: &Order): u64 {
        self.cancel_retention_bps as u64
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
        order_id: u128,
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
        assert!(maker_fee_rate % SCALED_PER_BPS == 0, EMakerFeeRateTooWide);
        assert!(maker_fee_rate / SCALED_PER_BPS <= MAX_MAKER_FEE_BPS, EMakerFeeRateTooWide);
        assert!(cancel_retention_bps <= MAX_CANCEL_RETENTION, ECancelRetentionTooWide);

        Order {
            order_id,
            trading_account_id,
            price,
            is_bid,
            quantity,
            filled_quantity,
            epoch,
            maker_fee_rate: (maker_fee_rate / SCALED_PER_BPS) as u16,
            cancel_retention_bps: cancel_retention_bps as u16,
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

        coin_fill::new(
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
            self.maker_fee_rate(),
            self.cancel_retention_bps as u64,
        )
    }

    /// Modify the order with a new quantity. The new quantity must be greater than
    /// the filled quantity and less than the original quantity, and the timestamp
    /// must be less than the expire timestamp.
    ///
    /// The remainder it leaves (`new_quantity - filled_quantity`) must also clear
    /// `math::min_qty_for_nonzero_quote` at the order's own price, the same bound
    /// placement applies. Without it a modify-down could park an order below the
    /// bound, where it can never settle for a non-zero quote again.
    public(package) fun modify(
        self: &mut Order,
        new_quantity: u64,
        timestamp: u64,
        price_scaling: u64,
    ) {
        assert!(
            new_quantity > self.filled_quantity &&
        new_quantity < self.quantity,
            EInvalidNewQuantity,
        );
        // Placement refuses an order too small to ever produce a non-zero-quote
        // fill; a modify-down has to honour the same bound, or one modify turns a
        // healthy order into dust the matcher can only ever step over. The
        // subtraction cannot underflow — the assert above pins
        // `new_quantity > filled_quantity`.
        assert!(
            new_quantity - self.filled_quantity >=
                math::min_qty_for_nonzero_quote(self.price, price_scaling),
            EOrderBelowMinimumSize,
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
    /// `fee_refund` is the refundable half of `released_fee_split` for the same
    /// `cancel_quantity` — callers that also need the retained half (every real
    /// one does, to know how much to unlock from the reserve) compute the split
    /// once themselves and pass the refund share in here, rather than this
    /// function deriving it again from the maker fee rate.
    public(package) fun calculate_cancel_refund(
        self: &Order,
        fee_refund: u64,
        cancel_quantity: Option<u64>,
        price_scaling: u64,
    ): Balances {
        let cancel_quantity = cancel_quantity.get_with_default(
            self.quantity - self.filled_quantity,
        );
        let mut base_out = 0;
        let mut quote_out = 0;
        if (self.is_bid()) {
            quote_out =
                math::qty_to_quote(cancel_quantity, self.price(), price_scaling) + fee_refund;
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

        quote_fee::split_released_fee(basis, self.cancel_retention_bps as u64)
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

    /// The funds this order still has locked: quote plus escrowed maker fee for a
    /// bid, base for an ask.
    ///
    /// The quote conversion stays inside the bid arm on purpose. `qty_to_quote`
    /// asserts its result fits in a `u64`, and an ask locks no quote at all, so
    /// computing it before the branch let a large enough ask at a high enough
    /// price abort a read of its own locked balance on a number the ask arm
    /// then discarded.
    public(package) fun locked_balance(self: &Order, maker_fee: u64, price_scaling: u64): Balances {
        let remaining_base_quantity = self.quantity() - self.filled_quantity();

        if (self.is_bid()) {
            let quote_quantity = math::qty_to_quote(
                remaining_base_quantity,
                self.price(),
                price_scaling,
            );
            let maker_fee_amount = quote_fee::fee_from_scaled_rate(maker_fee, quote_quantity);

            let mut balances = balances::new(0, quote_quantity, 0);
            if (maker_fee_amount > 0) {
                balances.add_quote(maker_fee_amount);
            };

            balances
        } else {
            balances::new(remaining_base_quantity, 0, 0)
        }
    }

    #[test_only]
    /// Fields of an `OrderCanceled` for tests asserting the fee split reported on
    /// the cancellation matches the refund the vault emitted.
    public fun canceled_event_parts(self: &OrderCanceled): (u128, u64, u64) {
        (self.order_id, self.fee_refunded, self.fee_retained)
    }

    #[test_only]
    /// Fields of an `OrderModified` for tests asserting the fee split reported on
    /// the modify-down matches the refund the vault emitted.
    public fun modified_event_parts(self: &OrderModified): (u128, u64, u64) {
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
        order_id: u128,
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
}
