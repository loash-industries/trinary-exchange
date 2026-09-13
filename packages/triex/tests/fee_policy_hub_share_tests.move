/// Tests for the hub-share rate configuration.
///
/// A class is a staged `current`/`next` pair in `ClassSchedule`'s shape. The
/// split is applied at recognition, so the one property that matters is
/// pre-announcement: a staged rate must not apply to the epoch it was written
/// in, and the running rate must not move until the boundary. There is no rate
/// history to keep — nothing ever asks for a past epoch's rate after that
/// epoch's revenue has been recognized.
#[test_only]
module triex::fee_policy_operator_share_tests {
    use std::unit_test::{assert_eq, destroy};
    use sui::test_scenario::{begin, end};
    use triex::{constants, fee_policy::{Self, FeePolicy}, registry};

    const OWNER: address = @0x1;
    const CLASS_STANDARD: u16 = 10;
    const CLASS_PARTNER: u16 = 11;

    fun a_collection(): ID {
        object::id_from_address(@0xC0FFEE)
    }

    fun another_collection(): ID {
        object::id_from_address(@0xDECAF)
    }

    #[test]
    fun unconfigured_resolves_to_zero() {
        // Deploying the ladder has to change nothing. An unassigned collection, an
        // unconfigured class and a default that was never set must all price to
        // zero, so every basis settles to nothing until someone opts a hub in.
        let mut test = begin(OWNER);
        let policy = fee_policy::create_for_testing(test.ctx());

        assert_eq!(policy.operator_share_class(a_collection()), 0);
        assert_eq!(policy.operator_share_bps_at(a_collection(), 0), 0);
        assert_eq!(policy.operator_share_bps_at(a_collection(), 99), 0);

        destroy(policy);
        end(test);
    }

    #[test]
    fun a_staged_rate_does_not_apply_to_the_epoch_it_was_set_in() {
        // The pre-announcement property, stated as a test because `FeePolicy`'s own
        // `cancel_retention_bps` does *not* have it — that field is written
        // unconditionally, so the pattern cannot be inherited by analogy.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_operator_share_class(CLASS_STANDARD, 1_000, &cap, test.ctx());
        policy.assign_operator_share_class(a_collection(), CLASS_STANDARD, &cap);

        // Epoch 0 is the epoch the write happened in: revenue already hosted
        // cannot be re-priced by it.
        assert_eq!(policy.operator_share_bps_at(a_collection(), 0), 0);
        assert_eq!(policy.operator_share_bps_at(a_collection(), 1), 1_000);
        assert_eq!(policy.operator_share_bps_at(a_collection(), 50), 1_000);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun a_reprice_does_not_move_the_running_rate_until_the_boundary() {
        // The promote-then-stage dance: a re-price written mid-epoch must leave
        // the running rate exactly where the operator last read it, and take over
        // only at the next boundary.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_operator_share_class(CLASS_STANDARD, 1_000, &cap, test.ctx());
        policy.assign_operator_share_class(a_collection(), CLASS_STANDARD, &cap);

        test.next_epoch(OWNER); // epoch 1 — 1_000 live
        policy.stage_operator_share_class(CLASS_STANDARD, 2_000, &cap, test.ctx());

        // Still this epoch: the running rate is untouched by the pending stage.
        assert_eq!(policy.operator_share_bps_at(a_collection(), 1), 1_000);
        // Next epoch: the staged rate is the rate.
        assert_eq!(policy.operator_share_bps_at(a_collection(), 2), 2_000);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun restaging_in_the_same_epoch_replaces_the_pending_rate() {
        // Two writes in one epoch: neither has taken effect yet, so the later one
        // wins and the earlier one never applies to anything.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_operator_share_class(CLASS_STANDARD, 1_000, &cap, test.ctx());
        policy.stage_operator_share_class(CLASS_STANDARD, 1_500, &cap, test.ctx());
        policy.stage_operator_share_class(CLASS_STANDARD, 2_500, &cap, test.ctx());
        policy.assign_operator_share_class(a_collection(), CLASS_STANDARD, &cap);

        assert_eq!(policy.operator_share_bps_at(a_collection(), 0), 0);
        assert_eq!(policy.operator_share_bps_at(a_collection(), 1), 2_500);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun classes_are_independent_and_reassignable() {
        // "Configurable per entity" in practice: a standard class, a partner class,
        // and a collection moved between them with one write.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_operator_share_class(CLASS_STANDARD, 1_000, &cap, test.ctx());
        policy.stage_operator_share_class(CLASS_PARTNER, 2_500, &cap, test.ctx());
        policy.assign_operator_share_class(a_collection(), CLASS_STANDARD, &cap);
        policy.assign_operator_share_class(another_collection(), CLASS_PARTNER, &cap);

        assert_eq!(policy.operator_share_bps_at(a_collection(), 1), 1_000);
        assert_eq!(policy.operator_share_bps_at(another_collection(), 1), 2_500);

        policy.assign_operator_share_class(a_collection(), CLASS_PARTNER, &cap);
        assert_eq!(policy.operator_share_bps_at(a_collection(), 1), 2_500);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun the_default_class_catches_unassigned_collections() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_operator_share_class(CLASS_STANDARD, 1_000, &cap, test.ctx());
        policy.set_default_operator_share_class(CLASS_STANDARD, &cap);

        assert_eq!(policy.operator_share_class(another_collection()), CLASS_STANDARD);
        assert_eq!(policy.operator_share_bps_at(another_collection(), 1), 1_000);

        // An explicit assignment still wins over the default.
        policy.stage_operator_share_class(CLASS_PARTNER, 2_500, &cap, test.ctx());
        policy.assign_operator_share_class(another_collection(), CLASS_PARTNER, &cap);
        assert_eq!(policy.operator_share_bps_at(another_collection(), 1), 2_500);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun a_rate_of_zero_is_a_real_setting() {
        // Turning a hub off has to be expressible, and distinguishable from never
        // having configured it only in that the class exists.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_operator_share_class(CLASS_STANDARD, 2_000, &cap, test.ctx());
        policy.assign_operator_share_class(a_collection(), CLASS_STANDARD, &cap);
        test.next_epoch(OWNER);
        policy.stage_operator_share_class(CLASS_STANDARD, 0, &cap, test.ctx());

        assert_eq!(policy.operator_share_bps_at(a_collection(), 1), 2_000);
        assert_eq!(policy.operator_share_bps_at(a_collection(), 2), 0);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EOperatorShareAboveCeiling)]
    fun staging_above_the_ceiling_aborts() {
        // MAX_OPERATOR_SHARE_BPS is a trust commitment stated in CAPABILITIES.md, so the
        // admin cannot exceed it even by mistake.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_operator_share_class(
            CLASS_STANDARD,
            constants::max_operator_share_bps() + 1,
            &cap,
            test.ctx(),
        );

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EOperatorShareClassDoesNotExist)]
    fun assigning_to_a_class_that_does_not_exist_aborts() {
        // Without this the id is simply wrong and resolves to zero, so a mistyped
        // class leaves the hub earning nothing — the one misconfiguration here that
        // produces no error and no event, and surfaces only when an operator asks
        // where their payment went.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.assign_operator_share_class(a_collection(), CLASS_PARTNER, &cap);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EOperatorShareClassDoesNotExist)]
    fun defaulting_to_a_class_that_does_not_exist_aborts() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.set_default_operator_share_class(CLASS_PARTNER, &cap);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun the_ceiling_itself_is_settable() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        let max = constants::max_operator_share_bps();
        policy.stage_operator_share_class(CLASS_STANDARD, max, &cap, test.ctx());
        policy.assign_operator_share_class(a_collection(), CLASS_STANDARD, &cap);
        assert_eq!(policy.operator_share_bps_at(a_collection(), 1), max);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    // === Beneficiary mapping ===

    #[test]
    fun registering_a_beneficiary_is_first_write_wins() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());

        assert_eq!(policy.operator_beneficiary(a_collection()), option::none());

        policy.register_operator_beneficiary_for_testing(a_collection(), @0xB0B);
        assert_eq!(policy.operator_beneficiary(a_collection()), option::some(@0xB0B));

        // A later registration cannot re-point it.
        policy.register_operator_beneficiary_for_testing(a_collection(), @0xBAD);
        assert_eq!(policy.operator_beneficiary(a_collection()), option::some(@0xB0B));

        // And collections are independent.
        assert!(policy.operator_beneficiary(another_collection()).is_none());

        destroy(policy);
        end(test);
    }

    #[test]
    fun destroying_a_beneficiary_removes_it_and_tolerates_absence() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.register_operator_beneficiary_for_testing(a_collection(), @0xB0B);
        policy.destroy_operator_beneficiary(a_collection(), &cap);
        assert_eq!(policy.operator_beneficiary(a_collection()), option::none());

        // Destroying what is not there is a no-op, not an abort — payout
        // tooling must be able to run it idempotently.
        policy.destroy_operator_beneficiary(a_collection(), &cap);
        assert!(policy.operator_beneficiary(a_collection()).is_none());

        // After a destroy, the next registration may pin a fresh address.
        policy.register_operator_beneficiary_for_testing(a_collection(), @0xCAFE);
        assert_eq!(policy.operator_beneficiary(a_collection()), option::some(@0xCAFE));

        destroy(cap);
        destroy(policy);
        end(test);
    }

    // === Adapter witness gate ===

    /// Stands in for the audited adapter package's witness.
    public struct Adapter has drop {}

    /// Any other type with `drop` — what a forger can mint for free.
    public struct Forgery has drop {}

    #[test]
    fun the_registered_witness_registers_set_if_absent() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        assert_eq!(policy.operator_adapter(), option::none());
        policy.set_operator_adapter<Adapter>(&cap);
        assert_eq!(
            policy.operator_adapter(),
            option::some(std::type_name::with_defining_ids<Adapter>()),
        );

        policy.register_operator_beneficiary_with_witness(a_collection(), @0xB0B, Adapter {});
        assert_eq!(policy.operator_beneficiary(a_collection()), option::some(@0xB0B));

        // The gate authorizes the write path, not a re-point: a second witnessed
        // registration is the same set-if-absent as the first.
        policy.register_operator_beneficiary_with_witness(a_collection(), @0xBAD, Adapter {});
        assert_eq!(policy.operator_beneficiary(a_collection()), option::some(@0xB0B));

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = triex::fee_policy::ENoAuthorizedAdapter)]
    fun no_registration_path_exists_until_an_adapter_is_registered() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());

        // The shipping state: no adapter, so no one — witness in hand or not —
        // can write a beneficiary.
        policy.register_operator_beneficiary_with_witness(a_collection(), @0xB0B, Adapter {});

        abort 0
    }

    #[test]
    #[expected_failure(abort_code = triex::fee_policy::EUnauthorizedAdapter)]
    fun a_forged_witness_cannot_register() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.set_operator_adapter<Adapter>(&cap);
        // `drop` is free to declare; only the registered type passes the gate.
        policy.register_operator_beneficiary_with_witness(a_collection(), @0xB0B, Forgery {});

        abort 0
    }

    #[test]
    #[expected_failure(abort_code = triex::fee_policy::ENoAuthorizedAdapter)]
    fun clearing_the_adapter_closes_the_registration_path() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.set_operator_adapter<Adapter>(&cap);
        policy.clear_operator_adapter(&cap);
        assert_eq!(policy.operator_adapter(), option::none());

        policy.register_operator_beneficiary_with_witness(a_collection(), @0xB0B, Adapter {});

        abort 0
    }
}
