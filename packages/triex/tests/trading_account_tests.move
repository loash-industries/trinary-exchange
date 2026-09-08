// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::trading_account_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test::destroy;
    use sui::{
        coin::mint_for_testing,
        sui::SUI,
        test_scenario::{Scenario, begin, end, return_shared}
    };
    use token::cred::CRED;
    use triexbook::trading_account::{Self, TradingAccount, TradeCap, DepositCap, WithdrawCap};

    public struct SPAM has store {}
    public struct USDC has store {}
    public struct USDT has store {}

    // === MultiCoin Test Constants ===
    const OWNER: address = @0xF;
    const ALICE: address = @0xA;
    const BOB: address = @0xB;
    const FAKE: address = @0xFAE;
    const TEST_ASSET_ID_1: u64 = 42;
    const TEST_ASSET_ID_2: u64 = 99;

    // === MultiCoin Test Helpers ===

    /// Setup a MultiCoin collection for testing
    fun setup_multicoin_collection(test: &mut Scenario): (ID, CollectionCap) {
        test.next_tx(OWNER);
        let (collection, collection_cap) = multicoin::new_collection(test.ctx());
        let collection_id = object::id(&collection);
        sui::transfer::public_share_object(collection);
        (collection_id, collection_cap)
    }

    #[test]
    fun test_deposit_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            assert!(trading_account.owner() == alice, 0);
            trading_account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
            let balance = trading_account.balance<SUI>();
            assert!(balance == 100, 0);

            trading_account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
            let balance = trading_account.balance<SUI>();
            assert!(balance == 200, 0);

            transfer::public_share_object(trading_account);
        };

        end(test);
    }

    #[test]
    fun test_deposit_custom_trading_account_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        test.next_tx(alice);
        {
            let trading_account = trading_account::new_with_custom_owner(bob, test.ctx());
            assert!(trading_account.owner() == bob, 0);
            transfer::public_share_object(trading_account);
        };
        test.next_tx(bob);
        {
            let mut trading_account = test.take_shared<TradingAccount>();
            trading_account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
            let balance = trading_account.balance<SUI>();
            assert!(balance == 100, 0);

            trading_account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
            let balance = trading_account.balance<SUI>();
            assert!(balance == 200, 0);

            return_shared(trading_account);
        };

        end(test);
    }

    #[test, expected_failure(abort_code = trading_account::EInvalidOwner)]
    fun test_deposit_as_owner_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let trading_account_id;

        test.next_tx(alice);
        {
            let trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            transfer::public_share_object(trading_account);
        };

        test.next_tx(bob);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            trading_account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
        };

        abort 0
    }

    #[test, expected_failure(abort_code = trading_account::EInvalidOwner)]
    fun test_remove_trader_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let trading_account_id;
        let trade_cap_id;

        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            let trade_cap = trading_account.mint_trade_cap(test.ctx());
            trade_cap_id = object::id(&trade_cap);
            transfer::public_transfer(trade_cap, bob);
            transfer::public_share_object(trading_account);
        };

        test.next_tx(bob);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            trading_account.revoke_trade_cap(&trade_cap_id, test.ctx());
        };

        abort 0
    }

    #[test, expected_failure(abort_code = trading_account::EInvalidTrader)]
    fun test_deposit_with_removed_trader_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let trading_account_id;
        let trade_cap_id;

        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            let trade_cap = trading_account.mint_trade_cap(test.ctx());
            let trade_proof = trading_account.generate_proof_as_trader(
                &trade_cap,
                test.ctx(),
            );
            trade_cap_id = object::id(&trade_cap);

            trading_account.deposit_with_proof(
                &trade_proof,
                mint_for_testing<SUI>(100, test.ctx()).into_balance(),
            );
            transfer::public_transfer(trade_cap, bob);
            let balance = trading_account.balance<SUI>();
            assert!(balance == 100, 0);

            trading_account.revoke_trade_cap(&trade_cap_id, test.ctx());
            transfer::public_share_object(trading_account);
        };

        test.next_tx(bob);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            let trade_cap = test.take_from_sender<TradeCap>();
            let trade_proof = trading_account.generate_proof_as_trader(
                &trade_cap,
                test.ctx(),
            );
            trading_account.deposit_with_proof(
                &trade_proof,
                mint_for_testing<CRED>(100000, test.ctx()).into_balance(),
            );
        };

        abort 0
    }

    #[test, expected_failure(abort_code = trading_account::EInvalidTrader)]
    fun test_deposit_with_removed_deposit_cap_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let trading_account_id;
        let deposit_cap_id;

        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            let deposit_cap = trading_account.mint_deposit_cap(test.ctx());
            deposit_cap_id = object::id(&deposit_cap);

            trading_account.deposit_with_cap<SUI>(
                &deposit_cap,
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
            transfer::public_transfer(deposit_cap, bob);
            let balance = trading_account.balance<SUI>();
            assert!(balance == 100, 0);

            trading_account.revoke_trade_cap(&deposit_cap_id, test.ctx());
            transfer::public_share_object(trading_account);
        };

        test.next_tx(bob);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            let deposit_cap = test.take_from_sender<DepositCap>();
            trading_account.deposit_with_cap<SUI>(
                &deposit_cap,
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
        };

        abort 0
    }

    #[test, expected_failure(abort_code = trading_account::EInvalidTrader)]
    fun test_deposit_with_wrong_deposit_cap_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let trading_account_id_2;

        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            let trading_account_2 = trading_account::new(test.ctx());
            trading_account_id_2 = object::id(&trading_account_2);
            let deposit_cap = trading_account.mint_deposit_cap(test.ctx());

            transfer::public_transfer(deposit_cap, bob);
            transfer::public_share_object(trading_account);
            transfer::public_share_object(trading_account_2);
        };

        test.next_tx(bob);
        {
            let mut trading_account_2 = test.take_shared_by_id<TradingAccount>(
                trading_account_id_2,
            );
            let deposit_cap = test.take_from_sender<DepositCap>();
            trading_account_2.deposit_with_cap<SUI>(
                &deposit_cap,
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
        };

        abort 0
    }

    #[test]
    fun test_deposit_with_deposit_cap_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let trading_account_id;

        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            let deposit_cap = trading_account.mint_deposit_cap(test.ctx());

            trading_account.deposit_with_cap<SUI>(
                &deposit_cap,
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
            transfer::public_transfer(deposit_cap, bob);
            let balance = trading_account.balance<SUI>();
            assert!(balance == 100, 0);

            transfer::public_share_object(trading_account);
        };

        test.next_tx(bob);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            let deposit_cap = test.take_from_sender<DepositCap>();
            trading_account.deposit_with_cap<SUI>(
                &deposit_cap,
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
            let balance = trading_account.balance<SUI>();
            assert!(balance == 200, 0);

            return_shared(trading_account);
            test.return_to_sender(deposit_cap);
        };

        end(test);
    }

    #[test, expected_failure(abort_code = trading_account::EInvalidTrader)]
    fun test_withdraw_with_removed_withdraw_cap_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let trading_account_id;
        let withdraw_cap_id;

        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            let withdraw_cap = trading_account.mint_withdraw_cap(test.ctx());
            withdraw_cap_id = object::id(&withdraw_cap);
            trading_account.deposit(
                mint_for_testing<SUI>(1000, test.ctx()),
                test.ctx(),
            );

            let sui = trading_account.withdraw_with_cap<SUI>(
                &withdraw_cap,
                100,
                test.ctx(),
            );
            assert!(sui.value() == 100, 0);
            sui.burn_for_testing();
            transfer::public_transfer(withdraw_cap, bob);
            let balance = trading_account.balance<SUI>();
            assert!(balance == 900, 0);

            trading_account.revoke_trade_cap(&withdraw_cap_id, test.ctx());
            transfer::public_share_object(trading_account);
        };

        test.next_tx(bob);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            let withdraw_cap = test.take_from_sender<WithdrawCap>();
            let sui = trading_account.withdraw_with_cap<SUI>(
                &withdraw_cap,
                100,
                test.ctx(),
            );
            sui.burn_for_testing();
        };

        abort 0
    }

    #[test, expected_failure(abort_code = trading_account::EInvalidTrader)]
    fun test_withdraw_with_wrong_withdraw_cap_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let trading_account_id_2;

        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            let mut trading_account_2 = trading_account::new(test.ctx());
            trading_account_id_2 = object::id(&trading_account_2);
            let withdraw_cap = trading_account.mint_withdraw_cap(test.ctx());
            trading_account_2.deposit(
                mint_for_testing<SUI>(1000, test.ctx()),
                test.ctx(),
            );

            transfer::public_transfer(withdraw_cap, bob);

            transfer::public_share_object(trading_account);
            transfer::public_share_object(trading_account_2);
        };

        test.next_tx(bob);
        {
            let mut trading_account_2 = test.take_shared_by_id<TradingAccount>(
                trading_account_id_2,
            );
            let withdraw_cap = test.take_from_sender<WithdrawCap>();
            let sui = trading_account_2.withdraw_with_cap<SUI>(
                &withdraw_cap,
                100,
                test.ctx(),
            );
            sui.burn_for_testing();
        };

        abort 0
    }

    #[test]
    fun test_withdraw_with_withdraw_cap_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        let bob = @0xB;
        let trading_account_id;

        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            let withdraw_cap = trading_account.mint_withdraw_cap(test.ctx());
            trading_account.deposit(
                mint_for_testing<SUI>(1000, test.ctx()),
                test.ctx(),
            );

            let sui = trading_account.withdraw_with_cap<SUI>(
                &withdraw_cap,
                100,
                test.ctx(),
            );
            assert!(sui.value() == 100, 0);
            sui.burn_for_testing();
            transfer::public_transfer(withdraw_cap, bob);
            let balance = trading_account.balance<SUI>();
            assert!(balance == 900, 0);

            transfer::public_share_object(trading_account);
        };

        test.next_tx(bob);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            let withdraw_cap = test.take_from_sender<WithdrawCap>();
            let sui = trading_account.withdraw_with_cap<SUI>(
                &withdraw_cap,
                100,
                test.ctx(),
            );
            sui.burn_for_testing();
            let balance = trading_account.balance<SUI>();
            assert!(balance == 800, 0);

            return_shared(trading_account);
            test.return_to_sender(withdraw_cap);
        };

        end(test);
    }

    #[test]
    fun test_withdraw_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
            let balance = trading_account.balance<SUI>();
            assert!(balance == 100, 0);

            let coin = trading_account.withdraw<SUI>(
                50,
                test.ctx(),
            );
            let balance = trading_account.balance<SUI>();
            assert!(balance == 50, 0);
            coin.burn_for_testing();

            transfer::public_share_object(trading_account);
        };

        end(test);
    }

    #[test]
    fun test_withdraw_all_ok() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
            let balance = trading_account.balance<SUI>();
            assert!(balance == 100, 0);

            let coin = trading_account.withdraw_all<SUI>(test.ctx());
            let balance = trading_account.balance<SUI>();
            assert!(balance == 0, 0);
            assert!(coin.burn_for_testing() == 100, 0);

            transfer::public_share_object(trading_account);
        };

        end(test);
    }

    #[test, expected_failure(abort_code = trading_account::ETradingAccountBalanceTooLow)]
    fun test_withdraw_balance_too_low_e() {
        let mut test = begin(@0xF);
        let alice = @0xA;
        test.next_tx(alice);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account.deposit(
                mint_for_testing<SUI>(100, test.ctx()),
                test.ctx(),
            );
            let balance = trading_account.balance<SUI>();
            assert!(balance == 100, 0);

            let _coin = trading_account.withdraw<SUI>(
                200,
                test.ctx(),
            );
        };

        abort 0
    }

    // #feat:refer
    // #[test]
    // fun test_referral_ok() {
    //     let mut test = begin(@0xF);
    //     let alice = @0xA;
    //     let referral_id1;
    //     let referral_id2;
    //     test.next_tx(alice);
    //     {
    //         referral_id1 = trading_account::mint_referral(test.ctx());
    //         referral_id2 = trading_account::mint_referral(test.ctx());
    //     };

    //     test.next_tx(alice);
    //     {
    //         let referral1 = test.take_shared_by_id<TriexBookReferral>(referral_id1);
    //         assert!(referral1.referral_owner() == alice, 0);
    //         let referral2 = test.take_shared_by_id<TriexBookReferral>(referral_id2);
    //         assert!(referral2.referral_owner() == alice, 0);

    //         let mut trading_account = trading_account::new(test.ctx());
    //         let trade_cap = trading_account.mint_trade_cap(test.ctx());
    //         trading_account.set_referral(&referral1, &trade_cap);
    //         assert!(trading_account.get_referral_id() == option::some(referral_id1), 0);
    //         trading_account.set_referral(&referral2, &trade_cap);
    //         assert!(trading_account.get_referral_id() == option::some(referral_id2), 0);

    //         trading_account.unset_referral(&trade_cap);
    //         assert!(trading_account.get_referral_id() == option::none(), 0);

    //         transfer::public_share_object(trading_account);
    //         return_shared(referral1);
    //         return_shared(referral2);
    //         unit_test::destroy(trade_cap);
    //     };

    //     end(test);
    // }

    // #feat:refer
    // #[test]
    // fun test_unset_no_referral_ok() {
    //     let mut test = begin(@0xF);
    //     let alice = @0xA;
    //     test.next_tx(alice);
    //     {
    //         let mut trading_account = trading_account::new(test.ctx());
    //         let trade_cap = trading_account.mint_trade_cap(test.ctx());
    //         trading_account.unset_referral(&trade_cap);
    //         assert!(trading_account.get_referral_id() == option::none(), 0);

    //         transfer::public_share_object(trading_account);
    //         unit_test::destroy(trade_cap);
    //     };

    //     end(test);
    // }

    // === MultiCoin Tests ===

    #[test]
    fun test_deposit_multicoin_ok() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        let trading_account = trading_account::new(test.ctx());
        assert!(trading_account.owner() == ALICE, 0);
        let ta_id = object::id(&trading_account);
        transfer::public_share_object(trading_account);

        // Mint first MultiCoin as OWNER and transfer to ALICE
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let multicoin_bal = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            TEST_ASSET_ID_1,
            100,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(multicoin_bal, ALICE);

        // Deposit as ALICE
        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let multicoin_bal = test.take_from_sender<multicoin::Balance>();
        trading_account.deposit_multicoin(multicoin_bal, test.ctx());
        let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        assert!(balance == 100, 0);
        return_shared(trading_account);

        // Mint second MultiCoin (tests join logic)
        test.next_tx(OWNER);
        let mut collection2 = test.take_shared<Collection>();
        let multicoin_bal2 = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection2,
            TEST_ASSET_ID_1,
            50,
            test.ctx(),
        );
        return_shared(collection2);
        transfer::public_transfer(multicoin_bal2, ALICE);

        // Deposit second balance as ALICE
        test.next_tx(ALICE);
        let mut trading_account2 = test.take_shared_by_id<TradingAccount>(ta_id);
        let multicoin_bal2 = test.take_from_sender<multicoin::Balance>();
        trading_account2.deposit_multicoin(multicoin_bal2, test.ctx());
        let balance = trading_account2.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        assert!(balance == 150, 1);
        return_shared(trading_account2);

        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_deposit_multicoin_multiple_assets_ok() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        let trading_account = trading_account::new(test.ctx());
        let ta_id = object::id(&trading_account);
        transfer::public_share_object(trading_account);

        // Mint asset 1 as OWNER and transfer to ALICE
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let multicoin_bal1 = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            TEST_ASSET_ID_1,
            100,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(multicoin_bal1, ALICE);

        // Mint asset 2 as OWNER and transfer to ALICE
        test.next_tx(OWNER);
        let mut collection2 = test.take_shared<Collection>();
        let multicoin_bal2 = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection2,
            TEST_ASSET_ID_2,
            200,
            test.ctx(),
        );
        return_shared(collection2);
        transfer::public_transfer(multicoin_bal2, ALICE);

        // Deposit both assets as ALICE
        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let multicoin_bal1 = test.take_from_sender<multicoin::Balance>();
        let multicoin_bal2 = test.take_from_sender<multicoin::Balance>();
        trading_account.deposit_multicoin(multicoin_bal1, test.ctx());
        trading_account.deposit_multicoin(multicoin_bal2, test.ctx());

        // Verify both balances
        let balance1 = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        let balance2 = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_2);
        assert!(balance1 == 100, 0);
        assert!(balance2 == 200, 1);
        return_shared(trading_account);

        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_withdraw_multicoin_ok() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());

            // Deposit 1000
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                1000,
                test.ctx(),
            );
            return_shared(collection);
            trading_account.deposit_multicoin(multicoin_bal, test.ctx());

            // Withdraw 400
            let withdrawn = trading_account.withdraw_multicoin(
                collection_id,
                TEST_ASSET_ID_1,
                400,
                test.ctx(),
            );
            assert!(withdrawn.value() == 400, 0);

            // Verify remaining balance
            let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
            assert!(balance == 600, 1);

            destroy(withdrawn);
            transfer::public_share_object(trading_account);
        };

        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_withdraw_all_multicoin_ok() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());

            // Deposit 1000
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                1000,
                test.ctx(),
            );
            return_shared(collection);
            trading_account.deposit_multicoin(multicoin_bal, test.ctx());

            // Withdraw all
            let withdrawn = trading_account.withdraw_all_multicoin(
                collection_id,
                TEST_ASSET_ID_1,
                test.ctx(),
            );
            assert!(withdrawn.value() == 1000, 0);

            // Verify balance is 0
            let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
            assert!(balance == 0, 1);

            destroy(withdrawn);
            transfer::public_share_object(trading_account);
        };

        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_withdraw_all_multicoin_empty_ok() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());

            // Withdraw all from non-existent asset (should return zero balance)
            let withdrawn = trading_account.withdraw_all_multicoin(
                collection_id,
                TEST_ASSET_ID_1,
                test.ctx(),
            );
            assert!(withdrawn.value() == 0, 0);

            destroy(withdrawn);
            transfer::public_share_object(trading_account);
        };

        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_multicoin_balance_query_ok() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());

            // Query non-existent asset (should return 0)
            let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
            assert!(balance == 0, 0);

            // Deposit and query
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                500,
                test.ctx(),
            );
            return_shared(collection);
            trading_account.deposit_multicoin(multicoin_bal, test.ctx());
            let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
            assert!(balance == 500, 1);

            // Query different asset (should still be 0)
            let balance2 = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_2);
            assert!(balance2 == 0, 2);

            transfer::public_share_object(trading_account);
        };

        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_withdraw_exact_amount_multicoin_ok() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());

            // Deposit 1000
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                1000,
                test.ctx(),
            );
            return_shared(collection);
            trading_account.deposit_multicoin(multicoin_bal, test.ctx());

            // Withdraw exact amount (should remove DOF entry)
            let withdrawn = trading_account.withdraw_multicoin(
                collection_id,
                TEST_ASSET_ID_1,
                1000,
                test.ctx(),
            );
            assert!(withdrawn.value() == 1000, 0);

            // Verify balance is 0
            let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
            assert!(balance == 0, 1);

            destroy(withdrawn);
            transfer::public_share_object(trading_account);
        };

        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_deposit_multicoin_with_deposit_cap_ok() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);
        let trading_account_id;

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            let deposit_cap = trading_account.mint_deposit_cap(test.ctx());

            // Deposit with cap
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                100,
                test.ctx(),
            );
            return_shared(collection);
            trading_account.deposit_multicoin_with_cap(&deposit_cap, multicoin_bal, test.ctx());
            let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
            assert!(balance == 100, 0);

            transfer::public_transfer(deposit_cap, BOB);
            transfer::public_share_object(trading_account);
        };

        test.next_tx(BOB);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
            let deposit_cap = test.take_from_sender<DepositCap>();

            // Bob deposits with cap
            let mut collection2 = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection2,
                TEST_ASSET_ID_1,
                200,
                test.ctx(),
            );
            return_shared(collection2);
            trading_account.deposit_multicoin_with_cap(&deposit_cap, multicoin_bal, test.ctx());
            let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
            assert!(balance == 300, 1);

            return_shared(trading_account);
            test.return_to_sender(deposit_cap);
        };

        destroy(collection_cap);
        test.end();
    }

    #[test]
    #[expected_failure(abort_code = trading_account::EInvalidTrader)]
    fun test_deposit_multicoin_with_wrong_cap_e() {
        let mut test = begin(ALICE);
        let (_, collection_cap) = setup_multicoin_collection(&mut test);
        let trading_account_id_2;

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());
            let trading_account_2 = trading_account::new(test.ctx());
            trading_account_id_2 = object::id(&trading_account_2);
            let deposit_cap = trading_account.mint_deposit_cap(test.ctx());

            transfer::public_transfer(deposit_cap, BOB);
            transfer::public_share_object(trading_account);
            transfer::public_share_object(trading_account_2);
        };

        test.next_tx(BOB);
        {
            let mut trading_account_2 = test.take_shared_by_id<TradingAccount>(
                trading_account_id_2,
            );
            let deposit_cap = test.take_from_sender<DepositCap>();

            // Try to use cap from trading_account 1 with trading_account 2
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                100,
                test.ctx(),
            );
            return_shared(collection);
            trading_account_2.deposit_multicoin_with_cap(&deposit_cap, multicoin_bal, test.ctx());
        };

        abort 0
    }

    #[test]
    fun test_withdraw_multicoin_with_withdraw_cap_ok() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);
        let trading_account_id;

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            let withdraw_cap = trading_account.mint_withdraw_cap(test.ctx());

            // Deposit 1000
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                1000,
                test.ctx(),
            );
            return_shared(collection);
            trading_account.deposit_multicoin(multicoin_bal, test.ctx());

            // Withdraw with cap
            let withdrawn = trading_account.withdraw_multicoin_with_cap(
                &withdraw_cap,
                collection_id,
                TEST_ASSET_ID_1,
                300,
                test.ctx(),
            );
            assert!(withdrawn.value() == 300, 0);
            destroy(withdrawn);

            let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
            assert!(balance == 700, 1);

            transfer::public_transfer(withdraw_cap, BOB);
            transfer::public_share_object(trading_account);
        };

        test.next_tx(BOB);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
            let withdraw_cap = test.take_from_sender<WithdrawCap>();

            // Bob withdraws with cap
            let withdrawn = trading_account.withdraw_multicoin_with_cap(
                &withdraw_cap,
                collection_id,
                TEST_ASSET_ID_1,
                200,
                test.ctx(),
            );
            assert!(withdrawn.value() == 200, 2);
            destroy(withdrawn);

            let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
            assert!(balance == 500, 3);

            return_shared(trading_account);
            test.return_to_sender(withdraw_cap);
        };

        destroy(collection_cap);
        test.end();
    }

    #[test]
    #[expected_failure(abort_code = trading_account::EInvalidTrader)]
    fun test_withdraw_multicoin_with_wrong_cap_e() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);
        let trading_account_id_2;

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());
            let mut trading_account_2 = trading_account::new(test.ctx());
            trading_account_id_2 = object::id(&trading_account_2);
            let withdraw_cap = trading_account.mint_withdraw_cap(test.ctx());

            // Deposit to trading_account 2
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                1000,
                test.ctx(),
            );
            return_shared(collection);
            trading_account_2.deposit_multicoin(multicoin_bal, test.ctx());

            transfer::public_transfer(withdraw_cap, BOB);
            transfer::public_share_object(trading_account);
            transfer::public_share_object(trading_account_2);
        };

        test.next_tx(BOB);
        {
            let mut trading_account_2 = test.take_shared_by_id<TradingAccount>(
                trading_account_id_2,
            );
            let withdraw_cap = test.take_from_sender<WithdrawCap>();

            // Try to use cap from trading_account 1 with trading_account 2
            let withdrawn = trading_account_2.withdraw_multicoin_with_cap(
                &withdraw_cap,
                collection_id,
                TEST_ASSET_ID_1,
                100,
                test.ctx(),
            );
            destroy(withdrawn);
        };

        abort 0
    }

    #[test]
    #[expected_failure(abort_code = trading_account::EInvalidTrader)]
    fun test_deposit_multicoin_with_revoked_cap_e() {
        let mut test = begin(ALICE);
        let (_, collection_cap) = setup_multicoin_collection(&mut test);
        let trading_account_id;
        let deposit_cap_id;

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            let deposit_cap = trading_account.mint_deposit_cap(test.ctx());
            deposit_cap_id = object::id(&deposit_cap);

            // Deposit once successfully
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                100,
                test.ctx(),
            );
            return_shared(collection);
            trading_account.deposit_multicoin_with_cap(&deposit_cap, multicoin_bal, test.ctx());

            transfer::public_transfer(deposit_cap, BOB);

            // Revoke the cap
            trading_account.revoke_trade_cap(&deposit_cap_id, test.ctx());
            transfer::public_share_object(trading_account);
        };

        test.next_tx(BOB);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
            let deposit_cap = test.take_from_sender<DepositCap>();

            // Try to deposit with revoked cap
            let mut collection2 = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection2,
                TEST_ASSET_ID_1,
                200,
                test.ctx(),
            );
            return_shared(collection2);
            trading_account.deposit_multicoin_with_cap(&deposit_cap, multicoin_bal, test.ctx());
        };

        abort 0
    }

    #[test]
    #[expected_failure(abort_code = trading_account::EInvalidTrader)]
    fun test_withdraw_multicoin_with_revoked_cap_e() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);
        let trading_account_id;
        let withdraw_cap_id;

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            let withdraw_cap = trading_account.mint_withdraw_cap(test.ctx());
            withdraw_cap_id = object::id(&withdraw_cap);

            // Deposit 1000
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                1000,
                test.ctx(),
            );
            return_shared(collection);
            trading_account.deposit_multicoin(multicoin_bal, test.ctx());

            // Withdraw once successfully
            let withdrawn = trading_account.withdraw_multicoin_with_cap(
                &withdraw_cap,
                collection_id,
                TEST_ASSET_ID_1,
                100,
                test.ctx(),
            );
            destroy(withdrawn);

            transfer::public_transfer(withdraw_cap, BOB);

            // Revoke the cap
            trading_account.revoke_trade_cap(&withdraw_cap_id, test.ctx());
            transfer::public_share_object(trading_account);
        };

        test.next_tx(BOB);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
            let withdraw_cap = test.take_from_sender<WithdrawCap>();

            // Try to withdraw with revoked cap
            let withdrawn = trading_account.withdraw_multicoin_with_cap(
                &withdraw_cap,
                collection_id,
                TEST_ASSET_ID_1,
                100,
                test.ctx(),
            );
            destroy(withdrawn);
        };

        abort 0
    }

    #[test]
    #[expected_failure(abort_code = trading_account::EMultiCoinBalanceTooLow)]
    fun test_withdraw_multicoin_insufficient_balance_e() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());

            // Deposit 100
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                100,
                test.ctx(),
            );
            return_shared(collection);
            trading_account.deposit_multicoin(multicoin_bal, test.ctx());

            // Try to withdraw 200 (should fail)
            let _withdrawn = trading_account.withdraw_multicoin(
                collection_id,
                TEST_ASSET_ID_1,
                200,
                test.ctx(),
            );
        };

        abort 0
    }

    #[test]
    #[expected_failure(abort_code = trading_account::EMultiCoinBalanceTooLow)]
    fun test_withdraw_multicoin_nonexistent_asset_e() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);
        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());

            // Try to withdraw from asset that was never deposited (should fail)
            let _withdrawn = trading_account.withdraw_multicoin(
                collection_id,
                TEST_ASSET_ID_1,
                100,
                test.ctx(),
            );
        };

        abort 0
    }

    #[test]
    #[expected_failure(abort_code = trading_account::EInvalidOwner)]
    fun test_deposit_multicoin_as_non_owner_e() {
        let mut test = begin(ALICE);
        let (_, collection_cap) = setup_multicoin_collection(&mut test);
        let trading_account_id;

        test.next_tx(ALICE);
        {
            let trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);
            transfer::public_share_object(trading_account);
        };

        test.next_tx(BOB);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);

            // Bob tries to deposit to Alice's trading_account (should fail)
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                100,
                test.ctx(),
            );
            return_shared(collection);
            trading_account.deposit_multicoin(multicoin_bal, test.ctx());
        };

        abort 0
    }

    #[test]
    #[expected_failure(abort_code = trading_account::EInvalidOwner)]
    fun test_withdraw_multicoin_as_non_owner_e() {
        let mut test = begin(ALICE);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);
        let trading_account_id;

        test.next_tx(ALICE);
        {
            let mut trading_account = trading_account::new(test.ctx());
            trading_account_id = object::id(&trading_account);

            // Deposit as owner
            let mut collection = test.take_shared<Collection>();
            let multicoin_bal = multicoin::mint_and_keep(
                &collection_cap,
                &mut collection,
                TEST_ASSET_ID_1,
                1000,
                test.ctx(),
            );
            return_shared(collection);
            trading_account.deposit_multicoin(multicoin_bal, test.ctx());

            transfer::public_share_object(trading_account);
        };

        test.next_tx(BOB);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);

            // Bob tries to withdraw from Alice's trading_account (should fail)
            let _withdrawn = trading_account.withdraw_multicoin(
                collection_id,
                TEST_ASSET_ID_1,
                100,
                test.ctx(),
            );
        };

        abort 0
    }

    // Removed: test_multicoin_multiple_collections_ok
    // Reason: Registry only supports ONE MultiCoin collection per registry.
    // Multiple assets in same collection are tested in test_deposit_multicoin_multiple_assets_ok.

    #[test]
    fun test_multicoin_with_coins_ok() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        let mut trading_account = trading_account::new(test.ctx());
        let ta_id = object::id(&trading_account);

        // Deposit regular Coins
        trading_account.deposit(mint_for_testing<SUI>(500, test.ctx()), test.ctx());
        trading_account.deposit(mint_for_testing<USDC>(300, test.ctx()), test.ctx());
        transfer::public_share_object(trading_account);

        // Mint MultiCoin as OWNER and transfer to ALICE
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let multicoin_bal = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            TEST_ASSET_ID_1,
            1000,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(multicoin_bal, ALICE);

        // Deposit MultiCoin as ALICE
        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let multicoin_bal = test.take_from_sender<multicoin::Balance>();
        trading_account.deposit_multicoin(multicoin_bal, test.ctx());

        // Verify all balances coexist
        assert!(trading_account.balance<SUI>() == 500, 0);
        assert!(trading_account.balance<USDC>() == 300, 1);
        assert!(trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1) == 1000, 2);
        return_shared(trading_account);

        destroy(collection_cap);
        test.end();
    }

    public(package) fun deposit_into_account<T>(
        trading_account: &mut TradingAccount,
        amount: u64,
        test: &mut Scenario,
    ) {
        trading_account.deposit(
            mint_for_testing<T>(amount, test.ctx()),
            test.ctx(),
        );
    }

    public(package) fun create_acct_and_share_with_funds(
        sender: address,
        amount: u64,
        test: &mut Scenario,
    ): ID {
        test.next_tx(sender);
        {
            let mut trading_account = trading_account::new(test.ctx());
            deposit_into_account<SUI>(&mut trading_account, amount, test);
            deposit_into_account<SPAM>(&mut trading_account, amount, test);
            deposit_into_account<USDC>(&mut trading_account, amount, test);
            deposit_into_account<CRED>(&mut trading_account, amount, test);
            deposit_into_account<USDT>(&mut trading_account, amount, test);
            let trade_cap = trading_account.mint_trade_cap(test.ctx());
            transfer::public_transfer(trade_cap, sender);
            let id = object::id(&trading_account);
            transfer::public_share_object(trading_account);

            id
        }
    }

    public(package) fun create_caps(sender: address, trading_account_id: ID, test: &mut Scenario) {
        test.next_tx(sender);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
            let deposit_cap = trading_account.mint_deposit_cap(test.ctx());
            let withdraw_cap = trading_account.mint_withdraw_cap(test.ctx());
            let trade_cap = trading_account.mint_trade_cap(test.ctx());
            transfer::public_transfer(deposit_cap, sender);
            transfer::public_transfer(withdraw_cap, sender);
            transfer::public_transfer(trade_cap, sender);
            return_shared(trading_account);
        }
    }

    public(package) fun asset_balance<Asset>(
        sender: address,
        trading_account_id: ID,
        test: &mut Scenario,
    ): u64 {
        test.next_tx(sender);
        {
            let trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
            let balance = trading_account.balance<Asset>();
            return_shared(trading_account);
            balance
        }
    }

    public(package) fun create_acct_and_share_with_funds_typed<
        BaseAsset,
        QuoteAsset,
        ReferenceBaseAsset,
    >(
        sender: address,
        amount: u64,
        test: &mut Scenario,
    ): ID {
        test.next_tx(sender);
        {
            let mut trading_account = trading_account::new(test.ctx());
            deposit_into_account<BaseAsset>(&mut trading_account, amount, test);
            deposit_into_account<QuoteAsset>(&mut trading_account, amount, test);
            deposit_into_account<ReferenceBaseAsset>(
                &mut trading_account,
                amount,
                test,
            );
            let trade_cap = trading_account.mint_trade_cap(test.ctx());
            transfer::public_transfer(trade_cap, sender);
            let id = object::id(&trading_account);
            transfer::public_share_object(trading_account);

            id
        }
    }

    // === Edge Case Tests (P2) ===

    #[test, expected_failure(abort_code = multicoin::EZeroAmount)]
    fun test_multicoin_zero_amount_deposit_e() {
        let mut test = begin(OWNER);
        let (_collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        let trading_account = trading_account::new(test.ctx());
        transfer::public_share_object(trading_account);

        // Try to mint zero amount - should fail in multicoin::mint_and_keep
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let multicoin_bal = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            TEST_ASSET_ID_1,
            0,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(multicoin_bal, ALICE);

        destroy(collection_cap);
        test.end();
    }

    #[test, expected_failure(abort_code = multicoin::EZeroAmount)]
    fun test_multicoin_zero_amount_withdraw_e() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        let trading_account = trading_account::new(test.ctx());
        let ta_id = object::id(&trading_account);
        transfer::public_share_object(trading_account);

        // Deposit some amount first
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let multicoin_bal = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            TEST_ASSET_ID_1,
            100,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(multicoin_bal, ALICE);

        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let multicoin_bal = test.take_from_sender<multicoin::Balance>();
        trading_account.deposit_multicoin(multicoin_bal, test.ctx());

        // Try to withdraw zero amount - should fail in multicoin split
        let withdrawn = trading_account.withdraw_multicoin(
            collection_id,
            TEST_ASSET_ID_1,
            0,
            test.ctx(),
        );
        destroy(withdrawn);

        abort 0
    }

    #[test]
    fun test_multicoin_max_amount_ok() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        let trading_account = trading_account::new(test.ctx());
        let ta_id = object::id(&trading_account);
        transfer::public_share_object(trading_account);

        // Use a very large amount (avoiding u64::MAX to prevent supply overflow)
        let large_amount = 10_000_000_000_000_000_000u64; // 10 quintillion
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let multicoin_bal = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            TEST_ASSET_ID_1,
            large_amount,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(multicoin_bal, ALICE);

        // Deposit large amount
        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let multicoin_bal = test.take_from_sender<multicoin::Balance>();
        trading_account.deposit_multicoin(multicoin_bal, test.ctx());
        let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        assert!(balance == large_amount, 0);

        // Withdraw large amount
        let withdrawn = trading_account.withdraw_multicoin(
            collection_id,
            TEST_ASSET_ID_1,
            large_amount,
            test.ctx(),
        );
        let balance_after = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        assert!(balance_after == 0, 1);

        return_shared(trading_account);
        destroy(withdrawn);
        destroy(collection_cap);
        test.end();
    }

    #[test, expected_failure(abort_code = trading_account::EMultiCoinBalanceTooLow)]
    fun test_multicoin_wrong_collection_e() {
        let mut test = begin(OWNER);

        // Create one collection and deposit
        let (_, collection_cap_1) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        let trading_account = trading_account::new(test.ctx());
        let ta_id = object::id(&trading_account);
        transfer::public_share_object(trading_account);

        // Mint from collection_1 and deposit
        test.next_tx(OWNER);
        let mut collection_1 = test.take_shared<Collection>();
        let multicoin_bal = multicoin::mint_and_keep(
            &collection_cap_1,
            &mut collection_1,
            TEST_ASSET_ID_1,
            100,
            test.ctx(),
        );
        return_shared(collection_1);
        transfer::public_transfer(multicoin_bal, ALICE);

        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let multicoin_bal = test.take_from_sender<multicoin::Balance>();
        trading_account.deposit_multicoin(multicoin_bal, test.ctx());

        // Create a fake collection ID that doesn't match any deposit
        let fake_collection_id = object::id_from_address(FAKE);

        // Try to withdraw using fake_collection_id - should fail with EMultiCoinBalanceTooLow
        let withdrawn = trading_account.withdraw_multicoin(
            fake_collection_id,
            TEST_ASSET_ID_1,
            50,
            test.ctx(),
        );
        destroy(withdrawn);

        abort 0
    }

    // === Integration Tests (P3) ===

    #[test, expected_failure(abort_code = trading_account::EInvalidTrader)]
    fun test_multicoin_cap_revocation_flow_ok() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        let trading_account = trading_account::new(test.ctx());
        let ta_id = object::id(&trading_account);
        transfer::public_share_object(trading_account);

        // Mint and give ALICE a deposit cap
        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let deposit_cap = trading_account.mint_deposit_cap(test.ctx());
        return_shared(trading_account);

        // Use the cap successfully
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let multicoin_bal = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            TEST_ASSET_ID_1,
            100,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(multicoin_bal, ALICE);

        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let multicoin_bal = test.take_from_sender<multicoin::Balance>();
        trading_account.deposit_multicoin_with_cap(&deposit_cap, multicoin_bal, test.ctx());
        let balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        assert!(balance == 100, 0);
        return_shared(trading_account);

        // Revoke the cap
        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let deposit_cap_id = object::id(&deposit_cap);
        trading_account.revoke_trade_cap(&deposit_cap_id, test.ctx());
        return_shared(trading_account);
        transfer::public_transfer(deposit_cap, BOB); // Transfer cap to BOB to try using it

        // Try to use revoked cap (should fail when BOB attempts to use it)
        test.next_tx(OWNER);
        let mut collection2 = test.take_shared<Collection>();
        let multicoin_bal2 = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection2,
            TEST_ASSET_ID_1,
            50,
            test.ctx(),
        );
        return_shared(collection2);
        transfer::public_transfer(multicoin_bal2, BOB);

        test.next_tx(BOB);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let multicoin_bal2 = test.take_from_sender<multicoin::Balance>();
        let deposit_cap = test.take_from_sender<DepositCap>();

        // This should fail because cap was revoked
        trading_account.deposit_multicoin_with_cap(&deposit_cap, multicoin_bal2, test.ctx());
        return_shared(trading_account);
        destroy(deposit_cap);
        destroy(collection_cap);
        test.end();
    }

    // Removed: test_multicoin_ownership_transfer_ok
    // Reason: TradingAccount doesn't support transfer_ownership - ownership is immutable after creation
    #[test]
    fun test_multicoin_concurrent_users_ok() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        // Create trading accounts for ALICE and BOB
        test.next_tx(ALICE);
        let alice_bm = trading_account::new(test.ctx());
        let alice_bm_id = object::id(&alice_bm);
        transfer::public_share_object(alice_bm);

        test.next_tx(BOB);
        let bob_bm = trading_account::new(test.ctx());
        let bob_bm_id = object::id(&bob_bm);
        transfer::public_share_object(bob_bm);

        // Mint and distribute multicoin to both users
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let alice_bal = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            TEST_ASSET_ID_1,
            500,
            test.ctx(),
        );
        let bob_bal = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            TEST_ASSET_ID_1,
            300,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(alice_bal, ALICE);
        transfer::public_transfer(bob_bal, BOB);

        // ALICE deposits
        test.next_tx(ALICE);
        let mut alice_bm = test.take_shared_by_id<TradingAccount>(alice_bm_id);
        let alice_bal = test.take_from_sender<multicoin::Balance>();
        alice_bm.deposit_multicoin(alice_bal, test.ctx());
        let alice_balance = alice_bm.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        assert!(alice_balance == 500, 0);
        return_shared(alice_bm);

        // BOB deposits
        test.next_tx(BOB);
        let mut bob_bm = test.take_shared_by_id<TradingAccount>(bob_bm_id);
        let bob_bal = test.take_from_sender<multicoin::Balance>();
        bob_bm.deposit_multicoin(bob_bal, test.ctx());
        let bob_balance = bob_bm.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        assert!(bob_balance == 300, 1);
        return_shared(bob_bm);

        // ALICE withdraws partial
        test.next_tx(ALICE);
        let mut alice_bm = test.take_shared_by_id<TradingAccount>(alice_bm_id);
        let alice_withdrawn = alice_bm.withdraw_multicoin(
            collection_id,
            TEST_ASSET_ID_1,
            200,
            test.ctx(),
        );
        let alice_remaining = alice_bm.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        assert!(alice_remaining == 300, 2);
        return_shared(alice_bm);
        destroy(alice_withdrawn);

        // BOB withdraws all
        test.next_tx(BOB);
        let mut bob_bm = test.take_shared_by_id<TradingAccount>(bob_bm_id);
        let bob_withdrawn = bob_bm.withdraw_multicoin(
            collection_id,
            TEST_ASSET_ID_1,
            300,
            test.ctx(),
        );
        let bob_remaining = bob_bm.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        assert!(bob_remaining == 0, 3);
        return_shared(bob_bm);
        destroy(bob_withdrawn);

        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_multicoin_multiple_collections_integration_ok() {
        let mut test = begin(OWNER);

        // Create two collections
        let (collection_id_1, collection_cap_1) = setup_multicoin_collection(&mut test);

        test.next_tx(OWNER);
        let (collection_2, collection_cap_2) = multicoin::new_collection(test.ctx());
        let collection_id_2 = object::id(&collection_2);
        sui::transfer::public_share_object(collection_2);

        // Create trading account for ALICE
        test.next_tx(ALICE);
        let trading_account = trading_account::new(test.ctx());
        let ta_id = object::id(&trading_account);
        transfer::public_share_object(trading_account);

        // Mint from collection_1
        test.next_tx(OWNER);
        let mut collection_1 = test.take_shared_by_id<Collection>(collection_id_1);
        let bal_1 = multicoin::mint_and_keep(
            &collection_cap_1,
            &mut collection_1,
            TEST_ASSET_ID_1,
            100,
            test.ctx(),
        );
        return_shared(collection_1);
        transfer::public_transfer(bal_1, ALICE);

        // Mint from collection_2
        test.next_tx(OWNER);
        let mut collection_2 = test.take_shared_by_id<Collection>(collection_id_2);
        let bal_2 = multicoin::mint_and_keep(
            &collection_cap_2,
            &mut collection_2,
            TEST_ASSET_ID_1,
            200,
            test.ctx(),
        );
        return_shared(collection_2);
        transfer::public_transfer(bal_2, ALICE);

        // Deposit from both collections
        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let bal_1 = test.take_from_sender<multicoin::Balance>();
        let bal_2 = test.take_from_sender<multicoin::Balance>();
        trading_account.deposit_multicoin(bal_1, test.ctx());
        trading_account.deposit_multicoin(bal_2, test.ctx());

        // Verify balances are tracked separately
        let balance_1 = trading_account.multicoin_balance(collection_id_1, TEST_ASSET_ID_1);
        let balance_2 = trading_account.multicoin_balance(collection_id_2, TEST_ASSET_ID_1);
        assert!(balance_1 == 100, 0);
        assert!(balance_2 == 200, 1);

        // Withdraw from collection_1
        let withdrawn_1 = trading_account.withdraw_multicoin(
            collection_id_1,
            TEST_ASSET_ID_1,
            50,
            test.ctx(),
        );
        let remaining_1 = trading_account.multicoin_balance(collection_id_1, TEST_ASSET_ID_1);
        assert!(remaining_1 == 50, 2);

        // Verify collection_2 balance unchanged
        let balance_2_after = trading_account.multicoin_balance(collection_id_2, TEST_ASSET_ID_1);
        assert!(balance_2_after == 200, 3);

        return_shared(trading_account);
        destroy(withdrawn_1);
        destroy(collection_cap_1);
        destroy(collection_cap_2);
        test.end();
    }

    #[test]
    fun test_multicoin_mixed_with_regular_coins_ok() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_multicoin_collection(&mut test);

        test.next_tx(ALICE);
        let trading_account = trading_account::new(test.ctx());
        let ta_id = object::id(&trading_account);
        transfer::public_share_object(trading_account);

        // Deposit regular SUI coin
        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        trading_account.deposit(mint_for_testing<SUI>(1000, test.ctx()), test.ctx());
        let sui_balance = trading_account.balance<SUI>();
        assert!(sui_balance == 1000, 0);
        return_shared(trading_account);

        // Deposit multicoin
        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let multicoin_bal = multicoin::mint_and_keep(
            &collection_cap,
            &mut collection,
            TEST_ASSET_ID_1,
            500,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(multicoin_bal, ALICE);

        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let multicoin_bal = test.take_from_sender<multicoin::Balance>();
        trading_account.deposit_multicoin(multicoin_bal, test.ctx());
        let multicoin_balance = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        assert!(multicoin_balance == 500, 1);

        // Verify SUI balance unchanged
        let sui_balance_after = trading_account.balance<SUI>();
        assert!(sui_balance_after == 1000, 2);
        return_shared(trading_account);

        // Withdraw regular coin
        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let withdrawn_sui = trading_account.withdraw<SUI>(300, test.ctx());
        let sui_remaining = trading_account.balance<SUI>();
        assert!(sui_remaining == 700, 3);

        // Verify multicoin balance unchanged
        let multicoin_balance_after = trading_account.multicoin_balance(
            collection_id,
            TEST_ASSET_ID_1,
        );
        assert!(multicoin_balance_after == 500, 4);
        return_shared(trading_account);
        destroy(withdrawn_sui);

        // Withdraw multicoin
        test.next_tx(ALICE);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(ta_id);
        let withdrawn_multicoin = trading_account.withdraw_multicoin(
            collection_id,
            TEST_ASSET_ID_1,
            200,
            test.ctx(),
        );
        let multicoin_remaining = trading_account.multicoin_balance(collection_id, TEST_ASSET_ID_1);
        assert!(multicoin_remaining == 300, 5);

        // Verify SUI balance still unchanged
        let sui_final = trading_account.balance<SUI>();
        assert!(sui_final == 700, 6);

        return_shared(trading_account);
        destroy(withdrawn_multicoin);
        destroy(collection_cap);
        test.end();
    }
}
