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
