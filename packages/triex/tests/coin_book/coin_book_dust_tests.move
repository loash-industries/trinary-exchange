/// Regression tests for the dust blocker.
///
/// A maker can end up resting below `math::min_qty_for_nonzero_quote` — a partial
/// fill leaves a sub-bound residue, and placement only ever checked the *original*
/// quantity. Such an order can never settle for a non-zero quote again.
///
/// The matcher used to answer that case with the same `false` it uses for "the
/// price no longer crosses", and the book walk read `false` as *stop*. One order
/// at the best price therefore made every order behind it unreachable, on both
/// sides and for limit and market takers alike, for the cost of a single modify.
///
/// The fix is threefold and each part is pinned below: the walk distinguishes
/// "skip this maker" from "stop"; a maker that can never fill again is retired on
/// sight so the book self-cleans rather than accumulating blockers; and a
/// modify-down may no longer land under the bound in the first place.
#[test_only]
module triex::coin_book_dust_tests {
    use sui::test_scenario::{begin, Scenario};
    use triex::{coin_book::{Self, Book}, coin_order_info::{Self, OrderInfo}, constants, math};

    const OWNER: address = @0x1;

    /// A raw price of 1e6 — a human price of 0.001 when base and quote share 9
    /// decimals, and the configuration the zero-quote bound actually bites in.
    /// Puts the bound at 1,000 raw base units.
    const CHEAP_PRICE: u64 = 1_000_000;

    fun scaling(): u64 { constants::float_scaling() }

    fun lot(): u64 { math::min_qty_for_nonzero_quote(CHEAP_PRICE, scaling()) }

    fun order(
        order_type: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        market_order: bool,
        ts: u64,
    ): OrderInfo {
        coin_order_info::new(
            object::id_from_address(@0xB00C),
            object::id_from_address(@0xACC7),
            OWNER,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            0,
            0,
            0,
            constants::max_u64(),
            market_order,
            ts,
            scaling(),
        )
    }

    /// Rest a maker and return its order id.
    fun rest(book: &mut Book, price: u64, quantity: u64, is_bid: bool, ts: u64): u128 {
        let mut info = order(constants::no_restriction(), price, quantity, is_bid, false, ts);
        book.create_order(&mut info, ts);
        assert!(info.order_inserted());

        info.order_id()
    }

    /// Cross the book with an IOC taker and return the filled `OrderInfo`.
    fun take(book: &mut Book, price: u64, quantity: u64, is_bid: bool, ts: u64): OrderInfo {
        let mut info = order(
            constants::immediate_or_cancel(),
            price,
            quantity,
            is_bid,
            false,
            ts,
        );
        book.create_order(&mut info, ts);

        info
    }

    /// A market taker, which is exempt from the placement bound and so is the only
    /// way to reach the matcher carrying a sub-bound quantity.
    fun take_market(book: &mut Book, quantity: u64, is_bid: bool, ts: u64): OrderInfo {
        let price = if (is_bid) constants::max_price() else constants::min_price();
        let mut info = order(constants::immediate_or_cancel(), price, quantity, is_bid, true, ts);
        book.create_order(&mut info, ts);

        info
    }

    /// Rest an ask at `CHEAP_PRICE` and partially fill it so it is left resting
    /// below the bound. Returns the blocker's id; its remaining quantity is
    /// `quantity - lot()`.
    fun rest_dust_ask(book: &mut Book, quantity: u64, test: &mut Scenario): u128 {
        let id = rest(book, CHEAP_PRICE, quantity, false, 0);
        let filled = take(book, CHEAP_PRICE, lot(), true, 0);
        assert!(filled.executed_quantity() == lot());
        test.next_tx(OWNER);

        id
    }

    #[test]
    /// The headline case. A sub-bound residue at the best price must not hide the
    /// healthy liquidity resting behind it.
    fun dust_residue_does_not_block_the_orders_behind_it() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        // 1_999 - lot() leaves 999 resting, one unit under the bound.
        rest_dust_ask(&mut book, 1_999, &mut test);
        rest(&mut book, CHEAP_PRICE, 5_000, false, 0);

        let taker = take(&mut book, CHEAP_PRICE, 5_000, true, 0);
        assert!(taker.executed_quantity() == 5_000);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The blocker does not merely get stepped over, it leaves. A maker that can
    /// never settle for a non-zero quote is retired on sight, so a book cannot be
    /// silted up with permanent blockers faster than takers clear them.
    fun an_unfillable_maker_is_retired_from_the_book() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        rest_dust_ask(&mut book, 1_999, &mut test);
        let (_, _, _, asks_before) = book.shape();
        assert!(asks_before == 1);

        // A taker that crosses but takes nothing still clears it, because the
        // retirement is a property of the maker and not of the crossing amount.
        rest(&mut book, CHEAP_PRICE, 5_000, false, 0);
        let taker = take(&mut book, CHEAP_PRICE, 5_000, true, 0);
        assert!(taker.executed_quantity() == 5_000);

        // Dust retired, healthy maker fully filled: nothing left on the side.
        let (_, _, _, asks_after) = book.shape();
        assert!(asks_after == 0);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The wedge was not confined to the blocker's own price level: the walk
    /// stopped outright, so every worse level went with it.
    fun dust_at_the_touch_does_not_hide_worse_price_levels() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        rest_dust_ask(&mut book, 1_999, &mut test);
        rest(&mut book, CHEAP_PRICE * 10, 5_000, false, 0);
        rest(&mut book, CHEAP_PRICE * 1000, 5_000, false, 0);

        // A taker willing to pay far above every resting ask reaches all of them.
        let taker = take(&mut book, CHEAP_PRICE * 10000, 10_000, true, 0);
        assert!(taker.executed_quantity() == 10_000);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The bid side behaves the same way. Bids are walked in the opposite
    /// direction, so this pins that the fix is not one-sided.
    fun dust_does_not_block_the_bid_side() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let _ = rest(&mut book, CHEAP_PRICE, 1_999, true, 0);
        let filled = take(&mut book, CHEAP_PRICE, lot(), false, 0);
        assert!(filled.executed_quantity() == lot());
        test.next_tx(OWNER);

        rest(&mut book, CHEAP_PRICE / 2, 5_000, true, 0);

        let taker = take(&mut book, CHEAP_PRICE / 2, 5_000, false, 0);
        assert!(taker.executed_quantity() == 5_000);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The safety property behind the retirement rule. "Unfillable" is read off the
    /// maker's own remaining quantity, never off the crossing amount, so a taker
    /// arriving with a sub-bound residue cannot evict a healthy resting order — it
    /// only declines to trade with it.
    fun a_healthy_maker_survives_a_taker_carrying_a_sub_bound_residue() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        rest(&mut book, CHEAP_PRICE, 1 * scaling(), false, 0);

        // Below the bound at this price, so no quote would change hands.
        let taker = take_market(&mut book, lot() - 1, true, 0);
        assert!(taker.executed_quantity() == 0);

        // The maker is untouched and still reachable.
        let (_, _, _, asks) = book.shape();
        assert!(asks == 1);
        let next = take(&mut book, CHEAP_PRICE, 5_000, true, 0);
        assert!(next.executed_quantity() == 5_000);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The quoting view walks the same way the matcher does. It used to carry the
    /// identical `break`, so an aggregator was told there was no liquidity behind a
    /// blocker that settlement would have filled straight through.
    fun the_quote_agrees_with_what_settlement_fills_across_dust() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        rest_dust_ask(&mut book, 1_999, &mut test);
        rest(&mut book, CHEAP_PRICE, 5_000, false, 0);

        // Quote a bid for exactly the quote value of the healthy maker, fee-free.
        let quote_in = math::qty_to_quote(5_000, CHEAP_PRICE, scaling());
        let (base_out, quote_left) = book.get_quantity_out(0, quote_in, 0, 0);
        assert!(base_out == 5_000);
        assert!(quote_left == 0);

        // And settlement delivers precisely that.
        let taker = take(&mut book, CHEAP_PRICE, 5_000, true, 0);
        assert!(taker.executed_quantity() == base_out);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    #[expected_failure(abort_code = ::triex::coin_order::EOrderBelowMinimumSize)]
    /// The cheap deliberate route. `modify` used to check only that the new
    /// quantity sat between the filled and original quantities, so one modify could
    /// turn a healthy order into a blocker without waiting for a partial fill.
    fun modify_down_below_the_bound_is_rejected() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let id = rest(&mut book, CHEAP_PRICE, 2_000, false, 0);
        book.modify_order(id, 1, 0);

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// The bound is a floor, not a ban: a modify-down that lands exactly on it is
    /// still a legal order.
    fun modify_down_to_exactly_the_bound_is_allowed() {
        let mut test = begin(OWNER);
        let mut book = coin_book::empty(test.ctx());

        let id = rest(&mut book, CHEAP_PRICE, 2_000, false, 0);
        book.modify_order(id, lot(), 0);

        // Still fillable, which is the whole point of the bound.
        let taker = take(&mut book, CHEAP_PRICE, lot(), true, 0);
        assert!(taker.executed_quantity() == lot());

        book.drop_for_testing();
        test.end();
    }
}
