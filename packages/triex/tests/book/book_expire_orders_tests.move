/// `book::expire_orders`, the book half of `clean_expired_orders` (TRIEX-159).
/// The pool tests rest only a few orders, which all sit in the hot buffer; these
/// rest enough to spill, so ids are retired from both stores.
#[test_only]
module triex::book_expire_orders_tests {
    use sui::test_scenario::begin;
    use triex::{book::{Self, Book, hot_capacity}, constants, order_info};

    const OWNER: address = @0x1;
    const EXPIRE: u64 = 100;

    fun qty(): u64 { 1_000_000 }

    fun price_at(level: u64): u64 { (level + 1) * 1_000 }

    fun rest(book: &mut Book, price: u64, is_bid: bool): u128 {
        let mut info = order_info::new(
            object::id_from_address(@0xB00C),
            object::id_from_address(@0xACC7),
            OWNER,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price,
            qty(),
            is_bid,
            0,
            0,
            0,
            EXPIRE,
            false,
            0,
            1,
        );
        book.create_order(&mut info, 0);
        assert!(info.order_inserted());

        info.order_id()
    }

    #[test]
    fun expires_from_both_stores_and_skips_the_rest() {
        let mut test = begin(OWNER);
        let mut book = book::empty_multicoin(test.ctx());

        // Improving prices: the oldest (worst) bids spill to the tree.
        let n = hot_capacity() + 4;
        let ids = vector::tabulate!(n, |i| rest(&mut book, price_at(i), true));
        let in_tree = ids[0];
        let in_hot = ids[n - 1];
        assert!(book.bids().contains(in_tree));
        assert!(book.hot_bids().any!(|o| o.order_id() == in_hot));
        let unknown = in_tree - 1;
        let batch = vector[in_tree, in_hot, in_tree, unknown];

        // On the expiry instant nothing has expired.
        assert!(book.expire_orders(&batch, EXPIRE).is_empty());
        assert!(book.side_length(true) == n);

        let fills = book.expire_orders(&batch, EXPIRE + 1);
        assert!(fills.length() == 2);
        assert!(fills[0].maker_order_id() == in_tree);
        assert!(fills[1].maker_order_id() == in_hot);
        fills.do_ref!(|fill| {
            assert!(fill.expired());
            assert!(fill.base_quantity() == qty());
            // A bid maker is retired as against an ask taker.
            assert!(!fill.taker_is_bid());
        });
        assert!(book.side_length(true) == n - 2);
        assert!(!book.bids().contains(in_tree));
        assert!(!book.hot_bids().any!(|o| o.order_id() == in_hot));

        book.drop_for_testing();
        test.end();
    }
}
