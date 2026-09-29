#[test_only]
module triex::math_coverage_tests {
    use std::unit_test::assert_eq;
    use triex::math;

    const FLOAT_SCALING: u64 = 1_000_000_000;
    const MAX_U64: u64 = 0xFFFFFFFFFFFFFFFF;

    #[test]
    /// A zero price is guarded rather than dividing by zero, on both scalings.
    fun min_qty_for_zero_price_is_one() {
        assert_eq!(math::min_qty_for_nonzero_quote(0, FLOAT_SCALING), 1);
        assert_eq!(math::min_qty_for_nonzero_quote(0, 1), 1);
    }

    #[test]
    /// The largest allowed precision is accepted.
    fun sqrt_at_max_precision() {
        assert_eq!(math::sqrt(4 * FLOAT_SCALING, FLOAT_SCALING), 2 * FLOAT_SCALING);
    }

    #[test]
    #[expected_failure(abort_code = math::EInvalidPrecision)]
    fun sqrt_rejects_precision_above_scaling() {
        math::sqrt(4, FLOAT_SCALING + 1);
    }

    #[test]
    #[expected_failure(abort_code = math::EOverflow)]
    fun mul_overflow_aborts() {
        math::mul(MAX_U64, 2 * FLOAT_SCALING);
    }

    #[test]
    #[expected_failure(abort_code = math::EOverflow)]
    fun div_overflow_aborts() {
        math::div(MAX_U64, FLOAT_SCALING / 2);
    }
}
