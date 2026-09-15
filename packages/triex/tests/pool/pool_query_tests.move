#[test_only]
module triex::pool_query_tests {
    use triex::pool_test_utils;

    #[test]
    fun test_get_order() {
        pool_test_utils::test_get_order();
    }

    #[test]
    fun test_get_orders() {
        pool_test_utils::test_get_orders();
    }

    #[test]
    fun test_dust_priced_level_does_not_break_the_quote() {
        pool_test_utils::test_dust_priced_level_does_not_break_the_quote();
    }

    #[test]
    fun test_dust_priced_level_does_not_break_the_swap_router() {
        pool_test_utils::test_dust_priced_level_does_not_break_the_swap_router();
    }
}
