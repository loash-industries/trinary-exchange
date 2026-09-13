/// Fee policy module holds every fee schedule on the exchange in one shared
/// object, read (immutably) by every trade. Pools store a 2-byte class id and
/// nothing else; a class is any pricing group — "standard CRED-quoted pools",
/// "multicoin pools", or a single negotiated market-maker deal, which is just a
/// class with one pool in it.
///
/// INVARIANT: `FeePolicy` must stay read-mostly. Writes are admin-only and
/// epoch-cadence by design; nothing on any user-reachable path may ever take it
/// `&mut`. Immutable reads of a shared object commute, so arbitrarily many
/// trades read this object in parallel — exactly as the whole network reads
/// `Clock` — but a write path on user flow would serialize the entire exchange.
///
/// Schedule changes are staged: `update_class` writes `next` with
/// `effective_epoch = now + 1`, and reads pick `next` once its epoch arrives.
/// A pricing change is therefore pre-announced and never re-prices a trade
/// mid-epoch, with no per-pool promotion machinery.
module triex::fee_policy {
    use std::type_name::{Self, TypeName};
    use sui::{dynamic_field as df, event, table::{Self, Table}};
    use triex::{constants, fee_schedule::{Self, FeeSchedule}, registry::TriexAdminCap};

    // === Errors ===
    const EClassAlreadyExists: u64 = 0;
    const EClassDoesNotExist: u64 = 1;
    const EInvalidCancelRetention: u64 = 2;
    const ENoDefaultClassForQuote: u64 = 3;
    const EClassQuoteMismatch: u64 = 4;
    const EDuplicateGenesisClass: u64 = 5;
    const EInvalidQuoteUnit: u64 = 6;
    const EHubShareAboveCeiling: u64 = 7;

    // === Constants ===
    const FEE_MULTIPLE: u64 = 1000; // 0.01 basis points
    const MIN_TAKER_FEE: u64 = 100000; // 1 basis point
    // Maker rates may be zero; only takers keep a floor. The caps bound what the
    // admin can ever set.
    const MAX_TAKER_FEE: u64 = 1000000000; // 10,000 basis points (100%)
    const MAX_MAKER_FEE: u64 = 1000000000; // 10,000 basis points (100%)

    /// Share of released bid-maker escrow the protocol keeps on cancel, modify-down
    /// or expiry. Full basis points, so the cap is a 100% retention (no refund).
    const MAX_CANCEL_RETENTION_BPS: u64 = 10000;

    // === Genesis ladder ===
    // Launch pricing, written by `bootstrap_quote`. Eight tiers, hand-specified
    // rather than derived from a single discount formula — each column decreases
    // on its own curve, rounded to the nearest 0.01% (still a `FEE_MULTIPLE`
    // multiple, and two orders of magnitude finer than the floor it needs to
    // clear). Multicoin prices at exactly double the coin-pool entry rate — that
    // relationship is deliberate and pinned by a test — but the two ladders are
    // not proportional tier-for-tier above the entry rung; each rate above tier 0
    // was chosen independently.
    const GENESIS_CANCEL_RETENTION_BPS: u64 = 2000; // 20% retained

    /// Coin pools: 1.10% taker / 0.90% maker at the entry tier, down to
    /// 0.55% / 0.45% at the top.
    fun coin_taker_fees(): vector<u64> {
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

    fun coin_maker_fees(): vector<u64> {
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

    /// Multicoin pools: exactly double the coin-pool entry rate — 2.20% taker /
    /// 1.80% maker — down to 1.10% / 0.90% at the top.
    fun multicoin_taker_fees(): vector<u64> {
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

    fun multicoin_maker_fees(): vector<u64> {
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

    /// Tier thresholds, scaled to a quote whose smallest unit is `quote_unit`
    /// (10^decimals).
    ///
    /// Denominated in fees *paid*, not notional traded: the turnover ring
    /// accumulates fee revenue, so reading these as trade size understates them by
    /// roughly the entry rate — 20k of fees is on the order of 1.8M of actual
    /// trading at 1.1%.
    ///
    /// Set two orders of magnitude above TRIEX-137 §11's ladder carried through the
    /// entry rate, so the rungs target sustained institutional flow rather than
    /// retail activity. The upper rungs are deliberately far out; they are headroom,
    /// and `update_class` can pull the whole ladder down for the next epoch without
    /// touching a single trader's accrued turnover.
    fun genesis_thresholds(quote_unit: u128): vector<u128> {
        vector[
            0,
            20_000 * quote_unit,
            100_000 * quote_unit,
            500_000 * quote_unit,
            2_000_000 * quote_unit,
            10_000_000 * quote_unit,
            50_000_000 * quote_unit,
            200_000_000 * quote_unit,
        ]
    }

    // === Structs ===
    /// The one shared object all fee policy lives in.
    public struct FeePolicy has key {
        id: UID,
        /// class_id → schedule for that class.
        classes: Table<u16, ClassSchedule>,
        /// Quote type → class a permissionless coin pool of that quote is born
        /// into. Creators must not choose their own pricing, so creation reads
        /// this rather than taking a class argument.
        default_classes: Table<TypeName, u16>,
        /// Same, for multicoin pools, which price differently from coin pools
        /// with the same quote.
        multicoin_default_classes: Table<TypeName, u16>,
    }

    /// One class's pricing. `quote` pins the unit the schedule's turnover
    /// thresholds are denominated in; a pool may only join a class whose quote
    /// matches its own.
    public struct ClassSchedule has store {
        quote: TypeName,
        current: FeeSchedule,
        next: FeeSchedule,
        /// Epoch at which `next` takes over. Reads compare against the running
        /// epoch, so promotion needs no write.
        effective_epoch: u64,
        cancel_retention_bps: u64,
    }

    // === Events ===
    /// Schedule history lives in these events rather than on-chain: one event per
    /// class change, instead of one per pool.
    public struct FeeClassUpdated has copy, drop {
        class_id: u16,
        quote: TypeName,
        schedule: FeeSchedule,
        effective_epoch: u64,
        cancel_retention_bps: u64,
    }

    // === Init ===
    /// The policy object ships empty. Classes are created by the admin after
    /// publish — pool creation requires a default class for the pool's quote, so
    /// the bootstrap order is: approve quote, create class, create pools.
    fun init(ctx: &mut TxContext) {
        let policy = FeePolicy {
            id: object::new(ctx),
            classes: table::new(ctx),
            default_classes: table::new(ctx),
            multicoin_default_classes: table::new(ctx),
        };
        transfer::share_object(policy);
    }

    // === Public-Mutative Functions * ADMIN * ===
    /// Stand up the launch pricing for `QuoteAsset`: create its coin and multicoin
    /// classes on the genesis ladder and register both as the defaults new pools of
    /// that quote are born into. The entire post-publish fee setup for one quote,
    /// in one transaction.
    ///
    /// This is not optional plumbing. `FeePolicy` ships empty and `create_pool`
    /// resolves `default_class` for its quote, so until this has run for a quote,
    /// every attempt to create a pool of that quote aborts with
    /// `ENoDefaultClassForQuote`. Run it once per approved quote immediately after
    /// publish, before any pool creation.
    ///
    /// `quote_unit` is 10^decimals of `QuoteAsset` — 1_000_000 for CRED and USDC,
    /// 1_000_000_000 for SUI. Thresholds are quote-unit sums, so the ladder has to
    /// be scaled to the quote it prices; passing the wrong scale silently misprices
    /// every tier above the first, which is why it is an explicit argument rather
    /// than a guess.
    ///
    /// Class ids are the caller's to allocate and must not collide with an existing
    /// class — `create_class` aborts on a duplicate, so a mistake here fails the
    /// transaction rather than overwriting live pricing.
    public fun bootstrap_quote<QuoteAsset>(
        self: &mut FeePolicy,
        coin_class_id: u16,
        multicoin_class_id: u16,
        quote_unit: u128,
        cap: &TriexAdminCap,
        ctx: &TxContext,
    ) {
        assert!(coin_class_id != multicoin_class_id, EDuplicateGenesisClass);
        assert!(quote_unit > 0, EInvalidQuoteUnit);

        let thresholds = genesis_thresholds(quote_unit);

        self.create_class<QuoteAsset>(
            coin_class_id,
            thresholds,
            coin_taker_fees(),
            coin_maker_fees(),
            GENESIS_CANCEL_RETENTION_BPS,
            cap,
            ctx,
        );
        self.set_default_class<QuoteAsset>(coin_class_id, cap);

        self.create_class<QuoteAsset>(
            multicoin_class_id,
            thresholds,
            multicoin_taker_fees(),
            multicoin_maker_fees(),
            GENESIS_CANCEL_RETENTION_BPS,
            cap,
            ctx,
        );
        self.set_multicoin_default_class<QuoteAsset>(multicoin_class_id, cap);
    }

    /// Create a pricing class denominated in `QuoteAsset`, effective immediately —
    /// a new class has no traders to surprise. Takes columns rather than tier
    /// structs because entry functions cannot accept Move structs as arguments.
    public fun create_class<QuoteAsset>(
        self: &mut FeePolicy,
        class_id: u16,
        min_turnovers: vector<u128>,
        taker_fees: vector<u64>,
        maker_fees: vector<u64>,
        cancel_retention_bps: u64,
        _cap: &TriexAdminCap,
        ctx: &TxContext,
    ) {
        assert!(!self.classes.contains(class_id), EClassAlreadyExists);
        let schedule = validated_schedule(min_turnovers, taker_fees, maker_fees);
        assert!(cancel_retention_bps <= MAX_CANCEL_RETENTION_BPS, EInvalidCancelRetention);

        let quote = type_name::with_defining_ids<QuoteAsset>();
        self
            .classes
            .add(
                class_id,
                ClassSchedule {
                    quote,
                    current: schedule,
                    next: schedule,
                    effective_epoch: ctx.epoch(),
                    cancel_retention_bps,
                },
            );

        event::emit(FeeClassUpdated {
            class_id,
            quote,
            schedule,
            effective_epoch: ctx.epoch(),
            cancel_retention_bps,
        });
    }

    /// Re-price an existing class, staged for the next epoch. One transaction
    /// re-prices every pool of the class; no per-pool fan-out exists.
    public fun update_class(
        self: &mut FeePolicy,
        class_id: u16,
        min_turnovers: vector<u128>,
        taker_fees: vector<u64>,
        maker_fees: vector<u64>,
        cancel_retention_bps: u64,
        _cap: &TriexAdminCap,
        ctx: &TxContext,
    ) {
        assert!(self.classes.contains(class_id), EClassDoesNotExist);
        let schedule = validated_schedule(min_turnovers, taker_fees, maker_fees);
        assert!(cancel_retention_bps <= MAX_CANCEL_RETENTION_BPS, EInvalidCancelRetention);

        let class = self.classes.borrow_mut(class_id);
        // A pending `next` that has already come due is the running schedule;
        // promote it before overwriting, so the stage below replaces the future,
        // never the present.
        if (ctx.epoch() >= class.effective_epoch) {
            class.current = class.next;
        };
        class.next = schedule;
        class.effective_epoch = ctx.epoch() + 1;
        class.cancel_retention_bps = cancel_retention_bps;

        event::emit(FeeClassUpdated {
            class_id,
            quote: class.quote,
            schedule,
            effective_epoch: class.effective_epoch,
            cancel_retention_bps,
        });
    }

    /// Point permissionless coin-pool creation for `QuoteAsset` at `class_id`.
    public fun set_default_class<QuoteAsset>(
        self: &mut FeePolicy,
        class_id: u16,
        _cap: &TriexAdminCap,
    ) {
        let quote = type_name::with_defining_ids<QuoteAsset>();
        self.assert_class_matches_quote(class_id, quote);
        if (self.default_classes.contains(quote)) {
            self.default_classes.remove(quote);
        };
        self.default_classes.add(quote, class_id);
    }

    /// Same, for multicoin pools.
    public fun set_multicoin_default_class<QuoteAsset>(
        self: &mut FeePolicy,
        class_id: u16,
        _cap: &TriexAdminCap,
    ) {
        let quote = type_name::with_defining_ids<QuoteAsset>();
        self.assert_class_matches_quote(class_id, quote);
        if (self.multicoin_default_classes.contains(quote)) {
            self.multicoin_default_classes.remove(quote);
        };
        self.multicoin_default_classes.add(quote, class_id);
    }

    // === Public-View Functions ===
    public fun class_exists(self: &FeePolicy, class_id: u16): bool {
        self.classes.contains(class_id)
    }

    /// The schedule pricing trades of `class_id` in `epoch`.
    public fun active_schedule(self: &FeePolicy, class_id: u16, epoch: u64): FeeSchedule {
        assert!(self.classes.contains(class_id), EClassDoesNotExist);
        let class = &self.classes[class_id];
        if (epoch >= class.effective_epoch) class.next else class.current
    }

    /// The schedule staged to take over, and when. Equal to the active one when
    /// nothing is pending.
    public fun next_schedule(self: &FeePolicy, class_id: u16): (FeeSchedule, u64) {
        assert!(self.classes.contains(class_id), EClassDoesNotExist);
        let class = &self.classes[class_id];
        (class.next, class.effective_epoch)
    }

    public fun class_quote(self: &FeePolicy, class_id: u16): TypeName {
        assert!(self.classes.contains(class_id), EClassDoesNotExist);
        self.classes[class_id].quote
    }

    public fun cancel_retention_bps(self: &FeePolicy, class_id: u16): u64 {
        assert!(self.classes.contains(class_id), EClassDoesNotExist);
        self.classes[class_id].cancel_retention_bps
    }

    // === Public-Package Functions ===
    /// The tier an account with `turnover` occupies under `class_id` in `epoch`,
    /// and its (taker, maker) rates. This is the single resolution path every
    /// trade prices through.
    public(package) fun resolve(
        self: &FeePolicy,
        class_id: u16,
        turnover: u128,
        epoch: u64,
    ): (u64, u64, u64) {
        assert!(self.classes.contains(class_id), EClassDoesNotExist);
        let class = &self.classes[class_id];
        let schedule = if (epoch >= class.effective_epoch) &class.next else &class.current;

        schedule.resolve(turnover)
    }

    /// Same resolution as `resolve`, plus the class's cancel retention rate, out
    /// of a single class-table borrow. Order placement needs both in the same
    /// breath; resolving them separately would borrow the same class twice.
    public(package) fun resolve_with_retention(
        self: &FeePolicy,
        class_id: u16,
        turnover: u128,
        epoch: u64,
    ): (u64, u64, u64, u64) {
        assert!(self.classes.contains(class_id), EClassDoesNotExist);
        let class = &self.classes[class_id];
        let schedule = if (epoch >= class.effective_epoch) &class.next else &class.current;
        let (tier, taker_fee, maker_fee) = schedule.resolve(turnover);

        (tier, taker_fee, maker_fee, class.cancel_retention_bps)
    }

    /// Class a permissionless coin pool quoted in `quote` is born into.
    public(package) fun default_class(self: &FeePolicy, quote: TypeName): u16 {
        assert!(self.default_classes.contains(quote), ENoDefaultClassForQuote);
        self.default_classes[quote]
    }

    public(package) fun multicoin_default_class(self: &FeePolicy, quote: TypeName): u16 {
        assert!(self.multicoin_default_classes.contains(quote), ENoDefaultClassForQuote);
        self.multicoin_default_classes[quote]
    }

    /// A pool may only join a class denominated in its own quote — thresholds are
    /// quote-unit sums, so a mismatch would price against a meaningless number.
    public(package) fun assert_class_matches_quote(
        self: &FeePolicy,
        class_id: u16,
        quote: TypeName,
    ) {
        assert!(self.classes.contains(class_id), EClassDoesNotExist);
        assert!(self.classes[class_id].quote == quote, EClassQuoteMismatch);
    }

    // === Private Functions ===
    fun validated_schedule(
        min_turnovers: vector<u128>,
        taker_fees: vector<u64>,
        maker_fees: vector<u64>,
    ): FeeSchedule {
        let schedule = fee_schedule::from_vectors(min_turnovers, taker_fees, maker_fees);
        schedule.validate(MIN_TAKER_FEE, MAX_TAKER_FEE, MAX_MAKER_FEE, FEE_MULTIPLE);

        schedule
    }

    // === Test Functions ===
    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext): FeePolicy {
        FeePolicy {
            id: object::new(ctx),
            classes: table::new(ctx),
            default_classes: table::new(ctx),
            multicoin_default_classes: table::new(ctx),
        }
    }

    #[test_only]
    public fun share_for_testing(self: FeePolicy) {
        transfer::share_object(self)
    }

    // === Hub revenue share ===
    //
    // `FeePolicy` has a `UID` but no versioned inner, so its struct cannot gain
    // fields on an upgrade — dynamic fields on its `id` can. Everything below is
    // additive, and all of it is admin-written at epoch cadence, which is what the
    // module invariant allows. The operator-written half of this configuration —
    // the payout address — deliberately lives in `hub_registry` instead, because a
    // user-reachable `&mut` on this object would serialize every trade that reads
    // it.

    /// class_id -> the rate ladder for that class.
    public struct HubShareClassKey has copy, drop, store { class_id: u16 }

    /// collection_id -> the class that collection's hubs are priced in.
    public struct HubShareAssignmentKey has copy, drop, store { collection_id: ID }

    /// Class a collection nobody has configured falls into.
    public struct DefaultHubShareKey has copy, drop, store {}

    /// One rung of a hub-share ladder: `bps` applies to every epoch from
    /// `from_epoch` until the next segment's `from_epoch`.
    public struct HubShareSegment has copy, drop, store {
        from_epoch: u64,
        bps: u64,
    }

    public struct HubShareClassUpdated has copy, drop {
        class_id: u16,
        bps: u64,
        from_epoch: u64,
    }

    public struct HubShareClassAssigned has copy, drop {
        collection_id: ID,
        class_id: u16,
    }

    /// Re-price a hub-share class, effective next epoch.
    ///
    /// The ladder is **append-only**, not the `current`/`next` pair a
    /// `ClassSchedule` keeps. A share is settled against the rate of the epoch that
    /// earned the revenue, and settlement can lag by up to the basis window, so the
    /// policy has to be able to answer "what was the rate in epoch N?" for any
    /// epoch still in that window. A two-slot ladder loses that answer after the
    /// second re-price — precisely when settlement is late, which is when it is
    /// asked. Segments keep it.
    ///
    /// Pinning the rate to the epoch that earned it also takes the timing out of
    /// settlement. `settle_hub_share` is permissionless; if a share were priced at
    /// whatever the ladder said when someone called it, the call would be a free
    /// option on every staged change — settle early to dodge a cut, wait to
    /// capture a rise, and whichever party gains calls first.
    public fun stage_hub_share_class(
        self: &mut FeePolicy,
        class_id: u16,
        bps: u64,
        _cap: &TriexAdminCap,
        ctx: &TxContext,
    ) {
        assert!(bps <= constants::max_hub_share_bps(), EHubShareAboveCeiling);

        // Next epoch, never this one: a rate an operator has not had the chance to
        // read cannot apply to revenue they have already hosted.
        let from_epoch = ctx.epoch() + 1;
        let key = HubShareClassKey { class_id };

        if (!df::exists_with_type<HubShareClassKey, vector<HubShareSegment>>(&self.id, key)) {
            df::add(&mut self.id, key, vector[HubShareSegment { from_epoch, bps }]);
        } else {
            let segments: &mut vector<HubShareSegment> = df::borrow_mut(&mut self.id, key);
            let len = segments.length();
            // Two re-prices in one epoch would give the same `from_epoch` twice and
            // the ladder would stop being a function of the epoch. The later write
            // replaces the earlier: neither has taken effect yet.
            if (len > 0 && segments[len - 1].from_epoch == from_epoch) {
                *segments.borrow_mut(len - 1) = HubShareSegment { from_epoch, bps };
            } else {
                segments.push_back(HubShareSegment { from_epoch, bps });
            };
            prune_hub_share_segments(segments, ctx.epoch());
        };

        event::emit(HubShareClassUpdated { class_id, bps, from_epoch });
    }

    /// Drop segments no epoch inside the basis window can still resolve to. The
    /// window is the settle-by deadline, so a rate older than a basis that could
    /// still be settled is unreachable by construction.
    fun prune_hub_share_segments(segments: &mut vector<HubShareSegment>, epoch: u64) {
        let window = constants::hub_basis_window_epochs();
        let floor = if (epoch > window) epoch - window else 0;
        // Keep the last segment at or below the floor: it is the rate the floor
        // epoch itself resolves to. Anything before that one is shadowed.
        while (segments.length() > 1 && segments[1].from_epoch <= floor) {
            segments.remove(0);
        };
    }

    /// Point a collection's hubs at a share class. One write re-prices every pool
    /// of every asset in that collection.
    public fun assign_hub_share_class(
        self: &mut FeePolicy,
        collection_id: ID,
        class_id: u16,
        _cap: &TriexAdminCap,
    ) {
        let key = HubShareAssignmentKey { collection_id };
        if (df::exists_with_type<HubShareAssignmentKey, u16>(&self.id, key)) {
            let assigned: &mut u16 = df::borrow_mut(&mut self.id, key);
            *assigned = class_id;
        } else {
            df::add(&mut self.id, key, class_id);
        };

        event::emit(HubShareClassAssigned { collection_id, class_id });
    }

    /// Class for collections nobody has configured. Absent means zero, which is
    /// why deploying the feature changes nothing until a hub is assigned.
    public fun set_default_hub_share_class(
        self: &mut FeePolicy,
        class_id: u16,
        _cap: &TriexAdminCap,
    ) {
        let key = DefaultHubShareKey {};
        if (df::exists_with_type<DefaultHubShareKey, u16>(&self.id, key)) {
            let current: &mut u16 = df::borrow_mut(&mut self.id, key);
            *current = class_id;
        } else {
            df::add(&mut self.id, key, class_id);
        };
    }

    /// The share rate that applied to revenue recognized in `epoch`, in bps.
    ///
    /// Zero for an unconfigured collection, an unconfigured class, or an epoch
    /// before the class's first segment — so an unconfigured exchange settles
    /// every basis to nothing, and the feature is inert until someone configures
    /// it.
    public fun hub_share_bps_at(self: &FeePolicy, collection_id: ID, epoch: u64): u64 {
        let class_id = self.hub_share_class(collection_id);
        let key = HubShareClassKey { class_id };
        if (!df::exists_with_type<HubShareClassKey, vector<HubShareSegment>>(&self.id, key)) {
            return 0
        };

        let segments: &vector<HubShareSegment> = df::borrow(&self.id, key);
        let mut i = segments.length();
        while (i > 0) {
            i = i - 1;
            let segment = &segments[i];
            if (segment.from_epoch <= epoch) return segment.bps;
        };

        0
    }

    /// Share class a collection is priced in, falling back to the default class
    /// and then to class 0.
    public fun hub_share_class(self: &FeePolicy, collection_id: ID): u16 {
        let assignment = HubShareAssignmentKey { collection_id };
        if (df::exists_with_type<HubShareAssignmentKey, u16>(&self.id, assignment)) {
            return *df::borrow<HubShareAssignmentKey, u16>(&self.id, assignment)
        };

        let default = DefaultHubShareKey {};
        if (df::exists_with_type<DefaultHubShareKey, u16>(&self.id, default)) {
            return *df::borrow<DefaultHubShareKey, u16>(&self.id, default)
        };

        0
    }

    #[test_only]
    public fun hub_share_segment_count(self: &FeePolicy, class_id: u16): u64 {
        let key = HubShareClassKey { class_id };
        if (!df::exists_with_type<HubShareClassKey, vector<HubShareSegment>>(&self.id, key)) {
            return 0
        };
        df::borrow<HubShareClassKey, vector<HubShareSegment>>(&self.id, key).length()
    }

}
