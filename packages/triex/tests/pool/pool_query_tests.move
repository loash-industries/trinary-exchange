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
}
