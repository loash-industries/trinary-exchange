/// History module tracks the fees a pool has recognized as collected.
///
/// Nothing on chain reads this back and nothing is emitted from it. The figure
/// is independently derivable from the per-trade events — `OrderFilled` carries
/// both sides' fees, `OrderCanceled` / `OrderExpired` / `OrderModified` carry
/// the retained share of released escrow — so the off-chain indexer is the
/// source of truth for fee accounting. What remains here is the observation
/// point the state tests assert fee recognition against, which costs three
/// additions on a struct the pool object already writes.
///
/// Everything epochal is gone: no rollover, no per-epoch archive, no volume
/// median and no event. Crossing an epoch boundary costs a pool nothing.
///
/// Fee rates are deliberately not recorded here either: they live per class in
/// the shared `FeePolicy` object, whose `FeeClassUpdated` events are the
/// schedule history, and orders carry their own maker rate.
module triex::history {
    use triex::balances::{Self, Balances};

    // === Structs ===
    public struct History has store {
        /// Fees recognized as collected over this pool's lifetime: fill-time
        /// taker and maker fees, plus retention kept from cancels, modify-downs
        /// and expiries. Cumulative — nothing resets it.
        total_fees_collected: Balances,
    }

    // === Public-Package Functions ===
    /// Create a new `History` instance. Called once upon pool creation.
    public(package) fun empty(): History {
        History { total_fees_collected: balances::empty() }
    }

    public(package) fun add_total_fees_collected(self: &mut History, fees: Balances) {
        self.total_fees_collected.add_balances(fees);
    }

    // === Test Functions ===
    #[test_only]
    public fun total_fees_collected_for_testing(self: &History): Balances {
        self.total_fees_collected
    }
}
