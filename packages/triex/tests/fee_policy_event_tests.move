/// Tests for the events that put fee-policy configuration on the event stream.
///
/// Every write to the policy that changes what a pool or a hub is priced at
/// must be visible to an indexer: the class defaults new pools are born into,
/// the class each pool trades under, the operator-share default, and the
/// genesis operator-share class that `new_policy` and
/// `seed_operator_share_genesis` write directly rather than by staging.
#[test_only]
module triex::fee_policy_event_tests {
    use std::{type_name, unit_test::{assert_eq, destroy}};
    use sui::{event, test_scenario::{begin, end, return_shared}};
    use triex::{
        fee_policy::{
            Self,
            FeePolicy,
            DefaultFeeClassSet,
            DefaultOperatorShareClassSet,
            OperatorBeneficiaryChanged,
            OperatorBeneficiaryDestroyed,
            OperatorBeneficiaryRegistered,
            OperatorShareClassUpdated,
            PoolFeeClassSet
        },
        integration_multicoin_test_utils as multicoin_test_utils,
        multicoin_pool::MultiCoinPool,
        pool::Pool,
        pool_test_utils::{Self, standard_class, multicoin_class},
        registry,
        trading_account_tests::{SPAM, USDC}
    };

    const OWNER: address = @0x1;
    /// `GENESIS_OPERATOR_SHARE_BPS`, mirrored because the source constant is private.
    const GENESIS_SHARE_BPS: u64 = 2000;
    const SIX_DP: u128 = 1_000_000;
    const CLASS_PARTNER: u16 = 11;

    #[test]
    fun genesis_announces_operator_share_class_zero_and_the_default() {
        let mut test = begin(OWNER);
        let policy = fee_policy::create_for_testing(test.ctx());

        let updates = event::events_by_type<OperatorShareClassUpdated>();
        assert_eq!(updates.length(), 1);
        let (class_id, bps, from_epoch) = updates[0].operator_share_class_updated_parts();
        assert_eq!(class_id, 0);
        assert_eq!(bps, GENESIS_SHARE_BPS);
        // Live from the first epoch, as `new_policy` writes it.
        assert_eq!(from_epoch, 0);

        let defaults = event::events_by_type<DefaultOperatorShareClassSet>();
        assert_eq!(defaults.length(), 1);
        assert_eq!(defaults[0].default_operator_share_class_set_class_id(), 0);

        destroy(policy);
        end(test);
    }

    #[test]
    fun seeding_genesis_announces_only_what_it_adds() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        policy.strip_operator_share_genesis_for_testing();

        // Seed a few epochs in, as an upgraded deployment would.
        test.next_epoch(OWNER);
        test.next_epoch(OWNER);
        let seeded_at = test.ctx().epoch();
        policy.seed_operator_share_genesis(&cap, test.ctx());
        let updates = event::events_by_type<OperatorShareClassUpdated>();
        assert_eq!(updates.length(), 1);
        let (class_id, bps, from_epoch) = updates[0].operator_share_class_updated_parts();
        assert_eq!(class_id, 0);
        assert_eq!(bps, GENESIS_SHARE_BPS);
        // Payable from the seeding epoch, not backdated to 0: the share
        // resolved to zero until this call.
        assert_eq!(seeded_at, 2);
        assert_eq!(from_epoch, seeded_at);
        assert_eq!(event::events_by_type<DefaultOperatorShareClassSet>().length(), 1);

        // Already seeded: nothing is written, so nothing is announced.
        test.next_tx(OWNER);
        policy.seed_operator_share_genesis(&cap, test.ctx());
        assert_eq!(event::events_by_type<OperatorShareClassUpdated>().length(), 0);
        assert_eq!(event::events_by_type<DefaultOperatorShareClassSet>().length(), 0);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun setting_default_classes_announces_the_pool_kind() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        // Creates classes 0 and 1 and points the coin and multicoin defaults at them.
        policy.bootstrap_quote<USDC>(0, 1, SIX_DP, &cap, test.ctx());

        let sets = event::events_by_type<DefaultFeeClassSet>();
        assert_eq!(sets.length(), 2);
        let (quote, class_id, multicoin) = sets[0].default_fee_class_set_parts();
        assert_eq!(quote, type_name::with_defining_ids<USDC>());
        assert_eq!(class_id, 0);
        assert_eq!(multicoin, false);
        let (quote, class_id, multicoin) = sets[1].default_fee_class_set_parts();
        assert_eq!(quote, type_name::with_defining_ids<USDC>());
        assert_eq!(class_id, 1);
        assert_eq!(multicoin, true);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun setting_the_default_operator_share_class_announces_it() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        policy.stage_operator_share_class(CLASS_PARTNER, 2_500, &cap, test.ctx());

        test.next_tx(OWNER);
        policy.set_default_operator_share_class(CLASS_PARTNER, &cap);

        let defaults = event::events_by_type<DefaultOperatorShareClassSet>();
        assert_eq!(defaults.length(), 1);
        assert_eq!(defaults[0].default_operator_share_class_set_class_id(), CLASS_PARTNER);

        destroy(cap);
        destroy(policy);
        end(test);
    }

    #[test]
    fun coin_pool_announces_its_class_at_creation_and_on_reassignment() {
        let mut test = begin(OWNER);
        let registry_id = pool_test_utils::setup_test(OWNER, &mut test);
        let pool_id = pool_test_utils::setup_pool_with_default_fees<SPAM, USDC>(
            OWNER,
            registry_id,
            &mut test,
        );

        let created = event::events_by_type<PoolFeeClassSet>();
        assert_eq!(created.length(), 1);
        let (id, class_id) = created[0].pool_fee_class_set_parts();
        assert_eq!(id, pool_id);
        assert_eq!(class_id, standard_class<USDC>());

        test.next_tx(OWNER);
        let mut pool = test.take_shared_by_id<Pool<SPAM, USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        // The multicoin class is also USDC-quoted, so a coin pool may join it.
        pool.set_pool_fee_class(&policy, multicoin_class<USDC>(), &cap);

        let reassigned = event::events_by_type<PoolFeeClassSet>();
        assert_eq!(reassigned.length(), 1);
        let (id, class_id) = reassigned[0].pool_fee_class_set_parts();
        assert_eq!(id, pool_id);
        assert_eq!(class_id, multicoin_class<USDC>());
        assert_eq!(pool.pool_fee_class(), multicoin_class<USDC>());

        return_shared(pool);
        return_shared(policy);
        destroy(cap);
        end(test);
    }

    #[test]
    fun multicoin_pool_announces_its_class_at_creation_and_on_reassignment() {
        let mut test = begin(OWNER);
        let (
            registry_id,
            collection_id,
            collection_cap,
        ) = multicoin_test_utils::setup_registry_with_multicoin(
            &mut test,
        );
        let pool_id = multicoin_test_utils::setup_multicoin_pool(
            OWNER,
            registry_id,
            collection_id,
            1,
            &mut test,
        );

        let created = event::events_by_type<PoolFeeClassSet>();
        assert_eq!(created.length(), 1);
        let (id, class_id) = created[0].pool_fee_class_set_parts();
        assert_eq!(id, pool_id);
        assert_eq!(class_id, multicoin_class<USDC>());

        test.next_tx(OWNER);
        let mut pool = test.take_shared_by_id<MultiCoinPool<USDC>>(pool_id);
        let policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        pool.set_pool_fee_class(&policy, standard_class<USDC>(), &cap);

        let reassigned = event::events_by_type<PoolFeeClassSet>();
        assert_eq!(reassigned.length(), 1);
        let (id, class_id) = reassigned[0].pool_fee_class_set_parts();
        assert_eq!(id, pool_id);
        assert_eq!(class_id, standard_class<USDC>());
        assert_eq!(pool.pool_fee_class(), standard_class<USDC>());

        return_shared(pool);
        return_shared(policy);
        destroy(cap);
        destroy(collection_cap);
        end(test);
    }

    /// Stands in for the audited adapter package's witness.
    public struct Adapter has drop {}

    /// A collection's payout history must read off the event stream alone:
    /// registration, every rotation with both ends, and an admin destroy.
    #[test]
    fun the_beneficiary_lifecycle_is_on_the_event_stream() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        let collection = object::id_from_address(@0xC0FFEE);

        policy.set_operator_adapter<Adapter>(&cap);
        policy.register_operator_beneficiary_with_witness(collection, @0xB0B, Adapter {});
        // A no-op second registration announces nothing.
        policy.register_operator_beneficiary_with_witness(collection, @0xBAD, Adapter {});
        policy.update_operator_beneficiary_with_witness(collection, @0xCAFE, Adapter {});
        // A no-op rotation to the current address announces nothing.
        policy.update_operator_beneficiary_with_witness(collection, @0xCAFE, Adapter {});
        policy.update_operator_beneficiary_with_witness(collection, @0xD00D, Adapter {});
        policy.destroy_operator_beneficiary(collection, &cap);
        // Destroying an absent mapping announces nothing either.
        policy.destroy_operator_beneficiary(collection, &cap);

        let registered = event::events_by_type<OperatorBeneficiaryRegistered>();
        assert_eq!(registered.length(), 1);
        let (registered_collection, beneficiary) = registered[
            0,
        ].operator_beneficiary_registered_parts();
        assert_eq!(registered_collection, collection);
        assert_eq!(beneficiary, @0xB0B);

        let changed = event::events_by_type<OperatorBeneficiaryChanged>();
        assert_eq!(changed.length(), 2);
        let (changed_collection, previous, beneficiary) = changed[
            0,
        ].operator_beneficiary_changed_parts();
        assert_eq!(changed_collection, collection);
        assert_eq!(previous, @0xB0B);
        assert_eq!(beneficiary, @0xCAFE);
        let (_, previous, beneficiary) = changed[1].operator_beneficiary_changed_parts();
        assert_eq!(previous, @0xCAFE);
        assert_eq!(beneficiary, @0xD00D);

        let destroyed = event::events_by_type<OperatorBeneficiaryDestroyed>();
        assert_eq!(destroyed.length(), 1);
        assert_eq!(destroyed[0].operator_beneficiary_destroyed_collection_id(), collection);

        destroy(cap);
        destroy(policy);
        end(test);
    }
}
