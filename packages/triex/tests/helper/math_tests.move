// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Rounding-direction tests for the fixed-point helpers every fee, fill and
/// escrow amount is computed through.
///
/// `math.move` documents its rounding in comments — `mul`/`div` floor,
/// `*_round_up` take the ceiling, and `quote_to_qty` truncates toward zero so a
/// taker can never acquire more base than their quote strictly covers — but
/// nothing pinned any of it. The direction is the whole safety property here: a
/// floor that silently becomes a ceiling pays out a raw unit the vault never
/// took in, once per fill, forever.
#[test_only]
module triexbook::math_tests {
    use triexbook::math;

    const FLOAT_SCALING: u64 = 1_000_000_000;

    /// What multicoin pools pass as `price_scaling`. The price is already encoded
    /// as human_price × QUOTE_UNIT, so the conversion divides by nothing.
    const NO_SCALING: u64 = 1;

    // === mul ===

    #[test]
    fun test_mul_rounds_down() {
        // The smallest dust there is: one raw unit times one raw unit is a
        // billionth of a unit, and flooring it is what keeps the vault from
        // paying out something it never received.
        assert!(math::mul(1, 1) == 0, 0);
        // 3 raw units at half scale is 1.5, floored to 1.
        assert!(math::mul(3, FLOAT_SCALING / 2) == 1, 1);
        // (1e9 + 1)^2 = 1e18 + 2e9 + 1, so the quotient carries a remainder of 1.
        assert!(math::mul(1_000_000_001, 1_000_000_001) == 1_000_000_002, 2);
    }

    #[test]
    fun test_mul_round_up_takes_the_ceiling() {
        // Same three inputs as above, one unit higher in every case that has a
        // remainder. This is the rate-charging direction: never undercharge.
        assert!(math::mul_round_up(1, 1) == 1, 0);
        assert!(math::mul_round_up(3, FLOAT_SCALING / 2) == 2, 1);
        assert!(math::mul_round_up(1_000_000_001, 1_000_000_001) == 1_000_000_003, 2);
    }

    #[test]
    fun test_mul_agrees_in_both_directions_when_exact() {
        // No remainder means there is nothing to round, so floor and ceiling must
        // land on the same number. Scaling by one is the identity.
        assert!(math::mul(FLOAT_SCALING, 12_345) == 12_345, 0);
        assert!(math::mul_round_up(FLOAT_SCALING, 12_345) == 12_345, 1);
        assert!(math::mul(2 * FLOAT_SCALING, 21) == 42, 2);
        assert!(math::mul_round_up(2 * FLOAT_SCALING, 21) == 42, 3);
    }

    // === div ===

    #[test]
    fun test_div_rounds_down() {
        // A third, in fixed point, drops its trailing third.
        assert!(math::div(1, 3) == 333_333_333, 0);
        // One raw unit split across two whole units is half a raw unit, floored
        // to nothing at all.
        assert!(math::div(1, 2 * FLOAT_SCALING) == 0, 1);
    }

    #[test]
    fun test_div_round_up_takes_the_ceiling() {
        assert!(math::div_round_up(1, 3) == 333_333_334, 0);
        assert!(math::div_round_up(1, 2 * FLOAT_SCALING) == 1, 1);
    }

    #[test]
    fun test_div_agrees_in_both_directions_when_exact() {
        assert!(math::div(FLOAT_SCALING, FLOAT_SCALING) == FLOAT_SCALING, 0);
        assert!(math::div_round_up(FLOAT_SCALING, FLOAT_SCALING) == FLOAT_SCALING, 1);
        assert!(math::div(7, FLOAT_SCALING) == 7, 2);
        assert!(math::div_round_up(7, FLOAT_SCALING) == 7, 3);
    }

    // === qty_to_quote / quote_to_qty ===

    #[test]
    fun test_qty_to_quote_on_a_standard_pool_is_mul() {
        let price = 2 * FLOAT_SCALING;
        let quantity = 100 * FLOAT_SCALING;
        assert!(math::qty_to_quote(quantity, price, FLOAT_SCALING) == 200 * FLOAT_SCALING, 0);
        assert!(
            math::qty_to_quote(quantity, price, FLOAT_SCALING) == math::mul(quantity, price),
            1,
        );
        // And it inherits `mul`'s floor: a billionth of a unit of notional is
        // dropped rather than rounded into existence.
        assert!(math::qty_to_quote(1, 1, FLOAT_SCALING) == 0, 2);
    }

    #[test]
    fun test_qty_to_quote_on_a_multicoin_pool_is_an_exact_product() {
        // `price_scaling = 1` divides by nothing, so this branch cannot round at
        // all — which is the entire reason multicoin prices are pre-encoded
        // against the quote unit.
        assert!(math::qty_to_quote(100, 2, NO_SCALING) == 200, 0);
        assert!(math::qty_to_quote(7, 3, NO_SCALING) == 21, 1);
        assert!(math::qty_to_quote(1, 1, NO_SCALING) == 1, 2);
    }

    #[test]
    #[expected_failure(abort_code = triexbook::math::EOverflow)]
    fun test_qty_to_quote_multicoin_overflow_aborts() {
        // 2^32 × 2^32 is 2^64, exactly one past what a u64 can hold. The
        // undivided multicoin branch is the only place a product this large can
        // reach a cast, so it is the only place that needs the guard.
        math::qty_to_quote(4_294_967_296, 4_294_967_296, NO_SCALING);
    }

    #[test]
    fun test_quote_to_qty_truncates_toward_zero() {
        // Standard pool: 200 quote at price 3 covers 66.666... base, floored.
        assert!(
            math::quote_to_qty(200 * FLOAT_SCALING, 3 * FLOAT_SCALING, FLOAT_SCALING) == 66_666_666_666,
            0,
        );
        // Multicoin: plain integer division. The remainder stays with the taker
        // rather than buying them a unit of base it does not cover.
        assert!(math::quote_to_qty(200, 3, NO_SCALING) == 66, 1);
        assert!(math::quote_to_qty(2, 3, NO_SCALING) == 0, 2);
    }

    // === Round-trip invariant ===

    #[test]
    fun test_multicoin_round_trip_never_favors_the_taker() {
        // The documented invariant behind `quote_to_qty`: a taker cannot acquire
        // more base than their quote strictly covers. So quote → base → quote can
        // only ever land at or below where it started. If this ever inverts, every
        // swap hands out value the vault never received.
        let prices = vector[1u64, 2, 3, 7, 999, 1_000, 1_000_003];
        let mut p = 0;
        while (p < prices.length()) {
            let price = prices[p];
            let mut quote = 0;
            while (quote < 200) {
                let base = math::quote_to_qty(quote, price, NO_SCALING);
                assert!(math::qty_to_quote(base, price, NO_SCALING) <= quote, 0);
                quote = quote + 1;
            };
            p = p + 1;
        };
    }

    #[test]
    fun test_standard_round_trip_never_favors_the_taker() {
        // Same invariant across the scaled branch, at prices and quote amounts
        // chosen so nothing divides evenly.
        let prices = vector[
            FLOAT_SCALING / 3,
            FLOAT_SCALING,
            3 * FLOAT_SCALING,
            7 * FLOAT_SCALING + 13,
        ];
        let mut p = 0;
        while (p < prices.length()) {
            let price = prices[p];
            let mut i = 0;
            while (i < 100) {
                let quote = 1_000_000_007 * (i + 1) + i;
                let base = math::quote_to_qty(quote, price, FLOAT_SCALING);
                assert!(math::qty_to_quote(base, price, FLOAT_SCALING) <= quote, 0);
                i = i + 1;
            };
            p = p + 1;
        };
    }
}
