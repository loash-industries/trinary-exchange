/// The operator adapter `triex::fee_policy` trusts to say who a collection's
/// hub share is paid to.
///
/// `FeePolicy` records a `collection_id -> address` payout mapping, written and
/// re-pointed only through a witness of the single adapter type the admin
/// pinned with `set_operator_adapter`. The witness proves nothing by itself —
/// Triex cannot read a payload off it — so the binding between the collection
/// and the person writing is checked here, on every write, before
/// `HubAdapterWitness` is minted:
///
/// - the `VaultConfig` is the warehouse_receipts config for the collection, and
///   it names the storage unit it was initialized for (vault creation is itself
///   `OwnerCap`-gated, so the pair cannot be forged);
/// - the `StorageUnit` passed is that storage unit;
/// - the caller's `OwnerCap<StorageUnit>` is *the* cap the storage unit
///   records (`owner_cap_id`), not merely one authorized for it — world lets an
///   AdminACL sponsor mint further caps for any object, and those must not be
///   able to re-point a hub's revenue.
///
/// `collection_id` is read off the config rather than taken as an argument, so
/// there is no way to present one storage unit's cap and write another
/// collection's mapping.
///
/// The cap holder chooses the payout address — themselves, a partner, an
/// armature `TreasuryVault` — and can re-point it at any time. Rotation is what
/// keeps the payee under the *current* owner's control: an `OwnerCap` is
/// transferable, and after a sale the old owner can no longer write while the
/// new one can. The mapping does not follow the cap by itself, and accrued
/// `operator_owed` follows the mapping at claim time, so a clean hand-over is
/// one PTB by the seller: borrow the cap → `update_operator(buyer's address)` →
/// `access::transfer_owner_cap_with_receipt`. A seller who wants the backlog
/// claims every pool first.
///
/// Every write emits an event carrying the storage unit, the vault config, the
/// cap that authorized it and the signer, alongside `fee_policy`'s own
/// `OperatorBeneficiaryRegistered` / `OperatorBeneficiaryChanged`, so a
/// collection's payout history and who authorized each step read off the
/// event stream alone.
///
/// Trust: the canonical-cap holder is the only *user* who can write, but these
/// parties can also re-point a hub, and the guarantee holds only as far as
/// they are trusted:
/// - this package's `UpgradeCap` — the pin is by defining id and survives
///   upgrades, so an upgrade could mint `HubAdapterWitness` freely. Make the
///   package immutable once published and audited, before the admin pins it;
/// - world AdminACL sponsors — `character::update_address` is sponsor-gated,
///   so a sponsor can point the owner's character at itself, borrow the
///   canonical cap and write. `verify_sponsor` accepts the gas sponsor, so a
///   sponsoring service that co-signs arbitrary user PTBs extends this to them;
/// - the warehouse_receipts and world `UpgradeCap`s — the binding rests on
///   `VaultConfig.storage_unit_id` and `StorageUnit.owner_cap_id` never
///   changing, which only their code guarantees.
///
/// Dead end: every write needs the live `StorageUnit` and its canonical cap.
/// Once world unanchors the storage unit or deletes the cap, the collection's
/// payout address is frozen at its last value for good, and if the admin then
/// destroys it, nobody can register again.
///
/// Lifecycle: the pin lives on one `FeePolicy` for good, and it only accepts
/// the world and warehouse_receipts types this package was linked against. An
/// immutable adapter also keeps calling the `fee_policy` version it was linked
/// against. So this package is published and pinned once per `FeePolicy`; a
/// cycle that fresh-publishes triex gets a new `FeePolicy`, and this package is
/// republished against it and pinned there. Fresh-publishing world or
/// warehouse_receipts *without* a fresh triex leaves new storage units unable
/// to register until triex itself is republished or upgraded.
module triex_hub_operator_adapter::hub_adapter {
    use sui::event;
    use triex::fee_policy::FeePolicy;
    use warehouse_receipts::{receipt::PendingVault, vault::VaultConfig};
    use world::{access::OwnerCap, storage_unit::StorageUnit};

    // === Errors ===
    const ENotStorageUnitOwner: u64 = 0;
    const EAlreadyRegistered: u64 = 1;
    const EStorageUnitMismatch: u64 = 2;

    // === Structs ===

    /// The witness `fee_policy::set_operator_adapter` pins. Constructible only
    /// in this module, and only after `assert_storage_unit_owner`.
    public struct HubAdapterWitness has drop {}

    // === Events ===

    /// A collection's first payout address, or its first after an admin
    /// destroy.
    public struct HubOperatorRegistered has copy, drop {
        collection_id: ID,
        storage_unit_id: ID,
        vault_config_id: ID,
        owner_cap_id: ID,
        beneficiary: address,
        registered_by: address,
    }

    /// A registered payout address re-pointed by the storage unit's owner.
    public struct HubOperatorChanged has copy, drop {
        collection_id: ID,
        storage_unit_id: ID,
        vault_config_id: ID,
        owner_cap_id: ID,
        previous: address,
        beneficiary: address,
        changed_by: address,
    }

    // === Public Functions ===

    /// Set the hub-share payout address for the collection `vault_config`
    /// custodies. One registration covers every multicoin pool in the
    /// collection, including pools created later, and releases any share
    /// already accrued on them to the next claim.
    ///
    /// Aborts if an address is already registered — `FeePolicy` would
    /// otherwise keep the first one silently; re-pointing is
    /// `update_operator`.
    public fun register_operator(
        policy: &mut FeePolicy,
        vault_config: &VaultConfig,
        storage_unit: &StorageUnit,
        owner_cap: &OwnerCap<StorageUnit>,
        beneficiary: address,
        ctx: &mut TxContext,
    ) {
        assert_storage_unit_owner(vault_config, storage_unit, owner_cap);

        let collection_id = vault_config.collection_id();
        assert!(policy.operator_beneficiary(collection_id).is_none(), EAlreadyRegistered);

        policy.register_operator_beneficiary_with_witness(
            collection_id,
            beneficiary,
            HubAdapterWitness {},
        );

        event::emit(HubOperatorRegistered {
            collection_id,
            storage_unit_id: vault_config.storage_unit_id(),
            vault_config_id: object::id(vault_config),
            owner_cap_id: object::id(owner_cap),
            beneficiary,
            registered_by: ctx.sender(),
        });
    }

    /// `register_operator` for a vault created earlier in the same PTB by
    /// `warehouse_receipts::receipt::new_vault` and not yet shared — the
    /// storage unit's first-time setup, in one transaction:
    /// `new_vault` → `register_operator_for_new_vault` → `share_vault`.
    public fun register_operator_for_new_vault(
        policy: &mut FeePolicy,
        pending: &PendingVault,
        storage_unit: &StorageUnit,
        owner_cap: &OwnerCap<StorageUnit>,
        beneficiary: address,
        ctx: &mut TxContext,
    ) {
        register_operator(
            policy,
            pending.pending_vault_config(),
            storage_unit,
            owner_cap,
            beneficiary,
            ctx,
        );
    }

    /// Re-point the collection's payout address. Only the current holder of
    /// the storage unit's `OwnerCap` can call it, so after the cap changes
    /// hands the new owner — and only the new owner — can take over the payee.
    ///
    /// `fee_policy` aborts if nothing is registered (registration is
    /// `register_operator`), or if `beneficiary` is already the payee, so every
    /// `HubOperatorChanged` is a real change.
    public fun update_operator(
        policy: &mut FeePolicy,
        vault_config: &VaultConfig,
        storage_unit: &StorageUnit,
        owner_cap: &OwnerCap<StorageUnit>,
        beneficiary: address,
        ctx: &mut TxContext,
    ) {
        assert_storage_unit_owner(vault_config, storage_unit, owner_cap);

        let collection_id = vault_config.collection_id();
        let previous = policy.update_operator_beneficiary_with_witness(
            collection_id,
            beneficiary,
            HubAdapterWitness {},
        );

        event::emit(HubOperatorChanged {
            collection_id,
            storage_unit_id: vault_config.storage_unit_id(),
            vault_config_id: object::id(vault_config),
            owner_cap_id: object::id(owner_cap),
            previous,
            beneficiary,
            changed_by: ctx.sender(),
        });
    }

    // === Private Functions ===

    /// The whole access-control surface: the storage unit is the one the
    /// config was initialized for, and the cap is the one that storage unit
    /// records as its owner's. The canonical cap is authorized for the storage
    /// unit by construction, so no separate `is_authorized` check is needed.
    fun assert_storage_unit_owner(
        vault_config: &VaultConfig,
        storage_unit: &StorageUnit,
        owner_cap: &OwnerCap<StorageUnit>,
    ) {
        assert!(object::id(storage_unit) == vault_config.storage_unit_id(), EStorageUnitMismatch);
        assert!(object::id(owner_cap) == storage_unit.owner_cap_id(), ENotStorageUnitOwner);
    }

    // === Test Functions ===

    #[test_only]
    public fun hub_operator_registered_parts(
        self: &HubOperatorRegistered,
    ): (ID, ID, ID, ID, address, address) {
        (
            self.collection_id,
            self.storage_unit_id,
            self.vault_config_id,
            self.owner_cap_id,
            self.beneficiary,
            self.registered_by,
        )
    }

    #[test_only]
    public fun hub_operator_changed_parts(
        self: &HubOperatorChanged,
    ): (ID, ID, ID, ID, address, address, address) {
        (
            self.collection_id,
            self.storage_unit_id,
            self.vault_config_id,
            self.owner_cap_id,
            self.previous,
            self.beneficiary,
            self.changed_by,
        )
    }
}
