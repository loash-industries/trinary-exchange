/// Shared utility functions.
///
/// The order-id codec here serves the **coin** pool stack only
/// (`triex::coin_book`), which keys its `BigVector` order storage by an encoded
/// `u128`. Multicoin pools (`triex::book`) use opaque `u64` serials and never
/// touch these functions. `pop_until` / `pop_n` back `triex::big_vector`.
module triex::utils {

    /// Pop elements from the back of `v` until its length equals `n`,
    /// returning the elements that were popped in the order they
    /// appeared in `v`.
    public(package) fun pop_until<T>(v: &mut vector<T>, n: u64): vector<T> {
        let mut res = vector[];
        while (v.length() > n) {
            res.push_back(v.pop_back());
        };

        res.reverse();
        res
    }

    /// Pop `n` elements from the back of `v`, returning the elements
    /// that were popped in the order they appeared in `v`.
    ///
    /// Aborts if `v` has fewer than `n` elements.
    public(package) fun pop_n<T>(v: &mut vector<T>, n: u64): vector<T> {
        let mut res = vector[];
        n.do!(|_| res.push_back(v.pop_back()));
        res.reverse();
        res
    }

    /// Encode a coin-pool order id.
    ///
    /// first bit is 0 for bid, 1 for ask
    /// next 63 bits are price (assertion for price is done in order function)
    /// last 64 bits are the per-side sequence number
    ///
    /// Key order is what gives the book price-time priority, so the sequence
    /// counters run in opposite directions per side — see
    /// `coin_book::get_order_id`.
    public(package) fun encode_order_id(is_bid: bool, price: u64, order_id: u64): u128 {
        if (is_bid) {
            ((price as u128) << 64) + (order_id as u128)
        } else {
            (1u128 << 127) + ((price as u128) << 64) + (order_id as u128)
        }
    }

    /// Decode order_id into (is_bid, price, order_id)
    public(package) fun decode_order_id(encoded_order_id: u128): (bool, u64, u64) {
        let is_bid = (encoded_order_id >> 127) == 0;
        let price = (encoded_order_id >> 64) as u64;
        let price = price & ((1u64 << 63) - 1);
        let order_id = (encoded_order_id & ((1u128 << 64) - 1)) as u64;

        (is_bid, price, order_id)
    }

    #[test]
    fun test_encode_decode_order_id() {
        let is_bid = true;
        let price = 2371538230592318123;
        let order_id = 9211238512301581235;
        let encoded_order_id = encode_order_id(is_bid, price, order_id);
        let (decoded_is_bid, decoded_price, decoded_order_id) = decode_order_id(
            encoded_order_id,
        );
        assert!(decoded_is_bid == is_bid, 0);
        assert!(decoded_price == price, 0);
        assert!(decoded_order_id == order_id, 0);

        let is_bid = false;
        let price = 1;
        let order_id = 1;
        let encoded_order_id = encode_order_id(is_bid, price, order_id);
        let (decoded_is_bid, decoded_price, decoded_order_id) = decode_order_id(
            encoded_order_id,
        );
        assert!(decoded_is_bid == is_bid, 0);
        assert!(decoded_price == price, 0);
        assert!(decoded_order_id == order_id, 0);

        let is_bid = true;
        let price = ((1u128 << 63) - 1) as u64;
        let order_id = ((1u128 << 64) - 1) as u64;
        let encoded_order_id = encode_order_id(is_bid, price, order_id);
        let (decoded_is_bid, decoded_price, decoded_order_id) = decode_order_id(
            encoded_order_id,
        );
        assert!(decoded_is_bid == is_bid, 0);
        assert!(decoded_price == price, 0);
        assert!(decoded_order_id == order_id, 0);

        let is_bid = false;
        let price = 0;
        let order_id = 0;
        let encoded_order_id = encode_order_id(is_bid, price, order_id);
        let (decoded_is_bid, decoded_price, decoded_order_id) = decode_order_id(
            encoded_order_id,
        );
        assert!(decoded_is_bid == is_bid, 0);
        assert!(decoded_price == price, 0);
        assert!(decoded_order_id == order_id, 0);
    }

    #[test]
    /// `MAX_PRICE` is `2^63 - 1`, exactly the widest value bits 64..126 hold, so
    /// a pool-legal price always round-trips. Encoding is not defined above it.
    fun test_encode_max_price_boundary() {
        let max_price = triex::constants::max_price();
        let encoded = encode_order_id(false, max_price, 7);
        let (is_bid, price, seq) = decode_order_id(encoded);
        assert!(!is_bid, 0);
        assert!(price == max_price, 0);
        assert!(seq == 7, 0);
    }

    #[test]
    /// Bid keys must order so that, at one price, the order placed first sorts
    /// *higher* — the bid side is walked from `max_slice` backwards, so the
    /// oldest order has to be reached first. The descending bid counter is what
    /// produces that.
    fun test_bid_key_order_is_time_priority() {
        let first = encode_order_id(true, 1000, 18446744073709551615);
        let second = encode_order_id(true, 1000, 18446744073709551614);
        assert!(first > second, 0);

        // Asks are walked from `min_slice` forwards, so the oldest must sort
        // lower; the ascending ask counter produces that.
        let first_ask = encode_order_id(false, 1000, 1);
        let second_ask = encode_order_id(false, 1000, 2);
        assert!(first_ask < second_ask, 0);
    }

    #[test]
    /// Every ask key sorts above every bid key, which is why one codec can key
    /// two independent trees without collision.
    fun test_side_bit_partitions_keyspace() {
        let highest_bid = encode_order_id(true, triex::constants::max_price(), 18446744073709551615);
        let lowest_ask = encode_order_id(false, 0, 0);
        assert!(highest_bid < lowest_ask, 0);
    }
}
