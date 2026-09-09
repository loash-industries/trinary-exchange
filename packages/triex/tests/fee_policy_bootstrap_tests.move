/// Tests for the post-publish bootstrap path: `fee_policy::bootstrap_quote`
/// is what stands the exchange up, and until it has run for a quote no pool of
/// that quote can be created at all. These pin the genesis ladder itself —
/// the rates a trader actually meets on day one — rather than the resolution
/// machinery, which `fee_schedule_tests` already covers.
#[test_only]
module triex::fee_policy_bootstrap_tests {
    use std::{type_name, unit_test::{assert_eq, destroy}};
    use sui::test_scenario::{begin, end};
    use triex::{fee_policy::{Self, FeePolicy}, registry};

    public struct CRED has store {}
    public struct NINE_DP has store {}

    const OWNER: address = @0x1;
    const COIN_CLASS: u16 = 0;
    const MULTICOIN_CLASS: u16 = 1;

    /// 10^6 — CRED and USDC scale.
    const SIX_DP: u128 = 1_000_000;
    /// 10^9 — SUI scale.
    const NINE_DP_UNIT: u128 = 1_000_000_000;

    const GENESIS_TIERS: u64 = 8;

    // The published launch table, transcribed from the docs rather than from the
    // module under test, so a typo in either one shows up as a failure here.
    fun coin_takers(): vector<u64> {
        vector[
            11_000_000,
            10_500_000,
            9_900_000,
            9_100_000,
            8_300_000,
            7_200_000,
            6_100_000,
            5_500_000,
        ]
    }

    fun coin_makers(): vector<u64> {
        vector[
            9_000_000,
            8_600_000,
            8_100_000,
            7_500_000,
            6_800_000,
            5_900_000,
            5_000_000,
            4_500_000,
        ]
    }

    fun multicoin_takers(): vector<u64> {
        vector[
            22_000_000,
            20_900_000,
            19_800_000,
            18_300_000,
            16_500_000,
            14_300_000,
            12_100_000,
            11_000_000,
        ]
    }

    fun multicoin_makers(): vector<u64> {
        vector[
            18_000_000,
            17_100_000,
            16_200_000,
            14_900_000,
            13_500_000,
            11_700_000,
            9_900_000,
            9_000_000,
        ]
    }

    /// Thresholds at six-decimal scale: 20k / 100k / 500k / 2M / 10M / 50M / 200M
    /// quote units of fees *paid*.
    fun six_dp_thresholds(): vector<u128> {
        vector[
            0,
            20_000_000_000,
            100_000_000_000,
            500_000_000_000,
            2_000_000_000_000,
            10_000_000_000_000,
            50_000_000_000_000,
            200_000_000_000_000,
        ]
    }

    fun assert_ladder(
        policy: &FeePolicy,
        class_id: u16,
        epoch: u64,
        takers: vector<u64>,
        makers: vector<u64>,
        thresholds: vector<u128>,
    ) {
        let schedule = policy.active_schedule(class_id, epoch);
        assert_eq!(schedule.tier_count(), GENESIS_TIERS);

        let mut i = 0;
        while (i < GENESIS_TIERS) {
            let tier = schedule.tier_at(i);
            assert_eq!(tier.taker_fee(), takers[i]);
            assert_eq!(tier.maker_fee(), makers[i]);
            assert_eq!(tier.min_turnover(), thresholds[i]);
            i = i + 1;
        };
    }

    #[test]
    fun bootstrap_creates_both_classes_and_registers_defaults() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.bootstrap_quote<CRED>(COIN_CLASS, MULTICOIN_CLASS, SIX_DP, &cap, test.ctx());

        assert!(policy.class_exists(COIN_CLASS));
        assert!(policy.class_exists(MULTICOIN_CLASS));

        // Pool creation reads these two tables; without them `create_pool` aborts.
        let quote = type_name::with_defining_ids<CRED>();
        assert_eq!(policy.default_class(quote), COIN_CLASS);
        assert_eq!(policy.multicoin_default_class(quote), MULTICOIN_CLASS);

        // Both classes are pinned to the quote they price, so a pool of another
        // quote can never join them.
        assert_eq!(policy.class_quote(COIN_CLASS), quote);
        assert_eq!(policy.class_quote(MULTICOIN_CLASS), quote);

        // Launch retention: 20% of released bid escrow.
        assert_eq!(policy.cancel_retention_bps(COIN_CLASS), 2_000);
        assert_eq!(policy.cancel_retention_bps(MULTICOIN_CLASS), 2_000);

        destroy(cap);
        policy.share_for_testing();
        end(test);
    }

    #[test]
    fun genesis_coin_ladder_is_the_published_table() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.bootstrap_quote<CRED>(COIN_CLASS, MULTICOIN_CLASS, SIX_DP, &cap, test.ctx());
        assert_ladder(
            &policy,
            COIN_CLASS,
            test.ctx().epoch(),
            coin_takers(),
            coin_makers(),
            six_dp_thresholds(),
        );

        destroy(cap);
        policy.share_for_testing();
        end(test);
    }

    #[test]
    fun genesis_multicoin_ladder_is_the_published_table() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.bootstrap_quote<CRED>(COIN_CLASS, MULTICOIN_CLASS, SIX_DP, &cap, test.ctx());
        assert_ladder(
            &policy,
            MULTICOIN_CLASS,
            test.ctx().epoch(),
            multicoin_takers(),
            multicoin_makers(),
            six_dp_thresholds(),
        );

        destroy(cap);
        policy.share_for_testing();
        end(test);
    }

    #[test]
    /// Multicoin is the premium venue at launch: its entry rate is exactly double
    /// the coin pool's. Only the entry rung is pinned this way — each ladder's
    /// rates above it were chosen independently, so they are not proportional
    /// tier-for-tier, and this test must not assert that they are.
    fun multicoin_entry_tier_prices_at_twice_the_coin_pool() {
        let coin_t = coin_takers();
        let coin_m = coin_makers();
        let mc_t = multicoin_takers();
        let mc_m = multicoin_makers();

        assert_eq!(mc_t[0], coin_t[0] * 2);
        assert_eq!(mc_m[0], coin_m[0] * 2);
    }

    #[test]
    /// Every column decreases going up the ladder, and a maker always undercuts
    /// the taker on its own rung — the two properties `validate` actually
    /// enforces on the shipped ladder, independent of the entry-tier 2x above.
    fun every_column_is_monotone_and_maker_undercuts_taker() {
        let coin_t = coin_takers();
        let coin_m = coin_makers();
        let mc_t = multicoin_takers();
        let mc_m = multicoin_makers();

        let mut i = 0;
        while (i < GENESIS_TIERS) {
            assert!(coin_m[i] < coin_t[i]);
            assert!(mc_m[i] < mc_t[i]);
            if (i > 0) {
                assert!(coin_t[i] <= coin_t[i - 1]);
                assert!(coin_m[i] <= coin_m[i - 1]);
                assert!(mc_t[i] <= mc_t[i - 1]);
                assert!(mc_m[i] <= mc_m[i - 1]);
            };
            i = i + 1;
        };
    }

    #[test]
    /// Thresholds are quote-unit sums, so a nine-decimal quote must land its
    /// breakpoints a thousand times higher than a six-decimal one.
    fun thresholds_scale_with_quote_decimals() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.bootstrap_quote<NINE_DP>(
            COIN_CLASS,
            MULTICOIN_CLASS,
            NINE_DP_UNIT,
            &cap,
            test.ctx(),
        );

        let schedule = policy.active_schedule(COIN_CLASS, test.ctx().epoch());
        let six_dp = six_dp_thresholds();
        let mut i = 0;
        while (i < GENESIS_TIERS) {
            assert_eq!(schedule.tier_at(i).min_turnover(), six_dp[i] * 1_000);
            i = i + 1;
        };

        // Rates are absolute, so they do not move with the quote's decimals.
        assert_eq!(schedule.tier_at(0).taker_fee(), 11_000_000);

        destroy(cap);
        policy.share_for_testing();
        end(test);
    }

    #[test]
    /// A trader is promoted exactly at a threshold, not one unit before it.
    fun each_threshold_promotes_on_its_own_boundary() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        policy.bootstrap_quote<CRED>(COIN_CLASS, MULTICOIN_CLASS, SIX_DP, &cap, test.ctx());

        let epoch = test.ctx().epoch();
        let thresholds = six_dp_thresholds();
        let takers = coin_takers();
        let makers = coin_makers();

        // A brand-new account with no turnover sits on the entry rung.
        let (tier, taker, maker) = policy.resolve(COIN_CLASS, 0, epoch);
        assert_eq!(tier, 0);
        assert_eq!(taker, takers[0]);
        assert_eq!(maker, makers[0]);

        let mut i = 1;
        while (i < GENESIS_TIERS) {
            // One unit short of the breakpoint is still the previous rung.
            let (below, below_taker, _) = policy.resolve(COIN_CLASS, thresholds[i] - 1, epoch);
            assert_eq!(below, i - 1);
            assert_eq!(below_taker, takers[i - 1]);

            // Landing exactly on it promotes.
            let (at, at_taker, at_maker) = policy.resolve(COIN_CLASS, thresholds[i], epoch);
            assert_eq!(at, i);
            assert_eq!(at_taker, takers[i]);
            assert_eq!(at_maker, makers[i]);

            i = i + 1;
        };

        // Turnover far past the top rung stays on the top rung.
        let (top, top_taker, _) = policy.resolve(
            COIN_CLASS,
            thresholds[GENESIS_TIERS - 1] * 1_000,
            epoch,
        );
        assert_eq!(top, GENESIS_TIERS - 1);
        assert_eq!(top_taker, takers[GENESIS_TIERS - 1]);

        destroy(cap);
        policy.share_for_testing();
        end(test);
    }

    #[test, expected_failure(abort_code = triex::fee_policy::EDuplicateGenesisClass)]
    fun bootstrap_rejects_identical_class_ids() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        // Both kinds into one class would silently price multicoin pools as coin
        // pools; the second `create_class` would abort anyway, but this fails on
        // the argument rather than halfway through the setup.
        policy.bootstrap_quote<CRED>(COIN_CLASS, COIN_CLASS, SIX_DP, &cap, test.ctx());

        destroy(cap);
        policy.share_for_testing();
        end(test);
    }

    #[test, expected_failure(abort_code = triex::fee_policy::EInvalidQuoteUnit)]
    fun bootstrap_rejects_zero_quote_unit() {
        let mut test = begin(OWNER);
        let mut policy = fee_policy::create_for_testing(test.ctx());
        let cap = registry::get_admin_cap_for_testing(test.ctx());

        // A zero scale would collapse every threshold to zero, putting every
        // trader on the top rung from their first trade.
        policy.bootstrap_quote<CRED>(COIN_CLASS, MULTICOIN_CLASS, 0, &cap, test.ctx());

        destroy(cap);
        policy.share_for_testing();
        end(test);
    }
}
