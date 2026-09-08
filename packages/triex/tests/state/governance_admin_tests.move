// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::governance_admin_tests {
    use sui::test_scenario::{begin, end};
    use triexbook::governance;

    const OWNER: address = @0xF;

    #[test]
    fun default_rates_ok() {
        let mut test = begin(OWNER);

        let gov = governance::empty(test.ctx());

        // Pool creation defaults: taker 2.2%, maker 1.8%
        assert!(gov.trade_params().taker_fee() == 22000000, 0);
        assert!(gov.trade_params().maker_fee() == 18000000, 0);
        assert!(gov.next_trade_params().taker_fee() == 22000000, 0);
        assert!(gov.next_trade_params().maker_fee() == 18000000, 0);

        governance::destroy_for_testing(gov);
        end(test);
    }

    #[test]
    fun default_rates_multicoin_ok() {
        let mut test = begin(OWNER);

        let gov = governance::empty_multicoin(test.ctx());

        // Multicoin pool creation defaults: taker 1.1%, maker 0.9%
        assert!(gov.trade_params().taker_fee() == 11000000, 0);
        assert!(gov.trade_params().maker_fee() == 9000000, 0);
        assert!(gov.next_trade_params().taker_fee() == 11000000, 0);
        assert!(gov.next_trade_params().maker_fee() == 9000000, 0);

        governance::destroy_for_testing(gov);
        end(test);
    }

    #[test]
    fun admin_set_fee_ok() {
        let mut test = begin(OWNER);

        let mut gov = governance::empty(test.ctx());

        // Set new rates: taker 1%, maker 0.5%
        gov.set_next_trade_params(10000000, 5000000, 2000);

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
    fun admin_set_fees_at_caps_ok() {
        let mut test = begin(OWNER);

        let mut gov = governance::empty(test.ctx());

        // Both rates at their 100% caps — above the launch defaults
        gov.set_next_trade_params(1000000000, 1000000000, 2000);

        let next_params = gov.next_trade_params();
        assert!(next_params.taker_fee() == 1000000000, 0);
        assert!(next_params.maker_fee() == 1000000000, 0);

        governance::destroy_for_testing(gov);
        end(test);
    }

    #[test]
    fun admin_set_maker_fee_zero_ok() {
        let mut test = begin(OWNER);

        let mut gov = governance::empty(test.ctx());

        // Maker rate has no floor: zero is allowed while the taker keeps its floor
        gov.set_next_trade_params(10000000, 0, 2000);

        let next_params = gov.next_trade_params();
        assert!(next_params.taker_fee() == 10000000, 0);
        assert!(next_params.maker_fee() == 0, 0);

        governance::destroy_for_testing(gov);
        end(test);
    }

    #[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
    fun admin_set_taker_fee_not_multiple_e() {
        let mut test = begin(OWNER);

        let mut gov = governance::empty(test.ctx());

        // Taker fee not a multiple of FEE_MULTIPLE (1000)
        gov.set_next_trade_params(10001, 5000000, 2000);

        abort 1
    }

    #[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
    fun admin_set_maker_fee_not_multiple_e() {
        let mut test = begin(OWNER);

        let mut gov = governance::empty(test.ctx());

        // Maker fee not a multiple of FEE_MULTIPLE (1000)
        gov.set_next_trade_params(10000000, 5000001, 2000);

        abort 1
    }

    #[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
    fun admin_set_taker_fee_too_low_e() {
        let mut test = begin(OWNER);

        let mut gov = governance::empty(test.ctx());

        // Taker fee below MIN_TAKER_FEE (100,000)
        gov.set_next_trade_params(50000, 0, 2000);

        abort 1
    }

    #[test, expected_failure(abort_code = governance::EInvalidTakerFee)]
    fun admin_set_taker_fee_too_high_e() {
        let mut test = begin(OWNER);

        let mut gov = governance::empty(test.ctx());

        // Taker fee above MAX_TAKER_FEE (1,000,000,000 = 100%)
        gov.set_next_trade_params(1001000000, 5000000, 2000);

        abort 1
    }

    #[test, expected_failure(abort_code = governance::EInvalidMakerFee)]
    fun admin_set_maker_fee_too_high_e() {
        let mut test = begin(OWNER);

        let mut gov = governance::empty(test.ctx());

        // Maker fee above MAX_MAKER_FEE (1,000,000,000 = 100%)
        gov.set_next_trade_params(10000000, 1001000000, 2000);

        abort 1
    }

    #[test]
    fun admin_multiple_fee_changes_ok() {
        let mut test = begin(OWNER);

        let mut gov = governance::empty(test.ctx());

        // Change 1: taker 0.5%, maker 0.25%
        gov.set_next_trade_params(5000000, 2500000, 2000);
        test.next_epoch(OWNER);
        gov.update(test.ctx());
        assert!(gov.trade_params().taker_fee() == 5000000, 0);
        assert!(gov.trade_params().maker_fee() == 2500000, 0);

        // Change 2: taker 1.5%, maker 1%
        gov.set_next_trade_params(15000000, 10000000, 2000);
        test.next_epoch(OWNER);
        gov.update(test.ctx());
        assert!(gov.trade_params().taker_fee() == 15000000, 0);
        assert!(gov.trade_params().maker_fee() == 10000000, 0);

        // Change 3: taker at floor (0.1%), maker at zero
        gov.set_next_trade_params(100000, 0, 2000);
        test.next_epoch(OWNER);
        gov.update(test.ctx());
        assert!(gov.trade_params().taker_fee() == 100000, 0);
        assert!(gov.trade_params().maker_fee() == 0, 0);

        governance::destroy_for_testing(gov);
        end(test);
    }

    #[test, expected_failure(abort_code = governance::EInvalidCancelRetention)]
    fun admin_set_cancel_retention_above_full_e() {
        let mut test = begin(OWNER);

        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());
        // 10000 bps keeps the whole escrow; anything above is not a share.
        gov.set_next_trade_params(10000000, 5000000, 10001);

        governance::destroy_for_testing(gov);
        test.end();
    }

    #[test]
    fun admin_set_cancel_retention_boundaries_ok() {
        let mut test = begin(OWNER);

        test.next_tx(OWNER);
        let mut gov = governance::empty(test.ctx());

        // Both ends are legal policy: refund everything, or keep everything.
        gov.set_next_trade_params(10000000, 5000000, 0);
        assert!(gov.next_trade_params().cancel_retention_bps() == 0);
        gov.set_next_trade_params(10000000, 5000000, 10000);
        assert!(gov.next_trade_params().cancel_retention_bps() == 10000);

        governance::destroy_for_testing(gov);
        test.end();
    }

    #[test]
    fun default_cancel_retention_is_twenty_percent() {
        let mut test = begin(OWNER);

        test.next_tx(OWNER);
        let coin_gov = governance::empty(test.ctx());
        let multicoin_gov = governance::empty_multicoin(test.ctx());

        assert!(coin_gov.trade_params().cancel_retention_bps() == 2000);
        assert!(multicoin_gov.trade_params().cancel_retention_bps() == 2000);

        governance::destroy_for_testing(coin_gov);
        governance::destroy_for_testing(multicoin_gov);
        test.end();
    }
}
