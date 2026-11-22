/// Full-freeze tests for a pool, driven through `fee_policy::disable_version`.
///
/// The version passed may be the one currently running. `pool::load_inner` /
/// `load_inner_mut` assert the running version is in the pool's cached copy of the
/// allowed set, so a disable freezes a pool, exits included, once that copy is
/// refreshed with `update_pool_allowed_versions` — one call per pool, and these
/// tests make it. These tests pin both halves of that: the freeze lands, and it
/// is recoverable.
///
/// What the same disable does before any pool is refreshed — stop new exposure
/// and every account everywhere at once — is pinned in `version_gate_tests`; the
/// stop of new trading that traps nobody's funds is `fee_policy::halt_trading`,
/// in `trading_halt_tests`.
#[test_only]
module triex::registry_kill_switch_tests {
    use std::unit_test::destroy;
    use sui::{sui::SUI, test_scenario::{begin, return_shared}};
    use token::cred::CRED;
    use triex::{
        constants,
        fee_policy::FeePolicy,
        pool::Pool,
        pool_test_utils,
        registry::{Self, Registry},
        trading_account_tests::{create_acct_and_share_with_funds, USDC}
    };

    const OWNER: address = @0x1;
    const ALICE: address = @0xAAAA;

    /// Stand up a registry and one live pool, and return both ids.
    fun setup(test: &mut sui::test_scenario::Scenario): (ID, ID) {
        let registry_id = pool_test_utils::setup_test(OWNER, test);
        let trading_account_id = create_acct_and_share_with_funds(
            ALICE,
            1_000_000 * constants::float_scaling(),
            test,
        );
        let pool_id = pool_test_utils::setup_pool_with_default_fees_and_reference_pool<
            SUI,
            USDC,
            SUI,
            CRED,
        >(ALICE, registry_id, trading_account_id, test);

        (registry_id, pool_id)
    }

    /// Disable `version` exchange-wide as admin.
    fun disable(registry_id: ID, version: u64, test: &mut sui::test_scenario::Scenario) {
        test.next_tx(OWNER);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let mut policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        policy.disable_version(&mut registry, version, &cap);
        destroy(cap);
        return_shared(policy);
        return_shared(registry);
    }

    /// Re-enable `version`, then refresh the pool's cached set through the
    /// permissionless path — the same two steps a real recovery would take.
    fun enable_and_refresh(
        registry_id: ID,
        pool_id: ID,
        version: u64,
        test: &mut sui::test_scenario::Scenario,
    ) {
        test.next_tx(OWNER);
        let mut registry = test.take_shared_by_id<Registry>(registry_id);
        let mut policy = test.take_shared<FeePolicy>();
        let cap = registry::get_admin_cap_for_testing(test.ctx());
        policy.enable_version(&mut registry, version, &cap);
        destroy(cap);
        return_shared(policy);

        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.update_pool_allowed_versions(&registry);
        return_shared(pool);
        return_shared(registry);
    }

    #[test]
    /// The running version can be disabled. Before this, `disable_version` asserted
    /// `version != current_version()`, so there was no way to halt a live package
    /// short of publishing a new one.
    fun test_current_version_can_be_disabled() {
        let mut test = begin(OWNER);
        let (registry_id, pool_id) = setup(&mut test);

        disable(registry_id, constants::current_version(), &mut test);

        // The switches stay usable — `disable_version` and `enable_version` are
        // ungated, which is what makes the freeze recoverable.
        enable_and_refresh(registry_id, pool_id, constants::current_version(), &mut test);

        test.end();
    }

    /// Push the registry's current allowed-version set onto the pool through the
    /// permissionless refresh. Pools cache the set, so this is the step that makes a
    /// registry-level disable actually bite — and it has to keep working *after* the
    /// running version is disabled, which is why `registry::allowed_versions` is not
    /// version-gated.
    fun propagate(registry_id: ID, pool_id: ID, test: &mut sui::test_scenario::Scenario) {
        test.next_tx(ALICE);
        let registry = test.take_shared_by_id<Registry>(registry_id);
        let mut pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        pool.update_pool_allowed_versions(&registry);
        return_shared(pool);
        return_shared(registry);
    }

    #[test]
    /// Propagating a halt must be possible *while halted*, and by anyone. If
    /// `allowed_versions` were version-gated this would abort and the kill switch
    /// would be inert — a flag no pool could ever observe.
    fun test_halt_can_be_propagated_while_halted() {
        let mut test = begin(OWNER);
        let (registry_id, pool_id) = setup(&mut test);

        disable(registry_id, constants::current_version(), &mut test);
        // ALICE is not the admin; propagation is deliberately permissionless so a
        // watchdog can fan the halt out across every pool.
        propagate(registry_id, pool_id, &mut test);

        test.end();
    }

    #[test]
    #[expected_failure(abort_code = ::triex::pool::EPackageVersionDisabled)]
    /// With the running version disabled and the change propagated, a pool refuses to
    /// load — trading halts.
    fun test_disabling_current_version_halts_trading() {
        let mut test = begin(OWNER);
        let (registry_id, pool_id) = setup(&mut test);

        disable(registry_id, constants::current_version(), &mut test);
        propagate(registry_id, pool_id, &mut test);

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        // Any entrypoint would do; every one routes through `load_inner`.
        pool.registered_pool();

        abort 0
    }

    #[test]
    /// A halt is reversible: re-enable the version, refresh the pool, and it serves
    /// again. This is the property that makes the kill switch safe to reach for.
    fun test_halt_is_recoverable() {
        let mut test = begin(OWNER);
        let (registry_id, pool_id) = setup(&mut test);

        disable(registry_id, constants::current_version(), &mut test);
        propagate(registry_id, pool_id, &mut test);
        enable_and_refresh(registry_id, pool_id, constants::current_version(), &mut test);

        test.next_tx(ALICE);
        let pool = test.take_shared_by_id<Pool<SUI, USDC>>(pool_id);
        assert!(pool.registered_pool());
        return_shared(pool);

        test.end();
    }
}
