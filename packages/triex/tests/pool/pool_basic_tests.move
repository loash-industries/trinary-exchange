// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::pool_basic_tests;

use std::unit_test::destroy;
use sui::{sui::SUI, test_scenario::{begin, end, return_shared, Scenario}};
use token::cred::CRED;
use triexbook::{
    balance_manager_tests::{create_acct_and_share_with_funds, SPAM, USDC, USDT},
    constants,
    pool::{Self, Pool},
    pool_test_utils,
    registry::Registry
};

const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;

#[test_only]
fun place_order_case(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
        SUI,
        USDC,
        SUI,
        CRED,
    >(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    pool_test_utils::validate_open_orders<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        0,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let status = constants::live();
    let executed_quantity = 0;
    let cumulative_quote_quantity = 0;
    let paid_fees = 0;

    let order_info = pool_test_utils::place_limit_order<SUI, USDC>(
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

    pool_test_utils::verify_order_info(
        &order_info,
        price,
        quantity,
        executed_quantity,
        cumulative_quote_quantity,
        paid_fees,
        status,
        expire_timestamp,
    );

    pool_test_utils::borrow_and_verify_book_order<SUI, USDC>(
        pool_id,
        order_info.order_id(),
        is_bid,
        quantity,
        executed_quantity,
        test.ctx().epoch(),
        status,
        expire_timestamp,
        &mut test,
    );

    pool_test_utils::validate_open_orders<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        1,
        &mut test,
    );
    end(test);
}

#[test_only]
fun place_and_cancel_order_case(is_bid: bool) {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
        SUI,
        USDC,
        SUI,
        CRED,
    >(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    let executed_quantity = 0;
    let cumulative_quote_quantity = 0;
    let paid_fees = 0;
    let status = constants::live();

    let order_info = pool_test_utils::place_limit_order<SUI, USDC>(
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

    pool_test_utils::verify_order_info(
        &order_info,
        price,
        quantity,
        executed_quantity,
        cumulative_quote_quantity,
        paid_fees,
        status,
        expire_timestamp,
    );

    pool_test_utils::cancel_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info.order_id(),
        &mut test,
    );

    end(test);
}

#[test_only]
fun update_pool_book_params_case() {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = pool_test_utils::setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );

    let alice_quantity_1 = 1_000_000;
    let alice_quantity_2 = 1_010_000;
    let alice_price = 2 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    pool_test_utils::place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity_1,
        true,
        expire_timestamp,
        &mut test,
    );

    // Tests for adjust_lot_size_admin removed - lot_size feature removed

    pool_test_utils::place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price,
        alice_quantity_2,
        true,
        expire_timestamp,
        &mut test,
    );
    // adjust_tick_size_admin removed with tick_size
    pool_test_utils::place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        alice_price + 100,
        alice_quantity_2,
        true,
        expire_timestamp,
        &mut test,
    );

    end(test);
}

#[test_only]
fun place_cancel_whitelisted_pool_case() {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);

    let pool_id = pool_test_utils::setup_pool_with_default_fees<SUI, CRED>(
        OWNER,
        registry_id,
        true,
        false,
        &mut test,
    );
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let order_info_1 = pool_test_utils::place_limit_order<SUI, CRED>(
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

    pool_test_utils::cancel_order<SUI, CRED>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info_1.order_id(),
        &mut test,
    );

    let order_info_2 = pool_test_utils::place_limit_order<SUI, CRED>(
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

    pool_test_utils::cancel_order<SUI, CRED>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info_2.order_id(),
        &mut test,
    );

    let order_info_3 = pool_test_utils::place_limit_order<SUI, CRED>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::cred_multiplier(),
        1 * constants::float_scaling(),
        false,
        constants::max_u64(),
        &mut test,
    );

    pool_test_utils::cancel_order<SUI, CRED>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info_3.order_id(),
        &mut test,
    );

    let order_info_4 = pool_test_utils::place_limit_order<SUI, CRED>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        constants::cred_multiplier(),
        1 * constants::float_scaling(),
        false,
        constants::max_u64(),
        &mut test,
    );

    pool_test_utils::cancel_order<SUI, CRED>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        order_info_4.order_id(),
        &mut test,
    );

    end(test);
}

#[test_only]
fun create_pool_case(whitelisted_pool: bool, stable_pool: bool) {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
    pool_test_utils::setup_pool_with_default_fees<SUI, CRED>(
        OWNER,
        registry_id,
        whitelisted_pool,
        stable_pool,
        &mut test,
    );
    end(test);
}

#[test_only]
fun create_pool_unapproved_quote_case() {
    // Create a registry without adding approved quotes
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_registry_without_approved_quotes(OWNER, &mut test);

    // Try to create a pool without approving USDC as quote - should fail
    pool_test_utils::setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );

    end(test);
}

#[test_only]
fun unregister_pool_case(unregister: bool) {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
    let pool_id = pool_test_utils::setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );

    if (unregister) {
        pool_test_utils::unregister_pool<SUI, USDC>(pool_id, registry_id, &mut test);
    };

    pool_test_utils::setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );

    end(test);
}

#[test_only]
fun get_pool_id_by_asset_case() {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
    let pool_id_1 = pool_test_utils::setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );
    let pool_id_2 = pool_test_utils::setup_pool_with_default_fees<SPAM, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );

    test.next_tx(OWNER);
    {
        let registry = test.take_shared_by_id<Registry>(registry_id);
        let pool_id_1_returned = pool::get_pool_id_by_asset<SUI, USDC>(&registry);
        let pool_id_2_returned = pool::get_pool_id_by_asset<SPAM, USDC>(&registry);
        return_shared(registry);

        assert!(pool_id_1 == pool_id_1_returned, constants::e_incorrect_pool_id());
        assert!(pool_id_2 == pool_id_2_returned, constants::e_incorrect_pool_id());
    };

    end(test);
}

#[test_only]
fun add_stablecoin<T>(sender: address, registry_id: ID, test: &mut Scenario) {
    test.next_tx(sender);
    let admin_cap = triexbook::registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    {
        triexbook::registry::add_stablecoin<T>(&mut registry, &admin_cap);
    };
    return_shared(registry);
    destroy(admin_cap);
}

#[test_only]
fun remove_stablecoin<T>(sender: address, registry_id: ID, test: &mut Scenario) {
    test.next_tx(sender);
    let admin_cap = triexbook::registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    {
        triexbook::registry::remove_stablecoin<T>(&mut registry, &admin_cap);
    };
    return_shared(registry);
    destroy(admin_cap);
}

#[test_only]
fun assert_pool_whitelisted<BaseAsset, QuoteAsset>(
    pool_id: ID,
    whitelisted: bool,
    test: &mut Scenario,
) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        assert!(pool.whitelisted() == whitelisted, 0);
        return_shared(pool);
    }
}

#[test_only]
fun permissionless_pools_case() {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);

    // Only 1 coin is stable
    add_stablecoin<USDC>(OWNER, registry_id, &mut test);
    let pool_id_1 = pool_test_utils::setup_default_permissionless_pool<SUI, USDC>(
        OWNER,
        registry_id,
        &mut test,
    );
    assert_pool_whitelisted<SUI, USDC>(pool_id_1, false, &mut test);

    let pool_id_2 = pool_test_utils::setup_default_permissionless_pool<USDT, USDC>(
        OWNER,
        registry_id,
        &mut test,
    );
    assert_pool_whitelisted<USDT, USDC>(pool_id_2, false, &mut test);

    // Now both coins are stable
    pool_test_utils::unregister_pool<USDT, USDC>(pool_id_2, registry_id, &mut test);
    add_stablecoin<USDT>(OWNER, registry_id, &mut test);
    let pool_id_2 = pool_test_utils::setup_default_permissionless_pool<USDT, USDC>(
        OWNER,
        registry_id,
        &mut test,
    );
    assert_pool_whitelisted<USDT, USDC>(pool_id_2, false, &mut test);

    let pool_id_3 = pool_test_utils::setup_default_permissionless_pool<CRED, USDC>(
        OWNER,
        registry_id,
        &mut test,
    );
    assert_pool_whitelisted<CRED, USDC>(pool_id_3, false, &mut test);

    end(test);
}

#[test_only]
fun adding_duplicate_stablecoin_case() {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);

    add_stablecoin<USDC>(OWNER, registry_id, &mut test);
    add_stablecoin<USDC>(OWNER, registry_id, &mut test);

    end(test);
}

#[test_only]
fun removing_not_whitelisted_stablecoin_case() {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);

    add_stablecoin<USDC>(OWNER, registry_id, &mut test);
    remove_stablecoin<USDT>(OWNER, registry_id, &mut test);

    end(test);
}

#[test_only]
fun place_order_max_restrictions_case() {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
        SUI,
        USDC,
        SUI,
        CRED,
    >(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    let order_type = constants::max_restriction() + 1;
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();

    pool_test_utils::place_limit_order<SUI, USDC>(
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

#[test_only]
fun place_and_cancel_order_empty_case() {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
        SUI,
        USDC,
        SUI,
        CRED,
    >(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = constants::max_u64();
    let is_bid = true;

    let placed_order_id = pool_test_utils::place_limit_order<SUI, USDC>(
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
    ).order_id();
    pool_test_utils::cancel_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        placed_order_id,
        &mut test,
    );
    pool_test_utils::cancel_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        placed_order_id,
        &mut test,
    );
    end(test);
}

#[test_only]
fun place_order_expired_order_skipped_case() {
    let mut test = begin(OWNER);
    let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
        SUI,
        USDC,
        SUI,
        CRED,
    >(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    pool_test_utils::set_time(100, &mut test);

    let order_type = constants::no_restriction();
    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let expire_timestamp = 0;
    let is_bid = true;

    pool_test_utils::place_limit_order<SUI, USDC>(
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
    end(test);
}

#[test]
fun test_place_order_bid() {
    place_order_case(true);
}

#[test]
fun test_place_order_ask() {
    place_order_case(false);
}

#[test]
fun test_place_and_cancel_order_bid() {
    place_and_cancel_order_case(true);
}

#[test]
fun test_place_and_cancel_order_ask() {
    place_and_cancel_order_case(false);
}

#[test]
fun test_update_pool_book_params_ok() {
    update_pool_book_params_case();
}

#[test]
fun test_place_cancel_whitelisted_pool() {
    place_cancel_whitelisted_pool_case();
}

#[test, expected_failure(abort_code = ::triexbook::pool::EPoolCannotBeBothWhitelistedAndStable)]
fun test_create_pool_e() {
    create_pool_case(true, true);
}

#[test, expected_failure(abort_code = ::triexbook::pool::EQuoteNotApproved)]
fun test_create_pool_unapproved_quote_e() {
    create_pool_unapproved_quote_case();
}

#[test]
fun test_create_pool_1_ok() {
    create_pool_case(false, true);
}

#[test]
fun test_create_pool_2_ok() {
    create_pool_case(true, false);
}

#[test]
fun test_create_pool_3_ok() {
    create_pool_case(false, false);
}

#[test]
fun test_unregister_pool_ok() {
    unregister_pool_case(true);
}

#[test, expected_failure(abort_code = ::triexbook::registry::EPoolAlreadyExists)]
fun test_duplicate_pool_e() {
    unregister_pool_case(false);
}

#[test]
fun test_get_pool_id_by_asset_ok() {
    get_pool_id_by_asset_case();
}

#[test]
fun test_permissionless_pools() {
    permissionless_pools_case();
}

#[test, expected_failure(abort_code = ::triexbook::registry::ECoinAlreadyWhitelisted)]
fun test_adding_duplicate_stablecoin_e() {
    adding_duplicate_stablecoin_case();
}

#[test, expected_failure(abort_code = ::triexbook::registry::ECoinNotWhitelisted)]
fun test_removing_not_whitelisted_stablecoin_e() {
    removing_not_whitelisted_stablecoin_case();
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EInvalidOrderType)]
fun test_place_order_max_restrictions_e() {
    place_order_max_restrictions_case();
}

#[test, expected_failure(abort_code = ::triexbook::book::EBookOrderNotFound)]
fun test_place_and_cancel_order_empty_e() {
    place_and_cancel_order_empty_case();
}

#[test, expected_failure(abort_code = ::triexbook::order_info::EInvalidExpireTimestamp)]
fun test_place_order_expired_order_skipped() {
    place_order_expired_order_skipped_case();
}
