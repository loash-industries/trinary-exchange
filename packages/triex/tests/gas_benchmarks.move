/// Gas benchmarks, not correctness tests.
///
/// Each benchmark performs a fixed amount of work. `build_scripts/gas-benchmark.sh`
/// binary-searches the smallest `--gas-limit` each one survives, which is a
/// deterministic measure of the Move VM gas that work costs. Read them
/// differentially — see the notes above the bodies in `pool_test_utils`.
///
/// They pass under a normal `sui move test` run, so they cost a few seconds on
/// every suite run and otherwise assert nothing.
#[test_only]
module triex::gas_benchmarks {
    use triex::pool_test_utils;

    #[test]
    fun bench_baseline() { pool_test_utils::bench_baseline() }

    #[test]
    fun bench_depth_10() { pool_test_utils::bench_depth_10() }

    #[test]
    fun bench_depth_40() { pool_test_utils::bench_depth_40() }

    #[test]
    fun bench_depth_80() { pool_test_utils::bench_depth_80() }

    // Depths above the 64-order slice size, where the coin book's B+ tree is meant
    // to overtake a flat vector. These span several trading accounts because
    // MAX_OPEN_ORDERS caps one account at 100.
    #[test]
    fun bench_depth_300() { pool_test_utils::bench_depth_300() }

    #[test]
    fun bench_cancel_at_depth_80() { pool_test_utils::bench_cancel_at_depth_80() }

    // Inside-market access. Real books concentrate their activity here, and the two
    // storage designs have opposite strengths at this spot, so these are the
    // benchmarks that decide the question the depth ladders cannot.
    #[test]
    fun bench_cancel_at_top_of_book_depth_80() {
        pool_test_utils::bench_cancel_at_top_of_book_depth_80()
    }

    #[test]
    fun bench_churn_at_depth_40() { pool_test_utils::bench_churn_at_depth_40() }

    #[test]
    fun bench_churn_at_depth_300() { pool_test_utils::bench_churn_at_depth_300() }

    #[test]
    fun bench_churn_at_depth_40_x40() { pool_test_utils::bench_churn_at_depth_40_x40() }

    // Uniquely-named aliases for the 20-cycle churn bodies. `gas-benchmark.sh`
    // filters tests by substring, and "bench_churn_at_depth_40" also names
    // "bench_churn_at_depth_40_x40", so the 20-cycle figure cannot be measured under
    // its own name. Differencing c20 against c40 cancels book construction exactly
    // and leaves the price of one churn cycle, which is the number these benchmarks
    // exist to produce.
    #[test]
    fun bench_tobchurn_d40_c20() { pool_test_utils::bench_churn_at_depth_40() }

    #[test]
    fun bench_tobchurn_d300_c20() { pool_test_utils::bench_churn_at_depth_300() }

    #[test]
    fun bench_churn_at_depth_300_x40() { pool_test_utils::bench_churn_at_depth_300_x40() }

    #[test]
    fun bench_taker_sweeps_01() { pool_test_utils::bench_taker_sweeps_01() }

    #[test]
    fun bench_taker_sweeps_10() { pool_test_utils::bench_taker_sweeps_10() }

    #[test]
    fun bench_ladder_1_tier() { pool_test_utils::bench_ladder_1_tier() }

    #[test]
    fun bench_ladder_8_tiers() { pool_test_utils::bench_ladder_8_tiers() }

    #[test]
    fun bench_makers_10() { pool_test_utils::bench_makers_10() }

    #[test]
    fun bench_market_sweeps_10() { pool_test_utils::bench_market_sweeps_10() }

    #[test]
    fun bench_swap_base_for_quote_10() { pool_test_utils::bench_swap_base_for_quote_10() }

    #[test]
    fun bench_modify_at_depth_80() { pool_test_utils::bench_modify_at_depth_80() }

    #[test]
    fun bench_cancel_all_at_depth_80() { pool_test_utils::bench_cancel_all_at_depth_80() }
}
