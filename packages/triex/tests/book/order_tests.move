#[test_only]
module triex::order_tests {
    use std::unit_test::assert_eq;
    use sui::{object::id_from_address, test_scenario::{next_tx, begin, end}};
    use triex::{balances, constants, order::{Self, Order}};

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;

    #[test]
    // Maker has a sell order of 15 at $10. Gets matched for 5.
    fun generate_fill_partial_fill_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 15 * constants::usdc_unit();
        let quantity = 10 * constants::sui_unit();
        let is_bid = false;
        let mut order = create_order_base(price, quantity, is_bid);

        let fill = order.generate_fill(
            0,
            5 * constants::sui_unit(),
            true,
            false,
            constants::float_scaling(),
        );
        assert!(!fill.expired(), 0);
        assert!(!fill.completed(), 0);
        assert!(fill.base_quantity() == 5 * constants::sui_unit(), 0);
        assert!(fill.taker_is_bid(), 0);
        assert!(fill.quote_quantity() == 75 * constants::usdc_unit(), 0); // 5 * $15 = $75
        assert_eq!(
            fill.get_settled_maker_quantities(),
            balances::new(0, 75 * constants::usdc_unit(), 0),
        );

        assert!(order.status() == constants::partially_filled(), 0);
        assert!(order.filled_quantity() == 5 * constants::sui_unit(), 0);

        test.end();
    }

    #[test]
    fun generate_fill_multiple_partial_fill_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 15 * constants::usdc_unit();
        let quantity = 12 * constants::sui_unit();
        let is_bid = false;
        let mut order = create_order_base(price, quantity, is_bid);

        let fill = order.generate_fill(
            0,
            5 * constants::sui_unit(),
            true,
            false,
            constants::float_scaling(),
        );
        assert!(!fill.expired(), 0);
        assert!(!fill.completed(), 0);
        assert!(fill.base_quantity() == 5 * constants::sui_unit(), 0);
        assert!(fill.taker_is_bid(), 0);
        assert!(fill.quote_quantity() == 75 * constants::usdc_unit(), 0); // 5 * $15 = $75
        assert_eq!(
            fill.get_settled_maker_quantities(),
            balances::new(0, 75 * constants::usdc_unit(), 0),
        );

        assert!(order.status() == constants::partially_filled(), 0);
        assert!(order.filled_quantity() == 5 * constants::sui_unit(), 0);

        let fill = order.generate_fill(
            0,
            15 * constants::sui_unit(),
            true,
            false,
            constants::float_scaling(),
        );
        assert!(!fill.expired(), 0);
        assert!(fill.completed(), 0);
        assert!(fill.base_quantity() == 7 * constants::sui_unit(), 0);
        assert!(fill.taker_is_bid(), 0);
        assert!(fill.quote_quantity() == 105 * constants::usdc_unit(), 0); // 7 * $15 = $105
        assert_eq!(
            fill.get_settled_maker_quantities(),
            balances::new(0, 105 * constants::usdc_unit(), 0),
        );

        assert!(order.status() == constants::filled(), 0);
        assert!(order.filled_quantity() == 12 * constants::sui_unit(), 0);

        test.end();
    }

    #[test]
    // Maker has a sell order of 0.1 at $111.11. Gets matched for 0.1.
    fun generate_fill_full_fill_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 111_110_000;
        let quantity = 1 * constants::sui_unit() / 10;
        let is_bid = false;
        let mut order = create_order_base(price, quantity, is_bid);

        let fill = order.generate_fill(
            0,
            1 * constants::sui_unit() / 10,
            true,
            false,
            constants::float_scaling(),
        );
        assert!(!fill.expired(), 0);
        assert!(fill.completed(), 0);
        assert!(fill.base_quantity() == 1 * constants::sui_unit() / 10, 0);
        assert!(fill.taker_is_bid(), 0);
        assert!(fill.quote_quantity() == 11_111_000, 0); // 0.1 * $111.11 = $11.111
        assert_eq!(fill.get_settled_maker_quantities(), balances::new(0, 11_111_000, 0));

        assert!(order.status() == constants::filled(), 0);
        assert!(order.filled_quantity() == 1 * constants::sui_unit() / 10, 0);

        test.end();
    }

    #[test]
    // Maker has a buy order of 1919 at $1.19. Gets matched for 0.01.
    fun generate_fill_partial_fill_ok_bid() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 1_190_000;
        let quantity = 1919 * constants::sui_unit();
        let is_bid = true;
        let mut order = create_order_base(price, quantity, is_bid);

        let fill = order.generate_fill(
            0,
            1 * constants::sui_unit() / 100,
            false,
            false,
            constants::float_scaling(),
        );
        assert!(!fill.expired(), 0);
        assert!(!fill.completed(), 0);
        assert!(fill.base_quantity() == 1 * constants::sui_unit() / 100, 0);
        assert!(!fill.taker_is_bid(), 0);
        assert!(fill.quote_quantity() == 11_900, 0); // 0.01 * $1.19 = $0.0119
        assert_eq!(
            fill.get_settled_maker_quantities(),
            balances::new(1 * constants::sui_unit() / 100, 0, 0),
        );

        assert!(order.status() == constants::partially_filled(), 0);
        assert!(order.filled_quantity() == 1 * constants::sui_unit() / 100, 0);

        test.end();
    }

    #[test]
    // Maker has a sell of 10 at $10 but taker is same as maker, self match option to expire.
    // Original base amount is returned to maker.
    fun generate_fill_self_match_expire_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 10 * constants::usdc_unit();
        let quantity = 10 * constants::sui_unit();
        let is_bid = false;
        let mut order = create_order_base(price, quantity, is_bid);

        let fill = order.generate_fill(
            0,
            10 * constants::sui_unit(),
            true,
            true,
            constants::float_scaling(),
        );
        assert!(fill.expired(), 0);
        assert!(!fill.completed(), 0);
        assert!(fill.base_quantity() == 10 * constants::sui_unit(), 0);
        assert!(fill.quote_quantity() == 100 * constants::usdc_unit(), 0);
        assert_eq!(
            fill.get_settled_maker_quantities(),
            balances::new(10 * constants::sui_unit(), 0, 0),
        );

        assert!(order.status() == constants::expired(), 0);
        assert!(order.filled_quantity() == 0, 0);

        test.end();
    }

    #[test]
    // Maker has a buy order of 10 at $10 but is expired.
    // Original quote amount is returned to maker.
    fun generate_fill_expired_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 10 * constants::usdc_unit();
        let quantity = 10 * constants::sui_unit();
        let is_bid = true;
        let order_id = 1;
        let trading_account_id = id_from_address(ALICE);
        let epoch = 1;
        let expire_timestamp = test.ctx().epoch_timestamp_ms();
        let mut order = create_order(
            price,
            quantity,
            is_bid,
            order_id,
            trading_account_id,
            epoch,
            expire_timestamp,
        );

        let fill = order.generate_fill(
            test.ctx().epoch_timestamp_ms() + 1,
            10 * constants::sui_unit(),
            false,
            false,
            constants::float_scaling(),
        );
        assert!(fill.expired(), 0);
        assert!(!fill.completed(), 0);
        assert!(fill.base_quantity() == 10 * constants::sui_unit(), 0);
        assert!(fill.quote_quantity() == 100 * constants::usdc_unit(), 0);
        assert_eq!(
            fill.get_settled_maker_quantities(),
            balances::new(0, 100 * constants::usdc_unit(), 0),
        );

        assert!(order.status() == constants::expired(), 0);
        assert!(order.filled_quantity() == 0, 0);

        test.end();
    }

    #[test]
    // Maker has a buy order of 10 at $10, half is filled, rest is expired.
    fun generate_fill_expired_partial_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 10 * constants::usdc_unit();
        let quantity = 10 * constants::sui_unit();
        let is_bid = true;
        let order_id = 1;
        let trading_account_id = id_from_address(ALICE);
        let epoch = 1;
        let expire_timestamp = test.ctx().epoch_timestamp_ms();
        let mut order = create_order(
            price,
            quantity,
            is_bid,
            order_id,
            trading_account_id,
            epoch,
            expire_timestamp,
        );

        let fill = order.generate_fill(
            test.ctx().epoch_timestamp_ms(),
            5 * constants::sui_unit(),
            false,
            false,
            constants::float_scaling(),
        );
        assert!(!fill.expired(), 0);
        assert!(!fill.completed(), 0);
        assert!(fill.base_quantity() == 5 * constants::sui_unit(), 0);
        assert!(fill.quote_quantity() == 50 * constants::usdc_unit(), 0); // 5 * $10 = $50
        assert_eq!(
            fill.get_settled_maker_quantities(),
            balances::new(5 * constants::sui_unit(), 0, 0),
        );

        assert!(order.status() == constants::partially_filled(), 0);
        assert!(order.filled_quantity() == 5 * constants::sui_unit(), 0);

        let fill = order.generate_fill(
            test.ctx().epoch_timestamp_ms() + 1,
            5 * constants::sui_unit(),
            false,
            false,
            constants::float_scaling(),
        );
        assert!(fill.expired(), 0);
        assert!(!fill.completed(), 0);
        assert!(fill.base_quantity() == 5 * constants::sui_unit(), 0);
        assert!(fill.quote_quantity() == 50 * constants::usdc_unit(), 0);
        assert_eq!(
            fill.get_settled_maker_quantities(),
            balances::new(0, 50 * constants::usdc_unit(), 0),
        );

        assert!(order.status() == constants::expired(), 0);
        assert!(order.filled_quantity() == 5 * constants::sui_unit(), 0);

        test.end();
    }

    #[test]
    // Start with quantity 10, modify it to 5, then fill 1, then modify it to 2.
    fun modify_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 10 * constants::usdc_unit();
        let quantity = 10 * constants::sui_unit();
        let is_bid = false;
        let mut order = create_order_base(price, quantity, is_bid);
        let ts = order.expire_timestamp();

        let new_quantity = 5 * constants::sui_unit();
        order.modify(new_quantity, ts);
        assert!(order.quantity() == 5 * constants::sui_unit(), 0);
        assert!(order.filled_quantity() == 0, 0);
        assert!(order.status() == constants::live(), 0);

        order.generate_fill(0, 1 * constants::sui_unit(), true, false, constants::float_scaling());
        assert!(order.quantity() == 5 * constants::sui_unit(), 0);
        assert!(order.filled_quantity() == 1 * constants::sui_unit(), 0);
        assert!(order.status() == constants::partially_filled(), 0);

        let new_quantity = 2 * constants::sui_unit();
        order.modify(new_quantity, ts);
        assert!(order.quantity() == 2 * constants::sui_unit(), 0);
        assert!(order.filled_quantity() == 1 * constants::sui_unit(), 0);
        assert!(order.status() == constants::partially_filled(), 0);

        order.generate_fill(0, 1 * constants::sui_unit(), true, false, constants::float_scaling());
        assert!(order.quantity() == 2 * constants::sui_unit(), 0);
        assert!(order.filled_quantity() == 2 * constants::sui_unit(), 0);
        assert!(order.status() == constants::filled(), 0);

        test.end();
    }

    #[test, expected_failure(abort_code = order::EInvalidNewQuantity)]
    // Start with quantity 10, reduce it by 1 10 times.
    fun modify_invalid_quantity_e() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 10 * constants::usdc_unit();
        let quantity = 10 * constants::sui_unit();
        let is_bid = false;
        let mut order = create_order_base(price, quantity, is_bid);
        let ts = order.expire_timestamp();

        let new_quantity = 9 * constants::sui_unit();
        order.modify(new_quantity, ts);
        assert!(order.quantity() == new_quantity, 0);
        let new_quantity = 8 * constants::sui_unit();
        order.modify(new_quantity, ts);
        assert!(order.quantity() == new_quantity, 0);
        let new_quantity = 7 * constants::sui_unit();
        order.modify(new_quantity, ts);
        assert!(order.quantity() == new_quantity, 0);
        let new_quantity = 6 * constants::sui_unit();
        order.modify(new_quantity, ts);
        assert!(order.quantity() == new_quantity, 0);
        let new_quantity = 5 * constants::sui_unit();
        order.modify(new_quantity, ts);
        assert!(order.quantity() == new_quantity, 0);
        let new_quantity = 4 * constants::sui_unit();
        order.modify(new_quantity, ts);
        assert!(order.quantity() == new_quantity, 0);
        let new_quantity = 3 * constants::sui_unit();
        order.modify(new_quantity, ts);
        assert!(order.quantity() == new_quantity, 0);
        let new_quantity = 2 * constants::sui_unit();
        order.modify(new_quantity, ts);
        assert!(order.quantity() == new_quantity, 0);
        let new_quantity = 1 * constants::sui_unit();
        order.modify(new_quantity, ts);
        assert!(order.quantity() == new_quantity, 0);
        let new_quantity = 0 * constants::sui_unit();
        order.modify(new_quantity, ts);

        abort (0)
    }

    #[test, expected_failure(abort_code = order::EInvalidNewQuantity)]
    fun modify_quantity_too_high_e() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 10 * constants::usdc_unit();
        let quantity = 10 * constants::sui_unit();
        let is_bid = false;
        let mut order = create_order_base(price, quantity, is_bid);
        let ts = order.expire_timestamp();

        let new_quantity = 10 * constants::sui_unit();
        order.modify(new_quantity, ts);

        abort (0)
    }

    #[test, expected_failure(abort_code = order::EOrderExpired)]
    fun modify_expired_e() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let price = 10 * constants::usdc_unit();
        let quantity = 10 * constants::sui_unit();
        let is_bid = true;
        let order_id = 1;
        let trading_account_id = id_from_address(ALICE);
        let epoch = 1;
        let expire_timestamp = test.ctx().epoch_timestamp_ms() + 1000;
        let mut order = create_order(
            price,
            quantity,
            is_bid,
            order_id,
            trading_account_id,
            epoch,
            expire_timestamp,
        );

        let new_quantity = 5 * constants::sui_unit();
        order.modify(new_quantity, expire_timestamp + 1);

        abort (0)
    }

    #[test_only]
    public fun create_order_base(price: u64, quantity: u64, is_bid: bool): Order {
        let order_id = 1;
        let trading_account_id = id_from_address(ALICE);
        let epoch = 1;
        let expire_timestamp = constants::max_u64();

        create_order(
            price,
            quantity,
            is_bid,
            order_id,
            trading_account_id,
            epoch,
            expire_timestamp,
        )
    }

    #[test_only]
    public fun create_order(
        price: u64,
        quantity: u64,
        is_bid: bool,
        order_id: u64,
        trading_account_id: ID,
        epoch: u64,
        expire_timestamp: u64,
    ): Order {
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

    #[test]
    // The maker rate snapshotted on the order rides into every Fill it generates,
    // for both partial and expiring fills — PR 2 charges ask-maker fill fees from
    // this value.
    fun generate_fill_propagates_maker_fee_rate_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let maker_fee_rate = 18_000_000; // 1.8%
        let mut order = order::new(
            1,
            id_from_address(ALICE),
            15 * constants::usdc_unit(),
            false,
            10 * constants::sui_unit(),
            0,
            1,
            maker_fee_rate,
            2000,
            constants::live(),
            constants::max_u64(),
        );

        let fill = order.generate_fill(
            0,
            5 * constants::sui_unit(),
            true,
            false,
            constants::float_scaling(),
        );
        assert_eq!(fill.maker_fee_rate(), maker_fee_rate);

        // An expiring fill carries the rate too
        let expired_fill = order.generate_fill(
            0,
            5 * constants::sui_unit(),
            true,
            true,
            constants::float_scaling(),
        );
        assert_eq!(expired_fill.maker_fee_rate(), maker_fee_rate);

        end(test);
    }

    // @todo: add a test for inserting order at same price to make sure same-prices are ordered for FIFO.

    // === Cancel refund with fee escrow ===
    // A bid maker's cancel returns the unfilled principal plus the refundable
    // share of the escrow held against it, at the rate and retention snapshotted
    // on the order.

    #[test_only]
    // A resting bid of 100 @ 2 (200 quote notional) at a 1.8% maker rate, so the
    // escrow is 3.6 and the default 20% retention splits it 2.88 / 0.72.
    fun bid_with_escrow(retention_bps: u64): Order {
        order::new(
            1,
            id_from_address(ALICE),
            2 * constants::float_scaling(),
            true,
            100 * constants::float_scaling(),
            0,
            1,
            18_000_000,
            retention_bps,
            constants::live(),
            constants::max_u64(),
        )
    }

    #[test]
    fun calculate_cancel_refund_includes_refundable_escrow() {
        let order = bid_with_escrow(2000);
        let principal = 200 * constants::float_scaling();
        let refund = 288 * constants::float_scaling() / 100;

        let (fee_refund, _retained) = order.released_fee_split(
            order.maker_fee_rate(),
            option::none(),
            constants::float_scaling(),
        );
        assert_eq!(
            order.calculate_cancel_refund(fee_refund, option::none(), constants::float_scaling()),
            balances::new(0, principal + refund, 0),
        );
    }

    #[test]
    fun calculate_cancel_refund_honors_snapshotted_retention() {
        // A zero-retention order refunds the whole escrow; a full-retention one
        // refunds none. Both read the rate off the order, not from the fee policy.
        let principal = 200 * constants::float_scaling();
        let escrow = 36 * constants::float_scaling() / 10;

        let free = bid_with_escrow(0);
        let (free_fee_refund, _free_retained) = free.released_fee_split(
            free.maker_fee_rate(),
            option::none(),
            constants::float_scaling(),
        );
        assert_eq!(
            free.calculate_cancel_refund(
                free_fee_refund,
                option::none(),
                constants::float_scaling(),
            ),
            balances::new(0, principal + escrow, 0),
        );

        let punitive = bid_with_escrow(10000);
        let (punitive_fee_refund, _punitive_retained) = punitive.released_fee_split(
            punitive.maker_fee_rate(),
            option::none(),
            constants::float_scaling(),
        );
        assert_eq!(
            punitive.calculate_cancel_refund(
                punitive_fee_refund,
                option::none(),
                constants::float_scaling(),
            ),
            balances::new(0, principal, 0),
        );
    }

    #[test]
    fun calculate_cancel_refund_ask_gets_no_fee_refund() {
        // Asks never lock escrow, so their cancel returns base only — a refund
        // here would pay out of another maker's locked fee.
        let order = order::new(
            1,
            id_from_address(ALICE),
            2 * constants::float_scaling(),
            false,
            100 * constants::float_scaling(),
            0,
            1,
            18_000_000,
            2000,
            constants::live(),
            constants::max_u64(),
        );

        let (refund, retained) = order.released_fee_split(
            order.maker_fee_rate(),
            option::none(),
            constants::float_scaling(),
        );
        assert_eq!(refund, 0);
        assert_eq!(retained, 0);
        assert_eq!(
            order.calculate_cancel_refund(refund, option::none(), constants::float_scaling()),
            balances::new(100 * constants::float_scaling(), 0, 0),
        );
    }

    #[test]
    fun released_fee_split_sums_to_released() {
        // The pool decrements `locked_maker_fees` by refund + retained, so any
        // gap between that sum and the released basis would strand escrow.
        let order = bid_with_escrow(2000);
        let basis = order.locked_fee_released(
            order.maker_fee_rate(),
            option::none(),
            constants::float_scaling(),
        );
        let (refund, retained) = order.released_fee_split(
            order.maker_fee_rate(),
            option::none(),
            constants::float_scaling(),
        );

        assert_eq!(basis, 36 * constants::float_scaling() / 10);
        assert_eq!(refund + retained, basis);
    }

    #[test]
    fun released_fee_split_prorates_on_modify_down() {
        // Cutting 100 to 40 releases the escrow on 60 (120 quote at 1.8% = 2.16),
        // split 1.728 / 0.432 — a modify-down is taxed like a cancel, so
        // modify-to-minimum-then-cancel dodges nothing.
        let order = bid_with_escrow(2000);
        let cancel_quantity = 60 * constants::float_scaling();
        let (refund, retained) = order.released_fee_split(
            order.maker_fee_rate(),
            option::some(cancel_quantity),
            constants::float_scaling(),
        );

        assert_eq!(refund, 1728 * constants::float_scaling() / 1000);
        assert_eq!(retained, 216 * constants::float_scaling() / 100 - refund);
    }
}
