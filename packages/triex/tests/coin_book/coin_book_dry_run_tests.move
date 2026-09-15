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
    use triex::{coin_book::{Self, Book}, coin_order_info, constants, math, quote_fee};

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;

    fun rest(b: &mut Book, price: u64, qty: u64, is_bid: bool) {
        let mut oi = coin_order_info::new(
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
            coin_book::price_scaling(b),
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
        let mut b = coin_book::empty(test.ctx());
        // One deep ask at human price 1.00 (price = 1e6 for a 6-decimal quote
        // against a 9-decimal base), so a single level absorbs the whole input.
        rest(&mut b, 1_000_000, 10_000_000_000_000, false);

        let taker_rate = 11_000_000; // 1.10%
        let input = 1_000_000_000; // 1_000 CRED at 6 decimals
        let (base_out, quote_left) = b.get_quantity_out(0, input, taker_rate, 0);

        // What settlement charges for the base this quote says it buys.
        let quote_spent = math::qty_to_quote(base_out, 1_000_000, coin_book::price_scaling(&b));
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
        let mut b = coin_book::empty(test.ctx());
        rest(&mut b, 1_000_000, 10_000_000_000_000, false);

        let taker_rate = 22_000_000; // 2.20%, where the old gap was widest
        let input = 1_000_000_000;
        let (base_out, quote_left) = b.get_quantity_out(0, input, taker_rate, 0);

        // Sell the base straight back into a bid at the same price.
        let mut b2 = coin_book::empty(test.ctx());
        rest(&mut b2, 1_000_000, 10_000_000_000_000, true);
        let (base_left, quote_out) = b2.get_quantity_out(base_out, 0, taker_rate, 0);
        assert!(base_left == 0, 0);

        let leg = quote_fee::fee_from_scaled_rate(
            taker_rate,
            math::qty_to_quote(base_out, 1_000_000, coin_book::price_scaling(&b)),
        );
        // Everything the round trip did not return is fee, and it is exactly two
        // of them. Under the multiplier the bid leg also held back 0.25x its fee
        // and never spent it, so this came up short by that much.
        assert!(quote_out + quote_left == input - 2 * leg, quote_out + quote_left);

        b.drop_for_testing();
        b2.drop_for_testing();
        test.end();
    }
}
