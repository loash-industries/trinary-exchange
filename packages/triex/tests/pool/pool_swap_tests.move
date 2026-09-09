#[test_only]
module triex::pool_swap_tests {
    use triex::pool_test_utils;

    #[test]
    fun test_mid_price_ok() {
        pool_test_utils::test_mid_price_ok();
    }

    #[test]
    fun test_swap_exact_amount_bid_ask() {
        pool_test_utils::test_swap_exact_amount_bid_ask();
    }

    #[test]
    fun test_swap_exact_amount_ask_bid() {
        pool_test_utils::test_swap_exact_amount_ask_bid();
    }

    #[test]
    fun test_swap_exact_amount_bid_ask_with_trading_account() {
        pool_test_utils::test_swap_exact_amount_bid_ask_with_trading_account();
    }

    #[test]
    fun test_swap_exact_amount_ask_bid_with_trading_account() {
        pool_test_utils::test_swap_exact_amount_ask_bid_with_trading_account();
    }

    #[test]
    fun test_swap_exact_amount_with_input_bid_ask() {
        pool_test_utils::test_swap_exact_amount_with_input_bid_ask();
    }

    #[test]
    fun test_swap_exact_amount_with_input_ask_bid() {
        pool_test_utils::test_swap_exact_amount_with_input_ask_bid();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_bid_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_bid_ok();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_bid_with_trading_account_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_bid_with_trading_account_ok();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_ask_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_ask_ok();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_ask_with_trading_account_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_ask_with_trading_account_ok();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_bid_low_qty_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_bid_low_qty_ok();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_bid_with_trading_account_low_qty_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_bid_with_trading_account_low_qty_ok();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_ask_low_qty_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_ask_low_qty_ok();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_ask_with_trading_account_low_qty_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_ask_with_trading_account_low_qty_ok();
    }

    #[test, expected_failure(abort_code = ::triex::pool::EMinimumQuantityOutNotMet)]
    fun test_swap_exact_not_fully_filled_bid_min_e() {
        pool_test_utils::test_swap_exact_not_fully_filled_bid_min_e();
    }

    #[test, expected_failure(abort_code = ::triex::pool::EMinimumQuantityOutNotMet)]
    fun test_swap_exact_not_fully_filled_bid_with_trading_account_min_e() {
        pool_test_utils::test_swap_exact_not_fully_filled_bid_with_trading_account_min_e();
    }

    #[test, expected_failure(abort_code = ::triex::pool::EMinimumQuantityOutNotMet)]
    fun test_swap_exact_not_fully_filled_ask_min_e() {
        pool_test_utils::test_swap_exact_not_fully_filled_ask_min_e();
    }

    #[test, expected_failure(abort_code = ::triex::pool::EMinimumQuantityOutNotMet)]
    fun test_swap_exact_not_fully_filled_ask_with_trading_account_min_e() {
        pool_test_utils::test_swap_exact_not_fully_filled_ask_with_trading_account_min_e();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_maker_partial_bid_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_maker_partial_bid_ok();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_maker_partial_bid_with_trading_account_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_maker_partial_bid_with_trading_account_ok();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_maker_partial_ask_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_maker_partial_ask_ok();
    }

    #[test]
    fun test_swap_exact_not_fully_filled_maker_partial_ask_with_trading_account_ok() {
        pool_test_utils::test_swap_exact_not_fully_filled_maker_partial_ask_with_trading_account_ok();
    }
}
