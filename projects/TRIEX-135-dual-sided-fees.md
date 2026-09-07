# TRIEX-135 — Migrate to dual-sided fees

**Ticket:** TRIEX-135 · **Status:** Plan (proposed) · **Date:** 2026-09-06
**Cross-reviewed against:** TRIEX-137 (marginal fee brackets), TRIEX-138 (fee refunds on cancel)
**Deployment decision:** ships as a **new package publish** (fresh version), not an in-place
upgrade — and **TRIEX-135, TRIEX-137, and TRIEX-138 all land in this same publish**
(one release branch, one deployment). **Release branch: `cycle-7`** (decided 2026-09-06).

Charge fees on both sides of a trade instead of the current bid-only model.

---

## 1. Current state (verified in code)

The single `fee: u64` sits in
[`trade_params.move`](../packages/triex/sources/state/trade_params.move#L7-L13), and every
fee decision funnels through `taker_fee_for_user(is_bid)` / `maker_fee_for_user(is_bid)`,
which return `fee` for bids and `0` for asks. The zeroing points:

- **Placement** — [`state.move:135-138`](../packages/triex/sources/state/state.move#L135-L138)
  → [`order_info::calculate_partial_fill_balances`](../packages/triex/sources/book/order_info.move#L451-L521),
  which only computes fees inside `if (self.is_bid ...)` branches. Fees are carved from the
  user's quote payment into `quote_fee_reserve` via `QuoteFeeDeposit` in
  [`vault::settle_balance_manager`](../packages/triex/sources/vault/vault.move#L169-L198).
- **Fills** — [`state::process_fills`](../packages/triex/sources/state/state.move#L449-L467)
  hard-codes the maker fill fee to zero (bid makers pre-paid at placement; ask makers pay
  nothing).
- **Cancel / modify** — [`state.move:188`](../packages/triex/sources/state/state.move#L188)
  and [`state.move:222`](../packages/triex/sources/state/state.move#L222) zero the historic
  rate for asks. `calculate_cancel_refund` ignores its fee param entirely — bid maker fees
  are today **forfeited** to the reserve on cancel
  ([`order.move:170-190`](../packages/triex/sources/book/order.move#L170-L190)).
  TRIEX-138 exists specifically to change this.
- **Queries / dry-runs** —
  [`pool.move:1080-1085`](../packages/triex/sources/pool.move#L1080-L1085),
  [`pool.move:1247-1253`](../packages/triex/sources/pool.move#L1247-L1253),
  [`multicoin_pool.move:828-832`](../packages/triex/sources/multicoin_pool.move#L828-L832),
  [`multicoin_pool.move:961-962`](../packages/triex/sources/multicoin_pool.move#L961-L962).
- **History** — `Volumes.total_fees_collected` is already a full `Balances`, and `EpochData`
  already has both `base_fees_collected` / `quote_fees_collected` — but `historic_fee_rate()`
  returns a single side-blind `u64`, and only taker `paid_fees` are recorded into history.
  Locked maker fees reach the reserve but never `total_fees_collected` (TRIEX-138 audit
  reaches the same conclusion and prescribes the fix — see §3 item 7).

---

## 2. Design decisions

### D1 — Ask-side fee denomination: **quote-denominated on both sides** (deducted from proceeds for asks)

Rationale:

- The admin revenue path (`withdraw_pool_fees`) and both vaults' `quote_fee_reserve` are
  quote-only; a base-denominated fee would need a second reserve, and in `multicoin_vault`
  the base is a MultiCoin dynamic-object-field — real plumbing.
- Treasury then collects only approved-quote assets (which already carry the min-decimals
  check), not dust in every base asset.
- `quote_fee.move` is already bps-on-quote-quantity; asks just stop returning `zero()`.
- **TRIEX-137 requires it**: its marginal brackets accumulate *fees paid per account per
  epoch* into a single turnover number. Base-denominated ask fees would make that
  accumulator mixed-unit (base + quote) and incomparable across trades. One quote-fee unit
  keeps one bracket schedule working for both sides.
- **TRIEX-138 requires it**: its refund machinery (`unlock_quote_fees`,
  `locked_maker_fees` solvency counter, capped `withdraw_quote_fees`) is built entirely on
  the quote reserve. Base-denominated ask fees would force a parallel base reserve +
  parallel refund + parallel solvency tracking.

**Consequence:** an ask maker cannot lock a quote fee at placement (they only deposit base),
so ask maker fees are deducted from quote proceeds **at fill time**, at the maker's
placement-epoch rate. Ticket item 4 ("ask-side locked fees tracked and released") resolves
to: asks lock *nothing extra*; `locked_balance` / `calculate_cancel_refund` stay
principal-only for asks — verified by tests rather than new lock/release machinery. Bonus:
TRIEX-138's ask-side half (its step 7) becomes a **no-op** — nothing locked, nothing to
refund.

Double-charge safety falls out by construction:

| Role | At placement | At fill |
| --- | --- | --- |
| Bid maker | fee locked into reserve | zero |
| Ask maker | zero | fee deducted from quote proceeds |
| Bid taker | — | fee added to quote owed |
| Ask taker | — | fee deducted from quote settled |

### D2 — Deployment: **new package publish** (decided)

`TradeParams` has `store` and is embedded in `Volumes` inside a `Table` and in
`Governance`, all inside the `Versioned` `PoolInner` — a layout change is not a
compatible Sui upgrade anyway, and TRIEX-137 (new `Order` field, `TradeParams` bracket
schedule) and TRIEX-138 (event shapes) would each hit the same wall. Decision: ship as a
fresh publish with a bumped `constants::current_version()`, per-environment
`Move.toml` / `Published.toml` entries, and registry version gating as usual.

Follow-ons this unlocks:

- Acceptance criterion #2 ("orders placed before the change settle against their historic
  epoch rate") definitively means the **within-deployment** epoch mechanism: an order
  placed in epoch N settles at epoch-N rates after rates change in N+1.
- Event shapes (`EpochData`, `PoolCreated`, `OrderFilled`, cancel events) can change
  freely — no V2-event contortions (TRIEX-138 §5's caveat dissolves if it lands in the
  same publish).
- **Decided: TRIEX-137 and TRIEX-138 land in this same publish** — see §4 for what
  that changes.

### D3 — Rate matrix: **two rates (taker / maker), applied to both sides** — confirmed 2026-09-06 (defaults given as taker/maker only: taker 2.2%, maker 1.8%)

The ticket text says "maker/taker × bid/ask" (4 rates). Cross-review argues for 2:

- TRIEX-137 layers a bracket schedule (`vector<{threshold, rate}>`) onto the rate config.
  With 4 independent rates that becomes four schedules (or one schedule × side
  multipliers) — config surface and rate validation double for no articulated
  product need.
- The commented-out DeepBook bounds in
  [`governance.move:26-34`](../packages/triex/sources/state/governance.move#L26-L34) only
  ever distinguish taker vs maker (with maker floors of 0) — no bid/ask split existed
  upstream either.
- 2 rates still delivers the ticket's headline: sellers stop trading free, maker/taker
  separation returns.

Plan below is written for 2 rates; going to 4 is mechanical if product confirms the
bid/ask split is really wanted. **Confirm with ticket author before Phase 1.**

Since TRIEX-137 lands in the same publish, its bracket schedule reshapes `TradeParams`
on the same release branch before anything freezes — the flat 2-rate shape here is an
implementation stage, not a published interface.

---

## 3. Implementation plan

### Phase 1 — Param plumbing (mechanical)

1. [`trade_params.move`](../packages/triex/sources/state/trade_params.move):
   `TradeParams { taker_fee, maker_fee }` (per D3), `new(taker_fee, maker_fee)`,
   side-blind accessors (`taker_fee()`, `maker_fee()` — the side no longer changes the
   rate, only where it's charged from); delete the dead DeepBook comment block.
2. [`governance.move`](../packages/triex/sources/state/governance.move) (legacy
   DeepBook name — proposals/voting are disabled; all rate-setting is
   `TriexbookAdminCap`-direct via `set_next_epoch_fee`): defaults in
   `empty()` — **decided 2026-09-06: taker 2.2%, maker 1.8%** (makers pay the
   discounted rate, per the usual venue structure).
   `set_next_trade_params(taker_fee, maker_fee)` with per-rate
   `FEE_MULTIPLE` + bounds validation, resurrecting the separate maker bounds
   (`MIN_MAKER_* = 0` — maker rates may be zero; taker keeps its floor). 2-field
   `TradeParamsUpdateEvent`.
3. [`state.move`](../packages/triex/sources/state/state.move): drop all three zeroing
   sites; `set_next_epoch_fee` takes both rates.
4. **Rate snapshot on `Order`** (pulled forward from TRIEX-137 Phase 3): persist the
   maker rate on the `Order` at placement (new field next to `epoch`). Cancel / modify /
   `locked_balance` / ask-maker fill deductions read the order's own recorded rate instead
   of replaying `historic_fee_rate(order.epoch())`. The historic `Volumes.trade_params`
   snapshot stays for events/analytics. This is *required* by 137 (per-account marginal
   rates make a global epoch replay impossible), makes 138's refunds exact by
   construction, and costs nothing extra since this is a fresh publish. Propagate the
   rate into `Fill` via `generate_fill` (alongside `maker_epoch`).
5. [`history.move`](../packages/triex/sources/state/history.move): `EpochData` carries
   both rates instead of `fee`; `historic_fee_rate` shrinks to an analytics/event
   concern (or is removed if item 4 covers all consumers).
6. [`pool.move`](../packages/triex/sources/pool.move) /
   [`multicoin_pool.move`](../packages/triex/sources/multicoin_pool.move): admin
   `set_next_epoch_fee` signatures, `PoolCreated` event fields,
   `pool_trade_params()` / `_next()` return both rates.

### Phase 2 — Ask-side charging (the substance)

7. [`order_info::calculate_partial_fill_balances`](../packages/triex/sources/book/order_info.move#L451-L521):
   ask taker fee = bps × each fill's quote quantity, **subtracted from settled quote**
   (bids unchanged: added to owed). Ask resting orders set `maker_fees = 0`.
8. [`fill.move`](../packages/triex/sources/book/fill.move#L117-L136) + `process_fills`:
   when the maker is an ask (`taker_is_bid`) and not expired, deduct the maker fee from
   the maker's settled quote at the rate snapshotted on the order (item 4), record via
   `set_fill_maker_fee`.
   **Fee recognition in history happens at fill time for makers on both sides**
   (aligned with TRIEX-138 acceptance #3 "epoch totals = fees on actually-filled
   volume"): record bid-maker fees into `total_fees_collected` per fill — *not* at lock
   time as an earlier draft of this plan said. Locked-but-unfilled bid maker fees stay
   unrecognized escrow (which 138 will refund). `OrderFilled.maker_fee` becomes truthful.
9. **Reserve routing** — today's `QuoteFeeDeposit` only intercepts quote the user *pays
   in*; ask-side fees come out of quote the vault *pays out*. Add
   `vault::move_quote_to_fee_reserve(amount)` (split `quote_balance` →
   `quote_fee_reserve`, emit `PoolFeesDeposited`) to both vaults; the pool aggregates
   ask-taker `paid_fees` + ask-maker fill deductions per tx and applies it alongside
   settlement. **Split `QuoteFeeDeposit` into taker and maker portions now**
   (TRIEX-138 step 1 needs the split so only the maker part counts as refundable-locked;
   doing it here avoids reworking the same plumbing twice).
10. **Swaps**: fix
    [`swap_exact_quantity_with_manager`](../packages/triex/sources/pool.move#L455-L460)
    ask branch — `quote_out` must be `cumulative_quote_quantity - paid_fees`; audit the
    multicoin swap equivalents.
11. **Dry-runs**:
    [`book::get_quantity_out`](../packages/triex/sources/book/book.move#L131-L200) models
    fees as extra *input* — correct for bids, wrong for asks under proceeds-deduction.
    The ask branch must instead net the fee from quote *output* so quotes mirror
    settlement.
12. **Queries**: `locked_balance` callers use the order's snapshotted rate (asks: no fee
    component); `calculate_cancel_refund` stays principal-only for asks and keeps
    today's bid forfeit behavior (TRIEX-138 owns changing that).

### Phase 3 — Tests (mapped to acceptance criteria)

- **Unit**: `trade_params_tests` (13 tests to rework), `governance_admin_tests`
  bounds/events (incl. maker-rate-zero allowed, taker floor enforced),
  `order_info` / `book` fee math incl. rounding, `history_tests` EpochData shape,
  order rate-snapshot round-trip.
- **Acceptance #1** (both sides accrue in `total_fees_collected`): new ask-flow cases in
  `tests/pool/pool_fee_tests` + a new multicoin fee test module — both sides accrue
  `total_fees_collected` and grow the reserve; admin withdraw still sweeps.
- **Acceptance #2** (historic rates): place bid+ask in epoch N, change next-epoch rates,
  advance epoch, then cancel/fill — verify epoch-N (snapshotted) rates apply.
- **Acceptance #3** (no double charge): bid maker lock→fill, ask maker place→fill,
  multi-fill taker scenarios; plus a vault conservation check: reserve Δ == fees
  recorded, no funds minted or lost.
- Update the `tests/integration` master-flow suites and swap tests for net-of-fee ask
  outputs.

### Phase 4 — Housekeeping

- Full `sui move test`, `verify-bytecode-meter.sh`.
- Update `packages/triex/README.md` fee section + `CAPABILITIES.md`
  (`set_next_epoch_fee` signature).
- Publish flow: bump `constants::current_version()`, publish per environment, update
  `Published.toml` / `Move.toml [environments]`, registry `enable_version`.
- Flag the `EpochData` / `PoolCreated` / `OrderFilled` event shape changes to off-chain
  consumers.

---

## 4. Cross-project review (TRIEX-137, TRIEX-138)

How the sibling plans resolved this plan's original open questions:

| # | Question | Resolution | Source |
| --- | --- | --- | --- |
| 1 | 4 rates or 2? | **2 (taker/maker)** recommended — brackets in 137 multiply per-rate config; upstream bounds only ever split taker/maker. Confirm vs ticket wording. | 137 Phase 1; `governance.move` commented bounds |
| 2 | Ask denomination | **Quote, resolved** — 137's turnover accumulator needs one unit; 138's refund/solvency machinery is quote-only. | 137 Phase 0/2; 138 §1 |
| 3 | Defaults | **Taker 2.2%, maker 1.8% (decided 2026-09-06)** — 137's "single bracket = flat equivalence" keeps flat defaults meaningful. | product decision |
| 4 | Maker rate floor | **0 allowed, resolved** — original constants had `MIN_MAKER_* = 0`; 138's philosophy (unexecuted order costs nothing) points the same way. | `governance.move:28,32`; 138 intro |
| 5 | Publish vs migrate | **New publish, decided** (also forced: 135/137/138 all change struct layouts). | decision 2026-09-06; 138 §5 |
| 6 | Cancel forfeit policy | **Keep forfeit in 135, resolved** — TRIEX-138 is the refund project. 135 preps it: deposit split (item 9), fill-time recognition (item 8), rate snapshot (item 4); ask-at-fill design makes 138's ask half a no-op. | 138 throughout |

**Conflict to flag on TRIEX-137** (now *blocking* for this release — brackets and
refunds ship together, so there is no interim state where lock-time counting is
defensible): its Phase 0
decision 2 counts maker fees toward bracket turnover **at lock time**, justified by
"never refunded on cancel" — which TRIEX-138 invalidates. Once refunds exist,
lock-time counting lets an account climb fee brackets by placing and cancelling orders
at only the cost of the 20% cancellation retention (decided 2026-09-06 — cancels refund
80% of the locked fee; see the 138 plan). Cheap churn is still churn: 137 must count
maker fees at **fill time** (which item 8 above conveniently
establishes as the recognition point). Relatedly, 137's ranking write-up cites the
"bid-side-only fee" as wash-trading mitigation — after 135, wash trades pay fees on
*both* legs, so the mitigation strengthens; the reasoning text should be refreshed but
the conclusion holds.

**Sequencing (single publish):** one release branch, implementation order
135 → 138 → 137, one deployment at the end.

- Nothing freezes until publish, so intermediate struct/event shapes are free to churn
  on the branch — 135 does not need to pre-build 137's bracket-ready `TradeParams`;
  137's phases reshape it in place before release.
- 135 and 138 rework the same functions (`order.move`, `vault.move`, `process_fills`,
  `QuoteFeeDeposit`, history recognition) — implement back-to-back to avoid
  hand-merging.
- Events get their final shapes once: `EpochData` (both rates), `OrderFilled`
  (truthful `maker_fee` + 137's effective rate / bracket index), cancel/modify events
  (138's refund amount). Off-chain consumers see a single schema migration.
- 138's header dependency ("dual-sided fees, ask half only") is satisfied within the
  branch, and its §5 V2-event caveat dissolves entirely.
- Release-level interaction tests to add: refunds × brackets (under fill-time counting,
  refunded fees never entered turnover, so no decrement path should be needed — verify;
  likewise the 20% cancellation retention must be excluded from turnover), and
  ask-maker fill fees charged at the order's snapshotted marginal rate.
- **Cancellation retention (decided 2026-09-06):** cancels/modify-downs/expiries refund
  80% of the locked bid-maker fee; the 20% retention is recognized as revenue. Under D1
  this reaches only bid makers — asks lock nothing, so ask-side place/cancel churn
  carries no fee cost. Details and loophole closures live in the 138 plan.

---

## 5. Remaining open questions

None — both resolved 2026-09-06:

1. ~~2 rates vs 4~~ — **2 rates (taker/maker)**, confirmed via the defaults being
   specified as a taker/maker pair only.
2. ~~Maker default rate~~ — **taker 2.2%, maker 1.8%** at pool creation.

Additional decisions made during PR 1 implementation (2026-09-06):

3. **Stable/volatile pool distinction removed entirely.** The
   `Governance.stable` flag, the stablecoin auto-classification at pool
   creation, the separate stable fee range, and the registry stablecoin
   whitelist (`add_stablecoin` / `remove_stablecoin` / `is_stablecoin`) are
   all deleted. One fee-bounds set for every pool:
   `MIN_TAKER_FEE` 1 bp, `MAX_TAKER_FEE` 100%, `MAX_MAKER_FEE` 100% (maker floor
   0). This also removed a latent inconsistency where stable pools launched
   at the global 2%+ default but could only be re-set within their 0.1–1 bp
   admin range.
4. **Defaults decoupled from caps.** `DEFAULT_TAKER_FEE` (2.2%) and
   `DEFAULT_MAKER_FEE` (1.8%) are independent constants; the 100% caps leave
   admin headroom to raise rates without a package upgrade.
5. **Per-pool-type defaults.** Multicoin pools launch at taker 1.1% / maker
   0.9% (`governance::empty_multicoin`, mirroring the `book::empty` /
   `book::empty_multicoin` idiom); coin pools keep 2.2% / 1.8%. Caps and
   floors are shared across pool types.
