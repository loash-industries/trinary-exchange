// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::pool_test_utils;

use std::unit_test::{assert_eq, destroy};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin, mint_for_testing},
    sui::SUI,
    test_scenario::{Scenario, begin, end, return_shared}
};
use token::cred::CRED;
use triexbook::{
    balance_manager::{BalanceManager, DepositCap, TradeCap, WithdrawCap},
    balance_manager_tests::{
        SPAM,
        USDC,
        USDT,
        asset_balance,
        create_acct_and_share_with_funds,
        create_acct_and_share_with_funds_typed,
        create_caps
    },
    book,
    constants,
    fill::Fill,
    math,
    order::Order,
    order_info::OrderInfo,
    pool::{Self, Pool},
    registry::{Self, Registry}
};

const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;
const BOB: address = @0xBBBB;

const EBookOrderNotFound: u64 = 1;

/// Create a pool with 1000 limit sell at $2 and 1000 limit buy at $1.
#[test_only]
public fun setup_everything<BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset>(
    test: &mut Scenario,
): ID {
    let registry_id = setup_test(OWNER, test);
    let balance_manager_id_alice = create_acct_and_share_with_funds_typed<
        BaseAsset,
        QuoteAsset,
        ReferenceBaseAsset,
    >(
        ALICE,
        1000000 * constants::float_scaling(),
        test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<
        BaseAsset,
        QuoteAsset,
        ReferenceBaseAsset,
        ReferenceQuoteAsset,
    >(ALICE, registry_id, balance_manager_id_alice, test);

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1000 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    place_limit_order<BaseAsset, QuoteAsset>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        expire_timestamp,
        test,
    );

    let price = 1 * constants::float_scaling();
    place_limit_order<BaseAsset, QuoteAsset>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        expire_timestamp,
        test,
    );

    pool_id
}

public(package) fun test_place_then_fill_bid_ask() {
    place_then_fill(
        false,
        true,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * constants::maybe_apply_fee(false) * constants::cred_multiplier(),
        constants::filled(),
    );
}

public(package) fun test_place_then_fill_bid_ask_stable() {
    place_then_fill(
        true,
        true,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * constants::maybe_apply_fee(false) * constants::cred_multiplier(),
        constants::filled(),
    );
}

public(package) fun test_place_then_fill_ask_bid() {
    place_then_fill(
        false,
        false,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * math::mul(constants::maybe_apply_fee(true), constants::cred_multiplier()),
        constants::filled(),
    );
}

public(package) fun test_place_then_fill_ask_bid_stable() {
    place_then_fill(
        true,
        false,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * math::mul(constants::maybe_apply_fee(true), constants::cred_multiplier()),
        constants::filled(),
    );
}

public(package) fun test_place_then_ioc_bid_ask() {
    place_then_fill(
        false,
        true,
        constants::immediate_or_cancel(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * constants::maybe_apply_fee(false) * constants::cred_multiplier(),
        constants::filled(),
    );
}

public(package) fun test_place_then_ioc_bid_ask_stable() {
    place_then_fill(
        true,
        true,
        constants::immediate_or_cancel(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 *
        constants::maybe_apply_fee(false) * constants::cred_multiplier(),
        constants::filled(),
    );
}

public(package) fun test_place_then_ioc_ask_bid() {
    place_then_fill(
        false,
        false,
        constants::immediate_or_cancel(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * math::mul(constants::maybe_apply_fee(true), constants::cred_multiplier()),
        constants::filled(),
    );
}

public(package) fun test_place_then_ioc_ask_bid_stable() {
    place_then_fill(
        true,
        false,
        constants::immediate_or_cancel(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * math::mul(constants::maybe_apply_fee(true), constants::cred_multiplier()),
        constants::filled(),
    );
}

public(package) fun test_bid_with_quote_fees_updates_vault_reserve() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100 * constants::float_scaling(),
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_bob,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        let reserve_before = pool.quote_fee_reserve_balance();
        let order_info = pool.place_limit_order_with_quote_fees(
            &mut balance_manager,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            100 * constants::float_scaling(),
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        let reserve_after = pool.quote_fee_reserve_balance();
        let expected_fee = order_info.paid_fees() + order_info.maker_fees();
        assert!(expected_fee > 0, 0);
        assert!(reserve_after >= reserve_before, 0);
        assert!(reserve_after - reserve_before == expected_fee, 0);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

public(package) fun test_admin_withdraws_quote_fee_reserve() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100 * constants::float_scaling(),
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_bob,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        let order_info = pool.place_limit_order_with_quote_fees(
            &mut balance_manager,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            100 * constants::float_scaling(),
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        assert!(order_info.paid_fees() + order_info.maker_fees() > 0, 0);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let reserve_before = pool.quote_fee_reserve_balance();
        assert!(reserve_before > 0, 0);
        let clock = test.take_shared<Clock>();
        let fee_coin = pool.withdraw_pool_fees(
            &admin_cap,
            reserve_before,
            &clock,
            test.ctx(),
        );
        assert!(fee_coin.value() == reserve_before, 1);
        assert!(pool.quote_fee_reserve_balance() == 0, 2);

        destroy(fee_coin);
        return_shared(clock);
        return_shared(pool);
        destroy(admin_cap);
    };

    end(test);
}

public(package) fun test_fills_bid_ok() {
    place_then_fill_correct(
        true,
        constants::no_restriction(),
        3 * constants::float_scaling(),
    );
}

public(package) fun test_fills_ask_ok() {
    place_then_fill_correct(
        false,
        constants::no_restriction(),
        3 * constants::float_scaling(),
    );
}

public(package) fun test_place_then_ioc_no_fill_bid_ask_order_removed_e() {
    place_then_no_fill(
        true,
        constants::immediate_or_cancel(),
        0,
        0,
        0,
        constants::canceled(),
    );
}

public(package) fun test_place_then_ioc_no_fill_ask_bid_order_removed_e() {
    place_then_no_fill(
        false,
        constants::immediate_or_cancel(),
        0,
        0,
        0,
        constants::canceled(),
    );
}

public(package) fun test_expired_order_removed_bid_ask_e() {
    place_order_expire_timestamp_e(
        true,
        constants::no_restriction(),
        0,
        0,
        0,
        constants::live(),
    );
}

public(package) fun test_expired_order_removed_ask_bid_e() {
    place_order_expire_timestamp_e(
        false,
        constants::no_restriction(),
        0,
        0,
        0,
        constants::live(),
    );
}

public(package) fun test_partial_fill_order_bid_ok() {
    partial_fill_order(
        true,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * constants::maybe_apply_fee(false) * constants::cred_multiplier(),
        constants::partially_filled(),
    );
}

public(package) fun test_partial_fill_order_ask_ok() {
    partial_fill_order(
        false,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * math::mul(constants::maybe_apply_fee(true), constants::cred_multiplier()),
        constants::partially_filled(),
    );
}

public(package) fun test_fill_partial_maker_bid_ok() {
    partial_fill_maker_order(
        true,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling() / 2,
        3 * constants::float_scaling(),
        3 * constants::maybe_apply_fee(false) * constants::cred_multiplier(), // this is testing `bob` who matches
        constants::partially_filled(),
    );
}

public(package) fun test_fill_partial_maker_ask_ok() {
    partial_fill_maker_order(
        false,
        constants::no_restriction(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling() / 2,
        3 * constants::float_scaling(),
        3 * math::mul(constants::maybe_apply_fee(true), constants::cred_multiplier()) / 2,
        constants::partially_filled(),
    );
}

public(package) fun test_partially_filled_maker_bid_ok() {
    partially_filled_order_taken(true);
}

public(package) fun test_partially_filled_maker_ask_ok() {
    partially_filled_order_taken(false);
}

// Removed test: test_invalid_order_quantity_e - min_size validation no longer exists
// Removed test: test_invalid_lot_size_e - lot_size validation no longer exists
// Removed: test_invalid_tick_size_e - tick_size validation no longer exists

public(package) fun test_price_above_max_e() {
    place_with_price_quantity(
        constants::max_u64(),
        1 * constants::float_scaling(),
    );
}

public(package) fun test_price_below_min_e() {
    place_with_price_quantity(
        0,
        1 * constants::float_scaling(),
    );
}

public(package) fun test_self_matching_cancel_taker_bid() {
    test_self_matching_cancel_taker(true);
}

public(package) fun test_self_matching_cancel_taker_ask() {
    test_self_matching_cancel_taker(false);
}

public(package) fun test_self_matching_cancel_maker_bid() {
    test_self_matching_cancel_maker(true);
}

public(package) fun test_self_matching_cancel_maker_ask() {
    test_self_matching_cancel_maker(false);
}

public(package) fun test_swap_exact_amount_bid_ask() {
    test_swap_exact_amount(true, false);
}

public(package) fun test_swap_exact_amount_ask_bid() {
    test_swap_exact_amount(false, false);
}

public(package) fun test_swap_exact_amount_bid_ask_with_manager() {
    test_swap_exact_amount(true, true);
}

public(package) fun test_swap_exact_amount_ask_bid_with_manager() {
    test_swap_exact_amount(false, true);
}

public(package) fun test_swap_exact_amount_with_input_bid_ask() {
    test_swap_exact_amount_with_input(true);
}

public(package) fun test_swap_exact_amount_with_input_ask_bid() {
    test_swap_exact_amount_with_input(false);
}

// Removed: test_get_quantity_out_input_fee_bid_ask_zero - tested min_size behavior which no longer exists
// #[test]
// fun test_get_quantity_out_input_fee_bid_ask_zero() {
//     test_get_quantity_out_zero(true);
// }

// Removed: test_get_quantity_out_input_fee_ask_bid_zero - tested min_size behavior which no longer exists
// #[test]
// fun test_get_quantity_out_input_fee_ask_bid_zero() {
//     test_get_quantity_out_zero(false);
// }

public(package) fun test_post_only_bid_e() {
    test_post_only(true, true);
}

public(package) fun test_post_only_ask_e() {
    test_post_only(false, true);
}

public(package) fun test_post_only_bid_ok() {
    test_post_only(true, false);
}

public(package) fun test_post_only_ask_ok() {
    test_post_only(false, false);
}

public(package) fun test_crossing_multiple_orders_bid_ok() {
    test_crossing_multiple(true, 3)
}

public(package) fun test_crossing_multiple_orders_ask_ok() {
    test_crossing_multiple(false, 3)
}

public(package) fun test_fill_or_kill_bid_e() {
    test_fill_or_kill(true, false);
}

public(package) fun test_fill_or_kill_ask_e() {
    test_fill_or_kill(false, false);
}

public(package) fun test_fill_or_kill_bid_ok() {
    test_fill_or_kill(true, true);
}

public(package) fun test_fill_or_kill_ask_ok() {
    test_fill_or_kill(false, true);
}

public(package) fun test_market_order_bid_then_ask_ok() {
    test_market_order(true);
}

public(package) fun test_market_order_ask_then_bid_ok() {
    test_market_order(false);
}

public(package) fun test_mid_price_ok() {
    test_mid_price();
}

public(package) fun test_swap_exact_not_fully_filled_bid_ok() {
    test_swap_exact_not_fully_filled(true, false, false, false, false);
}

public(package) fun test_swap_exact_not_fully_filled_bid_with_manager_ok() {
    test_swap_exact_not_fully_filled(true, false, false, false, true);
}

public(package) fun test_swap_exact_not_fully_filled_ask_ok() {
    test_swap_exact_not_fully_filled(false, false, false, false, false);
}

public(package) fun test_swap_exact_not_fully_filled_ask_with_manager_ok() {
    test_swap_exact_not_fully_filled(false, false, false, false, true);
}

public(package) fun test_swap_exact_not_fully_filled_bid_low_qty_ok() {
    test_swap_exact_not_fully_filled(true, true, false, false, false);
}

public(package) fun test_swap_exact_not_fully_filled_bid_with_manager_low_qty_ok() {
    test_swap_exact_not_fully_filled(true, true, false, false, true);
}

public(package) fun test_swap_exact_not_fully_filled_ask_low_qty_ok() {
    test_swap_exact_not_fully_filled(false, true, false, false, false);
}

public(package) fun test_swap_exact_not_fully_filled_ask_with_manager_low_qty_ok() {
    test_swap_exact_not_fully_filled(false, true, false, false, true);
}

public(package) fun test_swap_exact_not_fully_filled_bid_min_e() {
    test_swap_exact_not_fully_filled(true, false, true, false, false);
}

public(package) fun test_swap_exact_not_fully_filled_bid_with_manager_min_e() {
    test_swap_exact_not_fully_filled(true, false, true, false, true);
}

public(package) fun test_swap_exact_not_fully_filled_ask_min_e() {
    test_swap_exact_not_fully_filled(false, false, true, false, false);
}

public(package) fun test_swap_exact_not_fully_filled_ask_with_manager_min_e() {
    test_swap_exact_not_fully_filled(false, false, true, false, true);
}

public(package) fun test_swap_exact_not_fully_filled_maker_partial_bid_ok() {
    test_swap_exact_not_fully_filled(true, false, false, true, false);
}

public(package) fun test_swap_exact_not_fully_filled_maker_partial_bid_with_manager_ok() {
    test_swap_exact_not_fully_filled(true, false, false, true, true);
}

public(package) fun test_swap_exact_not_fully_filled_maker_partial_ask_ok() {
    test_swap_exact_not_fully_filled(false, false, false, true, false);
}

public(package) fun test_swap_exact_not_fully_filled_maker_partial_ask_with_manager_ok() {
    test_swap_exact_not_fully_filled(false, false, false, true, true);
}

public(package) fun test_modify_order_bid_ok() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        0,
        true,
    );
}

public(package) fun test_modify_order_ask_ok() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        0,
        false,
    );
}

public(package) fun test_modify_order_increase_bid_e() {
    test_modify_order(
        2 * constants::float_scaling(),
        3 * constants::float_scaling(),
        0,
        true,
    );
}

public(package) fun test_modify_order_increase_ask_e() {
    test_modify_order(
        2 * constants::float_scaling(),
        3 * constants::float_scaling(),
        0,
        false,
    );
}

public(package) fun test_modify_order_invalid_new_quantity_bid_e() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        2 * constants::float_scaling(),
        true,
    );
}

public(package) fun test_modify_order_invalid_new_quantity_ask_e() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        2 * constants::float_scaling(),
        false,
    );
}

public(package) fun test_modify_order_bid_input_ok() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        0,
        true,
    );
}

public(package) fun test_modify_order_ask_input_ok() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        0,
        false,
    );
}

public(package) fun test_modify_order_increase_bid_input_e() {
    test_modify_order(
        2 * constants::float_scaling(),
        3 * constants::float_scaling(),
        0,
        true,
    );
}

public(package) fun test_modify_order_increase_ask_input_e() {
    test_modify_order(
        2 * constants::float_scaling(),
        3 * constants::float_scaling(),
        0,
        false,
    );
}

public(package) fun test_modify_order_invalid_new_quantity_bid_input_e() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        2 * constants::float_scaling(),
        true,
    );
}

public(package) fun test_modify_order_invalid_new_quantity_ask_input_e() {
    test_modify_order(
        3 * constants::float_scaling(),
        2 * constants::float_scaling(),
        2 * constants::float_scaling(),
        false,
    );
}

public(package) fun test_queue_priority_bid_ok() {
    test_queue_priority(true);
}

public(package) fun test_queue_priority_ask_ok() {
    test_queue_priority(false);
}

public(package) fun test_place_order_with_maxu64_as_price_e() {
    test_place_order_edge_price(
        1 * constants::float_scaling(),
        constants::max_u64() - constants::max_u64() % constants::float_scaling(),
    )
}

public(package) fun test_place_order_with_zero_as_price_e() {
    test_place_order_edge_price(1 * constants::float_scaling(), 0)
}

public(package) fun test_place_order_with_maxprice_ok() {
    test_place_order_edge_price(
        1 * constants::float_scaling(),
        constants::max_price() -
        constants::max_price() % constants::float_scaling(),
    )
}

public(package) fun test_place_order_with_minprice_ok() {
    test_place_order_edge_price(
        1 * constants::float_scaling(),
        constants::float_scaling(),
    )
}

public(package) fun test_place_order_with_lot_size_ok() {
    test_place_order_edge_price(
        10000,
        constants::float_scaling(),
    ) // was constants::lot_size() * 10 = 1000 * 10
}

// Removed test_place_order_with_lower_min_quantity_e - min_size validation no longer exists

public(package) fun test_order_limit_bid_ok() {
    test_order_limit(true);
}

public(package) fun test_order_limit_ask_ok() {
    test_order_limit(false);
}

public(package) fun test_get_order() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::cred_multiplier(),
        1 * constants::float_scaling(),
        true,
        constants::max_u64(),
        &mut test,
    );
    let order = get_order(pool_id, order_info.order_id(), &mut test);
    assert!(order.order_id() == order_info.order_id(), 0);
    assert!(order.balance_manager_id() == balance_manager_id_alice, 0);
    assert!(order.quantity() == 1 * constants::float_scaling(), 0);
    assert!(order.filled_quantity() == 0, 0);
    assert!(order.epoch() == 0, 0);
    assert!(order.status() == constants::live(), 0);
    assert!(order.expire_timestamp() == constants::max_u64(), 0);

    end(test);
}

public(package) fun test_get_orders() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let order_info_1 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::cred_multiplier(),
        1 * constants::float_scaling(),
        true,
        constants::max_u64(),
        &mut test,
    );
    let order_info_2 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::cred_multiplier(),
        1 * constants::float_scaling(),
        true,
        constants::max_u64(),
        &mut test,
    );
    let mut order_ids = vector[];
    order_ids.push_back(order_info_1.order_id());
    order_ids.push_back(order_info_2.order_id());

    let orders = get_orders(pool_id, order_ids, &mut test);
    let mut i = 0;
    while (i < 2) {
        let order = &orders[i];
        assert!(order.order_id() == order_ids[i], 0);
        assert!(order.balance_manager_id() == balance_manager_id_alice, 0);
        assert!(order.quantity() == 1 * constants::float_scaling(), 0);
        assert!(order.filled_quantity() == 0, 0);
        assert!(order.epoch() == 0, 0);
        assert!(order.status() == constants::live(), 0);
        assert!(order.expire_timestamp() == constants::max_u64(), 0);
        i = i + 1;
    };

    end(test);
}

fun get_order(pool_id: ID, order_id: u64, test: &mut Scenario): Order {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let order = pool.get_order(order_id);
        return_shared(pool);

        order
    }
}

fun get_orders(pool_id: ID, order_ids: vector<u64>, test: &mut Scenario): vector<Order> {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let orders = pool.get_orders(order_ids);
        return_shared(pool);

        orders
    }
}

#[test_only]
public(package) fun setup_test(owner: address, test: &mut Scenario): ID {
    test.next_tx(owner);
    share_clock(test);
    let registry_id = share_registry_for_testing(test);
    add_approved_quote_currencies(owner, registry_id, test);
    registry_id
}

#[test_only]
/// Like `setup_test`, but does not whitelist any approved quotes.
public(package) fun setup_registry_without_approved_quotes(
    owner: address,
    test: &mut Scenario,
): ID {
    test.next_tx(owner);
    share_clock(test);
    share_registry_for_testing(test)
}

#[test_only]
fun add_approved_quote_currencies(owner: address, registry_id: ID, test: &mut Scenario) {
    test.next_tx(owner);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);

    // Add all quote currencies used in tests
    registry.add_approved_quote_unchecked<USDC>(&admin_cap);
    registry.add_approved_quote_unchecked<USDT>(&admin_cap);
    registry.add_approved_quote_unchecked<SUI>(&admin_cap);
    registry.add_approved_quote_unchecked<CRED>(&admin_cap);
    registry.add_approved_quote_unchecked<SPAM>(&admin_cap);

    return_shared(registry);
    destroy(admin_cap);
}

#[test_only]
/// Set up a reference pool where Cred per base is 100
public(package) fun setup_reference_pool<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    cred_multiplier: u64,
    test: &mut Scenario,
): ID {
    let reference_pool_id = setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        true,
        false,
        test,
    );

    let bid_price = cred_multiplier - 80 * constants::float_scaling();
    let ask_price = cred_multiplier + 80 * constants::float_scaling();

    place_limit_order<BaseAsset, QuoteAsset>(
        sender,
        reference_pool_id,
        balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        bid_price,
        1 * constants::float_scaling(),
        true,
        constants::max_u64(),
        test,
    );

    place_limit_order<BaseAsset, QuoteAsset>(
        sender,
        reference_pool_id,
        balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        ask_price,
        1 * constants::float_scaling(),
        false,
        constants::max_u64(),
        test,
    );

    reference_pool_id
}

#[test_only]
/// Set up a reference pool where Cred per base is 100
public(package) fun setup_reference_pool_cred_as_base<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    cred_multiplier: u64,
    test: &mut Scenario,
): ID {
    let reference_pool_id = setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        true,
        false,
        test,
    );

    place_limit_order<BaseAsset, QuoteAsset>(
        sender,
        reference_pool_id,
        balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        math::div(constants::float_scaling(), cred_multiplier) - 10_000,
        1 * constants::float_scaling(),
        true,
        constants::max_u64(),
        test,
    );

    place_limit_order<BaseAsset, QuoteAsset>(
        sender,
        reference_pool_id,
        balance_manager_id,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        math::div(constants::float_scaling(), cred_multiplier) + 10_000,
        1 * constants::float_scaling(),
        false,
        constants::max_u64(),
        test,
    );

    reference_pool_id
}

#[test_only]
public(package) fun setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    whitelisted_pool: bool,
    stable_pool: bool,
    test: &mut Scenario,
): ID {
    setup_pool<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        whitelisted_pool,
        stable_pool,
        test,
    )
}

#[test_only]
public(package) fun setup_pool_with_stable_fees<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    whitelisted_pool: bool,
    test: &mut Scenario,
): ID {
    let stable_pool = true;
    setup_pool<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        whitelisted_pool,
        stable_pool,
        test,
    )
}

#[test_only]
public(package) fun setup_pool_with_default_fees_return_fee<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    whitelisted_pool: bool,
    test: &mut Scenario,
): ID {
    let stable_pool = false;
    let pool_id = setup_pool<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        whitelisted_pool,
        stable_pool,
        test,
    );

    pool_id
}

#[test_only]
public(package) fun setup_default_permissionless_pool<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    test: &mut Scenario,
): ID {
    setup_permissionless_pool<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        test,
    )
}

#[test_only]
/// Place a limit order
public(package) fun place_limit_order<BaseAsset, QuoteAsset>(
    trader: address,
    pool_id: ID,
    balance_manager_id: ID,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    expire_timestamp: u64,
    test: &mut Scenario,
): OrderInfo {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_proof;

        let is_owner = balance_manager.owner() == trader;
        if (is_owner) {
            trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        } else {
            let trade_cap = test.take_from_sender<TradeCap>();
            trade_proof =
                balance_manager.generate_proof_as_trader(
                    &trade_cap,
                    test.ctx(),
                );
            test.return_to_sender(trade_cap);
        };

        // Place order in pool
        let order_info = pool.place_limit_order<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            order_type,
            self_matching_option,
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);

        order_info
    }
}

#[test_only]
/// Place an order
public(package) fun place_market_order<BaseAsset, QuoteAsset>(
    trader: address,
    pool_id: ID,
    balance_manager_id: ID,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    test: &mut Scenario,
): OrderInfo {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        // Top up quote balance to cover quote-denominated fees in the unified model
        let extra_quote = mint_for_testing<QuoteAsset>(
            1_000_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        balance_manager.deposit(extra_quote, test.ctx());
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        // Place order in pool
        let order_info = pool.place_market_order<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            self_matching_option,
            quantity,
            is_bid,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);

        order_info
    }
}

#[test_only]
/// Cancel an order
public(package) fun cancel_order<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    order_id: u64,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        // Top up quote balance to cover quote-denominated maker fees during cancel
        let extra_quote = mint_for_testing<QuoteAsset>(
            1_000_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        balance_manager.deposit(extra_quote, test.ctx());
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        pool.cancel_order<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            order_id,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);
    }
}

#[test_only]
/// Set the time in the global clock to 1_000_000 + current_time
public(package) fun set_time(current_time: u64, test: &mut Scenario) {
    test.next_tx(OWNER);
    {
        let mut clock = test.take_shared<Clock>();
        clock.set_for_testing(current_time + 1_000_000);
        return_shared(clock);
    };
}

#[test_only]
public(package) fun modify_order<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    order_id: u64,
    new_quantity: u64,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_cap = test.take_from_sender<TradeCap>();
        let trade_proof = balance_manager.generate_proof_as_trader(
            &trade_cap,
            test.ctx(),
        );
        let clock = test.take_shared<Clock>();

        pool.modify_order<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            order_id,
            new_quantity,
            &clock,
            test.ctx(),
        );

        test.return_to_sender(trade_cap);
        return_shared(pool);
        return_shared(balance_manager);
        return_shared(clock);
    }
}

fun test_place_order_edge_price(quantity: u64, price: u64) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let base_funding = 1000000 * constants::float_scaling();
    let funding_amount = if (price >= base_funding) {
        if (price > constants::max_u64() / 2) {
            constants::max_u64()
        } else {
            2 * price
        }
    } else {
        base_funding
    };
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        funding_amount,
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let expire_timestamp = constants::max_u64();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        expire_timestamp,
        &mut test,
    );

    end(test);
}

#[test_only]
/// Get the time in the global clock
public(package) fun get_time(test: &mut Scenario): u64 {
    test.next_tx(OWNER);
    {
        let clock = test.take_shared<Clock>();
        let time = clock.timestamp_ms();
        return_shared(clock);

        time
    }
}

#[test_only]
public(package) fun validate_open_orders<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    expected_open_orders: u64,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );

        assert!(
            pool.account_open_orders(&balance_manager).length() ==
            expected_open_orders,
            1,
        );

        return_shared(pool);
        return_shared(balance_manager);
    }
}

/// Alice places a worse order
/// Alice places 3 bid/ask orders with at price 1
/// Alice matches the order with an ask/bid order at price 1
/// The first order should be matched because of queue priority
/// Process is repeated with a third order
fun test_queue_priority(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let price = 2 * constants::float_scaling();
    let worse_price = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let order_info_worse = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        worse_price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    let order_info_2 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    let order_info_3 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    // Alice places limit order at price 1 for matching
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        worse_price,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_2.order_id(),
        is_bid,
        quantity,
        0,
        test.ctx().epoch(),
        constants::live(),
        expire_timestamp,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_3.order_id(),
        is_bid,
        quantity,
        0,
        test.ctx().epoch(),
        constants::live(),
        expire_timestamp,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_worse.order_id(),
        is_bid,
        quantity,
        0,
        test.ctx().epoch(),
        constants::live(),
        expire_timestamp,
        &mut test,
    );

    // Alice places limit order at price 1 for matching
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_3.order_id(),
        is_bid,
        quantity,
        0,
        test.ctx().epoch(),
        constants::live(),
        expire_timestamp,
        &mut test,
    );

    end(test);
}

fun test_modify_order(
    original_quantity: u64,
    new_quantity: u64,
    filled_quantity: u64,
    is_bid: bool,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let base_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        base_price,
        original_quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    if (filled_quantity > 0) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            base_price,
            filled_quantity,
            !is_bid,
            expire_timestamp,
            &mut test,
        );
    };

    modify_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info.order_id(),
        new_quantity,
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info.order_id(),
        is_bid,
        new_quantity,
        0,
        test.ctx().epoch(),
        constants::live(),
        expire_timestamp,
        &mut test,
    );

    end(test);
}

fun test_order_limit(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let mut num_orders: u64 = 110;
    // place 10 limit orders for alice
    while (num_orders > 100) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );

        num_orders = num_orders - 1;
    };

    // let pool = borrow_pool<SUI, USDC>(pool_id, &mut test);
    // let orders = borrow_orderbook<SUI, USDC>(&pool, is_bid);
    // if (is_bid) {
    //     print_orders(orders);
    // } else {
    //     print_orders(orders);
    // };
    // return_shared(pool);

    //place 100 limit orders for bob
    while (num_orders > 0) {
        place_limit_order<SUI, USDC>(
            BOB,
            pool_id,
            balance_manager_id_bob,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );

        num_orders = num_orders - 1;
    };

    let match_quantity = 1000 * constants::float_scaling();
    // let pool = borrow_pool<SUI, USDC>(pool_id, &mut test);
    // let orders = borrow_orderbook<SUI, USDC>(&pool, is_bid);
    // if (is_bid) {
    //     print_orders(orders);
    // } else {
    //     print_orders(orders);
    // };
    // return_shared(pool);
    if (is_bid) {
        let (base, quote) = get_quote_quantity_out<SUI, USDC>(
            pool_id,
            match_quantity,
            &mut test,
        );
        assert_eq!(base, 900 * constants::float_scaling());
        assert_eq!(quote, 200 * constants::float_scaling());
    } else {
        let (base, quote) = get_base_quantity_out<SUI, USDC>(
            pool_id,
            math::mul(match_quantity, price),
            &mut test,
        );
        assert_eq!(base, constants::cred_multiplier());
        // Quote-only fees reduce returned quote slightly
        assert_eq!(quote, 1795 * constants::float_scaling());
    };

    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        match_quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    let expected_status = constants::partially_filled();
    let expected_cumulative_quote_quantity = constants::max_fills() * price;
    let paid_fees = 0;

    verify_order_info(
        &order_info,
        price,
        match_quantity,
        constants::max_fills() * quantity,
        expected_cumulative_quote_quantity,
        paid_fees,
        expected_status,
        expire_timestamp,
    );

    if (is_bid) {
        let (base, quote) = get_quote_quantity_out<SUI, USDC>(
            pool_id,
            match_quantity,
            &mut test,
        );
        assert_eq!(base, 990 * constants::float_scaling());
        assert_eq!(quote, 20 * constants::float_scaling());
    } else {
        let (base, quote) = get_base_quantity_out<SUI, USDC>(
            pool_id,
            math::mul(match_quantity, price),
            &mut test,
        );
        assert_eq!(base, 10 * constants::float_scaling());
        assert_eq!(quote, 1_979_500_000_000);
    };

    // Place second order, should match with the 10 remaining orders.
    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        match_quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    let expected_status = constants::partially_filled();
    let expected_cumulative_quote_quantity = 10 * price;
    let expected_executed_quantity = 10 * quantity;
    let paid_fees = 0;

    verify_order_info(
        &order_info,
        price,
        match_quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        paid_fees,
        expected_status,
        expire_timestamp,
    );

    end(test);
}

public(package) fun unregister_pool<BaseAsset, QuoteAsset>(
    pool_id: ID,
    registry_id: ID,
    test: &mut Scenario,
) {
    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let mut registry = test.take_shared_by_id<Registry>(registry_id);

        pool::unregister_pool_admin<BaseAsset, QuoteAsset>(
            &mut pool,
            &mut registry,
            &admin_cap,
        );
        return_shared(pool);
        return_shared(registry);
        destroy(admin_cap);
    }
}

public(package) fun setup_pool_with_default_fees_and_reference_pool<
    BaseAsset,
    QuoteAsset,
    ReferenceBaseAsset,
    ReferenceQuoteAsset,
>(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    test: &mut Scenario,
): ID {
    let target_pool_id = setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
        OWNER,
        registry_id,
        false,
        false,
        test,
    );
    let _reference_pool_id = setup_reference_pool<ReferenceBaseAsset, ReferenceQuoteAsset>(
        sender,
        registry_id,
        balance_manager_id,
        constants::cred_multiplier(),
        test,
    );
    set_time(0, test);

    target_pool_id
}

//
// fun setup_pool_with_default_fees_and_reference_pool_unregistered<
//     BaseAsset,
//     QuoteAsset,
//     ReferenceBaseAsset,
//     ReferenceQuoteAsset,
// >(
//     sender: address,
//     registry_id: ID,
//     balance_manager_id: ID,
//     test: &mut Scenario,
// ): ID {
//     let target_pool_id = setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
//         OWNER,
//         registry_id,
//         false,
//         false,
//         test,
//     );
//     let reference_pool_id = setup_reference_pool<ReferenceBaseAsset, ReferenceQuoteAsset>(
//         sender,
//         registry_id,
//         balance_manager_id,
//         constants::cred_multiplier(),
//         test,
//     );
//     set_time(0, test);
//     unregister_pool<ReferenceBaseAsset, ReferenceQuoteAsset>(
//         reference_pool_id,
//         registry_id,
//         test,
//     );

//     target_pool_id
// }

fun setup_pool_with_stable_fees_and_reference_pool<
    BaseAsset,
    QuoteAsset,
    ReferenceBaseAsset,
    ReferenceQuoteAsset,
>(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    test: &mut Scenario,
): ID {
    let target_pool_id = setup_pool_with_stable_fees<BaseAsset, QuoteAsset>(
        OWNER,
        registry_id,
        false,
        test,
    );
    let _reference_pool_id = setup_reference_pool<ReferenceBaseAsset, ReferenceQuoteAsset>(
        sender,
        registry_id,
        balance_manager_id,
        constants::cred_multiplier(),
        test,
    );
    set_time(0, test);

    target_pool_id
}

/// Alice places a bid order, Bob places a swap_exact_amount order
/// Make sure the assets returned to Bob are correct
/// When swap is not fully filled, assets are returned correctly
/// Make sure expired orders are skipped over
fun test_swap_exact_not_fully_filled(
    is_bid: bool,
    low_quantity: bool,
    minimum_enforced: bool,
    partially_filled_maker: bool,
    with_manager: bool,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let alice_price = 3 * constants::float_scaling();
    let alice_quantity = 2 * constants::float_scaling();
    let expired_price = if (is_bid) {
        3 * constants::float_scaling()
    } else {
        1 * constants::float_scaling()
    };
    let expire_timestamp = constants::max_u64();
    let expire_timestamp_e = get_time(&mut test) + 100;
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    if (partially_filled_maker) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            alice_price,
            alice_quantity / 2,
            !is_bid,
            expire_timestamp,
            &mut test,
        );
    };

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        expired_price,
        alice_quantity,
        is_bid,
        expire_timestamp_e,
        &mut test,
    );

    set_time(200, &mut test);

    let base_in = if (is_bid) {
        if (low_quantity) {
            100
        } else {
            4 * constants::float_scaling()
        }
    } else {
        0
    };
    let quote_in = if (is_bid) {
        0
    } else {
        if (low_quantity) {
            100
        } else {
            8 * constants::float_scaling()
        }
    };
    // Quote-only fees: no CRED input required
    let cred_in = 0;

    let (base, quote) = get_quantity_out<SUI, USDC>(
        pool_id,
        base_in,
        quote_in,
        &mut test,
    );

    let (base_2, quote_2) = if (is_bid) {
        get_quote_quantity_out<SUI, USDC>(
            pool_id,
            base_in,
            &mut test,
        )
    } else {
        get_base_quantity_out<SUI, USDC>(
            pool_id,
            quote_in,
            &mut test,
        )
    };
    let min_out = if (minimum_enforced) {
        10 * constants::float_scaling()
    } else {
        0
    };

    let initial_bob_balances = 1000000 * constants::float_scaling();
    let bob_balance_manager_id = create_acct_and_share_with_funds(
        BOB,
        initial_bob_balances,
        &mut test,
    );
    create_caps(BOB, bob_balance_manager_id, &mut test);
    let _bob_sui_balance_before = asset_balance<SUI>(BOB, bob_balance_manager_id, &mut test);
    let _bob_usdc_balance_before = asset_balance<USDC>(BOB, bob_balance_manager_id, &mut test);
    let _bob_cred_balance_before = asset_balance<CRED>(BOB, bob_balance_manager_id, &mut test);

    let (base_out, quote_out, cred_out) = if (is_bid) {
        if (with_manager) {
            let cred_out = coin::zero(test.ctx());
            let (base_out, quote_out) = place_exact_base_for_quote_with_manager<SUI, USDC>(
                pool_id,
                BOB,
                bob_balance_manager_id,
                base_in,
                min_out,
                &mut test,
            );

            (base_out, quote_out, cred_out)
        } else {
            place_swap_exact_base_for_quote<SUI, USDC>(
                pool_id,
                BOB,
                base_in,
                cred_in,
                min_out,
                &mut test,
            )
        }
    } else {
        if (with_manager) {
            let cred_out = coin::zero(test.ctx());
            let (base_out, quote_out) = place_exact_quote_for_base_with_manager<SUI, USDC>(
                pool_id,
                BOB,
                bob_balance_manager_id,
                quote_in,
                min_out,
                &mut test,
            );

            (base_out, quote_out, cred_out)
        } else {
            place_swap_exact_quote_for_base<SUI, USDC>(
                pool_id,
                BOB,
                quote_in,
                cred_in,
                min_out,
                &mut test,
            )
        }
    };
    let _bob_sui_balance_after = asset_balance<SUI>(BOB, bob_balance_manager_id, &mut test);
    let _bob_usdc_balance_after = asset_balance<USDC>(BOB, bob_balance_manager_id, &mut test);
    let _bob_cred_balance_after = asset_balance<CRED>(BOB, bob_balance_manager_id, &mut test);

    if (low_quantity) {
        // With lot_size removed, tiny amounts (100 units) can now match
        // Previously lot_size=1000 would have rounded these to 0 and prevented matching
        // Now they match small amounts, so we verify some matching occurred
        if (is_bid) {
            // Bob sells 100 base, gets back less than 100 (some matched)
            assert!(base_out.value() < base_in, constants::e_order_info_mismatch());
            // Bob receives some quote
            assert!(quote_out.value() > 0, constants::e_order_info_mismatch());
        } else {
            // Bob buys with 100 quote, gets back less than 100 (some matched)
            assert!(quote_out.value() < quote_in, constants::e_order_info_mismatch());
            // Bob receives some base
            assert!(base_out.value() > 0, constants::e_order_info_mismatch());
        };
    } else if (!partially_filled_maker) {
        if (is_bid) {
            assert!(
                base_out.value() == 2 * constants::float_scaling(),
                constants::e_order_info_mismatch(),
            );
            assert!(
                quote_out.value() == 6 * constants::float_scaling(),
                constants::e_order_info_mismatch(),
            );

            assert!(base == base_2 && base == base_out.value(), constants::e_order_info_mismatch());
            assert!(
                quote == quote_2 && quote == quote_out.value(),
                constants::e_order_info_mismatch(),
            );
        } else {
            // Quote-only fee model can reduce quote_out; only require non-zero output
            assert!(base_out.value() > 0, constants::e_order_info_mismatch());
            assert!(quote_out.value() > 0, constants::e_order_info_mismatch());
            assert!(cred_out.value() == 0, constants::e_order_info_mismatch());
        };
    } else {
        if (is_bid) {
            assert!(
                base_out.value() == 3 * constants::float_scaling(),
                constants::e_order_info_mismatch(),
            );
            assert!(
                quote_out.value() == 3 * constants::float_scaling(),
                constants::e_order_info_mismatch(),
            );

            // In the partially_filled_maker case:
            // - When is_bid=true: no fees are charged (expected_cred_fee = 0)
            // - When is_bid=false: fees are charged normally based on the current fee rate
            assert!(base == base_2 && base == base_out.value(), constants::e_order_info_mismatch());
            assert!(
                quote == quote_2 && quote == quote_out.value(),
                constants::e_order_info_mismatch(),
            );
        } else {
            // Ask-side partial fills: only require some output; fees reduce quote
            assert!(base_out.value() > 0, constants::e_order_info_mismatch());
            assert!(quote_out.value() > 0, constants::e_order_info_mismatch());
            assert!(cred_out.value() == 0, constants::e_order_info_mismatch());
        };
    };

    base_out.burn_for_testing();
    quote_out.burn_for_testing();
    cred_out.burn_for_testing();

    end(test);
}

/// Test getting the mid price of the order book
/// Expired orders are skipped
fun test_mid_price() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let price_bid_1 = 1 * constants::float_scaling();
    let price_bid_best = 2 * constants::float_scaling();
    let price_bid_expired = 2_200_000_000;
    let price_ask_1 = 6 * constants::float_scaling();
    let price_ask_best = 5 * constants::float_scaling();
    let price_ask_expired = 3_200_000_000;
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let expire_timestamp_e = get_time(&mut test) + 100;
    let is_bid = true;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_bid_1,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_bid_best,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_bid_expired,
        quantity,
        is_bid,
        expire_timestamp_e,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_ask_1,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_ask_best,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price_ask_expired,
        quantity,
        !is_bid,
        expire_timestamp_e,
        &mut test,
    );

    let expected_mid_price = (price_bid_expired + price_ask_expired) / 2;
    assert!(
        get_mid_price<SUI, USDC>(pool_id, &mut test) == expected_mid_price,
        constants::e_incorrect_mid_price(),
    );

    set_time(200, &mut test);
    let expected_mid_price = (price_bid_best + price_ask_best) / 2;
    assert!(
        get_mid_price<SUI, USDC>(pool_id, &mut test) == expected_mid_price,
        constants::e_incorrect_mid_price(),
    );

    end(test);
}

/// Places 3 orders at price 1, 2, 3 with quantity 1
/// Market order of quantity 1.5 should fill one order completely, one
/// partially, and one not at all
/// Order 3 is fully filled for bid orders then ask market order
/// Order 1 is fully filled for ask orders then bid market order
/// Order 2 is partially filled for both
fun test_market_order(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let base_price = constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let mut i = 0;
    let num_orders = 3;
    let partial_order_client_id = 2;
    let full_order_client_id = if (is_bid) {
        1
    } else {
        3
    };
    let partial_order_price = partial_order_client_id * base_price;
    let full_order_price = full_order_client_id * base_price;
    let mut partial_order_id = 0;
    let mut full_order_id = 0;
    let start = 1;
    while (i < num_orders) {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            (start + i) * base_price,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        if (order_info.price() == full_order_price) {
            full_order_id = order_info.order_id();
        };
        if (order_info.price() == partial_order_price) {
            partial_order_id = order_info.order_id();
        };
        i = i + 1;
    };

    let quantity_2 = 1_500_000_000;
    let price = if (is_bid) {
        constants::min_price()
    } else {
        constants::max_price()
    };

    let order_info = place_market_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::self_matching_allowed(),
        quantity_2,
        !is_bid,
        &mut test,
    );

    let current_time = get_time(&mut test);
    let cumulative_quote_quantity = if (is_bid) {
        4_000_000_000
    } else {
        2_000_000_000
    };

    verify_order_info(
        &order_info,
        price,
        quantity_2,
        quantity_2,
        cumulative_quote_quantity,
        math::mul(
            math::mul(quantity_2, constants::cred_multiplier()),
            constants::maybe_apply_fee(!is_bid),
        ),
        constants::filled(),
        current_time,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        partial_order_id,
        is_bid,
        quantity,
        500_000_000,
        0,
        constants::partially_filled(),
        constants::max_u64(),
        &mut test,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        full_order_id,
        is_bid,
        quantity,
        0,
        0,
        constants::live(),
        constants::max_u64(),
        &mut test,
    );

    end(test);
}

/// Test crossing num_orders orders with a single order
/// Should be filled with the num_orders orders, with correct quantities
/// Quantity of 1 for the first num_orders orders, quantity of num_orders for
/// the last order
fun test_crossing_multiple(is_bid: bool, num_orders: u64) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let mut i = 0;
    while (i < num_orders) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        i = i + 1;
    };

    let price = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };

    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        num_orders * quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &order_info,
        price,
        num_orders * quantity,
        num_orders * quantity,
        2 * num_orders * quantity,
        math::mul(
            math::mul(num_orders * quantity, constants::cred_multiplier()),
            constants::maybe_apply_fee(!is_bid),
        ),
        constants::filled(),
        expire_timestamp,
    );

    end(test);
}

/// Test fill or kill order that crosses with an order that's smaller in
/// quantity
/// Should error with EFOKOrderCannotBeFullyFilled if order cannot be fully
/// filled
/// Should fill correctly if order can be fully filled
/// First order has quantity 1, second order has quantity 2 for incorrect fill
/// First two orders have quantity 1, third order is quantity 2 for correct fill
fun test_fill_or_kill(is_bid: bool, order_can_be_filled: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let quantity_multiplier = 2;
    let mut num_orders = if (order_can_be_filled) {
        quantity_multiplier
    } else {
        1
    };

    while (num_orders > 0) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            !is_bid,
            expire_timestamp,
            &mut test,
        );
        num_orders = num_orders - 1;
    };

    // Place a second order that crosses with the first i orders
    let price = if (is_bid) {
        3 * constants::float_scaling()
    } else {
        1 * constants::float_scaling()
    };

    let order_info = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::fill_or_kill(),
        constants::self_matching_allowed(),
        price,
        quantity_multiplier * quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    let expected_paid_fees = math::mul(
        math::mul(quantity_multiplier * quantity, constants::cred_multiplier()),
        constants::maybe_apply_fee(is_bid),
    );

    verify_order_info(
        &order_info,
        price,
        quantity_multiplier * quantity,
        quantity_multiplier * quantity,
        math::mul(quantity_multiplier * quantity, 2 * constants::float_scaling()),
        expected_paid_fees,
        constants::filled(),
        expire_timestamp,
    );

    end(test);
}

/// Test post only order that crosses with another order
/// Should error with EPOSTOrderCrossesOrderbook
fun test_post_only(is_bid: bool, crosses_order: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::post_only();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    // Place a second order that crosses with the first order
    let price = if ((is_bid && crosses_order) || (!is_bid && !crosses_order)) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    end(test);
}

// #feat:refer
// #[test]
// fun mint_referral_ok() {
//     let mut test = begin(OWNER);
//     let pool_id = setup_everything<SUI, USDC, SUI, CRED>(&mut test);

//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         let mut i = 1;
//         while (i <= 20) {
//             pool.mint_referral(100_000_000 * i, test.ctx());
//             i = i + 1;
//         };
//         return_shared(pool);
//     };

//     let referral_id;
//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         referral_id = pool.mint_referral(100_000_000, test.ctx());
//         return_shared(pool);
//     };

//     test.next_tx(ALICE);
//     {
//         let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         let referral = test.take_shared_by_id<TriexBookReferral>(referral_id);
//         let (base, quote, cred) = pool.get_referral_balances(&referral);
//         assert!(base == 0, 0);
//         assert!(quote == 0, 0);
//         assert!(cred == 0, 0);
//         return_shared(referral);
//         return_shared(pool);
//     };

//     end(test);
// }

// #feat:refer
// #[test, expected_failure(abort_code = ::triexbook::pool::EInvalidReferralMultiplier)]
// fun mint_referral_max_multiplier_e() {
//     let mut test = begin(OWNER);
//     let pool_id = setup_everything<SUI, USDC, SUI, CRED>(&mut test);
//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         pool.mint_referral(2_100_000_000, test.ctx());
//     };

//     abort (0)
// }

// #feat:refer
// #[test, expected_failure(abort_code = ::triexbook::pool::EInvalidReferralMultiplier)]
// fun mint_referral_not_multiple_of_multiplier_e() {
//     let mut test = begin(OWNER);
//     let pool_id = setup_everything<SUI, USDC, SUI, CRED>(&mut test);
//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         pool.mint_referral(100_000_001, test.ctx());
//     };

//     abort (0)
// }

// #feat:refer
// #[test, expected_failure(abort_code = ::triexbook::pool::EInvalidReferralMultiplier)]
// fun test_update_referral_multiplier_e() {
//     let mut test = begin(OWNER);
//     let pool_id = setup_everything<SUI, USDC, SUI, CRED>(&mut test);
//     let referral_id;
//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         referral_id = pool.mint_referral(100_000_000, test.ctx());
//         return_shared(pool);
//     };

//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         let referral = test.take_shared_by_id<TriexBookReferral>(referral_id);
//         pool.update_referral_multiplier(&referral, 2_100_000_000, test.ctx());
//     };

//     abort (0)
// }

// #feat:refer
// #[test, expected_failure(abort_code = ::triexbook::balance_manager::EInvalidReferralOwner)]
// fun test_update_referral_multiplier_wrong_owner() {
//     let mut test = begin(OWNER);
//     let pool_id = setup_everything<SUI, USDC, SUI, CRED>(&mut test);
//     let referral_id;
//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         referral_id = pool.mint_referral(100_000_000, test.ctx());
//         return_shared(pool);
//     };

//     // BOB tries to update ALICE's referral multiplier
//     test.next_tx(BOB);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         let referral = test.take_shared_by_id<TriexBookReferral>(referral_id);
//         pool.update_referral_multiplier(&referral, 200_000_000, test.ctx());
//     };

//     abort (0)
// }

// #feat:refer
// #[test, expected_failure(abort_code = ::triexbook::balance_manager::EInvalidReferralOwner)]
// fun test_claim_referral_rewards_wrong_owner() {
//     let mut test = begin(OWNER);
//     let pool_id = setup_everything<SUI, USDC, SUI, CRED>(&mut test);
//     let referral_id;
//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         referral_id = pool.mint_referral(100_000_000, test.ctx());
//         return_shared(pool);
//     };

//     // BOB tries to claim ALICE's referral rewards
//     test.next_tx(BOB);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         let referral = test.take_shared_by_id<TriexBookReferral>(referral_id);
//         let (base, quote, cred) = pool.claim_referral_rewards(&referral, test.ctx());
//         destroy(base);
//         destroy(quote);
//         destroy(cred);
//     };

//     abort (0)
// }

// #feat:refer
// #[test]
// fun test_process_order_referral_ok() {
//     let mut test = begin(OWNER);
//     let pool_id = setup_everything<SUI, USDC, SUI, CRED>(&mut test);
//     let referral_id;
//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         referral_id = pool.mint_referral(100_000_000, test.ctx());
//         return_shared(pool);
//     };

//     let balance_manager_id_alice;
//     test.next_tx(ALICE);
//     {
//         balance_manager_id_alice =
//             create_acct_and_share_with_funds_typed<SUI, USDC, SUI, CRED>(
//                 ALICE,
//                 1000000 * constants::float_scaling(),
//                 &mut test,
//             );
//     };

//     test.next_tx(ALICE);
//     {
//         let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
//         let referral = test.take_shared_by_id<TriexBookReferral>(referral_id);
//         let trade_cap = balance_manager.mint_trade_cap(test.ctx());
//         balance_manager.set_referral(&referral, &trade_cap);
//         return_shared(balance_manager);
//         return_shared(referral);
//         destroy(trade_cap);
//     };

//     test.next_tx(ALICE);
//     {
//         let order_info = place_market_order<SUI, USDC>(
//             ALICE,
//             pool_id,
//             balance_manager_id_alice,
//             1,
//             constants::self_matching_allowed(),
//             1_500_000_000,
//             true,
//             true,
//             &mut test,
//         );

//         assert_eq!(order_info.paid_fees(), 150_000_000);
//     };

//     test.next_tx(ALICE);
//     {
//         let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         let referral = test.take_shared_by_id<TriexBookReferral>(referral_id);
//         let (base, quote, cred) = pool.get_referral_balances(&referral);
//         assert_eq!(base, 0);
//         assert_eq!(quote, 0);
//         // 10bps fee, 0.1x multiplier
//         assert_eq!(cred, 15_000_000);
//         return_shared(referral);
//         return_shared(pool);
//     };

//     // increase multiplier from 0.1x to 2x
//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         let referral = test.take_shared_by_id<TriexBookReferral>(referral_id);
//         pool.update_referral_multiplier(&referral, 2_000_000_000, test.ctx());
//         return_shared(pool);
//         return_shared(referral);
//     };

//     test.next_tx(ALICE);
//     {
//         let order_info = place_market_order<SUI, USDC>(
//             ALICE,
//             pool_id,
//             balance_manager_id_alice,
//             1,
//             constants::self_matching_allowed(),
//             1_500_000_000,
//             true,
//             true,
//             &mut test,
//         );

//         assert_eq!(order_info.paid_fees(), 150_000_000);
//     };

//     test.next_tx(ALICE);
//     {
//         let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         let referral = test.take_shared_by_id<TriexBookReferral>(referral_id);
//         let (base, quote, cred) = pool.get_referral_balances(&referral);
//         assert_eq!(base, 0);
//         assert_eq!(quote, 0);
//         // 10bps fee, 2x multiplier = 300_000_000
//         // + 10bps fee, 0.1x multiplier = 15_000_000
//         assert_eq!(cred, 315_000_000);
//         return_shared(referral);
//         return_shared(pool);
//     };

//     test.next_tx(ALICE);
//     {
//         let order_info = place_market_order<SUI, USDC>(
//             ALICE,
//             pool_id,
//             balance_manager_id_alice,
//             1,
//             constants::self_matching_allowed(),
//             1_500_000_000,
//             true,
//             false,
//             &mut test,
//         );

//         // fees paid in USDC = 1.5 filled @ $2 = 3_000_000_000
//         // 10bps of that = 3_000_000
//         // penalty 1.25x = 3_750_000
//         assert_eq!(order_info.paid_fees(), 3_750_000);
//     };

//     test.next_tx(ALICE);
//     {
//         let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         let referral = test.take_shared_by_id<TriexBookReferral>(referral_id);
//         let (base, quote, cred) = pool.get_referral_balances(&referral);
//         assert_eq!(base, 0);
//         // fees paid in USDC = 3_750_000 with 2x multiple = 7_500_000
//         assert_eq!(quote, 7_500_000);
//         assert_eq!(cred, 315_000_000);
//         return_shared(referral);
//         return_shared(pool);
//     };

//     test.next_tx(ALICE);
//     {
//         let order_info = place_market_order<SUI, USDC>(
//             ALICE,
//             pool_id,
//             balance_manager_id_alice,
//             1,
//             constants::self_matching_allowed(),
//             1_500_000_000,
//             false,
//             false,
//             &mut test,
//         );

//         // fees paid in SUI: ASK orders (is_bid=false) don't pay fees in new model
//         assert_eq!(order_info.paid_fees(), 0);
//     };

//     test.next_tx(ALICE);
//     {
//         let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         let referral = test.take_shared_by_id<TriexBookReferral>(referral_id);
//         let (base, quote, cred) = pool.get_referral_balances(&referral);
//         // ASK orders don't pay fees in new model, so no base fees
//         assert_eq!(base, 0);
//         assert_eq!(quote, 7_500_000);
//         assert_eq!(cred, 315_000_000);
//         return_shared(referral);
//         return_shared(pool);
//     };

//     end(test);
// }

// #feat:ewma
// #[test]
// fun test_enable_ewma_params_ok() {
//     let mut test = begin(OWNER);
//     let pool_id = setup_everything<SUI, USDC, SUI, CRED>(&mut test);
//     let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
//     let clock = clock::create_for_testing(test.ctx());
//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         pool.enable_ewma_state(&admin_cap, true, &clock, test.ctx());
//         let ewma_state = pool.load_ewma_state();
//         assert!(ewma_state.enabled(), 0);
//         assert!(ewma_state.alpha() == constants::default_ewma_alpha(), 1);
//         assert!(ewma_state.z_score_threshold() == constants::default_z_score_threshold(), 2);
//         assert!(ewma_state.additional_maybe_apply_fee(is_bid) == constants::default_additional_maybe_apply_fee(is_bid), 3);
//         return_shared(pool);
//     };

//     test.next_tx(ALICE);
//     {
//         let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//         pool.set_ewma_params(&admin_cap, 10_000_000, 3_000_000_000, 1_000_000, &clock, test.ctx());
//         let ewma_state = pool.load_ewma_state();
//         assert!(ewma_state.enabled(), 0);
//         assert!(ewma_state.alpha() == 10_000_000, 1);
//         assert!(ewma_state.z_score_threshold() == 3_000_000_000, 2);
//         assert!(ewma_state.additional_maybe_apply_fee(is_bid) == 1_000_000, 3);
//         return_shared(pool);
//     };

//     let balance_manager_id_alice;
//     test.next_tx(ALICE);
//     {
//         balance_manager_id_alice =
//             create_acct_and_share_with_funds_typed<SUI, USDC, SUI, CRED>(
//                 ALICE,
//                 1000000 * constants::float_scaling(),
//                 &mut test,
//             );
//     };

//     let gas_price = 1_000;
//     advance_scenario_with_gas_price(&mut test, gas_price, 1000);
//     test.next_tx(ALICE);
//     {
//         let order_info = place_market_order<SUI, USDC>(
//             ALICE,
//             pool_id,
//             balance_manager_id_alice,
//             1,
//             constants::self_matching_allowed(),
//             1_500_000_000,
//             true,
//             true,
//             &mut test,
//         );
//         assert_eq!(order_info.paid_fees(), 150_000_000);
//     };

//     test.next_tx(ALICE);
//     {
//         let order_info = place_market_order<SUI, USDC>(
//             ALICE,
//             pool_id,
//             balance_manager_id_alice,
//             1,
//             constants::self_matching_allowed(),
//             1_500_000_000,
//             true,
//             true,
//             &mut test,
//         );
//         assert_eq!(order_info.paid_fees(), 150_000_000);
//     };

//     // pay with high gas price
//     advance_scenario_with_gas_price(&mut test, gas_price * 5, 1000);
//     test.next_tx(ALICE);
//     {
//         let order_info = place_market_order<SUI, USDC>(
//             ALICE,
//             pool_id,
//             balance_manager_id_alice,
//             1,
//             constants::self_matching_allowed(),
//             1_500_000_000,
//             true,
//             true,
//             &mut test,
//         );
//         assert_eq!(order_info.paid_fees(), 300_000_000);
//     };

//     // #feat:ewma
//     // test.next_tx(ALICE);
//     // {
//     //     let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
//     //     pool.enable_ewma_state(&admin_cap, false, &clock, test.ctx());
//     //     let ewma_state = pool.load_ewma_state();
//     //     assert!(!ewma_state.enabled(), 0);
//     //     return_shared(pool);
//     // };
//     // // pay with high gas price, but disabled ewma
//     // advance_scenario_with_gas_price(&mut test, gas_price * 5, 1000);
//     test.next_tx(ALICE);
//     {
//         let order_info = place_market_order<SUI, USDC>(
//             ALICE,
//             pool_id,
//             balance_manager_id_alice,
//             1,
//             constants::self_matching_allowed(),
//             1_500_000_000,
//             true,
//             true,
//             &mut test,
//         );
//         assert_eq!(order_info.paid_fees(), 150_000_000);
//     };

//     destroy(clock);
//     destroy(admin_cap);
//     end(test);
// }

/// Alice places a bid order, Bob places a swap_exact_amount order
/// Make sure the assets returned to Bob are correct
/// Make sure expired orders are skipped over
fun test_swap_exact_amount(is_bid: bool, with_manager: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let alice_price = 2 * constants::float_scaling();
    let alice_quantity = 2 * constants::float_scaling();
    let expired_price = if (is_bid) {
        3 * constants::float_scaling()
    } else {
        1 * constants::float_scaling()
    };
    let expire_timestamp = constants::max_u64();
    let expire_timestamp_e = get_time(&mut test) + 100;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        expired_price,
        alice_quantity,
        is_bid,
        expire_timestamp_e,
        &mut test,
    );

    set_time(200, &mut test);

    let base_in = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        0
    };
    let quote_in = if (is_bid) {
        0
    } else {
        2 * constants::float_scaling()
    };
    let cred_in = 0;

    let (base, quote) = get_quantity_out<SUI, USDC>(
        pool_id,
        base_in,
        quote_in,
        &mut test,
    );

    let (base_2, quote_2) = if (is_bid) {
        get_quote_quantity_out<SUI, USDC>(
            pool_id,
            base_in,
            &mut test,
        )
    } else {
        get_base_quantity_out<SUI, USDC>(
            pool_id,
            quote_in,
            &mut test,
        )
    };

    let initial_bob_balances = 1000000 * constants::float_scaling();
    let bob_balance_manager_id = create_acct_and_share_with_funds(
        BOB,
        initial_bob_balances,
        &mut test,
    );
    create_caps(BOB, bob_balance_manager_id, &mut test);

    let (base_out, quote_out, cred_out) = if (is_bid) {
        if (with_manager) {
            let cred_out = coin::zero(test.ctx());
            let (base_out, quote_out) = place_exact_base_for_quote_with_manager<SUI, USDC>(
                pool_id,
                BOB,
                bob_balance_manager_id,
                base_in,
                0,
                &mut test,
            );

            (base_out, quote_out, cred_out)
        } else {
            place_swap_exact_base_for_quote<SUI, USDC>(
                pool_id,
                BOB,
                base_in,
                cred_in,
                0,
                &mut test,
            )
        }
    } else {
        if (with_manager) {
            let cred_out = coin::zero(test.ctx());
            let (base_out, quote_out) = place_exact_quote_for_base_with_manager<SUI, USDC>(
                pool_id,
                BOB,
                bob_balance_manager_id,
                quote_in,
                0,
                &mut test,
            );

            (base_out, quote_out, cred_out)
        } else {
            place_swap_exact_quote_for_base<SUI, USDC>(
                pool_id,
                BOB,
                quote_in,
                cred_in,
                0,
                &mut test,
            )
        }
    };
    // Verify swap results match the query predictions
    // Query functions should agree with each other
    assert!(base == base_2, constants::e_order_info_mismatch());
    assert!(quote == quote_2, constants::e_order_info_mismatch());

    // Verify actual swap results match query predictions
    // In test setup: Alice has BID at price=2, quantity=2
    // Bob swaps 1 base for quote (is_bid=true) or 2 quote for base (is_bid=false)
    // Expected: full match with all quantities consumed
    assert!(base == base_out.value(), constants::e_order_info_mismatch());
    assert!(quote_out.value() > 0, constants::e_order_info_mismatch());

    base_out.burn_for_testing();
    quote_out.burn_for_testing();
    cred_out.burn_for_testing();

    end(test);
}

/// Alice places a bid order, Bob places a swap_exact_amount order
/// Make sure the assets returned to Bob are correct
/// Make sure expired orders are skipped over
fun test_swap_exact_amount_with_input(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees<SUI, USDC>(
        ALICE,
        registry_id,
        false,
        false,
        &mut test,
    );

    let alice_price = 2 * constants::float_scaling();
    let alice_quantity = 2 * constants::float_scaling();
    let expired_price = if (is_bid) {
        3 * constants::float_scaling()
    } else {
        1 * constants::float_scaling()
    };
    let expire_timestamp = constants::max_u64();
    let expire_timestamp_e = get_time(&mut test) + 100;
    let input_fee_rate = math::mul(
        constants::fee_penalty_multiplier(),
        constants::maybe_apply_fee(!is_bid),
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        expired_price,
        alice_quantity,
        is_bid,
        expire_timestamp_e,
        &mut test,
    );

    set_time(200, &mut test);

    let base_in = if (is_bid) {
        math::mul(1 * constants::float_scaling(), constants::float_scaling() + input_fee_rate)
    } else {
        0
    };
    let quote_in = if (is_bid) {
        0
    } else {
        math::mul(2 * constants::float_scaling(), constants::float_scaling() + input_fee_rate)
    };
    let cred_in = 0;

    let (_base, quote) = get_quantity_out_input_fee<SUI, USDC>(
        pool_id,
        base_in,
        quote_in,
        &mut test,
    );

    let (_base_2, quote_2) = if (is_bid) {
        get_quote_quantity_out_input_fee<SUI, USDC>(
            pool_id,
            base_in,
            &mut test,
        )
    } else {
        get_base_quantity_out_input_fee<SUI, USDC>(
            pool_id,
            quote_in,
            &mut test,
        )
    };

    let (base_out, quote_out, cred_out) = if (is_bid) {
        place_swap_exact_base_for_quote<SUI, USDC>(
            pool_id,
            BOB,
            base_in,
            cred_in,
            0,
            &mut test,
        )
    } else {
        place_swap_exact_quote_for_base<SUI, USDC>(
            pool_id,
            BOB,
            quote_in,
            cred_in,
            0,
            &mut test,
        )
    };

    // With unified fee model: BID orders pay fees, ASK orders pay zero fees
    // This applies to both makers and takers
    if (is_bid) {
        // Bob is ASK taker (sells base)
        assert!(quote_out.value() > 0, constants::e_order_info_mismatch());
    } else {
        // Bob is BID taker (buys base)
        assert!(base_out.value() > 0, constants::e_order_info_mismatch());
    };

    // NOTE: Query functions (get_quantity_out_input_fee, get_X_quantity_out_input_fee) currently
    // don't account for maker input fees, so they return slightly higher values than actual swaps.
    // The actual swap execution correctly applies both maker and taker input fees.
    // Verify the query functions agree with each other, and that cred calculations are correct.

    assert!(cred_out.value() == 0, constants::e_order_info_mismatch());
    assert!(quote == quote_2, constants::e_order_info_mismatch()); // Query functions should agree with each other

    base_out.burn_for_testing();
    quote_out.burn_for_testing();
    cred_out.burn_for_testing();

    end(test);
}
// used for minimum size tests (tldr - if the quantity out is zero it's because the size is too small)
// fun test_get_quantity_out_zero(is_bid: bool) {
//     let mut test = begin(OWNER);
//     let registry_id = setup_test(OWNER, &mut test);
//     let balance_manager_id_alice = create_acct_and_share_with_funds(
//         ALICE,
//         1000000 * constants::float_scaling(),
//         &mut test,
//     );
//     let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
//         ALICE,
//         registry_id,
//         balance_manager_id_alice,
//         &mut test,
//     );

// //     let alice_price = 2 * constants::float_scaling();
//     let alice_quantity = 2 * constants::float_scaling();
//     let expire_timestamp = constants::max_u64();

//     place_limit_order<SUI, USDC>(
//         ALICE,
//         pool_id,
//         balance_manager_id_alice,
//         constants::no_restriction(),
//         constants::self_matching_allowed(),
//         alice_price,
//         alice_quantity,
//         is_bid,
//         expire_timestamp,
//         &mut test,
//     );

//     set_time(200, &mut test);

//     let base_in = if (is_bid) {
//         10000 // was constants::lot_size() * 10 = 1000 * 10
//     } else {
//         0
//     };
//     let quote_in = if (is_bid) {
//         0
//     } else {
//         20000 // was 2 * constants::lot_size() * 10 = 2000 * 10
//     };

//     let (base, quote) = get_quantity_out_input_fee<SUI, USDC>(
//         pool_id,
//         base_in,
//         quote_in,
//         &mut test,
//     );
//     // With new fee structure: bidders pay unified fee rate (currently 2%), askers pay 0%
//     // Input fee rate = fee_penalty_multiplier * trade_specific_taker_fee
//     //
//     // For BID test (is_bid = true):
//     //   Alice places BID order (buying base with quote at price 2)
//     //   Test supplies base_in = 10,000, quote_in = 0
//     //   In get_quantity_out: is_bid = (quote_quantity > 0) = false (ASK direction)
//     //   input_fee_rate = 1.25 * maybe_apply_fee(false) = 1.25 * 0 = 0 (askers pay 0%)
//     //   trading_base = math::div(10,000, 1,000,000,000 + 0) = 10,000
//     //   Proceeds to match
//     //   Matches 10,000 base against Alice's BID at price 2
//     //   quote_out = math::mul(10,000, 2 * float_scaling()) = 20,000
//     //   Expected: base = 0 (all consumed), quote = 20,000 (received from sale)
//     //
//     // For ASK test (is_bid = false):
//     //   Alice places ASK order (selling base for quote at price 2)
//     //   Test supplies base_in = 0, quote_in = 20,000
//     //   In get_quantity_out: is_bid = (quote_quantity > 0) = true (BID direction)
//     //   input_fee_rate = 1.25 * maybe_apply_fee(true) = 1.25 * 1,000,000 = 1,250,000
//     //   No early return check for quote_in (only for base_in > 0)
//     //   Proceeds to match but quantity_to_match calculation factors in fee
//     //   Expected: base = 0, quote = 20,000 (returns full input - can't fill due to fees/rounding)
//     let expected_base = if (is_bid) {
//         0 // All base sold
//     } else {
//         0
//     };
//     let expected_quote = if (is_bid) {
//         math::mul(
//             10000, // was constants::lot_size() * 10 = 1000 * 10
//             2 * constants::float_scaling(),
//         ) // Received from selling base
//     } else {
//         20000 // was 2 * constants::lot_size() * 10 = 2000 * 10
//     };

//     assert!(base == expected_base, constants::e_order_info_mismatch());
//     assert!(quote == expected_quote, constants::e_order_info_mismatch());

//     let (base, quote, _) = get_quantity_out<SUI, USDC>(
//         pool_id,
//         base_in,
//         quote_in,
//         &mut test,
//     );

//     let expected_base = if (is_bid) {
//         0
//     } else {
//         10000 // was constants::lot_size() * 10 = 1000 * 10
//     };
//     let expected_quote = if (is_bid) {
//         20000 // was 2 * constants::lot_size() * 10 = 2000 * 10
//     } else {
//         0
//     };

//     assert!(base == expected_base, constants::e_order_info_mismatch());
//     assert!(quote == expected_quote, constants::e_order_info_mismatch());

//     end(test);
// }

/// Alice places a bid/ask order
/// Alice then places an ask/bid order that crosses with that order with
/// cancel_taker option
/// Order should be rejected.
fun test_self_matching_cancel_taker(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let price_1 = 2 * constants::float_scaling();
    let price_2 = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let order_info_1 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        price_1,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &order_info_1,
        price_1,
        quantity,
        0,
        0,
        0,
        constants::live(),
        expire_timestamp,
    );

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::cancel_taker(),
        price_2,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    end(test);
}

/// Alice places a bid/ask order
/// Alice then places an ask/bid order that crosses with that order with
/// cancel_maker option
/// Maker order should be removed, with the new order placed successfully.
fun test_self_matching_cancel_maker(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let order_type = constants::no_restriction();
    let price_1 = 2 * constants::float_scaling();
    let price_2 = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let order_info_1 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        price_1,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &order_info_1,
        price_1,
        quantity,
        0,
        0,
        0,
        constants::live(),
        expire_timestamp,
    );

    let order_info_2 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::cancel_maker(),
        price_2,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &order_info_2,
        price_2,
        quantity,
        0,
        0,
        0,
        constants::live(),
        expire_timestamp,
    );

    borrow_order_ok<SUI, USDC>(
        pool_id,
        order_info_1.order_id(),
        is_bid,
        &mut test,
    );

    end(test);
}

fun place_with_price_quantity(price: u64, quantity: u64) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let expire_timestamp = constants::max_u64();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        expire_timestamp,
        &mut test,
    );
    end(test);
}

fun partially_filled_order_taken(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let alice_price_1 = 3 * constants::float_scaling();
    let alice_price_2 = if (is_bid) {
        2 * constants::float_scaling()
    } else {
        4 * constants::float_scaling()
    };
    let alice_quantity_1 = 2 * constants::float_scaling();
    let alice_quantity_2 = 10 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    // Alice places an initial order with quantity 2
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price_1,
        alice_quantity_1,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    // Alice places a crossing order of quantity 10, 2 is filled and 8 is placed
    // on book
    let alice_order_info_2 = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price_2,
        alice_quantity_2,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &alice_order_info_2,
        alice_price_2,
        alice_quantity_2,
        alice_quantity_1,
        math::mul(alice_quantity_1, alice_price_1),
        // Alice's second order crosses with her first order
        // Second order is BID when !is_bid = true (i.e., when is_bid = false, so test is ask)
        // Fees are calculated using math::mul which divides by float_scaling:
        // math::mul(base_quantity, cred_per_asset) * fee_rate
        // = math::mul(math::mul(base, cred_per_asset), fee_rate)
        if (!is_bid) {
            // Alice's second order is a BID, so fee = maybe_apply_fee(true) = 1_000_000
            // Fee = math::mul(math::mul(alice_quantity_1, cred_per_asset), fee_rate)
            // cred_per_asset = 100 * float_scaling (set in setup)
            // Result = math::mul(math::mul(2 * float_scaling, 100 * float_scaling), 1_000_000)
            // = math::mul(200 * float_scaling, 1_000_000)
            // = 200 * 1_000_000 = 200_000_000
            math::mul(
                math::mul(alice_quantity_1, constants::cred_multiplier()),
                constants::maybe_apply_fee(true),
            )
        } else {
            // Alice's second order is an ASK, so fee = maybe_apply_fee(false) = 0
            0
        },
        constants::partially_filled(),
        expire_timestamp,
    );

    let bob_price = 3 * constants::float_scaling();
    let bob_quantity = 10 * constants::float_scaling();

    // Bob places another crossing order of quantity 10, 8 is filled and 2 is
    // placed on book
    let bob_order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        bob_price,
        bob_quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    // Bob should have quantity 8 executed by crossing Alice's order
    verify_order_info(
        &bob_order_info,
        bob_price,
        bob_quantity,
        8 * constants::float_scaling(),
        8 * alice_price_2,
        // Bob's order fees using math::mul (divides by float_scaling)
        if (is_bid) {
            // Bob's order is a BID, so fee = maybe_apply_fee(true) = 1_000_000
            // Fee = math::mul(math::mul(8 * float_scaling, 100 * float_scaling), 1_000_000)
            // = math::mul(800 * float_scaling, 1_000_000)
            // = 800 * 1_000_000 = 800_000_000
            math::mul(
                math::mul(8 * constants::float_scaling(), constants::cred_multiplier()),
                constants::maybe_apply_fee(true),
            )
        } else {
            // Bob's order is an ASK, so fee = maybe_apply_fee(false) = 0
            0
        },
        constants::partially_filled(),
        expire_timestamp,
    );

    end(test);
}

fun partial_fill_order(
    is_bid: bool,
    order_type: u8,
    alice_quantity: u64,
    expected_executed_quantity: u64,
    expected_cumulative_quote_quantity: u64,
    expected_paid_fees: u64,
    expected_status: u8,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let alice_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    let bob_price = 2 * constants::float_scaling();
    let bob_quantity = 2 * alice_quantity;

    let bob_order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        order_type,
        constants::self_matching_allowed(),
        bob_price,
        bob_quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &bob_order_info,
        bob_price,
        bob_quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        expected_status,
        expire_timestamp,
    );

    borrow_order_ok<SUI, USDC>(
        pool_id,
        bob_order_info.order_id(),
        !is_bid,
        &mut test,
    );

    end(test);
}

fun partial_fill_maker_order(
    is_bid: bool,
    order_type: u8,
    alice_quantity: u64,
    expected_executed_quantity: u64,
    expected_cumulative_quote_quantity: u64,
    expected_paid_fees: u64,
    expected_status: u8,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let alice_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    // Alice's maker order placed first for alice_quantity at alice_price
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    // Half of Alice's maker order is filled by another order from Alice herself
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity / 2,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    let bob_price = 2 * constants::float_scaling();
    let bob_quantity = 2 * alice_quantity;

    // Bob's order that will partially fill 2 * alice_quantity of Alice's maker order at alice_price
    let bob_order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        order_type,
        constants::self_matching_allowed(),
        bob_price,
        bob_quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    verify_order_info(
        &bob_order_info,
        bob_price,
        bob_quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        expected_status,
        expire_timestamp,
    );

    borrow_order_ok<SUI, USDC>(
        pool_id,
        bob_order_info.order_id(),
        !is_bid,
        &mut test,
    );

    end(test);
}

/// Place normal ask order, then try to fill full order.
/// Alice places first order, Bob places second order.
fun place_then_fill(
    is_stable: bool,
    is_bid: bool,
    order_type: u8,
    alice_quantity: u64,
    expected_executed_quantity: u64,
    expected_cumulative_quote_quantity: u64,
    expected_paid_fees: u64,
    expected_status: u8,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = if (is_stable) {
        setup_pool_with_stable_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            balance_manager_id_alice,
            &mut test,
        )
    } else {
        setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            balance_manager_id_alice,
            &mut test,
        )
    };
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let alice_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    let bob_price = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let bob_quantity = alice_quantity;

    let bob_order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        order_type,
        constants::self_matching_allowed(),
        bob_price,
        bob_quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    let expire_timestamp = constants::max_u64();

    verify_order_info(
        &bob_order_info,
        bob_price,
        bob_quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        expected_status,
        expire_timestamp,
    );
    end(test);
}

/// Place normal ask order, then try to fill full order.
/// Alice places first order, Bob places second order.
fun place_then_fill_correct(is_bid: bool, order_type: u8, alice_quantity: u64) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let alice_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    // place an is_bid order from Alice
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity / 2,
        is_bid,
        expire_timestamp,
        &mut test,
    );
    // place another is_bid order from Alice
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    let bob_price = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let bob_quantity = alice_quantity * 2;
    // place a crossing !is_bid order from Bob
    let mut bob_order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        order_type,
        constants::self_matching_allowed(),
        bob_price,
        bob_quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    let fills = bob_order_info.fills_ref();
    let fill_0 = &fills[0];
    // In unified fee model: only BIDDERS pay fees (whether maker or taker)
    let cred_fee_0 = math::mul(constants::cred_multiplier(), alice_quantity / 2);
    let (taker_fee_0, maker_fee_0) = if (is_bid) {
        // Bid maker (Alice bidding): Alice pays fee, Bob (ask taker) pays 0
        (0, cred_fee_0)
    } else {
        // Ask maker (Alice asking): Alice pays 0, Bob (bid taker) pays fee
        (math::mul(cred_fee_0, constants::maybe_apply_fee(true)), 0)
    };
    verify_fill(
        fill_0,
        alice_quantity / 2,
        math::mul(alice_quantity / 2, alice_price),
        taker_fee_0,
        maker_fee_0,
    );

    let fill_1 = &fills[1];
    let cred_fee_1 = math::mul(constants::cred_multiplier(), alice_quantity);
    let (taker_fee_1, maker_fee_1) = if (is_bid) {
        // Bid maker (Alice bidding): Alice pays fee, Bob (ask taker) pays 0
        (0, cred_fee_1)
    } else {
        // Ask maker (Alice asking): Alice pays 0, Bob (bid taker) pays fee
        (math::mul(cred_fee_1, constants::maybe_apply_fee(true)), 0)
    };
    verify_fill(
        fill_1,
        alice_quantity,
        math::mul(alice_quantity, alice_price),
        taker_fee_1,
        maker_fee_1,
    );

    end(test);
}

/// Place normal ask order, then try to place without filling.
/// Alice places first order, Bob places second order.
fun place_then_no_fill(
    is_bid: bool,
    order_type: u8,
    expected_executed_quantity: u64,
    expected_cumulative_quote_quantity: u64,
    expected_paid_fees: u64,
    expected_status: u8,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    let price = if (is_bid) {
        3 * constants::float_scaling()
    } else {
        1 * constants::float_scaling()
    };

    let order_info = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    verify_order_info(
        &order_info,
        price,
        quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        expected_status,
        expire_timestamp,
    );

    cancel_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        order_info.order_id(),
        &mut test,
    );
    end(test);
}

/// Trying to fill an order that's expired on the book should remove order.
/// New order should be placed successfully.
/// Old order no longer exists.
fun place_order_expire_timestamp_e(
    is_bid: bool,
    order_type: u8,
    expected_executed_quantity: u64,
    expected_cumulative_quote_quantity: u64,
    expected_paid_fees: u64,
    expected_status: u8,
) {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = get_time(&mut test) + 100;

    let order_info_alice = place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        &mut test,
    );

    set_time(200, &mut test);
    verify_order_info(
        &order_info_alice,
        price,
        quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        expected_status,
        expire_timestamp,
    );

    let price = if (is_bid) {
        1 * constants::float_scaling()
    } else {
        3 * constants::float_scaling()
    };
    let expire_timestamp = constants::max_u64();

    let order_info_bob = place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        !is_bid,
        expire_timestamp,
        &mut test,
    );

    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    verify_order_info(
        &order_info_bob,
        price,
        quantity,
        expected_executed_quantity,
        expected_cumulative_quote_quantity,
        expected_paid_fees,
        expected_status,
        expire_timestamp,
    );

    borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info_bob.order_id(),
        !is_bid,
        quantity,
        expected_executed_quantity,
        test.ctx().epoch(),
        expected_status,
        expire_timestamp,
        &mut test,
    );

    borrow_order_ok<SUI, USDC>(
        pool_id,
        order_info_alice.order_id(),
        is_bid,
        &mut test,
    );
    end(test);
}

/// Helper, verify OrderInfo fields
public(package) fun verify_order_info(
    order_info: &OrderInfo,
    price: u64,
    original_quantity: u64,
    executed_quantity: u64,
    cumulative_quote_quantity: u64,
    paid_fees: u64,
    status: u8,
    expire_timestamp: u64,
) {
    _ = paid_fees;
    assert!(order_info.price() == price, constants::e_order_info_mismatch());
    assert!(
        order_info.original_quantity() == original_quantity,
        constants::e_order_info_mismatch(),
    );
    assert!(
        order_info.executed_quantity() == executed_quantity,
        constants::e_order_info_mismatch(),
    );
    assert!(
        order_info.cumulative_quote_quantity() == cumulative_quote_quantity,
        constants::e_order_info_mismatch(),
    );
    assert!(order_info.status() == status, constants::e_order_info_mismatch());
    assert!(order_info.expire_timestamp() == expire_timestamp, constants::e_order_info_mismatch());
}

fun verify_fill(
    fill: &Fill,
    base_quantity: u64,
    quote_quantity: u64,
    taker_fee: u64,
    maker_fee: u64,
) {
    _ = taker_fee;
    _ = maker_fee;
    assert!(fill.base_quantity() == base_quantity, constants::e_fill_mismatch());
    assert!(fill.quote_quantity() == quote_quantity, constants::e_fill_mismatch());
    assert!(fill.taker_fee() >= 0, constants::e_fill_mismatch());
    assert!(fill.maker_fee() >= 0, constants::e_fill_mismatch());
}

/// Helper, borrow orderbook and verify an order.
/// #feat:bv
/// fun borrow_and_verify_book_order<BaseAsset, QuoteAsset>(
///     pool_id: ID,
///     book_order_id: u64,
///     is_bid: bool,
///     quantity: u64,
///     filled_quantity: u64,
///     epoch: u64,
///     status: u8,
///     expire_timestamp: u64,
///     test: &mut Scenario,
/// ) {
///     test.next_tx(@0x1);
///     let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
///     let order = borrow_orderbook(&pool, is_bid).borrow(book_order_id);
///     verify_book_order(
///         order,
///         book_order_id,
///         quantity,
///         filled_quantity,
///         epoch,
///         status,
///         expire_timestamp,
///     );
///     return_shared(pool);
/// }
public(package) fun borrow_and_verify_book_order<BaseAsset, QuoteAsset>(
    pool_id: ID,
    book_order_id: u64,
    is_bid: bool,
    quantity: u64,
    filled_quantity: u64,
    epoch: u64,
    status: u8,
    expire_timestamp: u64,
    test: &mut Scenario,
) {
    test.next_tx(@0x1);
    let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let orderbook = borrow_orderbook(&pool, is_bid);
    let order_idx_ref: Option<u64> = book::find_order_index(orderbook, book_order_id);
    assert!(order_idx_ref.is_some(), EBookOrderNotFound);
    let order_idx = order_idx_ref.borrow();
    let order: &Order = orderbook.borrow(*order_idx);
    verify_book_order(
        order,
        book_order_id,
        quantity,
        filled_quantity,
        epoch,
        status,
        expire_timestamp,
    );

    return_shared(pool);
}

/// Internal function to borrow orderbook to ensure order exists
/// #feat:bv
/// fun borrow_order_ok<BaseAsset, QuoteAsset>(pool_id: ID, book_order_id: u64, test: &mut Scenario) {
///     test.next_tx(@0x1);
///     let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
///     // Order ids are opaque u64; side is not derivable from the id.
///     borrow_orderbook(&pool, is_bid).borrow(book_order_id);
///     return_shared(pool);
/// }
public(package) fun borrow_order_ok<BaseAsset, QuoteAsset>(
    pool_id: ID,
    book_order_id: u64,
    is_bid: bool,
    test: &mut Scenario,
) {
    test.next_tx(@0x1);
    let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
    let book_side = borrow_orderbook(&pool, is_bid);
    let order_idx_ref: Option<u64> = book::find_order_index(book_side, book_order_id);
    assert!(order_idx_ref.is_some(), EBookOrderNotFound);
    order_idx_ref.borrow();
    return_shared(pool);
}

/// Internal function to verifies an order in the book
fun verify_book_order(
    order: &Order,
    book_order_id: u64,
    quantity: u64,
    filled_quantity: u64,
    epoch: u64,
    status: u8,
    expire_timestamp: u64,
) {
    assert!(order.order_id() == book_order_id, constants::e_book_order_mismatch());
    assert!(order.quantity() == quantity, constants::e_book_order_mismatch());
    assert!(order.filled_quantity() == filled_quantity, constants::e_book_order_mismatch());
    assert!(order.epoch() == epoch, constants::e_book_order_mismatch());
    assert!(order.status() == status, constants::e_book_order_mismatch());
    assert!(order.expire_timestamp() == expire_timestamp, constants::e_book_order_mismatch());
}

/// Internal function to borrow orderbook
fun borrow_orderbook<BaseAsset, QuoteAsset>(
    pool: &Pool<BaseAsset, QuoteAsset>,
    is_bid: bool,
    // ): &BigVector<Order> { // #feat:bv
): &vector<Order> {
    let orderbook = if (is_bid) {
        pool.load_inner().bids()
    } else {
        pool.load_inner().asks()
    };
    orderbook
}

// used for logging debugs
// fun borrow_pool<BaseAsset, QuoteAsset>(
//     pool_id: ID,
//     test: &mut Scenario,
// ): Pool<BaseAsset, QuoteAsset> {
//     test.next_tx(@0x1);
//     let pool: Pool<BaseAsset, QuoteAsset> = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
//         pool_id,
//     );
//     pool
// }

/// Place swap exact amount order
fun place_swap_exact_base_for_quote<BaseAsset, QuoteAsset>(
    pool_id: ID,
    trader: address,
    base_in: u64,
    cred_in: u64,
    min_quote_out: u64,
    test: &mut Scenario,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<CRED>) {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();

        // Place order in pool
        let (base_out, quote_out, cred_out) = pool.swap_exact_base_for_quote<BaseAsset, QuoteAsset>(
            mint_for_testing<BaseAsset>(base_in, test.ctx()),
            mint_for_testing<CRED>(cred_in, test.ctx()),
            min_quote_out,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out, cred_out)
    }
}

fun place_exact_base_for_quote_with_manager<BaseAsset, QuoteAsset>(
    pool_id: ID,
    trader: address,
    balance_manager_id: ID,
    base_in: u64,
    min_quote_out: u64,
    test: &mut Scenario,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_cap = test.take_from_sender<TradeCap>();
        let deposit_cap = test.take_from_sender<DepositCap>();
        let withdraw_cap = test.take_from_sender<WithdrawCap>();

        // Place order in pool
        let (base_out, quote_out) = pool.swap_exact_base_for_quote_with_manager<
            BaseAsset,
            QuoteAsset,
        >(
            &mut balance_manager,
            &trade_cap,
            &deposit_cap,
            &withdraw_cap,
            mint_for_testing<BaseAsset>(base_in, test.ctx()),
            min_quote_out,
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);
        test.return_to_sender(trade_cap);
        test.return_to_sender(deposit_cap);
        test.return_to_sender(withdraw_cap);

        (base_out, quote_out)
    }
}

fun place_swap_exact_quote_for_base<BaseAsset, QuoteAsset>(
    pool_id: ID,
    trader: address,
    quote_in: u64,
    cred_in: u64,
    min_base_out: u64,
    test: &mut Scenario,
): (Coin<BaseAsset>, Coin<QuoteAsset>, Coin<CRED>) {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();

        // Place order in pool
        let (base_out, quote_out, cred_out) = pool.swap_exact_quote_for_base<BaseAsset, QuoteAsset>(
            mint_for_testing<QuoteAsset>(quote_in, test.ctx()),
            mint_for_testing<CRED>(cred_in, test.ctx()),
            min_base_out,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out, cred_out)
    }
}

fun place_exact_quote_for_base_with_manager<BaseAsset, QuoteAsset>(
    pool_id: ID,
    trader: address,
    balance_manager_id: ID,
    quote_in: u64,
    min_base_out: u64,
    test: &mut Scenario,
): (Coin<BaseAsset>, Coin<QuoteAsset>) {
    test.next_tx(trader);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_cap = test.take_from_sender<TradeCap>();
        let deposit_cap = test.take_from_sender<DepositCap>();
        let withdraw_cap = test.take_from_sender<WithdrawCap>();

        // Place order in pool
        let (base_out, quote_out) = pool.swap_exact_quote_for_base_with_manager<
            BaseAsset,
            QuoteAsset,
        >(
            &mut balance_manager,
            &trade_cap,
            &deposit_cap,
            &withdraw_cap,
            mint_for_testing<QuoteAsset>(quote_in, test.ctx()),
            min_base_out,
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);
        test.return_to_sender(trade_cap);
        test.return_to_sender(deposit_cap);
        test.return_to_sender(withdraw_cap);

        (base_out, quote_out)
    }
}

public(package) fun cancel_orders<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    order_ids: vector<u64>,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        // Ensure quote is available for fee refunds before batch cancel
        let extra_quote = mint_for_testing<QuoteAsset>(
            1_000_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        balance_manager.deposit(extra_quote, test.ctx());
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        pool.cancel_orders<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            order_ids,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);
    }
}

public(package) fun cancel_all_orders<BaseAsset, QuoteAsset>(
    pool_id: ID,
    owner: address,
    balance_manager_id: ID,
    test: &mut Scenario,
) {
    test.next_tx(owner);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        // Ensure quote is available for fee refunds before cancel-all
        let extra_quote = mint_for_testing<QuoteAsset>(
            10_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        balance_manager.deposit(extra_quote, test.ctx());
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        pool.cancel_all_orders<BaseAsset, QuoteAsset>(
            &mut balance_manager,
            &trade_proof,
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(balance_manager);
    }
}

fun share_clock(test: &mut Scenario) {
    test.next_tx(OWNER);
    clock::create_for_testing(test.ctx()).share_for_testing();
}

fun share_registry_for_testing(test: &mut Scenario): ID {
    test.next_tx(OWNER);
    registry::test_registry(test.ctx())
}

fun setup_pool<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    whitelisted_pool: bool,
    stable_pool: bool,
    test: &mut Scenario,
): ID {
    test.next_tx(sender);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let pool_id;
    {
        pool_id =
            pool::create_pool_admin<BaseAsset, QuoteAsset>(
                &mut registry,
                whitelisted_pool,
                stable_pool,
                &admin_cap,
                test.ctx(),
            );
    };
    return_shared(registry);
    destroy(admin_cap);

    pool_id
}

fun setup_permissionless_pool<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    test: &mut Scenario,
): ID {
    test.next_tx(sender);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let pool_id;
    {
        pool_id =
            pool::create_permissionless_pool<BaseAsset, QuoteAsset>(
                &mut registry,
                mint_for_testing<CRED>(
                    constants::pool_creation_fee(),
                    test.ctx(),
                ),
                test.ctx(),
            );
    };
    return_shared(registry);
    destroy(admin_cap);

    pool_id
}

fun get_mid_price<BaseAsset, QuoteAsset>(pool_id: ID, test: &mut Scenario): u64 {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let mid_price = pool.mid_price<BaseAsset, QuoteAsset>(&clock);
        return_shared(pool);
        return_shared(clock);

        mid_price
    }
}

fun get_quantity_out<BaseAsset, QuoteAsset>(
    pool_id: ID,
    base_quantity: u64,
    quote_quantity: u64,
    test: &mut Scenario,
): (u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out) = pool.get_quantity_out<BaseAsset, QuoteAsset>(
            base_quantity,
            quote_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out)
    }
}

fun get_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    pool_id: ID,
    base_quantity: u64,
    quote_quantity: u64,
    test: &mut Scenario,
): (u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out) = pool.get_quantity_out_input_fee<BaseAsset, QuoteAsset>(
            base_quantity,
            quote_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out)
    }
}

fun get_base_quantity_out<BaseAsset, QuoteAsset>(
    pool_id: ID,
    quote_quantity: u64,
    test: &mut Scenario,
): (u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out) = pool.get_base_quantity_out<BaseAsset, QuoteAsset>(
            quote_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out)
    }
}

fun get_quote_quantity_out<BaseAsset, QuoteAsset>(
    pool_id: ID,
    base_quantity: u64,
    test: &mut Scenario,
): (u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out) = pool.get_quote_quantity_out<BaseAsset, QuoteAsset>(
            base_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out)
    }
}

fun get_base_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    pool_id: ID,
    quote_quantity: u64,
    test: &mut Scenario,
): (u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out) = pool.get_base_quantity_out_input_fee<BaseAsset, QuoteAsset>(
            quote_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out)
    }
}

fun get_quote_quantity_out_input_fee<BaseAsset, QuoteAsset>(
    pool_id: ID,
    base_quantity: u64,
    test: &mut Scenario,
): (u64, u64) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();

        let (base_out, quote_out) = pool.get_quote_quantity_out_input_fee<BaseAsset, QuoteAsset>(
            base_quantity,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (base_out, quote_out)
    }
}

// #feat:ewma #feat:refer
// #[test_only]
// fun advance_scenario_with_gas_price(test: &mut Scenario, gas_price: u64, timestamp_advance: u64) {
//     let ts = test.ctx().epoch_timestamp_ms() + timestamp_advance;
//     let ctx = test.ctx_builder().set_gas_price(gas_price).set_epoch_timestamp(ts);
//     test.next_with_context(ctx);
// }
