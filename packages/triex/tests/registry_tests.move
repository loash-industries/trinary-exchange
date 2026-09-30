/// Admin, lookup and guard tests for `registry`.
#[test_only]
module triex::registry_tests {
    use std::{type_name, unit_test::{assert_eq, destroy}};
    use sui::{test_scenario::{Scenario, begin, end}, vec_set};
    use triex::{
        constants,
        registry::{Self, Registry, TriexAdminCap},
        registry_quote_dec2,
        registry_quote_dec3::{Self, REGISTRY_QUOTE_DEC3},
        trading_account_tests::{USDC, USDT}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;

    /// A fresh registry with its trading-account map initialised, taken as `OWNER`.
    fun setup(test: &mut Scenario): (Registry, TriexAdminCap) {
        let registry_id = registry::test_registry(test.ctx());
        test.next_tx(OWNER);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        registry.init_trading_account_map(&cap, test.ctx());
        (registry, cap)
    }

    fun a_collection(): ID {
        object::id_from_address(@0xC0FFEE)
    }

    // === Versions ===

    #[test]
    #[expected_failure(abort_code = registry::EVersionAlreadyEnabled)]
    fun enabling_an_enabled_version_aborts() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        registry.enable_version(constants::current_version(), &cap);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = registry::EVersionNotEnabled)]
    fun disabling_a_version_never_enabled_aborts() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        registry.disable_version(constants::current_version() + 1, &cap);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = registry::EPackageVersionNotEnabled)]
    fun mutating_while_the_running_version_is_disabled_aborts() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        registry.disable_version(constants::current_version(), &cap);
        assert!(!registry.allowed_versions().contains(&constants::current_version()));
        registry.set_treasury_address(ALICE, &cap);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = registry::EPackageVersionNotEnabled)]
    fun reading_while_the_running_version_is_disabled_aborts() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        registry.disable_version(constants::current_version(), &cap);
        registry.is_quote_approved(type_name::with_defining_ids<USDC>());
        abort 0
    }

    #[test]
    fun treasury_address_defaults_to_sender_and_can_be_changed() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        assert_eq!(registry.treasury_address(), OWNER);
        registry.set_treasury_address(ALICE, &cap);
        assert_eq!(registry.treasury_address(), ALICE);
        destroy(cap);
        destroy(registry);
        end(test);
    }

    // === Approved quotes ===

    #[test]
    /// A quote with exactly the minimum decimals is approved from its metadata.
    fun a_three_decimal_quote_is_approved() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        let quote = type_name::with_defining_ids<REGISTRY_QUOTE_DEC3>();
        let metadata = registry_quote_dec3::metadata(test.ctx());

        assert!(!registry.is_quote_approved(quote));
        registry.add_approved_quote(&metadata, &cap);
        assert!(registry.is_quote_approved(quote));

        destroy(metadata);
        destroy(cap);
        destroy(registry);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = registry::EQuoteInsufficientDecimals)]
    fun a_two_decimal_quote_is_rejected() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        let metadata = registry_quote_dec2::metadata(test.ctx());
        registry.add_approved_quote(&metadata, &cap);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = registry::EQuoteAlreadyApproved)]
    fun approving_a_quote_twice_aborts() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        let metadata = registry_quote_dec3::metadata(test.ctx());
        registry.add_approved_quote_unchecked<USDC>(&cap);
        registry.add_approved_quote(&metadata, &cap);
        assert!(registry.is_quote_approved(type_name::with_defining_ids<REGISTRY_QUOTE_DEC3>()));
        registry.add_approved_quote(&metadata, &cap);
        abort 0
    }

    #[test]
    fun removing_an_approved_quote_revokes_only_it() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        registry.add_approved_quote_unchecked<USDC>(&cap);
        registry.add_approved_quote_unchecked<USDT>(&cap);

        registry.remove_approved_quote<USDC>(&cap);
        assert!(!registry.is_quote_approved(type_name::with_defining_ids<USDC>()));
        assert!(registry.is_quote_approved(type_name::with_defining_ids<USDT>()));

        destroy(cap);
        destroy(registry);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = registry::EQuoteNotApproved)]
    fun removing_before_any_approval_aborts() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        registry.remove_approved_quote<USDC>(&cap);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = registry::EQuoteNotApproved)]
    fun removing_an_unapproved_quote_aborts() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        registry.add_approved_quote_unchecked<USDT>(&cap);
        registry.remove_approved_quote<USDC>(&cap);
        abort 0
    }

    // === Trading accounts ===

    #[test]
    /// Re-initialising the map keeps existing entries; unknown owners read empty.
    fun trading_account_map_init_is_idempotent() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        let id = object::id_from_address(@0xA1);

        assert_eq!(registry.get_trading_account_ids(ALICE), vec_set::empty());
        registry.add_trading_account(ALICE, id);
        registry.add_trading_account(ALICE, id);
        registry.init_trading_account_map(&cap, test.ctx());
        assert_eq!(registry.get_trading_account_ids(ALICE), vec_set::singleton(id));
        assert_eq!(registry.get_trading_account_ids(OWNER), vec_set::empty());

        destroy(cap);
        destroy(registry);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = registry::EMaxTradingAccountsReached)]
    fun exceeding_the_trading_account_limit_aborts() {
        let mut test = begin(OWNER);
        let (mut registry, _cap) = setup(&mut test);
        let max = constants::max_trading_accounts();
        max.do!(
            |i| registry.add_trading_account(
                ALICE,
                object::id_from_address(sui::address::from_u256(i as u256)),
            ),
        );
        assert_eq!(registry.get_trading_account_ids(ALICE).length(), max);
        registry.add_trading_account(ALICE, object::id_from_address(@0xFFFF));
        abort 0
    }

    // === Pools ===

    #[test]
    #[expected_failure(abort_code = registry::EPoolDoesNotExist)]
    fun unregistering_a_missing_pool_aborts() {
        let mut test = begin(OWNER);
        let (mut registry, _cap) = setup(&mut test);
        registry.unregister_pool<USDT, USDC>();
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = registry::EPoolDoesNotExist)]
    fun looking_up_a_missing_pool_aborts() {
        let mut test = begin(OWNER);
        let (registry, _cap) = setup(&mut test);
        registry.get_pool_id<USDT, USDC>();
        abort 0
    }

    #[test]
    fun a_registered_pool_can_be_looked_up_and_unregistered() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);
        let pool_id = object::id_from_address(@0xB00);

        registry.register_pool<USDT, USDC>(pool_id);
        assert_eq!(registry.get_pool_id<USDT, USDC>(), pool_id);
        registry.unregister_pool<USDT, USDC>();
        registry.register_pool<USDT, USDC>(pool_id);

        destroy(cap);
        destroy(registry);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = registry::EMulticoinPoolDoesNotExist)]
    fun unregistering_before_any_multicoin_pool_aborts() {
        let mut test = begin(OWNER);
        let (mut registry, _cap) = setup(&mut test);
        registry.unregister_multicoin_pool<USDC>(a_collection(), 1);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = registry::EMulticoinPoolDoesNotExist)]
    fun unregistering_a_missing_multicoin_pool_aborts() {
        let mut test = begin(OWNER);
        let (mut registry, _cap) = setup(&mut test);
        registry.register_multicoin_pool<USDC>(
            a_collection(),
            1,
            object::id_from_address(@0xB00),
            test.ctx(),
        );
        registry.unregister_multicoin_pool<USDC>(a_collection(), 2);
        abort 0
    }

    #[test]
    fun multicoin_pool_exists_tracks_registration() {
        let mut test = begin(OWNER);
        let (mut registry, cap) = setup(&mut test);

        assert!(!registry.multicoin_pool_exists<USDC>(a_collection(), 1));
        registry.register_multicoin_pool<USDC>(
            a_collection(),
            1,
            object::id_from_address(@0xB00),
            test.ctx(),
        );
        assert!(registry.multicoin_pool_exists<USDC>(a_collection(), 1));
        assert!(!registry.multicoin_pool_exists<USDT>(a_collection(), 1));
        registry.unregister_multicoin_pool<USDC>(a_collection(), 1);
        assert!(!registry.multicoin_pool_exists<USDC>(a_collection(), 1));

        destroy(cap);
        destroy(registry);
        end(test);
    }
}

/// One-time-witness coins carrying real `CoinMetadata`, for the quote-decimals gate.
#[test_only, allow(deprecated_usage)]
module triex::registry_quote_dec3 {
    use std::unit_test::destroy;
    use sui::{coin::{Self, CoinMetadata}, test_utils::create_one_time_witness};

    public struct REGISTRY_QUOTE_DEC3 has drop {}

    public fun metadata(ctx: &mut TxContext): CoinMetadata<REGISTRY_QUOTE_DEC3> {
        let (treasury, metadata) = coin::create_currency(
            create_one_time_witness<REGISTRY_QUOTE_DEC3>(),
            3,
            b"D3",
            b"",
            b"",
            option::none(),
            ctx,
        );
        destroy(treasury);
        metadata
    }
}

#[test_only, allow(deprecated_usage)]
module triex::registry_quote_dec2 {
    use std::unit_test::destroy;
    use sui::{coin::{Self, CoinMetadata}, test_utils::create_one_time_witness};

    public struct REGISTRY_QUOTE_DEC2 has drop {}

    public fun metadata(ctx: &mut TxContext): CoinMetadata<REGISTRY_QUOTE_DEC2> {
        let (treasury, metadata) = coin::create_currency(
            create_one_time_witness<REGISTRY_QUOTE_DEC2>(),
            2,
            b"D2",
            b"",
            b"",
            option::none(),
            ctx,
        );
        destroy(treasury);
        metadata
    }
}
