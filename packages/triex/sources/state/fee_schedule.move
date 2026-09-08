/// Fee schedule module holds the tier ladder a pool prices trades against.
///
/// A schedule is a step function, not a set of marginal brackets: an order is
/// charged entirely at the rate of the tier its trader occupied *before* the
/// order. Turnover from the order accrues afterwards, so an order can never
/// discount itself, and crossing a threshold applies from the next order on.
///
/// The metric a schedule is resolved against is an account's trailing fee
/// turnover (`fee_turnover`), which counts only fees recognized as protocol
/// revenue at fill. Escrow a maker can still cancel out of is deliberately not
/// in it, so resting orders buy no tier progress.
module triexbook::fee_schedule {
    use triexbook::constants;

    // === Errors ===
    const EEmptySchedule: u64 = 0;
    const EFirstTierNotZero: u64 = 1;
    const EThresholdsNotAscending: u64 = 2;
    const ETakerRateNotMonotone: u64 = 3;
    const EMakerRateNotMonotone: u64 = 4;
    const ETooManyTiers: u64 = 5;
    const EInvalidTakerFee: u64 = 6;
    const EInvalidMakerFee: u64 = 7;
    const EVectorLengthMismatch: u64 = 8;

    // === Structs ===
    /// One rung of the ladder.
    public struct FeeTier has copy, drop, store {
        /// Inclusive lower bound on trailing fee turnover, in quote units.
        min_turnover: u128,
        taker_fee: u64,
        maker_fee: u64,
    }

    /// The ladder. `tiers[0].min_turnover` is always zero, so every account
    /// resolves to some tier and there is no "unset" case to handle at fill time.
    public struct FeeSchedule has copy, drop, store {
        tiers: vector<FeeTier>,
    }

    // === Public-View Functions ===
    public fun tier_count(self: &FeeSchedule): u64 {
        self.tiers.length()
    }

    public fun tier_at(self: &FeeSchedule, index: u64): &FeeTier {
        &self.tiers[index]
    }

    public fun min_turnover(self: &FeeTier): u128 {
        self.min_turnover
    }

    public fun taker_fee(self: &FeeTier): u64 {
        self.taker_fee
    }

    public fun maker_fee(self: &FeeTier): u64 {
        self.maker_fee
    }

    // === Public-Package Functions ===
    /// Build a schedule from parallel vectors. Entry functions cannot take Move
    /// structs as arguments, so an admin transaction supplies the columns and the
    /// package assembles them.
    public(package) fun from_vectors(
        min_turnovers: vector<u128>,
        taker_fees: vector<u64>,
        maker_fees: vector<u64>,
    ): FeeSchedule {
        let len = min_turnovers.length();
        assert!(taker_fees.length() == len, EVectorLengthMismatch);
        assert!(maker_fees.length() == len, EVectorLengthMismatch);

        let mut tiers = vector[];
        let mut i = 0;
        while (i < len) {
            tiers.push_back(FeeTier {
                min_turnover: min_turnovers[i],
                taker_fee: taker_fees[i],
                maker_fee: maker_fees[i],
            });
            i = i + 1;
        };

        FeeSchedule { tiers }
    }

    /// The tier an account with `turnover` occupies, and its rates.
    ///
    /// Linear scan rather than binary search: schedules are capped at
    /// `MAX_FEE_TIERS`, and the scan exits at the first threshold above `turnover`,
    /// so the common case of a low-turnover account is the cheapest one.
    public(package) fun resolve(self: &FeeSchedule, turnover: u128): (u64, u64, u64) {
        let tiers = &self.tiers;
        let len = tiers.length();

        // Tier 0 always qualifies, so the scan starts at 1.
        let mut index = 0;
        let mut i = 1;
        while (i < len) {
            if (tiers[i].min_turnover > turnover) break;
            index = i;
            i = i + 1;
        };

        let tier = &tiers[index];
        (index, tier.taker_fee, tier.maker_fee)
    }

    /// Rates of the entry rung. These are what `TradeParams` carries, so views and
    /// events that report "the pool's fee" keep reporting the rate a new trader
    /// actually pays.
    public(package) fun base_taker_fee(self: &FeeSchedule): u64 {
        self.tiers[0].taker_fee
    }

    public(package) fun base_maker_fee(self: &FeeSchedule): u64 {
        self.tiers[0].maker_fee
    }

    /// Validate a schedule against the exchange's hard bounds.
    ///
    /// Bounds are passed in rather than read from `fee_policy` so this module
    /// stays a leaf; `fee_policy` supplies its own constants. Maker rates
    /// deliberately have no floor — zero is a legitimate rate — while takers keep
    /// theirs.
    public(package) fun validate(
        self: &FeeSchedule,
        min_taker_fee: u64,
        max_taker_fee: u64,
        max_maker_fee: u64,
        fee_multiple: u64,
    ) {
        let tiers = &self.tiers;
        let len = tiers.length();
        assert!(len > 0, EEmptySchedule);
        assert!(len <= constants::max_fee_tiers(), ETooManyTiers);
        assert!(tiers[0].min_turnover == 0, EFirstTierNotZero);

        let mut i = 0;
        while (i < len) {
            let tier = &tiers[i];
            assert!(tier.taker_fee % fee_multiple == 0, EInvalidTakerFee);
            assert!(tier.maker_fee % fee_multiple == 0, EInvalidMakerFee);
            assert!(tier.taker_fee >= min_taker_fee, EInvalidTakerFee);
            assert!(tier.taker_fee <= max_taker_fee, EInvalidTakerFee);
            assert!(tier.maker_fee <= max_maker_fee, EInvalidMakerFee);

            if (i > 0) {
                let prev = &tiers[i - 1];
                assert!(tier.min_turnover > prev.min_turnover, EThresholdsNotAscending);
                // More turnover must never cost more, on either side.
                assert!(tier.taker_fee <= prev.taker_fee, ETakerRateNotMonotone);
                assert!(tier.maker_fee <= prev.maker_fee, EMakerRateNotMonotone);
            };

            i = i + 1;
        };
    }
}
