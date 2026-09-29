#[test_only]
module triex::state_coverage_tests {
    use std::unit_test::{assert_eq, destroy};
    use sui::{object::id_from_address, test_scenario::begin};
    use triex::{balances, constants, order_info_tests::create_order_info_base, state};

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;

    #[test]
    /// Withdrawing for an account the pool has never seen returns nothing.
    fun withdraw_settled_amounts_unknown_account_is_empty() {
        let mut test = begin(OWNER);
        let mut state = state::empty(test.ctx());

        let (settled, owed) = state.withdraw_settled_amounts(id_from_address(ALICE));
        assert_eq!(settled, balances::empty());
        assert_eq!(owed, balances::empty());

        destroy(state);
        test.end();
    }

    #[test, expected_failure(abort_code = state::EMaxOpenOrders)]
    /// Resting one order past the per-account cap aborts.
    fun process_create_rejects_order_past_open_order_cap() {
        let mut test = begin(OWNER);
        let mut state = state::empty(test.ctx());
        let epoch = test.ctx().epoch();

        let mut i = 0;
        while (i <= constants::max_open_orders()) {
            let mut info = create_order_info_base(ALICE, 1_000_000, 1_000_000_000, true, epoch);
            info.set_order_id((i + 1) as u128);
            state.process_create_for_testing(&mut info, 0, 0, test.ctx());
            i = i + 1;
        };

        abort
    }
}
