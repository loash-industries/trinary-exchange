/// Guard and branch tests for `fee_policy` class management and lookups.
#[test_only]
module triex::fee_policy_coverage_tests {
    use std::{type_name, unit_test::{assert_eq, destroy}};
    use sui::test_scenario::{Scenario, begin, end};
    use triex::{
        fee_policy::{Self, FeePolicy},
        registry::{Self, TriexAdminCap},
        trading_account_tests::{USDC, USDT}
    };

    const OWNER: address = @0x1;
    const CLASS_A: u16 = 1;
    const CLASS_B: u16 = 2;
    const MISSING: u16 = 99;
    const TAKER: u64 = 11_000_000;
    const MAKER: u64 = 9_000_000;
    const RETENTION: u64 = 2_000;

    public struct Adapter has drop {}

    fun new_policy(test: &mut Scenario): (FeePolicy, TriexAdminCap) {
        (
            fee_policy::create_for_testing(test.ctx()),
            registry::get_admin_cap_for_testing(test.ctx()),
        )
    }

    fun add_class<Q>(
        policy: &mut FeePolicy,
        id: u16,
        taker: u64,
        retention: u64,
        cap: &TriexAdminCap,
        test: &mut Scenario,
    ) {
        policy.create_class<Q>(
            id,
            vector[0],
            vector[taker],
            vector[MAKER],
            retention,
            cap,
            test.ctx(),
        );
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EClassAlreadyExists)]
    fun creating_an_existing_class_aborts() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        add_class<USDC>(&mut policy, CLASS_A, TAKER, RETENTION, &cap, &mut test);
        add_class<USDC>(&mut policy, CLASS_A, TAKER, RETENTION, &cap, &mut test);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EInvalidCancelRetention)]
    fun creating_a_class_above_full_retention_aborts() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        add_class<USDC>(&mut policy, CLASS_A, TAKER, 10_001, &cap, &mut test);
        abort 0
    }

    #[test]
    fun a_class_at_full_retention_is_accepted() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        add_class<USDC>(&mut policy, CLASS_A, TAKER, 10_000, &cap, &mut test);
        assert_eq!(policy.cancel_retention_bps(CLASS_A), 10_000);
        assert_eq!(policy.class_quote(CLASS_A), type_name::with_defining_ids<USDC>());
        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EClassDoesNotExist)]
    fun updating_a_missing_class_aborts() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        policy.update_class(
            MISSING,
            vector[0],
            vector[TAKER],
            vector[MAKER],
            RETENTION,
            &cap,
            test.ctx(),
        );
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EInvalidCancelRetention)]
    fun updating_a_class_above_full_retention_aborts() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        add_class<USDC>(&mut policy, CLASS_A, TAKER, RETENTION, &cap, &mut test);
        policy.update_class(
            CLASS_A,
            vector[0],
            vector[TAKER],
            vector[MAKER],
            10_001,
            &cap,
            test.ctx(),
        );
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EClassDoesNotExist)]
    fun active_schedule_of_a_missing_class_aborts() {
        let mut test = begin(OWNER);
        let (policy, _cap) = new_policy(&mut test);
        policy.active_schedule(MISSING, 0);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EClassDoesNotExist)]
    fun next_schedule_of_a_missing_class_aborts() {
        let mut test = begin(OWNER);
        let (policy, _cap) = new_policy(&mut test);
        policy.next_schedule(MISSING);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EClassDoesNotExist)]
    fun class_quote_of_a_missing_class_aborts() {
        let mut test = begin(OWNER);
        let (policy, _cap) = new_policy(&mut test);
        policy.class_quote(MISSING);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EClassDoesNotExist)]
    fun cancel_retention_of_a_missing_class_aborts() {
        let mut test = begin(OWNER);
        let (policy, _cap) = new_policy(&mut test);
        policy.cancel_retention_bps(MISSING);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EClassDoesNotExist)]
    fun resolving_a_missing_class_aborts() {
        let mut test = begin(OWNER);
        let (policy, _cap) = new_policy(&mut test);
        policy.resolve(MISSING, 0, 0);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EClassDoesNotExist)]
    fun resolving_with_retention_a_missing_class_aborts() {
        let mut test = begin(OWNER);
        let (policy, _cap) = new_policy(&mut test);
        policy.resolve_with_retention(MISSING, 0, 0);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EClassDoesNotExist)]
    fun defaulting_to_a_missing_class_aborts() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        policy.set_default_class<USDC>(MISSING, &cap);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::EClassQuoteMismatch)]
    fun defaulting_to_a_class_of_another_quote_aborts() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        add_class<USDT>(&mut policy, CLASS_A, TAKER, RETENTION, &cap, &mut test);
        policy.set_default_class<USDC>(CLASS_A, &cap);
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::ENoDefaultClassForQuote)]
    fun coin_default_without_one_set_aborts() {
        let mut test = begin(OWNER);
        let (policy, _cap) = new_policy(&mut test);
        policy.default_class(type_name::with_defining_ids<USDC>());
        abort 0
    }

    #[test]
    #[expected_failure(abort_code = fee_policy::ENoDefaultClassForQuote)]
    fun multicoin_default_without_one_set_aborts() {
        let mut test = begin(OWNER);
        let (policy, _cap) = new_policy(&mut test);
        policy.multicoin_default_class(type_name::with_defining_ids<USDC>());
        abort 0
    }

    #[test]
    /// Re-pointing a default replaces the previous entry for both venues.
    fun defaults_can_be_repointed() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        let usdc = type_name::with_defining_ids<USDC>();
        add_class<USDC>(&mut policy, CLASS_A, TAKER, RETENTION, &cap, &mut test);
        add_class<USDC>(&mut policy, CLASS_B, TAKER, RETENTION, &cap, &mut test);

        policy.set_default_class<USDC>(CLASS_A, &cap);
        policy.set_default_class<USDC>(CLASS_B, &cap);
        assert_eq!(policy.default_class(usdc), CLASS_B);

        policy.set_multicoin_default_class<USDC>(CLASS_B, &cap);
        policy.set_multicoin_default_class<USDC>(CLASS_A, &cap);
        assert_eq!(policy.multicoin_default_class(usdc), CLASS_A);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    /// A staged update prices from its effective epoch on, and not before.
    fun resolve_with_retention_selects_by_epoch() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);
        add_class<USDC>(&mut policy, CLASS_A, TAKER, RETENTION, &cap, &mut test);
        policy.update_class(
            CLASS_A,
            vector[0],
            vector[2 * TAKER],
            vector[MAKER],
            3_000,
            &cap,
            test.ctx(),
        );

        let (tier, taker, maker, retention) = policy.resolve_with_retention(CLASS_A, 0, 0);
        assert_eq!(tier, 0);
        assert_eq!(taker, TAKER);
        assert_eq!(maker, MAKER);
        assert_eq!(retention, 3_000);

        let (_, taker, _, _) = policy.resolve_with_retention(CLASS_A, 0, 1);
        assert_eq!(taker, 2 * TAKER);
        let (_, taker, _) = policy.resolve(CLASS_A, 0, 1);
        assert_eq!(taker, 2 * TAKER);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    /// Clearing a registered adapter removes it; clearing again is a no-op.
    fun clearing_a_registered_adapter_revokes_it() {
        let mut test = begin(OWNER);
        let (mut policy, cap) = new_policy(&mut test);

        policy.set_operator_adapter<Adapter>(&cap);
        assert!(policy.operator_adapter().is_some());
        policy.clear_operator_adapter(&cap);
        assert_eq!(policy.operator_adapter(), option::none());
        policy.clear_operator_adapter(&cap);
        assert_eq!(policy.operator_adapter(), option::none());

        destroy(cap);
        destroy(policy);
        end(test);
    }
}
