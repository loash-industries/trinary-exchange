// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::trade_params_tests {
    use std::unit_test::assert_eq;
    use triexbook::trade_params;

    #[test]
    fun test_trade_params_basic() {
        let taker_fee = 22_000_000; // 2.2%
        let maker_fee = 18_000_000; // 1.8%
        let params = trade_params::new(taker_fee, maker_fee, 2000);

        assert_eq!(params.taker_fee(), taker_fee);
        assert_eq!(params.maker_fee(), maker_fee);
    }

    #[test]
    fun test_trade_params_rates_independent() {
        let params = trade_params::new(10_000_000, 0, 2000);

        assert_eq!(params.taker_fee(), 10_000_000);
        assert_eq!(params.maker_fee(), 0);
    }

    #[test]
    fun test_trade_params_copy_semantics() {
        let params = trade_params::new(1_000_000, 500_000, 2000);
        let copied = params;

        assert_eq!(copied.taker_fee(), params.taker_fee());
        assert_eq!(copied.maker_fee(), params.maker_fee());
    }
}
