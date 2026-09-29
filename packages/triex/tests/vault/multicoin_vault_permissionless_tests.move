#[test_only]
module triex::multicoin_vault_permissionless_tests {
    use multicoin::multicoin;
    use std::unit_test::{assert_eq, destroy};
    use sui::{coin::mint_for_testing, test_scenario::{Scenario, begin, end}};
    use token::cred::CRED;
    use triex::{
        balances,
        multicoin_vault::{Self, MultiCoinVault},
        trading_account,
        trading_account_tests::USDC
    };

    const ALICE: address = @0xA;
    const BOB: address = @0xB;
    const ASSET_ID: u64 = 42;

    fun collection_id(): ID {
        object::id_from_address(@0xC0)
    }

    /// Vault holding `base`/`quote`/`cred`, funded through a proof-gated settle from Alice.
    fun funded_vault(base: u64, quote: u64, cred: u64, test: &mut Scenario): MultiCoinVault<USDC> {
        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id(), ASSET_ID, test.ctx());
        let mut alice = trading_account::new(test.ctx());
        alice.deposit(mint_for_testing<USDC>(quote + 1, test.ctx()), test.ctx());
        alice.deposit(mint_for_testing<CRED>(cred + 1, test.ctx()), test.ctx());
        alice.deposit_multicoin(
            multicoin::create_balance_for_testing(collection_id(), ASSET_ID, base + 1, test.ctx()),
            test.ctx(),
        );
        let proof = alice.generate_proof_as_owner(test.ctx());
        vault.settle_trading_account(
            balances::new(0, 0, 0),
            balances::new(base, quote, cred),
            &mut alice,
            &proof,
            option::none(),
            test.ctx(),
        );
        destroy(alice);
        vault
    }

    #[test]
    fun test_permissionless_settles_all_legs_and_joins_existing_base() {
        let mut test = begin(BOB);
        let mut vault = funded_vault(5_000, 4_000, 3_000, &mut test);

        test.next_tx(BOB);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(2_000, 1_500, 1_000),
            balances::new(0, 0, 0),
            &mut bob,
            test.ctx(),
        );
        assert_eq!(bob.multicoin_balance(collection_id(), ASSET_ID), 2_000);
        assert_eq!(bob.balance<USDC>(), 1_500);
        assert_eq!(bob.balance<CRED>(), 1_000);

        // Second base payout joins the balance already held by the account.
        vault.settle_trading_account_permissionless(
            balances::new(500, 0, 0),
            balances::new(0, 0, 0),
            &mut bob,
            test.ctx(),
        );
        assert_eq!(bob.multicoin_balance(collection_id(), ASSET_ID), 2_500);

        let (base, quote, cred) = vault.balances();
        assert_eq!(base, 2_500);
        assert_eq!(quote, 2_500);
        assert_eq!(cred, 2_000);

        destroy(bob);
        destroy(vault);
        test.end();
    }

    #[test]
    fun test_permissionless_quote_only_and_cred_only() {
        let mut test = begin(BOB);
        let mut vault = funded_vault(0, 1_000, 1_000, &mut test);

        test.next_tx(BOB);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(0, 300, 0),
            balances::new(0, 0, 0),
            &mut bob,
            test.ctx(),
        );
        vault.settle_trading_account_permissionless(
            balances::new(0, 0, 400),
            balances::new(0, 0, 0),
            &mut bob,
            test.ctx(),
        );
        assert_eq!(bob.balance<USDC>(), 300);
        assert_eq!(bob.balance<CRED>(), 400);
        assert_eq!(bob.multicoin_balance(collection_id(), ASSET_ID), 0);

        let (base, quote, cred) = vault.balances();
        assert_eq!(base, 0);
        assert_eq!(quote, 700);
        assert_eq!(cred, 600);

        destroy(bob);
        destroy(vault);
        test.end();
    }

    #[test, expected_failure(abort_code = multicoin_vault::EHasOwedBalances)]
    fun test_permissionless_with_owed_cred_e() {
        let mut test = begin(BOB);
        let mut vault = funded_vault(1_000, 1_000, 1_000, &mut test);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(100, 0, 0),
            balances::new(0, 0, 1),
            &mut bob,
            test.ctx(),
        );

        destroy(bob);
        destroy(vault);
        test.end();
    }

    #[test, expected_failure(abort_code = multicoin_vault::EHasOwedBalances)]
    fun test_permissionless_with_owed_base_e() {
        let mut test = begin(BOB);
        let mut vault = funded_vault(1_000, 1_000, 1_000, &mut test);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(100, 0, 0),
            balances::new(1, 0, 0),
            &mut bob,
            test.ctx(),
        );

        destroy(bob);
        destroy(vault);
        test.end();
    }

    #[test, expected_failure(abort_code = multicoin_vault::EHasOwedBalances)]
    fun test_permissionless_with_owed_quote_e() {
        let mut test = begin(BOB);
        let mut vault = funded_vault(1_000, 1_000, 1_000, &mut test);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(100, 0, 0),
            balances::new(0, 1, 0),
            &mut bob,
            test.ctx(),
        );

        destroy(bob);
        destroy(vault);
        test.end();
    }

    #[test, expected_failure(abort_code = multicoin_vault::ENoBalanceToSettle)]
    fun test_permissionless_nothing_to_settle_e() {
        let mut test = begin(BOB);
        let mut vault = funded_vault(1_000, 1_000, 1_000, &mut test);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(0, 0, 0),
            balances::new(0, 0, 0),
            &mut bob,
            test.ctx(),
        );

        destroy(bob);
        destroy(vault);
        test.end();
    }

    #[test, expected_failure(abort_code = multicoin_vault::EInsufficientBaseBalance)]
    fun test_permissionless_insufficient_base_e() {
        let mut test = begin(BOB);
        let mut vault = funded_vault(100, 1_000, 1_000, &mut test);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(101, 0, 0),
            balances::new(0, 0, 0),
            &mut bob,
            test.ctx(),
        );

        destroy(bob);
        destroy(vault);
        test.end();
    }

    #[test, expected_failure(abort_code = multicoin_vault::EInsufficientQuoteBalance)]
    fun test_permissionless_insufficient_quote_e() {
        let mut test = begin(BOB);
        let mut vault = funded_vault(1_000, 100, 1_000, &mut test);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(0, 101, 0),
            balances::new(0, 0, 0),
            &mut bob,
            test.ctx(),
        );

        destroy(bob);
        destroy(vault);
        test.end();
    }

    #[test, expected_failure(abort_code = multicoin_vault::EInsufficientCredBalance)]
    fun test_permissionless_insufficient_cred_e() {
        let mut test = begin(BOB);
        let mut vault = funded_vault(1_000, 1_000, 100, &mut test);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(0, 0, 101),
            balances::new(0, 0, 0),
            &mut bob,
            test.ctx(),
        );

        destroy(bob);
        destroy(vault);
        test.end();
    }

    #[test]
    fun test_move_zero_quote_to_fee_reserve_is_noop() {
        let mut test = begin(BOB);
        let mut vault = funded_vault(0, 1_000, 0, &mut test);
        vault.move_quote_to_fee_reserve(
            object::id_from_address(@0x9001),
            object::id_from_address(@0x9002),
            0,
            0,
        );

        let (_, quote, _) = vault.balances();
        assert_eq!(quote, 1_000);
        assert_eq!(vault.quote_fee_reserve_balance(), 0);

        destroy(vault);
        test.end();
    }

    #[test, expected_failure(abort_code = multicoin_vault::EInsufficientFeeReserve)]
    fun test_withdraw_quote_fees_above_reserve_e() {
        let mut test = begin(BOB);
        let mut vault = multicoin_vault::empty<USDC>(collection_id(), ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(1_000, test.ctx()).into_balance());
        assert_eq!(vault.quote_fee_reserve_balance(), 1_000);

        let fees = vault.withdraw_quote_fees(1_001, test.ctx());

        destroy(fees);
        destroy(vault);
        test.end();
    }
}
