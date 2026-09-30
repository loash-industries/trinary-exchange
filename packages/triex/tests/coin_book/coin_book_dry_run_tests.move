/// Dry-run fee pricing for the coin book.
///
/// `get_quantity_out` is what every router, indexer and swap entry point prices
/// against, and what `swap_exact_quantity` sizes its order from. What it reserves
/// for the fee therefore has to be what settlement charges — no more, or the input
/// is never deployed, and no less, or the swap overdraws.
///
/// These live here rather than in `book_tests` because the coin stack is what runs
/// `FLOAT_SCALING` price scaling; `triex::book` serves the multicoin pools now and
/// its `empty_multicoin` constructor prices on a bare product, which is not the
/// arithmetic these figures are calibrated against.
#[test_only]
module triex::coin_book_dry_run_tests {
    use sui::{object::id_from_address, test_scenario::begin};
    use triex::{book::{Self, Book}, constants, math, order_info::{Self, OrderInfo}, quote_fee};

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;

    fun rest(b: &mut Book, price: u64, qty: u64, is_bid: bool) {
        let mut oi = order_info::new(
            id_from_address(@0x1),
            id_from_address(@0xA1),
            ALICE,
            constants::post_only(),
            constants::self_matching_allowed(),
            price,
            qty,
            is_bid,
            0,
            9_000_000,
            2_000,
            constants::max_u64(),
            false,
            0,
            book::price_scaling(b),
        );
        b.create_order(&mut oi, 0);
        assert!(oi.order_inserted(), 0);
    }

    #[test]
    /// A bid dry run must reserve exactly the taker fee that settles, not a
    /// multiple of it.
    ///
    /// The reservation used to be sized at `FEE_PENALTY_MULTIPLIER * taker_rate`
    /// while `calculate_partial_fill_balances` charged the plain rate, so the
    /// difference — 0.25x the fee, i.e. 0.271% of the input at the 1.10% coin
    /// entry rung and 0.535% at the 2.20% multicoin one — was input the swap
    /// never deployed and nobody received. It also made the two sides of the
    /// same book quote asymmetrically, which a router reads as a half-spread
    /// that does not exist.
    fun bid_dry_run_reserves_exactly_the_fee_that_settles() {
        let mut test = begin(OWNER);
        let mut b = book::empty(test.ctx());
        // One deep ask at human price 1.00 (price = 1e6 for a 6-decimal quote
        // against a 9-decimal base), so a single level absorbs the whole input.
        rest(&mut b, 1_000_000, 10_000_000_000_000, false);

        let taker_rate = 11_000_000; // 1.10%
        let input = 1_000_000_000; // 1_000 CRED at 6 decimals
        let (base_out, quote_left) = b.get_quantity_out(0, input, taker_rate, 0);

        // What settlement charges for the base this quote says it buys.
        let quote_spent = math::qty_to_quote(base_out, 1_000_000, book::price_scaling(&b));
        let fee = quote_fee::fee_from_scaled_rate(taker_rate, quote_spent);

        // Nothing is left undeployed beyond the input the level's own price
        // granularity cannot spend, which `quote_left` already accounts for.
        assert!(input - quote_spent - fee == quote_left, input - quote_spent - fee);
        // And that residue is sub-unit against the trade, not a fraction of a
        // percent of it: under the old multiplier this was 2_712_701.
        assert!(quote_left < 1_000, quote_left);

        b.drop_for_testing();
        test.end();
    }

    #[test]
    /// Buying base and selling it straight back at the same price must cost
    /// exactly two taker fees and nothing else.
    ///
    /// This is the asymmetry stated as a round trip. The multiplier applied to
    /// the bid leg only, so the two directions of the same book quoted a
    /// different fee for the same trade and a round trip leaked a third charge
    /// no one collected — a phantom half-spread on the bid side.
    fun a_round_trip_costs_exactly_two_taker_fees() {
        let mut test = begin(OWNER);
        let mut b = book::empty(test.ctx());
        rest(&mut b, 1_000_000, 10_000_000_000_000, false);

        let taker_rate = 22_000_000; // 2.20%, where the old gap was widest
        let input = 1_000_000_000;
        let (base_out, quote_left) = b.get_quantity_out(0, input, taker_rate, 0);

        // Sell the base straight back into a bid at the same price.
        let mut b2 = book::empty(test.ctx());
        rest(&mut b2, 1_000_000, 10_000_000_000_000, true);
        let (base_left, quote_out) = b2.get_quantity_out(base_out, 0, taker_rate, 0);
        assert!(base_left == 0, 0);

        let leg = quote_fee::fee_from_scaled_rate(
            taker_rate,
            math::qty_to_quote(base_out, 1_000_000, book::price_scaling(&b)),
        );
        // Everything the round trip did not return is fee, and it is exactly two
        // of them. Under the multiplier the bid leg also held back 0.25x its fee
        // and never spent it, so this came up short by that much.
        assert!(quote_out + quote_left == input - 2 * leg, quote_out + quote_left);

        b.drop_for_testing();
        b2.drop_for_testing();
        test.end();
    }

    // === Taker fee on the order's aggregate ===
    // Settlement charges the taker fee once, on the order's whole matched quote,
    // and the dry run prices on the same basis. A book of 50 levels worth 90 raw
    // quote each is the audit's measurement: at 1.10% every level floors to zero
    // on its own, while the 4,500 they sum to owes 49.

    const DUST_LEVELS: u64 = 50;
    const DUST_LEVEL_BASE: u64 = 90_000; // 90 raw quote at price 1e6
    const DUST_PRICE: u64 = 1_000_000;
    const DUST_RATE: u64 = 11_000_000; // 1.10%

    fun rest_dust_levels(b: &mut Book, is_bid: bool) {
        DUST_LEVELS.do!(|_| rest(b, DUST_PRICE, DUST_LEVEL_BASE, is_bid));
    }

    /// Cross the book at the levels' own price with an immediate-or-cancel taker
    /// and settle it the way `place_order_int` does.
    fun take(b: &mut Book, qty: u64, is_bid: bool): OrderInfo {
        let mut oi = order_info::new(
            id_from_address(@0x1),
            id_from_address(@0xB1),
            @0xB,
            constants::immediate_or_cancel(),
            constants::self_matching_allowed(),
            DUST_PRICE,
            qty,
            is_bid,
            0,
            9_000_000,
            2_000,
            constants::max_u64(),
            false,
            0,
            book::price_scaling(b),
        );
        b.create_order(&mut oi, 0);
        oi.calculate_partial_fill_balances(DUST_RATE, 9_000_000);
        oi
    }

    fun sum_fill_taker_fees(oi: &OrderInfo): u64 {
        let mut total = 0;
        oi.fills().do!(|fill| total = total + fill.taker_fee());
        total
    }

    #[test]
    /// A sweep of small fills pays the fee on their sum, not the sum of their
    /// floored fees, and the per-fill amounts the events report add up to it.
    fun a_sweep_of_small_fills_pays_the_fee_on_their_sum() {
        let mut test = begin(OWNER);
        let mut b = book::empty(test.ctx());
        rest_dust_levels(&mut b, false);

        let oi = take(&mut b, DUST_LEVELS * DUST_LEVEL_BASE, true);

        assert!(oi.fills().length() == DUST_LEVELS, oi.fills().length());
        assert!(oi.cumulative_quote_quantity() == 4_500, oi.cumulative_quote_quantity());
        // Per fill this was floor(90 * 1.1%) = 0, fifty times over.
        assert!(oi.paid_fees() == 49, oi.paid_fees());
        assert!(sum_fill_taker_fees(&oi) == oi.paid_fees(), sum_fill_taker_fees(&oi));
        // No single fill is charged more than a unit over its own floored share.
        oi.fills().do!(|fill| assert!(fill.taker_fee() <= 1, fill.taker_fee()));

        b.drop_for_testing();
        test.end();
    }

    #[test]
    /// A bid dry run over fragmented liquidity reserves the aggregate fee, so the
    /// swap it sizes settles to exactly the quote it promised.
    ///
    /// The input stops the walk partway through a level: 21 full levels and 88
    /// of the 22nd, 1,978 raw quote owing 21. Priced level by level the fee
    /// would have read as zero, and the swap would have been short 21 at
    /// settlement. A unit here costs under one raw quote, so the dry run takes
    /// one more base past the budget for free: 88,001 of the 22nd level still
    /// floors to 88.
    fun bid_dry_run_on_fragmented_liquidity_matches_settlement() {
        let mut test = begin(OWNER);
        let mut b = book::empty(test.ctx());
        rest_dust_levels(&mut b, false);

        let input = 2_000;
        let (base_out, quote_left) = b.get_quantity_out(0, input, DUST_RATE, 0);
        assert!(base_out == 1_978_001, base_out);
        assert!(quote_left == 1, quote_left);

        let oi = take(&mut b, base_out, true);
        assert!(oi.executed_quantity() == base_out, oi.executed_quantity());
        assert!(oi.paid_fees() == 21, oi.paid_fees());
        assert!(
            input - oi.cumulative_quote_quantity() - oi.paid_fees() == quote_left,
            oi.cumulative_quote_quantity(),
        );

        b.drop_for_testing();
        test.end();
    }

    #[test]
    /// The ask side nets the aggregate fee off its proceeds, and settlement pays
    /// out exactly that.
    fun ask_dry_run_on_fragmented_liquidity_matches_settlement() {
        let mut test = begin(OWNER);
        let mut b = book::empty(test.ctx());
        rest_dust_levels(&mut b, true);

        let input = DUST_LEVELS * DUST_LEVEL_BASE;
        let (base_left, quote_out) = b.get_quantity_out(input, 0, DUST_RATE, 0);
        assert!(base_left == 0, base_left);
        assert!(quote_out == 4_500 - 49, quote_out);

        let oi = take(&mut b, input, false);
        assert!(oi.cumulative_quote_quantity() - oi.paid_fees() == quote_out, oi.paid_fees());

        b.drop_for_testing();
        test.end();
    }
}
