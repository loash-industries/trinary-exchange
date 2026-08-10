// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module token::cred;

public struct CRED has drop {}

public struct ProtectedTreasury has key {
    id: UID,
}

public struct TreasuryCapKey has copy, drop, store {}

public fun burn(arg0: &mut ProtectedTreasury, arg1: sui::coin::Coin<CRED>) {
    sui::coin::burn<CRED>(borrow_cap_mut(arg0), arg1);
}

public fun total_supply(arg0: &ProtectedTreasury): u64 {
    sui::coin::total_supply<CRED>(borrow_cap(arg0))
}

fun borrow_cap(arg0: &ProtectedTreasury): &sui::coin::TreasuryCap<CRED> {
    let v0 = TreasuryCapKey {};
    sui::dynamic_object_field::borrow<TreasuryCapKey, sui::coin::TreasuryCap<CRED>>(
        &arg0.id,
        v0,
    )
}

fun borrow_cap_mut(arg0: &mut ProtectedTreasury): &mut sui::coin::TreasuryCap<CRED> {
    let v0 = TreasuryCapKey {};
    sui::dynamic_object_field::borrow_mut<TreasuryCapKey, sui::coin::TreasuryCap<CRED>>(
        &mut arg0.id,
        v0,
    )
}

fun create_coin(
    arg0: CRED,
    arg1: u64,
    arg2: &mut sui::tx_context::TxContext,
): (ProtectedTreasury, sui::coin::Coin<CRED>) {
    let (v0, v1) = sui::coin::create_currency<CRED>(
        arg0,
        6,
        b"CRED",
        b"Inter-Galactic Credits",
        b"CRED is the neutral trading currency for EVE Frontier. It is used to price and trade in-game items and settle balances between players and tribes.",
        std::option::some<sui::url::Url>(
            sui::url::new_unsafe_from_bytes(b"https://trinary.exchange/trilith.svg"),
        ),
        arg2,
    );
    let mut cap = v0;
    sui::transfer::public_freeze_object<sui::coin::CoinMetadata<CRED>>(v1);
    let mut protected_treasury = ProtectedTreasury { id: sui::object::new(arg2) };

    let coin = sui::coin::mint<CRED>(&mut cap, arg1, arg2);
    sui::dynamic_object_field::add<TreasuryCapKey, sui::coin::TreasuryCap<CRED>>(
        &mut protected_treasury.id,
        TreasuryCapKey {},
        cap,
    );

    (protected_treasury, coin)
}

#[allow(lint(share_owned))]
fun init(arg0: CRED, arg1: &mut TxContext) {
    let (v0, v1) = create_coin(arg0, 10000000000000000, arg1);
    sui::transfer::share_object<ProtectedTreasury>(v0);
    sui::transfer::public_transfer<sui::coin::Coin<CRED>>(v1, sui::tx_context::sender(arg1));
}

#[test_only]
public fun share_treasury_for_testing(ctx: &mut sui::tx_context::TxContext) {
    let (v0, v1) = create_coin(CRED {}, 10000000000000000, ctx);
    sui::transfer::share_object<ProtectedTreasury>(v0);
    v1.burn_for_testing();
}
