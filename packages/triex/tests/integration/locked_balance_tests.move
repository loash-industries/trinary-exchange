// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_locked_balance_tests;

use sui::{sui::SUI, test_scenario::{begin, end, return_shared}, test_utils::destroy};
use token::cred::CRED;
use triexbook::{
    balance_manager_tests::{Self as balance_manager_tests, USDC},
    constants,
    integration_test_utils as utils,
    math,
    pool::Pool,
    pool_tests,
    registry
};

#[test]
fun test_locked_balance_bid_ok() {
    test_locked_balance(true)
}

#[test]
fun test_locked_balance_ask_ok() {
    test_locked_balance(false)
}

/// Default maker rate for a volatile pool: 1.8%.
fun maker_fee_on(quote_quantity: u64): u64 {
    math::mul(quote_quantity, 18_000_000)
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
    // A bid locks its quote principal plus the maker fee charged on it; an
    // ask locks only base, and is charged out of its quote proceeds on fill.
    let quote = math::mul(price, quantity);
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
        utils::add_usdc(&mut alice_locked_balance, quote + maker_fee_on(quote));
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
        // Half the bid filled: both its principal and its fee shrink with the
        // remaining quantity.
        utils::sub_usdc(&mut alice_locked_balance, quote / 2 + maker_fee_on(quote / 2));
        utils::add_sui(&mut alice_locked_balance, quantity / 2);
    } else {
        // Alice's ask proceeds settle net of the maker fee taken out of them.
        utils::add_usdc(&mut alice_locked_balance, quote / 2 - maker_fee_on(quote / 2));
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
        utils::add_usdc(&mut alice_locked_balance, quote + maker_fee_on(quote));
        utils::sub_sui(&mut alice_locked_balance, quantity / 2);
    } else {
        utils::add_sui(&mut alice_locked_balance, quantity);
        // Placing again settles her netted proceeds out to her balance manager
        utils::sub_usdc(&mut alice_locked_balance, quote / 2 - maker_fee_on(quote / 2));
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

/// An order records its maker fee rate at placement: after the admin changes
/// rates and the epoch advances, a resting order's locked balance still
/// reflects the rate it was placed under, while a new order locks at the
/// freshly promoted rate.
#[test]
fun test_locked_balance_uses_snapshotted_maker_rate() {
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

    let price = 2 * constants::float_scaling();
    let quantity = 3 * constants::float_scaling();
    let quote = math::mul(price, quantity);
    // Default maker rate at placement: 1.8% = 180 bps
    let fee_at_default_rate = quote * 180 / 10000;

    pool_tests::place_limit_order<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    let (_, quote_locked, _) = utils::locked_balance<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        &mut test,
    );
    assert!(quote_locked == quote + fee_at_default_rate, 0);

    // Admin lowers the rates for the next epoch: taker 1%, maker 0.5%.
    test.next_tx(utils::owner());
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool1_id);
        pool.set_next_epoch_fee(10_000_000, 5_000_000, &admin_cap);
        return_shared(pool);
        destroy(admin_cap);
    };
    test.next_epoch(utils::owner());

    // The resting order still reports its snapshotted 1.8% rate.
    let (_, quote_locked, _) = utils::locked_balance<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        &mut test,
    );
    assert!(quote_locked == quote + fee_at_default_rate, 1);

    // A new order placed in the new epoch locks at the promoted 0.5% rate.
    let fee_at_new_rate = quote * 50 / 10000;
    pool_tests::place_limit_order<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    let (_, quote_locked, _) = utils::locked_balance<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        &mut test,
    );
    assert!(quote_locked == 2 * quote + fee_at_default_rate + fee_at_new_rate, 2);

    end(test);
}
