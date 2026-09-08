#[test_only]
module triexbook::fee_turnover_tests {
    use std::unit_test::assert_eq;
    use triexbook::{constants, fee_turnover};

    /// Assert the invariant the whole design rests on: the maintained rolling sum
    /// always equals what the buckets actually hold. If this ever drifts, tiers
    /// resolve against a number with no basis in recorded fees.
    fun assert_invariant(turnover: &fee_turnover::FeeTurnover) {
        assert_eq!(turnover.total(), turnover.sum_buckets());
    }

    #[test]
    fun starts_empty() {
        let turnover = fee_turnover::empty(7);

        assert_eq!(turnover.total(), 0);
        assert_eq!(turnover.anchor_epoch(), 7);
        assert_eq!(turnover.head(), 0);
        assert_invariant(&turnover);
    }

    #[test]
    fun records_into_the_current_bucket() {
        let mut turnover = fee_turnover::empty(0);
        turnover.record(100);
        turnover.record(50);

        assert_eq!(turnover.total(), 150);
        assert_eq!(turnover.bucket_at(0), 150);
        assert_invariant(&turnover);
    }

    #[test]
    fun recording_zero_is_a_noop() {
        // The fill path credits unconditionally, including expired fills that
        // charge nothing, so zero has to be free and harmless.
        let mut turnover = fee_turnover::empty(0);
        turnover.record(0);

        assert_eq!(turnover.total(), 0);
        assert_invariant(&turnover);
    }

    #[test]
    fun rolling_within_the_window_retains_history() {
        let mut turnover = fee_turnover::empty(0);
        turnover.record(100);

        turnover.roll(1);
        turnover.record(50);

        // Both epochs are inside the window, so both still count.
        assert_eq!(turnover.total(), 150);
        assert_eq!(turnover.head(), 1);
        assert_eq!(turnover.bucket_at(0), 100);
        assert_eq!(turnover.bucket_at(1), 50);
        assert_invariant(&turnover);
    }

    #[test]
    fun rolling_to_the_same_epoch_is_a_noop() {
        // Every account touch rolls, and an active trader touches many times per
        // epoch — this is the common case and it must not move the ring.
        let mut turnover = fee_turnover::empty(4);
        turnover.record(100);

        turnover.roll(4);

        assert_eq!(turnover.total(), 100);
        assert_eq!(turnover.head(), 0);
        assert_eq!(turnover.anchor_epoch(), 4);
        assert_invariant(&turnover);
    }

    #[test]
    fun rolling_backwards_is_a_noop() {
        let mut turnover = fee_turnover::empty(4);
        turnover.record(100);

        turnover.roll(2);

        assert_eq!(turnover.total(), 100);
        assert_eq!(turnover.anchor_epoch(), 4);
        assert_invariant(&turnover);
    }

    #[test]
    fun full_window_stays_in_scope() {
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);

        // One unit of fees in each epoch of the window.
        let mut epoch = 0;
        while (epoch < window) {
            if (epoch > 0) turnover.roll(epoch);
            turnover.record(1);
            epoch = epoch + 1;
        };

        assert_eq!(turnover.total(), window as u128);
        assert_invariant(&turnover);
    }

    #[test]
    fun oldest_epoch_falls_out_of_the_window() {
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);

        turnover.record(100);
        let mut epoch = 1;
        while (epoch < window) {
            turnover.roll(epoch);
            turnover.record(1);
            epoch = epoch + 1;
        };

        // Window covers epochs 0..=window-1, so everything still counts.
        assert_eq!(turnover.total(), 100 + ((window - 1) as u128));

        // Stepping one epoch further pushes epoch 0 out.
        turnover.roll(window);
        assert_eq!(turnover.total(), (window - 1) as u128);
        assert_invariant(&turnover);
    }

    #[test]
    fun dormancy_for_a_full_window_clears_everything() {
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);
        turnover.record(5_000);

        turnover.roll(window);

        assert_eq!(turnover.total(), 0);
        assert_eq!(turnover.head(), 0);
        assert_eq!(turnover.anchor_epoch(), window);
        assert_invariant(&turnover);
    }

    #[test]
    fun long_dormancy_clears_without_walking_every_epoch() {
        // Elapsed epochs are unbounded, so the far-dormant path must clear in
        // window-sized work rather than proportional to the gap.
        let mut turnover = fee_turnover::empty(0);
        turnover.record(5_000);

        turnover.roll(1_000_000);

        assert_eq!(turnover.total(), 0);
        assert_eq!(turnover.anchor_epoch(), 1_000_000);
        assert_invariant(&turnover);
    }

    #[test]
    fun the_epoch_just_inside_the_window_survives() {
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);
        turnover.record(5_000);

        // One short of a full window: the original epoch is still the oldest
        // in-scope bucket.
        turnover.roll(window - 1);

        assert_eq!(turnover.total(), 5_000);
        assert_invariant(&turnover);
    }

    #[test]
    fun ring_wraps_and_keeps_accounting() {
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);

        // Run well past one full lap of the ring, recording every epoch.
        let mut epoch = 0;
        while (epoch < window * 2 + 7) {
            if (epoch > 0) turnover.roll(epoch);
            turnover.record(10);
            epoch = epoch + 1;
        };

        // Only the trailing window's worth is ever in scope, no matter how long
        // the account has been trading.
        assert_eq!(turnover.total(), (window as u128) * 10);
        assert_invariant(&turnover);
    }

    #[test]
    fun gap_shorter_than_the_window_evicts_only_what_aged_out() {
        let mut turnover = fee_turnover::empty(0);
        turnover.record(100);
        turnover.roll(1);
        turnover.record(200);

        // Skip ahead so epoch 0 ages out but epoch 1 does not.
        turnover.roll(constants::turnover_window_epochs());

        assert_eq!(turnover.total(), 200);
        assert_invariant(&turnover);
    }

    // === Multi-bucket eviction and mixed sequences ===

    #[test]
    fun one_roll_evicts_every_bucket_that_aged_out() {
        // Three consecutive epochs with fees, then a jump far enough that the first
        // two fall out of the window but the third does not.
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);
        turnover.record(10);
        turnover.roll(1);
        turnover.record(20);
        turnover.roll(2);
        turnover.record(30);
        assert_eq!(turnover.total(), 60);

        // At epoch window+1 the window covers epochs 2..=window+1, so epochs 0 and
        // 1 are gone and only epoch 2's 30 survives.
        turnover.roll(window + 1);

        assert_eq!(turnover.total(), 30);
        assert_invariant(&turnover);
    }

    #[test]
    fun eviction_walks_past_the_wrap_point() {
        // The evicted buckets straddle index 0, so this fails if the ring arithmetic
        // is off rather than merely the accounting.
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);

        let mut epoch = 0;
        while (epoch < window) {
            if (epoch > 0) turnover.roll(epoch);
            turnover.record(1);
            epoch = epoch + 1;
        };
        assert_eq!(turnover.total(), window as u128);

        // Advance five more epochs without recording: five oldest buckets age out.
        turnover.roll(window + 4);

        assert_eq!(turnover.total(), (window - 5) as u128);
        assert_invariant(&turnover);
    }

    #[test]
    fun recording_after_dormancy_starts_from_zero() {
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);
        turnover.record(9_999);

        turnover.roll(window * 3);
        turnover.record(7);

        // The stale total is gone and only the fresh fee counts.
        assert_eq!(turnover.total(), 7);
        assert_invariant(&turnover);
    }

    #[test]
    fun many_records_within_one_epoch_accumulate() {
        // An active trader touches the account many times per epoch; every credit
        // must land in the same bucket rather than advancing the ring.
        let mut turnover = fee_turnover::empty(3);
        let mut i = 0;
        while (i < 50) {
            turnover.roll(3); // no-op, as it would be on every account touch
            turnover.record(2);
            i = i + 1;
        };

        assert_eq!(turnover.total(), 100);
        assert_eq!(turnover.head(), 0);
        assert_invariant(&turnover);
    }

    #[test]
    fun sparse_activity_across_a_long_span_keeps_only_the_window() {
        // Record every fifth epoch for several windows' worth of time.
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);

        let mut epoch = 0;
        while (epoch <= window * 3) {
            turnover.roll(epoch);
            if (epoch % 5 == 0) turnover.record(100);
            epoch = epoch + 1;
        };

        // In-window epochs are (window*3 - window, window*3] = (60, 90] for a
        // 30-epoch window; the multiples of five in that half-open range are
        // 65,70,75,80,85,90 — six of them.
        assert_eq!(turnover.total(), 600);
        assert_invariant(&turnover);
    }

    #[test]
    fun large_values_do_not_break_the_rolling_sum() {
        // Buckets are u64 and the sum is u128, so a window full of very large
        // epochs must still add up exactly.
        let window = constants::turnover_window_epochs();
        let big: u64 = 1_000_000_000_000_000_000;
        let mut turnover = fee_turnover::empty(0);

        let mut epoch = 0;
        while (epoch < window) {
            if (epoch > 0) turnover.roll(epoch);
            turnover.record(big);
            epoch = epoch + 1;
        };

        assert_eq!(turnover.total(), (big as u128) * (window as u128));
        assert_invariant(&turnover);
    }

    // === record_at: folding pending credits into past epochs ===

    #[test]
    fun record_at_credits_the_bucket_of_the_earning_epoch() {
        let mut turnover = fee_turnover::empty(0);
        turnover.record(100);
        turnover.roll(2);

        // Fold credits earned in epochs behind the head: each lands exactly where
        // per-epoch tracking would have put it, just later.
        turnover.record_at(1, 40);
        turnover.record_at(2, 5);

        assert_eq!(turnover.total(), 145);
        assert_eq!(turnover.bucket_at(0), 100);
        assert_eq!(turnover.bucket_at(1), 40);
        assert_eq!(turnover.bucket_at(2), 5);
        assert_invariant(&turnover);
    }

    #[test]
    fun record_at_credits_age_out_on_their_own_schedule() {
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);
        turnover.record(100);
        turnover.roll(2);
        turnover.record_at(1, 40);
        turnover.record_at(2, 5);

        // Rolling to epoch `window` evicts only epoch 0: a late-folded credit
        // expires when its earning epoch does, not later.
        turnover.roll(window);

        assert_eq!(turnover.total(), 45);
        assert_invariant(&turnover);
    }

    #[test]
    fun record_at_drops_credits_older_than_the_window() {
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);
        turnover.roll(window);

        // Exactly one window behind is already out of scope and silently dropped;
        // one epoch inside still lands.
        turnover.record_at(0, 100);
        assert_eq!(turnover.total(), 0);
        turnover.record_at(1, 25);
        assert_eq!(turnover.total(), 25);
        assert_invariant(&turnover);
    }

    #[test]
    fun record_at_zero_is_a_noop() {
        let mut turnover = fee_turnover::empty(5);
        turnover.record_at(3, 0);

        assert_eq!(turnover.total(), 0);
        assert_invariant(&turnover);
    }

    #[test, expected_failure(abort_code = fee_turnover::EEpochAhead)]
    fun record_at_ahead_of_the_ring_aborts() {
        // Pending credits are earned at fill time, so one postdating a ring rolled
        // to the current epoch means the caller forgot to roll — never valid.
        let mut turnover = fee_turnover::empty(3);
        turnover.record_at(4, 10);
    }

    // === EpochAmount ===

    #[test]
    fun epoch_amount_round_trips_and_accumulates() {
        let mut entry = fee_turnover::new_epoch_amount(7, 100);
        assert_eq!(entry.entry_epoch(), 7);
        assert_eq!(entry.entry_amount(), 100);

        entry.add_to_entry(50);
        assert_eq!(entry.entry_amount(), 150);
    }

    // === total_at agrees with rolling ===

    #[test]
    fun total_at_matches_what_rolling_would_leave() {
        // The read-only view and the mutating roll must never disagree, or a
        // trader's displayed tier differs from the one they are charged at.
        let window = constants::turnover_window_epochs();

        let mut probe = 0;
        while (probe <= window + 3) {
            let mut rolled = fee_turnover::empty(0);
            rolled.record(10);
            rolled.roll(1);
            rolled.record(20);
            rolled.roll(2);
            rolled.record(30);

            let mut viewed = fee_turnover::empty(0);
            viewed.record(10);
            viewed.roll(1);
            viewed.record(20);
            viewed.roll(2);
            viewed.record(30);

            // `total_at` predicts, `roll` performs — compare them at every offset.
            let predicted = viewed.total_at(probe);
            rolled.roll(probe);
            assert_eq!(predicted, rolled.total());

            probe = probe + 1;
        };
    }

    #[test]
    fun total_at_is_stable_for_the_current_and_past_epochs() {
        let mut turnover = fee_turnover::empty(5);
        turnover.record(100);

        assert_eq!(turnover.total_at(5), 100);
        // Reading "as of" an earlier epoch cannot invent history.
        assert_eq!(turnover.total_at(4), 100);
        assert_eq!(turnover.total_at(0), 100);
    }

    #[test]
    fun total_at_reports_zero_past_the_window_without_mutating() {
        let window = constants::turnover_window_epochs();
        let mut turnover = fee_turnover::empty(0);
        turnover.record(5_000);

        assert_eq!(turnover.total_at(window), 0);
        // The view left the ring untouched — the stale sum is still there until a
        // real roll happens on the next trade.
        assert_eq!(turnover.total(), 5_000);
        assert_eq!(turnover.anchor_epoch(), 0);
    }
}
