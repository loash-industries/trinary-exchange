/// Fee turnover module tracks how much an account has paid in fees over a
/// trailing window of epochs, which is the metric a `FeeSchedule` resolves a
/// trader's tier against.
///
/// Only fees recognized as protocol revenue at fill are ever recorded here:
/// taker fees paid, and maker fees the fill earned out. Escrow a bid maker can
/// still cancel or expire out of is refundable, so counting it would let a
/// trader climb the ladder on orders that never traded — the loophole this
/// metric exists to close. Retention kept from a cancel is revenue but not
/// turnover either, on the same reasoning `state::recognize_retention` already
/// applies to volume.
///
/// The window is a fixed-size ring of per-epoch buckets. `rolling_sum` is
/// maintained as an invariant rather than recomputed, so resolving a tier is
/// O(1) and only the epoch rollover pays for eviction.
module triexbook::fee_turnover;

use triexbook::constants;

// === Errors ===
const EEpochAhead: u64 = 0;

// === Structs ===
/// A fee credit tagged with the epoch it was earned in. Maker fees are
/// recognized in transactions that do not carry the maker's `BalanceManager`,
/// so pools hold them as pending entries of this shape until the maker's own
/// next transaction folds them into the BM-hosted ring — see `record_at`.
public struct EpochAmount has copy, drop, store {
    epoch: u64,
    amount: u64,
}

public struct FeeTurnover has copy, drop, store {
    /// Epoch the newest bucket belongs to.
    anchor_epoch: u64,
    /// One bucket per epoch of the window, in quote units.
    buckets: vector<u64>,
    /// Index of the newest bucket.
    head: u64,
    /// Invariant: equal to the sum of `buckets`.
    rolling_sum: u128,
}

// === Public-View Functions ===
/// Fees this account has paid across the trailing window, as of the last time
/// the ring was rolled. Callers on the trade path roll first, so this is exact
/// there; read-only callers should prefer `total_at`.
public fun total(self: &FeeTurnover): u128 {
    self.rolling_sum
}

/// Fees in the trailing window as of `epoch`, without mutating.
///
/// Rolling is lazy, so a dormant account's `rolling_sum` still includes buckets
/// that have since aged out. Views must not report that stale figure — a trader
/// would see a tier they no longer have, and would be charged the real rate
/// anyway once `roll` catches up on their next trade. This computes what `roll`
/// would leave behind, and the two are asserted equal in tests.
public fun total_at(self: &FeeTurnover, epoch: u64): u128 {
    if (epoch <= self.anchor_epoch) return self.rolling_sum;

    let window = constants::turnover_window_epochs();
    let elapsed = epoch - self.anchor_epoch;
    if (elapsed >= window) return 0;

    let mut total = self.rolling_sum;
    let mut head = self.head;
    let mut rolled = 0;
    while (rolled < elapsed) {
        head = (head + 1) % window;
        total = total - (self.buckets[head] as u128);
        rolled = rolled + 1;
    };

    total
}

// === Public-Package Functions ===
public(package) fun empty(epoch: u64): FeeTurnover {
    let window = constants::turnover_window_epochs();
    let mut buckets = vector[];
    let mut i = 0;
    while (i < window) {
        buckets.push_back(0);
        i = i + 1;
    };

    FeeTurnover { anchor_epoch: epoch, buckets, head: 0, rolling_sum: 0 }
}

/// Advance the ring to `epoch`, evicting whatever fell out of the window.
///
/// Lazy: nothing happens until an account is next touched, so a dormant account
/// costs nothing until it trades again. Cost is O(epochs elapsed), capped at the
/// window length, and zero in the common case of a second trade in the same
/// epoch.
public(package) fun roll(self: &mut FeeTurnover, epoch: u64) {
    if (epoch <= self.anchor_epoch) return;

    let window = constants::turnover_window_epochs();
    let elapsed = epoch - self.anchor_epoch;

    if (elapsed >= window) {
        // Dormant for at least a full window, so every bucket has aged out.
        // Clearing directly keeps this O(window) instead of O(elapsed), which
        // matters because `elapsed` is unbounded.
        let mut i = 0;
        while (i < window) {
            *self.buckets.borrow_mut(i) = 0;
            i = i + 1;
        };
        self.head = 0;
        self.rolling_sum = 0;
    } else {
        let mut rolled = 0;
        while (rolled < elapsed) {
            let head = (self.head + 1) % window;
            self.head = head;
            let evicted = self.buckets[head];
            if (evicted > 0) {
                self.rolling_sum = self.rolling_sum - (evicted as u128);
                *self.buckets.borrow_mut(head) = 0;
            };
            rolled = rolled + 1;
        };
    };

    self.anchor_epoch = epoch;
}

/// Credit fees to the current bucket. Callers must have rolled the ring to the
/// current epoch first.
public(package) fun record(self: &mut FeeTurnover, amount: u64) {
    if (amount == 0) return;

    let head = self.head;
    let bucket = self.buckets.borrow_mut(head);
    *bucket = *bucket + amount;
    self.rolling_sum = self.rolling_sum + (amount as u128);
}

/// Credit fees into the bucket of the epoch they were earned in, which may be
/// behind the head. This is what makes folding a pool's pending maker credits
/// exact: turnover lands where per-account-per-pool tracking would have put it,
/// just later. Entries that have already aged out of the window are dropped.
/// Callers must have rolled the ring to the current epoch first.
public(package) fun record_at(self: &mut FeeTurnover, epoch: u64, amount: u64) {
    if (amount == 0) return;
    // Pending entries are earned at fill time, so they can never postdate a
    // ring rolled to the current epoch.
    assert!(epoch <= self.anchor_epoch, EEpochAhead);

    let window = constants::turnover_window_epochs();
    let behind = self.anchor_epoch - epoch;
    if (behind >= window) return;

    let index = (self.head + window - behind) % window;
    let bucket = self.buckets.borrow_mut(index);
    *bucket = *bucket + amount;
    self.rolling_sum = self.rolling_sum + (amount as u128);
}

// === EpochAmount ===
public(package) fun new_epoch_amount(epoch: u64, amount: u64): EpochAmount {
    EpochAmount { epoch, amount }
}

public fun entry_epoch(self: &EpochAmount): u64 {
    self.epoch
}

public fun entry_amount(self: &EpochAmount): u64 {
    self.amount
}

public(package) fun add_to_entry(self: &mut EpochAmount, amount: u64) {
    self.amount = self.amount + amount;
}

// === Test Functions ===
#[test_only]
public fun anchor_epoch(self: &FeeTurnover): u64 {
    self.anchor_epoch
}

#[test_only]
public fun head(self: &FeeTurnover): u64 {
    self.head
}

#[test_only]
public fun bucket_at(self: &FeeTurnover, index: u64): u64 {
    self.buckets[index]
}

/// Recompute the sum from the buckets, for asserting the `rolling_sum`
/// invariant in tests.
#[test_only]
public fun sum_buckets(self: &FeeTurnover): u128 {
    let mut sum = 0u128;
    let mut i = 0;
    while (i < self.buckets.length()) {
        sum = sum + (self.buckets[i] as u128);
        i = i + 1;
    };

    sum
}
