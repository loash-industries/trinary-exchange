// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::governance_admin_tests;

use sui::test_scenario::{begin, end};
use triexbook::governance;

const OWNER: address = @0xF;

#[test]
fun default_rates_ok() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Pool creation defaults: taker 2.2%, maker 1.8%
    assert!(gov.trade_params().taker_fee() == 22000000, 0);
    assert!(gov.trade_params().maker_fee() == 18000000, 0);
    assert!(gov.next_trade_params().taker_fee() == 22000000, 0);
    assert!(gov.next_trade_params().maker_fee() == 18000000, 0);

    governance::destroy_for_testing(gov);
    end(test);
}

#[test]
fun admin_set_fee_volatile_ok() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Set new rates: taker 1%, maker 0.5%
    gov.set_next_trade_params(10000000, 5000000);

    // Verify next_trade_params has been updated
    let next_params = gov.next_trade_params();
    assert!(next_params.taker_fee() == 10000000, 0);
    assert!(next_params.maker_fee() == 5000000, 0);

    // Update to next epoch to apply the fee
    test.next_epoch(OWNER);
    gov.update(test.ctx());

    // Verify current trade_params now has the new rates
    let current_params = gov.trade_params();
    assert!(current_params.taker_fee() == 10000000, 0);
    assert!(current_params.maker_fee() == 5000000, 0);

    governance::destroy_for_testing(gov);
    end(test);
}

#[test]
fun admin_set_fee_stable_ok() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Set new rates for stable pool (taker 0.05%, maker 0.03%)
    gov.set_next_trade_params(50000, 30000);

    let next_params = gov.next_trade_params();
    assert!(next_params.taker_fee() == 50000, 0);
    assert!(next_params.maker_fee() == 30000, 0);

    governance::destroy_for_testing(gov);
    end(test);
}

#[test]
fun admin_set_maker_fee_zero_ok() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Maker rate has no floor: zero is allowed while the taker keeps its floor
    gov.set_next_trade_params(10000000, 0);

    let next_params = gov.next_trade_params();
    assert!(next_params.taker_fee() == 10000000, 0);
    assert!(next_params.maker_fee() == 0, 0);

    governance::destroy_for_testing(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun admin_set_taker_fee_not_multiple_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Taker fee not a multiple of FEE_MULTIPLE (1000)
    gov.set_next_trade_params(10001, 5000000);

    abort 1
}

#[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
fun admin_set_maker_fee_not_multiple_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Maker fee not a multiple of FEE_MULTIPLE (1000)
    gov.set_next_trade_params(10000000, 5000001);

    abort 1
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun admin_set_fee_volatile_too_low_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Taker fee below MIN_TAKER_VOLATILE (100,000)
    gov.set_next_trade_params(50000, 0);

    abort 1
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun admin_set_fee_volatile_too_high_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Taker fee above MAX_TAKER_VOLATILE (22,000,000 = 2.2%)
    gov.set_next_trade_params(23000000, 5000000);

    abort 1
}

#[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
fun admin_set_maker_fee_volatile_too_high_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Maker fee above MAX_MAKER_VOLATILE (18,000,000 = 1.8%)
    gov.set_next_trade_params(10000000, 19000000);

    abort 1
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun admin_set_fee_stable_too_low_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Taker fee below MIN_FEE_RATE_STABLE (10,000)
    gov.set_next_trade_params(5000, 0);

    abort 1
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun admin_set_fee_stable_too_high_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Taker fee above MAX_FEE_RATE_STABLE (100,000)
    gov.set_next_trade_params(150000, 50000);

    abort 1
}

#[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
fun admin_set_maker_fee_stable_too_high_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Maker fee above MAX_FEE_RATE_STABLE (100,000)
    gov.set_next_trade_params(50000, 150000);

    abort 1
}

#[test, expected_failure(abort_code = governance::EWhitelistedPoolCannotChange)]
fun admin_set_fee_whitelisted_e() {
    let mut test = begin(OWNER);

    let whitelisted = true;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Setting fees on a whitelisted pool should fail
    gov.set_next_trade_params(500000, 0);

    abort 1
}

#[test]
fun admin_multiple_fee_changes_ok() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Change 1: taker 0.5%, maker 0.25%
    gov.set_next_trade_params(5000000, 2500000);
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    assert!(gov.trade_params().taker_fee() == 5000000, 0);
    assert!(gov.trade_params().maker_fee() == 2500000, 0);

    // Change 2: taker 1.5%, maker 1%
    gov.set_next_trade_params(15000000, 10000000);
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    assert!(gov.trade_params().taker_fee() == 15000000, 0);
    assert!(gov.trade_params().maker_fee() == 10000000, 0);

    // Change 3: taker at floor (0.1%), maker at zero
    gov.set_next_trade_params(100000, 0);
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    assert!(gov.trade_params().taker_fee() == 100000, 0);
    assert!(gov.trade_params().maker_fee() == 0, 0);

    governance::destroy_for_testing(gov);
    end(test);
}
