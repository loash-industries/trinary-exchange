#[test_only]
/// The multicoin bid-side dry run (`book::get_quantity_out`) has to report
/// exactly what `swap_exact_quote_for_base` returns. Execution fills the planned
/// base greedily from the best maker, so the dry run must neither price a
/// leftover unit at a worse maker nor stop a unit short of what the budget buys.
module triex::multicoin_pool_swap_dry_run_parity_tests {
    use multicoin::multicoin::{Self, Collection, CollectionCap};
    use std::unit_test;
    use sui::{
        clock::Clock,
        coin::mint_for_testing,
        test_scenario::{Scenario, begin, end, return_shared}
    };
    use token::cred::CRED;
    use triex::{
        constants,
        fee_policy::FeePolicy,
        integration_multicoin_test_utils as mc_utils,
        multicoin_pool::MultiCoinPool,
        trading_account::TradingAccount,
        trading_account_tests::USDC
    };

    const OWNER: address = @0x1;
    const BOB: address = @0xB;
    const CAROL: address = @0xC;
    const ASSET_GOLD: u64 = 1;

    /// Returns (pool_id, bob_ta, cap). Bob holds gold to sell.
    fun setup(test: &mut Scenario): (ID, ID, CollectionCap) {
        let (registry_id, collection_id, cap) = mc_utils::setup_registry_with_multicoin(test);
        let pool_id = mc_utils::setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            ASSET_GOLD,
            test,
        );
        let bob_ta = mc_utils::create_trading_account_with_funds(BOB, 1_000_000_000, 0, test);

        test.next_tx(OWNER);
        let mut collection = test.take_shared<Collection>();
        let gold = multicoin::mint_and_keep(
            &cap,
            &mut collection,
            ASSET_GOLD,
            1_000_000,
            test.ctx(),
        );
        return_shared(collection);
        transfer::public_transfer(gold, BOB);

        test.next_tx(BOB);
        let mut bob = test.take_shared_by_id<TradingAccount>(bob_ta);
        let gold = test.take_from_sender<multicoin::Balance>();
        bob.deposit_multicoin(gold, test.ctx());
        return_shared(bob);

        (pool_id, bob_ta, cap)
    }

    fun ask(pool_id: ID, ta_id: ID, price: u64, quantity: u64, test: &mut Scenario) {
        test.next_tx(BOB);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let mut ta = test.take_shared_by_id<TradingAccount>(ta_id);
        let proof = ta.generate_proof_as_owner(test.ctx());
        pool.place_limit_order(
            &policy,
            &mut ta,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            quantity,
            false,
            constants::max_u64(),
            &clock,
            test.ctx(),
        );
        return_shared(ta);
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);
    }

    /// Swaps `quote_in` for base and asserts the result equals the dry run exactly.
    /// Returns the base bought.
    fun swap_matches_dry_run(pool_id: ID, quote_in: u64, test: &mut Scenario): u64 {
        test.next_tx(CAROL);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let clock = test.take_shared<Clock>();
        let (dry_base, dry_left) = pool.get_quantity_out(&policy, 0, quote_in, &clock, test.ctx());
        let (base_out, quote_out, cred_out) = pool.swap_exact_quote_for_base(
            &policy,
            mint_for_testing<USDC>(quote_in, test.ctx()),
            mint_for_testing<CRED>(0, test.ctx()),
            0,
            &clock,
            test.ctx(),
        );
        let bought = base_out.value();
        assert!(bought == dry_base);
        assert!(quote_out.value() == dry_left);
        transfer::public_transfer(base_out, CAROL);
        transfer::public_transfer(quote_out, CAROL);
        transfer::public_transfer(cred_out, CAROL);
        return_shared(clock);
        return_shared(policy);
        return_shared(pool);
        bought
    }

    /// Two asks at price 3 (16 then 100 items), taker fee 2.2%, 49 quote. The
    /// fee-reserving estimate affords 15 items on the first ask, but 16 items
    /// settle for 48 + floor(1.056) = 49. The old dry run bought the 16th item on
    /// the second ask under its own floor and reported 1 quote left over, while
    /// the swap returned 0.
    #[test]
    fun same_price_makers_report_exact_leftover() {
        let mut test = begin(OWNER);
        let (pool_id, bob_ta, cap) = setup(&mut test);
        ask(pool_id, bob_ta, 3, 16, &mut test);
        ask(pool_id, bob_ta, 3, 100, &mut test);
        ask(pool_id, bob_ta, 7, 50, &mut test);

        assert!(swap_matches_dry_run(pool_id, 49, &mut test) == 16);
        let mut quote_in = 1;
        while (quote_in <= 60) {
            swap_matches_dry_run(pool_id, quote_in, &mut test);
            quote_in = quote_in + 1;
        };
        unit_test::destroy(cap);
        end(test);
    }
}
