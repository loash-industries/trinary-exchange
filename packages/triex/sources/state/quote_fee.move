// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Quote fee module encapsulates quote-denominated fee calculations.
/// Used when pools operate in quote-fee mode instead of CRED-fee mode.
///
/// Rates arrive here FLOAT_SCALING-denominated, matching what the fee policy stores
/// and what an order snapshots. `FEE_PRECISION` below is basis points and is
/// used only for the cancel-retention split, which the fee policy also expresses in
/// bps — the two scales are deliberate, not interchangeable.
module triexbook::quote_fee {
    use triexbook::constants;

    // === Constants ===
    const FEE_PRECISION: u64 = 10000; // 100.00% = 10000 basis points

    // === Public-Package Functions ===
    /// Fee charged on `quote_quantity` at a FLOAT_SCALING-denominated rate.
    /// This is the single source of truth for quote fee amounts: order placement,
    /// fill settlement and dry-run quotes all price through it, so a quote can
    /// never disagree with what settles. Rates are honored at the full precision
    /// the policy accepts (FEE_MULTIPLE allows 0.01 bp), and clamped at 100%.
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

    #[test_only]
    public fun fee_precision(): u64 {
        FEE_PRECISION
    }
}
