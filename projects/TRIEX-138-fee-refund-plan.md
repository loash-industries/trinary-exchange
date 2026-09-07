# TRIEX-138 — Fee refunds on order cancellation

Analysis and implementation plan for returning the maker fee locked with a resting
order when that order is cancelled (or expires) without filling, so an unexecuted
order costs nothing but gas.

- **Ticket:** TRIEX-138
- **Package:** `packages/triex` (`triexbook`)
- **Status:** in progress — step 1 (escrow tracking + withdrawal cap) implemented on
  `triex-138-pr1-locked-fee-escrow`; steps 2–6 (the refund itself) still open
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
- ⏭️ `unlock_quote_fees(amount)` (`quote_balance.join(quote_fee_reserve.split(amount))`
  + `PoolFeesRefunded`) deferred to PR2, where the refund path first needs it —
  adding it in PR1 would have been dead code.
- ~~Note: `QuoteFeeDeposit` bundles taker + maker fees into one amount~~ — already
  split by TRIEX-135, so only the maker part is counted as locked.
- **Rounding note:** the lock floors once over the whole order while recognition
  floors per fill/cancel, so a resolved order can leave a few units still counted
  as locked. That errs toward under-withdrawing rather than spending escrow, which
  is the safe direction; PR2's refund inherits the same bias.

### 2. Refund computation

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

### 3. Expiry path

- When a fill is `expired` and the maker is a bid, include **80% of** the fee on
  the returned quantity in the maker's settled balances (in `state::process_fills`,
  which has `fill.maker_epoch()` for the historic rate), unlock that portion from
  the reserve, and recognize the retained 20% as revenue.
- The ticket doesn't name expiry, but it's the same "cancelled without filling"
  economics — flag in the PR as an included fix.

### 4. Epoch fee accounting (acceptance #3)

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

### 5. Events

- Add the refund amount to cancel/modify events.
- Caveat: Sui package upgrades can't change existing struct layouts, so this
  likely means `OrderCanceledV2`-style events (or relying on the new
  `PoolFeesRefunded` event alone to avoid V2 events for now — the indexer gets the
  data either way).

### 6. Mirror in multicoin

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

- [ ] Place → cancel with no fills returns the balance manager to its pre-order
      state minus **20% of the locked maker fee** minus gas. *(Amended from "exact
      pre-order state" by the 80% retention decision, 2026-09-06.)*
- [ ] Partial fill → cancel refunds 80% of the unfilled portion's fee only.
- [ ] Modify-down and expiry apply the same 80/20 split (no avoidance path).
- [ ] Epoch fee totals match fees on actually-filled volume **plus cancellation/
      expiry retentions**; retentions excluded from per-account bracket turnover.
