#[test_only]
module triex::multicoin_vault_tests {
    use multicoin::multicoin::{Self, Balance as MultiCoinBalance, Collection, CollectionCap};
    use std::unit_test::destroy;
    use sui::{
        coin::mint_for_testing,
        test_scenario::{Scenario, next_tx, begin, end, return_shared}
    };
    use token::cred::CRED;
    use triex::{
        balances,
        constants,
        multicoin_vault,
        trading_account::{Self, TradingAccount},
        trading_account_tests::USDC
    };

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;
    const BOB: address = @0xB;

    // Test asset ID
    const TEST_ASSET_ID: u64 = 42;

    // === Helper Functions ===

    /// Stand-in pool id for the vault-level suites, which construct a vault
    /// directly and have no pool. Only ever reaches an event field.
    fun test_pool_id(): ID {
        object::id_from_address(@0x9001)
    }

    /// Setup a MultiCoin collection for testing
    fun setup_collection(test: &mut Scenario): (ID, CollectionCap) {
        test.next_tx(OWNER);
        let (collection, collection_cap) = multicoin::new_collection(test.ctx());
        let collection_id = object::id(&collection);
        sui::transfer::public_share_object(collection);
        (collection_id, collection_cap)
    }

    /// Create a trading account with both Coin and MultiCoin funds
    fun create_multicoin_acct_and_share_with_funds(
        sender: address,
        coin_amount: u64,
        collection_cap: &CollectionCap,
        multicoin_asset_id: u64,
        multicoin_amount: u64,
        test: &mut Scenario,
    ): ID {
        test.next_tx(sender);
        let mut trading_account = trading_account::new(test.ctx());

        // Deposit Coin-based assets
        trading_account.deposit(
            mint_for_testing<USDC>(coin_amount, test.ctx()),
            test.ctx(),
        );
        trading_account.deposit(
            mint_for_testing<CRED>(coin_amount, test.ctx()),
            test.ctx(),
        );

        // Deposit MultiCoin balance
        if (multicoin_amount > 0) {
            // Mint MultiCoin using collection
            let mut collection = test.take_shared<Collection>();
            let multicoin_balance = multicoin::mint_and_keep(
                collection_cap,
                &mut collection,
                multicoin_asset_id,
                multicoin_amount,
                test.ctx(),
            );
            return_shared(collection);

            // Transfer to sender first, then deposit
            transfer::public_transfer(multicoin_balance, sender);
        };

        let trade_cap = trading_account.mint_trade_cap(test.ctx());
        transfer::public_transfer(trade_cap, sender);
        let id = object::id(&trading_account);
        transfer::public_share_object(trading_account);

        // If we minted multicoin, deposit it now
        if (multicoin_amount > 0) {
            test.next_tx(sender);
            let mut trading_account_mut = test.take_shared_by_id<TradingAccount>(id);
            let multicoin_bal = test.take_from_sender<MultiCoinBalance>();
            trading_account_mut.deposit_multicoin(multicoin_bal, test.ctx());
            return_shared(trading_account_mut);
        };

        id
    }

    // === Tests ===

    #[test]
    fun test_empty_vault_creation() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());

        let (base, quote, cred) = vault.balances();
        assert!(base == 0, 0);
        assert!(quote == 0, 1);
        assert!(cred == 0, 2);
        assert!(vault.collection_id() == collection_id, 3);
        assert!(vault.asset_id() == TEST_ASSET_ID, 4);

        destroy(vault);
        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_owed_equals_settled_ok() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let settled_balances = balances::new(1000, 1000, 1000);
        let owed_balances = balances::new(1000, 1000, 1000);
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // Move funds into the vault (equal amounts in and out should be no-op)
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        destroy(vault);
        destroy(trading_account);
        destroy(collection_cap);
        test.end();
    }

    #[test]
    #[expected_failure(abort_code = trading_account::EInvalidProof)]
    fun test_owed_equals_settled_invalid_proof_e() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id_alice = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let trading_account_id_bob = create_multicoin_acct_and_share_with_funds(
            BOB,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let settled_balances = balances::new(1000, 1000, 1000);
        let owed_balances = balances::new(1000, 1000, 1000);
        let mut trading_account_alice = test.take_shared_by_id<TradingAccount>(
            trading_account_id_alice,
        );
        let mut trading_account_bob = test.take_shared_by_id<TradingAccount>(
            trading_account_id_bob,
        );
        let trade_proof = trading_account_alice.generate_proof_as_owner(test.ctx());

        // Try to use Alice's proof with Bob's trading_account (should fail)
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account_bob,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        destroy(vault);
        destroy(trading_account_bob);
        destroy(trading_account_alice);
        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_withdraw_cred_to_burn() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // Put CRED in vault
        let owed = balances::new(0, 0, 10000);
        let settled = balances::new(0, 0, 0);
        vault.settle_trading_account(
            settled,
            owed,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Withdraw 3000 CRED for burning
        let cred_to_burn = vault.withdraw_cred_to_burn(3000);
        assert!(cred_to_burn.value() == 3000, 0);

        // Vault should have 7000 CRED left
        let (_base, _quote, cred) = vault.balances();
        assert!(cred == 7000, 1);

        destroy(cred_to_burn);
        destroy(vault);
        destroy(trading_account);
        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_settle_vault_owes_base_to_user() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // First, put some base tokens into the vault
        let initial_owed = balances::new(5000, 0, 0);
        let initial_settled = balances::new(0, 0, 0);
        vault.settle_trading_account(
            initial_settled,
            initial_owed,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Verify vault has 5000 base
        let (base, quote, cred) = vault.balances();
        assert!(base == 5000, 0);
        assert!(quote == 0, 1);
        assert!(cred == 0, 2);

        // Now vault owes user 2000 base (settled > owed)
        let settled_balances = balances::new(2000, 0, 0);
        let owed_balances = balances::new(0, 0, 0);
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Vault should have 3000 base left
        let (base_after, quote_after, cred_after) = vault.balances();
        assert!(base_after == 3000, 3);
        assert!(quote_after == 0, 4);
        assert!(cred_after == 0, 5);

        destroy(vault);
        destroy(trading_account);
        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_settle_user_owes_base_to_vault() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // User owes vault 3000 base (owed > settled)
        let settled_balances = balances::new(0, 0, 0);
        let owed_balances = balances::new(3000, 0, 0);
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Vault should have 3000 base
        let (base, quote, cred) = vault.balances();
        assert!(base == 3000, 0);
        assert!(quote == 0, 1);
        assert!(cred == 0, 2);

        destroy(vault);
        destroy(trading_account);
        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_settle_vault_owes_quote_to_user() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // First, put some quote tokens into the vault
        let initial_owed = balances::new(0, 5000, 0);
        let initial_settled = balances::new(0, 0, 0);
        vault.settle_trading_account(
            initial_settled,
            initial_owed,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Verify vault has 5000 quote
        let (base, quote, cred) = vault.balances();
        assert!(base == 0, 0);
        assert!(quote == 5000, 1);
        assert!(cred == 0, 2);

        // Now vault owes user 2000 quote
        let settled_balances = balances::new(0, 2000, 0);
        let owed_balances = balances::new(0, 0, 0);
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Vault should have 3000 quote left
        let (base_after, quote_after, cred_after) = vault.balances();
        assert!(base_after == 0, 3);
        assert!(quote_after == 3000, 4);
        assert!(cred_after == 0, 5);

        destroy(vault);
        destroy(trading_account);
        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_settle_user_owes_quote_to_vault() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // User owes vault 3000 quote
        let settled_balances = balances::new(0, 0, 0);
        let owed_balances = balances::new(0, 3000, 0);
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Vault should have 3000 quote
        let (base, quote, cred) = vault.balances();
        assert!(base == 0, 0);
        assert!(quote == 3000, 1);
        assert!(cred == 0, 2);

        destroy(vault);
        destroy(trading_account);
        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_settle_vault_owes_cred_to_user() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // First, put some CRED tokens into the vault
        let initial_owed = balances::new(0, 0, 5000);
        let initial_settled = balances::new(0, 0, 0);
        vault.settle_trading_account(
            initial_settled,
            initial_owed,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Verify vault has 5000 CRED
        let (base, quote, cred) = vault.balances();
        assert!(base == 0, 0);
        assert!(quote == 0, 1);
        assert!(cred == 5000, 2);

        // Now vault owes user 2000 CRED
        let settled_balances = balances::new(0, 0, 2000);
        let owed_balances = balances::new(0, 0, 0);
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Vault should have 3000 CRED left
        let (base_after, quote_after, cred_after) = vault.balances();
        assert!(base_after == 0, 3);
        assert!(quote_after == 0, 4);
        assert!(cred_after == 3000, 5);

        destroy(vault);
        destroy(trading_account);
        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_settle_user_owes_cred_to_vault() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // User owes vault 3000 CRED
        let settled_balances = balances::new(0, 0, 0);
        let owed_balances = balances::new(0, 0, 3000);
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Vault should have 3000 CRED
        let (base, quote, cred) = vault.balances();
        assert!(base == 0, 0);
        assert!(quote == 0, 1);
        assert!(cred == 3000, 2);

        destroy(vault);
        destroy(trading_account);
        destroy(collection_cap);
        test.end();
    }

    #[test]
    fun test_settle_complex_multi_asset() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // Complex settlement: user owes base and quote, vault owes CRED
        // First put CRED in vault
        let setup_owed = balances::new(0, 0, 5000);
        let setup_settled = balances::new(0, 0, 0);
        vault.settle_trading_account(
            setup_settled,
            setup_owed,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Now: user owes 1000 base + 2000 quote, vault owes 1500 CRED
        let settled_balances = balances::new(0, 0, 1500);
        let owed_balances = balances::new(1000, 2000, 0);
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        // Vault should have: 1000 base, 2000 quote, 3500 CRED (5000 - 1500)
        let (base, quote, cred) = vault.balances();
        assert!(base == 1000, 0);
        assert!(quote == 2000, 1);
        assert!(cred == 3500, 2);

        destroy(vault);
        destroy(trading_account);
        destroy(collection_cap);
        test.end();
    }

    #[test]
    #[expected_failure(abort_code = multicoin_vault::EInsufficientBaseBalance)]
    fun test_settle_insufficient_base_e() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // Try to settle more base than vault has (vault owes 1000 base but has 0)
        let settled_balances = balances::new(1000, 0, 0);
        let owed_balances = balances::new(0, 0, 0);
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        abort (0)
    }

    #[test]
    #[expected_failure(abort_code = multicoin_vault::EInsufficientQuoteBalance)]
    fun test_settle_insufficient_quote_e() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // Try to settle more quote than vault has
        let settled_balances = balances::new(0, 1000, 0);
        let owed_balances = balances::new(0, 0, 0);
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        abort (0)
    }

    #[test]
    #[expected_failure(abort_code = multicoin_vault::EInsufficientCredBalance)]
    fun test_settle_insufficient_cred_e() {
        let mut test = begin(OWNER);

        let (collection_id, collection_cap) = setup_collection(&mut test);
        let trading_account_id = create_multicoin_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &collection_cap,
            TEST_ASSET_ID,
            1000000 * constants::float_scaling(),
            &mut test,
        );

        test.next_tx(ALICE);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        let mut trading_account = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let trade_proof = trading_account.generate_proof_as_owner(test.ctx());

        // Try to settle more CRED than vault has
        let settled_balances = balances::new(0, 0, 1000);
        let owed_balances = balances::new(0, 0, 0);
        vault.settle_trading_account(
            settled_balances,
            owed_balances,
            &mut trading_account,
            &trade_proof,
            option::none(),
            test.ctx(),
        );

        abort (0)
    }

    // === Quote Fee Reserve Tests ===
    // Mirrors of `vault_tests`' fee-reserve suite. The locked-escrow mechanism is
    // duplicated code between the two vaults, so it needs duplicated tests — a fix
    // applied to one vault and not the other would otherwise ship silently.

    #[test]
    fun test_withdrawable_excludes_locked_escrow() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(10_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(4_000);

        assert!(vault.quote_fee_reserve_balance() == 10_000);
        assert!(vault.locked_maker_fees() == 4_000);
        assert!(vault.withdrawable_quote_fees() == 6_000);

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_recognizing_escrow_moves_it_to_withdrawable() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(10_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(4_000);

        // Recognition reclassifies without moving funds. At 0 bps — an
        // unconfigured hub — the whole recognized amount is immediately the
        // treasury's: no holdback, no settlement step, nothing provisional.
        vault.recognize_locked_maker_fees(1_500, 0);
        assert!(vault.quote_fee_reserve_balance() == 10_000);
        assert!(vault.locked_maker_fees() == 2_500);
        assert!(vault.hub_owed() == 0);
        assert!(vault.withdrawable_quote_fees() == 7_500);

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_recognizing_escrow_splits_with_the_hub_eagerly() {
        // The eager split: recognition at a live rate credits the hub its share
        // of exactly what was recognized, and the remainder is the treasury's in
        // the same instant.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(10_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(4_000);

        vault.recognize_locked_maker_fees(1_500, max_bps());
        assert!(vault.quote_fee_reserve_balance() == 10_000);
        assert!(vault.locked_maker_fees() == 2_500);
        // 40% of 1_500 = 600 to the hub, exactly; the remaining 900 plus the
        // 6_000 never locked is sweepable now.
        assert!(vault.hub_owed() == 600);
        assert!(vault.withdrawable_quote_fees() == 6_900);
        assert_solvent(&vault);

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_recognizing_more_than_locked_saturates_at_zero() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(10_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(1_000);

        // Per-fill flooring can never exceed the once-floored lock, but the
        // counter saturates rather than underflowing if it ever did.
        vault.recognize_locked_maker_fees(4_000, max_bps());
        assert!(vault.locked_maker_fees() == 0);
        // The hub is credited off the actual decrement, not the request. Off the
        // request it would be 40% of 4_000 = 1_600 — a claim on revenue that was
        // never recognized, subtracted from a reserve that never received it.
        assert!(vault.hub_owed() == 400);
        assert!(vault.withdrawable_quote_fees() == 9_600);

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_withdraw_exactly_unlocked_ok() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(10_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(4_000);

        let fee_coin = vault.withdraw_quote_fees(6_000, test.ctx());
        assert!(fee_coin.value() == 6_000);
        // The escrow is untouched and still fully backed.
        assert!(vault.quote_fee_reserve_balance() == 4_000);
        assert!(vault.locked_maker_fees() == 4_000);
        assert!(vault.withdrawable_quote_fees() == 0);

        destroy(fee_coin);
        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = multicoin_vault::EFeesLocked)]
    fun test_withdraw_one_above_unlocked_e() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(10_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(4_000);

        let fee_coin = vault.withdraw_quote_fees(6_001, test.ctx());

        destroy(fee_coin);
        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = multicoin_vault::EInsufficientFeeReserve)]
    fun test_unlock_more_than_reserve_e() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(1_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(1_000);

        vault.unlock_quote_fees(
            collection_id,
            1,
            collection_id,
            2_000,
            0,
        );

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_unlock_moves_escrow_out_of_the_reserve() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(10_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(4_000);

        // A refund leaves the reserve entirely, so it stops counting as escrow
        // too — otherwise the counter would strand the funds it no longer holds.
        vault.unlock_quote_fees(collection_id, 1, collection_id, 3_000, 0);
        assert!(vault.quote_fee_reserve_balance() == 7_000);
        assert!(vault.locked_maker_fees() == 1_000);
        assert!(vault.withdrawable_quote_fees() == 6_000);

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    // === Hub Revenue Share Tests ===
    // The reserve carries a second claim beside escrow. These exercise the
    // arithmetic that keeps `reserve >= encumbered()` true, which is what makes
    // both claims payable out of one balance.

    fun max_bps(): u64 {
        constants::max_hub_share_bps()
    }

    /// The invariant the whole shared-pot construction rests on. Asserted after
    /// every operation below, because the moment it fails one of the claimants
    /// is owed money the reserve does not hold.
    fun assert_solvent<QuoteAsset>(vault: &multicoin_vault::MultiCoinVault<QuoteAsset>) {
        assert!((vault.quote_fee_reserve_balance() as u128) >= vault.encumbered());
    }

    #[test]
    fun test_hub_credit_floors() {
        // The credit floors, so a unit of revenue can never mint more than its
        // ceiling share of a claim. One unit at 40% credits zero.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(1_000, test.ctx()).into_balance());

        vault.credit_hub_share(1, max_bps());
        assert!(vault.hub_owed() == 0);
        assert_solvent(&vault);

        vault.credit_hub_share(3, 3_333);
        assert!(vault.hub_owed() == 0);

        vault.credit_hub_share(10, 1_000);
        assert!(vault.hub_owed() == 1);
        assert_solvent(&vault);

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_credit_never_exceeds_the_ceiling_share() {
        // Swept across amounts and rates where flooring bites hardest: the credit
        // must never exceed `amount × MAX / 10000`, or a recognition would mint a
        // claim the reserve deposit did not cover.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let amounts = vector[1u64, 2, 3, 7, 99, 100, 101, 2_499, 2_500, 9_999];
        let rates = vector[0u64, 1, 7, 1_000, 3_333, max_bps()];

        amounts.do_ref!(|amount| {
            rates.do_ref!(|bps| {
                let mut vault = multicoin_vault::empty<USDC>(
                    collection_id,
                    TEST_ASSET_ID,
                    test.ctx(),
                );
                vault.deposit_quote_fees(
                    mint_for_testing<USDC>(*amount, test.ctx()).into_balance(),
                );
                vault.credit_hub_share(*amount, *bps);

                assert!(
                    (vault.hub_owed() as u128) <=
                    (*amount as u128) * (max_bps() as u128) / 10_000,
                );
                assert_solvent(&vault);

                destroy(vault);
            });
        });

        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_encumbered_sums_both_claims() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(10_000, test.ctx()).into_balance());

        // 2_000 of escrow left locked, 1_500 recognized at 40% (= 600 owed).
        vault.lock_maker_fees_for_testing(3_500);
        vault.recognize_locked_maker_fees(1_500, max_bps());

        assert!(vault.locked_maker_fees() == 2_000);
        assert!(vault.hub_owed() == 600);
        assert!(vault.encumbered() == 2_600);
        assert!(vault.withdrawable_quote_fees() == 7_400);
        assert_solvent(&vault);

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = multicoin_vault::EFeesLocked)]
    fun test_sweep_cannot_take_hub_owed() {
        // The guardrail: the operator's accrued share is not the treasury's to
        // sweep.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(1_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(1_000);
        vault.recognize_locked_maker_fees(1_000, max_bps());
        assert!(vault.hub_owed() == 400);

        // 400 is the hub's, so 601 is one unit too many.
        assert!(vault.withdrawable_quote_fees() == 600);
        let coin = vault.withdraw_quote_fees(601, test.ctx());

        destroy(coin);
        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = multicoin_vault::EHubShareAboveCeiling)]
    fun test_crediting_above_the_ceiling_aborts() {
        // MAX_HUB_SHARE_BPS is the number stated in CAPABILITIES.md, so the vault
        // enforces it rather than trusting the policy to have done so.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(1_000, test.ctx()).into_balance());

        vault.credit_hub_share(1_000, max_bps() + 1);

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_claim_pays_the_accrued_share_and_zeroes_it() {
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(1_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(1_000);
        vault.recognize_locked_maker_fees(1_000, 1_000); // 10%

        assert!(vault.hub_owed() == 100);
        let share = vault.claim_hub_share(test_pool_id(), ALICE, 0, test.ctx());

        assert!(share.value() == 100);
        assert!(vault.hub_owed() == 0);
        assert!(vault.quote_fee_reserve_balance() == 900);
        // The claim consumed its own encumbrance, so the rest is the treasury's.
        assert!(vault.withdrawable_quote_fees() == 900);
        assert_solvent(&vault);

        destroy(share);
        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_claiming_nothing_is_harmless() {
        // A payout cron sweeping many pools will hit plenty with nothing owed.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(500, test.ctx()).into_balance());

        let share = vault.claim_hub_share(test_pool_id(), ALICE, 0, test.ctx());
        assert!(share.value() == 0);
        assert!(vault.withdrawable_quote_fees() == 500);

        destroy(share);
        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_escrow_refund_leaves_the_hub_claim_untouched() {
        // A refund must come out of escrow, never out of a settled share. If
        // `unlock` could reach past `locked_maker_fees`, the operator's coin would
        // fund a maker's refund and the claim would abort later.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(10_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(6_000);
        vault.recognize_locked_maker_fees(2_000, max_bps());
        assert!(vault.hub_owed() == 800);

        // Refund the escrow that is still locked.
        vault.unlock_quote_fees(collection_id, 1, collection_id, 4_000, 0);

        assert!(vault.locked_maker_fees() == 0);
        assert!(vault.hub_owed() == 800);
        assert!(vault.quote_fee_reserve_balance() == 6_000);
        assert!(vault.withdrawable_quote_fees() == 5_200);
        assert_solvent(&vault);

        // And the share is still payable.
        let share = vault.claim_hub_share(test_pool_id(), ALICE, 0, test.ctx());
        assert!(share.value() == 800);

        destroy(share);
        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_recognitions_at_different_rates_accumulate_exactly() {
        // A re-price between two recognitions must price each at its own rate —
        // the eager equivalent of the old per-epoch bucket separation, with the
        // rate applied the instant the revenue exists instead of later.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(10_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(3_000);

        // 1_000 recognized at 10%, then 2_000 at 40% — not one blended rate.
        vault.recognize_locked_maker_fees(1_000, 1_000);
        assert!(vault.hub_owed() == 100);
        vault.recognize_locked_maker_fees(2_000, max_bps());
        assert!(vault.hub_owed() == 900);
        assert_solvent(&vault);

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_an_impossible_shortfall_blocks_the_sweep_without_bricking_the_view() {
        // Regression. `unlock_quote_fees` decrements escrow by
        // `amount.min(locked_maker_fees)` but the reserve by the full amount, so a
        // refund larger than what is still counted as escrow eats recognized
        // revenue. Order-level accounting makes that unreachable — a release never
        // exceeds what its own order locked — but the counter is pool-wide and the
        // existing code carries that `min` defensively rather than relying on it.
        //
        // The hub claim on the reserve keeps the consequence severe:
        // `reserve - encumbered()` would underflow, and a `u64` underflow aborts,
        // taking down `withdraw_pool_fees` *and* the public
        // `withdrawable_pool_fees()` view permanently. Saturating keeps the sweep
        // blocked — which is correct, the money is claimed — while leaving every
        // read answerable.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(1_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(100);
        vault.recognize_locked_maker_fees(100, max_bps());
        assert!(vault.hub_owed() == 40);

        // Escrow is already zero, so this refund drains revenue the operator is owed
        // against.
        vault.unlock_quote_fees(collection_id, 1, collection_id, 970, 0);
        assert!(vault.quote_fee_reserve_balance() == 30);
        assert!(vault.encumbered() == 40);

        // Reads still answer, and the treasury is allowed nothing.
        assert!(vault.withdrawable_quote_fees() == 0);

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = multicoin_vault::EInsufficientFeeReserve)]
    fun test_a_shortfall_still_fails_loudly_on_the_claim() {
        // The other half of the trade-off above: quiet on the sweep, loud on the
        // claim. An operator must never be handed a coin the reserve cannot cover,
        // so the claim keeps its hard assert and is where a real shortfall surfaces.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(1_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(100);
        vault.recognize_locked_maker_fees(100, max_bps());
        vault.unlock_quote_fees(collection_id, 1, collection_id, 970, 0);

        let share = vault.claim_hub_share(test_pool_id(), ALICE, 0, test.ctx());

        destroy(share);
        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_solvency_holds_across_a_stream_of_recognitions() {
        // Every recognition credits `floor(amount × bps)` against a reserve that
        // grew by at least `amount`, so the invariant must survive any sequence
        // of amounts and rates with no cushion. The reserve is set to exactly
        // the recognized revenue so an off-by-one has nowhere to hide.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);

        // Amounts and rates chosen so the division leaves a large fractional
        // part in both directions.
        let amounts = vector[1u64, 3, 7, 2_501, 9_999, 10_000, 33_333, 1];
        let rates = vector[max_bps(), 1, 3_333, 9, 2_500, 0, 1_999, max_bps()];

        let mut total = 0;
        amounts.do_ref!(|b| total = total + *b);

        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(total, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(total);

        let mut expected_owed = 0;
        let mut i = 0;
        while (i < amounts.length()) {
            vault.recognize_locked_maker_fees(amounts[i], rates[i]);
            expected_owed =
                expected_owed + (((amounts[i] as u128) * (rates[i] as u128) / 10_000) as u64);
            assert!(vault.hub_owed() == expected_owed);
            assert_solvent(&vault);
            i = i + 1;
        };
        assert!(vault.locked_maker_fees() == 0);

        // Everything divided: the operator's share plus the treasury's is the whole
        // reserve, with nothing stranded and nothing conjured.
        assert!(vault.withdrawable_quote_fees() == total - expected_owed);

        let share = vault.claim_hub_share(test_pool_id(), ALICE, 0, test.ctx());
        assert!(share.value() == expected_owed);
        assert!(vault.quote_fee_reserve_balance() == total - expected_owed);
        assert_solvent(&vault);

        destroy(share);
        destroy(vault);
        destroy(collection_cap);
        end(test);
    }

    #[test]
    fun test_solvency_holds_when_claims_interleave_with_recognition() {
        // A payout cron and a trading pool do not take turns. Revenue keeps
        // arriving between claims, so the counters have to stay solvent when
        // `claim` and `recognize` interleave.
        let mut test = begin(OWNER);
        let (collection_id, collection_cap) = setup_collection(&mut test);
        let mut vault = multicoin_vault::empty<USDC>(collection_id, TEST_ASSET_ID, test.ctx());
        vault.deposit_quote_fees(mint_for_testing<USDC>(100_000, test.ctx()).into_balance());
        vault.lock_maker_fees_for_testing(100_000);

        let mut round = 0;
        let mut total_claimed = 0;
        while (round < 12) {
            let amount = 137 + round * 11;
            vault.recognize_locked_maker_fees(amount, 3_700);
            let expected = ((amount as u128) * 3_700 / 10_000) as u64;
            assert!(vault.hub_owed() == expected);
            assert_solvent(&vault);

            let share = vault.claim_hub_share(test_pool_id(), ALICE, 0, test.ctx());
            assert!(share.value() == expected);
            assert!(vault.hub_owed() == 0);
            total_claimed = total_claimed + share.value();
            assert_solvent(&vault);
            destroy(share);

            round = round + 1;
        };

        assert!(vault.quote_fee_reserve_balance() == 100_000 - total_claimed);
        assert_solvent(&vault);

        destroy(vault);
        destroy(collection_cap);
        end(test);
    }
}
