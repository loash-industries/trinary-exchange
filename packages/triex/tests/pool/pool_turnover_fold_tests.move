/// Coin-pool twin of `multicoin_pool_turnover_fold_tests`: cancel and modify
/// fold the pool's pending maker turnover into the exchange-wide ring.
/// `withdraw_settled_amounts` is deliberately absent — it takes no `TxContext`
/// on this pool, so it cannot fold without breaking upgrade compatibility.
#[test_only]
module triex::pool_turnover_fold_tests {
    use std::unit_test::assert_eq;
    use sui::{sui::SUI, test_scenario::{Scenario, begin, end, return_shared}};
    use token::cred::CRED;
    use triex::{
        constants,
        pool::Pool,
        pool_test_utils,
        trading_account::TradingAccount,
        trading_account_tests::{USDC, create_acct_and_share_with_funds}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    /// Alice rests a bid that Bob half-fills. Returns (pool, alice, order id, credit).
    fun alice_earns_maker_credit(test: &mut Scenario): (ID, ID, u128, u128) {
        let registry_id = pool_test_utils::setup_test(OWNER, test);
        let funds = 1000000 * constants::float_scaling();
        let alice = create_acct_and_share_with_funds(ALICE, funds, test);
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(ALICE, registry_id, alice, test);
        let bob = create_acct_and_share_with_funds(BOB, funds, test);

        let price = 2 * constants::float_scaling();
        let quantity = 100 * constants::float_scaling();
        let order = pool_test_utils::place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            alice,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            test,
        );
        pool_test_utils::place_limit_order<SUI, USDC>(
            BOB,
            pool_id,
            bob,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity / 2,
            false,
            constants::max_u64(),
            test,
        );

        let credit = pool_turnover(pool_id, alice, test);
        assert_eq!(ring(alice, test), 0);
        assert!(credit > 0);
        (pool_id, alice, order.order_id(), credit)
    }

    fun ring(trading_account_id: ID, test: &mut Scenario): u128 {
        test.next_tx(OWNER);
        let ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let turnover = ta.fee_turnover<USDC>(test.ctx());
        return_shared(ta);
        turnover
    }

    fun pool_turnover(pool_id: ID, trading_account_id: ID, test: &mut Scenario): u128 {
        test.next_tx(OWNER);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let ta = test.take_shared_by_id<TradingAccount>(trading_account_id);
        let turnover = pool.account_fee_turnover(&ta, test.ctx());
        return_shared(ta);
        return_shared(pool);
        turnover
    }

    #[test]
    fun cancel_folds_pending_turnover() {
        let mut test = begin(OWNER);
        let (pool_id, alice, order_id, credit) = alice_earns_maker_credit(&mut test);

        pool_test_utils::cancel_order<SUI, USDC>(ALICE, pool_id, alice, order_id, &mut test);

        assert_eq!(ring(alice, &mut test), credit);
        assert_eq!(pool_turnover(pool_id, alice, &mut test), credit);
        end(test);
    }

    #[test]
    fun modify_folds_pending_turnover() {
        let mut test = begin(OWNER);
        let (pool_id, alice, order_id, credit) = alice_earns_maker_credit(&mut test);

        pool_test_utils::modify_order<SUI, USDC>(
            ALICE,
            pool_id,
            alice,
            order_id,
            75 * constants::float_scaling(),
            &mut test,
        );

        assert_eq!(ring(alice, &mut test), credit);
        assert_eq!(pool_turnover(pool_id, alice, &mut test), credit);
        end(test);
    }
}
