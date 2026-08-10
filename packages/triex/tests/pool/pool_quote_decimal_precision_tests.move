// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end fee-precision tests for Pool<SUI, Qn> across quote currencies
/// of varying decimal precision.
///
/// The pool uses price_scaling = FLOAT_SCALING (1e9) for all normal pools.
/// The price encoding for a 9-decimal base (SUI) is:
///
///   price_internal = human_price × QUOTE_UNIT
///       (FLOAT_SCALING / BASE_UNIT = 1e9/1e9 = 1 cancels out)
///
///   quote_qty = math::mul(base_qty, price_internal)
///             = base_qty × price_internal / FLOAT_SCALING
///             = base_qty × human_price × QUOTE_UNIT / FLOAT_SCALING
///             = base_qty × human_price × QUOTE_UNIT / BASE_UNIT   ✓
///
/// Fee precision degrades as QUOTE_UNIT shrinks:
///   Q9 (1e9): fee = quote × 2% — always precise for any trade size
///   Q6 (1e6): fee = quote × 2% — always precise
///   Q2  (100): fee = quote × 2% — precise down to $0.50 fills
///   Q1   (10): fee = quote × 2% — truncates to 0 for fills < $5 (50 raw units)
///
/// Each test places a maker ask then a crossing taker bid, then validates
/// both OrderInfo.paid_fees() and the vault's quote_fee_reserve_balance().
#[test_only]
module triexbook::pool_quote_decimal_precision_tests;

use std::unit_test::destroy;
use sui::{
    clock::{Self, Clock},
    coin::mint_for_testing,
    sui::SUI,
    test_scenario::{begin, end, return_shared}
};
use triexbook::{
    balance_manager::{Self as balance_manager, BalanceManager},
    constants,
    math,
    pool::{Self, Pool},
    registry::{Self, Registry}
};

const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;
const BOB: address = @0xBBBB;

// Pool governance default: 2% taker fee on bids
const FEE_BPS: u64 = 200;
const FEE_PRECISION: u64 = 10_000;

// Enough to cover the largest test (100 × FLOAT_SCALING × FLOAT_SCALING quote)
const LARGE_BALANCE: u64 = 100_000_000_000_000_000;

// ── Quote phantom types ───────────────────────────────────────────────────────

/// 9-decimal quote (e.g., SUI, ETH). QUOTE_UNIT = FLOAT_SCALING = 1_000_000_000.
/// price_internal = human × 1_000_000_000
/// 1 SUI at $2 → quote = 2_000_000_000 raw Q9, fee = 40_000_000 (non-zero ✓)
public struct Q9 has store {}

/// 6-decimal quote (e.g., USDC). QUOTE_UNIT = 1_000_000.
/// price_internal = human × 1_000_000
/// 1 SUI at $2 → quote = 2_000_000 raw Q6, fee = 40_000 (non-zero ✓)
public struct Q6 has store {}

/// 2-decimal quote (e.g., JPY expressed in cents). QUOTE_UNIT = 100.
/// price_internal = human × 100
/// 1 SUI at $2 → quote = 200 raw Q2, fee = 4 (non-zero ✓)
/// Precision floor: quote < 50 raw → fee truncates to 0
public struct Q2 has store {}

/// 1-decimal quote. QUOTE_UNIT = 10.
/// price_internal = human × 10
/// 1 SUI at $25 → quote = 250 raw Q1, fee = 5 (non-zero ✓)
/// 1 SUI at $2  → quote =  20 raw Q1, fee = 0 (2% of $2 = $0.04 < 0.1 raw → truncates)
public struct Q1 has store {}

// ── Setup helpers ─────────────────────────────────────────────────────────────

fun setup_registry_and_clock(test: &mut sui::test_scenario::Scenario): ID {
    test.next_tx(OWNER);
    clock::create_for_testing(test.ctx()).share_for_testing();
    test.next_tx(OWNER);
    registry::test_registry(test.ctx())
}

/// Approve a quote type in the registry. Call once per (registry, QuoteAsset) pair.
fun approve_quote<QuoteAsset>(registry_id: ID, test: &mut sui::test_scenario::Scenario) {
    test.next_tx(OWNER);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    registry.add_approved_quote_unchecked<QuoteAsset>(&admin_cap);
    return_shared(registry);
    destroy(admin_cap);
}

/// Create a pool for a pre-approved QuoteAsset. May be called multiple times.
fun create_pool<QuoteAsset>(registry_id: ID, test: &mut sui::test_scenario::Scenario): ID {
    test.next_tx(OWNER);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let pool_id = pool::create_pool_admin<SUI, QuoteAsset>(
        &mut registry,
        true, // whitelisted
        false, // not stable
        &admin_cap,
        test.ctx(),
    );
    return_shared(registry);
    destroy(admin_cap);
    pool_id
}

fun create_funded_bm<QuoteAsset>(trader: address, test: &mut sui::test_scenario::Scenario): ID {
    test.next_tx(trader);
    let mut bm = balance_manager::new(test.ctx());
    bm.deposit(mint_for_testing<SUI>(LARGE_BALANCE, test.ctx()), test.ctx());
    bm.deposit(mint_for_testing<QuoteAsset>(LARGE_BALANCE, test.ctx()), test.ctx());
    let id = object::id(&bm);
    transfer::public_share_object(bm);
    id
}

/// Core: place a maker ask then a crossing taker bid, return (paid_fees, vault_reserve).
fun fill_and_get_fees<QuoteAsset>(
    pool_id: ID,
    alice_bm_id: ID,
    bob_bm_id: ID,
    price: u64,
    qty: u64,
    test: &mut sui::test_scenario::Scenario,
): (u64, u64) {
    // Alice: resting ask (sell SUI for QuoteAsset, no fee for asks)
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let proof = bm.generate_proof_as_owner(test.ctx());
        pool.place_limit_order(
            &mut bm,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(bm);
    };

    // Bob: crossing bid (buy SUI with QuoteAsset, taker pays 2% fee)
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, QuoteAsset>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let proof = bm.generate_proof_as_owner(test.ctx());
        let order_info = pool.place_limit_order(
            &mut bm,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        let paid_fees = order_info.paid_fees();
        let vault_reserve = pool.quote_fee_reserve_balance();
        return_shared(pool);
        return_shared(clock);
        return_shared(bm);
        (paid_fees, vault_reserve)
    }
}

// ── Q9 (9-decimal): precision never an issue ──────────────────────────────────

/// 1 SUI at $2 with 9-decimal quote.
/// price = 2 × 1e9 = 2_000_000_000
/// quote = math::mul(1e9, 2_000_000_000) = 2_000_000_000 raw Q9
/// fee   = 2_000_000_000 × 200 / 10_000 = 40_000_000
#[test]
fun test_q9_two_dollar_fill_fee_captured() {
    let mut test = begin(OWNER);
    let registry_id = setup_registry_and_clock(&mut test);
    approve_quote<Q9>(registry_id, &mut test);
    let pool_id = create_pool<Q9>(registry_id, &mut test);
    let alice_bm_id = create_funded_bm<Q9>(ALICE, &mut test);
    let bob_bm_id = create_funded_bm<Q9>(BOB, &mut test);

    let price = 2 * constants::float_scaling(); // human $2, QUOTE_UNIT = 1e9
    let qty = 1 * constants::float_scaling(); // 1 SUI

    let (paid_fees, vault_reserve) = fill_and_get_fees<Q9>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price,
        qty,
        &mut test,
    );

    let expected_quote = math::mul(qty, price); // = 2_000_000_000
    let expected_fee = expected_quote * FEE_BPS / FEE_PRECISION; // = 40_000_000

    assert!(paid_fees == expected_fee, 0);
    assert!(vault_reserve == expected_fee, 1);
    assert!(expected_fee > 0, 2);

    end(test);
}

/// 3 SUI at $5 with 9-decimal quote — larger fill, fee stays precise.
/// quote = math::mul(3e9, 5e9) = 15_000_000_000
/// fee   = 15_000_000_000 × 200 / 10_000 = 300_000_000
#[test]
fun test_q9_large_fill_fee_captured() {
    let mut test = begin(OWNER);
    let registry_id = setup_registry_and_clock(&mut test);
    approve_quote<Q9>(registry_id, &mut test);
    let pool_id = create_pool<Q9>(registry_id, &mut test);
    let alice_bm_id = create_funded_bm<Q9>(ALICE, &mut test);
    let bob_bm_id = create_funded_bm<Q9>(BOB, &mut test);

    let price = 5 * constants::float_scaling();
    let qty = 3 * constants::float_scaling();

    let (paid_fees, vault_reserve) = fill_and_get_fees<Q9>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price,
        qty,
        &mut test,
    );

    let expected_quote = math::mul(qty, price); // = 15_000_000_000
    let expected_fee = expected_quote * FEE_BPS / FEE_PRECISION; // = 300_000_000

    assert!(paid_fees == expected_fee, 0);
    assert!(vault_reserve == expected_fee, 1);

    end(test);
}

// ── Q6 (6-decimal): standard USDC precision ───────────────────────────────────

/// 1 SUI at $2 with 6-decimal quote (USDC-like).
/// price = 2 × 1e6 = 2_000_000
/// quote = math::mul(1e9, 2_000_000) = 2_000_000 raw Q6 (= $2.00 USDC)
/// fee   = 2_000_000 × 200 / 10_000 = 40_000 raw Q6 (= $0.04 USDC)
#[test]
fun test_q6_two_dollar_fill_fee_captured() {
    let mut test = begin(OWNER);
    let registry_id = setup_registry_and_clock(&mut test);
    approve_quote<Q6>(registry_id, &mut test);
    let pool_id = create_pool<Q6>(registry_id, &mut test);
    let alice_bm_id = create_funded_bm<Q6>(ALICE, &mut test);
    let bob_bm_id = create_funded_bm<Q6>(BOB, &mut test);

    let price = 2 * 1_000_000u64; // $2 with 6-decimal QUOTE_UNIT
    let qty = 1 * constants::float_scaling(); // 1 SUI

    let (paid_fees, vault_reserve) = fill_and_get_fees<Q6>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price,
        qty,
        &mut test,
    );

    let expected_quote = math::mul(qty, price); // = 2_000_000
    let expected_fee = expected_quote * FEE_BPS / FEE_PRECISION; // = 40_000

    assert!(paid_fees == expected_fee, 0);
    assert!(vault_reserve == expected_fee, 1);
    assert!(expected_fee > 0, 2);

    end(test);
}

/// 5 SUI at $1.50 with 6-decimal quote — fractional dollar price.
/// price = 1_500_000 (1.50 × 1e6)
/// quote = math::mul(5e9, 1_500_000) = 7_500_000 raw Q6
/// fee   = 7_500_000 × 200 / 10_000 = 150_000
#[test]
fun test_q6_fractional_price_fee_captured() {
    let mut test = begin(OWNER);
    let registry_id = setup_registry_and_clock(&mut test);
    approve_quote<Q6>(registry_id, &mut test);
    let pool_id = create_pool<Q6>(registry_id, &mut test);
    let alice_bm_id = create_funded_bm<Q6>(ALICE, &mut test);
    let bob_bm_id = create_funded_bm<Q6>(BOB, &mut test);

    let price = 1_500_000u64; // $1.50 with 6-decimal QUOTE_UNIT
    let qty = 5 * constants::float_scaling();

    let (paid_fees, vault_reserve) = fill_and_get_fees<Q6>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price,
        qty,
        &mut test,
    );

    let expected_quote = math::mul(qty, price); // = 7_500_000
    let expected_fee = expected_quote * FEE_BPS / FEE_PRECISION; // = 150_000

    assert!(paid_fees == expected_fee, 0);
    assert!(vault_reserve == expected_fee, 1);

    end(test);
}

// ── Q2 (2-decimal): low-decimal, precision still adequate at $0.50+ ───────────

/// 1 SUI at $2 with 2-decimal quote.
/// price = 2 × 100 = 200 raw Q2 per SUI
/// quote = math::mul(1e9, 200) = 200 raw Q2 (= $2.00)
/// fee   = 200 × 200 / 10_000 = 4 raw Q2 (= $0.04)
#[test]
fun test_q2_two_dollar_fill_fee_captured() {
    let mut test = begin(OWNER);
    let registry_id = setup_registry_and_clock(&mut test);
    approve_quote<Q2>(registry_id, &mut test);
    let pool_id = create_pool<Q2>(registry_id, &mut test);
    let alice_bm_id = create_funded_bm<Q2>(ALICE, &mut test);
    let bob_bm_id = create_funded_bm<Q2>(BOB, &mut test);

    let price = 2 * 100u64; // $2 with 2-decimal QUOTE_UNIT
    let qty = 1 * constants::float_scaling();

    let (paid_fees, vault_reserve) = fill_and_get_fees<Q2>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price,
        qty,
        &mut test,
    );

    let expected_quote = math::mul(qty, price); // = 200
    let expected_fee = expected_quote * FEE_BPS / FEE_PRECISION; // = 4

    assert!(paid_fees == expected_fee, 0);
    assert!(vault_reserve == expected_fee, 1);
    assert!(expected_fee > 0, 2);

    end(test);
}

/// Precision floor for Q2: fill below $0.50 produces zero fee.
/// price = 40 raw Q2 (= $0.40), qty = 1 SUI
/// quote = 40, fee = 40 × 200 / 10_000 = 0 (0.8 raw rounds down)
/// At $0.50 (price = 50): fee = 50 × 200 / 10_000 = 1 (first non-zero) ✓
/// Both fills use the same pool — only one Pool<SUI,Q2> can exist per registry.
#[test]
fun test_q2_precision_floor_and_threshold() {
    let mut test = begin(OWNER);
    let registry_id = setup_registry_and_clock(&mut test);
    approve_quote<Q2>(registry_id, &mut test);
    let pool_id = create_pool<Q2>(registry_id, &mut test);
    let alice_bm_id = create_funded_bm<Q2>(ALICE, &mut test);
    let bob_bm_id = create_funded_bm<Q2>(BOB, &mut test);

    let qty = 1 * constants::float_scaling();

    // $0.40 fill: fee = 0 (precision truncation)
    let price_below = 40u64; // $0.40 with 2-decimal QUOTE_UNIT
    let (fees_below, reserve_below) = fill_and_get_fees<Q2>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price_below,
        qty,
        &mut test,
    );
    assert!(fees_below == 0, 0);
    assert!(reserve_below == 0, 1);

    // $0.50 fill: fee = 1 (just above precision floor); same pool, same BMs
    let price_threshold = 50u64; // $0.50 with 2-decimal QUOTE_UNIT
    let (fees_threshold, reserve_threshold) = fill_and_get_fees<Q2>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price_threshold,
        qty,
        &mut test,
    );
    assert!(fees_threshold == 1, 2);
    assert!(reserve_threshold == 1, 3);

    end(test);
}

// ── Q1 (1-decimal): lowest precision, fee requires larger fills ────────────────

/// 1 SUI at $25 with 1-decimal quote — sufficient for non-zero fee.
/// price = 25 × 10 = 250 raw Q1 per SUI
/// quote = math::mul(1e9, 250) = 250 raw Q1
/// fee   = 250 × 200 / 10_000 = 5 raw Q1 (non-zero ✓)
#[test]
fun test_q1_adequate_price_fee_captured() {
    let mut test = begin(OWNER);
    let registry_id = setup_registry_and_clock(&mut test);
    approve_quote<Q1>(registry_id, &mut test);
    let pool_id = create_pool<Q1>(registry_id, &mut test);
    let alice_bm_id = create_funded_bm<Q1>(ALICE, &mut test);
    let bob_bm_id = create_funded_bm<Q1>(BOB, &mut test);

    let price = 25 * 10u64; // $25 with 1-decimal QUOTE_UNIT = 250 raw
    let qty = 1 * constants::float_scaling();

    let (paid_fees, vault_reserve) = fill_and_get_fees<Q1>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price,
        qty,
        &mut test,
    );

    let expected_quote = math::mul(qty, price); // = 250
    let expected_fee = expected_quote * FEE_BPS / FEE_PRECISION; // = 5

    assert!(paid_fees == expected_fee, 0);
    assert!(vault_reserve == expected_fee, 1);
    assert!(expected_fee > 0, 2);

    end(test);
}

/// Precision floor for Q1: $2 fill produces zero fee.
/// price = 2 × 10 = 20 raw Q1 per SUI
/// quote = 20, fee = 20 × 200 / 10_000 = 0 (2% of $2 = $0.04 < 0.1 raw → truncates)
/// At $5 (price = 50): fee = 50 × 200 / 10_000 = 1 (first non-zero) ✓
/// Both fills use the same pool — only one Pool<SUI,Q1> can exist per registry.
#[test]
fun test_q1_precision_floor_and_threshold() {
    let mut test = begin(OWNER);
    let registry_id = setup_registry_and_clock(&mut test);
    approve_quote<Q1>(registry_id, &mut test);
    let pool_id = create_pool<Q1>(registry_id, &mut test);
    let alice_bm_id = create_funded_bm<Q1>(ALICE, &mut test);
    let bob_bm_id = create_funded_bm<Q1>(BOB, &mut test);

    let qty = 1 * constants::float_scaling();

    // $2 fill: fee = 0 (precision truncation — 0.4 raw rounds down to 0)
    let price_below = 2 * 10u64; // $2 with 1-decimal QUOTE_UNIT = 20 raw
    let (fees_below, reserve_below) = fill_and_get_fees<Q1>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price_below,
        qty,
        &mut test,
    );
    assert!(fees_below == 0, 0);
    assert!(reserve_below == 0, 1);

    // $5 fill: fee = 1 (threshold for non-zero 2% fee with 1-decimal quote)
    // Same pool and BMs — reserve accumulates from both fills
    let price_threshold = 5 * 10u64; // $5 with 1-decimal QUOTE_UNIT = 50 raw
    let (fees_threshold, reserve_threshold) = fill_and_get_fees<Q1>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price_threshold,
        qty,
        &mut test,
    );
    assert!(fees_threshold == 1, 2);
    assert!(reserve_threshold == 1, 3);

    end(test);
}
