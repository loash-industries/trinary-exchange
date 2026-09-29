#[test_only]
module triex::coin_order_info_coverage_tests {
    use std::unit_test::assert_eq;
    use sui::object::id_from_address;
    use triex::{
        balances,
        coin_fill as fill,
        coin_order as order,
        coin_order_info::{Self as order_info, OrderInfo},
        constants,
        quote_fee
    };

    const ALICE: address = @0xA;
    const PRICE: u64 = 2_000_000_000;
    const QUANTITY: u64 = 10_000_000_000;
    const MAKER_FEE_RATE: u64 = 18_000_000;
    const TAKER_FEE_RATE: u64 = 22_000_000;
    const RETENTION_BPS: u64 = 2_500;

    fun new_order_info(
        order_type: u8,
        self_matching_option: u8,
        expire_timestamp: u64,
        market_order: bool,
    ): OrderInfo {
        order_info::new(
            id_from_address(@0x2),
            id_from_address(ALICE),
            ALICE,
            order_type,
            self_matching_option,
            PRICE,
            QUANTITY,
            true,
            3,
            MAKER_FEE_RATE,
            RETENTION_BPS,
            expire_timestamp,
            market_order,
            0,
            constants::float_scaling(),
        )
    }

    fun limit_order_info(): OrderInfo {
        new_order_info(
            constants::no_restriction(),
            constants::self_matching_allowed(),
            constants::max_u64(),
            false,
        )
    }

    #[test]
    /// Placement fields read back as constructed.
    fun getters_reflect_construction() {
        let info = new_order_info(
            constants::immediate_or_cancel(),
            constants::self_matching_allowed(),
            constants::max_u64(),
            true,
        );
        assert_eq!(info.pool_id(), id_from_address(@0x2));
        assert_eq!(info.order_type(), constants::immediate_or_cancel());
        assert_eq!(info.epoch(), 3);
        assert_eq!(info.maker_fee_rate(), MAKER_FEE_RATE);
        assert_eq!(info.cancel_retention_bps(), RETENTION_BPS);
        assert!(info.market_order());
        assert!(!info.fill_limit_reached());
        assert!(!limit_order_info().market_order());
    }

    #[test]
    /// `set_paid_fees` drives the quote-denominated fee balances.
    fun set_paid_fees_updates_fee_balances() {
        let mut info = limit_order_info();
        assert_eq!(info.paid_fees_balances(), balances::new(0, 0, 0));
        info.set_paid_fees(1_234);
        assert_eq!(info.paid_fees(), 1_234);
        assert_eq!(info.paid_fees_balances(), balances::new(0, 1_234, 0));
    }

    #[test]
    /// A live fill priced through `calculate_partial_fill_balances` carries the taker fee.
    fun add_fill_then_taker_fee_is_charged() {
        let mut info = limit_order_info();
        let quote = 1_000_000_000;
        info.add_fill(
            fill::new(
                1,
                PRICE,
                id_from_address(@0xB),
                false,
                false,
                QUANTITY,
                quote / 2,
                quote,
                true,
                0,
                0,
                0,
            ),
        );
        assert_eq!(info.fills().length(), 1);

        info.calculate_partial_fill_balances(TAKER_FEE_RATE, 0);
        let expected = quote_fee::fee_from_scaled_rate(TAKER_FEE_RATE, quote);
        assert!(expected > 0);
        assert_eq!(info.paid_fees(), expected);
        assert_eq!(info.fills()[0].taker_fee(), expected);
    }

    #[test]
    /// A resting order that hit the fill limit stops matching without a status change.
    fun assert_execution_stops_at_fill_limit() {
        let mut info = limit_order_info();
        info.set_fill_limit_reached();
        assert!(info.fill_limit_reached());
        assert!(info.assert_execution());
        assert_eq!(info.status(), constants::live());
    }

    #[test]
    #[expected_failure(abort_code = triex::coin_order_info::EInvalidExpireTimestamp)]
    fun validate_rejects_past_expiry() {
        let info = new_order_info(
            constants::no_restriction(),
            constants::self_matching_allowed(),
            100,
            false,
        );
        info.validate_inputs(101);
    }

    #[test]
    #[expected_failure(abort_code = triex::coin_order_info::EInvalidOrderType)]
    fun validate_rejects_unknown_order_type() {
        let info = new_order_info(
            constants::max_restriction() + 1,
            constants::self_matching_allowed(),
            constants::max_u64(),
            false,
        );
        info.validate_inputs(0);
    }

    #[test]
    #[expected_failure(abort_code = triex::coin_order_info::EMarketOrderCannotBePostOnly)]
    fun validate_rejects_post_only_market_order() {
        let info = new_order_info(
            constants::post_only(),
            constants::self_matching_allowed(),
            constants::max_u64(),
            true,
        );
        info.validate_inputs(0);
    }

    #[test]
    #[expected_failure(abort_code = triex::coin_order_info::ESelfMatchingCancelTaker)]
    fun cancel_taker_aborts_on_self_match() {
        let mut info = new_order_info(
            constants::no_restriction(),
            constants::cancel_taker(),
            constants::max_u64(),
            false,
        );
        let mut maker = order::new(
            7,
            id_from_address(ALICE),
            PRICE,
            false,
            QUANTITY,
            0,
            0,
            0,
            0,
            constants::live(),
            constants::max_u64(),
        );
        info.match_maker(&mut maker, 0);
    }

    #[test]
    /// With no taker fee, a live fill is apportioned nothing.
    fun zero_taker_fee_charges_nothing() {
        let mut info = limit_order_info();
        info.add_fill(
            fill::new(
                1,
                PRICE,
                id_from_address(@0xB),
                false,
                false,
                QUANTITY,
                500_000_000,
                1_000_000_000,
                true,
                0,
                0,
                0,
            ),
        );

        info.calculate_partial_fill_balances(0, 0);
        assert_eq!(info.paid_fees(), 0);
        assert_eq!(info.fills()[0].taker_fee(), 0);
    }

    #[test]
    /// Cancel-taker only guards self-matches; a different maker still fills.
    fun cancel_taker_fills_other_account() {
        let mut info = new_order_info(
            constants::no_restriction(),
            constants::cancel_taker(),
            constants::max_u64(),
            false,
        );
        let mut maker = order::new(
            7,
            id_from_address(@0xB),
            PRICE,
            false,
            QUANTITY,
            0,
            0,
            0,
            0,
            constants::live(),
            constants::max_u64(),
        );
        assert!(info.match_maker(&mut maker, 0).continues());
        assert_eq!(info.executed_quantity(), QUANTITY);
        assert_eq!(info.status(), constants::filled());
        assert_eq!(info.fills().length(), 1);
    }
}
