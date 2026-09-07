// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// TradeParams module contains the trade parameters for a trading pair.
module triexbook::trade_params;

public struct TradeParams has copy, drop, store {
    taker_fee: u64,
    maker_fee: u64,
}

// === Public-Package Functions ===
public(package) fun new(taker_fee: u64, maker_fee: u64): TradeParams {
    TradeParams { taker_fee, maker_fee }
}

/// The side of the order never changes the rate, only where the fee is
/// charged from (bids pay in quote at placement/owed, asks out of quote
/// proceeds at fill).
public(package) fun taker_fee(trade_params: &TradeParams): u64 {
    trade_params.taker_fee
}

public(package) fun maker_fee(trade_params: &TradeParams): u64 {
    trade_params.maker_fee
}
