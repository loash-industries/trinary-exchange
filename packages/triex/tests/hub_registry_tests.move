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
