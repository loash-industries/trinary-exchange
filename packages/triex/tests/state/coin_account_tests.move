#[test_only]
module triex::coin_account_tests {
    use std::unit_test::assert_eq;
    use sui::object::id_from_address;
    use triex::{balances, account as coin_account, fill as coin_fill, constants};

    #[test]
    /// Total volume sums taker volume and live maker fills.
    fun total_volume_sums_taker_and_maker() {
        let mut account = coin_account::empty();
        account.add_order(1);
        account.add_taker_volume(300);
        account.process_maker_fill(
            &coin_fill::new(
                1,
                1_000_000_000,
                id_from_address(@0xA),
                false,
                true,
                200,
                200,
                200,
                false,
                0,
                0,
                0,
            ),
        );

        assert_eq!(account.total_volume(), 500);
        assert!(account.open_orders().is_empty());
    }

    #[test]
    /// Owed balances accumulate and are drained by `settle`.
    fun add_owed_balances_accumulates_until_settled() {
        let mut account = coin_account::empty();
        account.add_owed_balances(balances::new(1, 2, 3));
        account.add_owed_balances(balances::new(10, 20, 30));
        account.add_settled_balances(balances::new(0, 5, 0));
        assert_eq!(account.owed_balances(), balances::new(11, 22, 33));

        let (settled, owed) = account.settle();
        assert_eq!(settled, balances::new(0, 5, 0));
        assert_eq!(owed, balances::new(11, 22, 33));
        assert_eq!(account.owed_balances(), balances::empty());
        assert_eq!(account.settled_balances(), balances::empty());
    }

    #[test]
    /// Entries a full window old are pruned on append; newer ones survive.
    fun pending_turnover_drops_window_aged_entries_on_append() {
        let window = constants::turnover_window_epochs();
        let mut account = coin_account::empty();
        account.add_pending_turnover(0, 100);
        account.add_pending_turnover(1, 40);
        account.add_pending_turnover(window + 1, 7);

        let entries = account.take_pending_turnover();
        assert_eq!(entries.length(), 1);
        assert_eq!(entries[0].entry_epoch(), window + 1);
        assert_eq!(entries[0].entry_amount(), 7);
    }

    #[test]
    /// Same-epoch credits merge; the window view excludes aged entries.
    fun pending_turnover_merges_and_windows() {
        let window = constants::turnover_window_epochs();
        let mut account = coin_account::empty();
        account.add_pending_turnover(2, 10);
        account.add_pending_turnover(2, 15);
        account.add_pending_turnover(3, 0);
        account.add_pending_turnover(4, 5);

        assert_eq!(account.pending_turnover_total(4), 30);
        assert_eq!(account.pending_turnover_total(window + 2), 5);
        assert_eq!(account.take_pending_turnover().length(), 2);
        assert_eq!(account.pending_turnover_total(4), 0);
    }
}
