/// Gas benchmarks, not correctness tests.
///
/// Each benchmark performs a fixed amount of work. `build_scripts/gas-benchmark.sh`
/// binary-searches the smallest `--gas-limit` each one survives, which is a
/// deterministic measure of the Move VM gas that work costs. Read them
/// differentially — see the notes above the bodies in `gas_benchmark_bodies`.
///
/// They live outside `tests/`, so a normal `sui move test` run does not build
/// them; `build_scripts/gas-benchmark.sh` copies them into a scratch copy of the
/// package before measuring.
#[test_only]
module triex::gas_benchmarks {
    use triex::gas_benchmark_bodies;

    #[test]
    fun bench_baseline() { gas_benchmark_bodies::bench_baseline() }

    #[test]
    fun bench_depth_10() { gas_benchmark_bodies::bench_depth_10() }

    #[test]
    fun bench_depth_40() { gas_benchmark_bodies::bench_depth_40() }

    #[test]
    fun bench_depth_80() { gas_benchmark_bodies::bench_depth_80() }

    // Depths above the 64-order slice size, where the coin book's B+ tree is meant
    // to overtake a flat vector. These span several trading accounts because
    // MAX_OPEN_ORDERS caps one account at 100.
    #[test]
    fun bench_depth_300() { gas_benchmark_bodies::bench_depth_300() }

    #[test]
    fun bench_cancel_at_depth_80() { gas_benchmark_bodies::bench_cancel_at_depth_80() }

    // Inside-market access. Real books concentrate their activity here, and the two
    // storage designs have opposite strengths at this spot, so these are the
    // benchmarks that decide the question the depth ladders cannot.
    #[test]
    fun bench_cancel_at_top_of_book_depth_80() {
        gas_benchmark_bodies::bench_cancel_at_top_of_book_depth_80()
    }

    #[test]
    fun bench_churn_at_depth_40() { gas_benchmark_bodies::bench_churn_at_depth_40() }

    #[test]
    fun bench_churn_at_depth_300() { gas_benchmark_bodies::bench_churn_at_depth_300() }

    #[test]
    fun bench_churn_at_depth_40_x40() { gas_benchmark_bodies::bench_churn_at_depth_40_x40() }

    // Uniquely-named aliases for the 20-cycle churn bodies. `gas-benchmark.sh`
    // filters tests by substring, and "bench_churn_at_depth_40" also names
    // "bench_churn_at_depth_40_x40", so the 20-cycle figure cannot be measured under
    // its own name. Differencing c20 against c40 cancels book construction exactly
    // and leaves the price of one churn cycle, which is the number these benchmarks
    // exist to produce.
    #[test]
    fun bench_tobchurn_d40_c20() { gas_benchmark_bodies::bench_churn_at_depth_40() }

    #[test]
    fun bench_tobchurn_d300_c20() { gas_benchmark_bodies::bench_churn_at_depth_300() }

    #[test]
    fun bench_churn_at_depth_300_x40() { gas_benchmark_bodies::bench_churn_at_depth_300_x40() }

    #[test]
    fun bench_taker_sweeps_01() { gas_benchmark_bodies::bench_taker_sweeps_01() }

    #[test]
    fun bench_taker_sweeps_10() { gas_benchmark_bodies::bench_taker_sweeps_10() }

    #[test]
    fun bench_ladder_1_tier() { gas_benchmark_bodies::bench_ladder_1_tier() }

    #[test]
    fun bench_ladder_8_tiers() { gas_benchmark_bodies::bench_ladder_8_tiers() }

    #[test]
    fun bench_makers_10() { gas_benchmark_bodies::bench_makers_10() }

    #[test]
    fun bench_market_sweeps_10() { gas_benchmark_bodies::bench_market_sweeps_10() }

    #[test]
    fun bench_swap_base_for_quote_10() { gas_benchmark_bodies::bench_swap_base_for_quote_10() }

    #[test]
    fun bench_modify_at_depth_80() { gas_benchmark_bodies::bench_modify_at_depth_80() }

    #[test]
    fun bench_cancel_all_at_depth_80() { gas_benchmark_bodies::bench_cancel_all_at_depth_80() }
}
