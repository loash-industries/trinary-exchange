# TRIEX-137 — Trading fee tiers keyed on trailing fee turnover

Design and implementation plan for replacing the flat per-pool rate with a per-trader
VIP ladder: the more a trader has actually **paid in fees** over a trailing window,
the cheaper their taker and maker rates.

- **Ticket:** TRIEX-137
- **Package:** `packages/triex` (`triexbook`)
- **Status:** design settled (2026-09-07), not yet implemented
- **Depends on:** TRIEX-135 (dual-sided fees) and TRIEX-138 (fee refunds) — both landed
- **Release branch:** `cycle-7` — single publish with TRIEX-135 and TRIEX-138;
  implementation order 135 → 138 → 137

> **This plan supersedes the marginal-bracket design.** The earlier revision of this
> file (`TRIEX-137-marginal-fee-brackets.md`) specified progressive marginal brackets
> over per-epoch fee turnover. That model is retired — see [§2](#2-model-decision) for
> why. It also supersedes `storage/tiered_trading_fees_proposal.md`, whose mechanics
> we adopt and whose metric and hosting we reject; the reconciliation is in [§3](#3-what-we-took-from-the-volume-tier-proposal).

## 1. What the code actually does today

The previous revision of this plan described pre-135 code. Corrected against `cycle-7`
(`b0a7dc1`):

- **Rates are per-pool and dual-sided.** `TradeParams { taker_fee, maker_fee,
  cancel_retention_bps }` (`sources/state/trade_params.move:7-15`), FLOAT_SCALING units
  (`1e9` = 100%). Both sides pay, always in quote. Bid takers pay on top of quote owed;
  ask takers and ask makers have it deducted from proceeds; bid makers escrow at
  placement. There is no `taker_fee_for_user(is_bid)` and no bid-only asymmetry — those
  died with 135.
- **Defaults:** coin pools 2.2% taker / 1.8% maker; multicoin 1.1% / 0.9%
  (`sources/state/governance.move:39-43`). `FEE_MULTIPLE = 1000` (0.01 bp granularity),
  `MIN_TAKER_FEE = 100_000` (1 bp), makers have no floor, both capped at 100%.
- **Rate resolution happens in two places, once per pool type:**
  `sources/pool.move:1449-1451` and `sources/multicoin_pool.move:1080-1082` read
  `trade_params` for the maker snapshot, and `state::process_create` reads the taker
  rate live at `sources/state/state.move:223-225`.
- **Orders already snapshot their own maker rate.** `Order.maker_fee_rate` and
  `Order.cancel_retention_bps` (`sources/book/order.move:25-34`) are recorded at
  placement; cancel, modify-down, expiry and `locked_balance` all replay the *order's*
  rate, not a global per-epoch one. **The Phase 3 item in the old plan asking for this
  field is already done** — 135 shipped it. Nothing in this ticket needs to touch
  `history::historic_fee_rate` replay.
- **`account::update` is dead code.** The call is commented out inside
  `state::update_account` (`sources/state/state.move:638-646`) under `#feat:rebate`, so
  `Account.epoch` never advances and `taker_volume` / `maker_volume` accumulate forever
  rather than resetting per epoch. The old plan described this as an existing hook; it
  is a prerequisite to build around, not to build on.
- **`Volumes.trade_params` archives the rate schedule per epoch for free**
  (`sources/state/history.move:25-31`) — still true, and this plan still uses it.
- **The exclusion rule this ticket needs already exists in code.**
  `state::recognize_retention` (`sources/state/state.move:623-631`) books retained
  escrow as revenue but deliberately keeps it out of `add_volume`, with the comment:
  *"retention must not buy fee-tier progress, or cancel churn becomes a cheap way to
  climb."*

## 2. Model decision

**Chosen: trailing-window step tiers over fees paid.** Rejected: per-epoch marginal
brackets (the old plan) and trailing-30d *volume* tiers (the storage proposal).

### 2.1 Why not per-epoch marginal brackets

The old design is a daily happy-hour ladder — every trader restarts at 2.2% each epoch
and re-climbs intraday. Against the market-design goal of attracting and retaining
high-volume spenders it fails on four counts:

1. **The whale's blended rate stays permanently inflated** by the daily re-climb, no
   matter how much they trade. The marginal rate late in an epoch is cheap; the average
   rate they compare across venues is not.
2. **Loyalty earns nothing.** A consistent $10M/epoch trader and a one-epoch tourist
   with the same epoch spend get identical treatment. No durable status means no
   switching cost, so a competitor undercuts you at will.
3. **It rewards bursting** volume into a single epoch rather than sustained flow —
   the opposite of the retention profile we want.
4. **It is illegible as a BD instrument.** Market makers negotiate against a tier
   table ("you land at VIP 6, 0.55%"). "Your blended intraday marginal rate" is not a
   number anyone signs a term sheet against.

The property marginal semantics were bought for — no retroactive repricing, no cliff
gaming — turns out to be a property of the *metric*, not the semantics. With fees-paid
as the metric, step tiers inherit it for free (§2.3).

### 2.2 Why a trailing window, and why step tiers follow from it

A trailing window (last `N` epochs of fees paid determines your tier, whole order
priced at your pre-order tier) is the CEX VIP model, and it works because the discount
becomes a **durable status good**:

- The high spender's rate reflects sustained spend from their first trade of the epoch.
- Falling off the ladder requires walking away for a month — a real switching cost.
- Concentration is rewarded; sybil-splitting is self-punishing, since dividing flow
  across accounts climbs every ladder slower.

Step semantics are then *forced*, not merely simpler: marginal brackets need a monotone
cursor ("the first 100k of fees ever"). A trailing sum rises and falls, so "the first
100k" is undefined. This is decision #2 in the storage proposal and it survives the
metric change unchanged.

Bonus: step tiers are strictly less work than the marginal variant. No bracket-boundary
inversion, no mid-fill blending, no decision about how to blend a maker rate across a
resting quantity that may never fill. Rate resolution becomes a lookup.

### 2.3 Why fees paid, not volume

This is the constraint the ticket puts first: *tiers must be progressed against only by
fees paid, not by fake volume from open orders that can be cancelled.* Using
fee-recognized-as-revenue as the metric satisfies it **by construction** rather than by
patching exclusions onto a volume counter:

- A cancellable open order contributes nothing, because its escrow is not revenue until
  it fills — and post-138 it is 80% refundable.
- Wash trading cannot manufacture progress. Accrual is 1:1 with real cost: buying a
  tier costs exactly the threshold in real, non-refundable protocol revenue. Under
  dual-sided fees a self-trade pays both legs, so the cost is if anything higher than
  single-leg intuition suggests.
- Cancel churn cannot climb, extending the rule `recognize_retention` already encodes.

The storage proposal's volume metric is weaker here: it needs the "fee-assessed volume
only" carve-out (its decision #5) to get partway to the same place, and even then it
counts *placement-time* bid maker locks, which post-138 are refundable — a live
place-and-cancel accrual loophole under the current code.

### 2.4 Why the counter lives in the pool, not the BalanceManager

This is the decisive break from the storage proposal, and it is a hard mechanical
constraint rather than a preference:

**At fill time, the maker's `BalanceManager` is not in the transaction.** A taker's
transaction carries only the taker's BM. `process_fills` identifies makers by
`fill.balance_manager_id()` — an `ID` — and mutates the pool-local account table
(`sources/state/state.move:608`), because it cannot touch an object that is not an
input. A BM-hosted tracker therefore **can never be credited for maker fees at the
moment they are recognized**.

The storage proposal sidestepped this only because, pre-135, makers paid at placement
in their own transaction. Post-135 makers pay at fill, so BM-hosting would
systematically undercount exactly the participants — liquidity providers — a fee ladder
most wants to reward.

The pool's `Account` table has no such problem: it is already mutated for every maker on
every fill.

### 2.5 Scalability: no new contention anywhere

The design deliberately introduces **no new shared object and no new write to an
existing shared object** on the trade path:

| State | Where | Contention added |
|---|---|---|
| Fee turnover counter | `Account` in `State.accounts`, inside the `Pool` | **None** — every trade already takes `&mut Pool` |
| Tier schedule (policy) | `TradeParams` in the pool's own `Governance` | **None** — read-only on the hot path, written only by admin, once per pool |
| `Registry` | untouched | **None** — stays off the trade path entirely |

Orderbook matching within one market is inherently sequential, so per-pool state is
free. Sui parallelism here comes from pools being independent shared objects, which this
preserves exactly. **The `Registry` must stay off the trade path** — a mutable
tier or volume counter there would serialize the entire exchange, which is the failure
mode this ticket exists to avoid.

The cost of that choice is that **tiers are per-pool**: turnover on ETH/CRED does not
discount SUI/CRED. Under the scalability constraint this is the right trade — exchange-wide
aggregation is precisely what drags in a global object (or a cross-quote normalization
problem). See §8 for the lazy roll-up that could relax it later without a shared counter.

### 2.6 On-chain cost, and the ceiling this sits on

§2.5 audits *contention* and finds none. That is necessary but not sufficient — it says
nothing about per-transaction cost, so this section states the cost honestly.

**What the tier design costs.** `Account` lives in `State.accounts: Table<ID, Account>`,
and a Sui `Table` keeps entries as separate dynamic-field objects with only a 40-byte
handle inline, so per-account tier state never enters the `Pool` object.

| Addition | Cost |
|---|---|
| `FeeTurnover` on `Account` | +273 bytes (8 + 30×8 + 1 + 8 + 16) |
| One-time storage deposit | ~20,700 MIST ≈ 0.00002 SUI, refundable |
| Ring rotation | 0 iterations typical, 30 worst case |
| Tier resolution | ≤ 8 comparisons |
| Accrual | two integer adds |
| Bytes added to `Order` | **zero** — reuses the existing `maker_fee_rate` snapshot |
| Bytes added to `PoolInner` | 512 (schedule, current + next) |

Per-fill overhead is the +273 bytes on each maker `Account`, which is a size delta on
I/O that `process_maker_fill` already performs, not a new object load. A three-maker fill
adds ~800 bytes; a 100-fill order adds ~27 KB.

**The ceiling.** None of that is the binding constraint. `Book` holds two plain
`vector<Order>` inline, and `Book` is inline in `PoolInner`
(`sources/book/book.move:31-41`, `sources/pool.move:54-61`) — `BigVector` is commented
out under `#feat:bv` and **the module does not exist in this repo**, so restoring it
means writing it. The whole book is therefore one Move object, serialized and
deserialized on every trade. At 98 bytes per `Order` against Sui's 250 KB
`max_move_object_size`, that caps a pool at roughly **2,600 resting orders**, after which
placement aborts. `MAX_OPEN_ORDERS = 100` is enforced per `BalanceManager`
(`sources/state/state.move:228`), not per pool, so **about 26 market makers at full quota
exhaust a pool.**

Three cost curves compound below that wall:

- The cleanup rescan in `match_against_book` (`sources/book/book.move:738-756`) walks the
  entire book side and iterates every fill for each resting order — O(depth × fills), and
  the outer loop runs on *every* `create_order`, including post-only makers that matched
  nothing.
- Cancel and modify linear-scan both sides outside the best-price fast path
  (`book.move:246-261`, `:378-392`), making `cancel_all_orders` O(100 × depth). The
  comment at `book.move:103` — *"on len < 20, linear search is faster than binary
  search"* — records the depth this was built for.
- `vector::insert` shifts, O(n), after an O(log n) search.

TRIEX-135 and 138 added 16 bytes to `Order`, already cutting maximum depth ~16%. This
ticket adds zero, which is why the maker rate reuses `maker_fee_rate` rather than taking
a new field.

**Consequence for sequencing.** This ladder is designed to attract high-volume traders
onto infrastructure that currently cannot host them: one trader at a million trades a day
is ~12 TPS sustained against a single shared object whose per-trade cost grows with book
depth, and the quote-and-cancel profile that generates such volume is exactly what hits
the O(depth) paths hardest. **BigVector (or a crit-bit book) should land before or
alongside this ladder, not after.** Independently, the cleanup rescan can drop a whole
O(depth × fills) term by collecting removal indices during the match walk, which already
visits precisely the affected orders.

This is not a new finding — `storage/market_design/IMPROVEMENTS.md:87-96` already flags
the O(n) vector book and says BigVector "will need to come back before books get deep."
It is recorded here because the fee ladder is what makes it urgent.

**Measurement gap.** The complexities and the size cap are read off the code and are
certain; the throughput figure is arithmetic. Nothing here has been measured, and it
cannot be with what the repo has today: there are no gas benchmarks, no performance
tests, and no CI. `packages/triex/build_scripts/verify-bytecode-meter.sh` sets no
thresholds and stores no baseline — it shells out to the Sui CLI and trusts the exit
code. The deepest book any test exercises is on the order of ten orders. A depth-sweep
gas benchmark should precede any decision that rests on these numbers.

### 2.7 Prior art: what DeepBook v3 does

Upstream (`MystenLabs/deepbookv3`) has **no rolling per-trader volume on-chain**, so
there is no reference implementation to adopt:

- Per-account volume is a single epoch. `Account.taker_volume` / `maker_volume` are
  zeroed by `account::update()` on rollover — which upstream actually calls, unlike this
  fork (§1).
- The discount is binary and stake-gated: `TradeParams { taker_fee, maker_fee,
  stake_required }` and `taker_fee_for_user(active_stake, volume_in_deep)` halves the
  taker fee iff `active_stake >= stake_required` **and** `volume_in_deep >=
  stake_required`. One threshold, one 50% cut, no ladder. `volume_in_deep` is
  current-epoch volume.
- The only multi-epoch structure is `historic_median` over 28 epochs, and it is
  **pool-wide, not per-trader** — it sizes maker rebates, not fee tiers.
- Trailing 30d per-trader volume exists only in the off-chain DeepBook indexer
  (`/get_historical_volume_by_balance_manager_id/...`), which is analytics, not something
  a Move function can price against.

Two things follow. First, DeepBook keeps ~32 bytes per account for this where we propose
273 — roughly 8×, which is the number to watch given the per-fill account I/O above.
Second, **DeepBook bought durability with stake, not with a trailing window.**
`active_stake >= stake_required` is inherently sticky and needs no history at all; their
volume condition is a spam filter on top. That does not satisfy this ticket's constraint
— progression by capital lockup is not progression by fees paid — but it is the cheaper
answer to the same problem, this fork still has the `#feat:stake` scaffolding commented
out, and a hybrid (stake as durability anchor, fees-paid as the ladder) is worth
considering before committing to the ring buffer long-term.

## 3. What we took from the volume-tier proposal

`storage/tiered_trading_fees_proposal.md` (2026-08-11) is a complete, design-settled
competing proposal. Its **mechanics are adopted**; its **metric and hosting are
rejected**. Explicit reconciliation, since both documents will be read together:

| Dimension | Storage proposal | This plan | Why |
|---|---|---|---|
| Metric | Trailing 30d fee-assessed *volume* | Trailing 30-epoch *fees paid* | Ticket constraint; closes the place-and-cancel accrual loophole 138 opened (§2.3) |
| Semantics | Step tiers, whole order at pre-order tier | **Same** | Forced by the trailing window (§2.2) |
| Window | 30 daily buckets, `Clock`-driven | 30 **epoch** buckets, `ctx.epoch()`-driven | Sui epochs are ~24h; avoids plumbing `Clock` into `state`, and the epoch rollover hook already exists |
| Counter hosting | Dynamic field on `BalanceManager` | `Account` in pool state | Maker fees are uncreditable to a BM at fill time (§2.4) |
| Scope | Exchange-wide per trader | Per-pool per trader | Follows from hosting; see §8 |
| Policy hosting | Registry canonical + per-pool sync | Per-pool only | Keeps `Registry` off the trade path; per-pool setters already exist |
| Separation rule | Raw metric only, never cache a tier | **Same** — load-bearing | Schedule changes re-price everyone with zero migration |
| Ladder shape | 8 tiers, ×5 spacing | **Same shape**, re-denominated into fees-paid | §6 |

Note that every code citation in the storage proposal's §3 table is stale (it describes
`TradeParams { fee: u64 }`, bid-only fees, no cancel refund, `MAX_TAKER_VOLATILE = 2%`).
The mechanism design survives; the citations do not.

## 4. Design

### 4.1 Policy — `FeeSchedule`

New module `sources/state/fee_schedule.move`:

```move
public struct FeeTier has copy, drop, store {
    /// Inclusive lower bound on trailing fee turnover, in quote units.
    min_turnover: u128,
    taker_fee: u64,   // FLOAT_SCALING units
    maker_fee: u64,   // FLOAT_SCALING units
}

public struct FeeSchedule has copy, drop, store {
    tiers: vector<FeeTier>, // ascending by min_turnover; tiers[0].min_turnover == 0
}

/// Index of the last tier whose min_turnover <= turnover, plus its rates.
public fun resolve(self: &FeeSchedule, turnover: u128): (u64 /*tier*/, u64 /*taker*/, u64 /*maker*/)
```

Held in `Governance` as its own field pair (`fee_schedule` / `next_fee_schedule`),
**deliberately not inside `TradeParams`.**

The earlier revision of this plan proposed putting it in `TradeParams` so that historic
schedules would be "archived for free" via `Volumes.trade_params`. Measurement killed
that idea. `Volumes` is currently 96 bytes (`total_volume` 16, `total_staked_volume` 16,
`total_fees_collected` 24, `historic_median` 16, `trade_params` 24). An 8-tier schedule
is 8 × (u128 + u64 + u64) = 256 bytes, so embedding it would take `TradeParams` from 24
to 280 bytes and `Volumes` from 96 to 352 — and `update_historic_median`
(`sources/state/history.move:183-190`) loads a **full `Volumes`** from the
`historic_volumes` dynamic-field table 28 times per epoch rollover. That turns a ~2.7 KB
read into ~10 KB, charged to whoever sends the first transaction of a new epoch, to
compute a median whose only consumer is commented-out `#feat:rebate` code.

It is also unnecessary. No on-chain path ever reads a historic schedule: orders carry
their own `maker_fee_rate` (§1), which is exactly why TRIEX-135 could delete the
`historic_fee_rate` replay. The only consumer of schedule history is an indexer, and the
`FeeScheduleUpdated` event in §4.6 serves that better than on-chain state does.

Cost of the corrected placement: 2 × 256 bytes inline in `PoolInner` (current + next),
about five orders of book depth — see §2.6.

Separate maker and taker columns per tier are deliberate: TRIEX-135 split the two dials,
and pushing maker rates toward zero at high tiers is the primary liquidity-seeding lever.

Validation in `governance::set_next_trade_params`, reusing the existing bounds
(`sources/state/governance.move:259-267`): non-empty; `tiers[0].min_turnover == 0`;
strictly ascending thresholds; every rate a `FEE_MULTIPLE` multiple within
`[MIN_TAKER_FEE, MAX_TAKER_FEE]` for takers and `[0, MAX_MAKER_FEE]` for makers; and
**rates non-increasing across tiers** — more turnover must never cost more. Cap the tier
count (16 is ample) so resolution stays bounded.

Activation follows the existing pattern exactly: stored as `next_trade_params`, promoted
by `governance::update` at the epoch boundary. `set_next_epoch_fee` becomes sugar for a
single-tier schedule, so there is one code path and existing callers keep working.

### 4.2 Metric — `FeeTurnover` on `Account`

```move
public struct FeeTurnover has copy, drop, store {
    anchor_epoch: u64,      // epoch of the newest bucket
    buckets: vector<u64>,   // TURNOVER_WINDOW_EPOCHS daily buckets, quote units
    head: u64,              // index of the newest bucket
    rolling_sum: u128,      // invariant: sum(buckets)
}
```

Added to `Account` (`sources/state/account.move:13-25`). `TURNOVER_WINDOW_EPOCHS = 30`
is a **package constant, not governance-settable** — that keeps `rolling_sum` a true O(1)
invariant instead of forcing a sum over the last `N` buckets on every rate resolution. A
shorter effective window is achievable by raising thresholds, so nothing is lost that
matters. (This is a deliberate change from the verbal recommendation that preceded this
plan, where a settable `N` was floated.)

Rotation is lazy: on touch, advance `head` by the number of elapsed epochs (capped at
the window — dormant ≥30 epochs clears everything), subtracting evicted buckets from
`rolling_sum`. O(epochs elapsed), O(1) in the common case.

**Do not re-enable the commented-out `account.update(ctx)` call** in
`state::update_account` (`sources/state/state.move:638-646`) to get the rollover hook.
That call is rebate-shaped and entangled with `#feat:rebate`. Add a focused
`account::roll_fee_turnover(&mut Account, ctx)` and call it unconditionally from
`update_account` instead. (The stale-volume bug — `taker_volume` / `maker_volume` never
resetting because `update` is dead — is real but out of scope here; file it separately.)

### 4.3 Accrual — what counts

Credit turnover **only** with fees recognized as protocol revenue at fill:

| Event | Counts? | Where |
|---|---|---|
| Taker fee paid at fill | ✅ credit taker | `order_info.paid_fees()` after `calculate_partial_fill_balances`, `state.move:233` |
| Maker fee recognized at fill | ✅ credit maker | `fill.maker_fee_charged()` in `process_fills`, `state.move:573` (already 0 for expired fills) |
| Bid-maker escrow at placement | ❌ | Refundable post-138 — this is the loophole |
| Escrow refunded on cancel/modify/expiry | ❌ | Never credited, so nothing to reverse |
| Retention kept on cancel/modify/expiry | ❌ | Extends the existing `recognize_retention` rule |

The maker credit site is convenient: `process_fills` already holds `&mut account` for
each maker at `state.move:608`.

### 4.4 Rate resolution and application

**Takers** — resolved live, whole order at the pre-order tier. Turnover from this order
accrues *after* pricing, so the order cannot discount itself. Trade-splitting near a
boundary is possible, harmless and CEX-normal.

**Makers** — resolved at placement and written into the **existing**
`Order.maker_fee_rate` snapshot. Everything downstream (escrow, fill-time recognition,
the 138 refund split, `locked_balance`) already replays the order's own rate and needs
**no changes at all**. A resting order keeps its placement tier for life, which is the
same posture 135 established for rate changes and 138 for retention changes.

Mechanically, both rates must be resolved before `order_info::new` at
`sources/pool.move:1452`, because the maker rate is a constructor argument. Add:

```move
public(package) fun resolve_trade_rates(
    self: &mut State, balance_manager_id: ID, ctx: &TxContext,
): (u64 /*taker*/, u64 /*maker*/)
```

which rolls governance, rolls/creates the account, reads `rolling_sum`, and resolves the
schedule. Call it at `sources/pool.move:1449` (replacing the flat `trade_params()` read)
and `sources/multicoin_pool.move:1080`; pass the maker rate into `order_info::new` and
the taker rate into `process_create` as a new parameter, replacing the internal read at
`state.move:223-225`. `process_create` is `public(package)`, so the signature is free to
change; its own `governance.update` / `update_account` calls are idempotent.

### 4.5 Manager-less swaps

`swap_exact_quantity` (`sources/pool.move:350-395`) mints a temp `BalanceManager`,
trades, withdraws and deletes it. Consequences:

1. Anonymous flow always prices at tier 0 and accrues nothing usable. Correct behavior —
   an incentive to route through a persistent BM, not a bypass.
2. **The temp BM's `Account` entry is orphaned in the pool's table forever** — this is a
   pre-existing leak (`update_account` has no removal path), which the ring buffer makes
   ~240 bytes worse per anonymous swap.

Fix it here rather than growing it: add `state::forget_account(bm_id)` (asserting no open
orders and zero settled/owed balances) and call it from the swap path after
`withdraw_all`, before `temp_balance_manager.delete()`.

### 4.6 Views and events

- `get_quantity_out_input_fee` (`sources/pool.move:1083`,
  `sources/multicoin_pool.move:838`) has no account context. Quote at tier 0 (worst case,
  never under-quotes) and add an account-aware overload taking a `&BalanceManager` for
  accurate quotes. Note that `swap_exact_quantity` itself calls this at
  `sources/pool.move:364` for sizing — tier 0 is the right answer there anyway.
- `pool_trade_params` / `pool_trade_params_next` (`sources/pool.move:1285-1302`) return
  `(taker_fee, maker_fee)`. Add `pool_fee_schedule()` and an account-aware
  `trade_params_for(&BalanceManager)`. (Pre-existing gap worth closing while here:
  neither exposes `cancel_retention_bps`.)
- `OrderFilled` (`sources/book/order_info.move:87-100`) gains `taker_tier` and
  `maker_tier` alongside the existing `taker_fee` / `maker_fee` amounts, so the indexer
  and UI can show a trader's current tier without recomputing the ladder.
- New `FeeScheduleUpdated { pool_id, tiers, effective_epoch }` on set and on activation.

## 5. Implementation phases

| Phase | Files | Work |
|---|---|---|
| 1 | `state/fee_schedule.move` (new), `trade_params.move`, `governance.move` | `FeeTier` / `FeeSchedule` / `resolve`, validation, next-epoch activation, `set_next_epoch_fee` as single-tier sugar |
| 2 | `state/account.move`, `state/state.move` | `FeeTurnover`, `roll_fee_turnover`, call it from `update_account`; accrual at both credit sites |
| 3 | `state/state.move`, `pool.move`, `multicoin_pool.move` | `resolve_trade_rates`; rewire both rate-resolution sites; `process_create` signature |
| 4 | `pool.move`, `multicoin_pool.move`, `state/state.move` | `forget_account` + swap-path cleanup; views; account-aware quote overloads |
| 5 | `book/order_info.move`, `state/fee_schedule.move` | `OrderFilled` tier fields; `FeeScheduleUpdated` |
| 6 | `tests/` | §7 |

Phases 1 and 2 are independent and can land in parallel; 3 depends on both.

## 6. Launch ladder

Re-denominated from the storage proposal's §11 ladder into fees-paid space, preserving
its shape (8 tiers, ~×5 spacing, ≤0.3pp adjacent taker steps). CRED has 6 decimals
(`packages/token/sources/cred.move:45`), so raw threshold units are the CRED figure ×10⁶.
Anchored on the current coin-pool defaults (2.2% / 1.8%):

| Tier | 30-epoch fees paid ≥ (CRED) | Taker | Maker | `taker_fee` | `maker_fee` |
|---|---|---|---|---|---|
| 0 | 0 | 2.20% | 1.80% | `22_000_000` | `18_000_000` |
| 1 | 200 | 1.90% | 1.55% | `19_000_000` | `15_500_000` |
| 2 | 1,000 | 1.60% | 1.30% | `16_000_000` | `13_000_000` |
| 3 | 5,000 | 1.30% | 1.05% | `13_000_000` | `10_500_000` |
| 4 | 20,000 | 1.05% | 0.85% | `10_500_000` | `8_500_000` |
| 5 | 100,000 | 0.85% | 0.65% | `8_500_000` | `6_500_000` |
| 6 | 400,000 | 0.70% | 0.50% | `7_000_000` | `5_000_000` |
| 7 | 1,500,000 | 0.55% | 0.40% | `5_500_000` | `4_000_000` |

```move
min_turnover: [0, 200_000_000, 1_000_000_000, 5_000_000_000, 20_000_000_000,
               100_000_000_000, 400_000_000_000, 1_500_000_000_000]
```

Every rate is a `FEE_MULTIPLE` (1000) multiple, every taker rate clears
`MIN_TAKER_FEE = 100_000` with 55× headroom, and both columns are monotone
non-increasing — so this passes §4.1 validation as written.

**Calibration notes.**

- *Anchoring.* Tier 1 is ~7 CRED/epoch of fees — roughly 300 CRED/epoch of taker volume
  at the base rate, reachable by an active individual, so the ladder is visible to normal
  users rather than whales only. Tier 7 implies on the order of 200M CRED of trailing
  volume, dedicated market-maker territory. This lands within a factor of ~2 of the
  storage proposal's volume ladder at every rung, which is the intent.
- *Wash-resistance.* Bridging costs the threshold gap in real fees and returns Δrate on
  future volume, so break-even future volume is `Δthreshold / Δrate`. Worst boundary
  (T6→T7): bridging 1.1M CRED of fees for a 0.15pp cut needs ~733M CRED of subsequent
  real volume inside the same 30-epoch window — over 3× the volume the tier-7 threshold
  itself implies. Every boundary clears this test, and the ratio is rate-independent
  because accrual is 1:1 with cost by construction.
- *Revenue.* Blended take depends on the volume distribution; under typical exchange
  concentration expect ~0.7–1.2% effective versus 2.2% flat. Levers in order of
  preference: raise top-tier rates, raise upper thresholds, or ship tiers 0–5 only and
  add 6–7 later — schedule changes are migration-free, so this is reversible.
- *Rollout.* Existing pools synthesize a single-tier schedule from their current flat
  rate on first touch, so activation is a pure fee cut: no trader is ever charged more
  than today.

## 7. Tests

Extend `tests/pool/pool_fee_tests.move`, `tests/state/quote_fee_tests.move`,
`tests/state/governance_admin_tests.move`.

- Tier resolution: exact threshold boundary, below/above, single-tier schedule equals
  today's flat behavior.
- Pre-order pricing: an order that crosses a threshold is priced entirely at the old
  tier; the *next* order gets the new one.
- **Cancellable flow buys nothing** (the ticket's headline constraint): place a large
  bid, cancel it, assert turnover is unchanged and the tier has not moved. Same for
  modify-down and expiry.
- Accrual credits the maker at fill, not at placement — including the multi-maker
  expiry case that TRIEX-138's `test_expiry_refund_event_attributes_the_maker` guards.
- Ring buffer: rotation across one epoch, across the full window, and ≥30 epochs of
  dormancy clearing to zero; `rolling_sum` invariant holds throughout.
- Resting order settles at its placement tier after the schedule changes and after the
  trader's tier changes.
- Governance validation rejects: unsorted thresholds, `tiers[0].min != 0`, non-multiples
  of `FEE_MULTIPLE`, taker below floor, increasing rates, over-long schedules.
- Temp-BM swap prices at tier 0 and leaves no orphaned account.
- Multicoin parity for all of the above.
- Run `build_scripts/verify-bytecode-meter.sh` — resolution and rotation sit on the hot
  fill path.

## 8. Deferred: exchange-wide aggregation

Per-pool tiers are a consequence of §2.4, not an end state. If exchange-wide tiers are
wanted later, the scalable path is **lazy roll-up, never a shared counter**: pools keep
accruing locally, and whenever the trader's *own* transaction has both their `BalanceManager`
and a pool in scope, the pool folds its local delta into a BM-hosted aggregate. That
recovers exchange-wide semantics with no new shared object and no new trade-path input —
the maker-side gap in §2.4 stays, but it degrades to "maker fees count per-pool, taker
fees count everywhere" rather than being lost. Not designed here; do not build it until
per-pool tiers are live and the demand is real.

## 9. Ranking investigation — closed

The ticket asks for a written recommendation on a ranked top-N variant before any
leaderboard code lands. **Recommendation: do not build one. Threshold tiers only.**

- A ranked discount is *positional*: unlike a threshold ladder, the cost of obtaining it
  depends on what competitors do, not on the published schedule. That is unpriceable for
  the trader and unbudgetable for us.
- It pays traders to buy rank. A threshold ladder's anti-wash property (§2.3) comes from
  accrual being 1:1 with cost; ranking breaks that, because the prize is scarce and its
  value rises with competition rather than staying capped at Δrate × volume.
- Live top-N puts a contended, mutating structure on the hot fill path and makes fill
  cost non-deterministic — a trader can be demoted between simulation and execution.
- Capping the top bracket at N seats does not scale the incentive to every high spender,
  which is the actual market-design goal. The ladder gives unbounded seats at a
  published price.

If a ranked program is ever wanted for marketing reasons, the only defensible variant is
**previous-epoch settled ranking** computed off the already-archived `historic_volumes`
table — non-gameable within the epoch, zero hot-path cost, and it can be run as a
rebate program entirely outside the fee path.

## 10. Acceptance criteria

Superseding the marginal-model criteria on the ticket:

- Fee turnover progresses **only** on fees recognized as revenue at fill. Placing and
  cancelling an order — at any size, at any frequency — moves a trader's tier by zero.
- A trader crossing a threshold is charged for the crossing order at their pre-order
  tier; the new tier applies from the next order.
- Turnover rolls off after 30 epochs, and an account dormant for a full window resolves
  to tier 0.
- An order resting across a schedule change or a tier change settles, refunds and
  reports at its placement rate.
- No new shared object, and no new mutable input, on the trade path. `Registry` is not
  read or written during a trade.
- Ranking decision recorded (§9) before any leaderboard code lands.
