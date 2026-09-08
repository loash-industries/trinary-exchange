// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module triexbook::pool_query_tests;

use triexbook::pool_test_utils;

#[test]
fun test_get_order() {
    pool_test_utils::test_get_order();
}

#[test]
fun test_get_orders() {
    pool_test_utils::test_get_orders();
}
