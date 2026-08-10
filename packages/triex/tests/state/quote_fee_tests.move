// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::quote_fee_tests;

use triexbook::quote_fee;

// const ALICE: address = @0xA11CE;

#[test]
fun test_new_quote_fee_info() {
    let fee_info = quote_fee::new(200); // 2%
    assert!(fee_info.fee_rate() == 200);
    assert!(fee_info.maker_fee_locked() == 0);
    assert!(fee_info.taker_fee_paid() == 0);
    assert!(fee_info.total_fees() == 0);
}

#[test]
fun test_calculate_maker_fee() {
    let mut fee_info = quote_fee::new(200); // 2%
    let quote_quantity = 1_000_000; // 1M quote units

    let maker_fee = fee_info.calculate_maker_fee(quote_quantity);

    assert!(maker_fee == 20_000); // 2% of 1M = 20K
    assert!(fee_info.maker_fee_locked() == 20_000);
    assert!(fee_info.taker_fee_paid() == 0);
    assert!(fee_info.total_fees() == 20_000);
}

#[test]
fun test_calculate_taker_fee() {
    let mut fee_info = quote_fee::new(200); // 2%
    let quote_quantity = 500_000; // 500K quote units

    let taker_fee = fee_info.calculate_taker_fee(quote_quantity);

    assert!(taker_fee == 10_000); // 2% of 500K = 10K
    assert!(fee_info.maker_fee_locked() == 0);
    assert!(fee_info.taker_fee_paid() == 10_000);
    assert!(fee_info.total_fees() == 10_000);
}

#[test]
fun test_maker_and_taker_fees_combined() {
    let mut fee_info = quote_fee::new(200); // 2%

    let maker_fee = fee_info.calculate_maker_fee(1_000_000);
    let taker_fee = fee_info.calculate_taker_fee(500_000);

    assert!(maker_fee == 20_000);
    assert!(taker_fee == 10_000);
    assert!(fee_info.maker_fee_locked() == 20_000);
    assert!(fee_info.taker_fee_paid() == 10_000);
    assert!(fee_info.total_fees() == 30_000);
}

#[test]
fun test_clear_maker_fee() {
    let mut fee_info = quote_fee::new(200);

    fee_info.calculate_maker_fee(1_000_000);
    assert!(fee_info.maker_fee_locked() == 20_000);

    fee_info.clear_maker_fee();
    assert!(fee_info.maker_fee_locked() == 0);
    assert!(fee_info.taker_fee_paid() == 0);
    assert!(fee_info.total_fees() == 0);
}

#[test]
fun test_zero_fee_info() {
    let fee_info = quote_fee::zero();

    assert!(fee_info.fee_rate() == 0);
    assert!(fee_info.maker_fee_locked() == 0);
    assert!(fee_info.taker_fee_paid() == 0);
    assert!(fee_info.total_fees() == 0);
}

#[test]
fun test_zero_fee_calculations() {
    let mut fee_info = quote_fee::zero();

    let maker_fee = fee_info.calculate_maker_fee(1_000_000);
    let taker_fee = fee_info.calculate_taker_fee(500_000);

    assert!(maker_fee == 0);
    assert!(taker_fee == 0);
    assert!(fee_info.total_fees() == 0);
}

#[test]
fun test_max_fee_rate() {
    let fee_info = quote_fee::new(10000); // 100%
    assert!(fee_info.fee_rate() == 10000);
}

#[test]
#[expected_failure(abort_code = quote_fee::EInvalidFeeRate)]
fun test_invalid_fee_rate_e() {
    quote_fee::new(10001); // Over 100%
}

#[test]
fun test_fee_precision() {
    let mut fee_info = quote_fee::new(50); // 0.5%
    let quote_quantity = 1_000_000;

    let maker_fee = fee_info.calculate_maker_fee(quote_quantity);

    assert!(maker_fee == 5_000); // 0.5% of 1M = 5K
}

#[test]
fun test_small_quantity_rounding() {
    let mut fee_info = quote_fee::new(200); // 2%
    let small_quantity = 100;

    let maker_fee = fee_info.calculate_maker_fee(small_quantity);

    // (100 * 200) / 10000 = 2
    assert!(maker_fee == 2);
}

#[test]
fun test_fee_rounding_down() {
    let mut fee_info = quote_fee::new(200); // 2%
    let quantity = 149; // Will round down

    let maker_fee = fee_info.calculate_maker_fee(quantity);

    // (149 * 200) / 10000 = 2.98 -> 2
    assert!(maker_fee == 2);
}

#[test]
fun test_multiple_calculations() {
    let mut fee_info = quote_fee::new(200);

    // First calculation
    let fee1 = fee_info.calculate_maker_fee(1_000_000);
    assert!(fee1 == 20_000);
    assert!(fee_info.maker_fee_locked() == 20_000);

    // Second calculation overwrites
    let fee2 = fee_info.calculate_maker_fee(500_000);
    assert!(fee2 == 10_000);
    assert!(fee_info.maker_fee_locked() == 10_000); // Overwritten, not accumulated
}

#[test]
fun test_large_quantities() {
    let mut fee_info = quote_fee::new(200); // 2%
    let large_quantity = 1_000_000_000_000; // 1 trillion

    let maker_fee = fee_info.calculate_maker_fee(large_quantity);

    assert!(maker_fee == 20_000_000_000); // 2% of 1T = 20B
}
