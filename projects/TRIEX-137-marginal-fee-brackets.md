# TRIEX-137 — Marginal trading fee rates via per-epoch fee turnover

> Plan for [TRIEX-137](https://plane.so) (medium priority, backlog): replace the flat
> per-pool `fee` with progressive (marginal) brackets keyed on fees an account has
> already paid in the current epoch — plus a written feasibility investigation of a
> top-N ranked variant **before** any leaderboard code lands.
>
> **Release branch:** `cycle-7` — single publish together with TRIEX-135 and
> TRIEX-138; implementation order 135 → 138 → 137. Flat defaults after 135:
> taker 2.2%, maker 1.8% (bracket 0 = base rate starts from these). Maker fees
> count toward turnover at **fill time**, not lock time — see 135 §4's blocking
> note (decided 2026-09-06).

## Current state of the code

- **Flat rate, bid-side only**: `sources/state/trade_params.move` —
  `taker_fee_for_user(is_bid)` returns `fee` for bids, `0` for asks; same for makers.
  The old DeepBook stake-based discount is fully commented out under `#feat:fees`.
- **Fill-time application**: `state::process_create` (`sources/state/state.move`)
  fetches the rates and passes them into `order_info::calculate_partial_fill_balances`
  (`sources/book/order_info.move`), which iterates fills, charges the quote-denominated
  taker fee per fill via `quote_fee`, and **locks the maker fee upfront** on the resting
  remainder. The account is already in scope here — good hook for turnover.
- **Historic replay**: cancel/modify (`state::process_cancel` / `process_modify`) and
  `locked_balance` (`sources/pool.move`) replay `history::historic_fee_rate(order.epoch())`
  — a **global per-epoch rate** snapshotted in `Volumes.trade_params`. With per-account
  marginal rates, a global replay can no longer reconstruct what an account actually
  locked. Note: `calculate_cancel_refund` currently takes the fee as `_maker_fee`
  (unused — locked fees aren't refunded on cancel, see `sources/book/order.move`), so
  the replay concern today is mainly `locked_balance` reporting and the modify path.
- **Epoch machinery already exists**: `account::update` resets per-account volumes on
  rollover, `history::update` snapshots per-epoch `Volumes` including trade params,
  `governance::update` promotes `next_trade_params`. Pool-wide `total_fees_collected`
  is tracked, but **per-account fee turnover is not** — that's the new field.
- **Governance is admin-direct**: `set_next_epoch_fee` → `governance::set_next_trade_params`
  with `FEE_MULTIPLE`/min/max validation (`sources/state/governance.move`). Brackets
  slot in here.
- **Second fill path**: `sources/multicoin_pool.move` duplicates the fee-rate selection
  and must stay in parity.

## Implementation plan

### Phase 0 — Design decisions to settle first

1. **Turnover metric**: the ticket specifies fees-paid (not volume). Bracket thresholds
   live in fee-paid space, so crossing a boundary mid-fill requires inverting:
   remaining bracket capacity in fee terms ÷ rate = flow that fills it. Straightforward
   but worth a dedicated pure function.
2. **When maker fees count as "paid"**: they're locked at placement and never refunded
   on cancel — recommend counting them at lock time (simplest, matches economic
   reality here).
3. **Dry-run semantics**: `get_quantity_out_input_fee` (`sources/pool.move`) has no
   account context. Decide: quote at base (worst-case) rate, or add an account-aware
   overload.

### Phase 1 — Bracket config + governance

Files: `trade_params.move`, `governance.move`, `state.move`, `pool.move`

- Extend `TradeParams` with a bracket schedule (`vector` of `{threshold, rate}`;
  bracket 0 = base rate, thresholds strictly increasing, rates non-increasing, each
  within existing MIN/MAX + `FEE_MULTIPLE` validation). Because `TradeParams` is
  already snapshotted per-epoch into `Volumes`, historic bracket schedules come along
  for free.
- Extend `set_next_trade_params` / `set_next_epoch_fee` and `TradeParamsUpdateEvent`
  / `EpochData`.

### Phase 2 — Per-account turnover

Files: `account.move`, `state.move`

- Add `epoch_fees_paid: u64` to `Account`; reset in `account::update` alongside the
  volume resets.
- Re-enable the currently-commented `account.update(ctx)` call inside
  `state::update_account` so the reset actually fires on the taker path.

### Phase 3 — Marginal application at fill time

Files: `order_info.move`, `quote_fee.move`, `state.move`, `multicoin_pool.move`, `order.move`

- New pure function `marginal_fee(brackets, fees_already_paid, quote_flow) →
  (fee_amount, effective_rate)` with the bracket-boundary blending math; unit-test it
  in isolation.
- Thread the account's `epoch_fees_paid` into `calculate_partial_fill_balances` (both
  pool paths); accumulate across fills within one order; write back to the account
  after settlement.
- **Persist the effective locked rate on `Order`** at placement (new field next to
  `epoch`) so `locked_balance`/modify use the order's own rate instead of the global
  `historic_fee_rate` replay — this is the acceptance criterion about orders resting
  across a bracket change.

### Phase 4 — Events

- Add effective rate + bracket index to `OrderFilled` (`sources/book/order_info.move`)
  for indexer/UI tier display.

### Phase 5 — Tests

- Marginal math edge cases: exact threshold, mid-fill crossing, single-bracket = flat
  equivalence.
- Epoch-rollover turnover reset.
- Order resting across an epoch settling at its recorded rate.
- Governance validation rejects bad schedules.
- Multicoin parity.
- Run `build_scripts/verify-bytecode-meter.sh` — the marginal loop sits on the hot
  fill path.

### Phase 6 — Ranking investigation (deliverable before any leaderboard code)

- Sketch a fixed-size top-N (`vector<(ID, u128)>`, N≈8) in `Volumes`; insert/evict is
  O(N) but only touched when an account's turnover would enter the set — negligible
  for most fills.
- Working position: **previous-epoch settled ranking** is the right call (the ticket
  hints at it too) — mid-epoch demotion makes fills non-deterministic in cost and
  invites last-block rank sniping, and live top-N is the most gameable variant.
  Wash-trading cost is partially mitigated by the bid-side-only fee (self-trading
  pays the fee on the buy leg regardless).
- Write the recommendation up as a comment on TRIEX-137 per the acceptance criteria.

## Sequencing

Phase 6's write-up can happen first or in parallel — it gates nothing in phases 1–5,
which implement threshold brackets regardless of the ranking decision.

## Acceptance criteria (from the ticket)

- A trader crossing a bracket mid-epoch pays the blended marginal rate, not the new
  rate retroactively.
- Turnover resets at epoch boundaries and orders resting across the boundary settle
  against the right historic rate.
- Ranking decision written up on TRIEX-137 before any leaderboard code lands.
