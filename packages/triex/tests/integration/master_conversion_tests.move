#[test_only]
module triex::integration_master_conversion_tests {
    use sui::{sui::SUI, test_scenario::{begin, end}};
    use token::cred::CRED;
    use triex::{
        constants,
        integration_test_utils::{Self as utils, ExpectedBalances},
        math,
        pool_tests,
        trading_account_tests::{Self as trading_account_tests, SPAM}
    };

    #[test]
    fun test_master_both_conversion_available_ok() {
        test_master_both_conversion_available(false);
    }

    #[test]
    fun test_master_both_conversion_available_cred_is_base_ok() {
        test_master_both_conversion_available(true);
    }

    // Test when there are 2 reference pools, and price points are added to both,
    // the quote conversion is used.
    fun test_master_both_conversion_available(cred_is_base: bool) {
        let mut test = begin(utils::owner());
        let registry_id = pool_tests::setup_test(utils::owner(), &mut test);
        pool_tests::set_time(0, &mut test);

        let starting_balance = 10000 * constants::float_scaling();
        let owner_trading_account_id = trading_account_tests::create_acct_and_share_with_funds(
            utils::owner(),
            starting_balance,
            &mut test,
        );

        // Create two reference pools.
        // Conversion is 100 CRED per SUI, 95 CRED per SPAM.
        let _pool1_reference_id = if (cred_is_base) {
            pool_tests::setup_reference_pool_cred_as_base<CRED, SUI>(
                utils::owner(),
                registry_id,
                owner_trading_account_id,
                constants::cred_multiplier(),
                &mut test,
            )
        } else {
            pool_tests::setup_reference_pool<SUI, CRED>(
                utils::owner(),
                registry_id,
                owner_trading_account_id,
                constants::cred_multiplier(),
                &mut test,
            )
        };
        let _pool2_reference_id = pool_tests::setup_reference_pool<SPAM, CRED>(
            utils::owner(),
            registry_id,
            owner_trading_account_id,
            95 * constants::float_scaling(),
            &mut test,
        );

        // Create pool with SUI as base asset and SPAM as quote asset.
        let pool1_id = pool_tests::setup_pool_with_default_fees<SUI, SPAM>(
            utils::owner(),
            registry_id,
            &mut test,
        );

        pool_tests::set_time(100_000, &mut test);

        let alice_trading_account_id = trading_account_tests::create_acct_and_share_with_funds(
            utils::alice(),
            starting_balance,
            &mut test,
        );
        let bob_trading_account_id = trading_account_tests::create_acct_and_share_with_funds(
            utils::bob(),
            starting_balance,
            &mut test,
        );
        let mut alice_balance: ExpectedBalances = utils::expected_balances_all(starting_balance);
        let mut bob_balance: ExpectedBalances = utils::expected_balances_all(starting_balance);

        // Variables to input into order.
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 3 * constants::float_scaling();
        let is_bid = true;
        let expire_timestamp = constants::max_u64();

        // Since both price points are available, SPAM (quote) conversion should be used.
        utils::execute_cross_trading<SUI, SPAM>(
            pool1_id,
            alice_trading_account_id,
            bob_trading_account_id,
            order_type,
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );

        let spam_delta = 2 * math::mul(quantity, price);
        let sui_delta = 2 * quantity;
        utils::sub_spam(&mut alice_balance, spam_delta);
        utils::add_sui(&mut alice_balance, sui_delta);
        utils::add_spam(&mut bob_balance, spam_delta);
        utils::sub_sui(&mut bob_balance, sui_delta);

        // Both sides pay, and they pay the same. `execute_cross_trading` crosses
        // once each way: Alice rests a bid that Bob lifts, then Alice lifts what
        // is left of Bob's ask. So each is maker on one leg and taker on the
        // other, and the bill is quote-denominated — SPAM here, not CRED.
        let half_quote = math::mul(price, quantity);
        let both_legs = utils::maker_fee_on(half_quote) + utils::taker_fee_on(half_quote);
        utils::sub_spam(&mut alice_balance, both_legs);
        utils::sub_spam(&mut bob_balance, both_legs);

        utils::check_balance(alice_trading_account_id, &alice_balance, &mut test);
        utils::check_balance(bob_trading_account_id, &bob_balance, &mut test);

        end(test);
    }
}
