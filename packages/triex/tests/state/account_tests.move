// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::account_tests {
    use std::unit_test::assert_eq;
    use sui::{object::id_from_address, test_scenario::{next_tx, begin, end}};
    use triexbook::{account, balances, constants, fill};

    const OWNER: address = @0xF;
    const ALICE: address = @0xA;

    #[test]
    fun add_balances_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let mut account = account::empty(test.ctx());
        let (settled, owed) = account.settle();
        assert_eq!(settled, balances::new(0, 0, 0));
        assert_eq!(owed, balances::new(0, 0, 0));

        account.add_settled_balances(balances::new(1, 2, 3));
        account.add_owed_balances(balances::new(4, 5, 6));
        let (settled, owed) = account.settle();
        assert_eq!(settled, balances::new(1, 2, 3));
        assert_eq!(owed, balances::new(4, 5, 6));

        test.end();
    }

    #[test]
    fun process_maker_fill_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let mut account = account::empty(test.ctx());
        account.add_order(1);
        let fill = fill::new(
            1,
            1,
            id_from_address(@0xB),
            false,
            false,
            100,
            100,
            500,
            false,
            0,
            0,
            0,
        );
        account.process_maker_fill(&fill);
        let (settled, owed) = account.settle();
        assert_eq!(settled, balances::new(100, 0, 0));
        assert_eq!(owed, balances::new(0, 0, 0));
        assert!(account.total_volume() == 100, 0);
        assert!(account.open_orders().length() == 1, 0);
        assert!(account.open_orders().contains(&1), 0);

        account.add_order(2);
        let fill = fill::new(
            2,
            2,
            id_from_address(@0xC),
            false,
            true,
            100,
            100,
            500,
            true,
            0,
            0,
            0,
        );
        account.process_maker_fill(&fill);
        let (settled, owed) = account.settle();
        assert_eq!(settled, balances::new(0, 500, 0));
        assert_eq!(owed, balances::new(0, 0, 0));
        assert!(account.total_volume() == 200, 0);
        assert!(account.open_orders().length() == 1, 0);
        assert!(account.open_orders().contains(&1), 0);
        assert!(!account.open_orders().contains(&2), 0);

        account.add_order(3);
        let fill = fill::new(
            3,
            3,
            id_from_address(@0xC),
            true,
            false,
            100,
            100,
            500,
            true,
            0,
            0,
            0,
        );
        account.process_maker_fill(&fill);
        let (settled, owed) = account.settle();
        assert_eq!(settled, balances::new(100, 0, 0));
        assert_eq!(owed, balances::new(0, 0, 0));
        assert!(account.total_volume() == 200, 0);
        assert!(account.open_orders().length() == 1, 0);
        assert!(account.open_orders().contains(&1), 0);
        assert!(!account.open_orders().contains(&2), 0);
        assert!(!account.open_orders().contains(&3), 0);

        account.add_order(4);
        let fill = fill::new(
            4,
            4,
            id_from_address(@0xC),
            false,
            true,
            100,
            100,
            500,
            true,
            0,
            0,
            0,
        );
        account.process_maker_fill(&fill);
        let (settled, owed) = account.settle();
        assert_eq!(settled, balances::new(0, 500, 0));
        assert_eq!(owed, balances::new(0, 0, 0));
        assert!(account.total_volume() == 300, 0);
        assert!(account.open_orders().length() == 1, 0);
        assert!(account.open_orders().contains(&1), 0);
        assert!(!account.open_orders().contains(&2), 0);
        assert!(!account.open_orders().contains(&3), 0);
        assert!(!account.open_orders().contains(&4), 0);

        test.end();
    }

    // #feat:stake - DISABLED
    // #[test]
    // fun add_remove_stake_ok() {
    // let mut test = begin(OWNER);R);

    // test.next_tx(ALICE);
    // let mut account = account::empty(test.ctx());
    // let (before, after) = account.add_stake(100);
    // assert!(before == 0, 0);
    // assert!(after == 100, 0);
    // assert!(account.active_stake() == 0, 0);
    // assert!(account.inactive_stake() == 100, 0);

    // let (before, after) = account.add_stake(100);
    // assert!(before == 100, 0);
    // assert!(after == 200, 0);
    // assert!(account.active_stake() == 0, 0);
    // assert!(account.inactive_stake() == 200, 0);
    // let (settled, owed) = account.settle();
    // assert_eq!(settled, balances::new(0, 0, 0));
    // assert_eq!(owed, balances::new(0, 0, 200));

    // account.remove_stake();
    // assert!(account.active_stake() == 0, 0);
    // assert!(account.inactive_stake() == 0, 0);
    // let (settled, owed) = account.settle();
    // assert_eq!(settled, balances::new(0, 0, 200));
    // assert_eq!(owed, balances::new(0, 0, 0));

    // let (before, after) = account.add_stake(0);
    // assert!(before == 0, 0);
    // assert!(after == 0, 0);
    // assert!(account.active_stake() == 0, 0);
    // assert!(account.inactive_stake() == 0, 0);
    // let (settled, owed) = account.settle();
    // assert_eq!(settled, balances::new(0, 0, 0));
    // assert_eq!(owed, balances::new(0, 0, 0));

    // test.end();
    // }

    #[test]
    fun update_ok() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let mut account = account::empty(test.ctx());
        let (prev_epoch, prev_maker_volume, prev_active_stake) = account.update(test.ctx());
        assert!(prev_epoch == 0, 0);
        assert!(prev_maker_volume == 0, 0);
        assert!(prev_active_stake == 0, 0);

        account.add_order(1);
        let fill = fill::new(
            1,
            1,
            id_from_address(@0xB),
            false,
            false,
            100,
            100,
            500,
            false,
            0,
            0,
            0,
        );
        account.process_maker_fill(&fill);

        // update doesn't do anything until next epoch
        let (prev_epoch, prev_maker_volume, prev_active_stake) = account.update(test.ctx());
        assert!(prev_epoch == 0, 0);
        assert!(prev_maker_volume == 0, 0);
        assert!(prev_active_stake == 0, 0);

        test.next_epoch(OWNER);
        test.next_tx(ALICE);
        let (prev_epoch, prev_maker_volume, prev_active_stake) = account.update(test.ctx());
        assert!(prev_epoch == 0, 0);
        assert!(prev_maker_volume == 100, 0);
        assert!(prev_active_stake == 0, 0);

        // #feat:stake - DISABLED
        // let (before, after) = account.add_stake(100);
        // assert!(before == 0, 0);
        // assert!(after == 100, 0);
        // assert!(account.active_stake() == 0, 0);
        // assert!(account.inactive_stake() == 100, 0);

        // already reset earlier, new stake not counted yet
        let (prev_epoch, prev_maker_volume, prev_active_stake) = account.update(test.ctx());
        assert!(prev_epoch == 0, 0);
        assert!(prev_maker_volume == 0, 0);
        assert!(prev_active_stake == 0, 0);

        test.next_epoch(OWNER);
        test.next_tx(ALICE);
        let (prev_epoch, prev_maker_volume, prev_active_stake) = account.update(test.ctx());
        assert!(prev_epoch == 1, 0);
        assert!(prev_maker_volume == 0, 0);
        assert!(prev_active_stake == 0, 0);
        // prev active stake still zero, but current active stake updated
        // #feat:stake - DISABLED
        // assert!(account.active_stake() == 100, 0);
        // assert!(account.inactive_stake() == 0, 0);

        // let (before, after) = account.add_stake(100);
        // assert!(before == 100, 0);
        // assert!(after == 200, 0);

        test.next_epoch(OWNER);
        test.next_tx(ALICE);
        let (prev_epoch, prev_maker_volume, prev_active_stake) = account.update(test.ctx());
        assert!(prev_epoch == 2, 0);
        assert!(prev_maker_volume == 0, 0);
        // #feat:stake - DISABLED
        // assert!(prev_active_stake == 100, 0);
        // assert!(account.active_stake() == 200, 0);
        // assert!(account.inactive_stake() == 0, 0);
        assert!(prev_active_stake == 0, 0);

        test.end();
    }

    // #feat:rebate
    // #[test]
    // fun claim_rebates_ok() {
    //     let mut test = begin(OWNER);

    //     test.next_tx(ALICE);
    //     let mut account = account::empty(test.ctx());
    //     account.claim_rebates();
    //     let (settled, owed) = account.settle();
    //     assert_eq!(settled, balances::new(0, 0, 0));
    //     assert_eq!(owed, balances::new(0, 0, 0));

    //     account.add_rebates(balances::new(50, 150, 100));
    //     account.claim_rebates();
    //     let (settled, owed) = account.settle();
    //     assert_eq!(settled, balances::new(50, 150, 100));
    //     assert_eq!(owed, balances::new(0, 0, 0));

    //     // user owes 100 CRED for staking
    //     account.add_stake(100);
    //     // user receives 150 base, 50 quote, 100 CRED from rebates
    //     account.add_rebates(balances::new(150, 50, 100));
    //     account.claim_rebates();
    //     let (settled, owed) = account.settle();
    //     assert_eq!(settled, balances::new(150, 50, 100));
    //     assert_eq!(owed, balances::new(0, 0, 100));

    //     test.end();
    // }

    // === Pending turnover ledger ===
    // Maker-fee credits recognized at fill wait on the account — tagged with the
    // epoch they were earned in — until the owner's next transaction drains them
    // into the ring on their `TradingAccount`.

    #[test]
    fun pending_turnover_merges_credits_earned_in_the_same_epoch() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let mut account = account::empty(test.ctx());
        account.add_pending_turnover(5, 100);
        account.add_pending_turnover(5, 50);

        // One entry per epoch: same-epoch credits fold into the last entry
        // rather than growing the vector.
        let entries = account.take_pending_turnover();
        assert_eq!(entries.length(), 1);
        assert_eq!(entries[0].entry_epoch(), 5);
        assert_eq!(entries[0].entry_amount(), 150);

        test.end();
    }

    #[test]
    fun pending_turnover_keeps_distinct_epochs_in_order() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let mut account = account::empty(test.ctx());
        account.add_pending_turnover(3, 10);
        account.add_pending_turnover(4, 20);
        account.add_pending_turnover(4, 5);

        let entries = account.take_pending_turnover();
        assert_eq!(entries.length(), 2);
        assert_eq!(entries[0].entry_epoch(), 3);
        assert_eq!(entries[0].entry_amount(), 10);
        assert_eq!(entries[1].entry_epoch(), 4);
        assert_eq!(entries[1].entry_amount(), 25);

        test.end();
    }

    #[test]
    fun pending_turnover_zero_credit_is_a_noop() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let mut account = account::empty(test.ctx());
        // The fill path credits unconditionally, including expired fills that
        // charge nothing, so zero must not grow the ledger.
        account.add_pending_turnover(5, 0);

        assert!(account.take_pending_turnover().is_empty(), 0);

        test.end();
    }

    #[test]
    fun pending_turnover_drops_window_aged_entries_on_append() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let window = constants::turnover_window_epochs();
        let mut account = account::empty(test.ctx());
        account.add_pending_turnover(0, 100);
        // A credit earned a full window later ages the epoch-0 entry out: the
        // fold would drop it anyway, and pruning here is what bounds the vector
        // for a maker who never sends their own transaction.
        account.add_pending_turnover(window, 7);

        let entries = account.take_pending_turnover();
        assert_eq!(entries.length(), 1);
        assert_eq!(entries[0].entry_epoch(), window);
        assert_eq!(entries[0].entry_amount(), 7);

        test.end();
    }

    #[test]
    fun take_pending_turnover_drains() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let mut account = account::empty(test.ctx());
        account.add_pending_turnover(1, 40);
        account.add_pending_turnover(2, 60);

        let entries = account.take_pending_turnover();
        assert_eq!(entries.length(), 2);

        // The drain is total: a second take finds nothing, and the total view
        // agrees.
        assert!(account.take_pending_turnover().is_empty(), 0);
        assert_eq!(account.pending_turnover_total(2), 0);

        test.end();
    }

    #[test]
    fun pending_turnover_total_reports_only_the_window() {
        let mut test = begin(OWNER);

        test.next_tx(ALICE);
        let window = constants::turnover_window_epochs();
        let mut account = account::empty(test.ctx());
        account.add_pending_turnover(0, 100);
        account.add_pending_turnover(5, 50);

        // Both in scope while the window still covers epoch 0.
        assert_eq!(account.pending_turnover_total(5), 150);
        assert_eq!(account.pending_turnover_total(window - 1), 150);
        // The view must exclude what the fold would drop, or a trader would see
        // a tier the next trade does not honor: epoch 0 ages out first...
        assert_eq!(account.pending_turnover_total(window), 50);
        // ...and eventually everything does, without mutating the ledger.
        assert_eq!(account.pending_turnover_total(window + 5), 0);
        assert_eq!(account.take_pending_turnover().length(), 2);

        test.end();
    }
}

// #feat:gov - DISABLED
// #[test]
// fun set_voted_proposal_ok() {
// let mut test = begin(OWNER);

// test.next_tx(ALICE);
// let mut account = account::empty(test.ctx());
// assert!(account.voted_proposal().is_none(), 0);

// let prev_proposal = account.set_voted_proposal(
//     option::some(id_from_address(@0x1)),
// );
// assert!(prev_proposal.is_none(), 0);
// assert!(account.voted_proposal().borrow() == id_from_address(@0x1), 0);

// let prev_proposal = account.set_voted_proposal(
//     option::some(id_from_address(@0x2)),
// );
// assert!(prev_proposal.borrow() == id_from_address(@0x1), 0);
// assert!(account.voted_proposal().borrow() == id_from_address(@0x2), 0);

// let prev_proposal = account.set_voted_proposal(option::none());
// assert!(prev_proposal.borrow() == id_from_address(@0x2), 0);
// assert!(account.voted_proposal().is_none(), 0);

// test.end();
// }
