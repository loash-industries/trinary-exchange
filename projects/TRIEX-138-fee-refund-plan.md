# TRIEX-138 — Fee refunds on order cancellation

Analysis and implementation plan for returning the maker fee locked with a resting
order when that order is cancelled (or expires) without filling, so an unexecuted
order costs nothing but gas.

- **Ticket:** TRIEX-138
- **Package:** `packages/triex` (`triexbook`)
- **Status:** in progress — step 1 (escrow tracking + withdrawal cap) landed as
  PR #5; steps 2–6 (the refund itself) implemented on
  `triex-138-pr2-fee-refunds`
- **Depends on:** dual-sided fees (for the ask-side half only)
- **Release branch:** `cycle-7` — single publish together with TRIEX-135 and
  TRIEX-137 (decided 2026-09-06)

## Audit findings — where the money actually goes

### Locking (works)

On a bid placement, `order_info::calculate_partial_fill_balances`
(`sources/book/order_info.move`) computes the maker fee on the *remaining*
quantity and adds it to `owed`. The pool then wraps `paid_fees + maker_fees` in a
`QuoteFeeDeposit` (`sources/pool.move:1478-1493`), and `vault::settle_balance_manager`
splits that amount out of the withdrawn quote into a **separate `quote_fee_reserve`
bucket** — not `quote_balance` (`sources/vault/vault.move:178-196`).

### Refunding (broken — confirmed)

`order::calculate_cancel_refund` takes the historic fee rate that
`state::process_cancel` / `process_modify` carefully re-derive… as `_maker_fee`,
and **ignores it**. The comment is explicit: *"no refund of previously locked fees
is issued on cancel"* (`sources/book/order.move:186-190`). The locked fee stays in
`quote_fee_reserve` forever and is sweepable by the admin via `withdraw_pool_fees`.

Three more gaps compound this:

1. **Expiry loses the fee too** — an expired bid maker gets back only quote
   principal via `fill::get_settled_maker_quantities`; the locked fee is stranded
   identically.
2. ~~**Epoch accounting is wrong in the *other* direction than the ticket fears**~~ —
   *resolved by TRIEX-135:* maker fees are now recorded into
   `total_fees_collected` at fill time on both sides, and `OrderFilled.maker_fee`
   is truthful. The ticket's "never added until the fill happens" is exactly the
   behavior that shipped, so §4 below is already satisfied for fill-time
   recognition; only the cancel/expiry retention side remains.
3. **Reserve solvency / admin race** — nothing distinguishes *earned* fees from
   *still-locked* fees in `quote_fee_reserve`. Admin can withdraw fees backing open
   orders; once refunds exist, that makes refunds abortable
   (`EInsufficientFeeReserve`).

Also worth noting:

- The `locked_balance` **view already includes the fee** as recoverable
  (`sources/pool.move:1246-1253`) — the view and the cancel path disagree today,
  which confirms refund-on-cancel is the intended semantics.
- A settlement subtlety shapes the whole fix: settled quote is paid out of
  `quote_balance`, so a refund **must move funds `quote_fee_reserve` →
  `quote_balance` at cancel time** — just adding quote to settled balances would
  pay refunds out of other users' principal.

## Design decisions (per the ticket)

- **Historic-epoch rate:** keep — already plumbed via
  `history::historic_fee_rate(order.epoch())`.
- **Partial refund — 80% (decided 2026-09-06):** cancellation refunds 80% of the
  locked maker fee; the 20% retention stays in the reserve as *earned* protocol
  revenue. This folds the previously-deferred **anti-spam cancellation fee** into
  this release instead of a follow-up ticket. Floor-rounding dust is additionally
  retained (refund = `floor(locked_fee × 80%)`, so refund ≤ locked always holds).
- **Retention rate as an admin-set param, not a constant:** add
  `cancel_retention_bps` (default `2000` = 20%, validated `0..10000`) alongside the
  trade params, set through the same `TriexbookAdminCap`-gated path as
  `set_next_epoch_fee` (there is no governance — the `governance.move` module is
  legacy-named, proposals/voting are disabled), snapshotted at placement like the
  rates — policy changes affect only new orders.
- **Scope asymmetry to be aware of:** under TRIEX-135's design only *bid* makers
  lock fees; asks pay from proceeds at fill and lock nothing. The retention therefore
  only ever bites bid makers — place/cancel churn on the ask side remains free at the
  fee level. If symmetric anti-spam pressure is wanted later, it needs a different
  mechanism (e.g. flat cancel fee), out of scope here.
- **Loophole closures (required, or the retention is decorative):**
  - *Modify-down* must retain 20% of the released fee delta too, else
    modify-to-minimum-then-cancel dodges nearly all retention. Cost: makers who
    requote by modifying down pay a churn tax — accepted.
  - *Expiry* must retain 20% as well, else spam orders simply carry
    `expire_timestamp = now + ε` and never cancel.

## Plan

### 1. Vault: fee unlock primitive + locked-fee tracking — **done (PR1)**

- ✅ `locked_maker_fees: u64` added to both vaults alongside `quote_fee_reserve`,
  incremented by the maker portion of `QuoteFeeDeposit` at placement and
  decremented as the escrow resolves: `recognize_locked_maker_fees` is called on
  bid-maker fills (`state::process_fills` reports the amount via `FeeFlows`) and
  on cancel/modify-down (`process_cancel` / `process_modify` return the released
  amount). Cancellation still *forfeits* — PR2 turns that same amount into the
  80/20 refund split, so no accounting changes shape.
- ✅ `withdraw_quote_fees` capped at `reserve − locked_maker_fees` (`EFeesLocked`),
  exposed as `pool::locked_maker_fees` / `pool::withdrawable_pool_fees`. The
  TRIEX-135 characterization test is replaced by its inverse.
- ✅ `unlock_quote_fees(amount)` (`quote_balance.join(quote_fee_reserve.split(amount))`
  + `PoolFeesRefunded`) added in PR2, where the refund path first needs it —
  adding it in PR1 would have been dead code.
- ~~Note: `QuoteFeeDeposit` bundles taker + maker fees into one amount~~ — already
  split by TRIEX-135, so only the maker part is counted as locked.
- **Rounding note:** the lock floors once over the whole order while recognition
  floors per fill/cancel, so a resolved order can leave a few units still counted
  as locked. That errs toward under-withdrawing rather than spending escrow, which
  is the safe direction; PR2's refund inherits the same bias unchanged, since
  `refund + retained == basis` exactly. The residues accumulate over the pool's
  lifetime with no reconciliation path (at most one raw quote unit per release);
  left uncorrected deliberately, and now documented as cumulative rather than
  per-order in both vaults.

### 2. Refund computation — **done (PR2)**

- Make `calculate_cancel_refund` use the fee rate. The basis is already computed by
  `order::locked_fee_released` (added in PR1, used there to report the forfeited
  amount) via `quote_fee::fee_from_scaled_rate` — the same helper lock time uses,
  since TRIEX-135's follow-up fix retired the `scaled_to_bps` truncation; refund =
  `floor(basis × (10000 − cancel_retention_bps) / 10000)`; retained =
  `basis − refund` stays in the reserve as earned revenue (partial fills and
  modify-down get pro-rata treatment automatically, since `cancel_quantity` is
  already threaded through both paths).
- `process_cancel` / `process_modify` return the fee-refund amount (e.g.
  `(Balances, Balances, u64)`); pool calls `vault.unlock_quote_fees(refund)`
  *before* `settle_balance_manager`, and the refund rides in settled quote — this
  keeps `withdraw_settled_amounts` and the permissionless path working unchanged.

### 3. Expiry path — **done (PR2)**

- When a fill is `expired` and the maker is a bid, include **80% of** the fee on
  the returned quantity in the maker's settled balances (in `state::process_fills`,
  which has `fill.maker_epoch()` for the historic rate), unlock that portion from
  the reserve, and recognize the retained 20% as revenue.
- The ticket doesn't name expiry, but it's the same "cancelled without filling"
  economics — flag in the PR as an included fix.

### 4. Epoch fee accounting (acceptance #3) — **done (PR2)**

- Adopt "never counted until fill" for the refundable portion: in
  `state::process_fills`, compute the maker's retained fee on
  `fill.quote_quantity()` at the order's snapshotted rate,
  `add_total_fees_collected`, and `set_fill_maker_fee` so `OrderFilled.maker_fee`
  becomes truthful.
- **Cancellation/expiry retentions are also recognized into
  `total_fees_collected`** at cancel/expiry time (they are realized revenue) — or a
  dedicated counter/event if analytics wants them separable from fill fees.
- **Retentions must NOT count toward TRIEX-137 bracket turnover** — only fill-time
  fees do. Otherwise cancel churn buys fee-tier progress at 20¢ on the dollar.
- Taker fees stay as-is.

### 5. Events — **done (PR2)**

- Add the refund amount to cancel/modify events. ✅
- Caveat: Sui package upgrades can't change existing struct layouts, so this
  likely means `OrderCanceledV2`-style events (or relying on the new
  `PoolFeesRefunded` event alone to avoid V2 events for now — the indexer gets the
  data either way).
- **Decided (PR2): refund and cancellation events are explicitly associated.**
  `OrderCanceled`, `OrderModified` and `OrderExpired` each gain `fee_refunded`
  and `fee_retained`, so the whole outcome of a release reads off one event, and
  `PoolFeesRefunded` gains `order_id` so the vault-side movement joins back to
  it. Both halves are reported because only the refunded half moves funds — the
  retained half stays in the reserve and the vault has nothing to emit for it.
  Layout changes are fine on the cycle-7 fresh publish; an in-place upgrade
  would have needed V2 events instead.
- Restructuring `FeeFlows.refunded` into a per-maker `vector<RefundedFee>` was
  required for this: a single match can expire several makers' orders, and the
  aggregate unlock attributed every refund to the *taker's* balance manager.
  The funds movement was correct (the vault nets at pool level), but the event
  named the wrong account. Regression-tested by
  `test_expiry_refund_event_attributes_the_maker`.

### 6. Mirror in multicoin — **done (PR2)**

- Same changes in `sources/multicoin_pool.move` (cancel/modify at lines 561–687,
  placement fee deposit at 1068–1083) and `sources/vault/multicoin_vault.move`,
  with `price_scaling = 1`.
- `cancel_orders` / `cancel_all_orders` in both pools just loop over
  `cancel_order`, so they inherit the fix for free.

### 7. Ask side (blocked on dual-sided fees)

- Keep the `is_bid ? historic_rate : 0` branching intact so dual-sided fees only
  has to flip the rate selection. No work now beyond not hardcoding bid-ness
  deeper.

### 8. Tests

- **Unit:** `order_tests` (refund math incl. rounding dust), `quote_fee_tests`,
  vault reserve-movement + admin-withdrawal-cap tests.
- **Integration:**
  - place → cancel returns exact pre-order balance (acceptance #1)
  - partial fill → cancel refunds only the unfilled portion (acceptance #2)
  - modify-down pro-rata refund
  - cancel after epoch/fee-rate change uses historic rate
  - expiry refund
  - epoch `total_fees_collected` = taker + maker fees on filled volume only
    (acceptance #3)
  - admin cannot withdraw locked fees
  - multicoin mirrors of the above
- Update `locked_balance_tests` if refund semantics change its expectations (they
  shouldn't — the view already includes the fee).

## Order of work

Vault primitive → refund math → state/pool wiring → expiry → history accounting →
events → multicoin mirror → tests throughout.

The riskiest piece is the reserve-bucket solvency (steps 1–2); land it with an
invariant test that `quote_fee_reserve ≥ locked_maker_fees` across a randomized
place/fill/cancel sequence.

## Acceptance criteria (from ticket)

- [x] Place → cancel with no fills returns the balance manager to its pre-order
      state minus **20% of the locked maker fee** minus gas. *(Amended from "exact
      pre-order state" by the 80% retention decision, 2026-09-06.)*
      — `test_cancel_refunds_escrow_to_maker`, multicoin mirror
      `test_multicoin_cancel_refunds_escrow_to_maker`.
- [x] Partial fill → cancel refunds 80% of the unfilled portion's fee only.
      — `test_cancel_after_partial_fill_refunds_unfilled_only`.
- [x] Modify-down and expiry apply the same 80/20 split (no avoidance path).
      — `test_modify_down_releases_escrow_proportionally`,
      `test_expired_bid_maker_is_refunded`,
      `released_fee_split_prorates_on_modify_down`.
- [x] Epoch fee totals match fees on actually-filled volume **plus cancellation/
      expiry retentions**; retentions excluded from per-account bracket turnover.
      — `process_cancel_recognizes_only_the_retention`,
      `process_modify_recognizes_only_the_retention`,
      `process_fills_books_expiry_retention_as_collected`. Retention goes through
      `state::recognize_retention`, which touches `add_total_fees_collected` and
      deliberately not `add_volume`.

### Edge cases covered

A coverage sweep after the main implementation added these; the ones marked
**(gap)** were genuine holes rather than restatements of the acceptance
criteria.

- **Solvency under a full sweep (gap).** An admin sweeping every unlocked unit
  leaves the reserve holding exactly the outstanding escrow. `unlock_quote_fees`
  splits a real balance and aborts if short, unlike the saturating subtract
  recognition uses, so this is where `reserve >= locked` has to actually hold.
- **Repeated releases (gap).** Several modify-downs then a cancel, and several
  partial fills then a cancel. Each slice floors independently while the lock
  floored once, so the accumulated releases can only ever be <= the lock.
- **Several makers expiring in one match (gap).** The case that forced
  `FeeFlows.refunded` to become a per-maker vector; each refund is attributed to
  its own maker and order.
- **Expired ask (gap).** No escrow exists, so nothing is refunded — and the
  `OrderExpired` event must not claim otherwise. The funds paths are guarded by
  `taker_is_bid` twice over, but the event calls `maker_fee_refunded()`
  unguarded, so this is observable only in the event.
- **Self-match resolved with `cancel_maker` (gap).** Runs through the expiry
  branch but emits `OrderCanceled`; splits on cancel terms.
- **`cancel_all_orders` (gap).** Several bids plus an ask in one transaction:
  one refund each for the bids, none for the ask.
- **Rounding dust at pool scale (gap).** Lot size is 1000 raw units, far below
  `FLOAT_SCALING`, so a maker *can* rest a quantity whose escrow does not divide
  by five: 1000 quote at 1.8% escrows 18, and 80% of that is 14.4. The refund
  floors to 14 and retention takes 4. Dust must fall to the protocol — a refund
  that rounded up would pay a fraction of a unit out of another maker's escrow
  every time — and the halves must still sum to the released amount or
  `locked_maker_fees` could never reach zero.
- **Retention policy range.** `> 10000` bps aborts; 0 and 10000 are both legal;
  defaults are 2000 on both pool types. End-to-end, a zero-retention pool makes
  place -> cancel free at the fee level, and a 100%-retention pool emits no
  refund event at all.
- **Policy changes bind forward only.** A resting order keeps the retention it
  was placed under *and* an order placed after the change picks the new one up —
  the second half matters, or the rate would be unreachable rather than merely
  non-retroactive.
- **Multicoin mirrors** for cancel, modify-down, expiry (including maker
  attribution) and escrow tracking.

Two mutants survive deliberately. `expiry_fee_split`'s `!self.expired` guard is
unreachable — all four callers already test `expired()` — and the `taker_is_bid`
half is reachable only through the event. Both are defence in depth, not dead
code worth deleting.

Not covered, deliberately: retention on a **whitelisted** pool. In this fork
`whitelisted` does not mean fee-exempt — that is upstream DeepBook's meaning,
and nothing here reads the flag when pricing. Its only live effect is that
`set_next_trade_params` aborts with `EWhitelistedPoolCannotChange`, so such a
pool launches at the normal defaults (now including a 2000 bps retention) and
can never be re-rated. The precision test suites actually create whitelisted
pools to measure fees, so current behaviour is load-bearing. Whether the flag
should keep any meaning is a design decision, tracked as TRIEX-139; asserting
either way here would prejudge it.

### Closed alongside the refund

Two gaps found reviewing PR #5, both addressed here:

1. **Forfeited escrow never reached `total_fees_collected`.** PR1 reclassified
   cancel/modify/expiry escrow as sweepable revenue without booking it, so epoch
   fee totals understated realized revenue. Step 4's `recognize_retention` closes
   it for the retained share; the refunded share correctly stays out.
2. **`locked_maker_fees` rounding drift.** Not fixed — see the rounding note in
   step 1. Verified PR2 does not worsen it (`refund + retained == basis`), and the
   vault comments now describe it as cumulative rather than per-order.
