/// Shared setup for the adapter suites: a real world (characters, network
/// nodes, storage units, `OwnerCap`s held by characters), real
/// warehouse_receipts vaults, and a triex `FeePolicy` / `Registry` / `Clock`
/// with a multicoin fee class for `HUB_USD`.
///
/// Every cap use goes through `borrow_owner_cap` → … → `return_owner_cap`, the
/// shape the app's PTBs use.
#[test_only]
module triex_hub_operator_adapter::test_world {
    use std::{string::utf8, unit_test};
    use sui::{clock, test_scenario::{Self as ts, Scenario}};
    use triex::{fee_policy::{Self, FeePolicy}, registry::{Self, Registry}};
    use triex_hub_operator_adapter::hub_adapter::{Self, HubAdapterWitness};
    use warehouse_receipts::{receipt::{Self, VaultAuth}, vault::VaultConfig};
    use world::{
        access::{Self, OwnerCap},
        character::{Self, Character},
        energy::EnergyConfig,
        network_node::{Self, NetworkNode},
        object_registry::ObjectRegistry,
        storage_unit::{Self, StorageUnit}
    };

    /// The quote every hub pool here trades in.
    public struct HUB_USD has drop {}

    // World sponsor (`world::test_helpers::admin`); also signs as the Triex admin.
    const ADMIN: address = @0xB;
    // Where the treasury leg of a claim is paid. Signs nothing else.
    const TREASURY: address = @0x7EA5;

    // `world::test_helpers` configures energy for this assembly type.
    const SSU_TYPE_ID: u64 = 5555;
    const NWN_TYPE_ID: u64 = 111000;
    const FUEL_TYPE_ID: u64 = 1;
    const LOCATION_HASH: vector<u8> =
        x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";

    const COIN_CLASS: u16 = 1;
    const MULTICOIN_CLASS: u16 = 2;
    const SIX_DP: u128 = 1_000_000;

    public fun admin(): address { ADMIN }

    public fun treasury(): address { TREASURY }

    /// A storage unit, its network node, and the character holding its cap.
    /// `vault_config` / `collection` are set once its vault is initialized.
    public struct Site has copy, drop {
        owner: address,
        character: ID,
        storage_unit: ID,
        network_node: ID,
        vault_config: Option<ID>,
        collection: Option<ID>,
    }

    public fun character(self: &Site): ID { self.character }

    public fun storage_unit(self: &Site): ID { self.storage_unit }

    public fun vault_config(self: &Site): ID { *self.vault_config.borrow() }

    public fun collection(self: &Site): ID { *self.collection.borrow() }

    // === Bootstrap ===

    /// World, `FeePolicy` (multicoin class for `HUB_USD`), `Registry` with
    /// `TREASURY` as treasury, and a shared `Clock`.
    public fun setup(sc: &mut Scenario) {
        world::test_helpers::setup_world(sc);
        world::test_helpers::configure_assembly_energy(sc);
        world::test_helpers::register_server_address(sc);

        ts::next_tx(sc, ADMIN);
        {
            let mut policy = fee_policy::create_for_testing(sc.ctx());
            let cap = registry::get_admin_cap_for_testing(sc.ctx());
            policy.bootstrap_quote<HUB_USD>(COIN_CLASS, MULTICOIN_CLASS, SIX_DP, &cap, sc.ctx());
            policy.share_for_testing();
            unit_test::destroy(cap);
            clock::create_for_testing(sc.ctx()).share_for_testing();
        };

        // `test_registry` makes its sender the treasury.
        ts::next_tx(sc, TREASURY);
        registry::test_registry(sc.ctx());

        ts::next_tx(sc, ADMIN);
        {
            let mut reg = ts::take_shared<Registry>(sc);
            let cap = registry::get_admin_cap_for_testing(sc.ctx());
            reg.add_approved_quote_unchecked<HUB_USD>(&cap);
            unit_test::destroy(cap);
            ts::return_shared(reg);
        };
    }

    /// A character for `owner`. `seed` keeps in-game item ids distinct.
    public fun create_character(sc: &mut Scenario, owner: address, seed: u64): ID {
        ts::next_tx(sc, ADMIN);
        let admin_acl = ts::take_shared<world::access::AdminACL>(sc);
        let mut registry = ts::take_shared<ObjectRegistry>(sc);
        let character = character::create_character(
            &mut registry,
            &admin_acl,
            (1000 + seed) as u32,
            utf8(b"tenant"),
            100,
            owner,
            utf8(b"name"),
            sc.ctx(),
        );
        let id = object::id(&character);
        character.share_character(&admin_acl, sc.ctx());
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
        id
    }

    /// A storage unit owned by a fresh character of `owner`, with no vault.
    /// `online` fuels its network node and brings both online, which deposits
    /// need.
    public fun create_site(sc: &mut Scenario, owner: address, seed: u64, online: bool): Site {
        let character_id = create_character(sc, owner, seed);
        let site = create_site_for(sc, owner, character_id, seed);
        if (online) bring_online(sc, &site);
        site
    }

    /// Another storage unit for an existing character (offline, no vault).
    public fun create_site_for(sc: &mut Scenario, owner: address, character_id: ID, seed: u64): Site {
        ts::next_tx(sc, ADMIN);
        let (storage_unit_id, nwn_id) = {
            let admin_acl = ts::take_shared<world::access::AdminACL>(sc);
            let mut registry = ts::take_shared<ObjectRegistry>(sc);
            let character = ts::take_shared_by_id<Character>(sc, character_id);
            let mut nwn = network_node::anchor(
                &mut registry,
                &character,
                &admin_acl,
                5000 + seed,
                NWN_TYPE_ID,
                LOCATION_HASH,
                1000,
                3_600_000,
                100,
                sc.ctx(),
            );
            let storage_unit = storage_unit::anchor(
                &mut registry,
                &mut nwn,
                &character,
                &admin_acl,
                90000 + seed,
                SSU_TYPE_ID,
                100_000_000,
                LOCATION_HASH,
                sc.ctx(),
            );
            let storage_unit_id = object::id(&storage_unit);
            let nwn_id = object::id(&nwn);
            storage_unit.share_storage_unit(&admin_acl, sc.ctx());
            nwn.share_network_node(&admin_acl, sc.ctx());
            ts::return_shared(character);
            ts::return_shared(registry);
            ts::return_shared(admin_acl);
            (storage_unit_id, nwn_id)
        };

        Site {
            owner,
            character: character_id,
            storage_unit: storage_unit_id,
            network_node: nwn_id,
            vault_config: option::none(),
            collection: option::none(),
        }
    }

    fun bring_online(sc: &mut Scenario, site: &Site) {
        let clock = clock::create_for_testing(sc.ctx());
        ts::next_tx(sc, site.owner);
        let mut character = ts::take_shared_by_id<Character>(sc, site.character);
        {
            let (nwn_cap, receipt) = character.borrow_owner_cap<NetworkNode>(
                ts::most_recent_receiving_ticket<OwnerCap<NetworkNode>>(&site.character),
                sc.ctx(),
            );
            let mut nwn = ts::take_shared_by_id<NetworkNode>(sc, site.network_node);
            nwn.deposit_fuel_test(&nwn_cap, FUEL_TYPE_ID, 10, 10, &clock);
            nwn.online(&nwn_cap, &clock);
            character.return_owner_cap(nwn_cap, receipt);
            ts::return_shared(nwn);
        };
        ts::return_shared(character);

        ts::next_tx(sc, site.owner);
        let mut character = ts::take_shared_by_id<Character>(sc, site.character);
        {
            let (cap, receipt) = borrow_storage_unit_cap(sc, &mut character, site.character);
            let mut storage_unit = ts::take_shared_by_id<StorageUnit>(sc, site.storage_unit);
            let mut nwn = ts::take_shared_by_id<NetworkNode>(sc, site.network_node);
            let energy_config = ts::take_shared<EnergyConfig>(sc);
            storage_unit.online(&mut nwn, &energy_config, &cap);
            character.return_owner_cap(cap, receipt);
            ts::return_shared(energy_config);
            ts::return_shared(nwn);
            ts::return_shared(storage_unit);
        };
        ts::return_shared(character);
        clock.destroy_for_testing();
    }

    /// The existing two-step setup: `initialize_vault` and the extension
    /// authorization, with no registration.
    public fun initialize_vault(sc: &mut Scenario, site: &mut Site) {
        ts::next_tx(sc, site.owner);
        let mut character = ts::take_shared_by_id<Character>(sc, site.character);
        let (cap, receipt) = borrow_storage_unit_cap(sc, &mut character, site.character);
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(sc, site.storage_unit);
        receipt::initialize_vault(&storage_unit, &cap, sc.ctx());
        storage_unit.authorize_extension<VaultAuth>(&cap);
        character.return_owner_cap(cap, receipt);
        ts::return_shared(storage_unit);
        ts::return_shared(character);

        record_vault(sc, site);
    }

    /// The first-time setup PTB the app sends: `new_vault`, authorize the
    /// extension, register `beneficiary` against the unshared vault, then
    /// `share_vault` — one transaction, one signature.
    public fun initialize_vault_and_register(sc: &mut Scenario, site: &mut Site, beneficiary: address) {
        initialize_vault_and_register_only(sc, site, beneficiary);
        record_vault(sc, site);
    }

    /// The setup PTB alone, leaving its events readable to the caller; follow
    /// with `record_vault`.
    public fun initialize_vault_and_register_only(sc: &mut Scenario, site: &Site, beneficiary: address) {
        ts::next_tx(sc, site.owner);
        let mut character = ts::take_shared_by_id<Character>(sc, site.character);
        let (cap, receipt) = borrow_storage_unit_cap(sc, &mut character, site.character);
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(sc, site.storage_unit);
        let mut policy = ts::take_shared<FeePolicy>(sc);

        let pending = receipt::new_vault(&storage_unit, &cap, sc.ctx());
        storage_unit.authorize_extension<VaultAuth>(&cap);
        hub_adapter::register_operator_for_new_vault(
            &mut policy,
            &pending,
            &storage_unit,
            &cap,
            beneficiary,
            sc.ctx(),
        );
        pending.share_vault();

        character.return_owner_cap(cap, receipt);
        ts::return_shared(policy);
        ts::return_shared(storage_unit);
        ts::return_shared(character);
    }

    /// Pick up the vault the previous transaction shared. Only one vault is
    /// created per transaction, so the most recent of each type is this one.
    public fun record_vault(sc: &mut Scenario, site: &mut Site) {
        ts::next_tx(sc, site.owner);
        let config = ts::take_shared<VaultConfig>(sc);
        assert!(config.storage_unit_id() == site.storage_unit);
        site.vault_config = option::some(object::id(&config));
        site.collection = option::some(config.collection_id());
        ts::return_shared(config);
    }

    // === Adapter calls, as the cap holder's PTB makes them ===

    /// What the admin does once per `FeePolicy`, after publishing the adapter.
    public fun pin_adapter(sc: &mut Scenario) {
        ts::next_tx(sc, ADMIN);
        let mut policy = ts::take_shared<FeePolicy>(sc);
        let cap = registry::get_admin_cap_for_testing(sc.ctx());
        policy.set_operator_adapter<HubAdapterWitness>(&cap);
        unit_test::destroy(cap);
        ts::return_shared(policy);
    }

    public fun clear_adapter(sc: &mut Scenario) {
        ts::next_tx(sc, ADMIN);
        let mut policy = ts::take_shared<FeePolicy>(sc);
        let cap = registry::get_admin_cap_for_testing(sc.ctx());
        policy.clear_operator_adapter(&cap);
        unit_test::destroy(cap);
        ts::return_shared(policy);
    }

    public fun destroy_beneficiary(sc: &mut Scenario, collection_id: ID) {
        ts::next_tx(sc, ADMIN);
        let mut policy = ts::take_shared<FeePolicy>(sc);
        let cap = registry::get_admin_cap_for_testing(sc.ctx());
        policy.destroy_operator_beneficiary(collection_id, &cap);
        unit_test::destroy(cap);
        ts::return_shared(policy);
    }

    /// `caller` borrows the storage unit cap held by character `cap_holder`
    /// and calls `register_operator` with `config_of`'s `VaultConfig` and
    /// storage unit.
    public fun register(
        sc: &mut Scenario,
        caller: address,
        cap_holder: ID,
        config_of: &Site,
        beneficiary: address,
    ) {
        write(sc, caller, cap_holder, config_of, config_of.storage_unit, beneficiary, false)
    }

    /// As `register`, but `update_operator`.
    public fun update(
        sc: &mut Scenario,
        caller: address,
        cap_holder: ID,
        config_of: &Site,
        beneficiary: address,
    ) {
        write(sc, caller, cap_holder, config_of, config_of.storage_unit, beneficiary, true)
    }

    /// As `register` / `update`, but presenting `storage_unit` rather than the
    /// config's own.
    public fun write_at(
        sc: &mut Scenario,
        caller: address,
        cap_holder: ID,
        config_of: &Site,
        storage_unit: ID,
        beneficiary: address,
        rotate: bool,
    ) {
        write(sc, caller, cap_holder, config_of, storage_unit, beneficiary, rotate)
    }

    fun write(
        sc: &mut Scenario,
        caller: address,
        cap_holder: ID,
        config_of: &Site,
        storage_unit_id: ID,
        beneficiary: address,
        rotate: bool,
    ) {
        ts::next_tx(sc, caller);
        let mut policy = ts::take_shared<FeePolicy>(sc);
        let mut character = ts::take_shared_by_id<Character>(sc, cap_holder);
        let config = ts::take_shared_by_id<VaultConfig>(sc, config_of.vault_config());
        let storage_unit = ts::take_shared_by_id<StorageUnit>(sc, storage_unit_id);
        let (cap, receipt) = borrow_storage_unit_cap(sc, &mut character, cap_holder);

        call_adapter(&mut policy, &config, &storage_unit, &cap, beneficiary, rotate, sc.ctx());

        character.return_owner_cap(cap, receipt);
        ts::return_shared(storage_unit);
        ts::return_shared(config);
        ts::return_shared(character);
        ts::return_shared(policy);
    }

    /// A world sponsor mints a second `OwnerCap<StorageUnit>` for `site`'s
    /// storage unit (`create_owner_cap_by_id` is gated only on the sponsor)
    /// and hands it to `holder`, who calls the adapter with it.
    public fun write_with_duplicate_cap(
        sc: &mut Scenario,
        holder: address,
        site: &Site,
        beneficiary: address,
        rotate: bool,
    ) {
        ts::next_tx(sc, ADMIN);
        {
            let admin_acl = ts::take_shared<world::access::AdminACL>(sc);
            let cap = access::create_owner_cap_by_id<StorageUnit>(
                site.storage_unit,
                &admin_acl,
                sc.ctx(),
            );
            assert!(access::is_authorized(&cap, site.storage_unit));
            access::transfer_owner_cap(cap, holder);
            ts::return_shared(admin_acl);
        };

        ts::next_tx(sc, holder);
        let mut policy = ts::take_shared<FeePolicy>(sc);
        let config = ts::take_shared_by_id<VaultConfig>(sc, site.vault_config());
        let storage_unit = ts::take_shared_by_id<StorageUnit>(sc, site.storage_unit);
        let cap = ts::take_from_sender<OwnerCap<StorageUnit>>(sc);

        call_adapter(&mut policy, &config, &storage_unit, &cap, beneficiary, rotate, sc.ctx());

        ts::return_to_sender(sc, cap);
        ts::return_shared(storage_unit);
        ts::return_shared(config);
        ts::return_shared(policy);
    }

    fun call_adapter(
        policy: &mut FeePolicy,
        config: &VaultConfig,
        storage_unit: &StorageUnit,
        cap: &OwnerCap<StorageUnit>,
        beneficiary: address,
        rotate: bool,
        ctx: &mut TxContext,
    ) {
        if (rotate) {
            hub_adapter::update_operator(policy, config, storage_unit, cap, beneficiary, ctx);
        } else {
            hub_adapter::register_operator(policy, config, storage_unit, cap, beneficiary, ctx);
        };
    }

    /// The cap id `site`'s storage unit records as its owner's.
    public fun owner_cap_id(sc: &mut Scenario, site: &Site): ID {
        ts::next_tx(sc, ADMIN);
        let storage_unit = ts::take_shared_by_id<StorageUnit>(sc, site.storage_unit);
        let id = storage_unit.owner_cap_id();
        ts::return_shared(storage_unit);
        id
    }

    /// Hand the storage unit's `OwnerCap` from `site`'s character to
    /// character `buyer` — a sale of the structure.
    public fun transfer_storage_unit(sc: &mut Scenario, site: &mut Site, buyer: address, buyer_character: ID) {
        ts::next_tx(sc, site.owner);
        let mut character = ts::take_shared_by_id<Character>(sc, site.character);
        let (cap, receipt) = borrow_storage_unit_cap(sc, &mut character, site.character);
        access::transfer_owner_cap_with_receipt(
            cap,
            receipt,
            object::id_to_address(&buyer_character),
            sc.ctx(),
        );
        ts::return_shared(character);

        site.owner = buyer;
        site.character = buyer_character;
    }

    public fun beneficiary(sc: &mut Scenario, collection_id: ID): Option<address> {
        ts::next_tx(sc, ADMIN);
        let policy = ts::take_shared<FeePolicy>(sc);
        let beneficiary = policy.operator_beneficiary(collection_id);
        ts::return_shared(policy);
        beneficiary
    }

    fun borrow_storage_unit_cap(
        sc: &mut Scenario,
        character: &mut Character,
        character_id: ID,
    ): (OwnerCap<StorageUnit>, world::access::ReturnOwnerCapReceipt) {
        character.borrow_owner_cap<StorageUnit>(
            ts::most_recent_receiving_ticket<OwnerCap<StorageUnit>>(&character_id),
            sc.ctx(),
        )
    }
}
