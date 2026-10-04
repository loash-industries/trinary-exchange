/// The admission-window suite on the coin book, at coin-pool price scaling. The
/// specification, the soundness argument and every check live in
/// `admission_window_test_utils`, shared with `book_admission_window_tests`; this
/// module only picks the coin fixture.
#[test_only]
module triex::coin_book_admission_window_tests {
    use triex::{admission_window_test_utils::{Self as utils, coin}, book::hot_capacity};

    // The grid is split per buffer occupancy rather than run as one test because a
    // single test over the whole grid at coin scaling exceeds the Move harness's
    // per-test time budget.

    #[test]
    fun admission_grid_asks_empty_buffer() { utils::run_row(coin(), false, 0) }

    #[test]
    fun admission_grid_asks_one_inline() { utils::run_row(coin(), false, 1) }

    #[test]
    fun admission_grid_asks_two_inline() { utils::run_row(coin(), false, 2) }

    #[test]
    fun admission_grid_asks_one_below_capacity() {
        utils::run_row(coin(), false, hot_capacity() - 1)
    }

    #[test]
    fun admission_grid_asks_at_capacity() { utils::run_row(coin(), false, hot_capacity()) }

    // The bid side is not redundant: the window reads `max_slice` here where the ask
    // side reads `min_slice`, and every comparison runs under the opposite sense of
    // `better`, so a swap between the two would pass on one side and fail here.

    #[test]
    fun admission_grid_bids_empty_buffer() { utils::run_row(coin(), true, 0) }

    #[test]
    fun admission_grid_bids_one_inline() { utils::run_row(coin(), true, 1) }

    #[test]
    fun admission_grid_bids_two_inline() { utils::run_row(coin(), true, 2) }

    #[test]
    fun admission_grid_bids_one_below_capacity() {
        utils::run_row(coin(), true, hot_capacity() - 1)
    }

    #[test]
    fun admission_grid_bids_at_capacity() { utils::run_row(coin(), true, hot_capacity()) }

    // === Targeted properties the grid implies but does not name ===

    #[test]
    fun spill_never_opens_the_window() { utils::spill_never_opens_the_window(coin()) }

    #[test]
    fun repeated_window_cycles() { utils::repeated_window_cycles(coin()) }

    #[test]
    fun orders_in_the_gap_go_behind_a_half_empty_buffer() {
        utils::orders_in_the_gap_go_behind_a_half_empty_buffer(coin())
    }

    #[test]
    fun a_placement_can_spill_itself() { utils::a_placement_can_spill_itself(coin()) }

    #[test]
    fun window_over_a_single_tree_order() { utils::window_over_a_single_tree_order(coin()) }

    // === Branch E: the thin book kept inline while its tree is empty ===

    #[test]
    fun behind_the_best_on_an_empty_tree_stays_inline() {
        utils::behind_the_best_on_an_empty_tree_stays_inline(coin())
    }

    #[test]
    fun behind_the_buffer_with_a_stocked_tree_goes_to_the_tree() {
        utils::behind_the_buffer_with_a_stocked_tree_goes_to_the_tree(coin())
    }

    #[test]
    fun a_drained_tree_reopens_branch_e() { utils::a_drained_tree_reopens_branch_e(coin()) }
}
