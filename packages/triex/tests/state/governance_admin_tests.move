// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::governance_admin_tests;

use sui::test_scenario::{begin, end};
use triexbook::governance;

const OWNER: address = @0xF;

#[test]
fun admin_set_fee_volatile_ok() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Set a new fee rate (1%)
    gov.set_next_trade_params(10000000); // 10,000,000 = 1%

    // Verify next_trade_params has been updated
    let next_params = gov.next_trade_params();
    assert!(next_params.fee() == 10000000, 0);

    // Update to next epoch to apply the fee
    test.next_epoch(OWNER);
    gov.update(test.ctx());

    // Verify current trade_params now has the new fee
    let current_params = gov.trade_params();
    assert!(current_params.fee() == 10000000, 0);

    governance::destroy_for_testing(gov);
    end(test);
}

#[test]
fun admin_set_fee_stable_ok() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Set a new fee rate for stable pool (0.05%)
    gov.set_next_trade_params(50000); // 50,000 = 0.05%

    let next_params = gov.next_trade_params();
    assert!(next_params.fee() == 50000, 0);

    governance::destroy_for_testing(gov);
    end(test);
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun admin_set_fee_not_multiple_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Try to set fee that's not a multiple of FEE_MULTIPLE (1000)
    gov.set_next_trade_params(10001);

    abort 1
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun admin_set_fee_volatile_too_low_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Try to set fee below MIN_TAKER_VOLATILE (100,000)
    gov.set_next_trade_params(50000);

    abort 1
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun admin_set_fee_volatile_too_high_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Try to set fee above MAX_TAKER_VOLATILE (20,000,000 = 2%)
    gov.set_next_trade_params(21000000);

    abort 1
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun admin_set_fee_stable_too_low_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Try to set fee below MIN_FEE_RATE_STABLE (10,000)
    gov.set_next_trade_params(5000);

    abort 1
}

#[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
fun admin_set_fee_stable_too_high_e() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = true;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Try to set fee above MAX_FEE_RATE_STABLE (100,000)
    gov.set_next_trade_params(150000);

    abort 1
}

#[test, expected_failure(abort_code = governance::EWhitelistedPoolCannotChange)]
fun admin_set_fee_whitelisted_e() {
    let mut test = begin(OWNER);

    let whitelisted = true;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Try to set fee on whitelisted pool (should fail)
    gov.set_next_trade_params(500000);

    abort 1
}

#[test]
fun admin_multiple_fee_changes_ok() {
    let mut test = begin(OWNER);

    let whitelisted = false;
    let stable_pool = false;
    let mut gov = governance::empty(whitelisted, stable_pool, test.ctx());

    // Change 1: Set to 0.5%
    gov.set_next_trade_params(5000000);
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    assert!(gov.trade_params().fee() == 5000000, 0);

    // Change 2: Set to 1.5%
    gov.set_next_trade_params(15000000);
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    assert!(gov.trade_params().fee() == 15000000, 0);

    // Change 3: Set to 0.1% (minimum for volatile)
    gov.set_next_trade_params(100000);
    test.next_epoch(OWNER);
    gov.update(test.ctx());
    assert!(gov.trade_params().fee() == 100000, 0);

    governance::destroy_for_testing(gov);
    end(test);
}
