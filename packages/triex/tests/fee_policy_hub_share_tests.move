/// Tests for the hub-share rate ladder.
///
/// The ladder is append-only rather than the `current`/`next` pair a
/// `ClassSchedule` keeps, and these pin the two properties that buys: a rate is
/// pre-announced before it can apply, and a past epoch's rate is still
/// answerable after later re-prices. The second is what makes a late settlement
/// produce the same number as a prompt one — and therefore what stops
/// permissionless settlement from being a free option on every staged change.
#[test_only]
module triex::fee_policy_hub_share_tests {
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

        assert_eq!(policy.hub_share_class(a_collection()), 0);
        assert_eq!(policy.hub_share_bps_at(a_collection(), 0), 0);
        assert_eq!(policy.hub_share_bps_at(a_collection(), 99), 0);

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

        policy.stage_hub_share_class(CLASS_STANDARD, 1_000, &cap, test.ctx());
        policy.assign_hub_share_class(a_collection(), CLASS_STANDARD, &cap);

        // Epoch 0 is the epoch the write happened in: revenue already hosted
        // cannot be re-priced by it.
        assert_eq!(policy.hub_share_bps_at(a_collection(), 0), 0);
        assert_eq!(policy.hub_share_bps_at(a_collection(), 1), 1_000);
        assert_eq!(policy.hub_share_bps_at(a_collection(), 50), 1_000);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun every_past_rate_stays_answerable_after_later_reprices() {
        // The defect this ladder exists to avoid. A two-slot `current`/`next` pair
        // loses epoch 1's rate the moment a second re-price lands — and settlement
        // may legitimately lag by up to the basis window, so that is exactly when
        // it gets asked.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_hub_share_class(CLASS_STANDARD, 1_000, &cap, test.ctx());
        policy.assign_hub_share_class(a_collection(), CLASS_STANDARD, &cap);

        test.next_epoch(OWNER); // epoch 1 — 1_000 live
        policy.stage_hub_share_class(CLASS_STANDARD, 2_000, &cap, test.ctx());
        test.next_epoch(OWNER); // epoch 2 — 2_000 live
        policy.stage_hub_share_class(CLASS_STANDARD, 3_000, &cap, test.ctx());
        test.next_epoch(OWNER); // epoch 3 — 3_000 live

        assert_eq!(policy.hub_share_bps_at(a_collection(), 0), 0);
        assert_eq!(policy.hub_share_bps_at(a_collection(), 1), 1_000);
        assert_eq!(policy.hub_share_bps_at(a_collection(), 2), 2_000);
        assert_eq!(policy.hub_share_bps_at(a_collection(), 3), 3_000);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun restaging_in_the_same_epoch_replaces_rather_than_appends() {
        // Two writes in one epoch would otherwise give two segments the same
        // `from_epoch`, and the ladder would stop being a function of the epoch.
        // Neither has taken effect yet, so the later one wins.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_hub_share_class(CLASS_STANDARD, 1_000, &cap, test.ctx());
        policy.stage_hub_share_class(CLASS_STANDARD, 1_500, &cap, test.ctx());
        policy.stage_hub_share_class(CLASS_STANDARD, 2_500, &cap, test.ctx());
        policy.assign_hub_share_class(a_collection(), CLASS_STANDARD, &cap);

        assert_eq!(policy.hub_share_segment_count(CLASS_STANDARD), 1);
        assert_eq!(policy.hub_share_bps_at(a_collection(), 1), 2_500);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun segments_older_than_the_basis_window_are_pruned() {
        // Unbounded growth would make the ladder a liability. Anything older than
        // the settle-by window is unreachable: no basis that old can still be
        // settled, so no epoch can resolve to it.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_hub_share_class(CLASS_STANDARD, 500, &cap, test.ctx());
        policy.assign_hub_share_class(a_collection(), CLASS_STANDARD, &cap);

        let window = constants::hub_basis_window_epochs();
        let mut i = 0;
        while (i < window + 5) {
            test.next_epoch(OWNER);
            policy.stage_hub_share_class(CLASS_STANDARD, 600 + i, &cap, test.ctx());
            i = i + 1;
        };

        // Bounded, and still able to price the oldest epoch a basis can be settled
        // for. The bound is `window + 2`: every `from_epoch` in `[floor, now + 1]`,
        // where the segment sitting exactly on the floor is the one the floor epoch
        // itself resolves to and so cannot be dropped.
        let staged = window + 6;
        let kept = policy.hub_share_segment_count(CLASS_STANDARD);
        assert!(kept <= window + 2);
        assert!(kept < staged);

        let epoch = test.ctx().epoch();
        assert!(policy.hub_share_bps_at(a_collection(), epoch - window) > 0);
        assert!(policy.hub_share_bps_at(a_collection(), epoch) > 0);

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

        policy.stage_hub_share_class(CLASS_STANDARD, 1_000, &cap, test.ctx());
        policy.stage_hub_share_class(CLASS_PARTNER, 2_500, &cap, test.ctx());
        policy.assign_hub_share_class(a_collection(), CLASS_STANDARD, &cap);
        policy.assign_hub_share_class(another_collection(), CLASS_PARTNER, &cap);

        assert_eq!(policy.hub_share_bps_at(a_collection(), 1), 1_000);
        assert_eq!(policy.hub_share_bps_at(another_collection(), 1), 2_500);

        policy.assign_hub_share_class(a_collection(), CLASS_PARTNER, &cap);
        assert_eq!(policy.hub_share_bps_at(a_collection(), 1), 2_500);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun the_default_class_catches_unassigned_collections() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_hub_share_class(CLASS_STANDARD, 1_000, &cap, test.ctx());
        policy.set_default_hub_share_class(CLASS_STANDARD, &cap);

        assert_eq!(policy.hub_share_class(another_collection()), CLASS_STANDARD);
        assert_eq!(policy.hub_share_bps_at(another_collection(), 1), 1_000);

        // An explicit assignment still wins over the default.
        policy.stage_hub_share_class(CLASS_PARTNER, 2_500, &cap, test.ctx());
        policy.assign_hub_share_class(another_collection(), CLASS_PARTNER, &cap);
        assert_eq!(policy.hub_share_bps_at(another_collection(), 1), 2_500);

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

        policy.stage_hub_share_class(CLASS_STANDARD, 2_000, &cap, test.ctx());
        policy.assign_hub_share_class(a_collection(), CLASS_STANDARD, &cap);
        test.next_epoch(OWNER);
        policy.stage_hub_share_class(CLASS_STANDARD, 0, &cap, test.ctx());

        assert_eq!(policy.hub_share_bps_at(a_collection(), 1), 2_000);
        assert_eq!(policy.hub_share_bps_at(a_collection(), 2), 0);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EHubShareAboveCeiling)]
    fun staging_above_the_ceiling_aborts() {
        // MAX_HUB_SHARE_BPS is a trust commitment stated in CAPABILITIES.md, so the
        // admin cannot exceed it even by mistake.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.stage_hub_share_class(
            CLASS_STANDARD,
            constants::max_hub_share_bps() + 1,
            &cap,
            test.ctx(),
        );

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EHubShareClassDoesNotExist)]
    fun assigning_to_a_class_that_does_not_exist_aborts() {
        // Without this the id is simply wrong and resolves to zero, so a mistyped
        // class leaves the hub earning nothing — the one misconfiguration here that
        // produces no error and no event, and surfaces only when an operator asks
        // where their payment went.
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.assign_hub_share_class(a_collection(), CLASS_PARTNER, &cap);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EHubShareClassDoesNotExist)]
    fun defaulting_to_a_class_that_does_not_exist_aborts() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.set_default_hub_share_class(CLASS_PARTNER, &cap);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun the_ceiling_itself_is_settable() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        let max = constants::max_hub_share_bps();
        policy.stage_hub_share_class(CLASS_STANDARD, max, &cap, test.ctx());
        policy.assign_hub_share_class(a_collection(), CLASS_STANDARD, &cap);
        assert_eq!(policy.hub_share_bps_at(a_collection(), 1), max);

        destroy(cap);
        destroy(policy);
        end(test);
    }
}
