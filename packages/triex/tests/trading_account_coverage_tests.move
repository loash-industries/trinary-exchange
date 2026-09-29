#[test_only]
module triex::trading_account_coverage_tests {
    use multicoin::multicoin;
    use std::unit_test::{assert_eq, destroy};
    use sui::{balance, test_scenario::{begin, end}};
    use triex::{trading_account, trading_account_tests::USDC};

    const ALICE: address = @0xA;
    const ASSET_ID: u64 = 7;

    fun collection_id(): ID {
        object::id_from_address(@0xC0)
    }

    #[test]
    fun test_deposit_multicoin_permissionless_adds_then_joins() {
        let mut test = begin(ALICE);
        let mut acct = trading_account::new(test.ctx());
        acct.deposit_multicoin_permissionless(
            multicoin::create_balance_for_testing(collection_id(), ASSET_ID, 300, test.ctx()),
            test.ctx(),
        );
        assert_eq!(acct.multicoin_balance(collection_id(), ASSET_ID), 300);

        acct.deposit_multicoin_permissionless(
            multicoin::create_balance_for_testing(collection_id(), ASSET_ID, 200, test.ctx()),
            test.ctx(),
        );
        assert_eq!(acct.multicoin_balance(collection_id(), ASSET_ID), 500);

        destroy(acct);
        test.end();
    }

    #[test]
    fun test_deposit_permissionless_creates_then_joins_balance() {
        let mut test = begin(ALICE);
        let mut acct = trading_account::new(test.ctx());
        acct.deposit_permissionless(balance::create_for_testing<USDC>(400));
        assert_eq!(acct.balance<USDC>(), 400);
        acct.deposit_permissionless(balance::create_for_testing<USDC>(100));
        assert_eq!(acct.balance<USDC>(), 500);

        destroy(acct);
        test.end();
    }

    #[test, expected_failure(abort_code = trading_account::ETradingAccountBalanceTooLow)]
    fun test_withdraw_with_proof_missing_balance_e() {
        let mut test = begin(ALICE);
        let mut acct = trading_account::new(test.ctx());
        assert_eq!(acct.balance<USDC>(), 0);
        let proof = acct.generate_proof_as_owner(test.ctx());
        let withdrawn = acct.withdraw_with_proof<USDC>(&proof, 1, false);

        destroy(withdrawn);
        destroy(acct);
        test.end();
    }

    #[test]
    fun test_proof_records_trader() {
        let mut test = begin(ALICE);
        let mut acct = trading_account::new(test.ctx());
        let proof = acct.generate_proof_as_owner(test.ctx());
        assert_eq!(proof.trader(), ALICE);

        destroy(acct);
        test.end();
    }

    #[test]
    fun test_remove_fee_turnover_detaches_ring() {
        let mut test = begin(ALICE);
        let mut acct = trading_account::new(test.ctx());
        acct.record_fee_turnover<USDC>(1_000, test.ctx());
        assert_eq!(acct.fee_turnover<USDC>(test.ctx()), 1_000);

        acct.remove_fee_turnover<USDC>();
        assert_eq!(acct.fee_turnover<USDC>(test.ctx()), 0);

        // Removing again, with no ring attached, is a no-op.
        acct.remove_fee_turnover<USDC>();
        assert_eq!(acct.fee_turnover<USDC>(test.ctx()), 0);

        destroy(acct);
        test.end();
    }
}
