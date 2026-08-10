// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_master_flow_tests;

use sui::{sui::SUI, test_scenario::{begin, end}};
use token::cred::CRED;
use triexbook::{
    balance_manager_tests::{Self as balance_manager_tests, SPAM, USDC},
    balances,
    constants,
    integration_test_utils::{Self as utils, ExpectedBalances},
    math,
    pool_tests
};

const NoError: u64 = 0;

const EDuplicatePool: u64 = 1;
const ENotEnoughFunds: u64 = 2;

#[test]
fun test_master_ok() {
    test_master(NoError)
}

#[test, expected_failure(abort_code = ::triexbook::registry::EPoolAlreadyExists)]
fun test_master_duplicate_pool_e() {
    test_master(EDuplicatePool)
}

#[test, expected_failure(abort_code = ::triexbook::balance_manager::EBalanceManagerBalanceTooLow)]
fun test_master_not_enough_funds_e() {
    test_master(ENotEnoughFunds)
}

fun test_master(error_code: u64) {
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
    let _pool2_reference_id = pool_tests::setup_reference_pool<SPAM, CRED>(
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
    if (error_code == EDuplicatePool) {
        pool_tests::setup_pool_with_default_fees<USDC, SUI>(
            utils::owner(),
            registry_id,
            false,
            false,
            &mut test,
        );
    };
    let pool2_id = pool_tests::setup_pool_with_default_fees<SPAM, USDC>(
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
    let big_quantity = 1_000_000 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let is_bid = true;
    let maker_fee = constants::maybe_apply_fee(is_bid);
    let cred_multiplier = constants::cred_multiplier();
    let mut alice_balance = utils::expected_balances_all(starting_balance);
    let mut bob_balance = utils::expected_balances_all(starting_balance);

    assert!(test.ctx().epoch() == 0, 0);

    if (error_code == ENotEnoughFunds) {
        pool_tests::place_limit_order<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_balance_manager_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            big_quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
    };

    utils::withdraw_settled_amounts<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        &mut test,
    );

    let order_info_1 = pool_tests::place_limit_order<SUI, USDC>(
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
    utils::sub_usdc(&mut alice_balance, math::mul(price, quantity));
    utils::sub_cred(
        &mut alice_balance,
        math::mul(
            math::mul(quantity, maker_fee),
            cred_multiplier,
        ),
    );

    pool_tests::place_limit_order<SPAM, USDC>(
        utils::alice(),
        pool2_id,
        alice_balance_manager_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    utils::sub_spam(&mut alice_balance, quantity);

    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);

    test.next_epoch(utils::owner());
    assert!(test.ctx().epoch() == 1, 0);

    test.next_epoch(utils::owner());
    assert!(test.ctx().epoch() == 2, 0);
    let old_maker_fee = maker_fee;

    pool_tests::cancel_order<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        order_info_1.order_id(),
        &mut test,
    );
    utils::add_usdc(&mut alice_balance, math::mul(price, quantity));
    utils::add_cred(
        &mut alice_balance,
        math::mul(
            math::mul(quantity, old_maker_fee),
            cred_multiplier,
        ),
    );
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);

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
    utils::sub_usdc(&mut alice_balance, math::mul(price, quantity));
    utils::sub_cred(
        &mut alice_balance,
        math::mul(
            math::mul(quantity, maker_fee),
            cred_multiplier,
        ),
    );
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);

    let executed_quantity = 3 * constants::float_scaling();
    let quantity = constants::cred_multiplier();

    pool_tests::place_market_order<SUI, USDC>(
        utils::bob(),
        pool1_id,
        bob_balance_manager_id,
        constants::self_matching_allowed(),
        quantity,
        !is_bid,
        &mut test,
    );
    utils::sub_sui(&mut bob_balance, executed_quantity);
    utils::add_usdc(&mut bob_balance, math::mul(price, executed_quantity));
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);

    utils::withdraw_settled_amounts<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        &mut test,
    );
    utils::add_sui(&mut alice_balance, executed_quantity);

    utils::withdraw_settled_amounts<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        &mut test,
    );
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);

    test.next_epoch(utils::owner());
    assert!(test.ctx().epoch() == 3, 0);

    test.next_epoch(utils::owner());
    assert!(test.ctx().epoch() == 4, 0);

    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);

    let expected_vault_fee = 0;
    utils::check_vault_balances<SUI, USDC>(
        pool1_id,
        &balances::new(0, 0, expected_vault_fee),
        &mut test,
    );

    let quantity = 1 * constants::float_scaling();
    let mut i: u64 = 23;
    while (i > 0) {
        test.next_epoch(utils::owner());
        utils::execute_cross_trading<SUI, USDC>(
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
        i = i - 1;
    };

    let quantity_sui_traded = 46 * constants::float_scaling();
    utils::add_sui(&mut alice_balance, quantity_sui_traded);
    utils::sub_usdc(&mut alice_balance, math::mul(price, quantity_sui_traded));
    utils::sub_cred(
        &mut alice_balance,
        math::mul(
            math::mul(quantity_sui_traded, maker_fee),
            cred_multiplier,
        ),
    );
    utils::sub_sui(&mut bob_balance, quantity_sui_traded);
    utils::add_usdc(&mut bob_balance, math::mul(price, quantity_sui_traded));

    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);

    test.next_epoch(utils::owner());
    assert!(test.ctx().epoch() == 28, 0);

    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);

    let bob_rebates = 0;
    utils::add_cred(&mut bob_balance, bob_rebates);
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);

    let quantity = 500_000_000;
    utils::execute_cross_trading<SUI, USDC>(
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

    let taker_sui_traded = quantity;
    let maker_sui_traded = quantity;
    let quantity_sui_traded = taker_sui_traded + maker_sui_traded;
    utils::add_sui(&mut alice_balance, quantity_sui_traded);
    utils::sub_usdc(&mut alice_balance, math::mul(price, quantity_sui_traded));
    utils::sub_cred(
        &mut alice_balance,
        math::mul(
            math::mul(quantity_sui_traded, maker_fee),
            cred_multiplier,
        ),
    );
    utils::sub_sui(&mut bob_balance, quantity_sui_traded);
    utils::add_usdc(&mut bob_balance, math::mul(price, quantity_sui_traded));

    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);

    test.next_epoch(utils::owner());
    assert!(test.ctx().epoch() == 29, 0);

    let expected_amount_burned = 0;
    utils::add_cred(&mut alice_balance, 0);
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);

    utils::add_cred(&mut bob_balance, 0);
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);

    utils::burn_cred<SUI, USDC>(utils::alice(), pool1_id, expected_amount_burned, &mut test);

    end(test);
}
