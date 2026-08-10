// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::trade_params_tests;

use std::unit_test::assert_eq;
use triexbook::trade_params;

// #feat:fees
// #[test]
// fun test_taker_fee_basic() {
//     let taker_fee = 1_000_000; // 0.1%
//     let maker_fee = 500_000; // 0.05%
//     let stake_required = 100 * constants::cred_unit();

//     let params = trade_params::new(taker_fee, maker_fee, stake_required);

//     assert_eq!(params.taker_fee(), taker_fee);
//     assert_eq!(params.maker_fee(), maker_fee);
//     assert_eq!(params.stake_required(), stake_required);
// }
#[test]
fun test_trade_params_basic() {
    let fee = 100_000_000;
    let params = trade_params::new(fee);
    assert_eq!(params.fee(), fee);
}

// #feat:stake
// #feat:fees
// #[test]
// fun test_taker_fee_for_user_no_stake_no_volume() {
//     let is_bid = true;
//     // #feat:fees
//     // let taker_fee = 2_000_000; // 0.2%
//     // let maker_fee = 500_000; // 0.05%
//     // let stake_required = 100 * constants::cred_unit();
//     // let params = trade_params::new(taker_fee, maker_fee, stake_required);
//     let fee = 100_000_000;
//     let params = trade_params::new(fee);

//     // User has no stake and no volume
//     // #feat:stake
//     // let active_stake = 0;
//     // let volume_in_cred = 0;

//     // #feat:fees
//     // let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_cred);
//     // // Should get full taker fee
//     // assert_eq!(user_taker_fee, taker_fee);
//     let user_taker_fee = params.taker_fee_for_user(is_bid);
//     assert_eq!(user_taker_fee, fee);
// }

// #feat:stake
// #feat:fees
// #[test]
// fun test_taker_fee_for_user_no_stake_no_volume_bud_not_bid() {
//     let is_bid = false;
//     // #feat:fees
//     // let taker_fee = 2_000_000; // 0.2%
//     // let maker_fee = 500_000; // 0.05%
//     // let stake_required = 100 * constants::cred_unit();
//     // let params = trade_params::new(taker_fee, maker_fee, stake_required);
//     let fee = 0;
//     let params = trade_params::new(fee);

//     // User has no stake and no volume
//     // #feat:stake
//     // let active_stake = 0;
//     // let volume_in_cred = 0;

//     // #feat:fees
//     // let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_cred);
//     // // Should get full taker fee
//     // assert_eq!(user_taker_fee, taker_fee);
//     let user_taker_fee = params.taker_fee_for_user(is_bid);
//     assert_eq!(user_taker_fee, fee);
// }

// #feat:stake
// #feat:fees
// #[test]
// fun test_taker_fee_for_user_has_stake_no_volume() {
//     let is_bid = true;
//     // #feat:fees
//     // let taker_fee = 2_000_000; // 0.2%
//     // let maker_fee = 500_000; // 0.05%
//     // let stake_required = 100 * constants::cred_unit();
//     // let params = trade_params::new(taker_fee, maker_fee, stake_required);
//     let fee = 100_000_000;
//     let params = trade_params::new(fee);

//     // User has stake but no volume
//     // #feat:stake
//     // let active_stake = 150 * constants::cred_unit();
//     // let volume_in_cred = 0;

//     // #feat:fees
//     // let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_cred);

//     // // Should still get full taker fee (needs both stake AND volume)
//     // assert_eq!(user_taker_fee, taker_fee);

//     let user_taker_fee = params.taker_fee_for_user(true);

//     // Should still get full taker fee (needs both stake AND volume)
//     assert_eq!(user_taker_fee, user_taker_fee);
// }

// #feat:stake
// #feat:fees
// #feat:stake
// #[test]
// fun test_taker_fee_for_user_has_volume_no_stake() {
//     let is_bid = true;
//     // #feat:fees
//     // let taker_fee = 2_000_000; // 0.2%
//     // let maker_fee = 500_000; // 0.05%
//     // let stake_required = 100 * constants::cred_unit();
//     // let params = trade_params::new(taker_fee, maker_fee, stake_required);
//     let fee = 100_000_000;
//     let params = trade_params::new(fee);

//     // User has volume but no stake
//     // #feat:stake
//     // let active_stake = 0;
//     // let volume_in_cred = 200 * (constants::cred_unit() as u64);

//     // #feat:fees
//     // let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_cred);

//     // // Should still get full taker fee (needs both stake AND volume)
//     // assert_eq!(user_taker_fee, taker_fee);

//     let user_taker_fee = params.taker_fee_for_user(true);

//     // Should still get full taker fee (needs both stake AND volume)
//     assert_eq!(user_taker_fee, user_taker_fee);
// }

// #feat:stake
// #[test]
// fun test_taker_fee_for_user_has_both_stake_and_volume() {
//     let is_bid = true;
//     // #feat:fees
//     // let taker_fee = 2_000_000; // 0.2%
//     // let maker_fee = 500_000; // 0.05%
//     // let stake_required = 100 * constants::cred_unit();
//     // let params = trade_params::new(taker_fee, maker_fee, stake_required);
//     let fee = 100_000_000;
//     let params = trade_params::new(fee);

//     // User has both stake and volume that meet requirements
//     // #feat:stake
//     // let active_stake = 150 * constants::cred_unit();
//     // let volume_in_cred = 200 * (constants::cred_unit() as u64);

//     // #feat:fees
//     // let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_cred);
//     // // Should get reduced taker fee (halved)
//     // assert_eq!(user_taker_fee, taker_fee / 2);
//     let user_taker_fee = params.taker_fee_for_user(is_bid);
//     assert_eq!(user_taker_fee, fee);
// }

#[test]
fun test_taker_fee_for_user_exactly_at_threshold() {
    // #feat:fees
    // let taker_fee = 1_000_000; // 0.1%
    // let maker_fee = 500_000; // 0.05%
    // let stake_required = 100 * constants::cred_unit();

    // let params = trade_params::new(taker_fee, maker_fee, stake_required);
    let is_bid = true;
    let fee = 100_000_000;
    let params = trade_params::new(fee);

    // User has exactly the required stake and volume
    // #feat:stake
    // let active_stake = 100 * constants::cred_unit();
    // let volume_in_cred = 100 * (constants::cred_unit() as u64);

    // #feat:fees
    // let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_cred);
    // // Should get reduced taker fee (halved)
    // assert_eq!(user_taker_fee, taker_fee / 2);
    let user_taker_fee = params.taker_fee_for_user(is_bid);
    assert_eq!(user_taker_fee, fee);
}

// #feat:stake
// #feat:fees
// #[test]
// fun test_taker_fee_for_user_stake_just_below_threshold() {
//     // #feat:fees
//     // let taker_fee = 1_000_000; // 0.1%
//     // let maker_fee = 500_000; // 0.05%
//     // let stake_required = 100 * constants::cred_unit();

//     // let params = trade_params::new(taker_fee, maker_fee, stake_required);
//     let is_bid = true;
//     let fee = 100_000_000;
//     let params = trade_params::new(fee);

//     // User has stake just below threshold but volume above

//     // let active_stake = 99 * constants::cred_unit();
//     // let volume_in_cred = 200 * (constants::cred_unit() as u64);

//     // #feat:fees
//     // let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_cred);

//     // // Should get full taker fee
//     // assert_eq!(user_taker_fee, taker_fee);
//     // let user_taker_fee = params.taker_fee_for_user(is_bid);
// }

// #feat:stake
// #feat:fees
// #[test]
// fun test_taker_fee_for_user_volume_just_below_threshold() {
//     // #feat:fees
//     // let taker_fee = 1_000_000; // 0.1%
//     // let maker_fee = 500_000; // 0.05%
//     // let stake_required = 100 * constants::cred_unit();

//     // let params = trade_params::new(taker_fee, maker_fee, stake_required);
//     let is_bid = true;
//     let fee = 100_000_000;
//     let params = trade_params::new(fee);

//     // User has volume just below threshold but stake above
//     let active_stake = 200 * constants::cred_unit();
//     let volume_in_cred = 99 * (constants::cred_unit() as u64);

//     // #feat:fees
//     // let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_cred);

//     // // Should get full taker fee
//     // assert_eq!(user_taker_fee, taker_fee);
//     let user_taker_fee = params.taker_fee_for_user(is_bid);
//     assert_eq!(user_taker_fee, fee);
// }

// #feat:stake
// #feat:fees
// #[test]
// fun test_taker_fee_for_user_with_high_stake_requirement() {
//     // #feat:fees
//     // let taker_fee = 4_000_000; // 0.4%
//     // let maker_fee = 500_000; // 0.05%
//     // let stake_required = 10_000 * constants::cred_unit(); // 10,000 CRED

//     // let params = trade_params::new(taker_fee, maker_fee, stake_required);
//     let is_bid = true;
//     let fee = 100_000_000;
//     let params = trade_params::new(fee);
//     // User has high stake and volume
//     let active_stake = 15_000 * constants::cred_unit();
//     let volume_in_cred = 20_000 * (constants::cred_unit() as u64);

//     // #feat:fees
//     // let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_cred);
//     // // Should get reduced taker fee (halved)
//     // assert_eq!(user_taker_fee, taker_fee / 2);
//     let user_taker_fee = params.taker_fee_for_user(is_bid);
//     assert_eq!(user_taker_fee, fee);
// }

// #feat:stake
// #feat:fees
// #[test]
// fun test_taker_fee_for_user_odd_taker_fee() {
//     // #feat:fees
//     // let taker_fee = 3_500_000; // 0.35%
//     // let maker_fee = 500_000; // 0.05%
//     // let stake_required = 50 * constants::cred_unit();

//     // let params = trade_params::new(taker_fee, maker_fee, stake_required);
//     let is_bid = true;
//     let fee = 100_000_000;
//     let params = trade_params::new(fee);

//     // User qualifies for reduced fee
//     let active_stake = 100 * constants::cred_unit();
//     let volume_in_cred = 100 * (constants::cred_unit() as u64);
//     // #feat:fees
//     // let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_cred);
//     // Should get reduced taker fee (halved)
//     // assert_eq!(user_taker_fee, 1_750_000);
//     let user_taker_fee = params.taker_fee_for_user(is_bid);
//     assert_eq!(user_taker_fee, fee);
// }

// #feat:stake
// #feat:fees
// #[test]
// fun test_taker_fee_for_user_zero_stake_requirement() {
//     // #feat:fees
//     // let taker_fee = 1_000_000; // 0.1%
//     // let maker_fee = 500_000; // 0.05%
//     // let stake_required = 0; // No stake required

//     // let params = trade_params::new(taker_fee, maker_fee, stake_required);
//     let is_bid = true;
//     let fee = 100_000_000;
//     let params = trade_params::new(fee);

//     // User has no stake but has volume
//     let active_stake = 0;
//     let volume_in_cred = 100 * (constants::cred_unit() as u64);

//     // #feat:fees
//     // let user_taker_fee = params.taker_fee_for_user(active_stake, volume_in_cred);
//     // // Should get reduced taker fee since stake_required is 0
//     // assert_eq!(user_taker_fee, taker_fee / 2);
//     let user_taker_fee = params.taker_fee_for_user(is_bid);
//     assert_eq!(user_taker_fee, fee);
// }
