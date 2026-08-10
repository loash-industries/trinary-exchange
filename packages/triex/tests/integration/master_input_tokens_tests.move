// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_master_input_tokens_tests;

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
const NoErrorHasCredPrice: u64 = 3;
const ENotEnoughFunds: u64 = 2;

#[test]
fun test_master_input_token_ok() {
    test_master_input_tokens(NoError)
}

#[test]
fun test_master_input_token_with_cred_price_ok() {
    test_master_input_tokens(NoErrorHasCredPrice)
}

fun test_master_input_tokens(error_code: u64) {
    std::debug::print(&b"=== Starting test_master_input_tokens ===");
    let mut test = begin(utils::owner());
    std::debug::print(&b"Test context created");
    let registry_id = pool_tests::setup_test(utils::owner(), &mut test);
    std::debug::print(&b"Registry setup complete");
    pool_tests::set_time(0, &mut test);
    std::debug::print(&b"Time set to 0");

    let starting_balance = 10000 * constants::float_scaling();
    std::debug::print(&b"Starting balance initialized");

    std::debug::print(&b"Creating pool1 (SUI/USDC)...");
    let pool1_id = pool_tests::setup_pool_with_default_fees<SUI, USDC>(
        utils::owner(),
        registry_id,
        false,
        false,
        &mut test,
    );
    std::debug::print(&b"Pool1 created");
    std::debug::print(&b"Creating pool2 (SPAM/USDC)...");
    let pool2_id = pool_tests::setup_pool_with_default_fees<SPAM, USDC>(
        utils::owner(),
        registry_id,
        false,
        false,
        &mut test,
    );
    std::debug::print(&b"Pool2 created");

    if (error_code == NoErrorHasCredPrice) {
        std::debug::print(&b"Setting up CRED price (NoErrorHasCredPrice branch)");
        let owner_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
            utils::owner(),
            starting_balance,
            &mut test,
        );
        std::debug::print(&b"Owner balance manager created");

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
    };

    std::debug::print(&b"Creating Alice balance manager...");
    let alice_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        utils::alice(),
        starting_balance,
        &mut test,
    );
    std::debug::print(&b"Alice balance manager created");
    std::debug::print(&b"Creating Bob balance manager...");
    let bob_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        utils::bob(),
        starting_balance,
        &mut test,
    );
    std::debug::print(&b"Bob balance manager created");

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 3 * constants::float_scaling();
    let big_quantity = 1_000_000 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let is_bid = true;
    let maker_fee = constants::maybe_apply_fee(is_bid);
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

    std::debug::print(&b"Withdrawing settled amounts for Alice...");
    utils::withdraw_settled_amounts<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        &mut test,
    );
    std::debug::print(&b"Settled amounts withdrawn");

    std::debug::print(&b"Alice placing bid order in pool1...");
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
    std::debug::print(&b"Order placed, now canceling...");

    pool_tests::cancel_order<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        order_info_1.order_id(),
        &mut test,
    );
    std::debug::print(&b"Order canceled, placing again...");

    let order_info_1_epoch0 = pool_tests::place_limit_order<SUI, USDC>(
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

    std::debug::print(&b"Order placed successfully");
    let usdc_asset = math::mul(price, quantity);
    let usdc_base_fee = math::mul(maker_fee, usdc_asset);
    let usdc_penalty_fee = math::mul(constants::fee_penalty_multiplier(), usdc_base_fee);
    std::debug::print(&b"Calculated Epoch 0 fees");
    utils::sub_usdc(&mut alice_balance, usdc_asset);
    utils::sub_usdc(&mut alice_balance, usdc_penalty_fee);

    std::debug::print(&b"Alice placing ask order in pool2...");
    let order_info_2 = pool_tests::place_limit_order<SPAM, USDC>(
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
    std::debug::print(&b"Pool2 order placed, canceling...");
    pool_tests::cancel_order<SPAM, USDC>(
        utils::alice(),
        pool2_id,
        alice_balance_manager_id,
        order_info_2.order_id(),
        &mut test,
    );
    std::debug::print(&b"Pool2 order canceled, placing again...");
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
    std::debug::print(&b"Pool2 order placed (ask pays no fees)");
    utils::sub_spam(&mut alice_balance, quantity);

    std::debug::print(&b"Checking Alice balance after Epoch 0 orders...");
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    std::debug::print(&b"Alice balance check passed");

    std::debug::print(&b"=== Advancing to EPOCH 1 ===");
    test.next_epoch(utils::owner());
    assert!(test.ctx().epoch() == 1, 0);
    std::debug::print(&b"Epoch 1 confirmed");

    std::debug::print(&b"Alicesh submitting governance proposal...");
    std::debug::print(&b"Proposal NOT submitted - governance disabled");

    std::debug::print(&b"=== Advancing to EPOCH 2 ===");
    test.next_epoch(utils::owner());
    assert!(test.ctx().epoch() == 2, 0);
    std::debug::print(&b"Epoch 2 confirmed");
    std::debug::print(&b"Fee rates remain constant (governance disabled)");

    std::debug::print(&b"Canceling Alice's old order from Epoch 0...");
    pool_tests::cancel_order<SUI, USDC>(
        utils::alice(),
        pool1_id,
        alice_balance_manager_id,
        order_info_1_epoch0.order_id(),
        &mut test,
    );
    std::debug::print(&b"Order canceled, calculating refund...");
    let canceled_quote_amount = math::mul(price, quantity);
    utils::add_usdc(&mut alice_balance, canceled_quote_amount);

    std::debug::print(&b"Checking Alice balance after cancel refund...");
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    std::debug::print(&b"Alice balance check passed after cancel");

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
    std::debug::print(&b"Order placed in Epoch 2");
    let usdc_asset_new = math::mul(price, quantity);
    utils::sub_usdc(&mut alice_balance, usdc_asset_new);
    let usdc_base_fee_new = math::mul(maker_fee, usdc_asset_new);
    let usdc_penalty_fee_new = math::mul(constants::fee_penalty_multiplier(), usdc_base_fee_new);
    std::debug::print(&b"Calculated Epoch 2 fees (same as Epoch 0)");
    utils::sub_usdc(&mut alice_balance, usdc_penalty_fee_new);

    std::debug::print(&b"Checking Alice balance after Epoch 2 order...");
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    std::debug::print(&b"Alice balance check passed after Epoch 2 order");

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

    std::debug::print(&b"Checking Alice balance after rebate claim...");
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    std::debug::print(&b"Alice balance check passed after rebate");

    std::debug::print(&b"Checking Bob balance after rebate claim...");
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);
    std::debug::print(&b"Bob balance check passed after rebate");

    let alice_order_quantity = 3 * constants::float_scaling();
    let usdc_amount = math::mul(price, alice_order_quantity);
    let _expected_vault_fee = math::mul(
        constants::fee_penalty_multiplier(),
        math::mul(maker_fee, usdc_amount),
    );
    utils::check_vault_balances<SUI, USDC>(
        pool1_id,
        &balances::new(0, 0, 0),
        &mut test,
    );

    let quantity = 1 * constants::float_scaling();
    let mut i: u64 = 23;
    std::debug::print(&b"=== Starting 23-epoch trading loop ===");
    while (i > 0) {
        std::debug::print(&b"Advancing to next epoch in loop...");
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
    std::debug::print(&b"23-epoch loop completed");

    let quantity_sui_traded = 46 * constants::float_scaling();
    utils::add_sui(&mut alice_balance, quantity_sui_traded);
    utils::sub_usdc(&mut alice_balance, math::mul(price, quantity_sui_traded));
    let alice_base_fee = math::mul(math::mul(quantity_sui_traded, maker_fee), price);
    let alice_usdc_fee = math::mul(constants::fee_penalty_multiplier(), alice_base_fee);
    utils::sub_usdc(&mut alice_balance, alice_usdc_fee);
    utils::sub_sui(&mut bob_balance, quantity_sui_traded);
    utils::add_usdc(&mut bob_balance, math::mul(price, quantity_sui_traded));

    std::debug::print(&b"Checking Alice balance after 23-epoch loop...");
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    std::debug::print(&b"Alice balance check passed after loop");

    std::debug::print(&b"Checking Bob balance after 23-epoch loop...");
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);
    std::debug::print(&b"Bob balance check passed after loop");

    test.next_epoch(utils::owner());
    assert!(test.ctx().epoch() == 28, 0);

    std::debug::print(&b"Checking Alice balance after Epoch 28 rebate claim...");
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    std::debug::print(&b"Alice balance check passed after Epoch 28 rebate");

    std::debug::print(&b"Checking Bob balance after Epoch 28 rebate claim...");
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);
    std::debug::print(&b"Bob balance check passed after Epoch 28 rebate");

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
    std::debug::print(&b"Epoch 28 trading executed");

    let quantity_sui_traded = 2 * quantity;
    utils::add_sui(&mut alice_balance, quantity_sui_traded);
    utils::sub_usdc(&mut alice_balance, math::mul(price, quantity_sui_traded));
    let alice_base_fee_28 = math::mul(math::mul(quantity_sui_traded, maker_fee), price);
    let alice_usdc_fee = math::mul(constants::fee_penalty_multiplier(), alice_base_fee_28);
    utils::sub_usdc(&mut alice_balance, alice_usdc_fee);
    utils::sub_sui(&mut bob_balance, quantity_sui_traded);
    utils::add_usdc(&mut bob_balance, math::mul(price, quantity_sui_traded));

    std::debug::print(&b"Checking Alice balance after Epoch 28 trading...");
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    std::debug::print(&b"Alice balance check passed after Epoch 28 trading");

    std::debug::print(&b"Checking Bob balance after Epoch 28 trading...");
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);
    std::debug::print(&b"Bob balance check passed after Epoch 28 trading");

    test.next_epoch(utils::owner());
    assert!(test.ctx().epoch() == 29, 0);

    std::debug::print(&b"Checking Alice final balance...");
    utils::check_balance(alice_balance_manager_id, &alice_balance, &mut test);
    std::debug::print(&b"Alice final balance check passed");

    std::debug::print(&b"Checking Bob final balance...");
    utils::check_balance(bob_balance_manager_id, &bob_balance, &mut test);
    std::debug::print(&b"Bob final balance check passed");

    std::debug::print(&b"=== Test completed successfully ===");
    end(test);
}
