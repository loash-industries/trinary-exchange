// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Legacy compatibility shim.
///
/// The original monolithic `tests/pool_tests.move` module was migrated:
/// - Shared helpers live in `triexbook::pool_test_utils` (still in tests/).
/// - Test entrypoints live under `tests/pool/`.
///
/// This module preserves the `triexbook::pool_tests` API used by other tests
/// (notably the integration suite).
#[test_only]
module triexbook::pool_tests;

use sui::{object::ID, test_scenario::Scenario};
use triexbook::{order_info::OrderInfo, pool_test_utils};

public fun setup_everything<BaseAsset, QuoteAsset, ReferenceBaseAsset, ReferenceQuoteAsset>(
    test: &mut Scenario,
): ID {
    pool_test_utils::setup_everything<
        BaseAsset,
        QuoteAsset,
        ReferenceBaseAsset,
        ReferenceQuoteAsset,
    >(test)
}

#[test_only]
public(package) fun setup_test(owner: address, test: &mut Scenario): ID {
    pool_test_utils::setup_test(owner, test)
}

#[test_only]
public(package) fun setup_reference_pool<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    cred_multiplier: u64,
    test: &mut Scenario,
): ID {
    pool_test_utils::setup_reference_pool<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        balance_manager_id,
        cred_multiplier,
        test,
    )
}

#[test_only]
public(package) fun setup_reference_pool_cred_as_base<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    balance_manager_id: ID,
    cred_multiplier: u64,
    test: &mut Scenario,
): ID {
    pool_test_utils::setup_reference_pool_cred_as_base<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        balance_manager_id,
        cred_multiplier,
        test,
    )
}

#[test_only]
public(package) fun setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    whitelisted_pool: bool,
    stable_pool: bool,
    test: &mut Scenario,
): ID {
    pool_test_utils::setup_pool_with_default_fees<BaseAsset, QuoteAsset>(
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
    pool_test_utils::setup_pool_with_stable_fees<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        whitelisted_pool,
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
    pool_test_utils::setup_pool_with_default_fees_return_fee<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        whitelisted_pool,
        test,
    )
}

#[test_only]
public(package) fun setup_default_permissionless_pool<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    test: &mut Scenario,
): ID {
    pool_test_utils::setup_default_permissionless_pool<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        test,
    )
}

#[test_only]
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
    pool_test_utils::place_limit_order<BaseAsset, QuoteAsset>(
        trader,
        pool_id,
        balance_manager_id,
        order_type,
        self_matching_option,
        price,
        quantity,
        is_bid,
        expire_timestamp,
        test,
    )
}

#[test_only]
public(package) fun place_market_order<BaseAsset, QuoteAsset>(
    trader: address,
    pool_id: ID,
    balance_manager_id: ID,
    self_matching_option: u8,
    quantity: u64,
    is_bid: bool,
    test: &mut Scenario,
): OrderInfo {
    pool_test_utils::place_market_order<BaseAsset, QuoteAsset>(
        trader,
        pool_id,
        balance_manager_id,
        self_matching_option,
        quantity,
        is_bid,
        test,
    )
}

#[test_only]
public(package) fun cancel_order<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    order_id: u64,
    test: &mut Scenario,
) {
    pool_test_utils::cancel_order<BaseAsset, QuoteAsset>(
        sender,
        pool_id,
        balance_manager_id,
        order_id,
        test,
    )
}

#[test_only]
public(package) fun set_time(current_time: u64, test: &mut Scenario) {
    pool_test_utils::set_time(current_time, test)
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
    pool_test_utils::modify_order<BaseAsset, QuoteAsset>(
        sender,
        pool_id,
        balance_manager_id,
        order_id,
        new_quantity,
        test,
    )
}

#[test_only]
public(package) fun get_time(test: &mut Scenario): u64 {
    pool_test_utils::get_time(test)
}

#[test_only]
public(package) fun validate_open_orders<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    expected_open_orders: u64,
    test: &mut Scenario,
) {
    pool_test_utils::validate_open_orders<BaseAsset, QuoteAsset>(
        sender,
        pool_id,
        balance_manager_id,
        expected_open_orders,
        test,
    )
}

#[test_only]
public(package) fun unregister_pool<BaseAsset, QuoteAsset>(
    pool_id: ID,
    registry_id: ID,
    test: &mut Scenario,
) {
    pool_test_utils::unregister_pool<BaseAsset, QuoteAsset>(pool_id, registry_id, test)
}

#[test_only]
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
    pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
        BaseAsset,
        QuoteAsset,
        ReferenceBaseAsset,
        ReferenceQuoteAsset,
    >(sender, registry_id, balance_manager_id, test)
}
