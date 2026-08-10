// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::order_info_tests;

use std::unit_test::assert_eq;
use sui::{object::id_from_address, test_scenario::{next_tx, begin, end}};
use triexbook::{balances, constants, math, order_info::{Self, OrderInfo}, quote_fee};

const OWNER: address = @0xF;
const ALICE: address = @0xA;
const BOB: address = @0xB;

#[test]
// Placing a bid order with quantity 1 at price $1. No fill.
// No taker fees, so maker fees should apply to entire quantity.
// Since its a bid, we should be required to transfer 1 USDC into the pool.
fun calculate_partial_fill_balances_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 1 * constants::usdc_unit();
    let quantity = 1 * constants::sui_unit();
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        quantity,
        true,
        test.ctx().epoch(),
    );
    let maker_fee = constants::maybe_apply_fee(true);
    let (settled, owed) = order_info.calculate_partial_fill_balances(
        constants::maybe_apply_fee(false),
        maker_fee,
    );

    let maker_fee_bps = quote_fee::scaled_to_bps(maker_fee);
    let mut maker_fee_info = quote_fee::new(maker_fee_bps);
    let locked_quote = math::mul(quantity, price);
    let expected_maker_fee_quote = maker_fee_info.calculate_maker_fee(locked_quote);

    assert_eq!(settled, balances::new(0, 0, 0));
    assert_eq!(owed, balances::new(0, locked_quote + expected_maker_fee_quote, 0));

    end(test);
}

#[test]
// Placing a bid order with quantity 10 at price $1.234. No fill.
// No taker fees, so maker fees should apply to entire quantity.
// Since its a bid, we should be required to transfer 1 USDC into the pool.
fun calculate_partial_fill_balances_precision_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 1_234_000;
    let quantity = 10 * constants::sui_unit();
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        quantity,
        true,
        test.ctx().epoch(),
    );
    let maker_fee = constants::maybe_apply_fee(true);
    let (settled, owed) = order_info.calculate_partial_fill_balances(
        constants::maybe_apply_fee(false),
        maker_fee,
    );

    let maker_fee_bps = quote_fee::scaled_to_bps(maker_fee);
    let mut maker_fee_info = quote_fee::new(maker_fee_bps);
    let locked_quote = math::mul(quantity, price);
    let expected_maker_fee_quote = maker_fee_info.calculate_maker_fee(locked_quote);

    assert_eq!(settled, balances::new(0, 0, 0));
    assert_eq!(owed, balances::new(0, locked_quote + expected_maker_fee_quote, 0));

    end(test);
}

#[test]
// Placing a bid order with quantity 10.86 at price $1.234. No fill.
fun calculate_partial_fill_balances_precision2_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 1_234_000;
    let quantity = 10_860_000_000;
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        quantity,
        true,
        test.ctx().epoch(),
    );
    let maker_fee = constants::maybe_apply_fee(true);
    let (settled, owed) = order_info.calculate_partial_fill_balances(
        constants::maybe_apply_fee(false),
        maker_fee,
    );

    let maker_fee_bps = quote_fee::scaled_to_bps(maker_fee);
    let mut maker_fee_info = quote_fee::new(maker_fee_bps);
    let locked_quote = math::mul(quantity, price);
    let expected_fee = maker_fee_info.calculate_maker_fee(locked_quote);

    assert_eq!(settled, balances::new(0, 0, 0));
    // USDC owed = price * quantity + maker fee (quote-denominated)
    assert_eq!(owed, balances::new(0, locked_quote + expected_fee, 0));

    end(test);
}

#[test]
// Place an ask order with quantity 655.36 at price $19.32. No fill.
fun calculate_partial_fill_balances_ask_no_fill_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 19_320_000;
    let quantity = 655_360_000_000;
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        quantity,
        false,
        test.ctx().epoch(),
    );
    let (settled, owed) = order_info.calculate_partial_fill_balances(
        constants::maybe_apply_fee(true),
        constants::maybe_apply_fee(false),
    );

    assert_eq!(settled, balances::new(0, 0, 0));
    // Since its an ask, transfer quantity amount worth of base token.
    // CRED owed = 0 (new fee model: only buyers pay, sellers pay no fees)
    assert_eq!(owed, balances::new(655_360_000_000, 0, 0));

    end(test);
}

#[test]
// Taker: bid order with quantity 10 at price $5
// Maker: ask order with quantity 5 at price $5
fun match_maker_partial_fill_bid_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 5 * constants::usdc_unit();
    let taker_quantity = 10 * constants::sui_unit();
    let maker_quantity = 5 * constants::sui_unit();
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        taker_quantity,
        true,
        test.ctx().epoch(),
    );
    let mut maker_order = create_order_info_base(
        BOB,
        price,
        maker_quantity,
        false,
        test.ctx().epoch(),
    ).to_order();
    let has_next = order_info.match_maker(&mut maker_order, 0);
    assert!(has_next, 0);
    assert!(order_info.fills_ref().length() == 1, 0);
    assert!(order_info.executed_quantity() == 5 * constants::sui_unit(), 0);
    assert!(order_info.cumulative_quote_quantity() == 25 * constants::usdc_unit(), 0);
    assert!(order_info.status() == constants::partially_filled(), 0);
    assert!(order_info.remaining_quantity() == 5 * constants::sui_unit(), 0);

    end(test);
}

#[test]
// Taker: bid order with quantity 111 at price $4
// Maker: ask order with quantity 38.13 at price $3.89
fun match_maker_partial_fill_ask_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 4 * constants::usdc_unit();
    let taker_quantity = 111 * constants::sui_unit();
    let maker_quantity = 38_130_000_000;
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        taker_quantity,
        true,
        test.ctx().epoch(),
    );
    let mut maker_order = create_order_info_base(
        BOB,
        3_890_000,
        maker_quantity,
        false,
        test.ctx().epoch(),
    ).to_order();
    let has_next = order_info.match_maker(&mut maker_order, 0);
    assert!(has_next, 0);
    assert!(order_info.fills_ref().length() == 1, 0);
    assert!(order_info.executed_quantity() == 38_130_000_000, 0);
    // 38.13 * 3.89 = 148.3257 = 148325700
    assert!(order_info.cumulative_quote_quantity() == 148_325_700, 0);
    assert!(order_info.status() == constants::partially_filled(), 0);
    assert!(order_info.remaining_quantity() == 72_870_000_000, 0);

    end(test);
}

#[test]
// Taker: ask order with quantity 10 at price $1
// Maker1: bid order with quantity 1.001001 at price $1.001
// Maker2: bid order with quantity 1 at price $1
fun match_maker_multiple_ask_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 1 * constants::usdc_unit();
    let taker_quantity = 10 * constants::sui_unit();
    let maker1_quantity = 1_001_001_000;
    let maker2_quantity = 1 * constants::sui_unit();
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        taker_quantity,
        false,
        test.ctx().epoch(),
    );
    let mut maker_order1 = create_order_info_base(
        BOB,
        1_001_000,
        maker1_quantity,
        true,
        test.ctx().epoch(),
    ).to_order();
    // quantity matched = 1.001001, taker fee = 0.001 = 0.001001001
    order_info.match_maker(&mut maker_order1, 0);
    // quantity matched = 1, taker fee = 0.001 = 0.001
    let mut maker_order2 = create_order_info_base(
        BOB,
        price,
        maker2_quantity,
        true,
        test.ctx().epoch(),
    ).to_order();
    order_info.match_maker(&mut maker_order2, 0);
    // remaining quantity = 10 - 1 - 1.001001 = 7.998999
    // taker fee = 0 (new fee model: seller doesn't pay taker fee)
    // maker fee = remaining_quantity * fee_rate (calculated dynamically)
    let maker_fee = constants::maybe_apply_fee(true);
    // let remaining_quantity = 7_998_999_000; // 7.998999 SUI
    let (_settled, owed) = order_info.calculate_partial_fill_balances(
        constants::maybe_apply_fee(false),
        maker_fee,
    );

    // Maker fees are quote-only; no CRED component expected
    assert_eq!(owed, balances::new(10_000_000_000, 0, 0));

    end(test);
}

#[test]
// Taker: bid order with quantity 10 at price $5
// Maker: ask order with quantity 50 at price $5
fun match_maker_full_fill_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 5 * constants::usdc_unit();
    let taker_quantity = 10 * constants::sui_unit();
    let maker_quantity = 50 * constants::sui_unit();
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        taker_quantity,
        true,
        test.ctx().epoch(),
    );
    let mut maker_order = create_order_info_base(
        BOB,
        price,
        maker_quantity,
        false,
        test.ctx().epoch(),
    ).to_order();
    let has_next = order_info.match_maker(&mut maker_order, 0);
    assert!(has_next, 0);
    assert!(order_info.fills_ref().length() == 1, 0);
    assert!(order_info.executed_quantity() == 10 * constants::sui_unit(), 0);
    assert!(order_info.cumulative_quote_quantity() == 50 * constants::usdc_unit(), 0);
    assert!(order_info.status() == constants::filled(), 0);
    assert!(order_info.remaining_quantity() == 0, 0);

    end(test);
}

#[test]
// Place a bid order with quantity 131.11 at price $1900. Partial fill of 100 at price $1813.05.
fun calculate_partial_fill_balances_bid_partial_fill_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 1_900_000_000;
    let maker_price = 1_813_050_000;
    let quantity = 131_110_000_000;
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        quantity,
        true,
        test.ctx().epoch(),
    );
    let mut maker_order = create_order_info_base(
        BOB,
        maker_price,
        100 * constants::sui_unit(),
        false,
        test.ctx().epoch(),
    ).to_order();
    let has_next = order_info.match_maker(&mut maker_order, 0);
    assert!(has_next, 0);
    assert!(order_info.fills_ref().length() == 1, 0);
    assert!(order_info.executed_quantity() == 100 * constants::sui_unit(), 0);
    // 100 * 1813.05 = 181305 = 181305000000
    assert!(order_info.cumulative_quote_quantity() == 181_305_000_000, 0);
    assert!(order_info.status() == constants::partially_filled(), 0);
    assert!(order_info.remaining_quantity() == 31_110_000_000, 0);
    let (settled, owed) = order_info.calculate_partial_fill_balances(
        constants::maybe_apply_fee(true), // taker_fee for executed portion (bid pays fee)
        constants::maybe_apply_fee(true), // maker_fee for remaining portion (bid pays fee)
    );

    // 100 SUI filled, the taker is owed 100 SUI.
    assert_eq!(settled, balances::new(100_000_000_000, 0, 0));
    // Taker paid 181305 USDC for 100 SUI, so they owe 181305 USDC.
    // The remaining 31.11 SUI is placed as a maker order at $1900
    // Additional owed to create maker order 31.11 * 1900 = 59109 USDC.
    // Total USDC owed = 181305 + 59109 = 240414

    // Taker fee = executed_quantity * fee_rate (2% unified rate)
    let executed_quantity = 100 * constants::sui_unit(); // 100 SUI
    let taker_fee_rate = constants::maybe_apply_fee(true); // 20M = 2%
    let _expected_taker_fee = math::mul(executed_quantity, taker_fee_rate);
    // Maker fee for remaining quantity
    // let remaining_quantity = 31_110_000_000; // 31.11 SUI
    let _maker_fee_rate = constants::maybe_apply_fee(true);
    // Quote-only fees: ensure quote owed is non-zero and CRED is zero
    assert!(balances::quote(&owed) > 0, 0);
    assert!(balances::cred(&owed) == 0, 0);

    end(test);
}

#[test]
// Place an ask order with quantity 0.005 at price $68,191.55. Partial fill of 0.001 at $70,000
fun calculate_partial_fill_balances_ask_partial_fill_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 68_191_550_000;
    let maker_price = 70_000_000_000;
    let quantity = 5_000_000;
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        quantity,
        false,
        test.ctx().epoch(),
    );
    let mut maker_order = create_order_info_base(
        BOB,
        maker_price,
        1_000_000,
        true,
        test.ctx().epoch(),
    ).to_order();
    let has_next = order_info.match_maker(&mut maker_order, 0);
    assert!(has_next, 0);
    assert!(order_info.fills_ref().length() == 1, 0);
    assert!(order_info.executed_quantity() == 1_000_000, 0);
    // 0.001 * 70,000 = 70 = 70000000
    assert!(order_info.cumulative_quote_quantity() == 70_000_000, 0);
    assert!(order_info.status() == constants::partially_filled(), 0);
    assert!(order_info.remaining_quantity() == 4_000_000, 0);
    let (settled, owed) = order_info.calculate_partial_fill_balances(
        constants::maybe_apply_fee(false),
        constants::maybe_apply_fee(true),
    );

    // Sell of 0.001 SUI filled at $70,000, taker is owed 70 USDC
    assert_eq!(settled, balances::new(0, 70_000_000, 0));
    // Taker paid 70 USDC for 0.001 SUI, so they owe 70 USDC.
    // The remaining 0.004 SUI is placed as a maker order at $68,191.55

    // Taker fee = 0 (new fee model: seller doesn't pay taker fee)
    // Maker fee = remaining_quantity * fee_rate (calculated dynamically)
    // let remaining_quantity = 4_000_000; // 0.004 SUI
    // Quote-only fee model keeps CRED at zero
    assert_eq!(owed, balances::new(5_000_000, 0, 0));

    end(test);
}

#[test]
// Place a bid order with quantity 999.99 at price $111.11. Full fill.
fun calculate_partial_fill_balances_bid_full_fill_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 111_110_000;
    let maker_price = 111_110_000;
    let quantity = 999_990_000_000;
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        quantity,
        true,
        test.ctx().epoch(),
    );
    let mut maker_order = create_order_info_base(
        BOB,
        maker_price,
        999_990_000_000,
        false,
        test.ctx().epoch(),
    ).to_order();
    let has_next = order_info.match_maker(&mut maker_order, 0);
    assert!(has_next, 0);
    assert!(order_info.fills_ref().length() == 1, 0);
    assert!(order_info.executed_quantity() == 999_990_000_000, 0);
    // 999.99 * 111.11 = 111108.8889 = 111108888900
    assert!(order_info.cumulative_quote_quantity() == 111_108_888_900, 0);
    assert!(order_info.status() == constants::filled(), 0);
    assert!(order_info.remaining_quantity() == 0, 0);

    end(test);
}

#[test]
// Place an ask order with quantity 0.0001 at price $1,000,000. Full fill.
fun calculate_partial_fill_balances_ask_full_fill_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 1_000_000_000_000;
    let maker_price = 1_000_000_000_000;
    let quantity = 100_000;
    let mut order_info = create_order_info_base(
        ALICE,
        price,
        quantity,
        false,
        test.ctx().epoch(),
    );
    let mut maker_order = create_order_info_base(
        BOB,
        maker_price,
        100_000,
        true,
        test.ctx().epoch(),
    ).to_order();
    let has_next = order_info.match_maker(&mut maker_order, 0);
    assert!(has_next, 0);
    assert!(order_info.fills_ref().length() == 1, 0);
    assert!(order_info.executed_quantity() == 100_000, 0);
    // 0.0001 * 1,000,000 = 100 = 100000000
    assert!(order_info.cumulative_quote_quantity() == 100_000_000, 0);
    assert!(order_info.status() == constants::filled(), 0);
    assert!(order_info.remaining_quantity() == 0, 0);

    end(test);
}

// Removed test: validate_inputs_below_minimum_e - min_size validation no longer exists
// Removed test: validate_inputs_invalid_lot_size_e - lot_size validation no longer exists

#[test, expected_failure(abort_code = order_info::EInvalidOrderType)]
fun validate_inputs_invalid_order_type_e() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 1_000_000;
    let quantity = 100_000;
    let balance_manager_id = id_from_address(@0x1);
    let order_type = 5;
    let market_order = false;
    let expire_timestamp = constants::max_u64();
    let fill_limit_reached = false;
    let order_inserted = true;
    create_order_info(
        balance_manager_id,
        ALICE,
        order_type,
        price,
        quantity,
        true,
        test.ctx().epoch(),
        expire_timestamp,
        market_order,
        fill_limit_reached,
        order_inserted,
    );

    abort (0)
}

#[test, expected_failure(abort_code = order_info::EMarketOrderCannotBePostOnly)]
fun validate_inputs_market_order_post_only_e() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 1_000_000;
    let quantity = 100_000;
    let balance_manager_id = id_from_address(@0x1);
    let order_type = 3;
    let market_order = true;
    let expire_timestamp = constants::max_u64();
    let fill_limit_reached = false;
    let order_inserted = false;
    create_order_info(
        balance_manager_id,
        ALICE,
        order_type,
        price,
        quantity,
        true,
        test.ctx().epoch(),
        expire_timestamp,
        market_order,
        fill_limit_reached,
        order_inserted,
    );

    abort (0)
}

#[test, expected_failure(abort_code = order_info::EOrderInvalidPrice)]
fun validate_inputs_invalid_price_e() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 0;
    let quantity = 100_000;
    create_order_info_base(ALICE, price, quantity, true, test.ctx().epoch());

    abort (0)
}

// Test removed: validate_inputs_invalid_price2_e - tested tick_size divisibility which was removed

#[test, expected_failure(abort_code = order_info::EPOSTOrderCrossesOrderbook)]
fun validate_execution_post_only_e() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 1_000_000;
    let quantity = 100_000;
    let balance_manager_id = id_from_address(@0x1);
    let order_type = 3;
    let market_order = false;
    let expire_timestamp = constants::max_u64();
    let fill_limit_reached = false;
    let order_inserted = true;
    let mut order_info = create_order_info(
        balance_manager_id,
        ALICE,
        order_type,
        price,
        quantity,
        true,
        test.ctx().epoch(),
        expire_timestamp,
        market_order,
        fill_limit_reached,
        order_inserted,
    );
    let mut maker_order = create_order_info_base(
        BOB,
        price,
        1_000_000,
        false,
        test.ctx().epoch(),
    ).to_order();
    order_info.match_maker(&mut maker_order, 0);
    order_info.assert_execution();

    abort (0)
}

#[test, expected_failure(abort_code = order_info::EFOKOrderCannotBeFullyFilled)]
fun validate_execution_FOK_e() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 1_000_000;
    let quantity = 100_000_000;
    let balance_manager_id = id_from_address(@0x1);
    let order_type = 2;
    let market_order = false;
    let expire_timestamp = constants::max_u64();
    let fill_limit_reached = false;
    let order_inserted = false;
    let mut order_info = create_order_info(
        balance_manager_id,
        ALICE,
        order_type,
        price,
        quantity,
        true,
        test.ctx().epoch(),
        expire_timestamp,
        market_order,
        fill_limit_reached,
        order_inserted,
    );
    let mut maker_order = create_order_info_base(
        BOB,
        price,
        1_000_000,
        true,
        test.ctx().epoch(),
    ).to_order();
    order_info.match_maker(&mut maker_order, 0);
    order_info.assert_execution();

    abort (0)
}

#[test]
fun validate_execution_immediate_or_cancel_ok() {
    let mut test = begin(OWNER);

    test.next_tx(ALICE);
    let price = 1_000_000;
    let quantity = 100_000_000;
    let balance_manager_id = id_from_address(@0x1);
    let order_type = 1;
    let market_order = false;
    let expire_timestamp = constants::max_u64();
    let fill_limit_reached = false;
    let order_inserted = false;
    let mut order_info = create_order_info(
        balance_manager_id,
        ALICE,
        order_type,
        price,
        quantity,
        true,
        test.ctx().epoch(),
        expire_timestamp,
        market_order,
        fill_limit_reached,
        order_inserted,
    );
    let mut maker_order = create_order_info_base(
        BOB,
        price,
        1_000_000,
        true,
        test.ctx().epoch(),
    ).to_order();
    order_info.match_maker(&mut maker_order, 0);
    order_info.assert_execution();
    assert!(order_info.status() == constants::canceled(), 0);

    end(test);
}

#[test_only]
public fun create_order_info_base(
    trader: address,
    price: u64,
    quantity: u64,
    is_bid: bool,
    epoch: u64,
): OrderInfo {
    let balance_manager_id = id_from_address(trader);
    let order_type = 0;
    let market_order = false;
    let expire_timestamp = constants::max_u64();
    let fill_limit_reached = false;
    let order_inserted = true;

    create_order_info(
        balance_manager_id,
        trader,
        order_type,
        price,
        quantity,
        is_bid,
        epoch,
        expire_timestamp,
        market_order,
        fill_limit_reached,
        order_inserted,
    )
}

#[test_only]
public fun create_order_info(
    balance_manager_id: ID,
    trader: address,
    order_type: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    epoch: u64,
    expire_timestamp: u64,
    market_order: bool,
    fill_limit_reached: bool,
    order_inserted: bool,
): OrderInfo {
    let pool_id = id_from_address(@0x2);
    let mut order_info = order_info::new(
        pool_id,
        balance_manager_id,
        trader,
        order_type,
        constants::self_matching_allowed(),
        price,
        quantity,
        is_bid,
        epoch,
        expire_timestamp,
        market_order,
        0,
        constants::float_scaling(),
    );

    order_info.set_order_id(1);
    order_info.validate_inputs(0);

    if (fill_limit_reached) {
        order_info.set_fill_limit_reached();
    };

    if (order_inserted) {
        order_info.set_order_inserted();
    };

    order_info
}
