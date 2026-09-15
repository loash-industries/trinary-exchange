module triex::math {
    /// scaling setting for float
    const FLOAT_SCALING: u64 = 1_000_000_000;
    const FLOAT_SCALING_U128: u128 = 1_000_000_000;
    const MAX_U64: u128 = 0xFFFFFFFFFFFFFFFF;

    /// Error codes
    const EInvalidPrecision: u64 = 0;
    const EOverflow: u64 = 1;

    /// Convert a base quantity to a raw quote quantity using pool-specific price scaling.
    ///
    /// - Normal pools (price_scaling = FLOAT_SCALING): equivalent to mul(base_qty, price),
    ///   i.e. base_qty × price / FLOAT_SCALING.
    /// - Multicoin pools (price_scaling = 1): direct product base_qty × price with no
    ///   division, since the price is already encoded as human_price × QUOTE_UNIT.
    public fun qty_to_quote(base_qty: u64, price: u64, price_scaling: u64): u64 {
        if (price_scaling == FLOAT_SCALING) {
            mul(base_qty, price)
        } else {
            let result = (base_qty as u128) * (price as u128);
            assert!(result <= MAX_U64, EOverflow);
            result as u64
        }
    }

    /// Convert a raw quote quantity to a base quantity using pool-specific price scaling.
    /// Inverse of qty_to_quote: base = quote × price_scaling / price.
    ///
    /// Truncates toward zero (buyer-conservative): the caller cannot acquire more base
    /// than the quote strictly covers. Any unspent quote remainder stays with the taker.
    ///
    /// - Normal pools (price_scaling = FLOAT_SCALING): equivalent to div(quote_qty, price).
    /// - Multicoin pools (price_scaling = 1): integer division quote_qty / price.
    public fun quote_to_qty(quote_qty: u64, price: u64, price_scaling: u64): u64 {
        if (price_scaling == FLOAT_SCALING) {
            div(quote_qty, price)
        } else {
            quote_qty / price
        }
    }

    /// The smallest base quantity that converts to a non-zero raw quote amount at
    /// `price` — a minimum order size, derived from the price instead of configured.
    ///
    /// `qty_to_quote` floors, so a fill of fewer base units than this settles for
    /// zero quote: the taker would receive base without paying for it, and the
    /// maker's `filled_quantity` would advance uncompensated. An order below this
    /// bound can never produce a fill the matcher will accept, so placement rejects
    /// it rather than letting it rest as permanently unfillable dust. Deriving the
    /// bound from the order's own price is what makes it work for a base priced at
    /// 0.000000001 quote and one priced at 10 billion quote without anyone choosing a
    /// per-pool constant.
    ///
    /// Under multicoin scaling (`price_scaling == 1`) the conversion is a bare
    /// product, so any non-zero quantity already yields non-zero quote and the
    /// answer is 1 — the zero-quote case is specific to the coin pools' fixed-point
    /// division.
    public fun min_qty_for_nonzero_quote(price: u64, price_scaling: u64): u64 {
        // Unreachable for a resting order — `MIN_PRICE` is 1 — but the fixed-point
        // reciprocal below would divide by zero, so it is guarded rather than
        // assumed. Quantizing to 1 is the identity, matching the multicoin branch.
        if (price == 0) return 1;
        if (price_scaling == FLOAT_SCALING) {
            // ceil(FLOAT_SCALING / price): the reciprocal of the price, rounded up.
            div_round_up(1, price)
        } else {
            1
        }
    }

    /// Multiply two floating numbers.
    /// This function will round down the result.
    public fun mul(x: u64, y: u64): u64 {
        let (_, result) = mul_internal(x, y);

        result
    }

    /// Multiply two floating numbers.
    /// This function will round up the result.
    public fun mul_round_up(x: u64, y: u64): u64 {
        let (is_round_down, result) = mul_internal(x, y);

        result + is_round_down
    }

    /// Divide two floating numbers.
    /// This function will round down the result.
    public fun div(x: u64, y: u64): u64 {
        let (_, result) = div_internal(x, y);

        result
    }

    /// Divide two floating numbers.
    /// This function will round up the result.
    public fun div_round_up(x: u64, y: u64): u64 {
        let (is_round_down, result) = div_internal(x, y);

        result + is_round_down
    }

    /// Computes the integer square root of a scaled u64 value, assuming the
    /// original value
    /// is scaled by precision. The result will be in the same floating-point
    /// representation.
    public fun sqrt(x: u64, precision: u64): u64 {
        assert!(precision <= FLOAT_SCALING, EInvalidPrecision);
        let multiplier = (FLOAT_SCALING / precision) as u128;
        let scaled_x: u128 = (x as u128) * multiplier * FLOAT_SCALING_U128;
        let sqrt_scaled_x: u128 = std::u128::sqrt(scaled_x);

        (sqrt_scaled_x / multiplier) as u64
    }

    public fun is_power_of_ten(n: u64): bool {
        let mut num = n;

        if (num < 1) {
            false
        } else {
            while (num % 10 == 0) {
                num = num / 10;
            };

            num == 1
        }
    }

    fun mul_internal(x: u64, y: u64): (u64, u64) {
        let x = x as u128;
        let y = y as u128;
        let round = if ((x * y) % FLOAT_SCALING_U128 == 0) 0 else 1;
        let result = x * y / FLOAT_SCALING_U128;
        assert!(result <= MAX_U64, EOverflow);

        (round, result as u64)
    }

    fun div_internal(x: u64, y: u64): (u64, u64) {
        let x = x as u128;
        let y = y as u128;
        let round = if ((x * FLOAT_SCALING_U128 % y) == 0) 0 else 1;
        let result = x * FLOAT_SCALING_U128 / y;
        assert!(result <= MAX_U64, EOverflow);

        (round, result as u64)
    }

    #[test]
    /// Test sqrt function
    fun test_sqrt() {
        let scaling = 1_000_000;
        let precision_6 = 1_000_000;
        let precision_9 = 1_000_000_000;

        assert!(sqrt(0, precision_6) == 0, 0);
        assert!(sqrt(1 * scaling, precision_6) == 1 * scaling, 0);
        assert!(sqrt(2 * scaling, precision_6) == 1_414_213, 0);
        assert!(sqrt(25 * scaling, precision_6) == 5 * scaling, 0);
        assert!(sqrt(59 * scaling, precision_6) == 7_681_145, 0);
        assert!(sqrt(100_000 * scaling, precision_6) == 316_227_766, 0);
        assert!(sqrt(300_000 * scaling, precision_6) == 547_722_557, 0);
        assert!(sqrt(100_000_000, precision_6) == 10_000_000, 0);

        assert!(sqrt(0, precision_9) == 0, 0);
        assert!(sqrt(1_000 * scaling, precision_9) == 1_000 * scaling, 0);
        assert!(sqrt(2_000 * scaling, precision_9) == 1_414_213_562, 0);
        assert!(sqrt(2_250 * scaling, precision_9) == 1_500 * scaling, 0);
        assert!(sqrt(25_000 * scaling, precision_9) == 5_000 * scaling, 0);
        assert!(sqrt(59_000 * scaling, precision_9) == 7_681_145_747, 0);
        assert!(sqrt(100_000_000 * scaling, precision_9) == 316_227_766_016, 0);
        assert!(sqrt(300_000_000 * scaling, precision_9) == 547_722_557_505, 0);
        assert!(sqrt(100_000_000_000, precision_9) == 10_000_000_000, 0);
    }

    #[test]
    /// Test is_power_of_ten function
    fun test_is_power_of_ten() {
        assert!(is_power_of_ten(1), 0);
        assert!(is_power_of_ten(10), 0);
        assert!(is_power_of_ten(100), 0);
        assert!(is_power_of_ten(1000), 0);
        assert!(is_power_of_ten(10000), 0);
        assert!(is_power_of_ten(100000), 0);
        assert!(!is_power_of_ten(0), 0);
        assert!(!is_power_of_ten(2), 0);
        assert!(!is_power_of_ten(3), 0);
        assert!(!is_power_of_ten(20), 0);
        assert!(!is_power_of_ten(1001), 0);
    }
}
