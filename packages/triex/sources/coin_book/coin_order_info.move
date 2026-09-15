/// Order module defines the order struct and its methods.
/// All order matching happens in this module.
///
/// Coin-pool fork of `triex::order_info`. Order ids are the encoded `u128` keys
/// of the coin book, so every id-carrying event here is a distinct type from its
/// multicoin twin and indexers get one unambiguous stream per trading type. The
/// matching, validation and fee arithmetic is shared verbatim with
/// `triex::order_info` — any change to it must land in both files.
module triex::coin_order_info {
    use sui::event;
    use triex::{
        balances::{Self, Balances},
        coin_fill::Fill,
        coin_order::{Self, Order},
        constants,
        math,
        quote_fee
    };

    // === Errors ===
    const EOrderInvalidPrice: u64 = 0;
    /// Reuses the code DeepBook assigns the same condition, though the bound here is
    /// derived from the order's own price rather than a per-pool constant.
    const EOrderBelowMinimumSize: u64 = 1;
    const EInvalidExpireTimestamp: u64 = 3;
    const EInvalidOrderType: u64 = 4;
    const EPOSTOrderCrossesOrderbook: u64 = 5;
    const EFOKOrderCannotBeFullyFilled: u64 = 6;
    const EMarketOrderCannotBePostOnly: u64 = 7;
    const ESelfMatchingCancelTaker: u64 = 8;

    // === Structs ===
    /// The result of offering one resting maker to a taker.
    ///
    /// The three cases are kept apart deliberately. Collapsing "this maker cannot
    /// trade" into "the book cannot trade" is what once let a single unfillable
    /// order at the best price make every order behind it unreachable, so the walk
    /// is told whether to stop or to step over rather than inferring it from a
    /// boolean that meant both.
    public enum MatchOutcome has copy, drop {
        /// A fill — or a retirement, which settles as a refund — was recorded
        /// against this maker. Keep walking.
        Filled,
        /// Nothing could be done with this maker, but the makers behind it are
        /// still reachable. Leave it resting and keep walking.
        Skipped,
        /// The book has nothing further for this taker: the price no longer
        /// crosses, or the taker is fully filled. Stop.
        Stopped,
    }

    /// OrderInfo struct represents all order information.
    /// This objects gets created at the beginning of the order lifecycle and
    /// gets updated until it is completed or placed in the book.
    /// It is returned at the end of the order lifecycle.
    public struct OrderInfo has copy, drop, store {
        // ID of the pool
        pool_id: ID,
        // ID of the order within the pool
        order_id: u128,
        // ID of the account the order uses
        trading_account_id: ID,
        // Trader of the order
        trader: address,
        // Order type, NO_RESTRICTION, IMMEDIATE_OR_CANCEL, FILL_OR_KILL, POST_ONLY
        order_type: u8,
        // Self matching option,
        self_matching_option: u8,
        // Price, only used for limit orders
        price: u64,
        // Whether the order is a buy or a sell
        is_bid: bool,
        // Quantity (in base asset terms) when the order is placed
        original_quantity: u64,
        // Expiration timestamp in ms
        expire_timestamp: u64,
        // Quantity executed so far
        executed_quantity: u64,
        // Cumulative quote quantity executed so far
        cumulative_quote_quantity: u64,
        // Any partial fills
        fills: vector<Fill>,
        // Fees paid so far in base/quote/CRED terms for taker orders
        paid_fees: u64,
        // Fees transferred to pool vault but not yet paid for maker order
        maker_fees: u64,
        // Epoch this order was placed
        epoch: u64,
        // Maker fee rate snapshotted at placement (post epoch-rollover), recorded
        // on the resting Order so it settles at its placement rate
        maker_fee_rate: u64,
        // Cancel-retention rate snapshotted at placement, carried onto the resting
        // Order so a policy change never re-prices an order already on the book
        cancel_retention_bps: u64,
        // Status of the order
        status: u8,
        // Is a market_order
        market_order: bool,
        // Executed in one transaction
        fill_limit_reached: bool,
        // Whether order is inserted
        order_inserted: bool,
        // Order Timestamp
        timestamp: u64,
        // Divisor used in base ↔ quote conversions; mirrors Book.price_scaling.
        // FLOAT_SCALING for normal pools, 1 for multicoin pools.
        price_scaling: u64,
    }

    /// Emitted when a maker order is filled.
    public struct OrderFilled has copy, drop, store {
        pool_id: ID,
        maker_order_id: u128,
        taker_order_id: u128,
        price: u64,
        taker_is_bid: bool,
        taker_fee: u64,
        maker_fee: u64,
        base_quantity: u64,
        quote_quantity: u64,
        maker_trading_account_id: ID,
        taker_trading_account_id: ID,
        timestamp: u64,
    }

    /// Emitted when a maker order is injected into the order book.
    public struct OrderPlaced has copy, drop, store {
        trading_account_id: ID,
        pool_id: ID,
        order_id: u128,
        trader: address,
        price: u64,
        is_bid: bool,
        placed_quantity: u64,
        expire_timestamp: u64,
        timestamp: u64,
    }

    /// Emitted when a maker order is expired.
    /// `fee_refunded` / `fee_retained` split the maker fee escrow the expiry
    /// released, on the same terms a cancel would have — expiry must not be the
    /// cheaper exit. The refund also surfaces as a `PoolFeesRefunded` carrying
    /// this same `order_id`. Both are zero for an expired ask, which escrows
    /// nothing.
    public struct OrderExpired has copy, drop, store {
        trading_account_id: ID,
        pool_id: ID,
        order_id: u128,
        trader: address, // trader that expired the order
        price: u64,
        is_bid: bool,
        original_quantity: u64,
        base_asset_quantity_canceled: u64,
        fee_refunded: u64,
        fee_retained: u64,
        timestamp: u64,
    }

    #[test_only]
    /// Fields of an `OrderExpired` for tests asserting the fee split reported on
    /// the expiry matches the refund the vault emitted.
    public fun expired_event_parts(self: &OrderExpired): (u128, u64, u64) {
        (self.order_id, self.fee_refunded, self.fee_retained)
    }

    /// Emitted when an order is fully filled.
    public struct OrderFullyFilled has copy, drop, store {
        pool_id: ID,
        order_id: u128,
        trading_account_id: ID,
        original_quantity: u64,
        is_bid: bool,
        timestamp: u64,
    }

    // === Public-View Functions ===
    public fun pool_id(self: &OrderInfo): ID {
        self.pool_id
    }

    public fun order_id(self: &OrderInfo): u128 {
        self.order_id
    }

    public fun trading_account_id(self: &OrderInfo): ID {
        self.trading_account_id
    }

    public fun trader(self: &OrderInfo): address {
        self.trader
    }

    public fun order_type(self: &OrderInfo): u8 {
        self.order_type
    }

    public fun self_matching_option(self: &OrderInfo): u8 {
        self.self_matching_option
    }

    public fun price(self: &OrderInfo): u64 {
        self.price
    }

    public fun is_bid(self: &OrderInfo): bool {
        self.is_bid
    }

    public fun original_quantity(self: &OrderInfo): u64 {
        self.original_quantity
    }

    public fun expire_timestamp(self: &OrderInfo): u64 {
        self.expire_timestamp
    }

    public fun executed_quantity(self: &OrderInfo): u64 {
        self.executed_quantity
    }

    public fun cumulative_quote_quantity(self: &OrderInfo): u64 {
        self.cumulative_quote_quantity
    }

    public fun fills(self: &OrderInfo): vector<Fill> {
        self.fills
    }

    public fun paid_fees(self: &OrderInfo): u64 {
        self.paid_fees
    }

    public fun maker_fees(self: &OrderInfo): u64 {
        self.maker_fees
    }

    public fun epoch(self: &OrderInfo): u64 {
        self.epoch
    }

    public fun maker_fee_rate(self: &OrderInfo): u64 {
        self.maker_fee_rate
    }

    public fun cancel_retention_bps(self: &OrderInfo): u64 {
        self.cancel_retention_bps
    }

    public fun status(self: &OrderInfo): u8 {
        self.status
    }

    public fun fill_limit_reached(self: &OrderInfo): bool {
        self.fill_limit_reached
    }

    public fun order_inserted(self: &OrderInfo): bool {
        self.order_inserted
    }

    // === Public-Package Functions ===
    public(package) fun new(
        pool_id: ID,
        trading_account_id: ID,
        trader: address,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        epoch: u64,
        maker_fee_rate: u64,
        cancel_retention_bps: u64,
        expire_timestamp: u64,
        market_order: bool,
        timestamp: u64,
        price_scaling: u64,
    ): OrderInfo {
        OrderInfo {
            pool_id,
            order_id: 0,
            trading_account_id,
            trader,
            order_type,
            self_matching_option,
            price,
            is_bid,
            original_quantity: quantity,
            expire_timestamp,
            executed_quantity: 0,
            cumulative_quote_quantity: 0,
            fills: vector[],
            epoch,
            maker_fee_rate,
            cancel_retention_bps,
            paid_fees: 0,
            maker_fees: 0,
            status: constants::live(),
            market_order,
            fill_limit_reached: false,
            order_inserted: false,
            timestamp,
            price_scaling,
        }
    }

    public(package) fun market_order(self: &OrderInfo): bool {
        self.market_order
    }

    public(package) fun set_order_id(self: &mut OrderInfo, order_id: u128) {
        self.order_id = order_id;
    }

    #[test_only]
    /// Snapshot the rates a real placement resolves from the fee policy. Test helpers
    /// build order info with zero rates, which skips the fee paths entirely; this
    /// lets a test opt into exercising them.
    public fun set_fee_snapshot_for_testing(
        self: &mut OrderInfo,
        maker_fee_rate: u64,
        cancel_retention_bps: u64,
    ) {
        self.maker_fee_rate = maker_fee_rate;
        self.cancel_retention_bps = cancel_retention_bps;
    }

    public(package) fun set_paid_fees(self: &mut OrderInfo, paid_fees: u64) {
        self.paid_fees = paid_fees;
    }

    public(package) fun add_fill(self: &mut OrderInfo, fill: Fill) {
        self.fills.push_back(fill);
    }

    public(package) fun fills_ref(self: &mut OrderInfo): &mut vector<Fill> {
        &mut self.fills
    }

    public(package) fun paid_fees_balances(self: &OrderInfo): Balances {
        // Taker fees are quote-denominated on both sides: bids pay on top of the
        // quote they owe, asks out of the quote proceeds they receive.
        if (self.paid_fees == 0) {
            return balances::new(0, 0, 0)
        };
        balances::new(0, self.paid_fees, 0)
    }

    /// Given a partially filled `OrderInfo`, the taker fee and maker fee, for the user
    /// placing the order, calculate all of the balances that need to be settled and
    /// the balances that are owed. The executed quantity is multiplied by the taker_fee
    /// and the remaining quantity is multiplied by the maker_fee to get the CRED fee.
    public(package) fun calculate_partial_fill_balances(
        self: &mut OrderInfo,
        taker_fee: u64,
        maker_fee: u64,
    ): (Balances, Balances) {
        let remaining_quantity = self.remaining_quantity();
        let mut settled_balances = balances::new(0, 0, 0);
        let mut owed_balances = balances::new(0, 0, 0);

        let mut total_taker_fee = 0;
        let fills = &mut self.fills;
        let mut i = 0;
        let num_fills = fills.length();
        while (i < num_fills) {
            let fill = &mut fills[i];
            if (!fill.expired()) {
                // The exact call the dry run in `coin_book::get_quantity_out`
                // makes, on the same per-fill basis, so a quote can never
                // disagree with what settles.
                let fee_amount = if (taker_fee > 0) {
                    quote_fee::fee_from_scaled_rate(taker_fee, fill.quote_quantity())
                } else {
                    0
                };
                fill.set_fill_taker_fee(&balances::new(0, fee_amount, 0));
                total_taker_fee = total_taker_fee + fee_amount;
            };

            i = i + 1;
        };

        self.paid_fees = total_taker_fee;
        // Bid takers pay their fee on top of the quote they owe; ask takers have
        // it deducted from the quote proceeds they receive (below).
        if (self.is_bid && total_taker_fee > 0) {
            owed_balances.add_quote(total_taker_fee);
        };

        if (self.order_inserted() && self.is_bid && maker_fee > 0) {
            let locked_quote = math::qty_to_quote(
                remaining_quantity,
                self.price(),
                self.price_scaling,
            );
            let maker_fee_amount = quote_fee::fee_from_scaled_rate(maker_fee, locked_quote);
            self.maker_fees = maker_fee_amount;
            if (maker_fee_amount > 0) {
                owed_balances.add_quote(maker_fee_amount);
            };
        } else {
            self.maker_fees = 0;
        };

        if (self.is_bid) {
            settled_balances.add_base(self.executed_quantity);
            owed_balances.add_quote(self.cumulative_quote_quantity);
            if (self.order_inserted()) {
                owed_balances.add_quote(
                    math::qty_to_quote(remaining_quantity, self.price(), self.price_scaling),
                );
            };
        } else {
            settled_balances.add_quote(self.cumulative_quote_quantity - total_taker_fee);
            owed_balances.add_base(self.executed_quantity);
            if (self.order_inserted()) {
                owed_balances.add_base(remaining_quantity);
            };
        };

        (settled_balances, owed_balances)
    }

    /// `OrderInfo` is converted to an `Order` before being injected into the order book.
    /// This is done to save space in the order book. Order contains the minimum
    /// information required to match orders.
    public(package) fun to_order(self: &OrderInfo): Order {
        coin_order::new(
            self.order_id,
            self.trading_account_id,
            self.price,
            self.is_bid,
            self.original_quantity,
            self.executed_quantity,
            self.epoch,
            self.maker_fee_rate,
            self.cancel_retention_bps,
            self.status,
            self.expire_timestamp,
        )
    }

    /// Validates that the initial order created meets the pool requirements.
    public(package) fun validate_inputs(order_info: &OrderInfo, timestamp: u64) {
        assert!(timestamp <= order_info.expire_timestamp, EInvalidExpireTimestamp);
        assert!(
            order_info.order_type >= constants::no_restriction() &&
        order_info.order_type <= constants::max_restriction(),
            EInvalidOrderType,
        );
        if (order_info.market_order) {
            assert!(order_info.order_type != constants::post_only(), EMarketOrderCannotBePostOnly);
            return
        };
        assert!(
            order_info.price >= constants::min_price() &&
        order_info.price <= constants::max_price(),
            EOrderInvalidPrice,
        );
        // A resting order smaller than one quote unit's worth of base at its own
        // price can never produce a non-zero fill, since the matcher quantizes to
        // exactly this bound — it would sit on the book forever as unfillable dust.
        // Reject it at placement instead. The bound is read off the price, so it
        // needs no per-pool minimum size: it is 1 for a base priced at or above one
        // quote unit and scales up automatically as the price falls.
        //
        // Market orders returned above: they match at each maker's price, not at the
        // sentinel price they carry, and they never rest.
        assert!(
            order_info.original_quantity >=
        math::min_qty_for_nonzero_quote(order_info.price, order_info.price_scaling),
            EOrderBelowMinimumSize,
        );
    }

    /// Assert order types after partial fill against the order book.
    public(package) fun assert_execution(self: &mut OrderInfo): bool {
        if (self.order_type == constants::post_only()) {
            assert!(self.executed_quantity == 0, EPOSTOrderCrossesOrderbook)
        };
        if (self.order_type == constants::fill_or_kill()) {
            assert!(self.executed_quantity == self.original_quantity, EFOKOrderCannotBeFullyFilled)
        };
        if (self.order_type == constants::immediate_or_cancel()) {
            if (self.remaining_quantity() > 0) {
                self.status = constants::canceled();
            } else {
                self.status = constants::filled();
            };

            return true
        };

        if (self.remaining_quantity() == 0) {
            self.status = constants::filled();

            return true
        };

        if (self.fill_limit_reached) {
            return true
        };

        false
    }

    /// Returns the remaining quantity for the order.
    public(package) fun remaining_quantity(self: &OrderInfo): u64 {
        self.original_quantity - self.executed_quantity
    }

    /// Returns true if two opposite orders are overlapping in price.
    public(package) fun can_match(self: &OrderInfo, order: &Order): bool {
        let maker_price = order.price();

        (
            self.original_quantity - self.executed_quantity > 0 && (
            self.is_bid && self.price >= maker_price ||
            !self.is_bid && self.price <= maker_price,
        ),
        )
    }

    /// Offers one resting maker to this taker and reports what the book walk should
    /// do next — see `MatchOutcome`.
    ///
    /// `Filled` appends a `Fill`. An expired maker, a `cancel_maker` self-match and a
    /// maker retired for being permanently unfillable all take the same path: the
    /// `Fill` carries the expired flag, no quote moves, and the maker's own principal
    /// is returned to them as settled.
    ///
    /// `Skipped` appends nothing. It means only that this maker could not trade —
    /// the taker's residue converts to zero quote at this maker's price — and the
    /// makers behind it are still reachable.
    ///
    /// `Stopped` is the only terminal answer: the price no longer crosses, or the
    /// taker is fully filled.
    public(package) fun match_maker(
        self: &mut OrderInfo,
        maker: &mut Order,
        timestamp: u64,
    ): MatchOutcome {
        if (!self.can_match(maker)) return MatchOutcome::Stopped;

        if (self.self_matching_option() == constants::cancel_taker()) {
            assert!(
                maker.trading_account_id() != self.trading_account_id(),
                ESelfMatchingCancelTaker,
            );
        };
        let expire_maker =
            self.self_matching_option() == constants::cancel_maker() &&
        maker.trading_account_id() == self.trading_account_id();
        let maker_remaining = maker.quantity() - maker.filled_quantity();
        // A maker whose *entire* remaining quantity still converts to zero quote can
        // never settle for anything again at its own price — a partial fill or a
        // modify-down left it under the bound. Leaving it to rest would block every
        // order behind it, so it is retired on sight along the path an expiry already
        // takes: no quote moves, the maker gets their own principal back, and the book
        // self-cleans instead of accumulating permanent blockers. The test is read off
        // the maker alone, never off the crossing amount, so a healthy maker is never
        // retired because some taker happened to arrive with a small residue.
        let unfillable =
            math::qty_to_quote(maker_remaining, maker.price(), self.price_scaling) == 0;
        let retire = expire_maker || unfillable;
        let expired = timestamp > maker.expire_timestamp() || retire;
        // Decline a live fill that would settle for no quote at all. `qty_to_quote`
        // floors, so a small enough fill converts to zero: the taker would receive
        // base without paying for it while the maker's `filled_quantity` advanced
        // uncompensated. The threshold is read off the maker's price, so it costs no
        // configured minimum and holds whatever the base is worth.
        //
        // Only the zero case is refused — fills are deliberately *not* rounded to a
        // whole multiple of that threshold. Quantizing would also truncate ordinary
        // fills, which matters because a quote with few decimals puts normal prices
        // well below `FLOAT_SCALING`. Flooring the quote instead leaves the taker a
        // rounding benefit under one raw quote unit per fill, which is what every
        // fixed-point book does.
        //
        // An expiry is exempt: it moves no quote, it hands the maker their own
        // principal back. That also keeps expired orders reachable for cleanup when
        // the crossing amount is below the threshold.
        //
        // Reaching the check below means the maker itself is healthy, so the shortfall
        // is the taker's own residue. That says nothing about the makers behind this
        // one — a bid taker walks ascending asks, where the same residue converts to
        // more quote, not less — so this maker is stepped over rather than ending the
        // walk.
        if (!expired) {
            let matchable = self.remaining_quantity().min(maker_remaining);
            if (math::qty_to_quote(matchable, maker.price(), self.price_scaling) == 0) {
                return MatchOutcome::Skipped
            };
        };
        let fill = maker.generate_fill(
            timestamp,
            self.remaining_quantity(),
            self.is_bid,
            retire,
            self.price_scaling,
        );
        self.fills.push_back(fill);
        if (fill.expired()) return MatchOutcome::Filled;

        self.executed_quantity = self.executed_quantity + fill.base_quantity();
        self.cumulative_quote_quantity = self.cumulative_quote_quantity + fill.quote_quantity();
        self.status = constants::partially_filled();
        if (self.remaining_quantity() == 0) self.status = constants::filled();

        MatchOutcome::Filled
    }

    /// True when the book walk should advance to the next maker. Only `Stopped`
    /// ends the walk; a skipped or retired maker leaves the orders behind it
    /// reachable.
    public(package) fun continues(self: &MatchOutcome): bool {
        match (self) {
            MatchOutcome::Stopped => false,
            _ => true,
        }
    }

    /// Emit all fills for this order in a vector of `OrderFilled` events.
    /// To avoid DOS attacks, 100 fills are emitted at a time. Up to 10,000
    /// fills can be emitted in a single call.
    public(package) fun emit_orders_filled(self: &OrderInfo, timestamp: u64) {
        let mut i = 0;
        let num_fills = self.fills.length();
        while (i < num_fills) {
            let fill = &self.fills[i];
            if (fill.completed()) {
                self.emit_order_fully_filled(
                    fill.maker_order_id(),
                    fill.trading_account_id(),
                    fill.original_maker_quantity(),
                    !fill.taker_is_bid(),
                    timestamp,
                );
            };
            if (!fill.expired()) {
                event::emit(self.order_filled_from_fill(fill, timestamp));
            } else {
                let cancel_maker = self.trading_account_id() == fill.trading_account_id();
                if (cancel_maker) {
                    self.emit_order_canceled_maker_from_fill(fill, timestamp);
                } else {
                    event::emit(self.order_expired_from_fill(fill, timestamp));
                };
            };
            i = i + 1;
        };
    }

    public(package) fun emit_order_placed(self: &OrderInfo) {
        event::emit(OrderPlaced {
            trading_account_id: self.trading_account_id,
            pool_id: self.pool_id,
            order_id: self.order_id,
            is_bid: self.is_bid,
            trader: self.trader,
            placed_quantity: self.remaining_quantity(),
            price: self.price,
            expire_timestamp: self.expire_timestamp,
            timestamp: self.timestamp,
        });
    }

    public(package) fun emit_order_info(self: &OrderInfo) {
        event::emit(*self);
    }

    public(package) fun emit_order_fully_filled_if_filled(self: &OrderInfo, timestamp: u64) {
        if (self.status == constants::filled()) {
            self.emit_order_fully_filled(
                self.order_id,
                self.trading_account_id,
                self.original_quantity,
                self.is_bid,
                timestamp,
            );
        }
    }

    public(package) fun emit_order_fully_filled(
        self: &OrderInfo,
        order_id: u128,
        trading_account_id: ID,
        original_quantity: u64,
        is_bid: bool,
        timestamp: u64,
    ) {
        event::emit(OrderFullyFilled {
            pool_id: self.pool_id,
            order_id,
            trading_account_id,
            original_quantity,
            is_bid,
            timestamp,
        })
    }

    public(package) fun set_fill_limit_reached(self: &mut OrderInfo) {
        self.fill_limit_reached = true;
    }

    public(package) fun set_order_inserted(self: &mut OrderInfo) {
        self.order_inserted = true;
    }

    // === Private Functions ===
    fun order_filled_from_fill(self: &OrderInfo, fill: &Fill, timestamp: u64): OrderFilled {
        OrderFilled {
            pool_id: self.pool_id,
            maker_order_id: fill.maker_order_id(),
            taker_order_id: self.order_id,
            price: fill.execution_price(),
            taker_is_bid: self.is_bid,
            taker_fee: fill.taker_fee(),
            maker_fee: fill.maker_fee(),
            base_quantity: fill.base_quantity(),
            quote_quantity: fill.quote_quantity(),
            maker_trading_account_id: fill.trading_account_id(),
            taker_trading_account_id: self.trading_account_id,
            timestamp,
        }
    }

    fun order_expired_from_fill(self: &OrderInfo, fill: &Fill, timestamp: u64): OrderExpired {
        OrderExpired {
            trading_account_id: fill.trading_account_id(),
            pool_id: self.pool_id,
            order_id: fill.maker_order_id(),
            trader: self.trader(),
            price: fill.execution_price(),
            is_bid: !self.is_bid(),
            original_quantity: fill.original_maker_quantity(),
            base_asset_quantity_canceled: fill.base_quantity(),
            fee_refunded: fill.maker_fee_refunded(),
            fee_retained: fill.maker_fee_retained(),
            timestamp,
        }
    }

    fun emit_order_canceled_maker_from_fill(self: &OrderInfo, fill: &Fill, timestamp: u64) {
        coin_order::emit_cancel_maker(
            fill.trading_account_id(),
            self.pool_id,
            fill.maker_order_id(),
            self.trader(),
            fill.execution_price(),
            !self.is_bid(),
            fill.original_maker_quantity(),
            fill.base_quantity(),
            fill.maker_fee_refunded(),
            fill.maker_fee_retained(),
            timestamp,
        )
    }
}
