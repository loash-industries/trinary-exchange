/// Pinning the hub adapter (TRIEX-152).
///
/// The report: `set_operator_adapter<W: drop>` pinned any type with `drop`,
/// first come first served, while the operator share was already accruing.
/// The admin could pin a witness it mints itself and claim the backlog; a
/// mistaken pin of a public type let anyone register; and a pinned adapter
/// whose `UpgradeCap` stayed live could be upgraded to mint its witness freely.
///
/// Pinned here:
///
/// - **The pin consumes the adapter's `UpgradeCap`** and deletes it, so the
///   pinned package is immutable from that transaction on. The cap has to be
///   the cap of the package that defines the witness, as first published: a
///   cap for another package, or for an upgraded one, is refused, and a
///   primitive type has no package to pin at all.
/// - **One pin, ever.** A second pin aborts, whatever its type. Re-opening
///   registration after a clear needs a pin to re-open.
/// - **No multicoin pricing before the pin.** `bootstrap_quote` and
///   `set_multicoin_default_class` abort until an adapter is pinned, so no
///   multicoin pool, and so no operator share, can exist before it. Coin
///   pools carry no share and are not gated, and closing registration after
///   the pin does not block pricing.
#[test_only]
module triex::adapter_pin_tests {
    use std::{type_name, unit_test::{assert_eq, destroy}};
    use sui::{address, event, package::{Self, UpgradeCap}, test_scenario::{Scenario, begin, end}};
    use token::cred::CRED;
    use triex::{
        fee_policy::{Self, FeePolicy, OperatorAdapterAuthorized, OperatorPayouts},
        registry::{Self, TriexAdminCap}
    };

    const OWNER: address = @0x1;
    const COIN_CLASS: u16 = 0;
    const MULTICOIN_CLASS: u16 = 1;
    const SIX_DP: u128 = 1_000_000;

    public struct USDC has drop {}

    /// Stands in for the audited adapter's witness. Defined in this package, so
    /// its defining package is the one these tests publish a cap for.
    public struct Adapter has drop {}

    /// Any other type with `drop`.
    public struct Other has drop {}

    /// The id of the package that defines `T`, as `type_name` reports it.
    fun package_of<T>(): ID {
        let name = type_name::with_defining_ids<T>().address_string();
        object::id_from_address(address::from_ascii_bytes(name.as_bytes()))
    }

    fun setup(test: &mut Scenario): (FeePolicy, OperatorPayouts, TriexAdminCap) {
        (
            fee_policy::create_for_testing(test.ctx()),
            fee_policy::create_payouts_for_testing(test.ctx()),
            registry::get_admin_cap_for_testing(test.ctx()),
        )
    }

    // === The pin consumes the adapter's UpgradeCap ===

    #[test]
    /// The production path: the adapter's publish left an `UpgradeCap` with the
    /// admin; pinning hands it over and deletes it. From then on the pinned
    /// package can never change, and the pin is on the event stream.
    fun pinning_consumes_the_adapter_upgrade_cap() {
        let mut test = begin(OWNER);
        let (policy, mut payouts, cap) = setup(&mut test);

        // The cap the adapter's publish produced, owned by the admin.
        let upgrade_cap = package::test_publish(package_of<Adapter>(), test.ctx());
        let upgrade_cap_id = object::id(&upgrade_cap);
        transfer::public_transfer(upgrade_cap, OWNER);

        test.next_tx(OWNER);
        let upgrade_cap = test.take_from_sender<UpgradeCap>();
        assert_eq!(payouts.pinned_operator_adapter(), option::none());
        payouts.pin_operator_adapter<Adapter>(&cap, upgrade_cap);

        let adapter = type_name::with_defining_ids<Adapter>();
        assert_eq!(payouts.pinned_operator_adapter(), option::some(adapter));
        // Pinning also opens registration for it.
        assert_eq!(payouts.operator_adapter(), option::some(adapter));
        let authorized = event::events_by_type<OperatorAdapterAuthorized>();
        assert_eq!(authorized.length(), 1);
        assert_eq!(authorized[0].operator_adapter_authorized_adapter(), option::some(adapter));

        // The cap no longer exists: `make_immutable` deleted it.
        let effects = test.next_tx(OWNER);
        assert!(effects.deleted().contains(&upgrade_cap_id));
        assert!(!test.has_most_recent_for_sender<UpgradeCap>());

        destroy(cap);
        destroy(policy);
        destroy(payouts);
        end(test);
    }

    #[test, expected_failure(abort_code = fee_policy::EAdapterUpgradeCapMismatch)]
    /// Holding *a* cap is not enough: it has to be the cap of the package that
    /// defines the witness.
    fun a_cap_for_another_package_cannot_pin() {
        let mut test = begin(OWNER);
        let (_policy, mut payouts, cap) = setup(&mut test);
        let upgrade_cap = package::test_publish(object::id_from_address(@0xBEEF), test.ctx());

        payouts.pin_operator_adapter<Adapter>(&cap, upgrade_cap);

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EAdapterUpgradeCapMismatch)]
    /// An upgraded adapter's cap points at its latest version, not at the
    /// package that defines the witness. The pin wants the package as first
    /// published, so the code auditors read at that address is what runs.
    ///
    /// The witness here is `token::cred::CRED`, a type with `drop` from a
    /// dependency. A dependency always builds at its published address, while
    /// this package builds at `0x0` when it has no `Published.toml` (as in a
    /// coverage run), and `0x0` is what an `UpgradeCap` holds mid-upgrade, so
    /// `authorize_upgrade` would refuse it.
    fun an_upgraded_adapter_cannot_be_pinned() {
        let mut test = begin(OWNER);
        let (_policy, mut payouts, cap) = setup(&mut test);
        let mut upgrade_cap = package::test_publish(package_of<CRED>(), test.ctx());
        let ticket = upgrade_cap.authorize_upgrade(package::compatible_policy(), b"digest");
        let receipt = package::test_upgrade(ticket);
        upgrade_cap.commit_upgrade(receipt);
        assert_eq!(upgrade_cap.version(), 2);
        assert!(upgrade_cap.upgrade_package() != package_of<CRED>());

        payouts.pin_operator_adapter<CRED>(&cap, upgrade_cap);

        abort 0
    }

    #[test]
    /// The control for the test above: the same package's cap, never upgraded,
    /// pins. Together they show the refusal is the upgrade and nothing else.
    fun the_same_adapter_pins_before_any_upgrade() {
        let mut test = begin(OWNER);
        let (policy, mut payouts, cap) = setup(&mut test);
        let upgrade_cap = package::test_publish(package_of<CRED>(), test.ctx());

        payouts.pin_operator_adapter<CRED>(&cap, upgrade_cap);
        assert_eq!(
            payouts.pinned_operator_adapter(),
            option::some(type_name::with_defining_ids<CRED>()),
        );

        destroy(cap);
        destroy(policy);
        destroy(payouts);
        end(test);
    }

    #[test, expected_failure(abort_code = std::type_name::ENonModuleType)]
    /// A primitive has no defining package, so it can never be pinned — the
    /// "mistaken pin of a public type" from the report, at its simplest.
    fun a_primitive_type_cannot_be_pinned() {
        let mut test = begin(OWNER);
        let (_policy, mut payouts, cap) = setup(&mut test);
        let upgrade_cap = package::test_publish(object::id_from_address(@0x1), test.ctx());

        payouts.pin_operator_adapter<bool>(&cap, upgrade_cap);

        abort 0
    }

    // === One pin, ever ===

    #[test, expected_failure(abort_code = fee_policy::EAdapterPinned)]
    fun a_second_pin_of_the_same_type_aborts() {
        let mut test = begin(OWNER);
        let (_policy, mut payouts, cap) = setup(&mut test);
        payouts.pin_operator_adapter_for_testing<Adapter>(&cap, test.ctx());

        payouts.pin_operator_adapter_for_testing<Adapter>(&cap, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::EAdapterPinned)]
    /// Even with a valid cap for its own package, another adapter cannot
    /// replace the pin.
    fun a_second_pin_of_another_type_aborts() {
        let mut test = begin(OWNER);
        let (_policy, mut payouts, cap) = setup(&mut test);
        payouts.pin_operator_adapter_for_testing<Adapter>(&cap, test.ctx());

        payouts.pin_operator_adapter_for_testing<Other>(&cap, test.ctx());

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::ENoPinnedAdapter)]
    /// `set_operator_adapter` only re-opens a pin; it can no longer create one.
    fun re_opening_needs_a_pin() {
        let mut test = begin(OWNER);
        let (_policy, mut payouts, cap) = setup(&mut test);

        payouts.set_operator_adapter<Adapter>(&cap);

        abort 0
    }

    #[test]
    /// After a clear, the pinned type re-opens registration without a cap: the
    /// package is already immutable.
    fun the_pinned_type_re_opens_after_a_clear() {
        let mut test = begin(OWNER);
        let (policy, mut payouts, cap) = setup(&mut test);
        payouts.pin_operator_adapter_for_testing<Adapter>(&cap, test.ctx());
        payouts.clear_operator_adapter(&cap);
        assert_eq!(payouts.operator_adapter(), option::none());

        payouts.set_operator_adapter<Adapter>(&cap);
        assert_eq!(
            payouts.operator_adapter(),
            option::some(type_name::with_defining_ids<Adapter>()),
        );
        payouts.register_operator_beneficiary_with_witness(
            object::id_from_address(@0xC0FFEE),
            @0xB0B,
            Adapter {},
        );
        assert_eq!(
            payouts.operator_beneficiary(object::id_from_address(@0xC0FFEE)),
            option::some(@0xB0B),
        );

        destroy(cap);
        destroy(policy);
        destroy(payouts);
        end(test);
    }

    // === No multicoin pricing before the pin ===

    #[test, expected_failure(abort_code = fee_policy::ENoPinnedAdapter)]
    /// The launch path cannot run first: no multicoin default class, so no
    /// multicoin pool, so no operator share accruing to nobody in particular.
    fun bootstrap_needs_a_pinned_adapter() {
        let mut test = begin(OWNER);
        let (mut policy, payouts, cap) = setup(&mut test);

        policy.bootstrap_quote<USDC>(
            &payouts,
            COIN_CLASS,
            MULTICOIN_CLASS,
            SIX_DP,
            &cap,
            test.ctx(),
        );

        abort 0
    }

    #[test, expected_failure(abort_code = fee_policy::ENoPinnedAdapter)]
    /// Nor can the multicoin default be set by hand.
    fun the_multicoin_default_needs_a_pinned_adapter() {
        let mut test = begin(OWNER);
        let (mut policy, payouts, cap) = setup(&mut test);
        policy.create_class<USDC>(
            MULTICOIN_CLASS,
            vector[0],
            vector[22_000_000],
            vector[18_000_000],
            2_000,
            &cap,
            test.ctx(),
        );

        policy.set_multicoin_default_class<USDC>(&payouts, MULTICOIN_CLASS, &cap);

        abort 0
    }

    #[test]
    /// Coin pools carry no operator share, so their pricing is not gated.
    fun the_coin_default_needs_no_adapter() {
        let mut test = begin(OWNER);
        let (mut policy, payouts, cap) = setup(&mut test);
        policy.create_class<USDC>(
            COIN_CLASS,
            vector[0],
            vector[11_000_000],
            vector[9_000_000],
            2_000,
            &cap,
            test.ctx(),
        );

        policy.set_default_class<USDC>(COIN_CLASS, &cap);
        assert_eq!(policy.default_class(type_name::with_defining_ids<USDC>()), COIN_CLASS);

        destroy(cap);
        destroy(policy);
        destroy(payouts);
        end(test);
    }

    #[test]
    /// Once pinned, the launch path runs — even with registration closed again,
    /// since the gate is the pin, not whether hubs can register right now.
    fun bootstrap_runs_once_pinned_even_with_registration_closed() {
        let mut test = begin(OWNER);
        let (mut policy, mut payouts, cap) = setup(&mut test);
        payouts.pin_operator_adapter_for_testing<Adapter>(&cap, test.ctx());
        payouts.clear_operator_adapter(&cap);

        policy.bootstrap_quote<USDC>(
            &payouts,
            COIN_CLASS,
            MULTICOIN_CLASS,
            SIX_DP,
            &cap,
            test.ctx(),
        );
        let usdc = type_name::with_defining_ids<USDC>();
        assert_eq!(policy.default_class(usdc), COIN_CLASS);
        assert_eq!(policy.multicoin_default_class(usdc), MULTICOIN_CLASS);

        destroy(cap);
        destroy(policy);
        destroy(payouts);
        end(test);
    }
}
