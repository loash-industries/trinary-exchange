#[test_only]
module triex::coin_fill_coverage_tests {
    use std::unit_test::assert_eq;
    use sui::object::id_from_address;
    use triex::{balances, coin_fill::{Self as fill, Fill}, quote_fee};

    const MAKER_FEE_RATE: u64 = 18_000_000;
    const RETENTION_BPS: u64 = 2_500;
    const QUOTE: u64 = 1_000_000_000;
    const BASE: u64 = 500_000_000;

    fun new_fill(expired: bool, taker_is_bid: bool): Fill {
        fill::new(
            9,
            2_000_000_000,
            id_from_address(@0xA),
            expired,
            false,
            BASE * 2,
            BASE,
            QUOTE,
            taker_is_bid,
            7,
            MAKER_FEE_RATE,
            RETENTION_BPS,
        )
    }

    #[test]
    /// The placement snapshot carried onto a fill reads back unchanged.
    fun snapshot_getters() {
        let fill = new_fill(false, true);
        assert_eq!(fill.maker_epoch(), 7);
        assert_eq!(fill.maker_fee_rate(), MAKER_FEE_RATE);
        assert_eq!(fill.cancel_retention_bps(), RETENTION_BPS);
        assert_eq!(fill.maker_fee(), 0);
        assert_eq!(fill.taker_fee(), 0);
    }

    #[test]
    /// A live fill charges the full escrow and releases nothing back.
    fun live_fill_charges_escrow() {
        let fill = new_fill(false, false);
        let escrowed = quote_fee::fee_from_scaled_rate(MAKER_FEE_RATE, QUOTE);
        assert!(escrowed > 0);
        assert_eq!(fill.maker_fee_escrowed(), escrowed);
        assert_eq!(fill.maker_fee_charged(), escrowed);
        assert_eq!(fill.maker_fee_refunded(), 0);
        assert_eq!(fill.maker_fee_retained(), 0);
    }

    #[test]
    /// An expired bid maker is charged nothing and its escrow splits on the retention.
    fun expired_bid_maker_splits_escrow() {
        let fill = new_fill(true, false);
        let escrowed = quote_fee::fee_from_scaled_rate(MAKER_FEE_RATE, QUOTE);
        let (refund, retained) = quote_fee::split_released_fee(escrowed, RETENTION_BPS);
        assert!(retained > 0);
        assert_eq!(fill.maker_fee_charged(), 0);
        assert_eq!(fill.maker_fee_refunded(), refund);
        assert_eq!(fill.maker_fee_retained(), retained);
        assert_eq!(refund + retained, escrowed);
        assert_eq!(fill.get_settled_maker_quantities(), balances::new(0, QUOTE + refund, 0));
    }

    #[test]
    /// An expired ask maker locked no escrow, so nothing is refunded or retained.
    fun expired_ask_maker_releases_nothing() {
        let fill = new_fill(true, true);
        assert_eq!(fill.maker_fee_charged(), 0);
        assert_eq!(fill.maker_fee_refunded(), 0);
        assert_eq!(fill.maker_fee_retained(), 0);
        assert_eq!(fill.get_settled_maker_quantities(), balances::new(BASE, 0, 0));
    }
}
