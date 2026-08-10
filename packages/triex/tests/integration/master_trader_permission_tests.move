// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_master_trader_permission_tests;

use sui::{sui::SUI, test_scenario::{begin, end}};
use token::cred::CRED;
use triexbook::{
    balance_manager_tests::{Self as balance_manager_tests, USDC},
    constants,
    integration_test_utils::{Self as utils, ExpectedBalances},
    math,
    pool_tests
};

const NoError: u64 = 0;
const NoErrorCredAsBase: u64 = 1;
const NoErrorPayWithInput: u64 = 2;

const EInvalidOwner: u64 = 11;
// Local copies of abort codes (module constants are private).
const ECapNotInListAbort: u64 = 100;
const EInvalidTraderAbort: u64 = 101;

#[test]
fun test_trader_permission_and_modify_returned_ok() {
    test_trader_permission_and_modify_returned(NoError)
}

#[test]
fun test_trader_permission_and_modify_returned_input_ok() {
    test_trader_permission_and_modify_returned(NoErrorPayWithInput)
}

#[test]
fun test_trader_permission_and_modify_returned_cred_as_base_ok() {
    test_trader_permission_and_modify_returned(NoErrorCredAsBase)
}

#[test, expected_failure(abort_code = ::triexbook::balance_manager::EInvalidOwner)]
fun test_trader_permission_and_modify_returned_invalid_owner_e() {
    test_trader_permission_and_modify_returned(EInvalidOwner)
}

#[test, expected_failure(abort_code = ::triexbook::balance_manager::ECapNotInList)]
fun test_trader_permission_and_modify_trader_not_in_list_e() {
    test_trader_permission_and_modify_returned(ECapNotInListAbort)
}

#[test, expected_failure(abort_code = ::triexbook::balance_manager::EInvalidTrader)]
fun test_trader_permission_invalid_trader_e() {
    test_trader_permission_and_modify_returned(EInvalidTraderAbort)
}

fun test_trader_permission_and_modify_returned(error_code: u64) {
    let mut test = begin(utils::owner());
    let registry_id = pool_tests::setup_test(utils::owner(), &mut test);
    pool_tests::set_time(0, &mut test);
    let starting_balance = 10000 * constants::float_scaling();

    let owner_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        utils::owner(),
        starting_balance,
        &mut test,
    );
    let alice_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        utils::alice(),
        starting_balance,
        &mut test,
    );

    // Create pool and reference pool.
    let pool1_id = pool_tests::setup_pool_with_default_fees<SUI, USDC>(
        utils::owner(),
        registry_id,
        false,
        false,
        &mut test,
    );
    let _pool1_reference_id = if (error_code == NoErrorCredAsBase) {
        pool_tests::setup_reference_pool_cred_as_base<CRED, SUI>(
            utils::owner(),
            registry_id,
            owner_balance_manager_id,
            constants::cred_multiplier(),
            &mut test,
        )
    } else {
        pool_tests::setup_reference_pool<SUI, CRED>(
            utils::owner(),
            registry_id,
            owner_balance_manager_id,
            constants::cred_multiplier(),
            &mut test,
        )
    };

    // Bob tries to authorize himself on Alice's balance manager, will error.
    if (error_code == EInvalidOwner) {
        utils::authorize_trader(utils::bob(), alice_balance_manager_id, utils::bob(), &mut test);
    };

    // Alice gives Bob permission to trade on her balance manager.
    let bob_trade_cap_id = utils::authorize_trader(
        utils::alice(),
        alice_balance_manager_id,
        utils::bob(),
        &mut test,
    );

    // Variables to input into order.
    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 10 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let is_bid = true;
    let maker_fee = constants::maybe_apply_fee(is_bid);
    let mut alice_balance: ExpectedBalances = utils::expected_balances_all(starting_balance);

    // Bob places an order with quantity 10 in SUI/USDC pool at a price of 2 using Alice's balance manager.
    let order_info = pool_tests::place_limit_order<SUI, USDC>(
        utils::bob(),
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
    if (error_code == NoErrorPayWithInput) {
        utils::sub_usdc(
            &mut alice_balance,
            math::mul(
                math::mul(
                    constants::maybe_apply_fee(is_bid),
                    constants::fee_penalty_multiplier(),
                ),
                math::mul(price, quantity),
            ),
        );
    } else {
        utils::sub_cred(
            &mut alice_balance,
            math::mul(math::mul(maker_fee, constants::cred_multiplier()), quantity),
        );
    };
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);

    let quantity = 5 * constants::float_scaling();

    // Owner places an ask order at the same price matches with 5 of Alice's order.
    pool_tests::place_limit_order<SUI, USDC>(
        utils::owner(),
        pool1_id,
        owner_balance_manager_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );
    utils::add_sui(&mut alice_balance, quantity);

    let new_quantity = 8 * constants::float_scaling();
    let cancelled_quantity = 2 * constants::float_scaling();
    let remaining_quantity = 3 * constants::float_scaling();

    // Bob modifies the order from original quantity of 10 to 8.
    // Since quantity of 5 was filled, the effective quantity is 3.
    pool_tests::modify_order<SUI, USDC>(
        utils::bob(),
        pool1_id,
        alice_balance_manager_id,
        order_info.order_id(),
        new_quantity,
        &mut test,
    );
    utils::add_usdc(&mut alice_balance, math::mul(price, cancelled_quantity));
    if (error_code == NoErrorPayWithInput) {
        utils::add_usdc(
            &mut alice_balance,
            math::mul(
                math::mul(
                    constants::maybe_apply_fee(is_bid),
                    constants::fee_penalty_multiplier(),
                ),
                math::mul(price, cancelled_quantity),
            ),
        );
    } else {
        utils::add_cred(
            &mut alice_balance,
            math::mul(
                math::mul(maker_fee, constants::cred_multiplier()),
                cancelled_quantity,
            ),
        );
    };
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);

    // Alice cancels the order herself, should get correct refund of remaining quantity.
    pool_tests::cancel_order<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        order_info.order_id(),
        &mut test,
    );
    utils::add_usdc(&mut alice_balance, math::mul(price, remaining_quantity));
    if (error_code == NoErrorPayWithInput) {
        utils::add_usdc(
            &mut alice_balance,
            math::mul(
                math::mul(
                    constants::maybe_apply_fee(is_bid),
                    constants::fee_penalty_multiplier(),
                ),
                math::mul(price, remaining_quantity),
            ),
        );
    } else {
        utils::add_cred(
            &mut alice_balance,
            math::mul(
                math::mul(maker_fee, constants::cred_multiplier()),
                remaining_quantity,
            ),
        );
    };
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);

    // Alice revokes Bob's trading permission.
    utils::remove_trader(utils::alice(), alice_balance_manager_id, bob_trade_cap_id, &mut test);

    // Alice revokes Bob's trading permission again, removing a trader not in list will error.
    if (error_code == ECapNotInListAbort) {
        utils::remove_trader(utils::alice(), alice_balance_manager_id, bob_trade_cap_id, &mut test);
    };

    // Bob tries to place an order using Alice's balance manager, will error.
    if (error_code == EInvalidTraderAbort) {
        pool_tests::place_limit_order<SUI, USDC>(
            utils::bob(),
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
    };

    end(test);
}
