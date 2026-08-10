// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end fee-precision tests for MultiCoinPool<Qn> across quote currencies
/// of varying decimal precision.
///
/// MultiCoin pools use price_scaling = 1 (the fix from commit a0f9eb0).
/// The price encoding for a 0-decimal base (NFT, BASE_UNIT = 1) is:
///
///   price_internal = human_price × QUOTE_UNIT
///
///   quote_qty = qty × price_internal       (direct product, no FLOAT_SCALING division)
///             = qty × human_price × QUOTE_UNIT   ✓
///
/// Before the fix, math::mul was used:
///   buggy_quote = math::mul(qty, price_internal)
///               = qty × price_internal / FLOAT_SCALING   ← 1e9× too small
///
/// After the fix, the correct amount is captured at every decimal level:
///
///   Decimal | QUOTE_UNIT | price (100/item) | correct fee  | buggy fee
///   --------+------------+------------------+--------------+-----------
///   Q9      | 1_000_000_000 | 100_000_000_000 | 2_000_000_000 | 2
///   Q6      |   1_000_000   |   100_000_000   |     2_000_000 | 0 (truncated)
///   Q2      |         100   |       10_000     |           200 | 0 (truncated)
///   Q1      |          10   |        1_000     |            20 | 0 (truncated)
///
/// Each test places a maker ask (NFT seller) then a crossing taker bid (NFT buyer),
/// then validates both OrderInfo.paid_fees() and vault.quote_fee_reserve_balance().
/// The buggy value is computed inline to make the contrast explicit.
#[test_only]
module triexbook::multicoin_pool_quote_decimal_precision_tests;

use multicoin::multicoin::{Self, Collection, CollectionCap};
use std::unit_test::destroy;
use sui::{clock::{Self, Clock}, coin::mint_for_testing, test_scenario::{begin, end, return_shared}};
use triexbook::{
    balance_manager::{Self as balance_manager, BalanceManager},
    constants,
    math,
    multicoin_pool::{Self, MultiCoinPool},
    registry::{Self, Registry}
};

const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;
const BOB: address = @0xBBBB;
const ASSET_GOLD: u64 = 1;

// Pool governance default: 2% taker fee on bids
const FEE_BPS: u64 = 200;
const FEE_PRECISION: u64 = 10_000;

// Large enough to cover the maximum test quote (100 × FLOAT_SCALING per item)
const LARGE_BALANCE: u64 = 100_000_000_000_000_000;

// ── Quote phantom types ───────────────────────────────────────────────────────

/// 9-decimal quote. QUOTE_UNIT = FLOAT_SCALING = 1_000_000_000.
/// price_internal = human × 1_000_000_000
/// 1 NFT at 100 → quote = 100_000_000_000, fee = 2_000_000_000
/// Buggy (math::mul): quote = 100, fee = 2  (1_000_000_000× too small)
public struct MQ9 has store {}

/// 6-decimal quote (e.g., real USDC). QUOTE_UNIT = 1_000_000.
/// price_internal = human × 1_000_000
/// 1 NFT at 100 → quote = 100_000_000, fee = 2_000_000
/// Buggy (math::mul): quote = 0, fee = 0  (truncated to zero)
public struct MQ6 has store {}

/// 2-decimal quote. QUOTE_UNIT = 100.
/// price_internal = human × 100
/// 1 NFT at 100 → quote = 10_000, fee = 200
/// Buggy (math::mul): quote = 0, fee = 0  (truncated to zero)
public struct MQ2 has store {}

/// 1-decimal quote. QUOTE_UNIT = 10.
/// price_internal = human × 10
/// 1 NFT at 100 → quote = 1_000, fee = 20
/// Buggy (math::mul): quote = 0, fee = 0  (truncated to zero)
/// Precision floor: price × qty < 50 raw → fee truncates to 0 even with fix
public struct MQ1 has store {}

// ── Setup helpers ─────────────────────────────────────────────────────────────

/// Initialize registry, clock, and a multicoin collection.
/// Returns (registry_id, collection_id, collection_cap).
fun setup_base(test: &mut sui::test_scenario::Scenario): (ID, ID, CollectionCap) {
    test.next_tx(OWNER);
    clock::create_for_testing(test.ctx()).share_for_testing();

    test.next_tx(OWNER);
    let registry_id = registry::test_registry(test.ctx());

    test.next_tx(OWNER);
    let (collection, collection_cap) = multicoin::new_collection(test.ctx());
    let collection_id = object::id(&collection);
    transfer::public_share_object(collection);

    (registry_id, collection_id, collection_cap)
}

/// Register a quote asset and create a whitelisted multicoin pool for ASSET_GOLD.
/// Call this ONCE per (registry, QuoteAsset) type.
fun create_pool_with_quote<QuoteAsset>(
    registry_id: ID,
    test: &mut sui::test_scenario::Scenario,
): ID {
    test.next_tx(OWNER);
    let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
    let mut registry = test.take_shared_by_id<Registry>(registry_id);
    let collection = test.take_shared<Collection>();
    registry.add_approved_quote_unchecked<QuoteAsset>(&admin_cap);
    let pool_id = multicoin_pool::create_pool_admin<QuoteAsset>(
        &mut registry,
        &collection,
        ASSET_GOLD,
        true, // whitelisted
        false, // not stable
        &admin_cap,
        test.ctx(),
    );
    return_shared(registry);
    return_shared(collection);
    destroy(admin_cap);
    pool_id
}

/// Create a BalanceManager funded with the QuoteAsset.
/// (Bob's BM; he pays QuoteAsset to buy NFTs.)
fun create_quote_funded_bm<QuoteAsset>(
    trader: address,
    test: &mut sui::test_scenario::Scenario,
): ID {
    test.next_tx(trader);
    let mut bm = balance_manager::new(test.ctx());
    bm.deposit(mint_for_testing<QuoteAsset>(LARGE_BALANCE, test.ctx()), test.ctx());
    let id = object::id(&bm);
    transfer::public_share_object(bm);
    id
}

/// Mint NFTs for Alice and deposit into her BalanceManager.
fun mint_and_deposit_nfts(
    alice_bm_id: ID,
    nft_qty: u64,
    collection_cap: &CollectionCap,
    test: &mut sui::test_scenario::Scenario,
) {
    test.next_tx(OWNER);
    {
        let mut collection = test.take_shared<Collection>();
        let nfts = multicoin::mint_and_keep(
            collection_cap,
            &mut collection,
            ASSET_GOLD,
            nft_qty,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(nfts, ALICE);
    };

    test.next_tx(ALICE);
    {
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let nfts = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(nfts, test.ctx());
        return_shared(alice_bm);
    };
}

/// Full scenario: maker ask then crossing taker bid, returns (paid_fees, vault_reserve).
fun fill_and_get_fees<QuoteAsset>(
    pool_id: ID,
    alice_bm_id: ID,
    bob_bm_id: ID,
    price: u64,
    qty: u64,
    test: &mut sui::test_scenario::Scenario,
): (u64, u64) {
    // Alice: resting ask (sell NFTs for QuoteAsset, zero fee on asks)
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<QuoteAsset>>(pool_id);
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

    // Bob: crossing bid (buy NFTs with QuoteAsset, taker pays 2% fee)
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<QuoteAsset>>(pool_id);
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

// ── MQ9 (9-decimal): 1e9× undercharge caught by the fix ──────────────────────

/// 1 NFT at 100 units with 9-decimal quote.
/// price = 100 × 1e9 = 100_000_000_000
/// correct quote = 1 × 100_000_000_000 = 100_000_000_000  (price_scaling = 1)
/// correct fee   = 100_000_000_000 × 200 / 10_000 = 2_000_000_000
/// buggy quote   = math::mul(1, 100_000_000_000) = 100  (÷ 1e9)
/// buggy fee     = 100 × 200 / 10_000 = 2  (1_000_000_000× too small)
#[test]
fun test_mq9_fee_correct_not_1e9_undercharged() {
    let mut test = begin(OWNER);
    let (registry_id, _collection_id, collection_cap) = setup_base(&mut test);
    let pool_id = create_pool_with_quote<MQ9>(registry_id, &mut test);

    // Alice BM (needs MQ9 for potential bids, but really just needs NFTs for ask)
    test.next_tx(ALICE);
    let alice_bm_id = {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(mint_for_testing<MQ9>(LARGE_BALANCE, test.ctx()), test.ctx());
        let id = object::id(&bm);
        transfer::public_share_object(bm);
        id
    };
    let bob_bm_id = create_quote_funded_bm<MQ9>(BOB, &mut test);

    mint_and_deposit_nfts(alice_bm_id, 10, &collection_cap, &mut test);

    let price = 100 * constants::float_scaling(); // 100 × 1e9 per NFT
    let qty = 1u64;

    let (paid_fees, vault_reserve) = fill_and_get_fees<MQ9>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price,
        qty,
        &mut test,
    );

    // price_scaling = 1 → quote = qty × price (direct product)
    let expected_quote = qty * price; // = 100_000_000_000
    let expected_fee = expected_quote * FEE_BPS / FEE_PRECISION; // = 2_000_000_000

    // buggy path: math::mul would divide by FLOAT_SCALING
    let buggy_quote = math::mul(qty, price); // = 100
    let buggy_fee = buggy_quote * FEE_BPS / FEE_PRECISION; // = 2

    assert!(paid_fees == expected_fee, 0);
    assert!(vault_reserve == expected_fee, 1);
    // The fix captures FLOAT_SCALING× more fee than the bug would have
    assert!(expected_fee / buggy_fee == constants::float_scaling(), 2);

    destroy(collection_cap);
    end(test);
}

// ── MQ6 (6-decimal): buggy path yields zero, fix captures full fee ────────────

/// 1 NFT at 100 units with 6-decimal quote.
/// price = 100 × 1e6 = 100_000_000
/// correct quote = 100_000_000  (price_scaling = 1)
/// correct fee   = 100_000_000 × 200 / 10_000 = 2_000_000
/// buggy quote   = math::mul(1, 100_000_000) = 0  (÷ 1e9 truncates)
/// buggy fee     = 0  (zero fee — the mainnet symptom for CRED-like decimals)
#[test]
fun test_mq6_fee_nonzero_not_truncated_to_zero() {
    let mut test = begin(OWNER);
    let (registry_id, _collection_id, collection_cap) = setup_base(&mut test);
    let pool_id = create_pool_with_quote<MQ6>(registry_id, &mut test);

    test.next_tx(ALICE);
    let alice_bm_id = {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(mint_for_testing<MQ6>(LARGE_BALANCE, test.ctx()), test.ctx());
        let id = object::id(&bm);
        transfer::public_share_object(bm);
        id
    };
    let bob_bm_id = create_quote_funded_bm<MQ6>(BOB, &mut test);

    mint_and_deposit_nfts(alice_bm_id, 10, &collection_cap, &mut test);

    let price = 100 * 1_000_000u64; // 100 units × 6-decimal QUOTE_UNIT
    let qty = 1u64;

    let (paid_fees, vault_reserve) = fill_and_get_fees<MQ6>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price,
        qty,
        &mut test,
    );

    let expected_quote = qty * price; // = 100_000_000
    let expected_fee = expected_quote * FEE_BPS / FEE_PRECISION; // = 2_000_000

    // The buggy path truncates 100_000_000 / 1e9 → 0
    let buggy_quote = math::mul(qty, price);
    assert!(buggy_quote == 0, 0); // confirm: old path gave zero

    assert!(paid_fees == expected_fee, 1);
    assert!(vault_reserve == expected_fee, 2);
    assert!(vault_reserve > 0, 3); // fee was captured, not lost

    destroy(collection_cap);
    end(test);
}

/// 5 NFTs at 50 units each with 6-decimal quote — multi-item fill.
/// price = 50 × 1e6 = 50_000_000
/// correct quote = 5 × 50_000_000 = 250_000_000
/// correct fee   = 250_000_000 × 200 / 10_000 = 5_000_000
#[test]
fun test_mq6_multi_item_fee_captured() {
    let mut test = begin(OWNER);
    let (registry_id, _collection_id, collection_cap) = setup_base(&mut test);
    let pool_id = create_pool_with_quote<MQ6>(registry_id, &mut test);

    test.next_tx(ALICE);
    let alice_bm_id = {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(mint_for_testing<MQ6>(LARGE_BALANCE, test.ctx()), test.ctx());
        let id = object::id(&bm);
        transfer::public_share_object(bm);
        id
    };
    let bob_bm_id = create_quote_funded_bm<MQ6>(BOB, &mut test);

    mint_and_deposit_nfts(alice_bm_id, 20, &collection_cap, &mut test);

    let price = 50 * 1_000_000u64; // 50 units with 6-decimal QUOTE_UNIT
    let qty = 5u64; // 5 NFTs

    let (paid_fees, vault_reserve) = fill_and_get_fees<MQ6>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price,
        qty,
        &mut test,
    );

    let expected_quote = qty * price; // = 250_000_000
    let expected_fee = expected_quote * FEE_BPS / FEE_PRECISION; // = 5_000_000

    assert!(paid_fees == expected_fee, 0);
    assert!(vault_reserve == expected_fee, 1);

    destroy(collection_cap);
    end(test);
}

// ── MQ2 (2-decimal): buggy path also gives zero ───────────────────────────────

/// 1 NFT at 100 units with 2-decimal quote.
/// price = 100 × 100 = 10_000
/// correct quote = 10_000  (price_scaling = 1)
/// correct fee   = 10_000 × 200 / 10_000 = 200
/// buggy quote   = math::mul(1, 10_000) = 0  (÷ 1e9 truncates)
/// buggy fee     = 0
#[test]
fun test_mq2_fee_nonzero_not_truncated_to_zero() {
    let mut test = begin(OWNER);
    let (registry_id, _collection_id, collection_cap) = setup_base(&mut test);
    let pool_id = create_pool_with_quote<MQ2>(registry_id, &mut test);

    test.next_tx(ALICE);
    let alice_bm_id = {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(mint_for_testing<MQ2>(LARGE_BALANCE, test.ctx()), test.ctx());
        let id = object::id(&bm);
        transfer::public_share_object(bm);
        id
    };
    let bob_bm_id = create_quote_funded_bm<MQ2>(BOB, &mut test);

    mint_and_deposit_nfts(alice_bm_id, 10, &collection_cap, &mut test);

    let price = 100 * 100u64; // 100 units × 2-decimal QUOTE_UNIT = 10_000
    let qty = 1u64;

    let (paid_fees, vault_reserve) = fill_and_get_fees<MQ2>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price,
        qty,
        &mut test,
    );

    let expected_quote = qty * price; // = 10_000
    let expected_fee = expected_quote * FEE_BPS / FEE_PRECISION; // = 200

    let buggy_quote = math::mul(qty, price); // = 0 (10_000 / 1e9 truncates)
    assert!(buggy_quote == 0, 0);

    assert!(paid_fees == expected_fee, 1);
    assert!(vault_reserve == expected_fee, 2);
    assert!(vault_reserve > 0, 3);

    destroy(collection_cap);
    end(test);
}

// ── MQ1 (1-decimal): lowest precision, fee still captured correctly ───────────

/// 1 NFT at 100 units with 1-decimal quote.
/// price = 100 × 10 = 1_000
/// correct quote = 1_000  (price_scaling = 1)
/// correct fee   = 1_000 × 200 / 10_000 = 20
/// buggy quote   = math::mul(1, 1_000) = 0  (÷ 1e9 truncates)
/// buggy fee     = 0
#[test]
fun test_mq1_fee_nonzero_not_truncated_to_zero() {
    let mut test = begin(OWNER);
    let (registry_id, _collection_id, collection_cap) = setup_base(&mut test);
    let pool_id = create_pool_with_quote<MQ1>(registry_id, &mut test);

    test.next_tx(ALICE);
    let alice_bm_id = {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(mint_for_testing<MQ1>(LARGE_BALANCE, test.ctx()), test.ctx());
        let id = object::id(&bm);
        transfer::public_share_object(bm);
        id
    };
    let bob_bm_id = create_quote_funded_bm<MQ1>(BOB, &mut test);

    mint_and_deposit_nfts(alice_bm_id, 10, &collection_cap, &mut test);

    let price = 100 * 10u64; // 100 units × 1-decimal QUOTE_UNIT = 1_000
    let qty = 1u64;

    let (paid_fees, vault_reserve) = fill_and_get_fees<MQ1>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price,
        qty,
        &mut test,
    );

    let expected_quote = qty * price; // = 1_000
    let expected_fee = expected_quote * FEE_BPS / FEE_PRECISION; // = 20

    let buggy_quote = math::mul(qty, price); // = 0 (1_000 / 1e9 truncates)
    assert!(buggy_quote == 0, 0);

    assert!(paid_fees == expected_fee, 1);
    assert!(vault_reserve == expected_fee, 2);
    assert!(vault_reserve > 0, 3);

    destroy(collection_cap);
    end(test);
}

/// Precision floor for MQ1: even with the fix, very low per-item prices can
/// still produce zero fee due to integer division within fee calculation.
/// price = 4 × 10 = 40 raw per item: quote = 40, fee = 40 × 2% = 0 (0.8 rounds down)
/// price = 5 × 10 = 50 raw per item: quote = 50, fee = 50 × 2% = 1 (threshold ✓)
/// Both fills use the same pool — only one MultiCoinPool<MQ1> can exist per registry.
#[test]
fun test_mq1_precision_floor_and_threshold() {
    let mut test = begin(OWNER);
    let (registry_id, _collection_id, collection_cap) = setup_base(&mut test);

    let pool_id = create_pool_with_quote<MQ1>(registry_id, &mut test);

    test.next_tx(ALICE);
    let alice_bm_id = {
        let mut bm = balance_manager::new(test.ctx());
        bm.deposit(mint_for_testing<MQ1>(LARGE_BALANCE, test.ctx()), test.ctx());
        let id = object::id(&bm);
        transfer::public_share_object(bm);
        id
    };
    let bob_bm_id = create_quote_funded_bm<MQ1>(BOB, &mut test);
    // Mint enough NFTs for both fills (1 each)
    mint_and_deposit_nfts(alice_bm_id, 5, &collection_cap, &mut test);

    // 4 raw Q1 per NFT: quote = 40, fee = 40 × 200/10_000 = 0
    let price_low = 4 * 10u64;
    let (fees_low, reserve_low) = fill_and_get_fees<MQ1>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price_low,
        1u64,
        &mut test,
    );
    assert!(fees_low == 0, 0);
    assert!(reserve_low == 0, 1);

    // 5 raw Q1 per NFT: quote = 50, fee = 50 × 200/10_000 = 1 (first non-zero)
    // Same pool and BMs — reserve accumulates from both fills (0 + 1 = 1)
    let price_threshold = 5 * 10u64;
    let (fees_threshold, reserve_threshold) = fill_and_get_fees<MQ1>(
        pool_id,
        alice_bm_id,
        bob_bm_id,
        price_threshold,
        1u64,
        &mut test,
    );
    assert!(fees_threshold == 1, 2);
    assert!(reserve_threshold == 1, 3);

    destroy(collection_cap);
    end(test);
}
