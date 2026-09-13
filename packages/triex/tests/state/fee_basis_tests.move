#[test_only]
module triex::fee_basis_tests {
    use std::unit_test::assert_eq;
    use triex::{constants, fee_basis};

    /// The invariant every other figure depends on: the maintained sum equals what
    /// the buckets hold. `hub_holdback` is computed from this sum and subtracted
    /// from the fee reserve inside a withdrawal assert, so drift here is drift in
    /// how much money the treasury may take.
    fun assert_invariant(basis: &fee_basis::FeeBasis) {
        assert_eq!(basis.unsettled(), basis.sum_buckets());
    }

    fun window(): u64 {
        constants::hub_basis_window_epochs()
    }

    #[test]
    fun starts_empty() {
        let basis = fee_basis::empty(7);

        assert_eq!(basis.unsettled(), 0);
        assert_eq!(basis.anchor_epoch(), 7);
        assert_eq!(basis.basis_at(7), 0);
        assert_invariant(&basis);
    }

    #[test]
    fun accrues_into_the_epoch_that_earned_it() {
        let mut basis = fee_basis::empty(4);
        assert!(basis.accrue(4, 100).is_empty());
        assert!(basis.accrue(4, 50).is_empty());

        assert_eq!(basis.unsettled(), 150);
        assert_eq!(basis.basis_at(4), 150);
        assert_invariant(&basis);
    }

    #[test]
    fun accruing_zero_is_a_noop() {
        // Every recognition point credits unconditionally — a fill that charges
        // nothing, a cancel with no retention — so zero has to be free.
        let mut basis = fee_basis::empty(0);
        assert!(basis.accrue(0, 0).is_empty());

        assert_eq!(basis.unsettled(), 0);
        assert_invariant(&basis);
    }

    #[test]
    fun separate_epochs_keep_separate_buckets() {
        // The whole point of the ring: epoch 3's revenue must stay priceable at
        // epoch 3's rate after epoch 4 has started earning at a different one.
        let mut basis = fee_basis::empty(3);
        basis.accrue(3, 900).destroy_empty();
        basis.accrue(4, 100).destroy_empty();

        assert_eq!(basis.basis_at(3), 900);
        assert_eq!(basis.basis_at(4), 100);
        assert_eq!(basis.unsettled(), 1000);
        assert_invariant(&basis);
    }

    #[test]
    fun rolling_within_the_window_keeps_everything() {
        let mut basis = fee_basis::empty(0);
        basis.accrue(0, 500).destroy_empty();

        let forfeited = basis.roll(window() - 1);
        assert!(forfeited.is_empty());
        assert_eq!(basis.basis_at(0), 500);
        assert_eq!(basis.unsettled(), 500);
        assert_invariant(&basis);
    }

    #[test]
    fun rolling_past_the_window_forfeits_and_reports_it() {
        // The settle-by deadline. Eviction is how the ring bounds storage, so an
        // unsettled bucket has to go — but it must come back as a reportable
        // amount, or an operator's accrual disappears with nothing to reconcile
        // against and the holdback is quietly released to the treasury.
        let mut basis = fee_basis::empty(0);
        basis.accrue(0, 500).destroy_empty();

        let forfeited = basis.roll(window());
        assert_eq!(forfeited.length(), 1);
        assert_eq!(forfeited[0].basis_epoch(), 0);
        assert_eq!(forfeited[0].basis_amount(), 500);

        assert_eq!(basis.basis_at(0), 0);
        assert_eq!(basis.unsettled(), 0);
        assert_invariant(&basis);
    }

    #[test]
    fun forfeits_every_stale_bucket_in_epoch_order() {
        let mut basis = fee_basis::empty(0);
        basis.accrue(0, 10).destroy_empty();
        basis.accrue(1, 20).destroy_empty();
        basis.accrue(2, 30).destroy_empty();

        // Two windows on: nothing survives, and the report is ordered oldest-first
        // so a consumer replaying events sees the epochs in sequence.
        let forfeited = basis.roll(2 * window());
        assert_eq!(forfeited.length(), 3);
        assert_eq!(forfeited[0].basis_epoch(), 0);
        assert_eq!(forfeited[0].basis_amount(), 10);
        assert_eq!(forfeited[1].basis_epoch(), 1);
        assert_eq!(forfeited[2].basis_epoch(), 2);
        assert_eq!(forfeited[2].basis_amount(), 30);

        assert_eq!(basis.unsettled(), 0);
        assert_invariant(&basis);
    }

    #[test]
    fun partial_roll_forfeits_only_what_aged_out() {
        let mut basis = fee_basis::empty(0);
        basis.accrue(0, 10).destroy_empty();
        basis.accrue(1, 20).destroy_empty();

        // Epoch 0 falls out of a window anchored at `window()`; epoch 1 does not.
        let forfeited = basis.roll(window());
        assert_eq!(forfeited.length(), 1);
        assert_eq!(forfeited[0].basis_epoch(), 0);
        assert_eq!(forfeited[0].basis_amount(), 10);

        assert_eq!(basis.basis_at(1), 20);
        assert_eq!(basis.unsettled(), 20);
        assert_invariant(&basis);
    }

    #[test]
    fun rolling_backwards_is_a_noop() {
        // Recognition sites pass whatever epoch their transaction runs in; nothing
        // guarantees monotonicity across a lazily-rolled ring, so an epoch behind
        // the anchor must not evict anything.
        let mut basis = fee_basis::empty(5);
        basis.accrue(5, 400).destroy_empty();

        assert!(basis.roll(3).is_empty());
        assert_eq!(basis.anchor_epoch(), 5);
        assert_eq!(basis.basis_at(5), 400);
        assert_invariant(&basis);
    }

    #[test]
    fun accruing_across_a_gap_forfeits_before_crediting() {
        let mut basis = fee_basis::empty(0);
        basis.accrue(0, 700).destroy_empty();

        let forfeited = basis.accrue(window() + 2, 60);
        assert_eq!(forfeited.length(), 1);
        assert_eq!(forfeited[0].basis_amount(), 700);
        assert_eq!(basis.basis_at(window() + 2), 60);
        assert_eq!(basis.unsettled(), 60);
        assert_invariant(&basis);
    }

    #[test]
    fun uncredit_takes_escrow_back_out_of_the_bucket() {
        // `settle_trading_account`'s correction: the deposit credited taker+maker,
        // and the maker half is escrow that has not been earned.
        let mut basis = fee_basis::empty(2);
        basis.accrue(2, 1000).destroy_empty();
        basis.uncredit(2, 400);

        assert_eq!(basis.basis_at(2), 600);
        assert_eq!(basis.unsettled(), 600);
        assert_invariant(&basis);
    }

    #[test]
    fun uncredit_of_zero_is_a_noop() {
        let mut basis = fee_basis::empty(0);
        basis.accrue(0, 10).destroy_empty();
        basis.uncredit(0, 0);

        assert_eq!(basis.basis_at(0), 10);
        assert_invariant(&basis);
    }

    #[test, expected_failure(abort_code = fee_basis::EInsufficientBasis)]
    fun uncredit_beyond_the_bucket_aborts() {
        // Saturating here would silently forgive an over-credit and leave the
        // maintained sum disagreeing with the buckets. Better to abort: it can only
        // happen if a caller uncredits something it never credited.
        let mut basis = fee_basis::empty(0);
        basis.accrue(0, 100).destroy_empty();
        basis.uncredit(0, 101);
    }

    #[test, expected_failure(abort_code = fee_basis::EEpochAhead)]
    fun uncredit_of_a_future_epoch_aborts() {
        let mut basis = fee_basis::empty(0);
        basis.accrue(0, 100).destroy_empty();
        basis.uncredit(1, 10);
    }

    #[test]
    fun pending_lists_every_carrying_epoch_oldest_first() {
        let mut basis = fee_basis::empty(10);
        basis.accrue(10, 5).destroy_empty();
        basis.accrue(12, 7).destroy_empty();
        basis.accrue(13, 9).destroy_empty();

        let pending = basis.pending();
        assert_eq!(pending.length(), 3);
        assert_eq!(pending[0].basis_epoch(), 10);
        assert_eq!(pending[1].basis_epoch(), 12);
        assert_eq!(pending[2].basis_epoch(), 13);
        assert_eq!(pending[2].basis_amount(), 9);
        assert_invariant(&basis);
    }

    #[test]
    fun pending_is_empty_when_nothing_is_carried() {
        let basis = fee_basis::empty(1);
        assert!(basis.pending().is_empty());
    }

    #[test]
    fun take_zeroes_one_epoch_and_leaves_the_rest() {
        let mut basis = fee_basis::empty(6);
        basis.accrue(6, 300).destroy_empty();
        basis.accrue(7, 400).destroy_empty();

        assert_eq!(basis.take(6), 300);
        assert_eq!(basis.basis_at(6), 0);
        assert_eq!(basis.basis_at(7), 400);
        assert_eq!(basis.unsettled(), 400);
        assert_invariant(&basis);
    }

    #[test]
    fun taking_twice_yields_nothing_the_second_time() {
        // Settlement must not be able to pay for the same basis twice, even if it
        // is called repeatedly in one transaction.
        let mut basis = fee_basis::empty(0);
        basis.accrue(0, 250).destroy_empty();

        assert_eq!(basis.take(0), 250);
        assert_eq!(basis.take(0), 0);
        assert_eq!(basis.unsettled(), 0);
        assert_invariant(&basis);
    }

    #[test]
    fun taking_an_out_of_window_epoch_yields_nothing() {
        let mut basis = fee_basis::empty(window() + 5);
        assert_eq!(basis.take(0), 0);
        assert_eq!(basis.take(window() + 6), 0);
        assert_invariant(&basis);
    }

    #[test]
    fun basis_at_reports_zero_outside_the_window() {
        let mut basis = fee_basis::empty(0);
        basis.accrue(0, 100).destroy_empty();
        basis.roll(window() - 1).destroy_empty();

        // Still inside: the oldest live epoch.
        assert_eq!(basis.basis_at(0), 100);
        // A future epoch reads as zero rather than aborting.
        assert_eq!(basis.basis_at(window()), 0);

        // One more epoch and epoch 0 ages out — reported, then gone.
        let forfeited = basis.roll(window());
        assert_eq!(forfeited.length(), 1);
        assert_eq!(forfeited[0].basis_amount(), 100);
        assert_eq!(basis.basis_at(0), 0);
        assert_invariant(&basis);
    }

    #[test]
    fun a_full_lap_reuses_buckets_without_leaking() {
        // The ring has to survive more epochs than it has buckets without the
        // maintained sum drifting — the failure mode that would make the holdback
        // wrong forever.
        let mut basis = fee_basis::empty(0);
        let mut epoch = 0;
        let mut total_forfeited = 0;
        while (epoch < 3 * window()) {
            let forfeited = basis.accrue(epoch, 10);
            // Before the first lap completes nothing can age out; after it, each
            // new epoch evicts exactly the one a window behind.
            if (epoch < window()) {
                assert!(forfeited.is_empty());
            } else {
                assert_eq!(forfeited.length(), 1);
                assert_eq!(forfeited[0].basis_epoch(), epoch - window());
                assert_eq!(forfeited[0].basis_amount(), 10);
                total_forfeited = total_forfeited + 10;
            };
            assert_invariant(&basis);
            epoch = epoch + 1;
        };

        // Only the window's worth is still live, and everything else was reported
        // rather than lost: the ring never silently swallows a basis.
        assert_eq!(basis.unsettled(), (window() as u128) * 10);
        assert_eq!(basis.pending().length(), window());
        assert_eq!(total_forfeited, 2 * window() * 10);
        assert_invariant(&basis);
    }
}
