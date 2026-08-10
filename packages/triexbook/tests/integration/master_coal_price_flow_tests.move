// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_master_cred_price_flow_tests;

use sui::{sui::SUI, test_scenario::{begin, end, return_shared}};
use token::cred::CRED;
use triexbook::{
    balance_manager::{Self as balance_manager, BalanceManager},
    balance_manager_tests::{Self as balance_manager_tests, SPAM, USDC},
    constants,
    integration_test_utils as utils,
    math,
    pool_tests
};

const NoError: u64 = 0;

#[test]
fun test_master_cred_price_ok() {
    test_master_cred_price(NoError)
}

fun test_master_cred_price(error_code: u64) {
    let mut test = begin(utils::owner());
    let registry_id = pool_tests::setup_test(utils::owner(), &mut test);

    let starting_balance = 10000 * constants::float_scaling();

    let owner_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        utils::owner(),
        starting_balance,
        &mut test,
    );

    let pool1_id = pool_tests::setup_reference_pool<SUI, CRED>(
        utils::owner(),
        registry_id,
        owner_balance_manager_id,
        constants::cred_multiplier(),
        &mut test,
    );
    let pool2_id = pool_tests::setup_pool_with_default_fees<SPAM, SUI>(
        utils::owner(),
        registry_id,
        false,
        false,
        &mut test,
    );

    pool_tests::set_time(0, &mut test);

    utils::check_mid_price<SUI, CRED>(
        pool1_id,
        constants::cred_multiplier(),
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
    let price = constants::cred_multiplier();
    let quantity = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let is_bid = true;
    let maker_fee = constants::maybe_apply_fee(is_bid);
    let taker_fee = constants::maybe_apply_fee(is_bid);
    let mut alice_balance = utils::expected_balances_all(starting_balance);
    let mut bob_balance = utils::expected_balances_all(starting_balance);

    assert!(test.ctx().epoch() == 0, 0);

    let order_info = pool_tests::place_limit_order<SUI, CRED>(
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

    pool_tests::cancel_order<SUI, CRED>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        order_info.order_id(),
        &mut test,
    );

    utils::execute_cross_trading<SUI, CRED>(
        pool1_id,
        alice_balance_manager_id,
        bob_balance_manager_id,
        order_type,
        price,
        quantity,
        is_bid,
        constants::max_u64(),
        &mut test,
    );

    let alice_cred_after = {
        test.next_tx(utils::alice());
        let balance_manager = test.take_shared_by_id<BalanceManager>(alice_balance_manager_id);
        let cred = balance_manager::balance<CRED>(&balance_manager);
        return_shared(balance_manager);
        cred
    };
    let bob_cred_after = {
        test.next_tx(utils::bob());
        let balance_manager = test.take_shared_by_id<BalanceManager>(bob_balance_manager_id);
        let cred = balance_manager::balance<CRED>(&balance_manager);
        return_shared(balance_manager);
        cred
    };

    utils::add_sui(&mut alice_balance, 2 * quantity);
    utils::set_cred(&mut alice_balance, alice_cred_after);
    utils::sub_sui(&mut bob_balance, 2 * quantity);
    utils::set_cred(&mut bob_balance, bob_cred_after);
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);

    pool_tests::set_time(100_000, &mut test);

    let price = 125 * constants::float_scaling();
    pool_tests::place_limit_order<SUI, CRED>(
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
    let alice_cred_after_bid = {
        test.next_tx(utils::alice());
        let balance_manager = test.take_shared_by_id<BalanceManager>(alice_balance_manager_id);
        let cred = balance_manager::balance<CRED>(&balance_manager);
        return_shared(balance_manager);
        cred
    };
    utils::set_cred(&mut alice_balance, alice_cred_after_bid);

    let price = 175 * constants::float_scaling();
    pool_tests::place_limit_order<SUI, CRED>(
        utils::bob(),
        pool1_id,
        bob_balance_manager_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    utils::sub_sui(&mut bob_balance, quantity);

    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);

    test.next_epoch(utils::owner());
    assert!(test.ctx().epoch() == 1, 0);
    pool_tests::set_time(200_000, &mut test);

    utils::check_mid_price<SUI, CRED>(
        pool1_id,
        150 * constants::float_scaling(),
        &mut test,
    );

    let price = 10 * constants::float_scaling();
    let order_info = pool_tests::place_limit_order<SPAM, SUI>(
        utils::alice(),
        pool2_id,
        alice_balance_manager_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    let cred_multiplier = 125_000_000_000;
    utils::sub_sui(&mut alice_balance, math::mul(price, quantity));
    utils::sub_cred(
        &mut alice_balance,
        math::mul(
            math::mul(maker_fee, math::mul(price, quantity)),
            cred_multiplier,
        ),
    );
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);

    pool_tests::cancel_order<SPAM, SUI>(
        utils::alice(),
        pool2_id,
        alice_balance_manager_id,
        order_info.order_id(),
        &mut test,
    );
    utils::add_sui(&mut alice_balance, math::mul(price, quantity));
    utils::add_cred(
        &mut alice_balance,
        math::mul(
            math::mul(maker_fee, math::mul(price, quantity)),
            cred_multiplier,
        ),
    );
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);

    let price = 10 * constants::float_scaling();
    let quantity = 3 * constants::float_scaling();
    utils::execute_cross_trading<SPAM, SUI>(
        pool2_id,
        alice_balance_manager_id,
        bob_balance_manager_id,
        order_type,
        price,
        quantity,
        is_bid,
        constants::max_u64(),
        &mut test,
    );

    let maker_quantity_traded = quantity;
    let taker_quantity_traded = quantity;
    let quantity_traded = maker_quantity_traded + taker_quantity_traded;

    let alice_maker_fee = math::mul(
        math::mul(maker_fee, math::mul(price, quantity)),
        cred_multiplier,
    );
    let alice_taker_fee = math::mul(
        math::mul(taker_fee, math::mul(price, quantity)),
        cred_multiplier,
    );

    utils::add_spam(&mut alice_balance, quantity_traded);
    utils::sub_sui(&mut alice_balance, math::mul(price, quantity_traded));
    utils::sub_cred(&mut alice_balance, alice_maker_fee + alice_taker_fee);

    utils::sub_spam(&mut bob_balance, quantity_traded);
    utils::add_sui(&mut bob_balance, math::mul(price, quantity_traded));

    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);

    end(test);
}
