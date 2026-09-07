// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::fee_schedule_tests;

use std::unit_test::assert_eq;
use triexbook::fee_schedule;

// Mirrors the bounds `governance` passes in. Kept local because `validate`
// takes them as arguments precisely so this module stays a leaf.
const MIN_TAKER: u64 = 100_000; // 1 bp
const MAX_TAKER: u64 = 1_000_000_000; // 100%
const MAX_MAKER: u64 = 1_000_000_000; // 100%
const FEE_MULTIPLE: u64 = 1000; // 0.01 bp

/// The launch ladder from the TRIEX-137 plan, in raw units (CRED has 6
/// decimals): 2.20%/1.80% down to 0.55%/0.40%.
fun launch_ladder(): fee_schedule::FeeSchedule {
    fee_schedule::from_vectors(
        vector[
            0,
            200_000_000,
            1_000_000_000,
            5_000_000_000,
            20_000_000_000,
            100_000_000_000,
            400_000_000_000,
            1_500_000_000_000,
        ],
        vector[
            22_000_000,
            19_000_000,
            16_000_000,
            13_000_000,
            10_500_000,
            8_500_000,
            7_000_000,
            5_500_000,
        ],
        vector[
            18_000_000,
            15_500_000,
            13_000_000,
            10_500_000,
            8_500_000,
            6_500_000,
            5_000_000,
            4_000_000,
        ],
    )
}

// === Resolution ===

#[test]
fun flat_schedule_prices_like_a_flat_fee() {
    let schedule = fee_schedule::flat(22_000_000, 18_000_000);

    // Every turnover resolves to the single rung, so a one-tier ladder is
    // indistinguishable from the flat rate it replaces.
    let (tier, taker, maker) = schedule.resolve(0);
    assert_eq!(tier, 0);
    assert_eq!(taker, 22_000_000);
    assert_eq!(maker, 18_000_000);

    let (tier, taker, maker) = schedule.resolve(999_999_999_999_999);
    assert_eq!(tier, 0);
    assert_eq!(taker, 22_000_000);
    assert_eq!(maker, 18_000_000);
}

#[test]
fun zero_turnover_resolves_to_entry_rung() {
    let (tier, taker, maker) = launch_ladder().resolve(0);

    assert_eq!(tier, 0);
    assert_eq!(taker, 22_000_000);
    assert_eq!(maker, 18_000_000);
}

#[test]
fun threshold_is_inclusive() {
    let schedule = launch_ladder();

    // One unit short of tier 1 stays on tier 0...
    let (tier, taker, _maker) = schedule.resolve(199_999_999);
    assert_eq!(tier, 0);
    assert_eq!(taker, 22_000_000);

    // ...and landing exactly on the threshold promotes.
    let (tier, taker, maker) = schedule.resolve(200_000_000);
    assert_eq!(tier, 1);
    assert_eq!(taker, 19_000_000);
    assert_eq!(maker, 15_500_000);
}

#[test]
fun resolves_to_highest_qualifying_tier() {
    let schedule = launch_ladder();

    // Between tier 4 and tier 5: takes tier 4, not the first that qualifies.
    let (tier, taker, maker) = schedule.resolve(99_999_999_999);
    assert_eq!(tier, 4);
    assert_eq!(taker, 10_500_000);
    assert_eq!(maker, 8_500_000);

    // Past the top rung, the ladder tops out rather than running off the end.
    let (tier, taker, maker) = schedule.resolve(50_000_000_000_000);
    assert_eq!(tier, 7);
    assert_eq!(taker, 5_500_000);
    assert_eq!(maker, 4_000_000);
}

#[test]
fun every_rung_is_reachable() {
    let schedule = launch_ladder();
    let expected_takers = vector[
        22_000_000,
        19_000_000,
        16_000_000,
        13_000_000,
        10_500_000,
        8_500_000,
        7_000_000,
        5_500_000,
    ];

    let mut i = 0;
    while (i < schedule.tier_count()) {
        let tier_def = schedule.tier_at(i);
        let (tier, taker, _maker) = schedule.resolve(tier_def.min_turnover());
        assert_eq!(tier, i);
        assert_eq!(taker, expected_takers[i]);
        i = i + 1;
    };
}

#[test]
fun base_rates_report_the_entry_rung() {
    let schedule = launch_ladder();

    assert_eq!(schedule.base_taker_fee(), 22_000_000);
    assert_eq!(schedule.base_maker_fee(), 18_000_000);
}

// === Validation ===

#[test]
fun launch_ladder_validates() {
    launch_ladder().validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test]
fun flat_schedule_validates() {
    fee_schedule::flat(22_000_000, 18_000_000)
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test]
fun zero_maker_fee_is_allowed() {
    // Makers have no floor — a zero maker rate is a legitimate liquidity
    // incentive, and only takers keep a minimum.
    fee_schedule::from_vectors(vector[0, 200_000_000], vector[22_000_000, 19_000_000], vector[
        18_000_000,
        0,
    ]).validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::EEmptySchedule)]
fun empty_schedule_rejected() {
    fee_schedule::from_vectors(vector[], vector[], vector[])
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::EFirstTierNotZero)]
fun first_tier_must_start_at_zero() {
    // Otherwise a brand-new account would resolve to no tier at all.
    fee_schedule::from_vectors(vector[1], vector[22_000_000], vector[18_000_000])
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::EThresholdsNotAscending)]
fun duplicate_thresholds_rejected() {
    fee_schedule::from_vectors(vector[0, 200_000_000, 200_000_000], vector[
        22_000_000,
        19_000_000,
        16_000_000,
    ], vector[18_000_000, 15_500_000, 13_000_000])
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::EThresholdsNotAscending)]
fun descending_thresholds_rejected() {
    fee_schedule::from_vectors(vector[0, 400_000_000, 200_000_000], vector[
        22_000_000,
        19_000_000,
        16_000_000,
    ], vector[18_000_000, 15_500_000, 13_000_000])
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::ETakerRateNotMonotone)]
fun rising_taker_rate_rejected() {
    // More turnover must never cost more.
    fee_schedule::from_vectors(vector[0, 200_000_000], vector[19_000_000, 22_000_000], vector[
        18_000_000,
        15_500_000,
    ]).validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::EMakerRateNotMonotone)]
fun rising_maker_rate_rejected() {
    fee_schedule::from_vectors(vector[0, 200_000_000], vector[22_000_000, 19_000_000], vector[
        15_500_000,
        18_000_000,
    ]).validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::EInvalidTakerFee)]
fun taker_rate_below_floor_rejected() {
    fee_schedule::from_vectors(vector[0], vector[1000], vector[0])
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::EInvalidTakerFee)]
fun taker_rate_above_cap_rejected() {
    fee_schedule::from_vectors(vector[0], vector[MAX_TAKER + FEE_MULTIPLE], vector[0])
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::EInvalidTakerFee)]
fun taker_rate_off_multiple_rejected() {
    fee_schedule::from_vectors(vector[0], vector[22_000_001], vector[18_000_000])
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::EInvalidMakerFee)]
fun maker_rate_off_multiple_rejected() {
    fee_schedule::from_vectors(vector[0], vector[22_000_000], vector[18_000_001])
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::ETooManyTiers)]
fun over_long_schedule_rejected() {
    // Resolution is a linear scan on the fill path, so the tier count is
    // bounded. Build one rung past the cap, still otherwise valid.
    let mut min_turnovers = vector[];
    let mut taker_fees = vector[];
    let mut maker_fees = vector[];
    let mut i = 0;
    while (i < 17) {
        min_turnovers.push_back((i as u128) * 1_000_000);
        // Strictly non-increasing and comfortably inside the bounds.
        taker_fees.push_back(22_000_000 - (i * FEE_MULTIPLE));
        maker_fees.push_back(18_000_000 - (i * FEE_MULTIPLE));
        i = i + 1;
    };

    fee_schedule::from_vectors(min_turnovers, taker_fees, maker_fees)
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::EVectorLengthMismatch)]
fun mismatched_taker_column_rejected() {
    fee_schedule::from_vectors(vector[0, 200_000_000], vector[22_000_000], vector[
        18_000_000,
        15_500_000,
    ]);
}

#[test, expected_failure(abort_code = fee_schedule::EVectorLengthMismatch)]
fun mismatched_maker_column_rejected() {
    fee_schedule::from_vectors(vector[0, 200_000_000], vector[22_000_000, 19_000_000], vector[
        18_000_000,
    ]);
}

// === Boundary cases ===

#[test]
fun equal_rates_across_tiers_validate() {
    // Non-increasing, not strictly decreasing: a rung that raises the turnover
    // requirement without cutting the rate is legal. Useful for staging a
    // ladder before the discounts are decided.
    fee_schedule::from_vectors(vector[0, 200_000_000, 1_000_000_000], vector[
        22_000_000,
        22_000_000,
        19_000_000,
    ], vector[18_000_000, 18_000_000, 18_000_000])
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test]
fun exactly_max_tiers_validates() {
    // 17 is rejected by `over_long_schedule_rejected`; the cap itself must be
    // usable, or the bound is off by one.
    let mut min_turnovers = vector[];
    let mut taker_fees = vector[];
    let mut maker_fees = vector[];
    let mut i = 0;
    while (i < 16) {
        min_turnovers.push_back((i as u128) * 1_000_000);
        taker_fees.push_back(22_000_000 - (i * FEE_MULTIPLE));
        maker_fees.push_back(18_000_000 - (i * FEE_MULTIPLE));
        i = i + 1;
    };
    let schedule = fee_schedule::from_vectors(min_turnovers, taker_fees, maker_fees);
    schedule.validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);

    assert_eq!(schedule.tier_count(), 16);
    // And the last rung is still reachable.
    let (tier, _taker, _maker) = schedule.resolve(15_000_000);
    assert_eq!(tier, 15);
}

#[test]
fun taker_rate_at_the_floor_validates() {
    fee_schedule::from_vectors(vector[0], vector[MIN_TAKER], vector[0])
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test]
fun taker_rate_at_the_cap_validates() {
    fee_schedule::from_vectors(vector[0], vector[MAX_TAKER], vector[MAX_MAKER])
        .validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test, expected_failure(abort_code = fee_schedule::EInvalidMakerFee)]
fun maker_rate_above_cap_rejected() {
    fee_schedule::from_vectors(vector[0], vector[22_000_000], vector[
        MAX_MAKER + FEE_MULTIPLE,
    ]).validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);
}

#[test]
fun saturating_turnover_resolves_to_the_top_rung() {
    // Turnover is u128 and the ring sums u64 buckets, so it cannot realistically
    // reach this — but resolution must not walk off the end regardless.
    let (tier, taker, maker) = launch_ladder().resolve(340282366920938463463374607431768211455);

    assert_eq!(tier, 7);
    assert_eq!(taker, 5_500_000);
    assert_eq!(maker, 4_000_000);
}

#[test]
fun a_threshold_above_any_reachable_turnover_is_simply_never_hit() {
    let schedule = fee_schedule::from_vectors(
        vector[0, 340282366920938463463374607431768211455],
        vector[22_000_000, 100_000],
        vector[18_000_000, 0],
    );
    schedule.validate(MIN_TAKER, MAX_TAKER, MAX_MAKER, FEE_MULTIPLE);

    let (tier, taker, _maker) = schedule.resolve(1_000_000_000_000_000);
    assert_eq!(tier, 0);
    assert_eq!(taker, 22_000_000);
}

#[test]
fun single_tier_ladder_never_promotes() {
    let schedule = fee_schedule::flat(22_000_000, 18_000_000);
    let (tier, _taker, _maker) = schedule.resolve(
        340282366920938463463374607431768211455,
    );

    assert_eq!(tier, 0);
}
