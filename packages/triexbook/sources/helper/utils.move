// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// CredBook utility functions.
module triexbook::utils;

// /// Pop elements from the back of `v` until its length equals `n`,
// /// returning the elements that were popped in the order they
// /// appeared in `v`.
// // #feat:bv
// public(package) fun pop_until<T>(v: &mut vector<T>, n: u64): vector<T> {
//     let mut res = vector[];
//     while (v.length() > n) {
//         res.push_back(v.pop_back());
//     };

//     res.reverse();
//     res
// }

// /// Pop `n` elements from the back of `v`, returning the elements
// /// that were popped in the order they appeared in `v`.
// ///
// /// Aborts if `v` has fewer than `n` elements.
// // #feat:bv
// public(package) fun pop_n<T>(v: &mut vector<T>, n: u64): vector<T> {
//     let mut res = vector[];
//     n.do!(|_| res.push_back(v.pop_back()));
//     res.reverse();
//     res
// }

// Order IDs are opaque `u64` serials. Side/price are stored explicitly on `Order`.
