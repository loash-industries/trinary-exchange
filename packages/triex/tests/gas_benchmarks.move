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
module triexbook::gas_benchmarks {
    use triexbook::pool_test_utils;

    #[test]
    fun bench_baseline() { pool_test_utils::bench_baseline() }

    #[test]
    fun bench_depth_10() { pool_test_utils::bench_depth_10() }

    #[test]
    fun bench_depth_40() { pool_test_utils::bench_depth_40() }

    #[test]
    fun bench_depth_80() { pool_test_utils::bench_depth_80() }

    #[test]
    fun bench_cancel_at_depth_80() { pool_test_utils::bench_cancel_at_depth_80() }

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
