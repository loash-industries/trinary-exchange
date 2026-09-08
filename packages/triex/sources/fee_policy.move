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
module triexbook::fee_policy;

use std::type_name::{Self, TypeName};
use sui::{event, table::{Self, Table}};
use triexbook::{fee_schedule::{Self, FeeSchedule}, registry::TriexbookAdminCap};

// === Errors ===
const EClassAlreadyExists: u64 = 0;
const EClassDoesNotExist: u64 = 1;
const EInvalidCancelRetention: u64 = 2;
const ENoDefaultClassForQuote: u64 = 3;
const EClassQuoteMismatch: u64 = 4;
const EDuplicateGenesisClass: u64 = 5;
const EInvalidQuoteUnit: u64 = 6;

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
// Launch pricing, written by `bootstrap_quote`. Eight tiers, each rung a fixed
// discount off the entry rate — 0/8/16/24/32/38/44/50 percent — taken on the
// taker and maker columns alike, so the spread between the two sides holds its
// ratio the whole way up. Every value is a `FEE_MULTIPLE` multiple and clears
// `MIN_TAKER_FEE`, so `validated_schedule` accepts both columns as written.
const GENESIS_CANCEL_RETENTION_BPS: u64 = 2000; // 20% retained

/// Coin pools: 1.1% taker / 0.9% maker at the entry tier, halving to
/// 0.55% / 0.45% at the top.
fun coin_taker_fees(): vector<u64> {
    vector[11_000_000, 10_120_000, 9_240_000, 8_360_000, 7_480_000, 6_820_000, 6_160_000, 5_500_000]
}

fun coin_maker_fees(): vector<u64> {
    vector[9_000_000, 8_280_000, 7_560_000, 6_840_000, 6_120_000, 5_580_000, 5_040_000, 4_500_000]
}

/// Multicoin pools: 2.2% taker / 1.8% maker at the entry tier, halving to
/// 1.1% / 0.9% at the top.
fun multicoin_taker_fees(): vector<u64> {
    vector[
        22_000_000,
        20_240_000,
        18_480_000,
        16_720_000,
        14_960_000,
        13_640_000,
        12_320_000,
        11_000_000,
    ]
}

fun multicoin_maker_fees(): vector<u64> {
    vector[
        18_000_000,
        16_560_000,
        15_120_000,
        13_680_000,
        12_240_000,
        11_160_000,
        10_080_000,
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
    cap: &TriexbookAdminCap,
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
    _cap: &TriexbookAdminCap,
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
    _cap: &TriexbookAdminCap,
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
    _cap: &TriexbookAdminCap,
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
    _cap: &TriexbookAdminCap,
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
public(package) fun assert_class_matches_quote(self: &FeePolicy, class_id: u16, quote: TypeName) {
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
