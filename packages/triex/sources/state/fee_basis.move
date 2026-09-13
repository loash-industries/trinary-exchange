/// Fee basis module tracks, per pool and per epoch, the fee revenue recognized
/// on that pool which has not yet been priced into a hub operator's share.
///
/// The counter holds the **basis** — revenue recognized, undivided — rather than
/// the split. That is what keeps the share rate off the trading path entirely: a
/// fill, a cancel and an expiry each add a `u64` and read no policy object,
/// while `settle` applies epoch *N*'s rate to epoch *N*'s basis later and
/// off the hot path. Two of the three recognition sites (`cancel_order`,
/// `modify_order`) have no `&FeePolicy` in scope and cannot get one without a
/// public signature change, so accumulating the basis is not an optimization
/// here — it is the only shape that fits.
///
/// Only revenue is ever credited. A bid maker's fee is escrow until their order
/// resolves, so it is credited at earn-out (fill, expiry retention, or the
/// retained share of a cancel) and never at deposit — the same distinction
/// `fee_turnover` draws, and for the same reason: counting refundable escrow
/// would pay an operator for orders that never traded.
///
/// The window is a fixed-size ring of per-epoch buckets, in `fee_turnover`'s
/// shape. `unsettled` is maintained as an invariant rather than re-summed,
/// because `withdraw_pool_fees` reads it inside an assert and must not pay for a
/// loop over the window. Eviction is the settle-by deadline made mechanical: a
/// bucket that ages out unsettled is forfeited, and `roll` hands the caller the
/// amounts so the forfeiture is emitted rather than silently released into the
/// next treasury sweep.
module triex::fee_basis {
    use triex::constants;

    // === Errors ===
    const EEpochAhead: u64 = 0;
    const EInsufficientBasis: u64 = 1;

    // === Structs ===
    /// A basis amount tagged with the epoch whose rate prices it.
    public struct EpochBasis has copy, drop, store {
        epoch: u64,
        amount: u64,
    }

    /// `copy, drop, store` matches `FeeTurnover`: both are plain per-epoch ring
    /// counters embedded by value in a longer-lived object, and neither owns any
    /// coins — the balance a basis is a claim against lives in the vault's
    /// `quote_fee_reserve`.
    public struct FeeBasis has copy, drop, store {
        /// Epoch the newest bucket belongs to.
        anchor_epoch: u64,
        /// One bucket per epoch of the window, in quote units.
        buckets: vector<u64>,
        /// Index of the newest bucket.
        head: u64,
        /// Invariant: equal to the sum of `buckets`. `u128` because the buckets
        /// are `u64` and there are `HUB_BASIS_WINDOW_EPOCHS` of them.
        unsettled: u128,
    }

    // === Public-View Functions ===
    /// Recognized-but-unpriced revenue across the whole window. This is the
    /// figure `withdraw_pool_fees` holds back a `MAX_HUB_SHARE_BPS` slice of, so
    /// it has to be O(1).
    public fun unsettled(self: &FeeBasis): u128 {
        self.unsettled
    }

    public fun anchor_epoch(self: &FeeBasis): u64 {
        self.anchor_epoch
    }

    /// Basis standing against `epoch`, or zero if that epoch is outside the
    /// window. Does not mutate, so a stale ring reports what it currently holds;
    /// callers that need the post-eviction figure roll first.
    public fun basis_at(self: &FeeBasis, epoch: u64): u64 {
        if (epoch > self.anchor_epoch) return 0;
        let window = constants::hub_basis_window_epochs();
        let behind = self.anchor_epoch - epoch;
        if (behind >= window) return 0;

        self.buckets[(self.head + window - behind) % window]
    }

    // === Public-Package Functions ===
    public(package) fun empty(epoch: u64): FeeBasis {
        let window = constants::hub_basis_window_epochs();
        let mut buckets = vector[];
        let mut i = 0;
        while (i < window) {
            buckets.push_back(0);
            i = i + 1;
        };

        FeeBasis { anchor_epoch: epoch, buckets, head: 0, unsettled: 0 }
    }

    /// Advance the ring to `epoch`, returning whatever aged out unsettled so the
    /// caller can emit it. Lazy, in `fee_turnover::roll`'s shape: a pool that
    /// does not trade costs nothing until it does, and a second fill in the same
    /// epoch costs nothing at all.
    ///
    /// The returned vector is empty in every case except an actual forfeiture,
    /// which is the rare one — so the allocation does not land on the common
    /// recognition path.
    public(package) fun roll(self: &mut FeeBasis, epoch: u64): vector<EpochBasis> {
        let mut forfeited = vector[];
        if (epoch <= self.anchor_epoch) return forfeited;

        let window = constants::hub_basis_window_epochs();
        let elapsed = epoch - self.anchor_epoch;

        if (elapsed >= window) {
            // Untouched for at least a full window: every bucket has aged out.
            // Walk oldest-to-newest so the forfeitures come out in epoch order.
            let mut i = 1;
            while (i <= window) {
                let index = (self.head + i) % window;
                let evicted = self.buckets[index];
                if (evicted > 0) {
                    // The bucket `i` steps forward of the head is the one
                    // `window - i` epochs behind the old anchor.
                    forfeited.push_back(EpochBasis {
                        epoch: self.anchor_epoch - (window - i),
                        amount: evicted,
                    });
                    *self.buckets.borrow_mut(index) = 0;
                };
                i = i + 1;
            };
            self.head = 0;
            self.unsettled = 0;
        } else {
            let mut rolled = 0;
            while (rolled < elapsed) {
                let head = (self.head + 1) % window;
                self.head = head;
                let evicted = self.buckets[head];
                if (evicted > 0) {
                    forfeited.push_back(EpochBasis {
                        epoch: self.anchor_epoch + rolled + 1 - window,
                        amount: evicted,
                    });
                    self.unsettled = self.unsettled - (evicted as u128);
                    *self.buckets.borrow_mut(head) = 0;
                };
                rolled = rolled + 1;
            };
        };

        self.anchor_epoch = epoch;
        forfeited
    }

    /// Roll to `epoch` and credit recognized revenue to it. Returns anything the
    /// roll forfeited.
    public(package) fun accrue(
        self: &mut FeeBasis,
        epoch: u64,
        amount: u64,
    ): vector<EpochBasis> {
        let forfeited = self.roll(epoch);
        if (amount > 0) {
            let head = self.head;
            let bucket = self.buckets.borrow_mut(head);
            *bucket = *bucket + amount;
            self.unsettled = self.unsettled + (amount as u128);
        };

        forfeited
    }

    /// Take back basis credited to `epoch`. Used where a deposit credits the
    /// whole fee and the escrow half has to come straight back out — see
    /// `multicoin_vault::settle_trading_account`. Never a correction for
    /// something already settled: settlement zeroes the bucket, so an uncredit
    /// against a settled epoch aborts rather than going negative.
    public(package) fun uncredit(self: &mut FeeBasis, epoch: u64, amount: u64) {
        if (amount == 0) return;
        assert!(epoch <= self.anchor_epoch, EEpochAhead);

        let window = constants::hub_basis_window_epochs();
        let behind = self.anchor_epoch - epoch;
        assert!(behind < window, EInsufficientBasis);

        let index = (self.head + window - behind) % window;
        let bucket = self.buckets.borrow_mut(index);
        assert!(*bucket >= amount, EInsufficientBasis);
        *bucket = *bucket - amount;
        self.unsettled = self.unsettled - (amount as u128);
    }

    /// Every epoch currently carrying basis, oldest first, so a settlement can
    /// price each one at its own rate. O(window), off the trading path.
    public(package) fun pending(self: &FeeBasis): vector<EpochBasis> {
        let window = constants::hub_basis_window_epochs();
        let mut out = vector[];
        let mut i = 1;
        while (i <= window) {
            let index = (self.head + i) % window;
            let amount = self.buckets[index];
            if (amount > 0) {
                out.push_back(EpochBasis {
                    epoch: self.anchor_epoch - (window - i),
                    amount,
                });
            };
            i = i + 1;
        };

        out
    }

    /// Zero `epoch`'s bucket and return what it held, for a settlement that has
    /// priced it. Returns zero if the epoch is outside the window.
    public(package) fun take(self: &mut FeeBasis, epoch: u64): u64 {
        if (epoch > self.anchor_epoch) return 0;
        let window = constants::hub_basis_window_epochs();
        let behind = self.anchor_epoch - epoch;
        if (behind >= window) return 0;

        let index = (self.head + window - behind) % window;
        let bucket = self.buckets.borrow_mut(index);
        let amount = *bucket;
        if (amount > 0) {
            *bucket = 0;
            self.unsettled = self.unsettled - (amount as u128);
        };

        amount
    }

    // === EpochBasis ===
    public fun basis_epoch(self: &EpochBasis): u64 {
        self.epoch
    }

    public fun basis_amount(self: &EpochBasis): u64 {
        self.amount
    }

    // === Test Functions ===
    #[test_only]
    public fun head(self: &FeeBasis): u64 {
        self.head
    }

    #[test_only]
    public fun bucket_at(self: &FeeBasis, index: u64): u64 {
        self.buckets[index]
    }

    /// Recompute the sum from the buckets, for asserting the `unsettled`
    /// invariant in tests.
    #[test_only]
    public fun sum_buckets(self: &FeeBasis): u128 {
        let mut sum = 0u128;
        let mut i = 0;
        while (i < self.buckets.length()) {
            sum = sum + (self.buckets[i] as u128);
            i = i + 1;
        };

        sum
    }
}
