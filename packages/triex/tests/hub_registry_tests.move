/// Tests for the hub beneficiary registry.
///
/// The registry is a separate shared object rather than a table on `FeePolicy`,
/// because the payout address is the one piece of this configuration an operator
/// eventually writes themselves and `fee_policy`'s module invariant forbids a
/// user-reachable `&mut` on the object every trade reads. These pin the behaviour
/// a claim depends on: a missing address is a distinct state from a zero rate,
/// and rotating does not move money that has already accrued.
#[test_only]
module triex::hub_registry_tests {
    use std::unit_test::{assert_eq, destroy};
    use sui::test_scenario::{begin, end, return_shared};
    use triex::{hub_registry::{Self, HubRegistry}, registry};

    const OWNER: address = @0x1;
    const ALICE: address = @0xA;
    const BOB: address = @0xB;
    const ATTACKER: address = @0xBAD;

    /// Stands in for the real adapter: the package the admin audits and registers,
    /// which checks the caller's `OwnerCap<StorageUnit>` against the collection
    /// before minting this.
    public struct AdapterWitness has drop {}

    /// Stands in for anyone else's. This is the whole content of the original
    /// finding: `drop` is not a permission, so any package can declare one of
    /// these, and a gate that accepts any `W: drop` accepts this too.
    public struct ForgedWitness has drop {}

    fun a_collection(): ID {
        object::id_from_address(@0xC0FFEE)
    }

    fun another_collection(): ID {
        object::id_from_address(@0xDECAF)
    }

    fun with_registry(test: &mut sui::test_scenario::Scenario): HubRegistry {
        hub_registry::init_for_testing(test.ctx());
        test.next_tx(OWNER);
        test.take_shared<HubRegistry>()
    }

    #[test]
    fun starts_with_nothing_configured() {
        // An unconfigured hub must be distinguishable from one configured at zero:
        // a claim aborts on the first and pays nothing on the second, and conflating
        // them would send an operator's accrual somewhere by default.
        let mut test = begin(OWNER);
        let reg = with_registry(&mut test);

        assert!(!reg.has_beneficiary(a_collection()));
        assert!(reg.beneficiary(a_collection()).is_none());

        return_shared(reg);
        end(test);
    }

    #[test]
    fun set_then_read_back() {
        let mut test = begin(OWNER);
        let mut reg = with_registry(&mut test);
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        reg.set_beneficiary(a_collection(), ALICE, &cap);

        assert!(reg.has_beneficiary(a_collection()));
        assert_eq!(reg.beneficiary(a_collection()).destroy_some(), ALICE);
        // Independent keys: configuring one hub must not configure another.
        assert!(reg.beneficiary(another_collection()).is_none());

        destroy(cap);
        return_shared(reg);
        end(test);
    }

    #[test]
    fun setting_again_rotates_in_place() {
        // Rotation is one write per hub — which is why the key is the collection and
        // not the pool. Keyed per pool, a broad-inventory operator would rotate
        // dozens of objects with a window where half still pay the old address.
        let mut test = begin(OWNER);
        let mut reg = with_registry(&mut test);
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        reg.set_beneficiary(a_collection(), ALICE, &cap);
        reg.set_beneficiary(a_collection(), BOB, &cap);

        assert_eq!(reg.beneficiary(a_collection()).destroy_some(), BOB);

        destroy(cap);
        return_shared(reg);
        end(test);
    }

    // === Operator self-service ===

    #[test]
    fun a_registered_adapters_witness_rotates_the_beneficiary() {
        let mut test = begin(OWNER);
        let mut reg = with_registry(&mut test);
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        reg.set_beneficiary(a_collection(), ALICE, &cap);
        reg.set_authorized_adapter<AdapterWitness>(&cap);

        // No admin cap in this call — the operator is rotating their own hub.
        test.next_tx(ALICE);
        reg.set_beneficiary_with_witness(a_collection(), BOB, AdapterWitness {});

        assert_eq!(reg.beneficiary(a_collection()).destroy_some(), BOB);

        destroy(cap);
        return_shared(reg);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = hub_registry::EUnauthorizedAdapter)]
    fun a_forged_witness_cannot_rotate_the_beneficiary() {
        // The finding this gate exists for. With a bare `<W: drop>` bound and no
        // registered type, `ForgedWitness` is indistinguishable from the real one —
        // anyone publishes a `drop` struct and redirects any hub's payouts to
        // themselves. Pinning the `TypeName` is what turns the bound into a check.
        let mut test = begin(OWNER);
        let mut reg = with_registry(&mut test);
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        reg.set_beneficiary(a_collection(), ALICE, &cap);
        reg.set_authorized_adapter<AdapterWitness>(&cap);

        test.next_tx(ATTACKER);
        reg.set_beneficiary_with_witness(a_collection(), ATTACKER, ForgedWitness {});

        destroy(cap);
        return_shared(reg);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = hub_registry::ENoAuthorizedAdapter)]
    fun no_witness_is_accepted_before_an_adapter_is_registered() {
        // Self-service is opt-in. Until the admin has audited and registered an
        // adapter, the witness path is closed to every type including the eventual
        // real one — so shipping the registry does not ship a rotation surface.
        let mut test = begin(OWNER);
        let mut reg = with_registry(&mut test);

        test.next_tx(ALICE);
        reg.set_beneficiary_with_witness(a_collection(), BOB, AdapterWitness {});

        return_shared(reg);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = hub_registry::EUnauthorizedAdapter)]
    fun revoking_an_adapter_closes_the_path_it_opened() {
        // The containment on a compromised adapter: registration is revocable, and
        // revoking it stops future rotations without touching anything already
        // accrued or settled.
        let mut test = begin(OWNER);
        let mut reg = with_registry(&mut test);
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        reg.set_authorized_adapter<AdapterWitness>(&cap);
        reg.clear_authorized_adapter(&cap);
        reg.set_authorized_adapter<ForgedWitness>(&cap);

        // Re-registering a *different* type also revokes the first: the field holds
        // one type, not a set, so there is no accumulating list of past adapters.
        test.next_tx(ALICE);
        reg.set_beneficiary_with_witness(a_collection(), BOB, AdapterWitness {});

        destroy(cap);
        return_shared(reg);
        end(test);
    }

    #[test]
    fun the_admin_override_survives_self_service() {
        // `delete_owner_cap` is sponsor-callable in world-contracts, so an operator
        // can lose the cap the adapter checks and be unable to rotate ever again
        // while a stale address keeps collecting. The admin path has to remain.
        let mut test = begin(OWNER);
        let mut reg = with_registry(&mut test);
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        reg.set_authorized_adapter<AdapterWitness>(&cap);
        reg.set_beneficiary(a_collection(), ALICE, &cap);

        assert_eq!(reg.beneficiary(a_collection()).destroy_some(), ALICE);
        assert!(reg.authorized_adapter().is_some());

        destroy(cap);
        return_shared(reg);
        end(test);
    }

    #[test]
    fun clearing_returns_to_unconfigured() {
        let mut test = begin(OWNER);
        let mut reg = with_registry(&mut test);
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        reg.set_beneficiary(a_collection(), ALICE, &cap);
        reg.clear_beneficiary(a_collection(), &cap);

        assert!(!reg.has_beneficiary(a_collection()));

        // Idempotent: clearing what was never set is not an error, so a cleanup
        // script does not need to probe first.
        reg.clear_beneficiary(another_collection(), &cap);
        assert!(!reg.has_beneficiary(another_collection()));

        destroy(cap);
        return_shared(reg);
        end(test);
    }
}
