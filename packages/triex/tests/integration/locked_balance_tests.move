// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_locked_balance_tests;

use sui::{sui::SUI, test_scenario::{begin, end}};
use token::cred::CRED;
use triexbook::{
    balance_manager_tests::{Self as balance_manager_tests, USDC},
    constants,
    integration_test_utils as utils,
    math,
    pool_tests
};

#[test]
fun test_locked_balance_bid_ok() {
    test_locked_balance(true)
}

#[test]
fun test_locked_balance_ask_ok() {
    test_locked_balance(false)
}

fun test_locked_balance(is_bid: bool) {
    let mut test = begin(utils::owner());
    let registry_id = pool_tests::setup_test(utils::owner(), &mut test);
    pool_tests::set_time(0, &mut test);

    let starting_balance = 10000 * constants::float_scaling();
    let owner_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        utils::owner(),
        starting_balance,
        &mut test,
    );

    let _pool1_reference_id = pool_tests::setup_reference_pool<SUI, CRED>(
        utils::owner(),
        registry_id,
        owner_balance_manager_id,
        constants::cred_multiplier(),
        &mut test,
    );

    let pool1_id = pool_tests::setup_pool_with_default_fees<SUI, USDC>(
        utils::owner(),
        registry_id,
        false,
        false,
        &mut test,
    );

    let alice_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        utils::alice(),
        starting_balance,
        &mut test,
    );
    let bob_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        utils::bob(),
        starting_balance,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 3 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let maker_fee = constants::maybe_apply_fee(is_bid);
    let cred_multiplier = constants::cred_multiplier();
    let mut alice_locked_balance = utils::expected_balances_all(0);

    assert!(test.ctx().epoch() == 0, 0);

    utils::check_locked_balance<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        &alice_locked_balance,
        &mut test,
    );

    pool_tests::place_limit_order<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    if (is_bid) {
        utils::add_usdc(&mut alice_locked_balance, math::mul(price, quantity));
        utils::add_cred(
            &mut alice_locked_balance,
            math::mul(
                math::mul(quantity, maker_fee),
                cred_multiplier,
            ),
        );
    } else {
        utils::add_sui(&mut alice_locked_balance, quantity);
    };

    utils::check_locked_balance<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        &alice_locked_balance,
        &mut test,
    );

    pool_tests::place_limit_order<SUI, USDC>(
        utils::bob(),
        pool1_id,
        bob_balance_manager_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity / 2,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    if (is_bid) {
        utils::sub_usdc(&mut alice_locked_balance, math::mul(price, quantity) / 2);
        utils::add_sui(&mut alice_locked_balance, quantity / 2);
        utils::sub_cred(
            &mut alice_locked_balance,
            math::mul(
                math::mul(quantity / 2, maker_fee),
                cred_multiplier,
            ),
        );
    } else {
        utils::add_usdc(&mut alice_locked_balance, math::mul(price, quantity) / 2);
        utils::sub_sui(&mut alice_locked_balance, quantity / 2);
    };

    utils::check_locked_balance<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        &alice_locked_balance,
        &mut test,
    );

    pool_tests::place_limit_order<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    if (is_bid) {
        utils::add_usdc(&mut alice_locked_balance, math::mul(price, quantity));
        utils::sub_sui(&mut alice_locked_balance, quantity / 2);
        utils::add_cred(
            &mut alice_locked_balance,
            math::mul(
                math::mul(quantity, maker_fee),
                cred_multiplier,
            ),
        );
    } else {
        utils::add_sui(&mut alice_locked_balance, quantity);
        utils::sub_usdc(&mut alice_locked_balance, math::mul(price, quantity) / 2);
    };

    utils::check_locked_balance<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        &alice_locked_balance,
        &mut test,
    );

    end(test);
}
