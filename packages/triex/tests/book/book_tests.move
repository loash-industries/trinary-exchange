#[test_only]
module triex::book_tests {
    use sui::{object::id_from_address, test_scenario::{next_tx, begin, end}};
    use triex::{book::{Self, Book}, constants, math, order::{Self, Order}, order_info, quote_fee};

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;

    #[test]
    // Test find_order_index with empty orderbook
    fun find_order_index_empty_orderbook() {
        let mut test = begin(OWNER);
        test.next_tx(ALICE);

        let orderbook = vector[];
        let result = book::find_order_index(&orderbook, 1);
        assert!(result.is_none(), 0);

        test.end();
    }

    #[test]
    // Test find_order_index with single order - found
    fun find_order_index_single_order_found() {
        let mut test = begin(OWNER);
        test.next_tx(ALICE);

        let order_id = 42;
        let ord = create_test_order(100, 1000, true, order_id);
        let order_id = ord.order_id();
        let mut orderbook = vector[];
        orderbook.push_back(ord);
        let result = book::find_order_index(&orderbook, order_id);
        assert!(result.is_some(), 0);
        assert!(result.destroy_some() == 0, 0);

        test.end();
    }

    #[test]
    // Test find_order_index with single order - not found
    fun find_order_index_single_order_not_found() {
        let mut test = begin(OWNER);
        test.next_tx(ALICE);

        let order_id = 42;
        let order = create_test_order(100, 1000, true, order_id);
        let mut orderbook = vector[];
        orderbook.push_back(order);

        let result = book::find_order_index(&orderbook, 999);
        assert!(result.is_none(), 0);

        test.end();
    }

    #[test]
    // Test find_order_index with multiple orders - first order found
    fun find_order_index_multiple_orders_first_found() {
        let mut test = begin(OWNER);
        test.next_tx(ALICE);

        let mut orderbook = vector[];
        orderbook.push_back(create_test_order(100, 1000, true, 1));
        orderbook.push_back(create_test_order(101, 1000, true, 2));
        orderbook.push_back(create_test_order(102, 1000, true, 3));
        let book_order_id = orderbook[0].order_id();
        let result = book::find_order_index(&orderbook, book_order_id);
        assert!(result.is_some(), 0);
        assert!(result.destroy_some() == 0, 0);

        test.end();
    }

    #[test]
    // Test find_order_index with multiple orders - middle order found
    fun find_order_index_multiple_orders_middle_found() {
        let mut test = begin(OWNER);
        test.next_tx(ALICE);

        let mut orderbook = vector[];
        orderbook.push_back(create_test_order(100, 1000, true, 1));
        orderbook.push_back(create_test_order(101, 1000, true, 2));
        orderbook.push_back(create_test_order(102, 1000, true, 3));
        let book_order_id = orderbook[1].order_id();
        let result = book::find_order_index(&orderbook, book_order_id);
        assert!(result.is_some(), 0);
        assert!(result.destroy_some() == 1, 0);

        test.end();
    }

    #[test]
    // Test find_order_index with multiple orders - last order found
    fun find_order_index_multiple_orders_last_found() {
        let mut test = begin(OWNER);
        test.next_tx(ALICE);

        let mut orderbook = vector[];
        orderbook.push_back(create_test_order(100, 1000, true, 1));
        orderbook.push_back(create_test_order(101, 1000, true, 2));
        orderbook.push_back(create_test_order(102, 1000, true, 3));
        let book_order_id = orderbook[2].order_id();
        let result = book::find_order_index(&orderbook, book_order_id);
        assert!(result.is_some(), 0);
        assert!(result.destroy_some() == 2, 0);

        test.end();
    }

    #[test]
    // Test find_order_index with multiple orders - not found
    fun find_order_index_multiple_orders_not_found() {
        let mut test = begin(OWNER);
        test.next_tx(ALICE);

        let mut orderbook = vector[];
        orderbook.push_back(create_test_order(100, 1000, true, 1));
        orderbook.push_back(create_test_order(101, 1000, true, 2));
        orderbook.push_back(create_test_order(102, 1000, true, 3));

        let result = book::find_order_index(&orderbook, 999);
        assert!(result.is_none(), 0);

        test.end();
    }

    #[test]
    // Test find_order_index with duplicate order_ids - should find last occurrence (searches backwards)
    fun find_order_index_duplicate_order_ids() {
        let mut test = begin(OWNER);
        test.next_tx(ALICE);

        let mut orderbook = vector[];
        orderbook.push_back(create_test_order(100, 1000, true, 1));
        orderbook.push_back(create_test_order(101, 1000, true, 2));
        orderbook.push_back(create_test_order(102, 1000, true, 1)); // Duplicate order_id
        orderbook.push_back(create_test_order(103, 1000, true, 3));
        let book_order_id = orderbook[2].order_id();
        let result = book::find_order_index(&orderbook, book_order_id);
        assert!(result.is_some(), 0);
        // Should find the last occurrence (index 2) since it searches from the end backwards
        assert!(result.destroy_some() == 2, 0);

        test.end();
    }

    #[test]
    // Test find_order_index searches from end (backwards) - should find last occurrence when searching backwards
    fun find_order_index_searches_backwards() {
        let mut test = begin(OWNER);
        test.next_tx(ALICE);

        let mut orderbook = vector[];
        orderbook.push_back(create_test_order(100, 1000, true, 1));
        orderbook.push_back(create_test_order(101, 1000, true, 1)); // Same order_id
        orderbook.push_back(create_test_order(102, 1000, true, 1)); // Same order_id
        let book_order_id = orderbook[2].order_id();
        let result = book::find_order_index(&orderbook, book_order_id);
        assert!(result.is_some(), 0);
        // Since it searches from the end backwards, it should find the last occurrence (index 2)
        assert!(result.destroy_some() == 2, 0);

        test.end();
    }

    #[test_only]
    // Helper function to create a test order
    fun create_test_order(price: u64, quantity: u64, is_bid: bool, order_id: u64): Order {
        let trading_account_id = id_from_address(ALICE);
        let epoch = 1;
        let expire_timestamp = constants::max_u64();

        order::new(
            order_id,
            trading_account_id,
            price,
            is_bid,
            quantity,
            0,
            epoch,
            0,
            2000,
            constants::live(),
            expire_timestamp,
        )
    }

    // === Dry-run fee pricing ===
    // `get_quantity_out` is what every router, indexer and swap entry point
    // prices against, and what `swap_exact_quantity` sizes its order from. What
    // it reserves for the fee therefore has to be what settlement charges — no
    // more, or the input is never deployed, and no less, or the swap overdraws.

    #[test_only]
    fun rest(b: &mut Book, price: u64, qty: u64, is_bid: bool) {
        let mut oi = order_info::new(
            id_from_address(@0x1),
            id_from_address(@0xA1),
            ALICE,
            constants::post_only(),
            constants::self_matching_allowed(),
            price,
            qty,
            is_bid,
            0,
            9_000_000,
            2_000,
            constants::max_u64(),
            false,
            0,
            book::price_scaling(b),
        );
        b.create_order(&mut oi, 0);
        assert!(oi.order_inserted(), 0);
    }

    #[test]
    /// A bid dry run must reserve exactly the taker fee that settles, not a
    /// multiple of it.
    ///
    /// The reservation used to be sized at `FEE_PENALTY_MULTIPLIER * taker_rate`
    /// while `calculate_partial_fill_balances` charged the plain rate, so the
    /// difference — 0.25x the fee, i.e. 0.271% of the input at the 1.10% coin
    /// entry rung and 0.535% at the 2.20% multicoin one — was input the swap
    /// never deployed and nobody received. It also made the two sides of the
    /// same book quote asymmetrically, which a router reads as a half-spread
    /// that does not exist.
    fun bid_dry_run_reserves_exactly_the_fee_that_settles() {
        let mut test = begin(OWNER);
        let ctx = test.ctx();
        let mut b = book::empty(ctx);
        // One deep ask at human price 1.00 (price = 1e6 for a 6-decimal quote
        // against a 9-decimal base), so a single level absorbs the whole input.
        rest(&mut b, 1_000_000, 10_000_000_000_000, false);

        let taker_rate = 11_000_000; // 1.10%
        let input = 1_000_000_000; // 1_000 CRED at 6 decimals
        let (base_out, quote_left) = b.get_quantity_out(0, input, taker_rate, 0);

        // What settlement charges for the base this quote says it buys.
        let quote_spent = math::qty_to_quote(base_out, 1_000_000, book::price_scaling(&b));
        let fee = quote_fee::fee_from_scaled_rate(taker_rate, quote_spent);

        // Nothing is left undeployed beyond the input the level's own price
        // granularity cannot spend, which `quote_left` already accounts for.
        assert!(input - quote_spent - fee == quote_left, input - quote_spent - fee);
        // And that residue is sub-unit against the trade, not a fraction of a
        // percent of it: under the old multiplier this was 2_712_701.
        assert!(quote_left < 1_000, quote_left);

        sui::test_utils::destroy(b);
        test.end();
    }

    #[test]
    /// Buying base and selling it straight back at the same price must cost
    /// exactly two taker fees and nothing else.
    ///
    /// This is the asymmetry stated as a round trip. The multiplier applied to
    /// the bid leg only, so the two directions of the same book quoted a
    /// different fee for the same trade and a round trip leaked a third charge
    /// no one collected — a phantom half-spread on the bid side.
    fun a_round_trip_costs_exactly_two_taker_fees() {
        let mut test = begin(OWNER);
        let ctx = test.ctx();
        let mut b = book::empty(ctx);
        rest(&mut b, 1_000_000, 10_000_000_000_000, false);

        let taker_rate = 22_000_000; // 2.20%, where the old gap was widest
        let input = 1_000_000_000;
        let (base_out, quote_left) = b.get_quantity_out(0, input, taker_rate, 0);

        // Sell the base straight back into a bid at the same price.
        let mut b2 = book::empty(test.ctx());
        rest(&mut b2, 1_000_000, 10_000_000_000_000, true);
        let (base_left, quote_out) = b2.get_quantity_out(base_out, 0, taker_rate, 0);
        assert!(base_left == 0, 0);

        let leg = quote_fee::fee_from_scaled_rate(
            taker_rate,
            math::qty_to_quote(base_out, 1_000_000, book::price_scaling(&b)),
        );
        // Everything the round trip did not return is fee, and it is exactly two
        // of them. Under the multiplier the bid leg also held back 0.25x its fee
        // and never spent it, so this came up short by that much.
        assert!(quote_out + quote_left == input - 2 * leg, quote_out + quote_left);

        sui::test_utils::destroy(b);
        sui::test_utils::destroy(b2);
        test.end();
    }

    #[test_only]
    use fun triex::book::get_quantity_out as Book.get_quantity_out;
    #[test_only]
    use fun triex::book::create_order as Book.create_order;
}
