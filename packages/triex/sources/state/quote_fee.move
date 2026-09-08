// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Quote fee module encapsulates quote-denominated fee calculations.
/// Used when pools operate in quote-fee mode instead of CRED-fee mode.
module triexbook::quote_fee {
    use triexbook::constants;

    // === Errors ===
    const EInvalidFeeRate: u64 = 0;

    // === Constants ===
    const FEE_PRECISION: u64 = 10000; // 100.00% = 10000 basis points

    // === Structs ===
    /// Quote-denominated fee information for an order
    public struct QuoteFeeInfo has copy, drop, store {
        /// Fee rate applied (in basis points, e.g., 200 = 2%)
        fee_rate: u64,
        /// Quote fee amount locked for maker orders
        maker_fee_locked: u64,
        /// Quote fee amount paid by taker on execution
        taker_fee_paid: u64,
    }

    // === Public-View Functions ===
    public fun fee_rate(self: &QuoteFeeInfo): u64 {
        self.fee_rate
    }

    public fun maker_fee_locked(self: &QuoteFeeInfo): u64 {
        self.maker_fee_locked
    }

    public fun taker_fee_paid(self: &QuoteFeeInfo): u64 {
        self.taker_fee_paid
    }

    public fun total_fees(self: &QuoteFeeInfo): u64 {
        self.maker_fee_locked + self.taker_fee_paid
    }

    // === Public-Package Functions ===
    /// Create new QuoteFeeInfo with given fee rate
    public(package) fun new(fee_rate: u64): QuoteFeeInfo {
        assert!(fee_rate <= FEE_PRECISION, EInvalidFeeRate);
        QuoteFeeInfo {
            fee_rate,
            maker_fee_locked: 0,
            taker_fee_paid: 0,
        }
    }

    /// Calculate and record maker fee for a limit order
    /// Returns the fee amount to be locked from trading account
    public(package) fun calculate_maker_fee(self: &mut QuoteFeeInfo, quote_quantity: u64): u64 {
        let fee =
            ((quote_quantity as u128) * (self.fee_rate as u128) / (FEE_PRECISION as u128)) as u64;
        self.maker_fee_locked = fee;
        fee
    }

    /// Calculate and record taker fee for an executed order
    /// Returns the fee amount to be deducted from proceeds
    public(package) fun calculate_taker_fee(self: &mut QuoteFeeInfo, quote_quantity: u64): u64 {
        let fee =
            ((quote_quantity as u128) * (self.fee_rate as u128) / (FEE_PRECISION as u128)) as u64;
        self.taker_fee_paid = fee;
        fee
    }

    /// Reset maker fee to zero (used on order cancellation)
    public(package) fun clear_maker_fee(self: &mut QuoteFeeInfo) {
        self.maker_fee_locked = 0;
    }

    /// Create a zero-fee QuoteFeeInfo (for ask orders)
    public(package) fun zero(): QuoteFeeInfo {
        QuoteFeeInfo {
            fee_rate: 0,
            maker_fee_locked: 0,
            taker_fee_paid: 0,
        }
    }

    /// Fee charged on `quote_quantity` at a FLOAT_SCALING-denominated rate.
    /// This is the single source of truth for quote fee amounts: order placement,
    /// fill settlement and dry-run quotes all price through it, so a quote can
    /// never disagree with what settles. Rates are honored at the full precision
    /// governance accepts (FEE_MULTIPLE allows 0.01 bp), and clamped at 100%.
    public(package) fun fee_from_scaled_rate(rate_scaled: u64, quote_quantity: u64): u64 {
        let scaling = constants::float_scaling_u128();
        let rate = if ((rate_scaled as u128) > scaling) scaling else rate_scaled as u128;

        ((quote_quantity as u128) * rate / scaling) as u64
    }

    /// Split escrow released by a cancel, modify-down or expiry into the part
    /// refunded to the maker and the part retained as protocol revenue.
    ///
    /// `retention_bps` is the order's snapshotted retention rate. The refund
    /// floors, so rounding dust lands in the retained half and the two parts
    /// always sum to exactly `basis` — the caller relies on that to decrement
    /// `locked_maker_fees` by the full released amount.
    public(package) fun split_released_fee(basis: u64, retention_bps: u64): (u64, u64) {
        let retention = if (retention_bps > FEE_PRECISION) FEE_PRECISION else retention_bps;
        let refund =
            (
                (basis as u128) * ((FEE_PRECISION - retention) as u128) / (FEE_PRECISION as u128),
            ) as u64;

        (refund, basis - refund)
    }

    /// Convert FLOAT_SCALING based fee rates to basis points (rounded down)
    public(package) fun scaled_to_bps(rate_scaled: u64): u64 {
        let numerator = (rate_scaled as u128) * (FEE_PRECISION as u128);
        let denominator = constants::float_scaling() as u128;
        let result = (numerator / denominator) as u64;

        if (result > FEE_PRECISION) {
            FEE_PRECISION
        } else {
            result
        }
    }

    #[test_only]
    public fun fee_precision(): u64 {
        FEE_PRECISION
    }

    #[test]
    fun test_scaled_to_bps_conversion() {
        let two_percent_scaled = 20_000_000; // represents 2%
        assert!(scaled_to_bps(two_percent_scaled) == 200);

        let zero_scaled = 0;
        assert!(scaled_to_bps(zero_scaled) == 0);

        let max_scaled = constants::float_scaling();
        assert!(scaled_to_bps(max_scaled) == FEE_PRECISION);
    }
}
