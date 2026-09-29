#[test_only]
module triex::coin_vault_coverage_tests {
    use std::unit_test::{assert_eq, destroy};
    use sui::{object::id_from_address, test_scenario::{Scenario, begin, end}};
    use token::cred::CRED;
    use triex::{
        balances,
        coin_vault::{Self, Vault},
        trading_account::{Self, TradingAccount},
        trading_account_tests::{USDC, SPAM, create_acct_and_share_with_funds}
    };

    const ALICE: address = @0xA;
    const BOB: address = @0xB;
    const FUNDS: u64 = 1_000_000;

    /// Alice's shared account plus a vault funded from it with `base`/`quote`/`cred`.
    fun funded_vault(
        base: u64,
        quote: u64,
        cred: u64,
        test: &mut Scenario,
    ): (Vault<SPAM, USDC>, TradingAccount) {
        let id = create_acct_and_share_with_funds(ALICE, FUNDS, test);
        test.next_tx(ALICE);
        let mut alice = test.take_shared_by_id<TradingAccount>(id);
        let proof = alice.generate_proof_as_owner(test.ctx());
        let mut vault = coin_vault::empty<SPAM, USDC>();
        vault.settle_trading_account(
            balances::new(0, 0, 0),
            balances::new(base, quote, cred),
            &mut alice,
            &proof,
            option::none(),
        );
        (vault, alice)
    }

    #[test]
    fun test_settle_cred_in_then_out() {
        let mut test = begin(ALICE);
        let (mut vault, mut alice) = funded_vault(0, 0, 5_000, &mut test);
        let (_, _, cred) = vault.balances();
        assert_eq!(cred, 5_000);
        assert_eq!(alice.balance<CRED>(), FUNDS - 5_000);

        let proof = alice.generate_proof_as_owner(test.ctx());
        vault.settle_trading_account(
            balances::new(0, 0, 2_000),
            balances::new(0, 0, 0),
            &mut alice,
            &proof,
            option::none(),
        );
        let (_, _, cred) = vault.balances();
        assert_eq!(cred, 3_000);
        assert_eq!(alice.balance<CRED>(), FUNDS - 3_000);

        destroy(vault);
        destroy(alice);
        test.end();
    }

    #[test]
    fun test_permissionless_quote_only_and_cred_only() {
        let mut test = begin(ALICE);
        let (mut vault, alice) = funded_vault(0, 1_000, 1_000, &mut test);

        test.next_tx(BOB);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(0, 300, 0),
            balances::new(0, 0, 0),
            &mut bob,
        );
        vault.settle_trading_account_permissionless(
            balances::new(0, 0, 400),
            balances::new(0, 0, 0),
            &mut bob,
        );
        assert_eq!(bob.balance<USDC>(), 300);
        assert_eq!(bob.balance<CRED>(), 400);
        assert_eq!(bob.balance<SPAM>(), 0);

        let (base, quote, cred) = vault.balances();
        assert_eq!(base, 0);
        assert_eq!(quote, 700);
        assert_eq!(cred, 600);

        destroy(bob);
        destroy(alice);
        destroy(vault);
        test.end();
    }

    #[test, expected_failure(abort_code = coin_vault::EHasOwedBalances)]
    fun test_permissionless_with_owed_cred_e() {
        let mut test = begin(ALICE);
        let (mut vault, alice) = funded_vault(1_000, 1_000, 1_000, &mut test);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(100, 0, 0),
            balances::new(0, 0, 1),
            &mut bob,
        );

        destroy(bob);
        destroy(alice);
        destroy(vault);
        test.end();
    }

    #[test, expected_failure(abort_code = coin_vault::EHasOwedBalances)]
    fun test_permissionless_with_owed_base_e() {
        let mut test = begin(ALICE);
        let (mut vault, alice) = funded_vault(1_000, 1_000, 1_000, &mut test);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(100, 0, 0),
            balances::new(1, 0, 0),
            &mut bob,
        );

        destroy(bob);
        destroy(alice);
        destroy(vault);
        test.end();
    }

    #[test, expected_failure(abort_code = coin_vault::EHasOwedBalances)]
    fun test_permissionless_with_owed_quote_e() {
        let mut test = begin(ALICE);
        let (mut vault, alice) = funded_vault(1_000, 1_000, 1_000, &mut test);
        let mut bob = trading_account::new(test.ctx());
        vault.settle_trading_account_permissionless(
            balances::new(100, 0, 0),
            balances::new(0, 1, 0),
            &mut bob,
        );

        destroy(bob);
        destroy(alice);
        destroy(vault);
        test.end();
    }

    #[test]
    fun test_move_zero_quote_to_fee_reserve_is_noop() {
        let mut test = begin(ALICE);
        let (mut vault, alice) = funded_vault(0, 1_000, 0, &mut test);
        vault.move_quote_to_fee_reserve(id_from_address(@0x1), alice.id(), 0, 0);

        let (_, quote, _) = vault.balances();
        assert_eq!(quote, 1_000);
        assert_eq!(vault.quote_fee_reserve_balance(), 0);

        destroy(alice);
        destroy(vault);
        test.end();
    }
}
