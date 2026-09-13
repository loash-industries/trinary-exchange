/// Hub registry holds where each trade hub's share of the fees earned on it is
/// paid: `collection_id -> address`.
///
/// This is deliberately not a table on `FeePolicy`. The payout address is the one
/// piece of revenue-share configuration a hub operator writes themselves, and
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
module triex::hub_registry {
    use sui::{event, table::{Self, Table}};
    use triex::registry::TriexAdminCap;

    // === Structs ===
    public struct HubRegistry has key {
        id: UID,
        /// collection_id -> the address that collection's share is paid to.
        /// Absent means nothing has been configured, and a claim aborts rather
        /// than guessing.
        beneficiaries: Table<ID, address>,
    }

    // === Events ===
    public struct HubBeneficiarySet has copy, drop {
        collection_id: ID,
        beneficiary: address,
    }

    public struct HubBeneficiaryCleared has copy, drop {
        collection_id: ID,
    }

    // === Init ===
    fun init(ctx: &mut TxContext) {
        transfer::share_object(HubRegistry {
            id: object::new(ctx),
            beneficiaries: table::new(ctx),
        });
    }

    // === Public-Mutative Functions * ADMIN * ===
    /// Set where a collection's hub share is paid.
    ///
    /// Note what this does *not* do: it does not move an already-accrued balance.
    /// A claim pays whoever is configured at claim time, so rotating between an
    /// accrual and a claim pays the new address for revenue the old one hosted.
    /// That is a settlement question between the two parties, and the accrual
    /// events are the record of it — the contract cannot arbitrate a hub sale it
    /// has no way to observe.
    public fun set_beneficiary(
        self: &mut HubRegistry,
        collection_id: ID,
        beneficiary: address,
        _cap: &TriexAdminCap,
    ) {
        if (self.beneficiaries.contains(collection_id)) {
            *self.beneficiaries.borrow_mut(collection_id) = beneficiary;
        } else {
            self.beneficiaries.add(collection_id, beneficiary);
        };

        event::emit(HubBeneficiarySet { collection_id, beneficiary });
    }

    /// Stop paying a collection. Accrual continues — the basis is a property of
    /// the pool, not of the configuration — so restoring a beneficiary restores
    /// the claim, up to the basis window.
    public fun clear_beneficiary(
        self: &mut HubRegistry,
        collection_id: ID,
        _cap: &TriexAdminCap,
    ) {
        if (self.beneficiaries.contains(collection_id)) {
            self.beneficiaries.remove(collection_id);
            event::emit(HubBeneficiaryCleared { collection_id });
        };
    }

    // === Public-View Functions ===
    public fun beneficiary(self: &HubRegistry, collection_id: ID): Option<address> {
        if (self.beneficiaries.contains(collection_id)) {
            option::some(*self.beneficiaries.borrow(collection_id))
        } else {
            option::none()
        }
    }

    public fun has_beneficiary(self: &HubRegistry, collection_id: ID): bool {
        self.beneficiaries.contains(collection_id)
    }

    // === Test Functions ===
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
