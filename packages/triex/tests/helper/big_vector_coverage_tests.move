#[test_only]
module triex::big_vector_coverage_tests {
    use std::unit_test::assert_eq;
    use triex::big_vector::{Self as bv, BigVector};

    /// A prime, so `(i * step) % N` walks every key in `0..N` exactly once.
    const N: u64 = 101;

    #[test, expected_failure(abort_code = bv::ESliceTooSmall)]
    fun empty_rejects_small_slice() {
        bv::empty<u64>(1, 4, &mut tx_context::dummy()).destroy_empty();
    }

    #[test, expected_failure(abort_code = bv::ESliceTooBig)]
    fun empty_rejects_big_slice() {
        bv::empty<u64>(256 * 1024 + 1, 4, &mut tx_context::dummy()).destroy_empty();
    }

    #[test, expected_failure(abort_code = bv::EFanOutTooSmall)]
    fun empty_rejects_small_fan_out() {
        bv::empty<u64>(2, 3, &mut tx_context::dummy()).destroy_empty();
    }

    #[test, expected_failure(abort_code = bv::EFanOutTooBig)]
    fun empty_rejects_big_fan_out() {
        bv::empty<u64>(2, 4097, &mut tx_context::dummy()).destroy_empty();
    }

    #[test]
    /// The size bounds themselves are accepted.
    fun empty_accepts_bounds() {
        bv::empty<u64>(2, 4, &mut tx_context::dummy()).destroy_empty();
        bv::empty<u64>(256 * 1024, 4096, &mut tx_context::dummy()).destroy_empty();
    }

    #[test, expected_failure(abort_code = bv::ENotFound)]
    /// A key past the end of its leaf is not found.
    fun borrow_past_last_key_aborts() {
        let v = filled(vector[10, 20, 30, 40, 50]);
        v.borrow(60);
        v.drop();
    }

    #[test, expected_failure(abort_code = bv::ENotFound)]
    /// A key falling between two stored keys is not found.
    fun borrow_gap_key_aborts() {
        let v = filled(vector[10, 20, 30, 40, 50]);
        v.borrow(45);
        v.drop();
    }

    #[test, expected_failure(abort_code = bv::ENotFound)]
    fun remove_past_last_key_aborts() {
        let mut v = filled(vector[10, 20, 30, 40, 50]);
        v.remove(60);
        v.drop();
    }

    #[test, expected_failure(abort_code = bv::ENotFound)]
    fun remove_gap_key_aborts() {
        let mut v = filled(vector[10, 20, 30, 40, 50]);
        v.remove(45);
        v.drop();
    }

    #[test]
    /// Range lookups on an empty vector return the null slice.
    fun lookups_on_empty_vector_are_null() {
        let v = bv::empty<u64>(2, 4, &mut tx_context::dummy());
        let (sr, ix) = v.slice_following(5);
        assert!(sr.is_null());
        assert_eq!(ix, 0);
        let (sr, ix) = v.slice_before(5);
        assert!(sr.is_null());
        assert_eq!(ix, 0);
        v.destroy_empty();
    }

    #[test]
    /// `slice_before` walks back across leaf boundaries and stops at the front.
    fun slice_before_crosses_leaves() {
        let v = filled(vector[10, 20, 30, 40, 50]);

        let (sr, _) = v.slice_before(10);
        assert!(sr.is_null());

        // Every stored key but the first has a predecessor one step behind it.
        let keys = vector[10u128, 20, 30, 40, 50];
        let mut i = 1;
        while (i < keys.length()) {
            let (sr, ix) = v.slice_before(keys[i]);
            assert!(!sr.is_null());
            let slice = v.borrow_slice(sr);
            assert_eq!(slice.key(ix), keys[i - 1]);
            assert!(ix < slice.length());
            i = i + 1;
        };

        v.drop();
    }

    #[test]
    /// Slice lengths across the leaf chain sum to the vector length.
    fun slice_lengths_sum_to_length() {
        let v = filled(vector[10, 20, 30, 40, 50, 60, 70]);
        let (mut sr, _) = v.min_slice();
        let mut total = 0;
        while (!sr.is_null()) {
            let slice = v.borrow_slice(sr);
            assert!(slice.length() <= 2);
            total = total + slice.length();
            sr = slice.next();
        };
        assert_eq!(total, v.length());
        v.drop();
    }

    #[test]
    /// Descending inserts split interior nodes on their left half.
    fun descending_inserts_stay_sorted() {
        let mut v = bv::empty<u64>(2, 4, &mut tx_context::dummy());
        let mut i = N;
        while (i > 0) {
            i = i - 1;
            v.insert(i as u128, i);
        };
        assert!(v.depth() >= 3);
        assert_contents!(&v, |_| true);

        // Drain from the front, forcing left-edge fix-ups at every level.
        let mut k = 0;
        while (k < N) {
            assert_eq!(v.remove(k as u128), k);
            k = k + 1;
            if (k % 10 == 0) assert_contents!(&v, |x| x >= k);
        };
        assert!(v.is_empty());
        v.destroy_empty();
    }

    #[test]
    /// Ascending inserts, draining from the back.
    fun ascending_inserts_drain_from_back() {
        let mut v = bv::empty<u64>(2, 4, &mut tx_context::dummy());
        let mut i = 0;
        while (i < N) {
            v.insert(i as u128, i);
            i = i + 1;
        };
        assert_contents!(&v, |_| true);

        while (i > 0) {
            i = i - 1;
            assert_eq!(v.remove(i as u128), i);
            if (i % 10 == 0) assert_contents!(&v, |x| x < i);
        };
        v.destroy_empty();
    }

    #[test]
    /// Scattered inserts and removals keep every surviving key reachable.
    fun scattered_inserts_and_removals() {
        scatter(37, 53);
        scatter(53, 29);
        scatter(11, 73);
        scatter(89, 17);
    }

    fun scatter(insert_step: u64, remove_step: u64) {
        let mut v = bv::empty<u64>(2, 4, &mut tx_context::dummy());
        let mut i = 0;
        while (i < N) {
            let key = (i * insert_step) % N;
            v.insert(key as u128, key);
            i = i + 1;
        };
        assert_eq!(v.length(), N);
        assert_contents!(&v, |_| true);

        let mut removed = vector::tabulate!(N, |_| false);
        let mut i = 0;
        while (i < N) {
            let key = (i * remove_step) % N;
            assert_eq!(v.remove(key as u128), key);
            *(&mut removed[key]) = true;
            i = i + 1;
            assert_eq!(v.length(), N - i);
            if (i % 7 == 0) assert_contents!(&v, |x| !removed[x]);
        };
        v.destroy_empty();
    }

    /// Leaves, read in order, hold exactly the keys in `0..N` that `keep`
    /// accepts, each stored against its own value, and every one borrows back.
    macro fun assert_contents($v: &BigVector<u64>, $keep: |u64| -> bool) {
        let v = $v;
        let mut expected = vector[];
        let mut k = 0;
        while (k < N) {
            if ($keep(k)) expected.push_back(k);
            k = k + 1;
        };
        let mut actual = vector[];
        v.inorder_values().do!(|leaf| actual.append(leaf));
        assert_eq!(actual, expected);
        assert_eq!(v.length(), expected.length());
        expected.do!(|k| assert_eq!(*v.borrow(k as u128), k));
    }

    fun filled(keys: vector<u128>): BigVector<u64> {
        let mut v = bv::empty(2, 4, &mut tx_context::dummy());
        keys.do!(|k| v.insert(k, k as u64));
        v
    }
}
