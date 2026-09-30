#[test_only]
/// The bid-side dry run (`coin_book::get_quantity_out`) has to price exactly the
/// fills `swap_exact_quote_for_base` then executes. Execution fills the planned
/// base greedily from the best maker, so a dry run that spends a leftover budget
/// on a worse maker — pricing that unit under its own floor — under-costs the
/// plan: the swap then needs more quote than it was given and aborts.
module triex::pool_swap_dry_run_parity_tests {
    use std::unit_test::destroy;
    use sui::{
        clock::Clock,
        coin::{Coin, mint_for_testing},
        sui::SUI,
        test_scenario::{Scenario, begin, end, return_shared}
    };
    use token::cred::CRED;
    use triex::{
        constants,
        fee_policy::FeePolicy,
        pool::Pool,
        pool_test_utils::{
            setup_test,
            setup_pool_with_default_fees_and_reference_pool,
            place_limit_order
        },
        trading_account_tests::{USDC, create_acct_and_share_with_funds}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const CAROL: address = @0xCCCC;

    fun setup(test: &mut Scenario): (ID, ID) {
        let registry_id = setup_test(OWNER, test);
        let alice = create_acct_and_share_with_funds(ALICE, 1_000_000_000_000, test);
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            alice,
            test,
        );
        (pool_id, alice)
    }

    fun ask(pool_id: ID, acct: ID, price: u64, quantity: u64, test: &mut Scenario) {
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            acct,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            false,
            constants::max_u64(),
            test,
        );
    }

    fun dry_run(pool_id: ID, quote_in: u64, test: &mut Scenario): (u64, u64) {
        test.next_tx(CAROL);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let policy = test.take_shared<FeePolicy>();
        let (base_out, quote_left) = pool.get_quantity_out(
            &policy,
            0,
            quote_in,
            &clock,
            test.ctx(),
        );
        return_shared(policy);
        return_shared(clock);
        return_shared(pool);
        (base_out, quote_left)
    }

    /// Swaps `quote_in` for base and asserts the result equals the dry run exactly.
    fun swap_matches_dry_run(pool_id: ID, quote_in: u64, test: &mut Scenario) {
        let (dry_base, dry_left) = dry_run(pool_id, quote_in, test);
        test.next_tx(CAROL);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let clock = test.take_shared<Clock>();
        let policy = test.take_shared<FeePolicy>();
        let (base, quote, cred): (Coin<SUI>, Coin<USDC>, Coin<CRED>) = pool.swap_exact_quantity(
            &policy,
            mint_for_testing<SUI>(0, test.ctx()),
            mint_for_testing<USDC>(quote_in, test.ctx()),
            mint_for_testing<CRED>(0, test.ctx()),
            0,
            &clock,
            test.ctx(),
        );
        assert!(base.value() == dry_base);
        assert!(quote.value() == dry_left);
        destroy(base);
        destroy(quote);
        destroy(cred);
        return_shared(policy);
        return_shared(clock);
        return_shared(pool);
    }

    /// Four ask levels with raw tails. With 93 quote the old dry run planned 57
    /// base at L1 plus one unit each at L2 and L3 (59 base, "2 left"); executing
    /// 59 base at L1 costs floor(93.04) = 93 plus a fee of 1, so the swap aborted.
    #[test]
    fun split_levels_swap_settles_the_dry_run_plan() {
        let mut test = begin(OWNER);
        let (pool_id, alice) = setup(&mut test);
        ask(pool_id, alice, 1_576_959_391, 334, &mut test);
        ask(pool_id, alice, 1_703_211_363, 23, &mut test);
        ask(pool_id, alice, 1_811_363_127, 141, &mut test);
        ask(pool_id, alice, 2_544_785_976, 37, &mut test);

        swap_matches_dry_run(pool_id, 93, &mut test);
        // Walk the rest of the book across partly consumed levels.
        let mut quote_in = 1;
        while (quote_in <= 40) {
            swap_matches_dry_run(pool_id, quote_in, &mut test);
            quote_in = quote_in + 1;
        };
        end(test);
    }

    /// One deep level with 1-unit asks behind it at the same price: the dust
    /// tail must not be priced for units the deep level would actually supply.
    #[test]
    fun dust_tail_behind_deep_level_does_not_break_the_swap() {
        let mut test = begin(OWNER);
        let (pool_id, alice) = setup(&mut test);
        ask(pool_id, alice, 1_900_000_000, 1_000_000, &mut test);
        ask(pool_id, alice, 1_900_000_000, 1, &mut test);
        ask(pool_id, alice, 1_900_000_000, 1, &mut test);

        // 93 quote used to plan 47 + 1 + 1 base: 49 base on the deep level costs
        // floor(93.1) = 93 plus a fee of 1, and the swap aborted.
        swap_matches_dry_run(pool_id, 93, &mut test);
        let mut quote_in = 1;
        while (quote_in <= 40) {
            swap_matches_dry_run(pool_id, quote_in, &mut test);
            quote_in = quote_in + 1;
        };
        end(test);
    }

    /// The reported leftover is what the swap returns, not one unit more.
    #[test]
    fun leftover_quote_matches_execution() {
        let mut test = begin(OWNER);
        let (pool_id, alice) = setup(&mut test);
        ask(pool_id, alice, 1_333_333_333, 1_000, &mut test);
        ask(pool_id, alice, 1_999_999_999, 3, &mut test);

        swap_matches_dry_run(pool_id, 18, &mut test);
        end(test);
    }
}
