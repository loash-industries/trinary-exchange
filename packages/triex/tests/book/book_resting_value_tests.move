/// What rests on the book has to be convertible to quote (TRIEX-153).
///
/// Matching values a resting maker's whole remainder at its own price whenever a
/// taker reaches it or it expires, and `math::qty_to_quote` aborts when that does
/// not fit in a `u64`. An ask locks only base, so before this bound three units
/// at `MAX_PRICE` could rest and abort every taker that reached them, with no way
/// to fill, expire or clean the order up — only its owner could cancel it.
///
/// These pin the bound on both price scalings. One unit past it cannot rest, on
/// either side. The largest remainder that can be valued does rest, and then
/// fills, expires and cleans up like any other order. And the bound is on what
/// rests, not on what is submitted: a taker that never rests is unconstrained,
/// and a resting order is measured by its remainder rather than its original
/// size.
#[test_only]
module triex::book_resting_value_tests {
    use sui::test_scenario::begin;
    use triex::{book::{Self, Book}, constants, order_info::{Self, OrderInfo}};

    const OWNER: address = @0x1;
    const MAKER: address = @0xACC7;
    const TAKER: address = @0x7A4E;

    const EXPIRE: u64 = 100;
    const MAX_U64: u64 = 0xFFFFFFFFFFFFFFFF;

    /// The largest base quantity whose value at `MAX_PRICE` fits in a `u64` on a
    /// multicoin book: 2 x (2^63 - 1) = 2^64 - 2.
    const MAX_QTY_MULTICOIN: u64 = 2;
    /// Coin books divide the product by 1e9, so the same bound sits at 2e9 raw
    /// base units.
    const MAX_QTY_COIN: u64 = 2_000_000_000;

    /// An ordinary price and size, for the liquidity the takers sweep.
    const PRICE: u64 = 1_000;

    fun order(
        account: address,
        order_type: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire: u64,
        price_scaling: u64,
    ): OrderInfo {
        order_info::new(
            object::id_from_address(@0xB00C),
            object::id_from_address(account),
            OWNER,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            0,
            0,
            0,
            expire,
            false,
            0,
            price_scaling,
        )
    }

    /// Submit a GTC order from the maker at time zero. Whether it rests is the
    /// caller's to assert.
    fun submit(book: &mut Book, price: u64, quantity: u64, is_bid: bool, expire: u64): OrderInfo {
        let mut info = order(
            MAKER,
            constants::no_restriction(),
            price,
            quantity,
            is_bid,
            expire,
            book.price_scaling(),
        );
        book.create_order(&mut info, 0);

        info
    }

    fun rest(book: &mut Book, price: u64, quantity: u64, is_bid: bool): u128 {
        let info = submit(book, price, quantity, is_bid, EXPIRE);
        assert!(info.order_inserted());

        info.order_id()
    }

    /// A taker of `order_type` priced at the extreme that crosses everything.
    fun take(
        book: &mut Book,
        order_type: u8,
        quantity: u64,
        taker_is_bid: bool,
        now: u64,
    ): OrderInfo {
        let price = if (taker_is_bid) constants::max_price() else constants::min_price();
        let mut info = order(
            TAKER,
            order_type,
            price,
            quantity,
            taker_is_bid,
            constants::max_u64(),
            book.price_scaling(),
        );
        book.create_order(&mut info, now);

        info
    }

    // === One unit past the bound cannot rest ===

    #[test, expected_failure(abort_code = order_info::EOrderValueOverflow)]
    /// The order from the report: three units at `MAX_PRICE` on a multicoin book.
    fun ask_past_the_bound_cannot_rest_multicoin() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        submit(&mut book, constants::max_price(), MAX_QTY_MULTICOIN + 1, false, EXPIRE);

        abort 0
    }

    #[test, expected_failure(abort_code = order_info::EOrderValueOverflow)]
    fun ask_past_the_bound_cannot_rest_coin() {
        let mut test = begin(OWNER);
        let mut book = book::empty(test.ctx());

        submit(&mut book, constants::max_price(), MAX_QTY_COIN + 1, false, EXPIRE);

        abort 0
    }

    #[test, expected_failure(abort_code = order_info::EOrderValueOverflow)]
    /// A bid past the bound was already unplaceable, but it aborted later and
    /// anonymously, inside `math`, when the pool tried to lock its quote. It now
    /// stops at the same check as the ask, with the same error.
    fun bid_past_the_bound_cannot_rest_multicoin() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        submit(&mut book, constants::max_price(), MAX_QTY_MULTICOIN + 1, true, EXPIRE);

        abort 0
    }

    #[test, expected_failure(abort_code = order_info::EOrderValueOverflow)]
    fun bid_past_the_bound_cannot_rest_coin() {
        let mut test = begin(OWNER);
        let mut book = book::empty(test.ctx());

        submit(&mut book, constants::max_price(), MAX_QTY_COIN + 1, true, EXPIRE);

        abort 0
    }

    #[test, expected_failure(abort_code = order_info::EOrderValueOverflow)]
    /// The bound is on the product, not on the price: a large enough quantity is
    /// past it well below `MAX_PRICE`. 2^32 x 2^32 is exactly 2^64.
    fun bound_is_on_the_product_not_the_price() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        submit(&mut book, 4_294_967_296, 4_294_967_296, false, EXPIRE);

        abort 0
    }

    // === The largest remainder that can be valued behaves like any other ===

    #[test]
    /// Exactly at the bound an order rests, on both sides and both scalings, and
    /// reads back as placed.
    fun largest_valued_orders_rest() {
        let mut test = begin(OWNER);

        let mut book = book::empty_multicoin(test.ctx());
        let ask = rest(&mut book, constants::max_price(), MAX_QTY_MULTICOIN, false);
        assert!(book.get_order(ask).quantity() == MAX_QTY_MULTICOIN);
        assert!(book.get_order(ask).price() == constants::max_price());
        book.drop_for_testing();

        let mut book = book::empty_multicoin(test.ctx());
        let bid = rest(&mut book, constants::max_price(), MAX_QTY_MULTICOIN, true);
        assert!(book.get_order(bid).quantity() == MAX_QTY_MULTICOIN);
        book.drop_for_testing();

        let mut book = book::empty(test.ctx());
        let ask = rest(&mut book, constants::max_price(), MAX_QTY_COIN, false);
        assert!(book.get_order(ask).quantity() == MAX_QTY_COIN);
        book.drop_for_testing();

        let mut book = book::empty(test.ctx());
        let bid = rest(&mut book, constants::max_price(), MAX_QTY_COIN, true);
        assert!(book.get_order(bid).quantity() == MAX_QTY_COIN);
        book.drop_for_testing();

        // The same product reached from the other factor: the whole u64 range of
        // base at a price of one raw quote unit each.
        let mut book = book::empty_multicoin(test.ctx());
        let ask = rest(&mut book, 1, MAX_U64, false);
        assert!(book.get_order(ask).quantity() == MAX_U64);
        book.drop_for_testing();

        test.end();
    }

    /// A taker that reaches the largest valued ask fills it in full. The fill is
    /// worth 2^64 - 2 quote, which is what the bound exists to keep expressible.
    fun check_largest_ask_fills(mut book: Book, max_qty: u64) {
        rest(&mut book, constants::max_price(), max_qty, false);

        let taker = take(&mut book, constants::immediate_or_cancel(), max_qty, true, 0);
        assert!(taker.executed_quantity() == max_qty);
        assert!(taker.cumulative_quote_quantity() == MAX_U64 - 1);
        assert!(taker.fills().length() == 1);
        assert!(!taker.fills()[0].expired());
        assert!(taker.fills()[0].completed());
        assert!(book.side_is_empty(false));

        book.drop_for_testing();
    }

    #[test]
    fun largest_valued_ask_fills() {
        let mut test = begin(OWNER);
        check_largest_ask_fills(book::empty_multicoin(test.ctx()), MAX_QTY_MULTICOIN);
        check_largest_ask_fills(book::empty(test.ctx()), MAX_QTY_COIN);
        test.end();
    }

    /// Once expired, the largest valued ask is retired by the first taker to reach
    /// it — the path that aborted on an ask past the bound, because the expiry
    /// arm of `generate_fill` values the whole remainder.
    fun check_largest_ask_is_retired_once_expired(mut book: Book, max_qty: u64) {
        rest(&mut book, constants::max_price(), max_qty, false);

        let taker = take(&mut book, constants::immediate_or_cancel(), 1, true, EXPIRE + 1);
        assert!(taker.executed_quantity() == 0);
        assert!(taker.cumulative_quote_quantity() == 0);
        let fills = taker.fills();
        assert!(fills.length() == 1);
        let fill = &fills[0];
        assert!(fill.expired());
        assert!(fill.base_quantity() == max_qty);
        assert!(fill.quote_quantity() == MAX_U64 - 1);
        assert!(book.side_is_empty(false));

        book.drop_for_testing();
    }

    #[test]
    fun largest_valued_ask_is_retired_by_a_taker_once_expired() {
        let mut test = begin(OWNER);
        check_largest_ask_is_retired_once_expired(
            book::empty_multicoin(test.ctx()),
            MAX_QTY_MULTICOIN,
        );
        check_largest_ask_is_retired_once_expired(book::empty(test.ctx()), MAX_QTY_COIN);
        test.end();
    }

    /// The permissionless cleanup (`book::expire_orders`, TRIEX-159) takes the
    /// same expiry arm, so it could not remove an ask past the bound either.
    /// Whatever can rest can now be cleaned up, on either side.
    fun check_largest_order_is_cleaned_up_once_expired(mut book: Book, max_qty: u64, is_bid: bool) {
        let id = rest(&mut book, constants::max_price(), max_qty, is_bid);

        // Still live on its expiry instant.
        assert!(book.expire_orders(&vector[id], EXPIRE).is_empty());
        assert!(book.side_length(is_bid) == 1);

        let fills = book.expire_orders(&vector[id], EXPIRE + 1);
        assert!(fills.length() == 1);
        assert!(fills[0].expired());
        assert!(fills[0].maker_order_id() == id);
        assert!(fills[0].base_quantity() == max_qty);
        assert!(fills[0].quote_quantity() == MAX_U64 - 1);
        assert!(book.side_is_empty(is_bid));

        book.drop_for_testing();
    }

    #[test]
    fun largest_valued_orders_are_cleaned_up_once_expired() {
        let mut test = begin(OWNER);
        check_largest_order_is_cleaned_up_once_expired(
            book::empty_multicoin(test.ctx()),
            MAX_QTY_MULTICOIN,
            false,
        );
        check_largest_order_is_cleaned_up_once_expired(
            book::empty_multicoin(test.ctx()),
            MAX_QTY_MULTICOIN,
            true,
        );
        check_largest_order_is_cleaned_up_once_expired(
            book::empty(test.ctx()),
            MAX_QTY_COIN,
            false,
        );
        check_largest_order_is_cleaned_up_once_expired(book::empty(test.ctx()), MAX_QTY_COIN, true);
        test.end();
    }

    // === The bound is on what rests, not on what is submitted ===

    #[test]
    /// An IOC or FOK taker priced at the extreme is a common way to sweep. Its
    /// nominal value — quantity times its own limit price — is far past a `u64`,
    /// but it settles at each maker's price and never rests, so it is not
    /// bounded: it fills what is there and abandons the remainder.
    fun taker_that_never_rests_is_not_bounded() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, PRICE, 3, false);
        rest(&mut book, PRICE + 1, 2, false);

        // Sweeps past the real depth: 1e6 wanted, 5 there.
        let ioc = take(&mut book, constants::immediate_or_cancel(), 1_000_000, true, 0);
        assert!(ioc.executed_quantity() == 5);
        assert!(ioc.cumulative_quote_quantity() == 3 * PRICE + 2 * (PRICE + 1));
        assert!(!ioc.order_inserted());
        assert!(ioc.status() == constants::canceled());
        assert!(book.side_is_empty(false));
        assert!(book.side_is_empty(true));

        // A FOK either fills in full or aborts, so it never rests either.
        rest(&mut book, PRICE, 1_000_000, false);
        let fok = take(&mut book, constants::fill_or_kill(), 1_000_000, true, 0);
        assert!(fok.executed_quantity() == 1_000_000);
        assert!(!fok.order_inserted());
        assert!(book.side_is_empty(false));

        // The ask side is the mirror: a taker ask at `MIN_PRICE` into bids.
        rest(&mut book, PRICE, 4, true);
        let ioc_ask = take(&mut book, constants::immediate_or_cancel(), MAX_U64, false, 0);
        assert!(ioc_ask.executed_quantity() == 4);
        assert!(!ioc_ask.order_inserted());
        assert!(book.side_is_empty(true));

        book.drop_for_testing();
        test.end();
    }

    #[test]
    /// A resting order is measured by its remainder. Seven units at `MAX_PRICE`
    /// could not be valued, but five of them execute first and the two that rest
    /// are exactly at the bound.
    fun only_the_remainder_is_bounded() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, PRICE, 5, false);

        let info = submit(&mut book, constants::max_price(), 5 + MAX_QTY_MULTICOIN, true, EXPIRE);
        assert!(info.executed_quantity() == 5);
        assert!(info.order_inserted());
        assert!(info.remaining_quantity() == MAX_QTY_MULTICOIN);
        assert!(book.side_is_empty(false));
        assert!(book.side_length(true) == 1);
        let resting = book.get_order(info.order_id());
        assert!(resting.quantity() - resting.filled_quantity() == MAX_QTY_MULTICOIN);

        book.drop_for_testing();
        test.end();
    }

    #[test, expected_failure(abort_code = order_info::EOrderValueOverflow)]
    /// The control for the test above: one more unit and the remainder is three,
    /// which cannot rest. The whole placement aborts, fills included.
    fun remainder_past_the_bound_cannot_rest() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, PRICE, 5, false);
        submit(&mut book, constants::max_price(), 5 + MAX_QTY_MULTICOIN + 1, true, EXPIRE);

        abort 0
    }

    #[test]
    /// A GTC order that fills completely has nothing left to rest, so the bound
    /// is never consulted, whatever its original size was worth.
    fun fully_filled_order_is_not_bounded() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        rest(&mut book, PRICE, 1_000_000, false);

        let info = submit(&mut book, constants::max_price(), 1_000_000, true, EXPIRE);
        assert!(info.executed_quantity() == 1_000_000);
        assert!(!info.order_inserted());
        assert!(info.status() == constants::filled());
        assert!(book.side_is_empty(false));
        assert!(book.side_is_empty(true));

        book.drop_for_testing();
        test.end();
    }
}
