// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::quote_fee_tests {
    use triexbook::{constants, quote_fee};

    // === fee_from_scaled_rate ===
    // The single helper every quote fee prices through: order placement, fill
    // settlement and dry-run quotes. Rates are FLOAT_SCALING-denominated.

    #[test]
    fun test_fee_from_scaled_rate_basic_percentages() {
        // 2% of 1_000_000
        assert!(quote_fee::fee_from_scaled_rate(20_000_000, 1_000_000) == 20_000);
        // 1.8%, the launch maker default
        assert!(quote_fee::fee_from_scaled_rate(18_000_000, 1_000_000) == 18_000);
        // 0.01 bp, the finest rate FEE_MULTIPLE admits, is honored rather than
        // truncated away — the reason this helper is not bps-denominated.
        assert!(quote_fee::fee_from_scaled_rate(1_000, 1_000_000_000) == 1_000);
    }

    #[test]
    fun test_fee_from_scaled_rate_zero_cases() {
        assert!(quote_fee::fee_from_scaled_rate(0, 1_000_000) == 0);
        assert!(quote_fee::fee_from_scaled_rate(20_000_000, 0) == 0);
    }

    #[test]
    fun test_fee_from_scaled_rate_rounds_down() {
        // 2% of 99 is 1.98; the fee floors so it can never exceed the quote it
        // is charged on.
        assert!(quote_fee::fee_from_scaled_rate(20_000_000, 99) == 1);
    }

    #[test]
    fun test_fee_from_scaled_rate_at_full_rate() {
        let full = constants::float_scaling();
        assert!(quote_fee::fee_from_scaled_rate(full, 1_000_000) == 1_000_000);
    }

    #[test]
    fun test_fee_from_scaled_rate_clamps_above_full_rate() {
        // Governance caps rates at 100% (MAX_TAKER_FEE == FLOAT_SCALING), so no
        // production path reaches this. The clamp is what keeps the fee bounded
        // by the quote regardless, which `calculate_partial_fill_balances` relies
        // on when it settles `cumulative_quote_quantity - total_taker_fee`.
        let over = constants::float_scaling() * 5;
        assert!(quote_fee::fee_from_scaled_rate(over, 1_000_000) == 1_000_000);
    }

    #[test]
    fun test_fee_from_scaled_rate_large_quantities() {
        // 2% of 1T, well past u64 range once multiplied, so the u128 widening
        // is doing real work here.
        assert!(quote_fee::fee_from_scaled_rate(20_000_000, 1_000_000_000_000) == 20_000_000_000);
    }

    // === split_released_fee ===
    // The 80/20 cancel split. Rounding dust must land in the retained half so the
    // two parts sum to exactly the basis — `locked_maker_fees` is decremented by
    // that sum, and a short decrement would leave escrow stranded forever.

    #[test]
    fun test_split_released_fee_default_retention() {
        let (refund, retained) = quote_fee::split_released_fee(1_000, 2000);
        assert!(refund == 800);
        assert!(retained == 200);
    }

    #[test]
    fun test_split_released_fee_rounds_dust_to_retained() {
        // 7 * 8000 / 10000 = 5.6 -> refund floors to 5, so retention takes the
        // extra unit rather than the refund over-paying.
        let (refund, retained) = quote_fee::split_released_fee(7, 2000);
        assert!(refund == 5);
        assert!(retained == 2);
        assert!(refund + retained == 7);
    }

    #[test]
    fun test_split_released_fee_sums_to_basis_across_range() {
        let mut basis = 0;
        while (basis < 200) {
            let (refund, retained) = quote_fee::split_released_fee(basis, 2000);
            assert!(refund + retained == basis);
            assert!(refund <= basis);
            basis = basis + 1;
        };
    }

    #[test]
    fun test_split_released_fee_zero_retention_refunds_all() {
        let (refund, retained) = quote_fee::split_released_fee(1_000, 0);
        assert!(refund == 1_000);
        assert!(retained == 0);
    }

    #[test]
    fun test_split_released_fee_full_retention_refunds_none() {
        let (refund, retained) = quote_fee::split_released_fee(1_000, 10000);
        assert!(refund == 0);
        assert!(retained == 1_000);
    }

    #[test]
    fun test_split_released_fee_clamps_retention_above_full() {
        // Governance caps the rate at 10000 bps, but the helper must not
        // underflow if it is ever handed more.
        let (refund, retained) = quote_fee::split_released_fee(1_000, 50_000);
        assert!(refund == 0);
        assert!(retained == 1_000);
    }

    #[test]
    fun test_split_released_fee_zero_basis() {
        let (refund, retained) = quote_fee::split_released_fee(0, 2000);
        assert!(refund == 0);
        assert!(retained == 0);
    }
}
