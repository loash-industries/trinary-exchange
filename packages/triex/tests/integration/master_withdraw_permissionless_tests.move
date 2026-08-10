// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_master_withdraw_permissionless_tests;

use sui::{sui::SUI, test_scenario::{Scenario, begin, end, return_shared}};
use triexbook::{
    balance_manager::{Self, BalanceManager},
    balance_manager_tests::{Self as balance_manager_tests, USDC},
    constants,
    pool::{Self, Pool},
    pool_tests
};

// Test addresses
const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;
const BOB: address = @0xBBBB;

#[test]
fun test_withdraw_settled_amounts_permissionless_ok() {
    let mut test = begin(OWNER);
    let registry_id = pool_tests::setup_test(OWNER, &mut test);
    pool_tests::set_time(0, &mut test);

    let starting_balance = 10000 * constants::float_scaling();
    let alice_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        ALICE,
        starting_balance,
        &mut test,
    );
    let bob_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        BOB,
        starting_balance,
        &mut test,
    );

    let pool_id = pool_tests::setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );

    let price = 2 * constants::float_scaling();
    let quantity = 5 * constants::float_scaling();
    let order_type = constants::no_restriction();
    let expire_timestamp = constants::max_u64();

    // Alice places a bid order
    pool_tests::place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        alice_balance_manager_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        true, // is_bid
        expire_timestamp,
        &mut test,
    );

    // Bob places an ask order that matches Alice's bid
    pool_tests::place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        bob_balance_manager_id,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        false, // is_bid
        expire_timestamp,
        &mut test,
    );

    // Check Alice's balance before withdrawal (settled amounts not yet withdrawn)
    test.next_tx(ALICE);
    let alice_sui_before = {
        let alice_manager = test.take_shared_by_id<BalanceManager>(
            alice_balance_manager_id,
        );
        let balance = balance_manager::balance<SUI>(&alice_manager);
        return_shared(alice_manager);
        balance
    };

    // Alice now has settled balances (received SUI from the trade)
    // Bob (not the owner) calls withdraw_settled_amounts_permissionless for Alice
    withdraw_settled_amounts_permissionless<SUI, USDC>(
        BOB,
        pool_id,
        alice_balance_manager_id,
        &mut test,
    );

    // Verify Alice's balance increased by the traded quantity
    test.next_tx(ALICE);
    {
        let alice_manager = test.take_shared_by_id<BalanceManager>(
            alice_balance_manager_id,
        );
        let alice_sui_after = balance_manager::balance<SUI>(&alice_manager);

        // Alice should have received the full quantity (5 SUI) from her filled bid order
        let expected_sui_received = quantity;
        assert!(alice_sui_after == alice_sui_before + expected_sui_received, 0);

        return_shared(alice_manager);
    };

    test.end();
}

#[test, expected_failure(abort_code = ::triexbook::vault::ENoBalanceToSettle)]
fun test_withdraw_settled_amounts_permissionless_no_balance_e() {
    let mut test = begin(OWNER);
    let registry_id = pool_tests::setup_test(OWNER, &mut test);
    pool_tests::set_time(0, &mut test);

    let starting_balance = 10000 * constants::float_scaling();
    let alice_balance_manager_id = balance_manager_tests::create_acct_and_share_with_funds(
        ALICE,
        starting_balance,
        &mut test,
    );

    let pool_id = pool_tests::setup_pool_with_default_fees<SUI, USDC>(
        OWNER,
        registry_id,
        false,
        false,
        &mut test,
    );

    // Alice has no settled balances, try to withdraw
    withdraw_settled_amounts_permissionless<SUI, USDC>(
        BOB,
        pool_id,
        alice_balance_manager_id,
        &mut test,
    );

    test.end();
}

fun withdraw_settled_amounts_permissionless<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let mut my_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(
            pool_id,
        );
        pool::withdraw_settled_amounts_permissionless<BaseAsset, QuoteAsset>(
            &mut pool,
            &mut my_manager,
        );
        return_shared(my_manager);
        return_shared(pool);
    }
}
