/// Zero-value fill tests for the coin book.
///
/// `qty_to_quote` floors, so a fill of fewer base units than
/// `math::min_qty_for_nonzero_quote(price)` would settle for zero quote — the taker
/// receiving base without paying for it while the maker's `filled_quantity` advanced
/// uncompensated. The matcher declines such a fill, and placement rejects an order
/// too small to ever produce anything else.
///
/// Fills are deliberately not rounded to a whole multiple of that bound: a quote
/// with few decimals puts ordinary prices well below `FLOAT_SCALING`, so quantizing
/// would truncate normal trades. Only the zero case is refused.
///
/// The bound is derived from each order's own price rather than configured per pool,
/// which is what lets it hold for a base priced at 0.000000001 quote and one priced
/// at 10 billion quote without anyone picking a constant.
#[test_only]
module triex::coin_book_zero_quote_tests {
    use sui::{sui::SUI, test_scenario::begin};
    use token::cred::CRED;
    use triex::{
        constants,
        math,
        pool_test_utils,
        trading_account_tests::{create_acct_and_share_with_funds, USDC}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    /// A raw price of 1e6 — a human price of 0.001 when base and quote share 9
    /// decimals. Entirely ordinary for a cheap base, and it puts the zero-quote
    /// bound at 1000 raw base units, so the effect is observable.
    const CHEAP_PRICE: u64 = 1_000_000;

    #[test]
    /// The bound is the fixed-point reciprocal of the price, and it self-sizes across
    /// the whole range of prices a coin pool has to support.
    fun test_min_qty_for_nonzero_quote_scales_with_price() {
        let scaling = constants::float_scaling();

        // A base worth a billionth of a quote unit: a whole base token buys one unit.
        assert!(math::min_qty_for_nonzero_quote(1, scaling) == 1_000_000_000);
        assert!(math::min_qty_for_nonzero_quote(CHEAP_PRICE, scaling) == 1_000);
        // At parity and above, every raw base unit is already worth a quote unit.
        assert!(math::min_qty_for_nonzero_quote(scaling, scaling) == 1);
        assert!(math::min_qty_for_nonzero_quote(10 * scaling, scaling) == 1);
        assert!(math::min_qty_for_nonzero_quote(constants::max_price(), scaling) == 1);

        // Every bound is tight: one unit below it still floors to zero quote.
        let lot = math::min_qty_for_nonzero_quote(CHEAP_PRICE, scaling);
        assert!(math::qty_to_quote(lot, CHEAP_PRICE, scaling) > 0);
        assert!(math::qty_to_quote(lot - 1, CHEAP_PRICE, scaling) == 0);

        // Multicoin scaling multiplies rather than dividing, so no fill can floor to
        // zero quote and the bound is trivially 1.
        assert!(math::min_qty_for_nonzero_quote(CHEAP_PRICE, 1) == 1);
    }

    /// Rest an ask at `CHEAP_PRICE`, then take `take_quantity` against it as a bid.
    /// Returns (base received by the taker, quote paid by the taker).
    fun sweep_against_cheap_ask(maker_quantity: u64, take_quantity: u64): (u64, u64) {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let maker = create_acct_and_share_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let taker = create_acct_and_share_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(ALICE, registry_id, maker, &mut test);

        pool_test_utils::place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            maker,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            CHEAP_PRICE,
            maker_quantity,
            false,
            constants::max_u64(),
            &mut test,
        );

        let info = pool_test_utils::place_limit_order<SUI, USDC>(
            BOB,
            pool_id,
            taker,
            constants::immediate_or_cancel(),
            constants::self_matching_allowed(),
            CHEAP_PRICE,
            take_quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        let executed = info.executed_quantity();
        let quote_paid = info.cumulative_quote_quantity();

        test.end();

        (executed, quote_paid)
    }

    /// As `sweep_against_cheap_ask`, but the taker crosses with a market order.
    /// Market orders are exempt from the placement floor — they match at each maker's
    /// price rather than the sentinel price they carry — so this is the path that
    /// reaches the matcher with a sub-lot quantity, and the one the original exploit
    /// reduces to.
    fun market_sweep_against_cheap_ask(maker_quantity: u64, take_quantity: u64): (u64, u64) {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let maker = create_acct_and_share_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let taker = create_acct_and_share_with_funds(
            BOB,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(ALICE, registry_id, maker, &mut test);

        pool_test_utils::place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            maker,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            CHEAP_PRICE,
            maker_quantity,
            false,
            constants::max_u64(),
            &mut test,
        );

        let info = pool_test_utils::place_market_order<SUI, USDC>(
            BOB,
            pool_id,
            taker,
            constants::self_matching_allowed(),
            take_quantity,
            true,
            &mut test,
        );
        let executed = info.executed_quantity();
        let quote_paid = info.cumulative_quote_quantity();

        test.end();

        (executed, quote_paid)
    }

    #[test]
    /// The regression. A taker asking for less than one quote unit's worth of base
    /// used to be filled for zero quote — free base, and the maker's fill counter
    /// advanced for nothing. It must now fill nothing at all.
    fun test_sub_lot_take_fills_nothing_rather_than_filling_free() {
        let lot = math::min_qty_for_nonzero_quote(CHEAP_PRICE, constants::float_scaling());
        let (executed, quote_paid) = market_sweep_against_cheap_ask(
            1 * constants::float_scaling(),
            lot - 1,
        );

        assert!(executed == 0);
        assert!(quote_paid == 0);
    }

    #[test]
    /// A market taker consumes a maker whose size is not a whole multiple of the
    /// bound in full, and pays for all of it.
    fun test_market_sweep_consumes_maker_in_full() {
        let lot = math::min_qty_for_nonzero_quote(CHEAP_PRICE, constants::float_scaling());
        let maker_quantity = 3 * lot + (lot / 2);
        let (executed, quote_paid) = market_sweep_against_cheap_ask(
            maker_quantity,
            maker_quantity,
        );

        assert!(executed == maker_quantity);
        assert!(
            quote_paid == math::qty_to_quote(executed, CHEAP_PRICE, constants::float_scaling()),
        );
    }

    #[test]
    /// Exactly one lot is the smallest fill that may happen, and it is paid for.
    fun test_take_of_exactly_one_lot_fills_and_is_paid_for() {
        let lot = math::min_qty_for_nonzero_quote(CHEAP_PRICE, constants::float_scaling());
        let (executed, quote_paid) = sweep_against_cheap_ask(
            1 * constants::float_scaling(),
            lot,
        );

        assert!(executed == lot);
        assert!(quote_paid > 0);
    }

    #[test]
    /// An ordinary take is filled in full, not rounded down to a multiple of the
    /// bound. This is the guard against over-correcting: quantizing here would shave
    /// every trade in any pool whose quote has few decimals.
    fun test_ordinary_take_is_not_quantized() {
        let lot = math::min_qty_for_nonzero_quote(CHEAP_PRICE, constants::float_scaling());
        let take = 2 * lot + (lot / 2);
        let (executed, quote_paid) = sweep_against_cheap_ask(1 * constants::float_scaling(), take);

        assert!(executed == take);
        assert!(
            quote_paid == math::qty_to_quote(executed, CHEAP_PRICE, constants::float_scaling()),
        );
        assert!(quote_paid > 0);
    }

    #[test]
    #[expected_failure(abort_code = ::triex::coin_order_info::EOrderBelowMinimumSize)]
    /// An order too small to ever yield a non-zero fill is refused rather than left
    /// to rest as permanently unfillable dust.
    fun test_placing_sub_lot_order_is_rejected() {
        let lot = math::min_qty_for_nonzero_quote(CHEAP_PRICE, constants::float_scaling());
        sweep_against_cheap_ask(lot - 1, lot);
    }

    #[test]
    /// The floor does not restrict ordinary pools: at a price at or above one quote
    /// unit per base unit the bound is 1, so the smallest expressible order is legal.
    fun test_minimum_is_one_unit_at_or_above_parity() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let maker = create_acct_and_share_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(ALICE, registry_id, maker, &mut test);

        let info = pool_test_utils::place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            maker,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            1,
            true,
            constants::max_u64(),
            &mut test,
        );
        assert!(info.order_inserted());

        test.end();
    }
}
