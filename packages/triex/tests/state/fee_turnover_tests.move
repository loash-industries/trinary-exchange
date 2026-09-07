// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::fee_turnover_tests;

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
