#[test_only]
module triex::integration_test_utils {
    use sui::{clock::Clock, sui::SUI, test_scenario::{Scenario, return_shared}};
    use token::cred::{Self as cred, ProtectedTreasury};
    use triex::{
        balances::Balances,
        constants,
        math,
        pool::{Self as pool, Pool},
        pool_tests,
        trading_account::{Self as trading_account, TradingAccount},
        trading_account_tests::{SPAM, USDC}
    };

    public struct ExpectedBalances has drop {
        sui: u64,
        usdc: u64,
        spam: u64,
        cred: u64,
        usdt: u64,
    }

    public fun expected_balances(
        sui: u64,
        usdc: u64,
        spam: u64,
        cred: u64,
        usdt: u64,
    ): ExpectedBalances {
        ExpectedBalances { sui, usdc, spam, cred, usdt }
    }

    public fun expected_balances_all(amount: u64): ExpectedBalances {
        expected_balances(amount, amount, amount, amount, amount)
    }

    public fun add_sui(balances: &mut ExpectedBalances, amount: u64) {
        balances.sui = balances.sui + amount;
    }

    public fun sub_sui(balances: &mut ExpectedBalances, amount: u64) {
        balances.sui = balances.sui - amount;
    }

    public fun add_usdc(balances: &mut ExpectedBalances, amount: u64) {
        balances.usdc = balances.usdc + amount;
    }

    public fun sub_usdc(balances: &mut ExpectedBalances, amount: u64) {
        balances.usdc = balances.usdc - amount;
    }

    public fun add_spam(balances: &mut ExpectedBalances, amount: u64) {
        balances.spam = balances.spam + amount;
    }

    public fun sub_spam(balances: &mut ExpectedBalances, amount: u64) {
        balances.spam = balances.spam - amount;
    }

    public fun add_cred(balances: &mut ExpectedBalances, amount: u64) {
        balances.cred = balances.cred + amount;
    }

    public fun sub_cred(balances: &mut ExpectedBalances, amount: u64) {
        balances.cred = balances.cred - amount;
    }

    public fun set_cred(balances: &mut ExpectedBalances, amount: u64) {
        balances.cred = amount;
    }

    public fun add_usdt(balances: &mut ExpectedBalances, amount: u64) {
        balances.usdt = balances.usdt + amount;
    }

    public fun sub_usdt(balances: &mut ExpectedBalances, amount: u64) {
        balances.usdt = balances.usdt - amount;
    }

    // === Fee model the pools actually run ===
    // The `master_*` suites used to track fees with `constants::maybe_apply_fee`
    // — a flat 2% on bids, 0% on asks — which has not matched the live schedule
    // since the genesis ladder landed, and ignored cancel retention entirely.
    // Expectations built on it could not be asserted, so `check_balance` printed
    // instead of checking and every balance in these suites went unverified.
    //
    // These restate the arithmetic rather than calling `quote_fee`. Delegating
    // would make the expectations move with the code under test: a mutant that
    // refunds the whole escrow on cancel would shift the "expected" figure by the
    // same amount and the assertion would still pass. An oracle has to be an
    // independent statement of the answer, so the rates come from the schedule
    // the harness seeds and the maths is spelled out here.

    /// `floor(quote_quantity * rate / FLOAT_SCALING)` — the fee arithmetic,
    /// restated.
    fun fee_at_rate(rate_scaled: u64, quote_quantity: u64): u64 {
        (
            ((quote_quantity as u128) * (rate_scaled as u128)) /
        (constants::float_scaling() as u128),
        ) as u64
    }

    /// Quote a bid maker locks as principal for `quantity` at `price`.
    public fun maker_principal(price: u64, quantity: u64): u64 {
        math::mul(price, quantity)
    }

    /// Quote fee a bid maker escrows at placement, at the coin-pool maker rate.
    /// Asks escrow nothing.
    public fun maker_escrow(price: u64, quantity: u64): u64 {
        fee_at_rate(pool_tests::default_maker_fee(), maker_principal(price, quantity))
    }

    /// Escrow returned to the maker by a cancel, modify-down or expiry. The
    /// refund floors, so rounding dust stays with the protocol.
    public fun refunded_on_cancel(escrow: u64): u64 {
        let kept = pool_tests::default_cancel_retention_bps();
        // 10_000 bps = 100%, the denominator `FeePolicy` expresses retention in.
        (((escrow as u128) * ((10_000 - kept) as u128)) / 10_000) as u64
    }

    /// The share of released escrow the protocol keeps.
    public fun retained_on_cancel(escrow: u64): u64 {
        escrow - refunded_on_cancel(escrow)
    }

    /// Taker fee on a quote leg, at the coin-pool entry rung.
    public fun taker_fee_on(quote_quantity: u64): u64 {
        fee_at_rate(pool_tests::default_taker_fee(), quote_quantity)
    }

    /// Maker fee on a quote leg, at the coin-pool entry rung.
    public fun maker_fee_on(quote_quantity: u64): u64 {
        fee_at_rate(pool_tests::default_maker_fee(), quote_quantity)
    }

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;
    const BOB: address = @0xBBBB;

    public fun owner(): address { OWNER }

    public fun alice(): address { ALICE }

    public fun bob(): address { BOB }

    public fun authorize_trader(
        sender: address,
        trading_account_id: ID,
        trader: address,
        test: &mut Scenario,
    ): ID {
        test.next_tx(sender);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            let trade_cap = trading_account.mint_trade_cap(test.ctx());
            let trade_cap_id = object::id(&trade_cap);
            transfer::public_transfer(trade_cap, trader);
            return_shared(trading_account);

            trade_cap_id
        }
    }

    public fun remove_trader(
        sender: address,
        trading_account_id: ID,
        trade_cap_id: ID,
        test: &mut Scenario,
    ) {
        test.next_tx(sender);
        {
            let mut trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            trading_account.revoke_trade_cap(&trade_cap_id, test.ctx());
            return_shared(trading_account);
        }
    }

    public fun check_mid_price<BaseAsset, QuoteAsset>(
        pool_id: ID,
        expected_mid_price: u64,
        test: &mut Scenario,
    ) {
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
            let clock = test.take_shared<Clock>();
            let mid_price = pool::mid_price(&pool, &clock);
            assert!(mid_price == expected_mid_price, 0);
            return_shared(pool);
            return_shared(clock);
        }
    }

    public fun execute_cross_trading<BaseAsset, QuoteAsset>(
        pool_id: ID,
        trading_account_id_1: ID,
        trading_account_id_2: ID,
        order_type: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire_timestamp: u64,
        test: &mut Scenario,
    ) {
        pool_tests::place_limit_order<BaseAsset, QuoteAsset>(
            ALICE,
            pool_id,
            trading_account_id_1,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            expire_timestamp,
            test,
        );
        pool_tests::place_limit_order<BaseAsset, QuoteAsset>(
            BOB,
            pool_id,
            trading_account_id_2,
            order_type,
            constants::self_matching_allowed(),
            price,
            2 * quantity,
            !is_bid,
            expire_timestamp,
            test,
        );
        pool_tests::place_limit_order<BaseAsset, QuoteAsset>(
            ALICE,
            pool_id,
            trading_account_id_1,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            expire_timestamp,
            test,
        );
        withdraw_settled_amounts<BaseAsset, QuoteAsset>(
            BOB,
            pool_id,
            trading_account_id_2,
            test,
        );
    }

    public fun check_vault_balances<BaseAsset, QuoteAsset>(
        pool_id: ID,
        expected_balances: &Balances,
        test: &mut Scenario,
    ) {
        test.next_tx(OWNER);
        {
            let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
            let (vault_base, vault_quote, vault_cred) = pool::vault_balances<BaseAsset, QuoteAsset>(
                &pool,
            );
            std::debug::print(&std::string::utf8(b"--- Vault Balance Check ---"));
            std::debug::print(&std::string::utf8(b"Base:"));
            std::debug::print(&vault_base);
            std::debug::print(&expected_balances.base());
            std::debug::print(&std::string::utf8(b"Quote:"));
            std::debug::print(&vault_quote);
            std::debug::print(&expected_balances.quote());
            std::debug::print(&std::string::utf8(b"Cred:"));
            std::debug::print(&vault_cred);
            std::debug::print(&expected_balances.cred());
            assert!(vault_base == expected_balances.base(), 0);
            assert!(vault_quote == expected_balances.quote(), 0);
            assert!(vault_cred == expected_balances.cred(), 0);

            return_shared(pool);
        }
    }

    public fun withdraw_settled_amounts<BaseAsset, QuoteAsset>(
        sender: address,
        pool_id: ID,
        trading_account_id: ID,
        test: &mut Scenario,
    ) {
        test.next_tx(sender);
        {
            let mut my_trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            let mut pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
            let trade_proof = my_trading_account.generate_proof_as_owner(test.ctx());
            pool::withdraw_settled_amounts<BaseAsset, QuoteAsset>(
                &mut pool,
                &mut my_trading_account,
                &trade_proof,
            );
            return_shared(my_trading_account);
            return_shared(pool);
        }
    }

    public fun check_balance(
        trading_account_id: ID,
        expected_balances: &ExpectedBalances,
        test: &mut Scenario,
    ) {
        test.next_tx(OWNER);
        {
            let my_trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            let sui = trading_account::balance<SUI>(&my_trading_account);
            let usdc = trading_account::balance<USDC>(&my_trading_account);
            let spam = trading_account::balance<SPAM>(&my_trading_account);

            if (sui != expected_balances.sui) {
                std::debug::print(&std::string::utf8(b"SUI actual / expected:"));
                std::debug::print(&sui);
                std::debug::print(&expected_balances.sui);
            };
            if (usdc != expected_balances.usdc) {
                std::debug::print(&std::string::utf8(b"USDC actual / expected:"));
                std::debug::print(&usdc);
                std::debug::print(&expected_balances.usdc);
            };
            if (spam != expected_balances.spam) {
                std::debug::print(&std::string::utf8(b"SPAM actual / expected:"));
                std::debug::print(&spam);
                std::debug::print(&expected_balances.spam);
            };
            assert!(sui == expected_balances.sui, 0);
            assert!(usdc == expected_balances.usdc, 1);
            assert!(spam == expected_balances.spam, 2);

            return_shared(my_trading_account);
        }
    }

    public fun check_locked_balance<BaseAsset, QuoteAsset>(
        sender: address,
        pool_id: ID,
        trading_account_id: ID,
        expected_balances: &ExpectedBalances,
        test: &mut Scenario,
    ) {
        let (base, quote, cred) = locked_balance<BaseAsset, QuoteAsset>(
            sender,
            pool_id,
            trading_account_id,
            test,
        );
        assert!(base == expected_balances.sui, 0);
        // Quote fees are locked alongside quote principal, so the quote side is
        // part of what this checks — leaving it unasserted made every
        // quote-denominated expectation dead weight.
        assert!(quote == expected_balances.usdc, 1);
        assert!(cred == expected_balances.cred, 2);
    }

    public fun get_level2_range<BaseAsset, QuoteAsset>(
        sender: address,
        pool_id: ID,
        price_low: u64,
        price_high: u64,
        is_bid: bool,
        test: &mut Scenario,
    ): (vector<u64>, vector<u64>) {
        test.next_tx(sender);
        {
            let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
            let clock = test.take_shared<Clock>();
            let (prices, quantities) = pool.get_level2_range<BaseAsset, QuoteAsset>(
                price_low,
                price_high,
                is_bid,
                &clock,
            );
            return_shared(pool);
            return_shared(clock);

            (prices, quantities)
        }
    }

    public fun get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(
        sender: address,
        pool_id: ID,
        ticks: u64,
        test: &mut Scenario,
    ): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) {
        test.next_tx(sender);
        {
            let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
            let clock = test.take_shared<Clock>();
            let (
                bid_prices,
                bid_quantities,
                ask_prices,
                ask_quantities,
            ) = pool.get_level2_ticks_from_mid<BaseAsset, QuoteAsset>(ticks, &clock);
            return_shared(pool);
            return_shared(clock);

            (bid_prices, bid_quantities, ask_prices, ask_quantities)
        }
    }

    public fun locked_balance<BaseAsset, QuoteAsset>(
        sender: address,
        pool_id: ID,
        trading_account_id: ID,
        test: &mut Scenario,
    ): (u64, u64, u64) {
        test.next_tx(sender);
        {
            let pool = test.take_shared_by_id<Pool<BaseAsset, QuoteAsset>>(pool_id);
            let my_trading_account = test.take_shared_by_id<TradingAccount>(
                trading_account_id,
            );
            let (base, quote, cred) = pool::locked_balance<BaseAsset, QuoteAsset>(
                &pool,
                &my_trading_account,
            );
            return_shared(pool);
            return_shared(my_trading_account);

            (base, quote, cred)
        }
    }
}
