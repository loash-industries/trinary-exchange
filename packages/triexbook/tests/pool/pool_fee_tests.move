// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::pool_fee_tests;

use triexbook::pool_test_utils;

#[test]
fun test_bid_with_quote_fees_updates_vault_reserve() {
    pool_test_utils::test_bid_with_quote_fees_updates_vault_reserve();
}

#[test]
fun test_admin_withdraws_quote_fee_reserve() {
    pool_test_utils::test_admin_withdraws_quote_fee_reserve();
}
