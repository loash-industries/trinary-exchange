// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Quote fee module encapsulates quote-denominated fee calculations.
/// Used when pools operate in quote-fee mode instead of CRED-fee mode.
module triexbook::quote_fee;

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
/// Returns the fee amount to be locked from balance manager
public(package) fun calculate_maker_fee(self: &mut QuoteFeeInfo, quote_quantity: u64): u64 {
    let fee = ((quote_quantity as u128) * (self.fee_rate as u128) / (FEE_PRECISION as u128)) as u64;
    self.maker_fee_locked = fee;
    fee
}

/// Calculate and record taker fee for an executed order
/// Returns the fee amount to be deducted from proceeds
public(package) fun calculate_taker_fee(self: &mut QuoteFeeInfo, quote_quantity: u64): u64 {
    let fee = ((quote_quantity as u128) * (self.fee_rate as u128) / (FEE_PRECISION as u128)) as u64;
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
