#[test_only]
module triex::balances_tests {
    use std::unit_test::assert_eq;
    use triex::{balances, constants};

    #[test]
    fun empty_is_all_zero() {
        assert_eq!(balances::empty(), balances::new(0, 0, 0));
    }

    #[test]
    fun reset_returns_old_and_zeroes() {
        let mut b = balances::new(1, 2, 3);
        let old = b.reset();
        assert_eq!(old, balances::new(1, 2, 3));
        assert_eq!(b, balances::empty());
    }

    #[test]
    fun add_balances_sums_each_leg() {
        let mut b = balances::new(1, 2, 3);
        b.add_balances(balances::new(10, 20, 30));
        assert_eq!(b, balances::new(11, 22, 33));
    }

    #[test]
    fun add_base_and_quote_touch_one_leg() {
        let mut b = balances::new(1, 2, 3);
        b.add_base(5);
        assert_eq!(b, balances::new(6, 2, 3));
        b.add_quote(7);
        assert_eq!(b, balances::new(6, 9, 3));
        assert_eq!(b.base(), 6);
        assert_eq!(b.quote(), 9);
        assert_eq!(b.cred(), 3);
    }

    #[test]
    fun mul_scales_each_leg() {
        let scaling = constants::float_scaling();
        let mut b = balances::new(2 * scaling, 4 * scaling, 6 * scaling);
        // Factor 0.5 in float-scaled terms.
        b.mul(scaling / 2);
        assert_eq!(b, balances::new(scaling, 2 * scaling, 3 * scaling));
    }

    #[test]
    fun mul_by_one_is_identity() {
        let mut b = balances::new(7, 8, 9);
        b.mul(constants::float_scaling());
        assert_eq!(b, balances::new(7, 8, 9));
    }

    #[test]
    fun non_zero_value_prefers_base_then_quote_then_cred() {
        assert_eq!(balances::new(1, 2, 3).non_zero_value(), 1);
        assert_eq!(balances::new(0, 2, 3).non_zero_value(), 2);
        assert_eq!(balances::new(0, 0, 3).non_zero_value(), 3);
        assert_eq!(balances::empty().non_zero_value(), 0);
    }
}
