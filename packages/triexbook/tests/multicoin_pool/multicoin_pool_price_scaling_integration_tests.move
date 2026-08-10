// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Integration tests that pin the price_scaling = 1 fix for multicoin pools.
///
/// These tests would have failed with the pre-fix code (math::mul divides by
/// FLOAT_SCALING, silently producing quotes 1e9× too small for 0-decimal bases).
/// They prove the fix is wired end-to-end through OrderInfo and process_modify.
#[test_only]
module triexbook::integration_multicoin_pool_price_scaling_tests;

use multicoin::multicoin::{Self, Collection, CollectionCap};
use std::unit_test;
use sui::{clock::{Self, Clock}, test_scenario::{begin, end, return_shared}};
use token::cred::CRED;
use triexbook::{
    balance_manager::{Self, BalanceManager},
    constants,
    integration_multicoin_test_utils::{Self as mc_utils, USDC},
    math,
    multicoin_pool::{Self, MultiCoinPool},
    registry::{Self as registry, Registry}
};

const OWNER: address = @0x1;
const ALICE: address = @0xAAAA;
const BOB: address = @0xBBBB;
const ASSET_GOLD: u64 = 1;

// Matches quote_fee: FEE_PRECISION = 10_000, default pool fee = 200 bps (2%).
const FEE_BPS: u64 = 200;
const FEE_PRECISION: u64 = 10_000;

/// A full bid fill at 100 "USDC"/item must produce the correct cumulative_quote
/// and paid_fees in the taker's OrderInfo.
///
/// price_scaling = 1 (fix):
///   quote     = 1 × 100 × FLOAT_SCALING = 100 × FLOAT_SCALING
///   paid_fees = quote × 200 / 10_000    =   2 × FLOAT_SCALING
///
/// math::mul (bug, FLOAT_SCALING divisor):
///   quote     = 1 × 100 × FLOAT_SCALING / FLOAT_SCALING = 100
///   paid_fees = 100 × 200 / 10_000                      =   2   ← 1e9× too small
#[test]
fun test_full_bid_fill_produces_correct_paid_fees() {
    let mut test = begin(OWNER);

    let (registry_id, collection_id, collection_cap) = mc_utils::setup_registry_with_multicoin(
        &mut test,
    );
    let pool_id = mc_utils::setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = mc_utils::create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let bob_bm_id = mc_utils::create_balance_manager_with_funds(
        BOB,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    // Mint multicoin and deposit into ALICE's balance manager so she can place an ask.
    test.next_tx(OWNER);
    {
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000 * constants::float_scaling(),
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, ALICE);
    };

    test.next_tx(ALICE);
    {
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold, test.ctx());
        return_shared(alice_bm);
    };

    let price = 100 * constants::float_scaling();
    let qty = 1u64;

    // ALICE places a resting ask: 1 item at 100 "USDC". Ask side pays zero fee.
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_proof = alice_bm.generate_proof_as_owner(test.ctx());

        pool.place_limit_order(
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty,
            false, // ask
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        return_shared(pool);
        return_shared(clock);
        return_shared(alice_bm);
    };

    // BOB places a crossing bid: 1 item at 100 "USDC". He becomes the taker and pays fee.
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let bob_proof = bob_bm.generate_proof_as_owner(test.ctx());

        let order_info = pool.place_limit_order(
            &mut bob_bm,
            &bob_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty,
            true, // taker bid
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        // price_scaling = 1  →  quote = qty × price = 1 × 100 × FLOAT_SCALING
        let expected_quote = qty * price;
        // paid_fees = quote × fee_bps / fee_precision = expected_quote × 200 / 10_000
        let expected_fees = expected_quote * FEE_BPS / FEE_PRECISION;

        assert!(order_info.status() == constants::filled(), 0);
        assert!(order_info.cumulative_quote_quantity() == expected_quote, 1);
        assert!(order_info.paid_fees() == expected_fees, 2);

        return_shared(pool);
        return_shared(clock);
        return_shared(bob_bm);
    };

    unit_test::destroy(collection_cap);
    end(test);
}

/// Modifying (partially cancelling) a multicoin bid must refund the correct
/// quote amount, proving that process_modify threads price_scaling = 1 into
/// calculate_cancel_refund.
///
/// price_scaling = 1 (fix):
///   cancel_refund = cancel_qty × price = 5 × 5 × FLOAT_SCALING = 25 × FLOAT_SCALING
///
/// math::mul (bug):
///   cancel_refund = math::mul(5, 5 × FLOAT_SCALING) = 25   ← 1e9× too small
#[test]
fun test_modify_bid_order_refunds_correct_quote_amount() {
    let mut test = begin(OWNER);

    let (registry_id, collection_id, collection_cap) = mc_utils::setup_registry_with_multicoin(
        &mut test,
    );
    let pool_id = mc_utils::setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = mc_utils::create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    let price = 5 * constants::float_scaling();
    let original_qty = 10u64;
    let modified_qty = 5u64;
    let cancel_qty = original_qty - modified_qty; // = 5

    // ALICE places a resting bid: 10 items at price P. Bids do not require
    // multicoin — only quote (USDC) is locked in the vault.
    test.next_tx(ALICE);
    let order_id = {
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_proof = alice_bm.generate_proof_as_owner(test.ctx());

        let bid_info = pool.place_limit_order(
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            original_qty,
            true, // bid
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        assert!(bid_info.status() == constants::live(), 0);
        let order_id = bid_info.order_id();

        return_shared(pool);
        return_shared(clock);
        return_shared(alice_bm);
        order_id
    };

    // Snapshot ALICE's free USDC balance right after placing the bid.
    // At this point the vault holds the locked quote + maker-fee for 10 items.
    test.next_tx(ALICE);
    let balance_after_bid = {
        let alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let bal = balance_manager::balance<USDC>(&alice_bm);
        return_shared(alice_bm);
        bal
    };

    // Reduce the bid from 10 to 5 items. The vault must return the quote for
    // the 5 cancelled items to ALICE's balance manager immediately.
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_proof = alice_bm.generate_proof_as_owner(test.ctx());

        pool.modify_order(
            &mut alice_bm,
            &alice_proof,
            order_id,
            modified_qty,
            &clock,
            test.ctx(),
        );

        // Sanity: the resting order shows the reduced quantity.
        let remaining = pool.get_order(order_id);
        assert!(remaining.quantity() == modified_qty, 1);

        return_shared(pool);
        return_shared(clock);
        return_shared(alice_bm);
    };

    // Snapshot ALICE's free USDC balance after the modify.
    test.next_tx(ALICE);
    let balance_after_modify = {
        let alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let bal = balance_manager::balance<USDC>(&alice_bm);
        return_shared(alice_bm);
        bal
    };

    // Refund received = difference in free balance.
    // price_scaling = 1  →  refund = cancel_qty × price = 5 × 5 × FLOAT_SCALING = 25 × FLOAT_SCALING
    // math::mul (bug)    →  refund = math::mul(5, 5 × FLOAT_SCALING) = 25
    let actual_refund = balance_after_modify - balance_after_bid;
    let expected_refund = cancel_qty * price; // = 25 × FLOAT_SCALING = 25_000_000_000
    assert!(actual_refund == expected_refund, 2);

    unit_test::destroy(collection_cap);
    end(test);
}

/// After a bid fill, the pool's quote_fee_reserve_balance must hold the fee
/// computed on the *correct* quote amount (price_scaling = 1), not the
/// 1e9× smaller value that math::mul would have produced.
///
/// price_scaling = 1 (fix):
///   quote             = 1 × (100 × FLOAT_SCALING) = 100_000_000_000
///   expected_fees     = 100_000_000_000 × 200 / 10_000 = 2_000_000_000
///   vault fee reserve = 2_000_000_000
///
/// math::mul (bug):
///   quote             = math::mul(1, 100 × FLOAT_SCALING) = 100
///   fees              = 100 × 200 / 10_000 = 2
///   vault fee reserve = 2   ← 1_000_000_000× too small (the mainnet symptom)
#[test]
fun test_vault_fee_reserve_correct_after_fill() {
    let mut test = begin(OWNER);

    let (registry_id, collection_id, collection_cap) = mc_utils::setup_registry_with_multicoin(
        &mut test,
    );
    let pool_id = mc_utils::setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = mc_utils::create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );
    let bob_bm_id = mc_utils::create_balance_manager_with_funds(
        BOB,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(OWNER);
    {
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            10,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, ALICE);
    };

    test.next_tx(ALICE);
    {
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold, test.ctx());
        return_shared(alice_bm);
    };

    let price = 100 * constants::float_scaling();
    let qty = 1u64;

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_proof = alice_bm.generate_proof_as_owner(test.ctx());

        pool.place_limit_order(
            &mut alice_bm,
            &alice_proof,
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
        return_shared(alice_bm);
    };

    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let bob_proof = bob_bm.generate_proof_as_owner(test.ctx());

        pool.place_limit_order(
            &mut bob_bm,
            &bob_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        // price_scaling = 1 → quote = qty × price (no FLOAT_SCALING division)
        let expected_quote = qty * price;
        let expected_fees = expected_quote * FEE_BPS / FEE_PRECISION;

        // The buggy path: math::mul divides by FLOAT_SCALING, giving a quote
        // 1e9× too small, and therefore fees 1e9× too small.
        let buggy_quote = math::mul(qty, price);
        let buggy_fees = buggy_quote * FEE_BPS / FEE_PRECISION;

        // Vault must hold the correct fee, not the undercharged amount.
        assert!(pool.quote_fee_reserve_balance() == expected_fees, 0);
        // Confirm the ratio: fix collects FLOAT_SCALING× more than the bug.
        assert!(expected_fees / buggy_fees == constants::float_scaling(), 1);

        return_shared(pool);
        return_shared(clock);
        return_shared(bob_bm);
    };

    unit_test::destroy(collection_cap);
    end(test);
}

/// Placing an ask at a price that would overflow under the old encoding must
/// succeed after the fix. With price_scaling = 1, price_internal = human ×
/// QUOTE_UNIT (no extra FLOAT_SCALING factor), so the valid price ceiling
/// is MAX_PRICE / QUOTE_UNIT ≈ 9.22 × 10^9 human USDC/item instead of ~9.
///
/// price = 10_000 × FLOAT_SCALING = 1e13  (below MAX_PRICE = 9.22e18)
/// Old encoding needed: 10_000 × FLOAT_SCALING × FLOAT_SCALING = 1e22 → u64 overflow
#[test]
fun test_high_price_order_within_valid_range() {
    let mut test = begin(OWNER);

    let (registry_id, collection_id, collection_cap) = mc_utils::setup_registry_with_multicoin(
        &mut test,
    );
    let pool_id = mc_utils::setup_multicoin_pool(
        OWNER,
        registry_id,
        collection_id,
        ASSET_GOLD,
        true,
        false,
        &mut test,
    );

    let alice_bm_id = mc_utils::create_balance_manager_with_funds(
        ALICE,
        1_000_000 * constants::float_scaling(),
        1_000_000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(OWNER);
    {
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            10,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, ALICE);
    };

    test.next_tx(ALICE);
    {
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold, test.ctx());
        return_shared(alice_bm);
    };

    // 10_000 human USDC/item. With old encoding (× FLOAT_SCALING again):
    //   10_000 × 1e9 × 1e9 = 1e22 → u64 overflow, EOrderInvalidPrice.
    // With fix (price_scaling = 1, no extra FLOAT_SCALING):
    //   10_000 × 1e9 = 1e13 < MAX_PRICE (9.22e18) → accepted.
    let price = 10_000 * constants::float_scaling();
    let qty = 1u64;

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_proof = alice_bm.generate_proof_as_owner(test.ctx());

        let order_info = pool.place_limit_order(
            &mut alice_bm,
            &alice_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        assert!(order_info.status() == constants::live(), 0);
        assert!(order_info.price() == price, 1);

        return_shared(pool);
        return_shared(clock);
        return_shared(alice_bm);
    };

    unit_test::destroy(collection_cap);
    end(test);
}

/// End-to-end trade of 1 NFT priced at 100 billion CRED, using a real
/// MultiCoinPool<CRED> with CRED_UNIT = 1_000_000 (6 decimals).
///
/// price_internal = 100_000_000_000 × 1_000_000 = 100_000_000_000_000_000 (1e17)
///
/// price_scaling = 1 (fix):
///   quote         = 1 × 1e17 = 100_000_000_000_000_000
///   paid_fees     = 1e17 × 200 / 10_000 = 2_000_000_000_000_000
///
/// math::mul (bug, ÷ FLOAT_SCALING):
///   quote         = math::mul(1, 1e17) = 1e17 / 1e9 = 100_000_000
///   paid_fees     = 1e8 × 200 / 10_000 = 2_000_000   (1e9× too small)
#[test]
fun test_trade_nft_for_100_billion_cred() {
    let mut test = begin(OWNER);

    // setup_registry_with_multicoin already approves CRED as a quote currency.
    let (registry_id, _collection_id, collection_cap) = mc_utils::setup_registry_with_multicoin(
        &mut test,
    );

    // Create a MultiCoinPool<CRED> for ASSET_GOLD.
    test.next_tx(OWNER);
    let pool_id = {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut reg = test.take_shared_by_id<Registry>(registry_id);
        let collection = test.take_shared<Collection>();
        let id = multicoin_pool::create_pool_admin<CRED>(
            &mut reg,
            &collection,
            ASSET_GOLD,
            true,
            false,
            &admin_cap,
            test.ctx(),
        );
        return_shared(reg);
        return_shared(collection);
        unit_test::destroy(admin_cap);
        id
    };

    // Alice (NFT seller) needs multicoin in her BM; Bob (buyer) needs enough CRED
    // to cover quote + fee = 1e17 + 2e15 = 1.02e17 raw CRED.
    let bob_cred_balance: u64 = 200_000_000_000_000_000; // 2e17 raw CRED (200 billion human)

    let alice_bm_id = mc_utils::create_balance_manager_with_funds(ALICE, 0, 0, &mut test);
    let bob_bm_id = mc_utils::create_balance_manager_with_funds(
        BOB,
        0,
        bob_cred_balance,
        &mut test,
    );

    // Mint 1 NFT and deposit into Alice's BM.
    test.next_tx(OWNER);
    {
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, ALICE);
    };
    test.next_tx(ALICE);
    {
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold, test.ctx());
        return_shared(alice_bm);
    };

    // CRED_UNIT = 1_000_000 (6 decimals).
    // price_internal = 100_000_000_000 human CRED × 1_000_000 = 1e17 raw
    let cred_unit: u64 = 1_000_000;
    let human_price: u64 = 100_000_000_000; // 100 billion CRED
    let price = human_price * cred_unit; // = 100_000_000_000_000_000 (1e17)
    let qty = 1u64;

    // Alice places a resting ask: 1 NFT at 100 billion CRED.
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<CRED>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let alice_proof = alice_bm.generate_proof_as_owner(test.ctx());

        pool.place_limit_order(
            &mut alice_bm,
            &alice_proof,
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
        return_shared(alice_bm);
    };

    // Bob places a crossing bid and becomes taker — he pays the 2% fee.
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<CRED>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let bob_proof = bob_bm.generate_proof_as_owner(test.ctx());

        let order_info = pool.place_limit_order(
            &mut bob_bm,
            &bob_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        // price_scaling = 1: quote = qty × price (direct product, no FLOAT_SCALING division)
        let expected_quote = qty * price; // = 100_000_000_000_000_000
        // Use u128 intermediate: 1e17 × 200 = 2e19 overflows u64 but fits in u128.
        let expected_fee =
            (((expected_quote as u128) * (FEE_BPS as u128)) / (FEE_PRECISION as u128)) as u64; // = 2_000_000_000_000_000

        // Buggy path: math::mul divides by FLOAT_SCALING, giving 1e9× smaller values
        let buggy_quote = math::mul(qty, price); // = 100_000_000 (1e8, not 1e17)
        let buggy_fee = buggy_quote * FEE_BPS / FEE_PRECISION; // = 2_000_000 (not 2e15)

        assert!(order_info.status() == constants::filled(), 0);
        assert!(order_info.cumulative_quote_quantity() == expected_quote, 1);
        assert!(order_info.paid_fees() == expected_fee, 2);
        assert!(pool.quote_fee_reserve_balance() == expected_fee, 3);
        // The fix captures FLOAT_SCALING× more fee than the bug
        assert!(expected_fee / buggy_fee == constants::float_scaling(), 4);

        return_shared(pool);
        return_shared(clock);
        return_shared(bob_bm);
    };

    unit_test::destroy(collection_cap);
    end(test);
}

/// Regression guard: fee = quote × fee_rate / FEE_PRECISION must use u128 for the
/// intermediate multiplication. With fee_rate = 200:
///
///   overflow threshold: quote > MAX_U64 / 200 = 92_233_720_368_547_758
///
/// This test uses price_internal = 92_233_720_368_547_759 (one above the threshold)
/// so that quote × 200 = 18_446_744_073_709_551_800 exceeds MAX_U64, which would
/// wrap or abort under naive u64 arithmetic. The u128 path produces the correct fee.
///
///   correct fee = 18_446_744_073_709_551_800 / 10_000 = 1_844_674_407_370_955
#[test]
fun test_fee_large_quote_no_u64_overflow() {
    let mut test = begin(OWNER);

    let (registry_id, _collection_id, collection_cap) = mc_utils::setup_registry_with_multicoin(
        &mut test,
    );

    test.next_tx(OWNER);
    let pool_id = {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut reg = test.take_shared_by_id<Registry>(registry_id);
        let collection = test.take_shared<Collection>();
        let id = multicoin_pool::create_pool_admin<CRED>(
            &mut reg,
            &collection,
            ASSET_GOLD,
            true,
            false,
            &admin_cap,
            test.ctx(),
        );
        return_shared(reg);
        return_shared(collection);
        unit_test::destroy(admin_cap);
        id
    };

    // price_internal one above overflow threshold: quote × 200 > MAX_U64
    let price: u64 = 92_233_720_368_547_759;
    let qty = 1u64;

    // Bob needs quote + fee raw CRED: 92_233_720_368_547_759 + 1_844_674_407_370_955 = 94_078_394_775_918_714
    let alice_bm_id = mc_utils::create_balance_manager_with_funds(ALICE, 0, 0, &mut test);
    let bob_bm_id = mc_utils::create_balance_manager_with_funds(
        BOB,
        0,
        200_000_000_000_000_000,
        &mut test,
    );

    test.next_tx(OWNER);
    {
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            1,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, ALICE);
    };
    test.next_tx(ALICE);
    {
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold, test.ctx());
        return_shared(alice_bm);
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<CRED>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let proof = alice_bm.generate_proof_as_owner(test.ctx());
        pool.place_limit_order(
            &mut alice_bm,
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
        return_shared(alice_bm);
    };

    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<CRED>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let proof = bob_bm.generate_proof_as_owner(test.ctx());

        let order_info = pool.place_limit_order(
            &mut bob_bm,
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

        let quote = qty * price; // = 92_233_720_368_547_759

        // Prove that naive u64 multiplication would overflow.
        let u128_product = (quote as u128) * (FEE_BPS as u128); // = 18_446_744_073_709_551_800
        assert!(u128_product > (constants::max_u64() as u128), 0);

        // The u128 path gives the correct truncated fee.
        let expected_fee = (u128_product / (FEE_PRECISION as u128)) as u64; // = 1_844_674_407_370_955

        assert!(order_info.status() == constants::filled(), 1);
        assert!(order_info.paid_fees() == expected_fee, 2);
        assert!(pool.quote_fee_reserve_balance() == expected_fee, 3);

        return_shared(pool);
        return_shared(clock);
        return_shared(bob_bm);
    };

    unit_test::destroy(collection_cap);
    end(test);
}

/// Regression guard: fee = quote × fee_rate / FEE_PRECISION truncates to zero when
/// quote × fee_rate < FEE_PRECISION, regardless of the arithmetic width used.
///
/// With fee_rate = 200 (2%) and FEE_PRECISION = 10_000:
///   minimum non-zero fee requires: quote × 200 ≥ 10_000  →  quote ≥ 50
///
///   quote = 49: 49 × 200 / 10_000 = 9_800 / 10_000 = 0  (truncated)
///   quote = 50: 50 × 200 / 10_000 = 10_000 / 10_000 = 1  (minimum non-zero)
///
/// Uses price_internal = 1 (minimum valid price) so quote = qty exactly.
/// Both fills share the same pool since only one MultiCoinPool<CRED> can exist per registry.
#[test]
fun test_fee_truncation_floor_and_threshold() {
    let mut test = begin(OWNER);

    let (registry_id, _collection_id, collection_cap) = mc_utils::setup_registry_with_multicoin(
        &mut test,
    );

    test.next_tx(OWNER);
    let pool_id = {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut reg = test.take_shared_by_id<Registry>(registry_id);
        let collection = test.take_shared<Collection>();
        let id = multicoin_pool::create_pool_admin<CRED>(
            &mut reg,
            &collection,
            ASSET_GOLD,
            true,
            false,
            &admin_cap,
            test.ctx(),
        );
        return_shared(reg);
        return_shared(collection);
        unit_test::destroy(admin_cap);
        id
    };

    // price = 1 raw CRED/NFT so that quote = qty exactly; easy to reason about.
    let price = 1u64;
    let qty_below: u64 = 49; // quote = 49 → fee = 0 (truncated)
    let qty_threshold: u64 = 50; // quote = 50 → fee = 1 (minimum non-zero)

    // Alice needs 49 + 50 = 99 NFTs; Bob needs 49 + 51 = 100 raw CRED.
    let alice_bm_id = mc_utils::create_balance_manager_with_funds(ALICE, 0, 0, &mut test);
    let bob_bm_id = mc_utils::create_balance_manager_with_funds(BOB, 0, 200, &mut test);

    test.next_tx(OWNER);
    {
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            ASSET_GOLD,
            qty_below + qty_threshold,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, ALICE);
    };
    test.next_tx(ALICE);
    {
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let gold = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(gold, test.ctx());
        return_shared(alice_bm);
    };

    // ── Fill 1: quote = 49, fee truncates to 0 ──────────────────────────────────
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<CRED>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let proof = alice_bm.generate_proof_as_owner(test.ctx());
        pool.place_limit_order(
            &mut alice_bm,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty_below,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(alice_bm);
    };
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<CRED>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let proof = bob_bm.generate_proof_as_owner(test.ctx());
        let info = pool.place_limit_order(
            &mut bob_bm,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty_below,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        assert!(info.paid_fees() == 0, 0); // 49 × 200 / 10_000 = 0
        assert!(pool.quote_fee_reserve_balance() == 0, 1);

        return_shared(pool);
        return_shared(clock);
        return_shared(bob_bm);
    };

    // ── Fill 2: quote = 50, fee = 1 (minimum non-zero) ─────────────────────────
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<CRED>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut alice_bm = test.take_shared_by_id<BalanceManager>(alice_bm_id);
        let proof = alice_bm.generate_proof_as_owner(test.ctx());
        pool.place_limit_order(
            &mut alice_bm,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty_threshold,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        return_shared(pool);
        return_shared(clock);
        return_shared(alice_bm);
    };
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<MultiCoinPool<CRED>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut bob_bm = test.take_shared_by_id<BalanceManager>(bob_bm_id);
        let proof = bob_bm.generate_proof_as_owner(test.ctx());
        let info = pool.place_limit_order(
            &mut bob_bm,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty_threshold,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        assert!(info.paid_fees() == 1, 2); // 50 × 200 / 10_000 = 1
        assert!(pool.quote_fee_reserve_balance() == 1, 3); // cumulative: 0 + 1

        return_shared(pool);
        return_shared(clock);
        return_shared(bob_bm);
    };

    unit_test::destroy(collection_cap);
    end(test);
}
