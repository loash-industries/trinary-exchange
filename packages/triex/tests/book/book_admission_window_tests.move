/// The admission-window suite on the multicoin book. The specification, the
/// soundness argument and every check live in `admission_window_test_utils`,
/// shared with `coin_book_admission_window_tests`; this module only picks the
/// multicoin fixture.
#[test_only]
module triex::book_admission_window_tests {
    use triex::admission_window_test_utils::{Self as utils, multicoin};

    #[test]
    /// The whole grid on the ask side: buffer occupancy x tree depth x price class,
    /// with both entry paths into the window.
    fun admission_grid_asks() { utils::run_grid(multicoin(), false) }

    #[test]
    /// The same grid on the bid side. Not redundant: the window reads `max_slice`
    /// here where the ask side reads `min_slice`, and every comparison runs under
    /// the opposite sense of `better`, so a swap between the two would pass on one
    /// side and fail here.
    fun admission_grid_bids() { utils::run_grid(multicoin(), true) }

    // === Targeted properties the grid implies but does not name ===

    #[test]
    fun spill_never_opens_the_window() { utils::spill_never_opens_the_window(multicoin()) }

    #[test]
    fun repeated_window_cycles() { utils::repeated_window_cycles(multicoin()) }

    #[test]
    fun orders_in_the_gap_go_behind_a_half_empty_buffer() {
        utils::orders_in_the_gap_go_behind_a_half_empty_buffer(multicoin())
    }

    #[test]
    fun a_placement_can_spill_itself() { utils::a_placement_can_spill_itself(multicoin()) }

    #[test]
    fun window_over_a_single_tree_order() { utils::window_over_a_single_tree_order(multicoin()) }
}
