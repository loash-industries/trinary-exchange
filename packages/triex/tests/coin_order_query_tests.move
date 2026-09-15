#[test_only]
module triex::coin_order_query_tests {
    use std::unit_test::destroy;
    use sui::{sui::SUI, test_scenario::{begin, end, return_shared}};
    use token::cred::CRED;
    use triex::{
        coin_order_query::iter_orders,
        constants,
        pool::Pool,
        pool_tests::{
            setup_test,
            setup_pool_with_default_fees_and_reference_pool,
            place_limit_order,
            cancel_order
        },
        trading_account_tests::{
            USDC,
            create_acct_and_share_with_funds as create_acct_and_share_with_funds
        },
        utils
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;

    /// The encoded id the `n`th bid placed in a fresh pool receives, 1-indexed.
    /// The bid sequence counter descends from `START_BID_ORDER_ID` so that, at one
    /// price, an earlier order sorts higher — the bid side is walked downward, so
    /// the oldest must be reached first. `price` is the order's own price, which
    /// the key embeds.
    fun bid_id(price: u64, n: u64): u128 {
        utils::encode_order_id(true, price, constants::start_bid_order_id() - n)
    }

    /// The encoded id the `n`th ask placed in a fresh pool receives, 1-indexed.
    /// The ask counter ascends, and the ask side is walked upward, so again the
    /// oldest order at a price is reached first.
    fun ask_id(price: u64, n: u64): u128 {
        utils::encode_order_id(false, price, constants::start_ask_order_id() + n)
    }

    #[test]
    fun test_place_orders_ok() {
        let mut test = begin(OWNER);
        let registry_id = setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );
        let mut iter = 1u64;
        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let mut expire_timestamp = constants::max_u64();
        let is_bid = true;

        while (iter <= 10) {
            place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                order_type,
                constants::self_matching_allowed(),
                price,
                quantity,
                is_bid,
                expire_timestamp,
                &mut test,
            );
            iter = iter + 1;
        };

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let orders = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::none(),
            100,
            true,
        );
        assert!(orders.orders().length() == 10);
        assert!(orders.has_next_page() == false);
        let mut i = 1;
        while (i <= 10) {
            let order = &orders.orders()[i - 1];
            assert!(order.order_id() == bid_id(price, i));
            assert!(order.price() == price);
            assert!(order.quantity() == quantity);
            assert!(order.is_bid() == is_bid);
            assert!(order.expire_timestamp() == expire_timestamp);
            i = i + 1;
        };
        return_shared(pool);

        let ask_price = 3 * constants::float_scaling();
        let ask_is_bid = false;
        while (iter <= 20) {
            place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                order_type,
                constants::self_matching_allowed(),
                ask_price,
                quantity,
                ask_is_bid,
                expire_timestamp,
                &mut test,
            );
            iter = iter + 1;
        };

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let orders = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::none(),
            100,
            false,
        );
        assert!(orders.orders().length() == 10);
        assert!(orders.has_next_page() == false);
        return_shared(pool);

        expire_timestamp = 100000000;
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            price,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let orders = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::some(100000001),
            100,
            true,
        );
        assert!(orders.orders().length() == 10);

        let orders = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::none(),
            5,
            true,
        );
        assert!(orders.orders().length() == 5);
        assert!(orders.has_next_page() == true);

        destroy(pool);
        end(test);
    }

    #[test]
    fun test_find_start_position_anchor_behavior() {
        let mut test = begin(OWNER);
        let registry_id = setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );

        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let is_bid = true;

        let mut i = 1u64;
        while (i <= 10) {
            place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                order_type,
                constants::self_matching_allowed(),
                price,
                quantity,
                is_bid,
                expire_timestamp,
                &mut test,
            );
            i = i + 1;
        };

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        // Exact anchor hit: start before anchor (so anchor isn't repeated).
        // In this setup, `iter_orders` returns bids in FIFO order: [1, 2, ..., 10].
        // Anchoring at 1 should return [2, 3, ..., 10].
        let page = iter_orders(
            &pool,
            option::some(bid_id(price, 1)),
            option::none(),
            option::none(),
            100,
            true,
        );
        assert!(page.orders().length() == 9);
        assert!(page.has_next_page() == false);
        assert!(page.orders()[0].order_id() == bid_id(price, 2));
        assert!(page.orders()[8].order_id() == bid_id(price, 10));

        // Anchor below the whole bid key range. Seeking is positional, so what makes
        // this page empty is that no live key sorts past `999` — not that `999` names
        // no live order. An id that is merely stale but in range resolves to its
        // neighbour and keeps paging; see
        // `test_stale_in_range_anchor_resumes_from_its_neighbour` below.
        //
        // The property being pinned here is that the vector implementation's fallback
        // is gone: no anchor re-serves page one.
        let page = iter_orders(
            &pool,
            option::some(999),
            option::none(),
            option::none(),
            100,
            true,
        );
        assert!(page.orders().length() == 0);
        assert!(page.has_next_page() == false);

        // Exact anchor hit on the last (worst-priced) order: nothing follows it.
        let page = iter_orders(
            &pool,
            option::some(bid_id(price, 10)),
            option::none(),
            option::none(),
            100,
            true,
        );
        assert!(page.orders().length() == 0);
        assert!(page.has_next_page() == false);

        destroy(pool);
        end(test);
    }

    #[test]
    fun test_iter_orders_limit_zero() {
        let mut test = begin(OWNER);
        let registry_id = setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );

        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();

        let mut i = 1u64;
        while (i <= 3) {
            place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                order_type,
                constants::self_matching_allowed(),
                price,
                quantity,
                true,
                expire_timestamp,
                &mut test,
            );
            i = i + 1;
        };

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        let page = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::none(),
            0,
            true,
        );
        assert!(page.orders().length() == 0);
        assert!(page.has_next_page() == false);

        destroy(pool);
        end(test);
    }

    #[test]
    fun test_iter_orders_end_order_id_stop_and_pagination() {
        let mut test = begin(OWNER);
        let registry_id = setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );

        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();

        let mut i = 1u64;
        while (i <= 10) {
            place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                order_type,
                constants::self_matching_allowed(),
                price,
                quantity,
                true,
                expire_timestamp,
                &mut test,
            );
            i = i + 1;
        };

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        // Hard stop: `end_order_id` is not included in the page.
        let page = iter_orders(
            &pool,
            option::none(),
            option::some(bid_id(price, 5)),
            option::none(),
            100,
            true,
        );
        assert!(page.orders().length() == 4);
        assert!(page.has_next_page() == false);
        assert!(page.orders()[0].order_id() == bid_id(price, 1));
        assert!(page.orders()[3].order_id() == bid_id(price, 4));

        // If the limit is hit before `end_order_id`, we still paginate.
        let page = iter_orders(
            &pool,
            option::none(),
            option::some(bid_id(price, 5)),
            option::none(),
            2,
            true,
        );
        assert!(page.orders().length() == 2);
        assert!(page.has_next_page() == true);
        assert!(page.orders()[0].order_id() == bid_id(price, 1));
        assert!(page.orders()[1].order_id() == bid_id(price, 2));

        destroy(pool);
        end(test);
    }

    #[test]
    fun test_iter_orders_min_expire_timestamp_filtering() {
        let mut test = begin(OWNER);
        let registry_id = setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );

        let order_type = constants::no_restriction();
        let price = 2 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();

        let low_expire_timestamp = constants::max_u64() - 1000;
        let high_expire_timestamp = constants::max_u64();
        let min_expire_timestamp = constants::max_u64() - 500;

        let mut i = 1u64;
        while (i <= 10) {
            let expire_timestamp = if (i <= 5) low_expire_timestamp else high_expire_timestamp;
            place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                order_type,
                constants::self_matching_allowed(),
                price,
                quantity,
                true,
                expire_timestamp,
                &mut test,
            );
            i = i + 1;
        };

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        // Only include orders with expire_timestamp >= 200.
        let page = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::some(min_expire_timestamp),
            100,
            true,
        );
        assert!(page.orders().length() == 5);
        assert!(page.has_next_page() == false);
        assert!(page.orders()[0].order_id() == bid_id(price, 6));
        assert!(page.orders()[4].order_id() == bid_id(price, 10));

        // Filtering can skip earlier orders but still paginate when limit is hit.
        let page = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::some(min_expire_timestamp),
            2,
            true,
        );
        assert!(page.orders().length() == 2);
        assert!(page.has_next_page() == true);
        assert!(page.orders()[0].order_id() == bid_id(price, 6));
        assert!(page.orders()[1].order_id() == bid_id(price, 7));

        destroy(pool);
        end(test);
    }

    #[test]
    fun test_iter_orders_asks_anchor_and_end_stop() {
        let mut test = begin(OWNER);
        let registry_id = setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );

        let order_type = constants::no_restriction();
        let price = 3 * constants::float_scaling();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();

        let mut i = 1u64;
        while (i <= 10) {
            place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                trading_account_id_alice,
                order_type,
                constants::self_matching_allowed(),
                price,
                quantity,
                false,
                expire_timestamp,
                &mut test,
            );
            i = i + 1;
        };

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        // The anchor is exclusive on the ask side too, even though the underlying
        // `slice_following` seek is inclusive — `iter_orders` steps over an exact
        // hit so paging with the previous page's last id never repeats it.
        let page = iter_orders(
            &pool,
            option::some(ask_id(price, 1)),
            option::none(),
            option::none(),
            100,
            false,
        );
        assert!(page.orders().length() == 9);
        assert!(page.has_next_page() == false);
        assert!(page.orders()[0].order_id() == ask_id(price, 2));
        assert!(page.orders()[8].order_id() == ask_id(price, 10));

        let page = iter_orders(
            &pool,
            option::none(),
            option::some(ask_id(price, 5)),
            option::none(),
            100,
            false,
        );
        assert!(page.orders().length() == 4);
        assert!(page.has_next_page() == false);
        assert!(page.orders()[0].order_id() == ask_id(price, 1));
        assert!(page.orders()[3].order_id() == ask_id(price, 4));

        destroy(pool);
        end(test);
    }

    #[test]
    fun test_key_order_bids_price_time_priority() {
        let mut test = begin(OWNER);
        let registry_id = setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );

        let order_type = constants::no_restriction();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let is_bid = true;

        // Insert out-of-order by price: with keyed storage, sort position comes from
        // the encoded id rather than a search for an insertion index.
        // Sequence numbers are assigned in placement order: 1..4.
        let p2 = 2 * constants::float_scaling();
        let p1 = 1 * constants::float_scaling();
        let p3 = 3 * constants::float_scaling();

        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p2,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p1,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p3,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p2,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        // Best bid is highest price; within same price, FIFO (older first).
        let page = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::none(),
            100,
            true,
        );
        assert!(page.orders().length() == 4);
        assert!(page.has_next_page() == false);

        // Full expected sequence: best price first; FIFO within price.
        let expected_order_ids = vector[bid_id(p3, 3), bid_id(p2, 1), bid_id(p2, 4), bid_id(p1, 2)];
        let expected_prices = vector[p3, p2, p2, p1];
        let mut j = 0;
        while (j < 4) {
            assert!(page.orders()[j].order_id() == expected_order_ids[j]);
            assert!(page.orders()[j].price() == expected_prices[j]);
            j = j + 1;
        };

        destroy(pool);
        end(test);
    }

    #[test]
    fun test_key_order_asks_price_time_priority() {
        let mut test = begin(OWNER);
        let registry_id = setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );

        let order_type = constants::no_restriction();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let is_bid = false;

        // Insert out-of-order by price: with keyed storage, sort position comes from
        // the encoded id rather than a search for an insertion index.
        // Sequence numbers are assigned in placement order: 1..4.
        let p2 = 2 * constants::float_scaling();
        let p3 = 3 * constants::float_scaling();
        let p1 = 1 * constants::float_scaling();

        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p2,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p3,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p1,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p2,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        // Best ask is lowest price; within same price, FIFO (older first).
        let page = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::none(),
            100,
            false,
        );
        assert!(page.orders().length() == 4);
        assert!(page.has_next_page() == false);

        // Full expected sequence: best (lowest) price first; FIFO within price.
        let expected_order_ids = vector[ask_id(p1, 3), ask_id(p2, 1), ask_id(p2, 4), ask_id(p3, 2)];
        let expected_prices = vector[p1, p2, p2, p3];
        let mut j = 0;
        while (j < 4) {
            assert!(page.orders()[j].order_id() == expected_order_ids[j]);
            assert!(page.orders()[j].price() == expected_prices[j]);
            j = j + 1;
        };

        destroy(pool);
        end(test);
    }

    #[test]
    fun test_key_order_insert_at_end_new_best_price() {
        let mut test = begin(OWNER);
        let registry_id = setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );

        let order_type = constants::no_restriction();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let is_bid = true;

        let p2 = 2 * constants::float_scaling();
        let p3 = 3 * constants::float_scaling();
        let p4 = 4 * constants::float_scaling();

        // Place two orders, then place a new best price.
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p2,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p3,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p4,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        // The new best bid holds the highest key on the bid side, so it is the
        // first order the downward walk reaches.
        let page = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::none(),
            100,
            true,
        );
        assert!(page.orders().length() == 3);
        assert!(page.has_next_page() == false);

        let expected_order_ids = vector[bid_id(p4, 3), bid_id(p3, 2), bid_id(p2, 1)];
        let expected_prices = vector[p4, p3, p2];
        let mut j = 0;
        while (j < 3) {
            assert!(page.orders()[j].order_id() == expected_order_ids[j]);
            assert!(page.orders()[j].price() == expected_prices[j]);
            j = j + 1;
        };

        destroy(pool);
        end(test);
    }

    #[test]
    fun test_key_order_insert_at_start_worst_price() {
        let mut test = begin(OWNER);
        let registry_id = setup_test(OWNER, &mut test);
        let trading_account_id_alice = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            trading_account_id_alice,
            &mut test,
        );

        let order_type = constants::no_restriction();
        let quantity = 1 * constants::float_scaling();
        let expire_timestamp = constants::max_u64();
        let is_bid = true;

        let p2 = 2 * constants::float_scaling();
        let p3 = 3 * constants::float_scaling();
        let p1 = 1 * constants::float_scaling();

        // Place two orders, then place a new worst price.
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p2,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p3,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );
        place_limit_order<SUI, USDC>(
            ALICE,
            pool_id,
            trading_account_id_alice,
            order_type,
            constants::self_matching_allowed(),
            p1,
            quantity,
            is_bid,
            expire_timestamp,
            &mut test,
        );

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        // New worst bid should be at START of the bids vector, so it is returned last.
        let page = iter_orders(
            &pool,
            option::none(),
            option::none(),
            option::none(),
            100,
            true,
        );
        assert!(page.orders().length() == 3);
        assert!(page.has_next_page() == false);

        let expected_order_ids = vector[bid_id(p3, 2), bid_id(p2, 1), bid_id(p1, 3)];
        let expected_prices = vector[p3, p2, p1];
        let mut j = 0;
        while (j < 3) {
            assert!(page.orders()[j].order_id() == expected_order_ids[j]);
            assert!(page.orders()[j].price() == expected_prices[j]);
            j = j + 1;
        };

        destroy(pool);
        end(test);
    }

    #[test]
    /// A cursor that was valid when the caller paged and went stale before they
    /// resumed. Unlike anchor `999` above, this id sits strictly *between* live
    /// keys, so it isolates staleness from being out of range.
    ///
    /// Seeking is positional: the page resumes from the neighbour of where the
    /// dead order sat. It is not an empty page and it is not page one.
    fun test_stale_in_range_anchor_resumes_from_its_neighbour() {
        let mut test = begin(OWNER);
        let registry_id = setup_test(OWNER, &mut test);
        let acct = create_acct_and_share_with_funds(
            ALICE,
            1000000 * constants::float_scaling(),
            &mut test,
        );
        let pool_id = setup_pool_with_default_fees_and_reference_pool<SUI, USDC, SUI, CRED>(
            ALICE,
            registry_id,
            acct,
            &mut test,
        );

        let price = 2 * constants::float_scaling();
        let mut i = 1u64;
        while (i <= 10) {
            place_limit_order<SUI, USDC>(
                ALICE,
                pool_id,
                acct,
                constants::no_restriction(),
                constants::self_matching_allowed(),
                price,
                1 * constants::float_scaling(),
                true,
                constants::max_u64(),
                &mut test,
            );
            i = i + 1;
        };

        // Retire the 5th bid, leaving a hole in the middle of the key range.
        cancel_order<SUI, USDC>(ALICE, pool_id, acct, bid_id(price, 5), &mut test);

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);

        let page = iter_orders(
            &pool,
            option::some(bid_id(price, 5)),
            option::none(),
            option::none(),
            100,
            true,
        );

        // Bids 6..10 — the orders that follow the hole, not an empty page.
        assert!(page.orders().length() == 5);
        assert!(page.orders()[0].order_id() == bid_id(price, 6));
        assert!(page.orders()[4].order_id() == bid_id(price, 10));

        return_shared(pool);
        end(test);
    }
}
