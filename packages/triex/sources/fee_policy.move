/// Fee policy module holds every fee schedule on the exchange in one shared
/// object, read (immutably) by every trade. Pools store a 2-byte class id and
/// nothing else; a class is any pricing group — "standard CRED-quoted pools",
/// "multicoin pools", or a single negotiated market-maker deal, which is just a
/// class with one pool in it.
///
/// INVARIANT: `FeePolicy` must stay read-mostly. Writes are admin-only and
/// epoch-cadence by design; nothing on any *trading* path may ever take it
/// `&mut`. Immutable reads of a shared object commute, so arbitrarily many
/// trades read this object in parallel — exactly as the whole network reads
/// `Clock` — but a write path on user flow would serialize the entire exchange.
/// The one user-reachable write is operator beneficiary registration through
/// the admin-registered adapter witness — rare by nature (once per storage
/// unit), and never on the flow of an order. Pool creation reads immutably.
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
    const EOperatorShareAboveCeiling: u64 = 7;
    const EOperatorShareClassDoesNotExist: u64 = 8;
    const ENoAuthorizedAdapter: u64 = 9;
    const EUnauthorizedAdapter: u64 = 10;

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
    /// The fee tables ship empty — classes are created by the admin after
    /// publish, and pool creation requires a default class for the pool's quote,
    /// so the bootstrap order is: approve quote, create class, create pools. The
    /// hub-share side ships configured instead: see `new_policy`.
    fun init(ctx: &mut TxContext) {
        transfer::share_object(new_policy(ctx));
    }

    /// The one constructor. Seeds the genesis hub-share state
    /// `operator_share_class` resolves through: class 0, starting at zero bps,
    /// registered as the default class. Neither field has a removal path, so on
    /// an object built here resolution always lands on a real class — and class
    /// 0 has one defined meaning, "the class unassigned collections pay",
    /// rather than being a free id that happens to double as a fallback.
    ///
    /// This runs from `init`, so it seeds a *fresh publish* only. An upgrade
    /// keeps the already-shared `FeePolicy`, which never passed through here;
    /// `seed_operator_share_genesis` is the admin call that brings such an
    /// object up to this state, and the resolvers stay total in the meantime.
    fun new_policy(ctx: &mut TxContext): FeePolicy {
        let mut policy = FeePolicy {
            id: object::new(ctx),
            classes: table::new(ctx),
            default_classes: table::new(ctx),
            multicoin_default_classes: table::new(ctx),
        };

        df::add(
            &mut policy.id,
            OperatorShareClassKey { class_id: 0 },
            OperatorShareClass { current_bps: 0, next_bps: 0, effective_epoch: 0 },
        );
        df::add(&mut policy.id, DefaultOperatorShareKey {}, 0u16);

        policy
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
        new_policy(ctx)
    }

    #[test_only]
    public fun share_for_testing(self: FeePolicy) {
        transfer::share_object(self)
    }

    // === Operator revenue share ===
    //
    // `FeePolicy` has a `UID` but no versioned inner, so its struct cannot gain
    // fields on an upgrade — dynamic fields on its `id` can. Everything below is
    // additive. The rates are admin-written at epoch cadence, which is what the
    // module invariant allows. The payout address is written exactly once, on
    // presentation of the registered adapter's witness — the adapter package is
    // what binds the write to the storage unit's `OwnerCap`, so the address
    // pinned is the storage unit owner's, not whichever sender deployed a pool
    // first — and destroyed only by the admin cap. There is no rotation path,
    // witness-gated or otherwise: re-pointing revenue at another party is
    // deliberately not a thing these contracts do; any such delegation is
    // settled outside Triex.
    //
    // The rate is applied eagerly, at the moment revenue is recognized — see
    // `docs/trade-hub-revenue-share.md`, "Revision: split at recognition".
    // Recognition and pricing being the same instant is what lets a class hold a
    // plain staged pair instead of an append-only history: there is never a
    // deferred basis that could ask "what was the rate in epoch N?" after N.

    /// class_id -> the staged rate pair for that class.
    public struct OperatorShareClassKey has copy, drop, store { class_id: u16 }

    /// collection_id -> the class that collection's hubs are priced in.
    public struct OperatorShareAssignmentKey has copy, drop, store { collection_id: ID }

    /// Class a collection nobody has configured falls into. Written at genesis
    /// to class 0 and never removed, only re-pointed.
    public struct DefaultOperatorShareKey has copy, drop, store {}

    /// collection_id -> the address that collection's share is paid to.
    /// Written exactly once, through the registered adapter's witness;
    /// destroyed only via the admin cap. Absent means a claim aborts rather
    /// than guessing.
    public struct OperatorBeneficiaryKey has copy, drop, store { collection_id: ID }

    /// The one witness type allowed to register a beneficiary. Absent until the
    /// admin registers an adapter, which is the shipping state: no registration
    /// path exists at all until the adapter package has been audited and named.
    public struct AuthorizedAdapterKey has copy, drop, store {}

    /// A hub-share class's pricing, in `ClassSchedule`'s shape: `next` takes over
    /// at `effective_epoch`, and reads compare against the running epoch so
    /// promotion needs no write.
    ///
    /// The `effective_epoch` gate is written here deliberately rather than
    /// inherited by analogy — `cancel_retention_bps` on the fee classes is *not*
    /// staged, so "`FeePolicy` stages every rate change" is not a uniform
    /// precedent. A hub rate must be pre-announced: it is what an operator
    /// underwrites a hosting decision with.
    public struct OperatorShareClass has copy, drop, store {
        current_bps: u64,
        next_bps: u64,
        effective_epoch: u64,
    }

    public struct OperatorShareClassUpdated has copy, drop {
        class_id: u16,
        bps: u64,
        from_epoch: u64,
    }

    public struct OperatorShareClassAssigned has copy, drop {
        collection_id: ID,
        class_id: u16,
    }

    public struct OperatorBeneficiaryRegistered has copy, drop {
        collection_id: ID,
        beneficiary: address,
    }

    public struct OperatorBeneficiaryDestroyed has copy, drop {
        collection_id: ID,
    }

    public struct OperatorAdapterAuthorized has copy, drop {
        adapter: Option<TypeName>,
    }

    /// Re-price a hub-share class, effective next epoch.
    ///
    /// Next epoch, never this one: a rate an operator has not had the chance to
    /// read cannot apply to revenue they host after it lands. With the split
    /// applied at recognition, that staging is the whole timing story — there is
    /// no settlement step whose caller could gain by moving it.
    ///
    /// Class 0 exists from genesis as the default class, so staging class 0 is
    /// the explicit "re-price every unassigned collection" operation — never a
    /// fresh negotiated class that quietly doubles as a fallback.
    public fun stage_operator_share_class(
        self: &mut FeePolicy,
        class_id: u16,
        bps: u64,
        _cap: &TriexAdminCap,
        ctx: &TxContext,
    ) {
        assert!(bps <= constants::max_operator_share_bps(), EOperatorShareAboveCeiling);

        let from_epoch = ctx.epoch() + 1;
        let key = OperatorShareClassKey { class_id };

        if (!df::exists_with_type<OperatorShareClassKey, OperatorShareClass>(&self.id, key)) {
            // A new class starts at zero and the staged rate arrives next epoch:
            // no hub can be paid at a rate that was never announced.
            df::add(
                &mut self.id,
                key,
                OperatorShareClass { current_bps: 0, next_bps: bps, effective_epoch: from_epoch },
            );
        } else {
            let class: &mut OperatorShareClass = df::borrow_mut(&mut self.id, key);
            // A pending `next` that has already come due is the running rate;
            // promote it before overwriting, so the stage below replaces the
            // future, never the present.
            if (ctx.epoch() >= class.effective_epoch) {
                class.current_bps = class.next_bps;
            };
            class.next_bps = bps;
            class.effective_epoch = from_epoch;
        };

        event::emit(OperatorShareClassUpdated { class_id, bps, from_epoch });
    }

    /// Point a collection's hubs at a share class, effective immediately.
    ///
    /// Immediate is safe here in a way it was not under deferred settlement:
    /// with the split applied at recognition, an assignment can only affect
    /// revenue that has not happened yet. There is no unsettled basis for it to
    /// re-price retroactively. One write re-prices every pool of every asset in
    /// the collection, from now on.
    public fun assign_operator_share_class(
        self: &mut FeePolicy,
        collection_id: ID,
        class_id: u16,
        _cap: &TriexAdminCap,
    ) {
        // An unconfigured class resolves to zero, so a mistyped id would leave the
        // hub silently earning nothing — the one failure this configuration can have
        // that nobody notices until an operator asks where their payment is.
        assert!(self.operator_share_class_exists(class_id), EOperatorShareClassDoesNotExist);

        upsert(&mut self.id, OperatorShareAssignmentKey { collection_id }, class_id);

        event::emit(OperatorShareClassAssigned { collection_id, class_id });
    }

    /// Class for collections nobody has configured. Ships pointing at genesis
    /// class 0, which pays zero — deploying the feature changes nothing until a
    /// hub is assigned, class 0 is re-priced, or the default is re-pointed.
    public fun set_default_operator_share_class(
        self: &mut FeePolicy,
        class_id: u16,
        _cap: &TriexAdminCap,
    ) {
        assert!(self.operator_share_class_exists(class_id), EOperatorShareClassDoesNotExist);

        upsert(&mut self.id, DefaultOperatorShareKey {}, class_id);
    }

    /// Bring a `FeePolicy` that predates the hub share up to the state
    /// `new_policy` seeds at genesis: class 0 at zero bps, pointed at by the
    /// default key.
    ///
    /// `init` runs on a first publish, never on an upgrade, so an upgraded
    /// deployment inherits a policy object with neither field. The resolvers
    /// tolerate that — the feature is simply inert — but the admin still needs a
    /// way to switch it on, and `assign_operator_share_class` cannot be the
    /// first call because it requires a class that exists. This is that call.
    ///
    /// Idempotent and non-destructive: it only ever adds what is missing, so
    /// running it against an already-seeded policy — or twice — cannot reset a
    /// live rate or re-point a configured default.
    public fun seed_operator_share_genesis(self: &mut FeePolicy, _cap: &TriexAdminCap) {
        let class_key = OperatorShareClassKey { class_id: 0 };
        if (!df::exists_with_type<OperatorShareClassKey, OperatorShareClass>(&self.id, class_key)) {
            df::add(
                &mut self.id,
                class_key,
                OperatorShareClass { current_bps: 0, next_bps: 0, effective_epoch: 0 },
            );
        };

        let default_key = DefaultOperatorShareKey {};
        if (!df::exists_with_type<DefaultOperatorShareKey, u16>(&self.id, default_key)) {
            df::add(&mut self.id, default_key, 0u16);
        };
    }

    /// The share rate applying to revenue this collection's pools recognize in
    /// `epoch`, in bps.
    ///
    /// **Total by design — this must never abort.** It is resolved on the
    /// cancel and modify paths, where an abort would freeze user funds. Every
    /// lookup below is guarded rather than assumed: an unconfigured collection
    /// resolves through the genesis default, a policy object that predates the
    /// feature resolves through `operator_share_class`'s own final fallback to
    /// class 0, and a class id with no class on it resolves to zero here. The
    /// result is clamped to the ceiling as a belt over the write-time assert.
    ///
    /// The guards are not decorative. `init` seeds the genesis state on a first
    /// publish only, so an upgrade inherits a `FeePolicy` with none of these
    /// fields — and the paths that call this are the ones that release user
    /// escrow.
    public fun operator_share_bps_at(self: &FeePolicy, collection_id: ID, epoch: u64): u64 {
        let class_id = self.operator_share_class(collection_id);
        let key = OperatorShareClassKey { class_id };
        if (!df::exists_with_type<OperatorShareClassKey, OperatorShareClass>(&self.id, key)) {
            return 0
        };

        let class: &OperatorShareClass = df::borrow(&self.id, key);
        let bps = if (epoch >= class.effective_epoch) class.next_bps else class.current_bps;

        bps.min(constants::max_operator_share_bps())
    }

    public fun operator_share_class_exists(self: &FeePolicy, class_id: u16): bool {
        df::exists_with_type<OperatorShareClassKey, OperatorShareClass>(
            &self.id,
            OperatorShareClassKey { class_id },
        )
    }

    /// Share class a collection is priced in, falling back to the default
    /// class, and then to class 0.
    ///
    /// **Total, including on a policy object that predates this feature.**
    /// `new_policy` seeds the default key at genesis, but `init` runs only on a
    /// first publish — an upgrade over an already-shared `FeePolicy` inherits an
    /// object with neither the default key nor class 0 on it, and an unguarded
    /// borrow there would abort. That abort would land on `place_order`,
    /// `cancel_all_orders` and any bid `cancel_order`/`modify_order` that
    /// retains escrow, i.e. it would freeze open maker escrow on every multicoin
    /// pool until an admin transaction seeded the field. The final fallback is
    /// what makes the feature inert on such an object rather than fatal:
    /// `operator_share_bps_at` resolves a missing class to zero, so an
    /// unseeded policy pays no hub anything, which is the intended deploy state.
    public fun operator_share_class(self: &FeePolicy, collection_id: ID): u16 {
        let assignment = OperatorShareAssignmentKey { collection_id };
        if (df::exists_with_type<OperatorShareAssignmentKey, u16>(&self.id, assignment)) {
            return *df::borrow<OperatorShareAssignmentKey, u16>(&self.id, assignment)
        };

        let default_key = DefaultOperatorShareKey {};
        if (df::exists_with_type<DefaultOperatorShareKey, u16>(&self.id, default_key)) {
            return *df::borrow<DefaultOperatorShareKey, u16>(&self.id, default_key)
        };

        0
    }

    /// Register the one witness type allowed to register beneficiaries,
    /// replacing any previous registration.
    ///
    /// The type is what makes the gate real. A bare `<W: drop>` bound authorizes
    /// nothing — any package can declare a struct with `drop` and mint one — so a
    /// witness only proves anything if the callee pins which type it will accept.
    /// Pinning it by `TypeName` rather than by importing the adapter keeps Triex
    /// free of any dependency on the game world: it compares a name, it does not
    /// link a module.
    public fun set_operator_adapter<W: drop>(self: &mut FeePolicy, _cap: &TriexAdminCap) {
        let adapter = type_name::with_defining_ids<W>();
        upsert(&mut self.id, AuthorizedAdapterKey {}, adapter);

        event::emit(OperatorAdapterAuthorized { adapter: option::some(adapter) });
    }

    /// Set `key` to `value`, present or not — the dynamic-field upsert every
    /// single-valued setter above shares.
    fun upsert<K: copy + drop + store, V: drop + store>(id: &mut UID, key: K, value: V) {
        if (df::exists_with_type<K, V>(id, key)) {
            *df::borrow_mut<K, V>(id, key) = value;
        } else {
            df::add(id, key, value);
        };
    }

    /// Withdraw the adapter, closing the registration path entirely until a new
    /// one is registered. Mappings already written are untouched.
    public fun clear_operator_adapter(self: &mut FeePolicy, _cap: &TriexAdminCap) {
        let key = AuthorizedAdapterKey {};
        if (df::exists_with_type<AuthorizedAdapterKey, TypeName>(&self.id, key)) {
            df::remove<AuthorizedAdapterKey, TypeName>(&mut self.id, key);
            event::emit(OperatorAdapterAuthorized { adapter: option::none() });
        };
    }

    /// The registered adapter type, if registration is enabled.
    public fun operator_adapter(self: &FeePolicy): Option<TypeName> {
        let key = AuthorizedAdapterKey {};
        if (df::exists_with_type<AuthorizedAdapterKey, TypeName>(&self.id, key)) {
            option::some(*df::borrow<AuthorizedAdapterKey, TypeName>(&self.id, key))
        } else {
            option::none()
        }
    }

    /// Record where a collection's operator share is paid, on presentation of
    /// the registered adapter's witness. First write wins, and after it the
    /// contracts offer no way to re-point — a hub changing hands, or an operator
    /// wanting revenue elsewhere, is a settlement matter external to Triex. The
    /// admin cap can destroy a mapping, never redirect one; after a destroy,
    /// re-registration runs through this same gate, so the address can only ever
    /// be re-pinned by the storage unit's current owner.
    ///
    /// **What this trusts, stated plainly.** The witness proves the call came
    /// *through* the registered adapter. It does not prove anything about
    /// `collection_id` or `beneficiary`, because a witness cannot carry a payload
    /// Triex could verify — a struct is constructible only in its defining
    /// module, so any field Triex could read is a field the adapter alone can
    /// set, and reading it would be trusting the adapter anyway. The binding is
    /// the adapter's job: it takes the caller's `OwnerCap<StorageUnit>` and the
    /// `VaultConfig`, checks the cap against the config's storage unit and the
    /// config's collection against the one being registered, and only then mints
    /// the witness. That logic is what the admin audits before registering it,
    /// which is why registration is admin-only, single-valued, and revocable.
    public fun register_operator_beneficiary_with_witness<W: drop>(
        self: &mut FeePolicy,
        collection_id: ID,
        beneficiary: address,
        _witness: W,
    ) {
        let adapter_key = AuthorizedAdapterKey {};
        assert!(
            df::exists_with_type<AuthorizedAdapterKey, TypeName>(&self.id, adapter_key),
            ENoAuthorizedAdapter,
        );
        assert!(
            df::borrow<AuthorizedAdapterKey, TypeName>(&self.id, adapter_key) ==
            type_name::with_defining_ids<W>(),
            EUnauthorizedAdapter,
        );

        self.register_operator_beneficiary(collection_id, beneficiary);
    }

    /// The set-if-absent write both the witness path above and tests land on.
    /// Set-if-absent is what makes a *second* registration attempt safe: it
    /// cannot capture a beneficiary an earlier registration established.
    /// Private, so no other module in the package can write a beneficiary
    /// without presenting the adapter witness.
    fun register_operator_beneficiary(
        self: &mut FeePolicy,
        collection_id: ID,
        beneficiary: address,
    ) {
        let key = OperatorBeneficiaryKey { collection_id };
        if (df::exists_with_type<OperatorBeneficiaryKey, address>(&self.id, key)) {
            return
        };

        df::add(&mut self.id, key, beneficiary);
        event::emit(OperatorBeneficiaryRegistered { collection_id, beneficiary });
    }

    /// Destroy a collection's payout mapping. Accrual continues — the rate is a
    /// property of the share class, not of the mapping — but claims abort until
    /// the storage unit's owner registers again through the adapter, so the
    /// share stays encumbered rather than paying an address the admin has
    /// disowned.
    public fun destroy_operator_beneficiary(
        self: &mut FeePolicy,
        collection_id: ID,
        _cap: &TriexAdminCap,
    ) {
        let key = OperatorBeneficiaryKey { collection_id };
        if (df::exists_with_type<OperatorBeneficiaryKey, address>(&self.id, key)) {
            df::remove<OperatorBeneficiaryKey, address>(&mut self.id, key);
            event::emit(OperatorBeneficiaryDestroyed { collection_id });
        };
    }

    public fun operator_beneficiary(self: &FeePolicy, collection_id: ID): Option<address> {
        let key = OperatorBeneficiaryKey { collection_id };
        if (df::exists_with_type<OperatorBeneficiaryKey, address>(&self.id, key)) {
            option::some(*df::borrow<OperatorBeneficiaryKey, address>(&self.id, key))
        } else {
            option::none()
        }
    }

    #[test_only]
    /// Strip the genesis hub-share state, standing up the object an upgrade
    /// inherits: a `FeePolicy` shared before this feature existed, which
    /// therefore never ran `new_policy`. The only way to reach that state from
    /// a test, since every constructor seeds it.
    public fun strip_operator_share_genesis_for_testing(self: &mut FeePolicy) {
        let class_key = OperatorShareClassKey { class_id: 0 };
        if (df::exists_with_type<OperatorShareClassKey, OperatorShareClass>(&self.id, class_key)) {
            df::remove<OperatorShareClassKey, OperatorShareClass>(&mut self.id, class_key);
        };

        let default_key = DefaultOperatorShareKey {};
        if (df::exists_with_type<DefaultOperatorShareKey, u16>(&self.id, default_key)) {
            df::remove<DefaultOperatorShareKey, u16>(&mut self.id, default_key);
        };
    }

    #[test_only]
    /// Register a beneficiary without the adapter witness, for tests exercising
    /// the mapping itself rather than the registration gate.
    public fun register_operator_beneficiary_for_testing(
        self: &mut FeePolicy,
        collection_id: ID,
        beneficiary: address,
    ) {
        self.register_operator_beneficiary(collection_id, beneficiary);
    }
}
