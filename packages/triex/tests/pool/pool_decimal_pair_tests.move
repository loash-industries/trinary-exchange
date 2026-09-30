/// Coin pools price as `P_human * 10^(Dq - Db + 9)`, and a `u64` price can only
/// hold that while the exponent stays in `[0, 18]` — that is, while the base and
/// quote decimals are at most 9 apart. Pool creation reads both coins' decimals
/// and refuses a pair outside that window, since nothing on the order path ever
/// sees decimals to catch it later.
#[test_only]
module triex::pool_decimal_pair_tests {
    use std::unit_test::destroy;
    use sui::{
        coin::mint_for_testing,
        coin_registry::Currency,
        test_scenario::{Scenario, begin, return_shared}
    };
    use token::cred::CRED;
    use triex::{
        coin_dec15::{Self, COIN_DEC15},
        coin_dec18::{Self, COIN_DEC18},
        coin_dec6::{Self, COIN_DEC6},
        constants,
        fee_policy::{Self, FeePolicy},
        pool,
        registry::{Self, Registry}
    };

    const OWNER: address = @0x1;

    public struct BASE has drop {}
    public struct QUOTE has drop {}

    /// A registry with `QuoteAsset` approved, and a shared policy pricing it.
    fun setup<QuoteAsset>(test: &mut Scenario): ID {
        test.next_tx(OWNER);
        let registry_id = registry::test_registry(test.ctx());
        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        registry.add_approved_quote_unchecked<QuoteAsset>(&admin_cap);
        return_shared(registry);

        let mut policy = fee_policy::create_for_testing(test.ctx());
        policy.create_class<QuoteAsset>(
            0,
            vector[0],
            vector[11_000_000],
            vector[9_000_000],
            2_000,
            &admin_cap,
            test.ctx(),
        );
        policy.set_default_class<QuoteAsset>(0, &admin_cap);
        fee_policy::share_for_testing(policy);
        destroy(admin_cap);
        registry_id
    }

    fun create_admin(base_decimals: u8, quote_decimals: u8) {
        let mut test = begin(OWNER);
        let registry_id = setup<QUOTE>(&mut test);

        test.next_tx(OWNER);
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let policy = test.take_shared<FeePolicy>();
        pool::create_pool_admin_for_testing<BASE, QUOTE>(
            &mut registry,
            &policy,
            base_decimals,
            quote_decimals,
            &admin_cap,
            test.ctx(),
        );
        return_shared(registry);
        return_shared(policy);
        destroy(admin_cap);
        test.end();
    }

    fun create_permissionless(base_decimals: u8, quote_decimals: u8) {
        let mut test = begin(OWNER);
        let registry_id = setup<QUOTE>(&mut test);

        test.next_tx(OWNER);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let policy = test.take_shared<FeePolicy>();
        pool::create_permissionless_pool_for_testing<BASE, QUOTE>(
            &mut registry,
            &policy,
            base_decimals,
            quote_decimals,
            mint_for_testing<CRED>(constants::pool_creation_fee(), test.ctx()),
            test.ctx(),
        );
        return_shared(registry);
        return_shared(policy);
        test.end();
    }

    // === The window, from both sides ===

    #[test]
    /// A 9-decimal gap is the widest that still prices, whichever side is wider.
    fun a_quote_nine_decimals_wider_is_accepted() {
        create_admin(0, 9);
    }

    #[test]
    fun a_base_nine_decimals_wider_is_accepted() {
        create_admin(18, 9);
    }

    #[test]
    fun equal_decimals_are_accepted() {
        create_admin(6, 6);
    }

    #[test, expected_failure(abort_code = pool::EInvalidDecimalPair)]
    /// A 0-decimal base against a 10-decimal quote: the exponent is 19, and even
    /// a price of one whole quote per unit overflows the `u64` price field.
    fun a_quote_ten_decimals_wider_is_rejected() {
        create_admin(0, 10);
    }

    #[test, expected_failure(abort_code = pool::EInvalidDecimalPair)]
    /// An 18-decimal base against a 6-decimal quote: the exponent is -3, so the
    /// book can only express prices in steps of 1,000 quote per whole coin.
    fun a_base_twelve_decimals_wider_is_rejected() {
        create_admin(18, 6);
    }

    #[test, expected_failure(abort_code = pool::EInvalidDecimalPair)]
    /// The permissionless path runs the same check: pool creation is open to
    /// anyone, and coin decimals are a free `u8`.
    fun the_permissionless_path_rejects_the_same_pair() {
        create_permissionless(18, 6);
    }

    // === Decimals read off a real `Currency` ===

    fun create_from_currency<BaseAsset>(base_currency: Currency<BaseAsset>) {
        let mut test = begin(OWNER);
        let registry_id = setup<COIN_DEC6>(&mut test);

        test.next_tx(OWNER);
        let quote_currency = coin_dec6::currency(test.ctx());
        let admin_cap = registry::get_admin_cap_for_testing(test.ctx());
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let policy = test.take_shared<FeePolicy>();
        pool::create_pool_admin<BaseAsset, COIN_DEC6>(
            &mut registry,
            &policy,
            &base_currency,
            &quote_currency,
            &admin_cap,
            test.ctx(),
        );
        return_shared(registry);
        return_shared(policy);
        destroy(admin_cap);
        destroy(base_currency);
        destroy(quote_currency);
        test.end();
    }

    #[test]
    fun a_currency_within_the_window_creates_the_pool() {
        let mut test = begin(OWNER);
        let base_currency = coin_dec15::currency(test.ctx());
        test.end();
        create_from_currency(base_currency);
    }

    #[test, expected_failure(abort_code = pool::EInvalidDecimalPair)]
    fun a_currency_outside_the_window_is_rejected() {
        let mut test = begin(OWNER);
        let base_currency = coin_dec18::currency(test.ctx());
        test.end();
        create_from_currency(base_currency);
    }
}

/// One-time-witness coins, so the currency tests read decimals off a real
/// `Currency` rather than a number the test passes in.
#[test_only]
module triex::coin_dec6 {
    use std::unit_test::destroy;
    use sui::{coin_registry::{Self, Currency}, test_utils::create_one_time_witness};

    public struct COIN_DEC6 has drop {}

    public fun currency(ctx: &mut TxContext): Currency<COIN_DEC6> {
        let (init, cap) = coin_registry::new_currency_with_otw(
            create_one_time_witness<COIN_DEC6>(),
            6,
            b"D6".to_string(),
            b"".to_string(),
            b"".to_string(),
            b"".to_string(),
            ctx,
        );
        destroy(cap);
        init.unwrap_for_testing()
    }
}

#[test_only]
module triex::coin_dec15 {
    use std::unit_test::destroy;
    use sui::{coin_registry::{Self, Currency}, test_utils::create_one_time_witness};

    public struct COIN_DEC15 has drop {}

    public fun currency(ctx: &mut TxContext): Currency<COIN_DEC15> {
        let (init, cap) = coin_registry::new_currency_with_otw(
            create_one_time_witness<COIN_DEC15>(),
            15,
            b"D15".to_string(),
            b"".to_string(),
            b"".to_string(),
            b"".to_string(),
            ctx,
        );
        destroy(cap);
        init.unwrap_for_testing()
    }
}

#[test_only]
module triex::coin_dec18 {
    use std::unit_test::destroy;
    use sui::{coin_registry::{Self, Currency}, test_utils::create_one_time_witness};

    public struct COIN_DEC18 has drop {}

    public fun currency(ctx: &mut TxContext): Currency<COIN_DEC18> {
        let (init, cap) = coin_registry::new_currency_with_otw(
            create_one_time_witness<COIN_DEC18>(),
            18,
            b"D18".to_string(),
            b"".to_string(),
            b"".to_string(),
            b"".to_string(),
            ctx,
        );
        destroy(cap);
        init.unwrap_for_testing()
    }
}
