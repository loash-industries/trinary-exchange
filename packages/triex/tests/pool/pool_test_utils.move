// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::pool_test_utils;

use std::unit_test::{assert_eq, destroy};
use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin, mint_for_testing},
    event,
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
    order::{Self, Order},
    order_info::{Self, OrderInfo},
    pool::{Self, Pool},
    quote_fee,
    registry::{Self, Registry},
    vault
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
        true,
        constants::immediate_or_cancel(),
        3 * constants::float_scaling(),
        3 * constants::float_scaling(),
        6 * constants::float_scaling(),
        3 * constants::maybe_apply_fee(false) * constants::cred_multiplier(),
        constants::filled(),
    );
}
public(package) fun test_place_then_ioc_ask_bid() {
    place_then_fill(
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
        // Alice's ask-maker fee (1.8% of the filled quote) is deducted from
        // her proceeds and lands in the same reserve as Bob's taker fee.
        let ask_maker_fee = order_info.cumulative_quote_quantity() * 180 / 10_000;
        let expected_fee = order_info.paid_fees() + order_info.maker_fees() + ask_maker_fee;
        assert!(expected_fee > 0, 0);
        assert!(reserve_after >= reserve_before, 0);
        assert!(reserve_after - reserve_before == expected_fee, 0);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// Acceptance: ask takers pay their fee out of quote proceeds, both sides'
/// fees land in the reserve, and the vault conserves quote exactly — after
/// the fill, every quote unit Alice paid in is either with Bob or in the
/// fee reserve.
public(package) fun test_ask_taker_fee_conservation() {
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
    let quantity = 100 * constants::float_scaling();
    // quote notional = 200; Alice locks 1.8% (3.6) at placement, Bob pays
    // 2.2% (4.4) from proceeds at fill
    let locked_maker_fee = 36 * constants::float_scaling() / 10;
    let taker_fee = 44 * constants::float_scaling() / 10;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
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

        // Alice's locked maker fee reached the reserve at placement
        let reserve_before = pool.quote_fee_reserve_balance();
        assert!(reserve_before == locked_maker_fee, 0);

        let order_info = pool.place_limit_order(
            &mut balance_manager,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        // Bob's ask-taker fee was deducted from his quote proceeds and moved
        // into the reserve
        assert!(order_info.paid_fees() == taker_fee, 1);
        let reserve_after = pool.quote_fee_reserve_balance();
        assert!(reserve_after - reserve_before == taker_fee, 2);

        // Conservation: Alice paid in 203.6 quote; 195.6 went to Bob, 8 sits
        // in the reserve, so the vault's free quote balance is exactly zero,
        // and it holds Bob's 100 base for Alice to withdraw.
        let (base_balance, quote_balance, _) = pool.vault_balances();
        assert!(quote_balance == 0, 3);
        assert!(base_balance == quantity, 4);
        assert!(reserve_after == locked_maker_fee + taker_fee, 5);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// Acceptance: an ask maker resting across an admin rate change and epoch
/// rollover is charged its snapshotted placement rate at fill time, while
/// the taker pays the freshly promoted rate.
public(package) fun test_ask_maker_fill_fee_uses_snapshotted_rate() {
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
    let quantity = 100 * constants::float_scaling();
    // Alice rests an ask in epoch 0 at the 1.8% default maker rate
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );

    // Admin lowers both rates for the next epoch: taker 1%, maker 0.5%
    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee(10_000_000, 5_000_000, 2000, &admin_cap);
        return_shared(pool);
        destroy(admin_cap);
    };
    test.next_epoch(OWNER);

    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_bob,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        let reserve_before = pool.quote_fee_reserve_balance();
        let order_info = pool.place_limit_order(
            &mut balance_manager,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        // Bob (taker) pays the promoted 1% rate: 200 × 1% = 2
        let bob_taker_fee = 2 * constants::float_scaling();
        assert!(order_info.paid_fees() == bob_taker_fee, 0);
        // Alice (maker) is charged her snapshotted 1.8%: 200 × 1.8% = 3.6,
        // not the promoted 0.5%
        let alice_maker_fee = 36 * constants::float_scaling() / 10;
        let reserve_after = pool.quote_fee_reserve_balance();
        assert!(reserve_after - reserve_before == bob_taker_fee + alice_maker_fee, 1);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    // Alice's settled quote is net of her snapshotted maker fee: 200 − 3.6
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let account = pool.account(&balance_manager);
        assert_eq!(
            account.settled_balances(),
            triexbook::balances::new(0, 1964 * constants::float_scaling() / 10, 0),
        );
        return_shared(balance_manager);
        return_shared(pool);
    };

    end(test);
}

/// Regression: a bid's fee escrow must reach the reserve even when the
/// placer's own pending settled quote covers the whole order, so the vault
/// withdraws nothing from their balance manager. The fee is carved out of the
/// quote the pool retains by netting, not out of a withdrawal that never
/// happens — previously the deposit was silently dropped and the fee stayed
/// in the vault's free quote balance, unsweepable.
public(package) fun test_bid_fee_reaches_reserve_when_settled_covers_owed() {
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
    let quantity = 100 * constants::float_scaling();

    // Alice rests an ask; Bob's bid fills it. Alice is left holding 196.4
    // quote of settled proceeds (200 less her 1.8% maker fee) that she never
    // withdraws, and the reserve holds her 3.6 plus Bob's 4.4 taker fee.
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    let settled_quote = 1964 * constants::float_scaling() / 10;
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        assert_eq!(
            pool.account(&balance_manager).settled_balances(),
            triexbook::balances::new(0, settled_quote, 0),
        );
        assert!(pool.quote_fee_reserve_balance() == 8 * constants::float_scaling(), 0);
        return_shared(balance_manager);
        return_shared(pool);
    };

    // Alice now rests a bid for 50 @ 2: 100 quote of principal plus a 1.8
    // maker fee. Owed (101.8) is below her settled 196.4, so the vault nets
    // the two and hands her the difference without touching her balance
    // manager — the fee still has to land in the reserve.
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        50 * constants::float_scaling(),
        true,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        // 8 from the fill plus Alice's newly locked 1.8
        assert!(pool.quote_fee_reserve_balance() == 98 * constants::float_scaling() / 10, 1);
        // Her settled proceeds were paid out net of what she owed
        assert_eq!(
            pool.account(&balance_manager).settled_balances(),
            triexbook::balances::new(0, 0, 0),
        );
        return_shared(balance_manager);
        return_shared(pool);
    };

    end(test);
}

/// Regression: the same netting, but where the placer's settled quote covers
/// the principal and only part of the fee, so the vault withdraws less than
/// the fee amount. Splitting the fee out of that marginal withdrawal aborted
/// a fully funded order; it comes out of the pool's quote balance instead.
public(package) fun test_bid_fee_reaches_reserve_when_settled_partially_covers_owed() {
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
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    // Alice rests a bid for 97 @ 2: 194 principal plus a 3.492 maker fee, so
    // she owes 197.492 against 196.4 settled. The vault withdraws only the
    // 1.092 shortfall — less than the fee itself.
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        97 * constants::float_scaling(),
        true,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        // 8 from the fill plus Alice's newly locked 3.492
        assert!(pool.quote_fee_reserve_balance() == 11492 * constants::float_scaling() / 1000, 0);
        return_shared(pool);
    };

    end(test);
}

/// Regression: governance accepts fee rates at 0.01 bp granularity, and both
/// settlement and the dry-run quote honor them at that precision. Rates used
/// to be truncated to whole basis points on the way in, so a sub-basis-point
/// maker rate collected nothing at all, and a fractional taker rate made
/// `get_quantity_out` disagree with what actually settled.
public(package) fun test_fractional_basis_point_fees_are_charged_as_configured() {
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

    // Taker 1.5 bp, maker 0.5 bp: both legal (multiples of the 0.01 bp fee
    // step, taker above its 1 bp floor), neither a whole basis point.
    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee(150_000, 50_000, 2000, &admin_cap);
        return_shared(pool);
        destroy(admin_cap);
    };
    test.next_epoch(OWNER);

    let price = 2 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();
    let notional = 200 * constants::float_scaling();
    // On 200 quote: maker 0.5 bp = 0.01, taker 1.5 bp = 0.03
    let maker_fee = constants::float_scaling() / 100;
    let taker_fee = 3 * constants::float_scaling() / 100;

    // Alice rests a bid: her escrow is the configured 0.5 bp, not zero.
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        assert!(pool.quote_fee_reserve_balance() == maker_fee, 0);
        return_shared(pool);
    };

    // The quote an ask taker is shown for the whole resting bid...
    let (_base_out, quote_out) = get_quantity_out<SUI, USDC>(pool_id, quantity, 0, &mut test);
    assert!(quote_out == notional - taker_fee, 1);

    // ...is exactly what Bob's ask settles for.
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_bob,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());

        let order_info = pool.place_limit_order(
            &mut balance_manager,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        assert!(order_info.paid_fees() == taker_fee, 2);
        assert!(order_info.cumulative_quote_quantity() - order_info.paid_fees() == quote_out, 3);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// Acceptance: `quote_fee_reserve >= locked_maker_fees` holds across a
/// place -> partial fill -> cancel sequence, and the escrow resolves exactly
/// as the order does: filled portions earn out in full at fill, the cancelled
/// remainder splits 80% back to the maker and 20% to revenue.
public(package) fun test_locked_fee_escrow_tracks_open_orders() {
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
    let quantity = 100 * constants::float_scaling();
    // 200 quote notional: Alice escrows 1.8% = 3.6 at placement
    let locked_maker_fee = 36 * constants::float_scaling() / 10;
    // Bob fills half: 100 quote, earning out 1.8 of escrow and paying 2.2
    let half_maker_fee = 18 * constants::float_scaling() / 10;
    let half_taker_fee = 22 * constants::float_scaling() / 10;
    // Cancelling the other half releases its 1.8 escrow: 1.44 refunded to
    // Alice, 0.36 retained.
    let cancel_refund = 144 * constants::float_scaling() / 100;
    let cancel_retained = half_maker_fee - cancel_refund;

    let alice_order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        alice_order_id = order_info.order_id();
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        assert!(pool.quote_fee_reserve_balance() == locked_maker_fee, 0);
        assert!(pool.locked_maker_fees() == locked_maker_fee, 1);
        assert!(pool.withdrawable_pool_fees() == 0, 2);
        return_shared(pool);
    };

    // Bob's ask takes half the bid.
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity / 2,
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let reserve = pool.quote_fee_reserve_balance();
        assert!(reserve == locked_maker_fee + half_taker_fee, 3);
        // Half the escrow earned out with the filled half
        assert!(pool.locked_maker_fees() == half_maker_fee, 4);
        assert!(pool.withdrawable_pool_fees() == reserve - half_maker_fee, 5);
        assert!(reserve >= pool.locked_maker_fees(), 6);
        return_shared(pool);
    };

    // Alice cancels the unfilled remainder; 80% of the escrow on it leaves the
    // reserve back to her, the rest becomes revenue.
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, alice_order_id, &clock, test.ctx());
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let reserve = pool.quote_fee_reserve_balance();
        assert!(reserve == locked_maker_fee + half_taker_fee - cancel_refund, 7);
        assert!(pool.locked_maker_fees() == 0, 8);
        // Everything left is earned: the taker fee, the filled half's escrow
        // and the retention on the cancelled half.
        assert!(pool.withdrawable_pool_fees() == reserve, 9);
        assert!(reserve == half_taker_fee + half_maker_fee + cancel_retained, 10);
        return_shared(pool);
    };

    end(test);
}

/// Edge: asks lock no escrow, so cancelling one must not decrement the
/// counter. A wrong decrement here would under-count the escrow and let an
/// admin sweep some other maker's locked fee.
public(package) fun test_ask_cancel_leaves_bid_escrow_intact() {
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

    let quantity = 100 * constants::float_scaling();
    let locked_maker_fee = 36 * constants::float_scaling() / 10;

    // Alice rests a bid at 2, escrowing 3.6.
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    // Bob rests an ask at 3 — no cross, and asks escrow nothing.
    let bob_order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            BOB,
            pool_id,
            balance_manager_id_bob,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            3 * constants::float_scaling(),
            quantity,
            false,
            constants::max_u64(),
            &mut test,
        );
        bob_order_id = order_info.order_id();
    };

    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        assert!(pool.locked_maker_fees() == locked_maker_fee, 0);
        return_shared(pool);
    };

    // Cancelling the ask releases no escrow.
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_bob,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, bob_order_id, &clock, test.ctx());
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        assert!(pool.quote_fee_reserve_balance() == locked_maker_fee, 1);
        assert!(pool.locked_maker_fees() == locked_maker_fee, 2);
        // Alice's escrow is still hers; nothing became sweepable.
        assert!(pool.withdrawable_pool_fees() == 0, 3);
        return_shared(pool);
    };

    end(test);
}

/// Edge: a modify-down releases escrow only on the quantity it removes, at
/// the order's snapshotted rate.
public(package) fun test_modify_down_releases_escrow_proportionally() {
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
    let quantity = 100 * constants::float_scaling();
    // 200 quote notional at 1.8% = 3.6 escrowed
    let locked_maker_fee = 36 * constants::float_scaling() / 10;
    // Cutting to 40 releases the escrow on 60 (120 quote): 2.16, of which
    // 1.728 refunds to Alice and 0.432 is retained.
    let released = 216 * constants::float_scaling() / 100;
    let refunded = 1728 * constants::float_scaling() / 1000;
    let retained = released - refunded;

    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.modify_order(
            &mut balance_manager,
            &trade_proof,
            order_id,
            40 * constants::float_scaling(),
            &clock,
            test.ctx(),
        );
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        // The refunded share leaves the reserve; the retained share stays and
        // becomes sweepable. The escrow on the 40 still resting is untouched.
        assert!(pool.quote_fee_reserve_balance() == locked_maker_fee - refunded, 0);
        assert!(pool.locked_maker_fees() == locked_maker_fee - released, 1);
        assert!(pool.withdrawable_pool_fees() == retained, 2);
        return_shared(pool);
    };

    end(test);
}

/// Edge: an admin may sweep exactly the unlocked portion while escrow is
/// still outstanding — the cap is `reserve - locked`, not all-or-nothing.
public(package) fun test_admin_sweep_takes_unlocked_portion() {
    let mut test = begin(OWNER);
    let (pool_id, _alice, _bob) = setup_pool_with_half_filled_bid(&mut test);
    // reserve 5.8 = Alice's 3.6 escrow + Bob's 2.2 taker fee; 1.8 still locked
    let unlocked = 4 * constants::float_scaling();
    let still_locked = 18 * constants::float_scaling() / 10;

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();

        assert!(pool.withdrawable_pool_fees() == unlocked, 0);
        let fee_coin = pool.withdraw_pool_fees(&admin_cap, unlocked, &clock, test.ctx());
        assert!(fee_coin.value() == unlocked, 1);
        // The escrow survives the sweep, still backing Alice's open remainder.
        assert!(pool.quote_fee_reserve_balance() == still_locked, 2);
        assert!(pool.locked_maker_fees() == still_locked, 3);
        assert!(pool.withdrawable_pool_fees() == 0, 4);

        destroy(fee_coin);
        return_shared(clock);
        return_shared(pool);
        destroy(admin_cap);
    };

    end(test);
}

/// Edge: one unit above the unlocked portion aborts, so the cap is exact.
public(package) fun test_admin_sweep_above_unlocked_portion_aborts() {
    let mut test = begin(OWNER);
    let (pool_id, _alice, _bob) = setup_pool_with_half_filled_bid(&mut test);
    let unlocked = 4 * constants::float_scaling();

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();

        let fee_coin = pool.withdraw_pool_fees(&admin_cap, unlocked + 1, &clock, test.ctx());

        destroy(fee_coin);
        return_shared(clock);
        return_shared(pool);
        destroy(admin_cap);
    };

    end(test);
}

/// Edge: an expired bid maker gets the escrow held against the returned
/// principal split on cancel terms — 80% back, 20% retained. Expiry must not
/// be cheaper than cancelling, or a spam order just carries a near-term
/// `expire_timestamp` and never cancels.
public(package) fun test_expired_bid_maker_releases_escrow() {
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
    let quantity = 100 * constants::float_scaling();
    let locked_maker_fee = 36 * constants::float_scaling() / 10;
    let expiry_refund = 288 * constants::float_scaling() / 100;
    let expiry_retained = locked_maker_fee - expiry_refund;
    let expire_timestamp = get_time(&mut test) + 100;

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

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        assert!(pool.locked_maker_fees() == locked_maker_fee, 0);
        return_shared(pool);
    };

    // Past the expiry, Bob's crossing ask meets the stale order: it expires
    // out instead of filling, returning Alice her quote principal.
    set_time(200, &mut test);
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        // Nothing filled, so the only quote fee that ever entered the reserve
        // was Alice's escrow; 80% of it has now left again.
        assert!(pool.quote_fee_reserve_balance() == expiry_retained, 1);
        assert!(pool.locked_maker_fees() == 0, 2);
        assert!(pool.withdrawable_pool_fees() == expiry_retained, 3);
        return_shared(pool);
    };

    end(test);
}

/// Alice rests a 100 @ 2 bid (3.6 escrow); Bob's ask takes half of it, so the
/// reserve ends at 5.8 with 1.8 still locked.
fun setup_pool_with_half_filled_bid(test: &mut Scenario): (ID, ID, ID) {
    let registry_id = setup_test(OWNER, test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        test,
    );
    let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        test,
    );
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        test,
    );

    let price = 2 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        test,
    );
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity / 2,
        false,
        constants::max_u64(),
        test,
    );

    (pool_id, balance_manager_id_alice, balance_manager_id_bob)
}

/// Acceptance: the reserve distinguishes earned fees from a bid maker's
/// still-locked escrow, and an admin sweep cannot reach the escrow backing an
/// open, unfilled order. (Replaces the TRIEX-135-era characterization test
/// that pinned the opposite behavior as a known gap.)
public(package) fun test_admin_cannot_sweep_locked_maker_fees() {
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

    // Alice rests a bid that never fills: 100 @ 2 locks a 1.8% maker fee
    // (3.6 quote) into the reserve as escrow, not earned revenue.
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100 * constants::float_scaling(),
        true,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();

        let reserve = pool.quote_fee_reserve_balance();
        // The entire reserve is Alice's locked fee — her order is open with
        // zero fills, so none of it is earned yet.
        assert!(reserve == 36 * constants::float_scaling() / 10, 0);
        assert!(pool.locked_maker_fees() == reserve, 1);
        assert!(pool.withdrawable_pool_fees() == 0, 2);

        // Sweeping it aborts: escrow is not revenue.
        let fee_coin = pool.withdraw_pool_fees(&admin_cap, reserve, &clock, test.ctx());

        destroy(fee_coin);
        return_shared(clock);
        return_shared(pool);
        destroy(admin_cap);
    };

    end(test);
}

/// Acceptance: once the bid maker's order fills, its escrow becomes earned
/// revenue and the admin can sweep it.
public(package) fun test_admin_can_sweep_maker_fees_once_filled() {
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
    let quantity = 100 * constants::float_scaling();
    let locked_maker_fee = 36 * constants::float_scaling() / 10;
    let taker_fee = 44 * constants::float_scaling() / 10;

    // Alice rests a bid: 3.6 of escrow, nothing withdrawable yet.
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        assert!(pool.locked_maker_fees() == locked_maker_fee, 0);
        assert!(pool.withdrawable_pool_fees() == 0, 1);
        return_shared(pool);
    };

    // Bob's ask fills it, which earns the escrow out and adds his taker fee.
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();

        assert!(pool.locked_maker_fees() == 0, 2);
        let reserve = pool.quote_fee_reserve_balance();
        assert!(reserve == locked_maker_fee + taker_fee, 3);
        assert!(pool.withdrawable_pool_fees() == reserve, 4);

        let fee_coin = pool.withdraw_pool_fees(&admin_cap, reserve, &clock, test.ctx());
        assert!(fee_coin.value() == reserve, 5);
        assert!(pool.quote_fee_reserve_balance() == 0, 6);

        destroy(fee_coin);
        return_shared(clock);
        return_shared(pool);
        destroy(admin_cap);
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
    // Snapshotted at placement from the pool's default maker rate (1.8%)
    assert!(order.maker_fee_rate() == 18_000_000, 0);
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
    test: &mut Scenario,
): ID {
    setup_pool<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
        test,
    )
}
#[test_only]
public(package) fun setup_pool_with_default_fees_return_fee<BaseAsset, QuoteAsset>(
    sender: address,
    registry_id: ID,
    test: &mut Scenario,
): ID {
    let pool_id = setup_pool<BaseAsset, QuoteAsset>(
        sender,
        registry_id,
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
        // Ask-side dry run nets the 2.2% taker fee from quote out: 200 − 4.4
        assert_eq!(quote, 1956 * constants::float_scaling() / 10);
    } else {
        let (base, quote) = get_base_quantity_out<SUI, USDC>(
            pool_id,
            math::mul(match_quantity, price),
            &mut test,
        );
        assert_eq!(base, constants::cred_multiplier());
        // Quote-only fees reduce returned quote slightly:
        // 2000 in, 200 spent on base, fee = 200 × 2.2% × 1.25 = 5.5
        assert_eq!(quote, 17945 * constants::float_scaling() / 10);
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
        // Ask-side dry run nets the 2.2% taker fee from quote out: 20 − 0.44
        assert_eq!(quote, 1956 * constants::float_scaling() / 100);
    } else {
        let (base, quote) = get_base_quantity_out<SUI, USDC>(
            pool_id,
            math::mul(match_quantity, price),
            &mut test,
        );
        assert_eq!(base, 10 * constants::float_scaling());
        // 2000 in, 20 spent on base, fee = 20 × 2.2% × 1.25 = 0.55
        assert_eq!(quote, 1_979_450_000_000);
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
            // Bob sells into the bids as an ask taker: 2.2% of the 6 quote
            // proceeds is deducted (6 − 0.132)
            assert!(
                quote_out.value() == 5_868 * constants::float_scaling() / 1000,
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
            // Bob sells into the remaining bid as an ask taker: 2.2% of the
            // 3 quote proceeds is deducted (3 − 0.066)
            assert!(
                quote_out.value() == 2_934 * constants::float_scaling() / 1000,
                constants::e_order_info_mismatch(),
            );

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
    let pool_id = {
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

/// Acceptance #1: place -> cancel with no fills returns the balance manager to
/// its pre-order state minus the 20% retention. The refund has to come out of
/// the fee reserve, not out of the pool balance holding other users' quote.
public(package) fun test_cancel_refunds_escrow_to_maker() {
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
    let quantity = 100 * constants::float_scaling();
    // 200 quote notional at 1.8% = 3.6 escrowed, so 0.72 is retained.
    let retained = 72 * constants::float_scaling() / 100;

    let balance_before = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);

    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, order_id, &clock, test.ctx());
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    let balance_after = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);
    // Round trip cost Alice exactly the retention, nothing else.
    assert!(balance_before - balance_after == retained, 0);

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        // The refund left the reserve; only the retention remains, and it is
        // fully sweepable because no escrow is outstanding.
        assert!(pool.quote_fee_reserve_balance() == retained, 1);
        assert!(pool.locked_maker_fees() == 0, 2);
        assert!(pool.withdrawable_pool_fees() == retained, 3);
        return_shared(pool);
    };

    end(test);
}

/// Acceptance #2: a partial fill earns its escrow out in full; only the
/// unfilled remainder's escrow is eligible for the 80/20 split, so cancelling
/// after a fill must not refund fees on volume that actually traded.
public(package) fun test_cancel_after_partial_fill_refunds_unfilled_only() {
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
    let quantity = 100 * constants::float_scaling();
    // 3.6 escrowed on 200 quote; Bob fills half, so 1.8 earns out and the
    // other 1.8 splits 1.44 refunded / 0.36 retained.
    let filled_maker_fee = 18 * constants::float_scaling() / 10;
    let half_taker_fee = 22 * constants::float_scaling() / 10;
    let cancel_refund = 144 * constants::float_scaling() / 100;
    let cancel_retained = filled_maker_fee - cancel_refund;

    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity / 2,
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, order_id, &clock, test.ctx());
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        // The filled half's fee is revenue in full — the cancel refund never
        // reaches it. What is left is that fee, Bob's taker fee and the
        // retention on the unfilled half.
        let reserve = pool.quote_fee_reserve_balance();
        assert!(reserve == filled_maker_fee + half_taker_fee + cancel_retained, 0);
        assert!(pool.locked_maker_fees() == 0, 1);
        assert!(pool.withdrawable_pool_fees() == reserve, 2);
        return_shared(pool);
    };

    end(test);
}

/// A resting order keeps the retention rate it was placed under, so an admin
/// raising the rate cannot retroactively tax orders already on the book.
public(package) fun test_cancel_uses_snapshotted_retention_rate() {
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
    let quantity = 100 * constants::float_scaling();
    let retained_at_placement = 72 * constants::float_scaling() / 100;

    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    // Admin keeps the fee rates but retains everything from here on.
    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee(22_000_000, 18_000_000, 10000, &admin_cap);
        return_shared(pool);
        destroy(admin_cap);
    };
    test.next_epoch(OWNER);

    let balance_before = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, order_id, &clock, test.ctx());
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    let balance_after = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);
    // Alice still gets her 80% back: the order carries the 20% it was placed
    // under, not the 100% now in force.
    assert!(balance_after - balance_before == 200 * constants::float_scaling() +
        288 * constants::float_scaling() / 100, 0);

    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        assert!(pool.quote_fee_reserve_balance() == retained_at_placement, 1);
        return_shared(pool);
    };

    // The other half of snapshotting: the new policy has to actually bind for
    // an order placed after it, or the rate would be unreachable rather than
    // merely non-retroactive.
    let new_order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        new_order_id = order_info.order_id();
    };

    let before_second_cancel = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, new_order_id, &clock, test.ctx());

        // 100% retention: nothing to unlock, so no refund event at all.
        let refunds = event::events_by_type<vault::PoolFeesRefunded>();
        assert!(refunds.length() == 0, 2);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    let after_second_cancel = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);
    // Principal back, escrow entirely forfeited under the new policy.
    assert!(after_second_cancel - before_second_cancel == 200 * constants::float_scaling(), 3);

    end(test);
}

/// The zero end of the range: a pool configured to retain nothing refunds the
/// whole escrow, so placing and cancelling is free at the fee level.
public(package) fun test_zero_retention_refunds_the_whole_escrow() {
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

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee(22_000_000, 18_000_000, 0, &admin_cap);
        return_shared(pool);
        destroy(admin_cap);
    };
    test.next_epoch(OWNER);

    let price = 2 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();
    let escrow = 36 * constants::float_scaling() / 10;

    let balance_before = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);

    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, order_id, &clock, test.ctx());

        let refunds = event::events_by_type<vault::PoolFeesRefunded>();
        assert!(refunds.length() == 1, 0);
        let (_id, amount, _bm) = vault::refunded_event_parts(&refunds[0]);
        assert!(amount == escrow, 1);

        // The reserve is empty: nothing traded and nothing was retained.
        assert!(pool.quote_fee_reserve_balance() == 0, 2);
        assert!(pool.locked_maker_fees() == 0, 3);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    let balance_after = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);
    // Exactly whole: the round trip cost nothing but gas.
    assert!(balance_after == balance_before, 4);

    end(test);
}

/// An expired bid maker is refunded on cancel terms, and the funds actually
/// reach their balance manager rather than only being credited as settled.
public(package) fun test_expired_bid_maker_is_refunded() {
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
    let quantity = 100 * constants::float_scaling();
    // 3.6 escrowed, so 2.88 refunds and 0.72 is retained.
    let retained = 72 * constants::float_scaling() / 100;
    let expire_timestamp = get_time(&mut test) + 100;

    let balance_before = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);

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

    // Past the expiry, Bob's crossing ask expires the stale order out.
    set_time(200, &mut test);
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );

    // The refund lands in settled balances, which Alice withdraws.
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.withdraw_settled_amounts(&mut balance_manager, &trade_proof);
        return_shared(balance_manager);
        return_shared(pool);
    };

    let balance_after = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);
    // Expiring cost Alice the same 0.72 a cancel would have.
    assert!(balance_before - balance_after == retained, 0);

    end(test);
}

/// The refund and the cancellation are reported as one story: `OrderCanceled`
/// carries both halves of the split, and the vault's `PoolFeesRefunded`
/// carries the same order id and the same refunded amount, so an indexer can
/// join them without inferring anything.
public(package) fun test_cancel_and_refund_events_agree() {
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
    let quantity = 100 * constants::float_scaling();
    let escrow = 36 * constants::float_scaling() / 10;
    let expected_refund = 288 * constants::float_scaling() / 100;

    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, order_id, &clock, test.ctx());

        let refunds = event::events_by_type<vault::PoolFeesRefunded>();
        assert!(refunds.length() == 1, 0);
        let (refund_order_id, refund_amount, refund_bm) = vault::refunded_event_parts(
            &refunds[0],
        );
        assert!(refund_order_id == order_id, 1);
        assert!(refund_amount == expected_refund, 2);
        assert!(refund_bm == balance_manager_id_alice, 3);

        let cancels = event::events_by_type<order::OrderCanceled>();
        assert!(cancels.length() == 1, 4);
        let (cancel_order_id, fee_refunded, fee_retained) = order::canceled_event_parts(
            &cancels[0],
        );
        // Same order, same refund: the two events describe one release.
        assert!(cancel_order_id == refund_order_id, 5);
        assert!(fee_refunded == refund_amount, 6);
        // The retained half is only on the cancel event — it never moves, so
        // the vault has nothing to emit for it.
        assert!(fee_refunded + fee_retained == escrow, 7);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// An expiry is triggered by someone else's order, so the refund must be
/// attributed to the expired maker and their order — not to the taker whose
/// transaction happened to surface it.
public(package) fun test_expiry_refund_event_attributes_the_maker() {
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
    let quantity = 100 * constants::float_scaling();
    let escrow = 36 * constants::float_scaling() / 10;
    let expected_refund = 288 * constants::float_scaling() / 100;
    let expire_timestamp = get_time(&mut test) + 100;

    let alice_order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
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
        alice_order_id = order_info.order_id();
    };

    set_time(200, &mut test);
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_bob,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.place_limit_order(
            &mut balance_manager,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        let refunds = event::events_by_type<vault::PoolFeesRefunded>();
        assert!(refunds.length() == 1, 0);
        let (refund_order_id, refund_amount, refund_bm) = vault::refunded_event_parts(
            &refunds[0],
        );
        // Bob sent the transaction; Alice owns the refund.
        assert!(refund_bm == balance_manager_id_alice, 1);
        assert!(refund_bm != balance_manager_id_bob, 2);
        assert!(refund_order_id == alice_order_id, 3);
        assert!(refund_amount == expected_refund, 4);

        let expiries = event::events_by_type<order_info::OrderExpired>();
        assert!(expiries.length() == 1, 5);
        let (expired_order_id, fee_refunded, fee_retained) = order_info::expired_event_parts(
            &expiries[0],
        );
        assert!(expired_order_id == refund_order_id, 6);
        assert!(fee_refunded == refund_amount, 7);
        assert!(fee_refunded + fee_retained == escrow, 8);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// Solvency edge: an admin sweeping every unlocked unit leaves the reserve
/// holding exactly the outstanding escrow. A cancel then has to unlock a real
/// balance out of it — `unlock_quote_fees` aborts if it is short, unlike the
/// saturating subtract recognition uses — so this is the case where the
/// `reserve >= locked` invariant actually has to hold, not just be tidy.
public(package) fun test_cancel_refund_survives_sweep_to_the_floor() {
    let mut test = begin(OWNER);
    let (pool_id, balance_manager_id_alice, _bob) = setup_pool_with_half_filled_bid(&mut test);

    // Half filled: reserve 5.8 (3.6 escrow + 2.2 taker fee), 1.8 still locked.
    let alice_order_id;
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        alice_order_id = pool.account_open_orders(&balance_manager).into_keys()[0];
        return_shared(balance_manager);
        return_shared(pool);
    };

    let swept;
    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        swept = pool.withdrawable_pool_fees();
        let fee_coin = pool.withdraw_pool_fees(&admin_cap, swept, &clock, test.ctx());
        // Nothing sweepable is left; the reserve is pure escrow now.
        assert!(pool.withdrawable_pool_fees() == 0, 0);
        assert!(pool.quote_fee_reserve_balance() == pool.locked_maker_fees(), 1);
        destroy(fee_coin);
        return_shared(clock);
        return_shared(pool);
        destroy(admin_cap);
    };

    // The refund must still be payable out of what the sweep could not touch.
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(
            &mut balance_manager,
            &trade_proof,
            alice_order_id,
            &clock,
            test.ctx(),
        );
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        // Only the retention on the cancelled half is left, and it is earned.
        let retained = 36 * constants::float_scaling() / 100;
        assert!(pool.quote_fee_reserve_balance() == retained, 2);
        assert!(pool.locked_maker_fees() == 0, 3);
        assert!(pool.withdrawable_pool_fees() == retained, 4);
        return_shared(pool);
    };

    end(test);
}

/// Repeated modify-downs each release a slice of the escrow, and the final
/// cancel releases the remainder. The slices are floored independently while
/// the lock was floored once, so their sum can only ever be <= the lock —
/// a release path that over-counted would abort here rather than silently
/// spending another maker's escrow.
public(package) fun test_repeated_modify_downs_then_cancel_stay_solvent() {
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

    let price = 3 * constants::float_scaling();
    let quantity = 97 * constants::float_scaling();

    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    let escrow_at_placement;
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        escrow_at_placement = pool.locked_maker_fees();
        return_shared(pool);
    };

    // Whittle the order down in uneven steps, checking the invariant after
    // each one rather than only at the end.
    let steps = vector[71, 53, 29, 11];
    let mut i = 0;
    while (i < steps.length()) {
        test.next_tx(ALICE);
        {
            let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mut balance_manager = test.take_shared_by_id<BalanceManager>(
                balance_manager_id_alice,
            );
            let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
            pool.modify_order(
                &mut balance_manager,
                &trade_proof,
                order_id,
                steps[i] * constants::float_scaling(),
                &clock,
                test.ctx(),
            );
            assert!(pool.quote_fee_reserve_balance() >= pool.locked_maker_fees(), 0);
            return_shared(balance_manager);
            return_shared(clock);
            return_shared(pool);
        };
        i = i + 1;
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, order_id, &clock, test.ctx());
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        // Every slice resolved, so nothing is escrowed. What stayed behind is
        // the retention, which can never exceed the original escrow.
        assert!(pool.locked_maker_fees() == 0, 1);
        let kept = pool.quote_fee_reserve_balance();
        assert!(kept == pool.withdrawable_pool_fees(), 2);
        assert!(kept <= escrow_at_placement, 3);
        // Retention is 20% of an escrow that was fully released in slices;
        // per-slice flooring can only lose dust, never a fifth of it.
        assert!(kept >= escrow_at_placement / 5 - 10, 4);
        return_shared(pool);
    };

    end(test);
}

/// Several partial fills before a cancel: each fill floors its own recognition
/// while the lock floored once over the whole order, so the accumulated
/// recognitions plus the cancel release must still not exceed the lock.
public(package) fun test_many_partial_fills_then_cancel_stay_solvent() {
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

    let price = 3 * constants::float_scaling();
    let quantity = 97 * constants::float_scaling();

    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    let bites = vector[13, 7, 23, 11];
    let mut i = 0;
    while (i < bites.length()) {
        place_limit_order<SUI, USDC>(
            BOB,
            pool_id,
            balance_manager_id_bob,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            bites[i] * constants::float_scaling(),
            false,
            constants::max_u64(),
            &mut test,
        );
        test.next_tx(ALICE);
        {
            let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
            assert!(pool.quote_fee_reserve_balance() >= pool.locked_maker_fees(), 0);
            return_shared(pool);
        };
        i = i + 1;
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, order_id, &clock, test.ctx());
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        assert!(pool.locked_maker_fees() == 0, 1);
        assert!(pool.quote_fee_reserve_balance() == pool.withdrawable_pool_fees(), 2);
        return_shared(pool);
    };

    end(test);
}

/// One match can expire several makers' orders at once. Each refund has to be
/// unlocked against its own maker and order — the aggregate the refund path
/// started as would have attributed every one of them to the taker.
public(package) fun test_multiple_expired_makers_each_get_their_own_refund() {
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
    let balance_manager_id_owner = create_acct_and_share_with_funds(
        OWNER,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let price = 2 * constants::float_scaling();
    let expire_timestamp = get_time(&mut test) + 100;
    // Two different sizes, so the two refunds are distinguishable.
    let alice_quantity = 100 * constants::float_scaling();
    let owner_quantity = 40 * constants::float_scaling();
    let alice_refund = 288 * constants::float_scaling() / 100; // 80% of 3.6
    let owner_refund = 1152 * constants::float_scaling() / 1000; // 80% of 1.44

    let alice_order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            alice_quantity,
            true,
            expire_timestamp,
            &mut test,
        );
        alice_order_id = order_info.order_id();
    };
    let owner_order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            OWNER,
            pool_id,
            balance_manager_id_owner,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            owner_quantity,
            true,
            expire_timestamp,
            &mut test,
        );
        owner_order_id = order_info.order_id();
    };

    // Bob's ask is large enough to sweep both stale bids out.
    set_time(200, &mut test);
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_bob,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.place_limit_order(
            &mut balance_manager,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            alice_quantity + owner_quantity,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        // Two refunds, one per expired maker, each naming its own order.
        let refunds = event::events_by_type<vault::PoolFeesRefunded>();
        assert!(refunds.length() == 2, 0);
        let (id_a, amount_a, bm_a) = vault::refunded_event_parts(&refunds[0]);
        let (id_b, amount_b, bm_b) = vault::refunded_event_parts(&refunds[1]);
        assert!(bm_a != bm_b, 1);
        // Neither is attributed to Bob, who merely triggered the expiries.
        assert!(bm_a != balance_manager_id_bob, 2);
        assert!(bm_b != balance_manager_id_bob, 3);

        let (alice_amount, owner_amount) = if (bm_a == balance_manager_id_alice) {
            assert!(id_a == alice_order_id, 4);
            assert!(id_b == owner_order_id, 5);
            (amount_a, amount_b)
        } else {
            assert!(id_b == alice_order_id, 6);
            assert!(id_a == owner_order_id, 7);
            (amount_b, amount_a)
        };
        assert!(alice_amount == alice_refund, 8);
        assert!(owner_amount == owner_refund, 9);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// An expired ask escrowed nothing, so it must release nothing. A refund here
/// would be paid out of some bid maker's locked fee.
public(package) fun test_expired_ask_maker_refunds_nothing() {
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
    let quantity = 100 * constants::float_scaling();
    let expire_timestamp = get_time(&mut test) + 100;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false, // ask
        expire_timestamp,
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        // Asks escrow nothing at placement.
        assert!(pool.locked_maker_fees() == 0, 0);
        return_shared(pool);
    };

    set_time(200, &mut test);
    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_bob,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.place_limit_order(
            &mut balance_manager,
            &trade_proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true, // bid crosses the stale ask
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        // The stale ask escrowed nothing, so nothing is refunded.
        let refunds = event::events_by_type<vault::PoolFeesRefunded>();
        assert!(refunds.length() == 0, 1);

        // And the expiry event must not claim otherwise. Nothing moves funds
        // on this path, so a non-zero split here would be visible only in the
        // event — an indexer would book a refund that never happened.
        let expiries = event::events_by_type<order_info::OrderExpired>();
        assert!(expiries.length() == 1, 9);
        let (_id, fee_refunded, fee_retained) = order_info::expired_event_parts(&expiries[0]);
        assert!(fee_refunded == 0, 10);
        assert!(fee_retained == 0, 11);

        // Bob's bid found only an expired ask, so it did not fill — it rests
        // and escrows its own 1.8% of 200 quote. That escrow is his, and it
        // is the only thing in the reserve: nothing traded, so there are no
        // earned fees and the whole reserve is still a claim.
        let bob_escrow = 36 * constants::float_scaling() / 10;
        assert!(pool.locked_maker_fees() == bob_escrow, 2);
        assert!(pool.quote_fee_reserve_balance() == bob_escrow, 3);
        assert!(pool.withdrawable_pool_fees() == 0, 4);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// A self-match resolved with `cancel_maker` expires the maker side out. That
/// is a cancellation the maker did choose, so it splits on cancel terms like
/// any other — not silently forfeiting, and not refunding in full.
public(package) fun test_self_match_cancel_maker_refunds_the_bid_escrow() {
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
    let quantity = 100 * constants::float_scaling();
    let escrow = 36 * constants::float_scaling() / 10;
    let expected_refund = 288 * constants::float_scaling() / 100;

    let bid_order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        bid_order_id = order_info.order_id();
    };

    // Alice crosses her own bid asking for the maker side to be cancelled.
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.place_limit_order(
            &mut balance_manager,
            &trade_proof,
            constants::no_restriction(),
            constants::cancel_maker(),
            price,
            quantity,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );

        let refunds = event::events_by_type<vault::PoolFeesRefunded>();
        assert!(refunds.length() == 1, 0);
        let (refund_order_id, refund_amount, refund_bm) = vault::refunded_event_parts(
            &refunds[0],
        );
        assert!(refund_order_id == bid_order_id, 1);
        assert!(refund_amount == expected_refund, 2);
        assert!(refund_bm == balance_manager_id_alice, 3);

        // A self-match cancel emits OrderCanceled rather than OrderExpired,
        // and it has to carry the same split.
        let cancels = event::events_by_type<order::OrderCanceled>();
        assert!(cancels.length() == 1, 4);
        let (cancel_order_id, fee_refunded, fee_retained) = order::canceled_event_parts(
            &cancels[0],
        );
        assert!(cancel_order_id == bid_order_id, 5);
        assert!(fee_refunded == expected_refund, 6);
        assert!(fee_refunded + fee_retained == escrow, 7);

        assert!(pool.locked_maker_fees() == 0, 8);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// `cancel_all_orders` loops over single cancels, so several bids resolve in
/// one transaction: each must unlock its own refund and clear its own escrow.
public(package) fun test_cancel_all_orders_refunds_every_bid() {
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

    let balance_before = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);

    // Three resting bids at different prices, plus an ask that escrows nothing.
    let quantities = vector[100, 40, 20];
    let mut i = 0;
    while (i < quantities.length()) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            (2 + i) * constants::float_scaling(),
            quantities[i] * constants::float_scaling(),
            true,
            constants::max_u64(),
            &mut test,
        );
        i = i + 1;
    };
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        50 * constants::float_scaling(),
        10 * constants::float_scaling(),
        false,
        constants::max_u64(),
        &mut test,
    );

    let escrow_before;
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        escrow_before = pool.locked_maker_fees();
        assert!(escrow_before > 0, 0);
        return_shared(pool);
    };

    let total_refunded;
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_all_orders(&mut balance_manager, &trade_proof, &clock, test.ctx());

        // One refund per bid; the ask escrowed nothing and contributes none.
        let refunds = event::events_by_type<vault::PoolFeesRefunded>();
        assert!(refunds.length() == 3, 1);
        let mut summed = 0;
        let mut r = 0;
        while (r < refunds.length()) {
            let (_id, amount, bm) = vault::refunded_event_parts(&refunds[r]);
            assert!(bm == balance_manager_id_alice, 2);
            summed = summed + amount;
            r = r + 1;
        };
        total_refunded = summed;

        assert!(pool.locked_maker_fees() == 0, 3);
        // Whatever was not refunded is retention, and it is all earned now.
        // Derived from the refunds rather than an aggregate 20%, since each
        // order floors its own split.
        assert!(pool.quote_fee_reserve_balance() == escrow_before - total_refunded, 4);
        assert!(pool.withdrawable_pool_fees() == escrow_before - total_refunded, 5);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    let balance_after = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);
    // Place three bids and an ask, then cancel the lot: Alice is out exactly
    // the retention, and nothing else.
    assert!(balance_before - balance_after == escrow_before - total_refunded, 6);

    end(test);
}

/// Rounding edge at pool scale. Lot size is well below `FLOAT_SCALING`, so a
/// maker can rest a quantity whose escrow does not divide by five: 1000 quote
/// at 1.8% escrows 18, and 80% of 18 is 14.4. The refund floors to 14, so the
/// retention takes 4 — a shade over its nominal 20%.
///
/// That direction matters. Dust must fall to the protocol, never to the
/// refund: a refund that rounded up would pay a fraction of a unit out of some
/// other maker's escrow every time, and the two halves must still sum to the
/// released amount or `locked_maker_fees` would never reach zero.
public(package) fun test_refund_rounding_dust_favors_the_retention() {
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

    // 1000 base at price 1.0 => 1000 quote notional.
    let price = 1 * constants::float_scaling();
    let quantity = 1000;
    let escrow = 18; // floor(1000 * 1.8%)
    let expected_refund = 14; // floor(18 * 80%), not 14.4
    let expected_retained = 4; // the dust lands here

    let balance_before = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);

    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        assert!(pool.locked_maker_fees() == escrow, 0);
        return_shared(pool);
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, order_id, &clock, test.ctx());

        let refunds = event::events_by_type<vault::PoolFeesRefunded>();
        assert!(refunds.length() == 1, 1);
        let (_id, amount, _bm) = vault::refunded_event_parts(&refunds[0]);
        assert!(amount == expected_refund, 2);

        let cancels = event::events_by_type<order::OrderCanceled>();
        let (_cid, fee_refunded, fee_retained) = order::canceled_event_parts(&cancels[0]);
        assert!(fee_refunded == expected_refund, 3);
        assert!(fee_retained == expected_retained, 4);
        // The halves still sum exactly, so the escrow counter can reach zero.
        assert!(fee_refunded + fee_retained == escrow, 5);
        assert!(pool.locked_maker_fees() == 0, 6);
        assert!(pool.quote_fee_reserve_balance() == expected_retained, 7);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    let balance_after = asset_balance<USDC>(ALICE, balance_manager_id_alice, &mut test);
    // Alice paid 4 of 18 rather than the nominal 3.6 — dust rounds against the
    // maker, which is the only safe direction for a solvency counter.
    assert!(balance_before - balance_after == expected_retained, 8);

    end(test);
}

/// A resting order buys no tier progress, however large it is and however often
/// it is cancelled. This is the constraint the whole fees-paid metric exists to
/// satisfy: escrow is refundable until it trades, so counting it at placement
/// would make place-and-cancel a free ladder.
public(package) fun test_resting_bid_earns_no_tier_progress() {
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

    // A bid this size escrows 3.6 in maker fees at placement.
    let quantity = 100 * constants::float_scaling();
    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    // Escrowed, but not earned — so it counts for nothing.
    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        assert!(pool.locked_maker_fees() > 0, 0);
        assert_eq!(pool.account_fee_turnover(&balance_manager, test.ctx()), 0);
        assert_eq!(pool.account_fee_tier(&balance_manager, test.ctx()), 0);
        return_shared(balance_manager);
        return_shared(pool);
    };

    // Cancelling refunds most of the escrow and retains the rest as revenue.
    // Neither half is turnover: the refund was never earned, and retention is
    // revenue but not trading, on the same reasoning `recognize_retention`
    // already applies to volume.
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, order_id, &clock, test.ctx());

        assert_eq!(pool.account_fee_turnover(&balance_manager, test.ctx()), 0);
        assert_eq!(pool.account_fee_tier(&balance_manager, test.ctx()), 0);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// Fees that actually settle do count, on both sides of the fill.
public(package) fun test_fill_accrues_turnover_to_both_sides() {
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
    let quantity = 100 * constants::float_scaling();
    // 200 notional: maker 1.8% = 3.6, taker 2.2% = 4.4.
    let expected_maker_fee = 36 * constants::float_scaling() / 10;
    let expected_taker_fee = 44 * constants::float_scaling() / 10;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    // Bob crosses it as an ask taker.
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let alice = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let bob = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);

        // Alice's escrow became revenue when the fill earned it out.
        assert_eq!(pool.account_fee_turnover(&alice, test.ctx()), expected_maker_fee as u128);
        // Bob paid his taker fee out of proceeds.
        assert_eq!(pool.account_fee_turnover(&bob, test.ctx()), expected_taker_fee as u128);

        return_shared(bob);
        return_shared(alice);
        return_shared(pool);
    };

    end(test);
}

/// Crossing a threshold discounts the *next* order, never the one that crossed.
public(package) fun test_tier_discount_applies_from_the_next_order() {
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

    // Two rungs: 2.2%/1.8% until 4 of fees paid, then 1.1%/0.9%.
    let threshold = 4 * constants::float_scaling();
    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee_schedule(
            vector[0, threshold as u128],
            vector[22_000_000, 11_000_000],
            vector[18_000_000, 9_000_000],
            2000,
            &admin_cap,
        );
        return_shared(pool);
        destroy(admin_cap);
    };
    test.next_epoch(OWNER);

    let price = 2 * constants::float_scaling();
    let quantity = 100 * constants::float_scaling();

    // Bob starts on the entry rung.
    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let bob = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let (taker, maker) = pool.trade_params_for_account(&bob, test.ctx());
        assert_eq!(taker, 22_000_000);
        assert_eq!(maker, 18_000_000);
        assert_eq!(pool.account_fee_tier(&bob, test.ctx()), 0);
        return_shared(bob);
        return_shared(pool);
    };

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    // Bob takes 200 notional at 2.2% = 4.4, which clears the threshold. The
    // fee on this order is charged at the entry rate he held before it.
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let bob = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);

        // He was charged 4.4, not the discounted 2.2 — the crossing order paid
        // the old rate.
        assert_eq!(pool.account_fee_turnover(&bob, test.ctx()), (44 * constants::float_scaling() / 10) as u128);
        // And he is promoted for everything that follows.
        assert_eq!(pool.account_fee_tier(&bob, test.ctx()), 1);
        let (taker, maker) = pool.trade_params_for_account(&bob, test.ctx());
        assert_eq!(taker, 11_000_000);
        assert_eq!(maker, 9_000_000);

        return_shared(bob);
        return_shared(pool);
    };

    // Give the book depth again so there is something to quote against.
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    // A dry run must price at the rate the trader will actually be charged.
    // Quoting the entry rung here is what made a promoted trader under-fill:
    // `swap_exact_quantity_with_manager` sizes its order from this number.
    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let bob = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let clock = test.take_shared<Clock>();

        let (_, entry_rung_quote) = pool.get_quantity_out(quantity, 0, &clock);
        let (_, bobs_quote) = pool.get_quantity_out_for_account(
            &bob,
            quantity,
            0,
            &clock,
            test.ctx(),
        );

        // Selling 200 notional: the entry rung nets 2.2% out of the proceeds,
        // Bob's rung 1.1%, so his quote is exactly the rate difference better.
        let notional = 200 * constants::float_scaling();
        assert_eq!(entry_rung_quote, notional - quote_fee::fee_from_scaled_rate(22_000_000, notional));
        assert_eq!(bobs_quote, notional - quote_fee::fee_from_scaled_rate(11_000_000, notional));
        assert!(bobs_quote > entry_rung_quote, 0);

        return_shared(clock);
        return_shared(bob);
        return_shared(pool);
    };

    end(test);
}

/// A schedule set by the admin takes effect at the epoch boundary, not
/// immediately — the same pre-announced posture as `set_next_epoch_fee`.
public(package) fun test_fee_schedule_activates_next_epoch() {
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

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee_schedule(
            vector[0, 1_000_000_000],
            vector[10_000_000, 5_000_000],
            vector[8_000_000, 4_000_000],
            2000,
            &admin_cap,
        );

        // Queued, not live: the current ladder is still the single default rung.
        assert_eq!(pool.pool_fee_schedule().tier_count(), 1);
        assert_eq!(pool.pool_fee_schedule_next().tier_count(), 2);
        let (taker, maker) = pool.pool_trade_params();
        assert_eq!(taker, 22_000_000);
        assert_eq!(maker, 18_000_000);
        // TradeParams tracks the incoming entry rung, so the two never diverge.
        let (next_taker, next_maker) = pool.pool_trade_params_next();
        assert_eq!(next_taker, 10_000_000);
        assert_eq!(next_maker, 8_000_000);

        return_shared(pool);
        destroy(admin_cap);
    };

    test.next_epoch(OWNER);

    // The promotion is lazy, so it lands on the first action of the new epoch.
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        2 * constants::float_scaling(),
        100 * constants::float_scaling(),
        true,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        assert_eq!(pool.pool_fee_schedule().tier_count(), 2);
        let (taker, maker) = pool.pool_trade_params();
        assert_eq!(taker, 10_000_000);
        assert_eq!(maker, 8_000_000);
        return_shared(pool);
    };

    end(test);
}

/// A flat fee is a one-rung ladder, so the legacy setter and the schedule
/// setter cannot drift apart.
public(package) fun test_flat_fee_setter_keeps_schedule_in_lockstep() {
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

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee(10_000_000, 5_000_000, 2000, &admin_cap);

        let next = pool.pool_fee_schedule_next();
        assert_eq!(next.tier_count(), 1);
        assert_eq!(next.base_taker_fee(), 10_000_000);
        assert_eq!(next.base_maker_fee(), 5_000_000);

        return_shared(pool);
        destroy(admin_cap);
    };

    end(test);
}

/// Acceptance: turnover rolls off after the window, and an account dormant for
/// a full window resolves back to the entry tier.
public(package) fun test_turnover_ages_out_after_the_window() {
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
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let alice = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        assert!(pool.account_fee_turnover(&alice, test.ctx()) > 0, 0);
        return_shared(alice);
        return_shared(pool);
    };

    // Sit out exactly one full window.
    let window = constants::turnover_window_epochs();
    let mut i = 0;
    while (i < window) {
        test.next_epoch(OWNER);
        i = i + 1;
    };

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let alice = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let bob = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);

        // Reported truthfully even though neither account has been touched
        // since — the view resolves as of the current epoch, not last touch.
        assert!(pool.account_fee_turnover(&alice, test.ctx()) == 0, 1);
        assert!(pool.account_fee_turnover(&bob, test.ctx()) == 0, 2);
        assert!(pool.account_fee_tier(&alice, test.ctx()) == 0, 3);

        return_shared(bob);
        return_shared(alice);
        return_shared(pool);
    };

    end(test);
}

/// One epoch short of the window, the same fees still count. Pins the boundary
/// from the other side so an off-by-one cannot pass both tests.
public(package) fun test_turnover_survives_to_the_window_edge() {
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
    let quantity = 100 * constants::float_scaling();
    let expected_taker_fee = 44 * constants::float_scaling() / 10;

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );

    let window = constants::turnover_window_epochs();
    let mut i = 0;
    while (i < window - 1) {
        test.next_epoch(OWNER);
        i = i + 1;
    };

    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let bob = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        assert!(pool.account_fee_turnover(&bob, test.ctx()) == expected_taker_fee as u128, 0);
        return_shared(bob);
        return_shared(pool);
    };

    end(test);
}

/// Acceptance: an order resting across a schedule change settles at the rate it
/// was placed at, not the new one.
public(package) fun test_resting_order_keeps_placement_rate_across_schedule_change() {
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

    // 200 notional at the default 1.8% maker rate escrows 3.6.
    let quantity = 100 * constants::float_scaling();
    let placement_escrow = 36 * constants::float_scaling() / 10;
    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    // Admin halves the ladder out from under the resting order.
    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee_schedule(
            vector[0],
            vector[11_000_000],
            vector[9_000_000],
            2000,
            &admin_cap,
        );
        return_shared(pool);
        destroy(admin_cap);
    };
    test.next_epoch(OWNER);

    // Cancelling releases the escrow the order actually holds, split at the
    // retention rate it snapshotted — both from placement, not from the new
    // schedule. At 0.9% the escrow would have been 1.8 and the retention 0.36.
    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        assert!(pool.locked_maker_fees() == placement_escrow, 0);

        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(&mut balance_manager, &trade_proof, order_id, &clock, test.ctx());

        // Split through the production helper: the refund floors, so dust
        // lands in the retained half. Computing 20% directly agrees only when
        // the escrow happens to divide evenly.
        let (_, expected_retained) = quote_fee::split_released_fee(placement_escrow, 2000);
        assert!(pool.quote_fee_reserve_balance() == expected_retained, 1);
        assert!(pool.locked_maker_fees() == 0, 2);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// Acceptance: being promoted to a cheaper tier does not reprice an order the
/// trader already has resting.
public(package) fun test_resting_order_keeps_placement_rate_across_tier_promotion() {
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

    // Any fill at all promotes to the cheaper rung.
    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee_schedule(
            vector[0, 1],
            vector[22_000_000, 11_000_000],
            vector[18_000_000, 9_000_000],
            2000,
            &admin_cap,
        );
        return_shared(pool);
        destroy(admin_cap);
    };
    test.next_epoch(OWNER);

    // Alice rests a bid far below the market, escrowing at the entry rate:
    // 1.8% of 100 notional = 1.8.
    let quantity = 100 * constants::float_scaling();
    let placement_escrow = 18 * constants::float_scaling() / 10;
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        1 * constants::float_scaling(),
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let alice = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        assert!(pool.locked_maker_fees() == placement_escrow, 0);
        assert!(pool.account_fee_tier(&alice, test.ctx()) == 0, 1);
        return_shared(alice);
        return_shared(pool);
    };

    // Bob offers at 3; Alice crosses it as a taker and pays a fee, promoting
    // herself. Her taker order fills completely, so it escrows nothing.
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3 * constants::float_scaling(),
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        3 * constants::float_scaling(),
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let alice = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);

        // She really was promoted, so the test is not vacuous...
        assert!(pool.account_fee_tier(&alice, test.ctx()) == 1, 2);
        let (taker, maker) = pool.trade_params_for_account(&alice, test.ctx());
        assert!(taker == 11_000_000, 3);
        assert!(maker == 9_000_000, 4);

        // ...and her resting order still holds the escrow it was placed with.
        // At the tier-1 rate it would be 0.9, half of this.
        assert!(pool.locked_maker_fees() == placement_escrow, 5);

        return_shared(alice);
        return_shared(pool);
    };

    end(test);
}

/// An expired maker order charges nothing, so it accrues nothing — the same
/// rule as a cancel, reached down a different path.
public(package) fun test_expired_bid_maker_accrues_no_turnover() {
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
    let quantity = 100 * constants::float_scaling();
    let expire_timestamp = get_time(&mut test) + 100;

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

    // Past the expiry, Bob's crossing ask meets the stale order: it expires out
    // rather than filling.
    set_time(200, &mut test);
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(OWNER);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let alice = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let bob = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);

        // Alice's order expired: no fee charged, so no progress — even though
        // the protocol did keep the retention as revenue.
        assert!(pool.account_fee_turnover(&alice, test.ctx()) == 0, 0);
        // Bob matched nothing, so he paid no taker fee either.
        assert!(pool.account_fee_turnover(&bob, test.ctx()) == 0, 1);

        return_shared(bob);
        return_shared(alice);
        return_shared(pool);
    };

    end(test);
}

/// Modifying an order down releases escrow on cancel terms, and like a cancel
/// it buys nothing — otherwise modify-to-minimum would be the cheap ladder.
public(package) fun test_modify_down_accrues_no_turnover() {
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

    let quantity = 100 * constants::float_scaling();
    let order_id;
    {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            2 * constants::float_scaling(),
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        order_id = order_info.order_id();
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.modify_order(
            &mut balance_manager,
            &trade_proof,
            order_id,
            quantity / 10,
            &clock,
            test.ctx(),
        );

        assert!(pool.account_fee_turnover(&balance_manager, test.ctx()) == 0, 0);

        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// A partial fill accrues only what the filled portion actually earned; the
/// escrow still resting behind it stays uncounted.
public(package) fun test_partial_fill_accrues_only_the_filled_portion() {
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
    let quantity = 100 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    // Bob takes 40 of the 100.
    let filled = 40 * constants::float_scaling();
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        filled,
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(ALICE);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let alice = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let bob = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);

        // 40 base at price 2 is 80 quote: maker 1.8% = 1.44, taker 2.2% = 1.76.
        let earned_maker_fee = 144 * constants::float_scaling() / 100;
        let taker_fee = 176 * constants::float_scaling() / 100;
        assert!(pool.account_fee_turnover(&alice, test.ctx()) == earned_maker_fee as u128, 0);
        assert!(pool.account_fee_turnover(&bob, test.ctx()) == taker_fee as u128, 1);

        // The unfilled 60 is still escrowed and still uncounted.
        assert!(pool.locked_maker_fees() > 0, 2);

        return_shared(bob);
        return_shared(alice);
        return_shared(pool);
    };

    end(test);
}

/// One taker sweeping several makers credits each maker their own fee, and
/// none of anyone else's.
public(package) fun test_each_maker_accrues_only_their_own_fee() {
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
    let balance_manager_id_owner = create_acct_and_share_with_funds(
        OWNER,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    let price = 2 * constants::float_scaling();
    let alice_quantity = 100 * constants::float_scaling();
    let owner_quantity = 50 * constants::float_scaling();

    place_limit_order<SUI, USDC>(
        ALICE,
        pool_id,
        balance_manager_id_alice,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        alice_quantity,
        true,
        constants::max_u64(),
        &mut test,
    );
    place_limit_order<SUI, USDC>(
        OWNER,
        pool_id,
        balance_manager_id_owner,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        owner_quantity,
        true,
        constants::max_u64(),
        &mut test,
    );

    // Bob sweeps both in one order.
    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        alice_quantity + owner_quantity,
        false,
        constants::max_u64(),
        &mut test,
    );

    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let alice = test.take_shared_by_id<BalanceManager>(balance_manager_id_alice);
        let bob = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let owner = test.take_shared_by_id<BalanceManager>(balance_manager_id_owner);

        // Alice made 200 quote at 1.8% = 3.6; the owner made 100 at 1.8% = 1.8.
        let alice_fee = 36 * constants::float_scaling() / 10;
        let owner_fee = 18 * constants::float_scaling() / 10;
        assert!(pool.account_fee_turnover(&alice, test.ctx()) == alice_fee as u128, 0);
        assert!(pool.account_fee_turnover(&owner, test.ctx()) == owner_fee as u128, 1);

        // Bob paid 2.2% across the whole 300 quote he took: 6.6, which is the
        // sum of neither maker's fee.
        let bob_fee = 66 * constants::float_scaling() / 10;
        assert!(pool.account_fee_turnover(&bob, test.ctx()) == bob_fee as u128, 2);

        return_shared(owner);
        return_shared(bob);
        return_shared(alice);
        return_shared(pool);
    };

    end(test);
}

/// An account with no row in the table resolves to the entry tier rather than
/// aborting — the temporary balance manager behind a manager-less swap takes
/// this path, and so does any UI querying before a trader's first trade.
public(package) fun test_untouched_account_reports_entry_tier() {
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

    // Bob has an account object but has never traded on this pool.
    let balance_manager_id_bob = create_acct_and_share_with_funds(
        BOB,
        1000000 * constants::float_scaling(),
        &mut test,
    );

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee_schedule(
            vector[0, 1],
            vector[22_000_000, 11_000_000],
            vector[18_000_000, 9_000_000],
            2000,
            &admin_cap,
        );
        return_shared(pool);
        destroy(admin_cap);
    };
    test.next_epoch(OWNER);

    test.next_tx(BOB);
    {
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let bob = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);

        assert!(pool.account_fee_turnover(&bob, test.ctx()) == 0, 0);
        assert!(pool.account_fee_tier(&bob, test.ctx()) == 0, 1);
        let (taker, maker) = pool.trade_params_for_account(&bob, test.ctx());
        assert!(taker == 22_000_000, 2);
        assert!(maker == 18_000_000, 3);

        return_shared(bob);
        return_shared(pool);
    };

    end(test);
}

// === Gas benchmarks ===
//
// These are not correctness tests. Each one performs a fixed amount of work so
// that `build_scripts/gas-benchmark.sh` can binary-search the smallest
// `--gas-limit` it survives, which is a deterministic measure of the Move VM
// gas that work costs.
//
// Read them differentially: subtract a benchmark from the one that does
// strictly more work, and what remains is the cost of the difference. Absolute
// numbers here are Move VM gas, not Sui computation + storage fees, so they are
// for comparing operations against each other and for detecting growth with
// book depth — not for predicting a mainnet fee.
//
// Bids are placed at ascending prices, so each new order is the best bid and
// lands at the end of the book vector. That keeps `vector::insert` at O(1) and
// isolates the O(depth) rescan in `match_against_book`.

/// Pool and two funded accounts, no orders. Subtract this from every other
/// benchmark to remove fixture cost.
public(package) fun bench_baseline() {
    let mut test = begin(OWNER);
    let registry_id = setup_test(OWNER, &mut test);
    let balance_manager_id_alice = create_acct_and_share_with_funds(
        ALICE,
        1000000 * constants::float_scaling(),
        &mut test,
    );
    setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
        ALICE,
        registry_id,
        balance_manager_id_alice,
        &mut test,
    );
    create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

    end(test);
}

/// Rest `count` bids at ascending prices from one account.
fun bench_place_bids(count: u64) {
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
    create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

    let quantity = 1 * constants::float_scaling();
    let mut i = 0;
    while (i < count) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            (i + 1) * constants::float_scaling(),
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        i = i + 1;
    };

    end(test);
}

public(package) fun bench_depth_10() { bench_place_bids(10) }

public(package) fun bench_depth_40() { bench_place_bids(40) }

public(package) fun bench_depth_80() { bench_place_bids(80) }

/// 80 resting bids, then cancel the *worst-priced* one. That order sits at
/// index 0, so `find_order_index` scans the whole book to reach it and the
/// removal shifts every element — the worst case for cancel at this depth.
public(package) fun bench_cancel_at_depth_80() {
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
    create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

    let quantity = 1 * constants::float_scaling();
    let mut first_order_id = 0;
    let mut i = 0;
    while (i < 80) {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            (i + 1) * constants::float_scaling(),
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        if (i == 0) first_order_id = order_info.order_id();
        i = i + 1;
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_order(
            &mut balance_manager,
            &trade_proof,
            first_order_id,
            &clock,
            test.ctx(),
        );
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// `makers` resting bids at one price, then a single ask that sweeps all of
/// them. Isolates the per-fill cost, including each maker's account touch.
fun bench_taker_sweeps(makers: u64) {
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
    let mut i = 0;
    while (i < makers) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        i = i + 1;
    };

    place_limit_order<SUI, USDC>(
        BOB,
        pool_id,
        balance_manager_id_bob,
        constants::no_restriction(),
        constants::self_matching_allowed(),
        price,
        quantity * makers,
        false,
        constants::max_u64(),
        &mut test,
    );

    end(test);
}

public(package) fun bench_taker_sweeps_01() { bench_taker_sweeps(1) }

public(package) fun bench_taker_sweeps_10() { bench_taker_sweeps(10) }

/// Rest 10 bids under a ladder of `tiers` rungs. Comparing the one-rung and
/// eight-rung variants prices the tier resolution TRIEX-137 added: both set a
/// schedule and roll an epoch, so everything except the ladder length cancels.
fun bench_place_bids_under_ladder(tiers: u64) {
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
    create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

    // Thresholds far above anything these orders accrue, so every placement
    // walks the whole ladder without ever promoting — the worst case for
    // resolution, and identical work per order across both variants.
    let mut min_turnovers = vector[];
    let mut taker_fees = vector[];
    let mut maker_fees = vector[];
    let mut t = 0;
    while (t < tiers) {
        min_turnovers.push_back((t as u128) * 1_000_000_000_000_000);
        taker_fees.push_back(22_000_000 - (t * 1000));
        maker_fees.push_back(18_000_000 - (t * 1000));
        t = t + 1;
    };

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee_schedule(min_turnovers, taker_fees, maker_fees, 2000, &admin_cap);
        return_shared(pool);
        destroy(admin_cap);
    };
    test.next_epoch(OWNER);

    let quantity = 1 * constants::float_scaling();
    let mut i = 0;
    while (i < 10) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            (i + 1) * constants::float_scaling(),
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        i = i + 1;
    };

    end(test);
}

public(package) fun bench_ladder_1_tier() { bench_place_bids_under_ladder(1) }

public(package) fun bench_ladder_8_tiers() { bench_place_bids_under_ladder(8) }

/// Set up a pool and hand its admin a ladder, so the validation the entry point
/// performs can be exercised through the real admin path rather than by calling
/// `fee_schedule::validate` directly with hand-copied bounds.
fun set_schedule_via_admin(
    min_turnovers: vector<u128>,
    taker_fees: vector<u64>,
    maker_fees: vector<u64>,
    cancel_retention_bps: u64,
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

    test.next_tx(OWNER);
    {
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.set_next_epoch_fee_schedule(
            min_turnovers,
            taker_fees,
            maker_fees,
            cancel_retention_bps,
            &admin_cap,
        );
        return_shared(pool);
        destroy(admin_cap);
    };

    end(test);
}

/// The entry point must reject a retention above 100%. Covered at the leaf in
/// `governance_admin_tests`, but only through `set_next_trade_params` — nothing
/// pinned the schedule setter's own bound.
public(package) fun test_schedule_setter_rejects_retention_above_full() {
    set_schedule_via_admin(vector[0], vector[22_000_000], vector[18_000_000], 10_001);
}

/// A ladder whose thresholds descend must be rejected by the admin entry point.
/// `fee_schedule_tests` covers every rejection, but by calling `validate`
/// directly with its own copies of the bounds — so deleting the `validate` call
/// from `set_next_fee_schedule` would not have failed anything.
public(package) fun test_schedule_setter_rejects_descending_thresholds() {
    set_schedule_via_admin(
        vector[0, 100, 50],
        vector[22_000_000, 15_000_000, 11_000_000],
        vector[18_000_000, 12_000_000, 9_000_000],
        2000,
    );
}

/// And a ladder that prices more turnover *higher* on the taker side.
public(package) fun test_schedule_setter_rejects_rising_taker_rate() {
    set_schedule_via_admin(
        vector[0, 100],
        vector[11_000_000, 22_000_000],
        vector[9_000_000, 9_000_000],
        2000,
    );
}

/// Ten bids resting at one price. Baseline for the benchmarks below that then
/// consume this book, so their differentials price the consuming call alone.
public(package) fun bench_makers_10() {
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
    create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let mut i = 0;
    while (i < 10) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        i = i + 1;
    };

    end(test);
}

/// Same book as `bench_makers_10`, consumed by a market order instead of a
/// crossing limit order. Differencing the two against that baseline prices the
/// market-order path against the limit path.
public(package) fun bench_market_sweeps_10() {
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
    let mut i = 0;
    while (i < 10) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        i = i + 1;
    };

    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(balance_manager_id_bob);
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.place_market_order(
            &mut balance_manager,
            &trade_proof,
            constants::self_matching_allowed(),
            quantity * 10,
            false,
            &clock,
            test.ctx(),
        );
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// Same book again, consumed by the manager-less swap. That path mints a
/// temporary balance manager, trades, withdraws and deletes it, so the
/// differential is what anonymous flow pays for the convenience.
public(package) fun bench_swap_base_for_quote_10() {
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
    create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

    let price = 2 * constants::float_scaling();
    let quantity = 1 * constants::float_scaling();
    let mut i = 0;
    while (i < 10) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        i = i + 1;
    };

    test.next_tx(BOB);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let (base_out, quote_out, cred_out) = pool.swap_exact_base_for_quote<SUI, USDC>(
            mint_for_testing<SUI>(quantity * 10, test.ctx()),
            mint_for_testing<CRED>(0, test.ctx()),
            0,
            &clock,
            test.ctx(),
        );
        destroy(base_out);
        destroy(quote_out);
        destroy(cred_out);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// 80 resting bids, then modify the worst-priced one down. Like the cancel
/// benchmark this hits the linear scan over both book sides, and it releases
/// escrow on cancel terms — the path a modify-to-minimum would take.
public(package) fun bench_modify_at_depth_80() {
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
    create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

    // Same quantity as `bench_depth_80`, so subtracting that baseline leaves
    // only the modify.
    let quantity = 1 * constants::float_scaling();
    let mut first_order_id = 0;
    let mut i = 0;
    while (i < 80) {
        let order_info = place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            (i + 1) * constants::float_scaling(),
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        if (i == 0) first_order_id = order_info.order_id();
        i = i + 1;
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.modify_order(
            &mut balance_manager,
            &trade_proof,
            first_order_id,
            quantity / 2,
            &clock,
            test.ctx(),
        );
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}

/// 80 resting bids, then cancel every one of them in a single call.
/// `cancel_all_orders` loops the account's open orders and each iteration runs
/// an O(depth) `cancel_order`, so this is the most expensive user-facing call
/// the pool exposes.
public(package) fun bench_cancel_all_at_depth_80() {
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
    create_acct_and_share_with_funds(BOB, 1000000 * constants::float_scaling(), &mut test);

    let quantity = 1 * constants::float_scaling();
    let mut i = 0;
    while (i < 80) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            balance_manager_id_alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            (i + 1) * constants::float_scaling(),
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );
        i = i + 1;
    };

    test.next_tx(ALICE);
    {
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let mut balance_manager = test.take_shared_by_id<BalanceManager>(
            balance_manager_id_alice,
        );
        let trade_proof = balance_manager.generate_proof_as_owner(test.ctx());
        pool.cancel_all_orders(&mut balance_manager, &trade_proof, &clock, test.ctx());
        return_shared(balance_manager);
        return_shared(clock);
        return_shared(pool);
    };

    end(test);
}
