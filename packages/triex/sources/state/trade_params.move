// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// TradeParams module contains the trade parameters for a trading pair.
module triexbook::trade_params;

public struct TradeParams has copy, drop, store {
    // #feat:fees
    // taker_fee: u64,
    // maker_fee: u64,
    // stake_required: u64,
    fee: u64,
}

// === Public-Package Functions ===
// #feat:fees
// public(package) fun new(taker_fee: u64, maker_fee: u64, stake_required: u64): TradeParams {
//     TradeParams { taker_fee, maker_fee, stake_required }
// }

// public(package) fun maker_fee(trade_params: &TradeParams): u64 {
//     trade_params.maker_fee
// }

// public(package) fun taker_fee(trade_params: &TradeParams): u64 {
//     trade_params.taker_fee
// }

// /// Returns the taker fee for a user based on the active stake and volume in cred.
// /// Taker fee is halved if user has enough stake and volume.
// public(package) fun taker_fee_for_user(
//     self: &TradeParams,
//     active_stake: u64,
//     volume_in_cred: u128,
// ): u64 {
//     if (
//         active_stake >= self.stake_required &&
//         volume_in_cred >= (self.stake_required as u128)
//     ) {
//         self.taker_fee / 2
//     } else {
//         self.taker_fee
//     }
// }

// public(package) fun stake_required(trade_params: &TradeParams): u64 {
//     trade_params.stake_required
// }

public(package) fun new(fee: u64): TradeParams {
    TradeParams { fee }
}

public(package) fun fee(trade_params: &TradeParams): u64 {
    trade_params.fee
}

// Returns the fee for a user based on whether the order is a bid or an ask.
// For Market Buys (taker), fee is applied. For Market Sells (maker), no fee is applied.
// For Limit Buys (maker), fee is applied. For Limit Sells (taker), no fee is applied.
public(package) fun taker_fee_for_user(self: &TradeParams, is_bid: bool): u64 {
    if (is_bid) {
        self.fee
    } else {
        0
    }
}

public(package) fun maker_fee_for_user(self: &TradeParams, is_bid: bool): u64 {
    if (is_bid) {
        self.fee
    } else {
        0
    }
}
