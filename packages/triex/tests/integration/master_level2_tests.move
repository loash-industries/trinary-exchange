// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_master_level2_tests;

use sui::{sui::SUI, test_scenario::{begin, end}};
use token::cred::CRED;
use triexbook::{
    balance_manager_tests as balance_manager_tests,
    constants,
    integration_test_utils as utils,
    pool_tests
};

const EIncorrectLevel2Price: u64 = 14;
const EIncorrectLevel2Quantity: u64 = 15;
const EIncorrectLevel2Length: u64 = 18;

#[test]
fun test_get_level_2_range_ok() {
    test_get_level_2_range();
}

fun test_get_level_2_range() {
    // There is a reference pool with SUI as base asset and CRED as quote asset.
    // We call get level 2 range for the reference pool, should return correct vectors.
    let mut test = begin(utils::owner());
    let registry_id = pool_tests::setup_test(utils::owner(), &mut test);
    pool_tests::set_time(0, &mut test);

    let starting_balance = 10000 * constants::float_scaling();
    let owner_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        utils::owner(),
        starting_balance,
        &mut test,
    );
    let pool1_reference_id = pool_tests::setup_reference_pool<SUI, CRED>(
        utils::owner(),
        registry_id,
        owner_balance_manager_id,
        constants::cred_multiplier(),
        &mut test,
    );

    // Currently there's a bid order at price 20 with quantity 1.
    // OWNER places another bid order in the reference pool at price 20 and quantity 2.
    let price = 20 * constants::float_scaling();
    let quantity = 2 * constants::float_scaling();
    let is_bid = true;
    pool_tests::place_limit_order<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        owner_balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        constants::max_u64(),
        &mut test,
    );

    // OWNER places another order in the reference pool at price 30 and quantity 5.
    let price = 30 * constants::float_scaling();
    let quantity = 5 * constants::float_scaling();
    let is_bid = true;
    pool_tests::place_limit_order<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        owner_balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        constants::max_u64(),
        &mut test,
    );

    // OWNER places a bid that will be expired, has no effect on level 2 range.
    pool_tests::place_limit_order<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        owner_balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pool_tests::get_time(&mut test) + 100,
        &mut test,
    );

    pool_tests::set_time(200, &mut test);

    // Get level 2 range for the reference pool, should return correct vectors.
    let is_bid = true;
    let (prices, quantities) = utils::get_level2_range<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        1,
        30 * constants::float_scaling(),
        is_bid,
        &mut test,
    );
    assert!(prices[0] == 30 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(prices[1] == 20 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(quantities[0] == 5 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(quantities[1] == 3 * constants::float_scaling(), EIncorrectLevel2Quantity);

    // Include price 20 but exclude price 30.
    let (prices, quantities) = utils::get_level2_range<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        1,
        20 * constants::float_scaling(),
        is_bid,
        &mut test,
    );
    assert!(prices[0] == 20 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(quantities[0] == 3 * constants::float_scaling(), EIncorrectLevel2Quantity);

    // Exclude all prices.
    let (prices, quantities) = utils::get_level2_range<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        21 * constants::float_scaling(),
        29 * constants::float_scaling(),
        is_bid,
        &mut test,
    );
    assert!(prices.length() == 0, EIncorrectLevel2Price);
    assert!(quantities.length() == 0, EIncorrectLevel2Quantity);

    // Currently there's an ask order at price 180 with quantity 1.
    // OWNER places another ask order in the reference pool at price 180 and quantity 2.
    let price = 180 * constants::float_scaling();
    let quantity = 2 * constants::float_scaling();
    let is_bid = false;
    pool_tests::place_limit_order<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        owner_balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        constants::max_u64(),
        &mut test,
    );

    // OWNER places another ask order that will be expired.
    pool_tests::place_limit_order<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        owner_balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        pool_tests::get_time(&mut test) + 100,
        &mut test,
    );

    pool_tests::set_time(400, &mut test);

    // OWNER places another ask order at price 170 and quantity 5.
    let price = 170 * constants::float_scaling();
    let quantity = 5 * constants::float_scaling();
    let is_bid = false;
    pool_tests::place_limit_order<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        owner_balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        constants::max_u64(),
        &mut test,
    );

    // Get level 2 range for the reference pool, should return correct vectors.
    let is_bid = false;
    let (prices, quantities) = utils::get_level2_range<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        170 * constants::float_scaling(),
        200 * constants::float_scaling(),
        is_bid,
        &mut test,
    );
    assert!(prices[0] == 170 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(prices[1] == 180 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(quantities[0] == 5 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(quantities[1] == 3 * constants::float_scaling(), EIncorrectLevel2Quantity);

    // Include price 180 but exclude price 170.
    let (prices, quantities) = utils::get_level2_range<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        180 * constants::float_scaling(),
        200 * constants::float_scaling(),
        is_bid,
        &mut test,
    );
    assert!(prices[0] == 180 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(quantities[0] == 3 * constants::float_scaling(), EIncorrectLevel2Quantity);

    // Include price 170 but exclude 180.
    let (prices, quantities) = utils::get_level2_range<SUI, CRED>(
        utils::owner(),
        pool1_reference_id,
        170 * constants::float_scaling(),
        179 * constants::float_scaling(),
        is_bid,
        &mut test,
    );
    assert!(prices[0] == 170 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(quantities[0] == 5 * constants::float_scaling(), EIncorrectLevel2Quantity);

    // Only the best bid of 30 and best ask of 170 should be returned.
    let (bid_prices, bid_quantities, ask_prices, ask_quantities) = utils::get_level2_ticks_from_mid<
        SUI,
        CRED,
    >(
        utils::owner(),
        pool1_reference_id,
        1,
        &mut test,
    );
    assert!(bid_prices[0] == 30 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(bid_quantities[0] == 5 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(ask_prices[0] == 170 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(ask_quantities[0] == 5 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(bid_prices.length() == 1, EIncorrectLevel2Length);
    assert!(ask_prices.length() == 1, EIncorrectLevel2Length);
    assert!(bid_quantities.length() == 1, EIncorrectLevel2Length);
    assert!(ask_quantities.length() == 1, EIncorrectLevel2Length);

    // Both bids and asks (2 each) should be returned.
    let (bid_prices, bid_quantities, ask_prices, ask_quantities) = utils::get_level2_ticks_from_mid<
        SUI,
        CRED,
    >(
        utils::owner(),
        pool1_reference_id,
        2,
        &mut test,
    );
    assert!(bid_prices[0] == 30 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(bid_quantities[0] == 5 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(bid_prices[1] == 20 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(bid_quantities[1] == 3 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(ask_prices[0] == 170 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(ask_quantities[0] == 5 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(ask_prices[1] == 180 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(ask_quantities[1] == 3 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(bid_prices.length() == 2, EIncorrectLevel2Length);
    assert!(ask_prices.length() == 2, EIncorrectLevel2Length);
    assert!(bid_quantities.length() == 2, EIncorrectLevel2Length);
    assert!(ask_quantities.length() == 2, EIncorrectLevel2Length);

    // Should only return 2 bids and 2 asks even though tick is higher.
    let (bid_prices, bid_quantities, ask_prices, ask_quantities) = utils::get_level2_ticks_from_mid<
        SUI,
        CRED,
    >(
        utils::owner(),
        pool1_reference_id,
        3,
        &mut test,
    );
    assert!(bid_prices[0] == 30 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(bid_quantities[0] == 5 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(bid_prices[1] == 20 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(bid_quantities[1] == 3 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(ask_prices[0] == 170 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(ask_quantities[0] == 5 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(ask_prices[1] == 180 * constants::float_scaling(), EIncorrectLevel2Price);
    assert!(ask_quantities[1] == 3 * constants::float_scaling(), EIncorrectLevel2Quantity);
    assert!(bid_prices.length() == 2, EIncorrectLevel2Length);
    assert!(ask_prices.length() == 2, EIncorrectLevel2Length);
    assert!(bid_quantities.length() == 2, EIncorrectLevel2Length);
    assert!(ask_quantities.length() == 2, EIncorrectLevel2Length);

    end(test);
}
