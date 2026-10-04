/// Unit tests for `hub_adapter`: every write path, every abort, and the event
/// each write leaves, against real world caps and warehouse vaults.
#[test_only]
module triex_hub_operator_adapter::hub_adapter_tests {
    use std::unit_test::assert_eq;
    use sui::{event, test_scenario as ts};
    use triex::fee_policy::{Self, OperatorBeneficiaryChanged, OperatorBeneficiaryRegistered};
    use triex_hub_operator_adapter::{
        hub_adapter::{Self, HubOperatorChanged, HubOperatorRegistered},
        test_world::{Self, Site}
    };
    use warehouse_receipts::receipt::VaultInitializedEvent;

    const OWNER: address = @0xC;
    const OTHER_OWNER: address = @0xD;
    const BUYER: address = @0xE;
    const PARTNER: address = @0xF00D;
    const NEW_PARTNER: address = @0xF11D;

    fun hub(sc: &mut ts::Scenario, owner: address, seed: u64): Site {
        let mut site = test_world::create_site(sc, owner, seed, false);
        test_world::initialize_vault(sc, &mut site);
        site
    }

    fun setup(sc: &mut ts::Scenario): Site {
        test_world::setup(sc);
        let site = hub(sc, OWNER, 1);
        test_world::pin_adapter(sc);
        site
    }

    // === register_operator ===

    #[test]
    fun owner_registers_themselves() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);

        assert!(test_world::beneficiary(&mut sc, site.collection()).is_none());
        let cap_id = test_world::owner_cap_id(&mut sc, &site);
        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);

        let registered = event::events_by_type<HubOperatorRegistered>();
        assert_eq!(registered.length(), 1);
        let (collection, storage_unit, config, cap, beneficiary, by) = registered[0]
            .hub_operator_registered_parts();
        assert_eq!(collection, site.collection());
        assert_eq!(storage_unit, site.storage_unit());
        assert_eq!(config, site.vault_config());
        assert_eq!(beneficiary, OWNER);
        assert_eq!(by, OWNER);
        assert_eq!(cap, cap_id);

        let triex_registered = event::events_by_type<OperatorBeneficiaryRegistered>();
        assert_eq!(triex_registered.length(), 1);
        let (collection, beneficiary) = triex_registered[0].operator_beneficiary_registered_parts();
        assert_eq!(collection, site.collection());
        assert_eq!(beneficiary, OWNER);

        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(OWNER));
        ts::end(sc);
    }

    /// The owner may name anyone as payee; the signer is recorded either way.
    #[test]
    fun owner_registers_a_third_party() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);

        test_world::register(&mut sc, OWNER, site.character(), &site, PARTNER);
        let registered = event::events_by_type<HubOperatorRegistered>();
        let (_, _, _, _, beneficiary, by) = registered[0].hub_operator_registered_parts();
        assert_eq!(beneficiary, PARTNER);
        assert_eq!(by, OWNER);

        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(PARTNER));
        ts::end(sc);
    }

    #[test]
    fun registration_is_per_collection() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        let other = hub(&mut sc, OTHER_OWNER, 2);

        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);
        assert!(test_world::beneficiary(&mut sc, other.collection()).is_none());

        test_world::register(&mut sc, OTHER_OWNER, other.character(), &other, OTHER_OWNER);
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(OWNER));
        assert_eq!(test_world::beneficiary(&mut sc, other.collection()), option::some(OTHER_OWNER));
        ts::end(sc);
    }

    /// Owning *a* storage unit is not enough: the cap must authorize the one
    /// the `VaultConfig` was initialized for.
    #[test, expected_failure(abort_code = hub_adapter::ENotStorageUnitOwner)]
    fun another_storage_units_cap_cannot_register() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        let other = hub(&mut sc, OTHER_OWNER, 2);

        test_world::register(&mut sc, OTHER_OWNER, other.character(), &site, OTHER_OWNER);
        ts::end(sc);
    }

    /// The cap lives on the owner's character, and only the character's
    /// wallet can borrow it — so a stranger cannot even reach the adapter with
    /// the owner's cap. (World enforces this, not the adapter.)
    #[
        test,
        expected_failure(
            abort_code = world::character::ESenderCannotAccessCharacter,
            location = world::character,
        ),
    ]
    fun a_stranger_cannot_borrow_the_owners_cap() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);

        test_world::register(&mut sc, OTHER_OWNER, site.character(), &site, OTHER_OWNER);
        ts::end(sc);
    }

    /// `FeePolicy` keeps the first registration and ignores later ones; the
    /// adapter turns that silent no-op into an abort.
    #[test, expected_failure(abort_code = hub_adapter::EAlreadyRegistered)]
    fun second_registration_aborts() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);

        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);
        test_world::register(&mut sc, OWNER, site.character(), &site, PARTNER);
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = fee_policy::ENoAuthorizedAdapter)]
    fun registration_requires_the_pinned_adapter() {
        let mut sc = ts::begin(test_world::admin());
        test_world::setup(&mut sc);
        let site = hub(&mut sc, OWNER, 1);

        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = fee_policy::ENoAuthorizedAdapter)]
    fun a_cleared_adapter_blocks_registration() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        test_world::clear_adapter(&mut sc);

        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);
        ts::end(sc);
    }

    // === register_operator_for_new_vault ===

    /// The first-time setup PTB: vault created, extension authorized, payee
    /// registered and vault shared in one transaction.
    #[test]
    fun first_time_setup_registers_in_the_same_transaction() {
        let mut sc = ts::begin(test_world::admin());
        test_world::setup(&mut sc);
        test_world::pin_adapter(&mut sc);
        let mut site = test_world::create_site(&mut sc, OWNER, 1, false);

        test_world::initialize_vault_and_register(&mut sc, &mut site, PARTNER);
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(PARTNER));
        ts::end(sc);
    }

    #[test]
    fun first_time_setup_emits_vault_and_registration_events() {
        let mut sc = ts::begin(test_world::admin());
        test_world::setup(&mut sc);
        test_world::pin_adapter(&mut sc);
        let mut site = test_world::create_site(&mut sc, OWNER, 1, false);

        test_world::initialize_vault_and_register_only(&mut sc, &site, OWNER);
        assert_eq!(event::events_by_type<VaultInitializedEvent>().length(), 1);
        assert_eq!(event::events_by_type<OperatorBeneficiaryRegistered>().length(), 1);
        let registered = event::events_by_type<HubOperatorRegistered>();
        assert_eq!(registered.length(), 1);
        let (_, storage_unit, _, _, beneficiary, by) = registered[0].hub_operator_registered_parts();
        assert_eq!(storage_unit, site.storage_unit());
        assert_eq!(beneficiary, OWNER);
        assert_eq!(by, OWNER);

        test_world::record_vault(&mut sc, &mut site);
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(OWNER));
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = fee_policy::ENoAuthorizedAdapter)]
    fun first_time_setup_requires_the_pinned_adapter() {
        let mut sc = ts::begin(test_world::admin());
        test_world::setup(&mut sc);
        let mut site = test_world::create_site(&mut sc, OWNER, 1, false);

        test_world::initialize_vault_and_register(&mut sc, &mut site, OWNER);
        ts::end(sc);
    }

    // === update_operator ===

    #[test]
    fun owner_rotates_the_payee() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        test_world::register(&mut sc, OWNER, site.character(), &site, PARTNER);
        let cap_id = test_world::owner_cap_id(&mut sc, &site);

        test_world::update(&mut sc, OWNER, site.character(), &site, NEW_PARTNER);

        let changed = event::events_by_type<HubOperatorChanged>();
        assert_eq!(changed.length(), 1);
        let (collection, storage_unit, config, cap, previous, beneficiary, by) = changed[0]
            .hub_operator_changed_parts();
        assert_eq!(collection, site.collection());
        assert_eq!(storage_unit, site.storage_unit());
        assert_eq!(config, site.vault_config());
        assert_eq!(cap, cap_id);
        assert_eq!(previous, PARTNER);
        assert_eq!(beneficiary, NEW_PARTNER);
        assert_eq!(by, OWNER);

        let triex_changed = event::events_by_type<OperatorBeneficiaryChanged>();
        assert_eq!(triex_changed.length(), 1);
        let (collection, previous, beneficiary) = triex_changed[0].operator_beneficiary_changed_parts();
        assert_eq!(collection, site.collection());
        assert_eq!(previous, PARTNER);
        assert_eq!(beneficiary, NEW_PARTNER);

        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(NEW_PARTNER));

        // And back — rotation is repeatable.
        test_world::update(&mut sc, OWNER, site.character(), &site, OWNER);
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(OWNER));
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = fee_policy::EOperatorBeneficiaryNotRegistered)]
    fun rotating_before_registering_aborts() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);

        test_world::update(&mut sc, OWNER, site.character(), &site, OWNER);
        ts::end(sc);
    }

    /// Rotating to the current payee succeeds without writing or emitting
    /// anything, so every `HubOperatorChanged` is a real change.
    #[test]
    fun rotating_to_the_current_payee_is_a_no_op() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        test_world::register(&mut sc, OWNER, site.character(), &site, PARTNER);

        test_world::update(&mut sc, OWNER, site.character(), &site, PARTNER);

        assert_eq!(event::events_by_type<HubOperatorChanged>().length(), 0);
        assert_eq!(event::events_by_type<OperatorBeneficiaryChanged>().length(), 0);
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(PARTNER));
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = hub_adapter::ENotStorageUnitOwner)]
    fun another_storage_units_cap_cannot_rotate() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        let other = hub(&mut sc, OTHER_OWNER, 2);
        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);

        test_world::update(&mut sc, OTHER_OWNER, other.character(), &site, OTHER_OWNER);
        ts::end(sc);
    }

    /// The admin's emergency stop freezes rotation as well as registration.
    #[test, expected_failure(abort_code = fee_policy::ENoAuthorizedAdapter)]
    fun a_cleared_adapter_blocks_rotation() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);
        test_world::clear_adapter(&mut sc);

        test_world::update(&mut sc, OWNER, site.character(), &site, PARTNER);
        ts::end(sc);
    }

    // === Ownership changes ===

    /// After a sale, the buyer — and only the buyer — controls the payee.
    #[test]
    fun the_buyer_takes_over_the_payee_after_a_sale() {
        let mut sc = ts::begin(test_world::admin());
        let mut site = setup(&mut sc);
        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);

        let buyer_character = test_world::create_character(&mut sc, BUYER, 50);
        test_world::transfer_storage_unit(&mut sc, &mut site, BUYER, buyer_character);
        // The mapping does not move by itself: the buyer re-points it.
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(OWNER));

        test_world::update(&mut sc, BUYER, buyer_character, &site, BUYER);
        let changed = event::events_by_type<HubOperatorChanged>();
        let (_, _, _, cap, previous, beneficiary, by) = changed[0].hub_operator_changed_parts();
        assert_eq!(previous, OWNER);
        assert_eq!(beneficiary, BUYER);
        assert_eq!(by, BUYER);
        // The same cap object, now held by the buyer's character.
        assert_eq!(cap, test_world::owner_cap_id(&mut sc, &site));
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(BUYER));
        ts::end(sc);
    }

    /// The seller keeps a cap for a different storage unit, and it no longer
    /// opens this one.
    #[test, expected_failure(abort_code = hub_adapter::ENotStorageUnitOwner)]
    fun the_seller_cannot_rotate_after_a_sale() {
        let mut sc = ts::begin(test_world::admin());
        let mut site = setup(&mut sc);
        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);
        let seller_character = site.character();

        let buyer_character = test_world::create_character(&mut sc, BUYER, 50);
        test_world::transfer_storage_unit(&mut sc, &mut site, BUYER, buyer_character);
        let _kept = test_world::create_site_for(&mut sc, OWNER, seller_character, 3);

        test_world::update(&mut sc, OWNER, seller_character, &site, PARTNER);
        ts::end(sc);
    }

    // === Admin destroy ===

    /// After an admin destroy, the owner registers again — the after-the-fact
    /// path — and the lifecycle reads off events.
    #[test]
    fun owner_reregisters_after_an_admin_destroy() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);
        test_world::destroy_beneficiary(&mut sc, site.collection());
        assert!(test_world::beneficiary(&mut sc, site.collection()).is_none());

        test_world::register(&mut sc, OWNER, site.character(), &site, PARTNER);
        assert_eq!(event::events_by_type<HubOperatorRegistered>().length(), 1);
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(PARTNER));
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = fee_policy::EOperatorBeneficiaryNotRegistered)]
    fun rotating_a_destroyed_mapping_aborts() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);
        test_world::destroy_beneficiary(&mut sc, site.collection());

        test_world::update(&mut sc, OWNER, site.character(), &site, PARTNER);
        ts::end(sc);
    }

    // === Canonical cap ===

    /// A second cap minted for the storage unit by a world sponsor is
    /// authorized for it (`is_authorized` passes) but is not the cap the
    /// storage unit records, so it cannot register a payee…
    #[test, expected_failure(abort_code = hub_adapter::ENotStorageUnitOwner)]
    fun a_sponsor_minted_duplicate_cap_cannot_register() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);

        test_world::write_with_duplicate_cap(&mut sc, OTHER_OWNER, &site, OTHER_OWNER, false);
        ts::end(sc);
    }

    /// …nor re-point an existing one.
    #[test, expected_failure(abort_code = hub_adapter::ENotStorageUnitOwner)]
    fun a_sponsor_minted_duplicate_cap_cannot_rotate() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);

        test_world::write_with_duplicate_cap(&mut sc, OTHER_OWNER, &site, OTHER_OWNER, true);
        ts::end(sc);
    }

    /// Presenting your own storage unit and cap against another storage
    /// unit's config is refused before the cap is even compared.
    #[test, expected_failure(abort_code = hub_adapter::EStorageUnitMismatch)]
    fun the_storage_unit_must_be_the_configs() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        let other = hub(&mut sc, OTHER_OWNER, 2);

        test_world::write_at(
            &mut sc,
            OTHER_OWNER,
            other.character(),
            &site,
            other.storage_unit(),
            OTHER_OWNER,
            false,
        );
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = hub_adapter::EStorageUnitMismatch)]
    fun the_storage_unit_must_be_the_configs_to_rotate() {
        let mut sc = ts::begin(test_world::admin());
        let site = setup(&mut sc);
        let other = hub(&mut sc, OTHER_OWNER, 2);
        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);

        test_world::write_at(
            &mut sc,
            OTHER_OWNER,
            other.character(),
            &site,
            other.storage_unit(),
            OTHER_OWNER,
            true,
        );
        ts::end(sc);
    }

    /// The atomic hand-over a seller runs: re-point to the buyer, then
    /// transfer the cap, so no claim can land on the seller's address after
    /// the sale.
    #[test]
    fun a_seller_hands_over_the_payee_with_the_cap() {
        let mut sc = ts::begin(test_world::admin());
        let mut site = setup(&mut sc);
        test_world::register(&mut sc, OWNER, site.character(), &site, OWNER);
        let buyer_character = test_world::create_character(&mut sc, BUYER, 50);

        test_world::hand_over_storage_unit(&mut sc, &mut site, BUYER, BUYER, buyer_character);
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(BUYER));

        // And the buyer now controls it.
        test_world::update(&mut sc, BUYER, buyer_character, &site, PARTNER);
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(PARTNER));
        ts::end(sc);
    }

    /// The same hand-over when the buyer is already the payee: the update is a
    /// no-op, so the cap still transfers in the same transaction.
    #[test]
    fun a_hand_over_to_the_current_payee_still_transfers_the_cap() {
        let mut sc = ts::begin(test_world::admin());
        let mut site = setup(&mut sc);
        test_world::register(&mut sc, OWNER, site.character(), &site, BUYER);
        let buyer_character = test_world::create_character(&mut sc, BUYER, 50);

        test_world::hand_over_storage_unit(&mut sc, &mut site, BUYER, BUYER, buyer_character);
        assert_eq!(event::events_by_type<HubOperatorChanged>().length(), 0);
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(BUYER));

        // The cap reached the buyer.
        test_world::update(&mut sc, BUYER, buyer_character, &site, PARTNER);
        assert_eq!(test_world::beneficiary(&mut sc, site.collection()), option::some(PARTNER));
        ts::end(sc);
    }
}
