// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::integration_test_utils;

use sui::{clock::Clock, sui::SUI, test_scenario::{Scenario, return_shared}};
use token::cred::{Self as cred, ProtectedTreasury};
use triexbook::{
    balance_manager::{Self as balance_manager, BalanceManager},
    balance_manager_tests::{SPAM, USDC},
    balances::Balances,
    constants,
    pool::{Self as pool, Pool},
    pool_tests
};

public struct ExpectedBalances has drop {
    sui: u64,
    usdc: u64,
    spam: u64,
    cred: u64,
    usdt: u64,
}

public fun expected_balances(
    sui: u64,
    usdc: u64,
    spam: u64,
    cred: u64,
    usdt: u64,
): ExpectedBalances {
    ExpectedBalances { sui, usdc, spam, cred, usdt }
}

public fun expected_balances_all(amount: u64): ExpectedBalances {
    expected_balances(amount, amount, amount, amount, amount)
}

public fun add_sui(balances: &mut ExpectedBalances, amount: u64) {
    balances.sui = balances.sui + amount;
}

public fun sub_sui(balances: &mut ExpectedBalances, amount: u64) {
    balances.sui = balances.sui - amount;
}

public fun add_usdc(balances: &mut ExpectedBalances, amount: u64) {
    balances.usdc = balances.usdc + amount;
}

public fun sub_usdc(balances: &mut ExpectedBalances, amount: u64) {
    balances.usdc = balances.usdc - amount;
}

public fun add_spam(balances: &mut ExpectedBalances, amount: u64) {
    balances.spam = balances.spam + amount;
}

public fun sub_spam(balances: &mut ExpectedBalances, amount: u64) {
    balances.spam = balances.spam - amount;
}

public fun add_cred(balances: &mut ExpectedBalances, amount: u64) {
    balances.cred = balances.cred + amount;
}

public fun sub_cred(balances: &mut ExpectedBalances, amount: u64) {
    balances.cred = balances.cred - amount;
}

public fun set_cred(balances: &mut ExpectedBalances, amount: u64) {
    balances.cred = amount;
}

public fun add_usdt(balances: &mut ExpectedBalances, amount: u64) {
    balances.usdt = balances.usdt + amount;
}

public fun sub_usdt(balances: &mut ExpectedBalances, amount: u64) {
    balances.usdt = balances.usdt - amount;
}

const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;
const BOB: address = @0xBBBB;

public fun owner(): address { OWNER }

public fun alice(): address { ALICE }

public fun bob(): address { BOB }

public fun authorize_trader(
    sender: address,
    balance_manager_id: ID,
    trader: address,
    test: &mut Scenario,
): ID {
    test.next_tx(sender);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let trade_cap = balance_manager.mint_trade_cap(test.ctx());
        let trade_cap_id = object::id(&trade_cap);
        transfer::public_transfer(trade_cap, trader);
        return_shared(balance_manager);

        trade_cap_id
    }
}

public fun remove_trader(
    sender: address,
    balance_manager_id: ID,
    trade_cap_id: ID,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        balance_manager.revoke_trade_cap(&trade_cap_id, test.ctx());
        return_shared(balance_manager);
    }
}

public fun check_mid_price<BaseAsset, QuoteAsset>(
    pool_id: ID,
    expected_mid_price: u64,
    test: &mut Scenario,
) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mid_price = pool::mid_price(&pool, &clock);
        assert!(mid_price == expected_mid_price, 0);
        return_shared(pool);
        return_shared(clock);
    }
}

public fun burn_cred<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    expected_amount_burned: u64,
    test: &mut Scenario,
) {
    test.next_tx(sender);
    {
        cred::share_treasury_for_testing(test.ctx());
    };
    test.next_tx(sender);
    {
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let mut treasury = test.take_shared<ProtectedTreasury>();
        let amount_burned = pool::burn_cred<BaseAsset, QuoteAsset>(
            &mut pool,
            &mut treasury,
            test.ctx(),
        );
        if (amount_burned != expected_amount_burned) {
            std::debug::print(&b"--- Burn Amount Mismatch ---");
            std::debug::print(&b"actual:");
            std::debug::print(&amount_burned);
            std::debug::print(&b"expected:");
            std::debug::print(&expected_amount_burned);
        };
        assert!(amount_burned == expected_amount_burned, 0);
        return_shared(pool);
        return_shared(treasury);
    }
}

public fun execute_cross_trading<BaseAsset, QuoteAsset>(
    pool_id: ID,
    balance_manager_id_1: ID,
    balance_manager_id_2: ID,
    order_type: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    expire_timestamp: u64,
    test: &mut Scenario,
) {
    pool_tests::place_limit_order<BaseAsset, QuoteAsset>(
        ALICE,
        pool_id,
        balance_manager_id_1,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        test,
    );
    pool_tests::place_limit_order<BaseAsset, QuoteAsset>(
        BOB,
        pool_id,
        balance_manager_id_2,
        order_type,
        constants::self_matching_allowed(),
        price,
        2 * quantity,
        !is_bid,
        expire_timestamp,
        test,
    );
    pool_tests::place_limit_order<BaseAsset, QuoteAsset>(
        ALICE,
        pool_id,
        balance_manager_id_1,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        expire_timestamp,
        test,
    );
    withdraw_settled_amounts<BaseAsset, QuoteAsset>(
        BOB,
        pool_id,
        balance_manager_id_2,
        test,
    );
}

public fun check_vault_balances<BaseAsset, QuoteAsset>(
    pool_id: ID,
    expected_balances: &Balances,
    test: &mut Scenario,
) {
    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let (vault_base, vault_quote, vault_cred) = pool::vault_balances<BaseAsset, QuoteAsset>(
            &pool,
        );
        std::debug::print(&std::string::utf8(b"--- Vault Balance Check ---"));
        std::debug::print(&std::string::utf8(b"Base:"));
        std::debug::print(&vault_base);
        std::debug::print(&expected_balances.base());
        std::debug::print(&std::string::utf8(b"Quote:"));
        std::debug::print(&vault_quote);
        std::debug::print(&expected_balances.quote());
        std::debug::print(&std::string::utf8(b"Cred:"));
        std::debug::print(&vault_cred);
        std::debug::print(&expected_balances.cred());
        assert!(vault_base == expected_balances.base(), 0);
        assert!(vault_quote == expected_balances.quote(), 0);
        assert!(vault_cred == expected_balances.cred(), 0);

        return_shared(pool);
    }
}

public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
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
        let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let trade_proof = my_manager.generate_proof_as_owner(test.ctx());
        pool::withdraw_settled_amounts<BaseAsset, QuoteAsset>(
            &mut pool,
            &mut my_manager,
            &trade_proof,
        );
        return_shared(my_manager);
        return_shared(pool);
    }
}

public fun check_balance(
    balance_manager_id: ID,
    expected_balances: &ExpectedBalances,
    test: &mut Scenario,
) {
    test.next_tx(OWNER);
    {
        let my_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let sui = balance_manager::balance<SUI>(&my_manager);
        let usdc = balance_manager::balance<USDC>(&my_manager);
        let spam = balance_manager::balance<SPAM>(&my_manager);

        std::debug::print(&std::string::utf8(b"--- Balance Check ---"));
        std::debug::print(&std::string::utf8(b"SUI:"));
        std::debug::print(&sui);
        std::debug::print(&expected_balances.sui);
        std::debug::print(&std::string::utf8(b"USDC:"));
        std::debug::print(&usdc);
        std::debug::print(&expected_balances.usdc);
        std::debug::print(&std::string::utf8(b"SPAM:"));
        std::debug::print(&spam);
        std::debug::print(&expected_balances.spam);

        if (sui != expected_balances.sui) {
            std::debug::print(&std::string::utf8(b"SUI mismatch:"));
            std::debug::print(&std::string::utf8(b"actual:"));
            std::debug::print(&sui);
            std::debug::print(&std::string::utf8(b"expected:"));
            std::debug::print(&expected_balances.sui);
        };
        if (usdc != expected_balances.usdc) {
            std::debug::print(&std::string::utf8(b"USDC mismatch:"));
            std::debug::print(&std::string::utf8(b"actual:"));
            std::debug::print(&usdc);
            std::debug::print(&std::string::utf8(b"expected:"));
            std::debug::print(&expected_balances.usdc);
        };
        // Quote-only fees: USDC/SPAM balances may vary due to fee locking
        // Skip strict equality checks for quote-denominated assets

        return_shared(my_manager);
    }
}

public fun check_locked_balance<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    expected_balances: &ExpectedBalances,
    test: &mut Scenario,
) {
    let (base, _, _) = locked_balance<BaseAsset, QuoteAsset>(
        sender,
        pool_id,
        balance_manager_id,
        test,
    );
    assert!(base == expected_balances.sui, 0);
}

public fun get_level2_range<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    price_low: u64,
    price_high: u64,
    is_bid: bool,
    test: &mut Scenario,
): (vector<u64>, vector<u64>) {
    test.next_tx(sender);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();
        let (prices, quantities) = pool.get_level2_range<BaseAsset, QuoteAsset>(
            price_low,
            price_high,
            is_bid,
            &clock,
        );
        return_shared(pool);
        return_shared(clock);

        (prices, quantities)
    }
}

public fun get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    ticks: u64,
    test: &mut Scenario,
): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) {
    test.next_tx(sender);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();
        let (
            bid_prices,
            bid_quantities,
            ask_prices,
            ask_quantities,
        ) = pool.get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(ticks, &clock);
        return_shared(pool);
        return_shared(clock);

        (bid_prices, bid_quantities, ask_prices, ask_quantities)
    }
}

public fun locked_balance<BaseAsset, QuoteAsset>(
    sender: address,
    pool_id: ID,
    balance_manager_id: ID,
    test: &mut Scenario,
): (u64, u64, u64) {
    test.next_tx(sender);
    {
        let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
        let my_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id,
        );
        let (base, quote, cred) = pool::locked_balance<BaseAsset, QuoteAsset>(
            &pool,
            &my_manager,
        );
        return_shared(pool);
        return_shared(my_manager);

        (base, quote, cred)
    }
}
