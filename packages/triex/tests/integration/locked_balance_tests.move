#[test_only]
module triex::integration_locked_balance_tests {
    use sui::{sui::SUI, test_scenario::{begin, end}};
    use token::cred::CRED;
    use triex::{
        constants,
        integration_test_utils as utils,
        math,
        pool_test_utils,
        pool_tests,
        trading_account_tests::{Self as trading_account_tests, USDC}
    };

    #[test]
    fun test_locked_balance_bid_ok() {
        test_locked_balance(true)
    }

    #[test]
    fun test_locked_balance_ask_ok() {
        test_locked_balance(false)
    }

    /// Default maker rate for a volatile pool: 0.9%.
    fun maker_fee_on(quote_quantity: u64): u64 {
        math::mul(quote_quantity, pool_test_utils::default_maker_fee())
    }

    fun test_locked_balance(is_bid: bool) {
        let mut test = begin(utils::owner());
        let registry_id = pool_tests::setup_test(utils::owner(), &mut test);
        pool_tests::set_time(0, &mut test);

        let starting_balance = 10000 * constants::float_scaling();
        let owner_trading_account_id = trading_account_tests::create_acct_and_share_with_funds(
            utils::owner(),
            starting_balance,
            &mut test,
        );

        let _pool1_reference_id = pool_tests::setup_reference_pool<SUI, CRED>(
            utils::owner(),
            registry_id,
            owner_trading_account_id,
            constants::cred_multiplier(),
            &mut test,
        );

        let pool1_id = pool_tests::setup_pool_with_default_fees<SUI, USDC>(
            utils::owner(),
            registry_id,
            &mut test,
        );

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

        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 3 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        // A bid locks its quote principal plus the maker fee charged on it; an
        // ask locks only base, and is charged out of its quote proceeds on fill.
        let quote = math::mul(price, quantity);
        let mut alice_locked_balance = utils::expected_balances_all(0);

        assert!(test.ctx().epoch() == 0, 0);

        utils::check_locked_balance<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            &alice_locked_balance,
            &mut test,
        );

        pool_tests::place_limit_order<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );

        if (is_bid) {
            utils::add_usdc(&mut alice_locked_balance, quote + maker_fee_on(quote));
        } else {
            utils::add_sui(&mut alice_locked_balance, quantity);
        };

        utils::check_locked_balance<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            &alice_locked_balance,
            &mut test,
        );

        pool_tests::place_limit_order<SUI, USDC>(
            utils::bob(),
            pool1_id,
            bob_trading_account_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity / 2,
            !is_bid,
            expire_timestamp,
            &mut test,
        );

        if (is_bid) {
            // Half the bid filled: both its principal and its fee shrink with the
            // remaining quantity.
            utils::sub_usdc(&mut alice_locked_balance, quote / 2 + maker_fee_on(quote / 2));
            utils::add_sui(&mut alice_locked_balance, quantity / 2);
        } else {
            // Alice's ask proceeds settle net of the maker fee taken out of them.
            utils::add_usdc(&mut alice_locked_balance, quote / 2 - maker_fee_on(quote / 2));
            utils::sub_sui(&mut alice_locked_balance, quantity / 2);
        };

        utils::check_locked_balance<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            &alice_locked_balance,
            &mut test,
        );

        pool_tests::place_limit_order<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );

        if (is_bid) {
            utils::add_usdc(&mut alice_locked_balance, quote + maker_fee_on(quote));
            utils::sub_sui(&mut alice_locked_balance, quantity / 2);
        } else {
            utils::add_sui(&mut alice_locked_balance, quantity);
            // Placing again settles her netted proceeds out to her trading account
            utils::sub_usdc(&mut alice_locked_balance, quote / 2 - maker_fee_on(quote / 2));
        };

        utils::check_locked_balance<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            &alice_locked_balance,
            &mut test,
        );

        end(test);
    }

    /// An ask locks base and nothing else, so reading its locked balance must not
    /// depend on its quote leg being representable. `qty_to_quote` asserts its
    /// result fits in a `u64`, and `quantity x price / 1e9` crosses that at
    /// 2_000_000_001 raw base units priced at `MAX_PRICE` — one unit above the
    /// control below. Computing the conversion before the bid/ask branch let such
    /// an ask brick its own owner's locked-funds view, on a number the ask arm
    /// discarded. Nothing upstream bounds it: `validate_inputs` checks no
    /// quantity, and `MAX_PRICE` is an accepted price.
    /// The control: one raw unit below the threshold, which read correctly even
    /// before the fix. It is here so a later change that moves the threshold
    /// instead of removing it cannot pass by making both cases abort.
    #[test]
    fun test_locked_balance_ask_below_the_quote_overflow_threshold() {
        check_max_price_ask_locks_base_only(2_000_000_000);
    }

    #[test]
    fun test_locked_balance_ask_past_the_quote_overflow_threshold() {
        check_max_price_ask_locks_base_only(2_000_000_001);
    }

    fun check_max_price_ask_locks_base_only(quantity: u64) {
        let mut test = begin(utils::owner());
        let registry_id = pool_tests::setup_test(utils::owner(), &mut test);
        pool_tests::set_time(0, &mut test);

        let starting_balance = 10000 * constants::float_scaling();
        let owner_trading_account_id = trading_account_tests::create_acct_and_share_with_funds(
            utils::owner(),
            starting_balance,
            &mut test,
        );
        let _pool1_reference_id = pool_tests::setup_reference_pool<SUI, CRED>(
            utils::owner(),
            registry_id,
            owner_trading_account_id,
            constants::cred_multiplier(),
            &mut test,
        );
        let pool1_id = pool_tests::setup_pool_with_default_fees<SUI, USDC>(
            utils::owner(),
            registry_id,
            &mut test,
        );
        let alice_trading_account_id = trading_account_tests::create_acct_and_share_with_funds(
            utils::alice(),
            starting_balance,
            &mut test,
        );

        pool_tests::place_limit_order<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            constants::max_price(),
            quantity,
            false,
            constants::max_u64(),
            &mut test,
        );

        let mut expected = utils::expected_balances_all(0);
        utils::add_sui(&mut expected, quantity);
        utils::check_locked_balance<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            &expected,
            &mut test,
        );

        end(test);
    }

    /// An order records its maker fee rate at placement: after the admin changes
    /// rates and the epoch advances, a resting order's locked balance still
    /// reflects the rate it was placed under, while a new order locks at the
    /// freshly promoted rate.
    #[test]
    fun test_locked_balance_uses_snapshotted_maker_rate() {
        let mut test = begin(utils::owner());
        let registry_id = pool_tests::setup_test(utils::owner(), &mut test);
        pool_tests::set_time(0, &mut test);

        let starting_balance = 10000 * constants::float_scaling();
        let owner_trading_account_id = trading_account_tests::create_acct_and_share_with_funds(
            utils::owner(),
            starting_balance,
            &mut test,
        );
        let _pool1_reference_id = pool_tests::setup_reference_pool<SUI, CRED>(
            utils::owner(),
            registry_id,
            owner_trading_account_id,
            constants::cred_multiplier(),
            &mut test,
        );
        let pool1_id = pool_tests::setup_pool_with_default_fees<SUI, USDC>(
            utils::owner(),
            registry_id,
            &mut test,
        );
        let alice_trading_account_id = trading_account_tests::create_acct_and_share_with_funds(
            utils::alice(),
            starting_balance,
            &mut test,
        );

        let price = 2 * constants::float_scaling();
        let quantity = 3 * constants::float_scaling();
        let quote = math::mul(price, quantity);
        // Default maker rate at placement: 0.9% = 90 bps
        let fee_at_default_rate = math::mul(quote, pool_test_utils::default_maker_fee());

        pool_tests::place_limit_order<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );

        let (_, quote_locked, _) = utils::locked_balance<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            &mut test,
        );
        assert!(quote_locked == quote + fee_at_default_rate, 0);

        // Admin lowers the rates for the next epoch: taker 1%, maker 0.5%. The
        // pool was born into the standard USDC class, so restaging that class on
        // the shared policy is what re-prices it.
        pool_test_utils::set_next_epoch_fee_for_testing<USDC>(
            10_000_000,
            5_000_000,
            2000,
            &mut test,
        );
        test.next_epoch(utils::owner());

        // The resting order still reports its snapshotted 0.9% rate.
        let (_, quote_locked, _) = utils::locked_balance<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            &mut test,
        );
        assert!(quote_locked == quote + fee_at_default_rate, 1);

        // A new order placed in the new epoch locks at the promoted 0.5% rate.
        let fee_at_new_rate = quote * 50 / 10000;
        pool_tests::place_limit_order<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            true,
            constants::max_u64(),
            &mut test,
        );

        let (_, quote_locked, _) = utils::locked_balance<SUI, USDC>(
            utils::alice(),
            pool1_id,
            alice_trading_account_id,
            &mut test,
        );
        assert!(quote_locked == 2 * quote + fee_at_default_rate + fee_at_new_rate, 2);

        end(test);
    }
}
