/// Operator registry holds where each trade operator's share of the fees earned on it is
/// paid: `collection_id -> address`.
///
/// This is deliberately not a table on `FeePolicy`. The payout address is the one
/// piece of revenue-share configuration a operator operator writes themselves, and
/// `fee_policy`'s module invariant is that nothing on a user-reachable path may
/// ever take it `&mut` — every trade on the exchange reads that object
/// immutably, and immutable reads of a shared object commute while a write does
/// not. Rotations belong on an object no trade touches.
///
/// Keying by collection rather than by pool is what keeps a rotation one write.
/// A storage unit mints exactly one multicoin `Collection`, but trades one pool
/// per (asset, quote) pair — so an operator with a broad inventory would
/// otherwise have to rotate dozens of pools in step, with a window in which half
/// of them pay the old address.
///
/// Writes are admin-only for now. The operator-facing path — a witness minted by
/// an adapter package that checks the caller's `OwnerCap<StorageUnit>` against
/// the collection — lands separately, so it can be reviewed as an authorization
/// change rather than as a rider on fee accounting.
module triex::operator_registry {
    use std::type_name::{Self, TypeName};
    use sui::{event, table::{Self, Table}};
    use triex::registry::TriexAdminCap;

    // === Errors ===
    const ENoAuthorizedAdapter: u64 = 0;
    const EUnauthorizedAdapter: u64 = 1;

    // === Structs ===
    public struct OperatorRegistry has key {
        id: UID,
        /// collection_id -> the address that collection's share is paid to.
        /// Absent means nothing has been configured, and a claim aborts rather
        /// than guessing.
        beneficiaries: Table<ID, address>,
        /// The one witness type allowed to rotate a beneficiary without the admin
        /// cap. `none` until an adapter is registered, which is the shipping state:
        /// self-service is opt-in, not on by default.
        authorized_adapter: Option<TypeName>,
    }

    // === Events ===
    public struct OperatorBeneficiarySet has copy, drop {
        collection_id: ID,
        beneficiary: address,
        /// False when the admin cap set it, true when a registered adapter did.
        /// An operator auditing their own operator wants to see which.
        by_adapter: bool,
    }

    public struct OperatorBeneficiaryCleared has copy, drop {
        collection_id: ID,
    }

    public struct OperatorAdapterAuthorized has copy, drop {
        adapter: Option<TypeName>,
    }

    // === Init ===
    fun init(ctx: &mut TxContext) {
        transfer::share_object(OperatorRegistry {
            id: object::new(ctx),
            beneficiaries: table::new(ctx),
            authorized_adapter: option::none(),
        });
    }

    // === Public-Mutative Functions * ADMIN * ===
    /// Set where a collection's operator share is paid.
    ///
    /// Note what this does *not* do: it does not move an already-accrued balance.
    /// A claim pays whoever is configured at claim time, so rotating between an
    /// accrual and a claim pays the new address for revenue the old one hosted.
    /// That is a settlement question between the two parties, and the accrual
    /// events are the record of it — the contract cannot arbitrate a operator sale it
    /// has no way to observe.
    public fun set_beneficiary(
        self: &mut OperatorRegistry,
        collection_id: ID,
        beneficiary: address,
        _cap: &TriexAdminCap,
    ) {
        self.write_beneficiary(collection_id, beneficiary, false);
    }

    /// Register the one witness type allowed to rotate a beneficiary without the
    /// admin cap, replacing any previous registration.
    ///
    /// The type is what makes the gate real. A bare `<W: drop>` bound authorizes
    /// nothing — any package can declare a struct with `drop` and mint one — so a
    /// witness only proves anything if the callee pins which type it will accept.
    /// Pinning it by `TypeName` rather than by importing the adapter keeps Triex
    /// free of any dependency on the game world: it compares a name, it does not
    /// link a module.
    public fun set_authorized_adapter<W: drop>(
        self: &mut OperatorRegistry,
        _cap: &TriexAdminCap,
    ) {
        let adapter = type_name::with_defining_ids<W>();
        self.authorized_adapter = option::some(adapter);
        event::emit(OperatorAdapterAuthorized { adapter: option::some(adapter) });
    }

    /// Withdraw self-service, leaving the admin cap as the only way to rotate.
    public fun clear_authorized_adapter(self: &mut OperatorRegistry, _cap: &TriexAdminCap) {
        self.authorized_adapter = option::none();
        event::emit(OperatorAdapterAuthorized { adapter: option::none() });
    }

    // === Public-Mutative Functions * OPERATOR SELF-SERVICE ===

    /// Rotate a collection's payout address on presentation of the registered
    /// adapter's witness.
    ///
    /// **What this trusts, stated plainly.** The witness proves the call came
    /// *through* the registered adapter. It does not prove anything about
    /// `collection_id`, because a witness cannot carry a payload Triex could
    /// verify — a struct is constructible only in its defining module, so any
    /// field Triex could read is a field the adapter alone can set, and reading it
    /// would be trusting the adapter anyway.
    ///
    /// So the binding is the adapter's job: it takes the caller's
    /// `OwnerCap<StorageUnit>` and the `VaultConfig`, checks
    /// `is_authorized(cap, vault_config.storage_unit_id())` and that the config's
    /// collection is the one being rotated, and only then mints the witness. That
    /// logic is what the admin audits before registering it, which is why
    /// registration is admin-only, single-valued, and revocable.
    ///
    /// The reach is bounded even so: an adapter can only move *where* a share is
    /// paid. It cannot change a rate, reach the reserve, or touch a balance already
    /// settled into `operator_owed` — the worst a compromised adapter redirects is
    /// future claims, and `clear_authorized_adapter` stops it.
    public fun set_beneficiary_with_witness<W: drop>(
        self: &mut OperatorRegistry,
        collection_id: ID,
        beneficiary: address,
        _witness: W,
    ) {
        assert!(self.authorized_adapter.is_some(), ENoAuthorizedAdapter);
        assert!(
            self.authorized_adapter.borrow() == type_name::with_defining_ids<W>(),
            EUnauthorizedAdapter,
        );

        self.write_beneficiary(collection_id, beneficiary, true);
    }

    fun write_beneficiary(
        self: &mut OperatorRegistry,
        collection_id: ID,
        beneficiary: address,
        by_adapter: bool,
    ) {
        if (self.beneficiaries.contains(collection_id)) {
            *self.beneficiaries.borrow_mut(collection_id) = beneficiary;
        } else {
            self.beneficiaries.add(collection_id, beneficiary);
        };

        event::emit(OperatorBeneficiarySet { collection_id, beneficiary, by_adapter });
    }

    /// Stop paying a collection. Accrual continues — the basis is a property of
    /// the pool, not of the configuration — so restoring a beneficiary restores
    /// the claim, up to the basis window.
    public fun clear_beneficiary(
        self: &mut OperatorRegistry,
        collection_id: ID,
        _cap: &TriexAdminCap,
    ) {
        if (self.beneficiaries.contains(collection_id)) {
            self.beneficiaries.remove(collection_id);
            event::emit(OperatorBeneficiaryCleared { collection_id });
        };
    }

    // === Public-View Functions ===
    public fun beneficiary(self: &OperatorRegistry, collection_id: ID): Option<address> {
        if (self.beneficiaries.contains(collection_id)) {
            option::some(*self.beneficiaries.borrow(collection_id))
        } else {
            option::none()
        }
    }

    public fun has_beneficiary(self: &OperatorRegistry, collection_id: ID): bool {
        self.beneficiaries.contains(collection_id)
    }

    /// The registered adapter type, if self-service is enabled.
    public fun authorized_adapter(self: &OperatorRegistry): Option<TypeName> {
        self.authorized_adapter
    }

    // === Test Functions ===
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
