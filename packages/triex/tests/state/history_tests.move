// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::history_tests;

// #feat:rebate - DISABLED - All imports unused since all tests are disabled
// use sui::{test_scenario::{begin, end}, test_utils};
// use triexbook::{balances, constants, history, trade_params};

// #feat:rebate - DISABLED
// const EWrongRebateAmount: u64 = 0;

// #feat:rebate - DISABLED
// const FLOAT_SCALING: u64 = 1_000_000_000;

// #feat:rebate - DISABLED
// #[test]
// /// Test that the rebate amount is calculated correctly.
// fun test_rebate_amount() {
//     let owner: address = @0x1;
//     let mut test = begin(owner);
//
//     // let trade_params = trade_params::new(0, 0, 1_000_000); // #feat:fees
//     let trade_params = trade_params::new(0);
//     let mut history = history::empty(trade_params, 0, test.ctx());
//     let mut epochs_to_advance = constants::phase_out_epochs();
//
//     while (epochs_to_advance > 0) {
//         test.next_epoch(owner);
//         history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//         history.set_current_volumes(
//             10 * FLOAT_SCALING,
//             5 * FLOAT_SCALING,
//             balances::new(0, 0, 500_000_000),
//         );
//         epochs_to_advance = epochs_to_advance - 1;
//     };
//
//     // epoch 29
//     test.next_epoch(owner);
//     history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//
//     history.set_current_volumes(
//         10 * FLOAT_SCALING,
//         5 * FLOAT_SCALING,
//         balances::new(500_000, 2_500_000, 1_000_000_000),
//     );
//
//     // epoch 30
//     test.next_epoch(owner);
//     history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//
//     let rebate = history.calculate_rebate_amount(
//         29,
//         (3 * FLOAT_SCALING) as u64,
//         // 1_000_000, // #feat:fees
//     );
//     assert!(rebate.base() == 90_000, EWrongRebateAmount);
//     assert!(rebate.quote() == 450_000, EWrongRebateAmount);
//     assert!(rebate.cred() == 180_000_000, EWrongRebateAmount);
//
//     unit_test::destroy(history);
//     end(test);
// }

// #feat:rebate - DISABLED
// #[test]
// /// Test that the rebate amount is correct when the epoch is skipped.
// fun test_epoch_skipped() {
//     let owner: address = @0x1;
//     let mut test = begin(owner);
//
//     // let trade_params = trade_params::new(0, 0, 1_000_000); // #feat:fees
//     let trade_params = trade_params::new(0);
//
//     // epoch 0
//     let mut history = history::empty(trade_params, 0, test.ctx());
//     let mut epochs_to_advance = constants::phase_out_epochs();
//
//     while (epochs_to_advance > 0) {
//         test.next_epoch(owner);
//         history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//         history.set_current_volumes(
//             10 * FLOAT_SCALING,
//             5 * FLOAT_SCALING,
//             balances::new(500_000, 2_500_000, 500_000_000),
//         );
//         epochs_to_advance = epochs_to_advance - 1;
//     };
//
//     // epoch 29
//     test.next_epoch(owner);
//     history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//
//     history.set_current_volumes(
//         10 * FLOAT_SCALING,
//         5 * FLOAT_SCALING,
//         balances::new(500_000, 2_500_000, 1_000_000_000),
//     );
//
//     // epoch 31
//     test.next_epoch(owner);
//     test.next_epoch(owner);
//     history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//
//     let rebate_epoch_0_alice = history.calculate_rebate_amount(
//         28,
//         0,
//         // 1_000_000, // #feat:fees
//     );
//     assert!(rebate_epoch_0_alice.base() == 0, EWrongRebateAmount);
//     assert!(rebate_epoch_0_alice.quote() == 0, EWrongRebateAmount);
//     assert!(rebate_epoch_0_alice.cred() == 0, EWrongRebateAmount);
//
//     let rebate_epoch_1_alice = history.calculate_rebate_amount(
//         28,
//         0,
//         // 1_000_000, // #feat:fees
//     );
//     assert!(rebate_epoch_1_alice.base() == 0, EWrongRebateAmount);
//     assert!(rebate_epoch_1_alice.quote() == 0, EWrongRebateAmount);
//     assert!(rebate_epoch_1_alice.cred() == 0, EWrongRebateAmount);
//
//     let rebate_epoch_1_bob = history.calculate_rebate_amount(
//         29,
//         (3 * FLOAT_SCALING) as u64,
//         // 1_000_000, // #feat:fees
//     );
//     assert!(rebate_epoch_1_bob.base() == 90_000, EWrongRebateAmount);
//     assert!(rebate_epoch_1_bob.quote() == 450_000, EWrongRebateAmount);
//     assert!(rebate_epoch_1_bob.cred() == 180_000_000, EWrongRebateAmount);
//
//     unit_test::destroy(history);
//     end(test);
// }

// #feat:rebate - DISABLED
// #[test]
// fun test_other_maker_volume_above_phase_out() {
//     let owner: address = @0x1;
//     let mut test = begin(owner);
//
//     // let trade_params = trade_params::new(0, 0, 1_000_000); // #feat:fees
//     let trade_params = trade_params::new(0);
//
//     // epoch 0
//     let mut history = history::empty(trade_params, 0, test.ctx());
//     let mut epochs_to_advance = constants::phase_out_epochs();
//
//     while (epochs_to_advance > 0) {
//         test.next_epoch(owner);
//         history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//         history.set_current_volumes(
//             10 * FLOAT_SCALING,
//             5 * FLOAT_SCALING,
//             balances::new(500_000, 2_500_000, 500_000_000),
//         );
//         epochs_to_advance = epochs_to_advance - 1;
//     };
//
//     // epoch 29
//     test.next_epoch(owner);
//     history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//
//     history.set_current_volumes(
//         15 * FLOAT_SCALING,
//         5 * FLOAT_SCALING,
//         balances::new(500_000, 2_500_000, 1_000_000_000),
//     );
//
//     // epoch 30
//     test.next_epoch(owner);
//     history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//
//     let rebate = history.calculate_rebate_amount(
//         29,
//         (3 * FLOAT_SCALING) as u64,
//         // 1_000_000, // #feat:fees
//     );
//     assert!(rebate.base() == 0, EWrongRebateAmount);
//     assert!(rebate.quote() == 0, EWrongRebateAmount);
//     assert!(rebate.cred() == 0, EWrongRebateAmount);
//
//     unit_test::destroy(history);
//     end(test);
// }

// #feat:rebate - DISABLED
// #[test]
// /// Pool is created on epoch 0,
// /// up till epoch 27 should still grant close to the maximum rebate.
// /// Epoch 28 should return the normal rebate.
// fun test_rebate_edge_epoch_ok() {
//     let owner: address = @0x1;
//     let mut test = begin(owner);
//
//     // let trade_params = trade_params::new(0, 0, 1_000_000); // #feat:fees
//     let trade_params = trade_params::new(0);
//
//     // epoch 0
//     let mut history = history::empty(trade_params, 0, test.ctx());
//     history.set_current_volumes(
//         10 * FLOAT_SCALING,
//         5 * FLOAT_SCALING,
//         balances::new(500_000, 2_500_000, 500_000_000),
//     );
//     let mut epochs_to_advance = constants::phase_out_epochs() - 1;
//
//     while (epochs_to_advance > 0) {
//         test.next_epoch(owner);
//         history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//         history.set_current_volumes(
//             10 * FLOAT_SCALING,
//             5 * FLOAT_SCALING,
//             balances::new(500_000, 2_500_000, 500_000_000),
//         );
//         let rebate = history.calculate_rebate_amount(
//             0,
//             (3 * FLOAT_SCALING) as u64,
//             // 1_000_000, // #feat:fees
//         );
//         assert!(rebate.base() == 300_000, EWrongRebateAmount);
//         assert!(rebate.quote() == 1_500_000, EWrongRebateAmount);
//         assert!(rebate.cred() == 300_000_000, EWrongRebateAmount);
//         epochs_to_advance = epochs_to_advance - 1;
//     };
//
//     // epoch 28
//     test.next_epoch(owner);
//     history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//
//     history.set_current_volumes(
//         10 * FLOAT_SCALING,
//         5 * FLOAT_SCALING,
//         balances::new(500_000, 1_000_000, 1_000_000_000),
//     );
//
//     // epoch 29
//     test.next_epoch(owner);
//     history.update(trade_params, object::id_from_address(@0x0), test.ctx());
//
//     let rebate = history.calculate_rebate_amount(
//         28,
//         (3 * FLOAT_SCALING) as u64,
//         // 1_000_000, // #feat:fees
//     );
//     assert!(rebate.base() == 90_000, EWrongRebateAmount);
//     assert!(rebate.quote() == 180_000, EWrongRebateAmount);
//     assert!(rebate.cred() == 180_000_000, EWrongRebateAmount);
//
//     unit_test::destroy(history);
//     end(test);
// }
