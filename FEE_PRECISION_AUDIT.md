# Fee precision audit — Trinary Exchange

**Scope.** Every quote-denominated fee path in `packages/triex`, traced end to end: order
placement → matching → fill settlement → escrow lock/recognition/refund → vault reserve →
admin sweep and hub-operator claim. Both pool families (`pool.move` coin pools,
`multicoin_pool.move`) and both quote conventions (`price_scaling = 1e9` and `= 1`).

**Commit.** `7471b3d` on `triex-hub-revenue-share`, plus the uncommitted F-1 fix in the working
tree (`math::quote_to_qty_capped`, its call site in `book.move`, and the two `pool_query_tests`
regressions).
**Baseline.** `sui move test` — 627/627 at audit time; 629/629 after the F-2 fix and its two
regression tests; **632/632** after the N-1, N-3 and F-4 follow-ups and their three.

**Second-pass correction.** F-3 was originally written up as a rounding bug with a
round-the-fee-up remedy, and that remedy was implemented and then **reverted**. It was wrong:
flooring is the *correct* rounding direction for a fee charged against a published rate, and the
minimum-charge rule levied up to 100% on a small quote leg. The finding below is rewritten
accordingly. N-3 was likewise downgraded — flooring a payout obligation is correct, not defective.
See *On what counts as a bug* below.
**Method.** Line-by-line re-trace of the fee lifecycle, a 500k-case fuzz of the bid-maker escrow
lifecycle *including the hub-share credit*, and 17 Move probes written against the real `book`,
`order`, `pool`, `multicoin_vault` and `fee_policy` (all passing; every number below is measured,
not estimated). This is a second pass — findings carried over from the first are re-verified
against the current tree rather than restated.

---

## Summary

| # | Finding | Severity | Status this pass |
|---|---|---|---|
| F-1 | `get_quantity_out` aborted on `EOverflow`; one dust ask bricked every coin-pool quote and swap above ~18.7k CRED | **High** | **Fixed** — re-verified, no residual overflow on either branch |
| F-2 | Bid dry run reserves 1.25× the taker fee it settles → systematic 0.14–0.54% under-fill | **Medium** | **Fixed** — undeployed input now 1 raw unit at every rung |
| N-1 | `locked_balance` aborts on a quote conversion the **ask** branch computes and discards | Low | **Fixed** — conversion narrowed into the bid arm, regression + control pinned |
| F-3 | Fees floor to zero below a per-fill quote threshold, with no minimum order size to bound it | Low | **Reclassified** — the rounding is correct; the defect is the missing `min_size`, plus per-fill rather than per-order aggregation |
| N-3 | The hub share floors on every recognition event, always toward the treasury | Info | **Reclassified** — correct rounding for a payout; the defect was a doc claim, now **corrected** |
| F-4 | `locked_maker_fees` residue is monotonic and never reconciled | Low | Re-fuzzed; bound confirmed, now also for the hub credit. Not a defect; the coin/multicoin view asymmetry it surfaced is **fixed** |
| F-5 | Effective cancel-retention on dust escrow reaches 100% | Low | Unchanged; intended |
| F-6 | `state.accounts` grows without bound from account-less swaps | Low | Unchanged |
| N-2 | `assign_operator_share_class` re-prices a hub immediately, defeating the staging guarantee | Info | **New** |
| N-4 | The `master_*` integration suites' balance expectations assert nothing | Info | **Fixed** — assertions live, expectations rebuilt, oracle mutation-tested |
| F-7 | `bootstrap_quote(quote_unit)` is unchecked against the coin's real decimals | Info | Unchanged; by design |

No finding lets anyone extract value that is not theirs, and **no finding is an accounting
unsoundness**: every path conserves — nothing is created, nothing is destroyed, and every raw unit
is attributable. F-1 was an availability bug and is fixed; F-2 was a genuine pricing bug and is
fixed; N-1 is an availability bug with a one-account blast radius; F-6, F-7, N-2 and N-4 are real
but outside the fee arithmetic. F-3, F-4, F-5 and N-3 are **not defects in the arithmetic** —
they are the correct conservative rounding, and the sections below say so rather than proposing to
"fix" them.

### On what counts as a bug

Three rules decide it, and they are what the reclassifications above turn on.

1. **Conservation.** Every raw unit that enters a path leaves it attributed to someone. This is the
   only one whose violation is an emergency, and nothing here violates it.
2. **The fee never exceeds the published rate.** `floor(q · r) ≤ q · r` always; `ceil` and any
   minimum-charge rule do not. An exchange that overcharges relative to its own schedule has a
   worse defect than one that under-collects sub-unit dust — the shortfall is bounded by one raw
   unit, while the overcharge is unbounded *as a rate* (a one-unit quote leg pays 100%).
3. **Rounding errs against the house.** A fee rounds down; a payout obligation (a maker refund, the
   hub's share) rounds down too, so it is never paid out of money that was not collected. F-4, F-5
   and N-3 are all this rule working correctly, which is why the residues they leave are stranded
   rather than leaked.

Where those rules collide with wanting the revenue, the resolution belongs at the **order-size
gate**, not in the rounding: a `min_size` keeps fills out of the range where the arithmetic cannot
express the fee. That is F-1's "still not fixed" enabler, and it is the single highest-value
change on this list.

---

## F-1 — `get_quantity_out` aborted on `EOverflow` (High) — **fixed, re-verified**

The full first-pass write-up (reachability, blast radius, the rejected first remedy, the shipped
one) stands as written; it is not repeated here. What this pass adds is verification that the fix
is total, not just sufficient for the reported trigger.

**The fix, as it now stands in the tree.** [math.move:44-71](packages/triex/sources/helper/math.move#L44-L71)
adds `quote_to_qty_capped`, which clamps on a `u128` intermediate instead of asserting on a `u64`
one, and [book.move:176-187](packages/triex/sources/book/book.move#L176-L187) passes `cur_quantity`
in as the cap rather than applying it afterwards.

**Re-verified, measured:**

| Probe | Result |
|---|---|
| `probe_f1_dust_ask_no_longer_aborts` | a 1-unit ask at `MIN_PRICE` moves the quote by exactly `+1` base unit instead of aborting |
| `probe_f1_max_price_level_quotes` | the opposite extreme — a 3e9-unit level at `MAX_PRICE`, quoted with `u64::MAX` of input — returns 1_972_872_996 base and leaves quote unspent, so the round trip back through `qty_to_quote` does not abort either |
| `pool_query_tests::test_dust_priced_level_does_not_break_the_quote` | in-tree regression, e2e through `pool` |
| `pool_query_tests::test_dust_priced_level_does_not_break_the_swap_router` | in-tree regression, `swap_exact_quote_for_base` |

**Why the neighbouring conversion cannot overflow, re-derived from scratch.** The line after the
clamp is `qty_to_quote(matched_base_quantity, cur_price, price_scaling)`, which still asserts on
`MAX_U64`. It is safe on both sides of the `min`:

- *Cap falls on the quotient.* `matched_base ≤ quantity_to_match · 1e9 / price`, so
  `matched_base · price / 1e9 ≤ quantity_to_match`, a `u64` by construction.
- *Cap falls on `cur_quantity`.* Then `cur_quantity ≤ quantity_to_match · 1e9 / price`, so
  `cur_quantity · price / 1e9 ≤ quantity_to_match` — same bound. This is the case the rejected
  first remedy got wrong: it converted `cur_quantity` *unconditionally*, where the bound does not
  hold.

Multicoin scaling is the same argument without the `1e9`. The ask branch is safe structurally: its
conversion is bounded by the resting bid's own size, and a bid at price `P` with quantity `Q` could
only have been placed if `qty_to_quote(Q, P)` fit — `calculate_partial_fill_balances` escrows
exactly that.

**Still not fixed — the enabler.** `MIN_PRICE` is 1 and `min_size` / `lot_size` / `tick_size`
remain commented out ([book.move:55-59](packages/triex/sources/book/book.move#L55-L59),
[book.move:371-372](packages/triex/sources/book/book.move#L371-L372)); `validate_inputs` checks
expiry, order type and price bounds and **nothing checks quantity at all**
([order_info.move:414-430](packages/triex/sources/book/order_info.move#L414-L430)). That is the
shared root of F-1, F-3, F-5 and N-1.

---

## F-2 — The bid dry run reserved 1.25× the fee it settles (Medium) — **fixed**

**Where.** [book.move:145-148](packages/triex/sources/book/book.move#L145-L148) and
[book.move:186-192](packages/triex/sources/book/book.move#L186-L192).

```move
let input_fee_rate = math::mul(
    constants::fee_penalty_multiplier(),   // 1_250_000_000 — "25% more than normal"
    trade_specific_taker_fee,
);
...
quantity_in_left = quantity_in_left - math::mul(matched_quote_quantity, input_fee_rate);
```

The bid branch sizes the fill against `1.25 × taker_rate`. Settlement charges the **plain** rate:
`order_info::calculate_partial_fill_balances` calls
`quote_fee::fee_from_scaled_rate(taker_fee, fill.quote_quantity())`
([order_info.move:341-347](packages/triex/sources/book/order_info.move#L341-L347)) with no
multiplier anywhere. The gap is input the swap simply never deploys.

`FEE_PENALTY_MULTIPLIER` has exactly one non-test caller — this line
(`grep -rn fee_penalty_multiplier sources/`). It is vestigial: the name and comment describe a
design where the input-token fee path *charged* a penalty rate, and nothing in this codebase does.

**Re-measured this pass**, against a deep level at human price 1.00, 1,000 CRED in:

| Rate | Rung | Input never deployed | As % of input |
|---|---|---|---|
| 1.10% | coin entry (tier 0) | **2_712_701** | 0.271% |
| 2.20% | multicoin entry (tier 0) | **5_352_799** | 0.535% |
| 0.55% | coin top (tier 7) | **1_365_613** | 0.137% |

So it scales with the fee tier: worst for multicoin pools and for tier-0 traders, and it never
goes away — even the cheapest trader on the ladder eats 0.137%.

The ask branch has no such multiplier — it nets the fee per level through the exact call
settlement makes, and `probe_f2_ask_direction_is_exact` confirms the quote equals
`gross − fee_from_scaled_rate(rate, gross)` **to the raw unit**. So buy and sell quotes are
**asymmetric**: any router reading these getters sees a phantom half-spread that exists only on
the bid side and only in the quote, not in the book.

**No funds are lost** — `swap_exact_quantity` hands the unspent quote back, and `min_out` is
checked against base received, so slippage protection stays consistent with the (pessimistic)
quote. The damage is fill quality and quoted price competitiveness.

### The fix

The bid branch now sizes against `trade_specific_taker_fee` and prices the reservation through
`quote_fee::charged_fee_from_scaled_rate` — the same helper, on the same per-level basis, that
`calculate_partial_fill_balances` settles with. `FEE_PENALTY_MULTIPLIER` had no other caller and
is **deleted** from `constants.move` rather than left dormant: a constant named for a penalty
nothing charges is how this survived in the first place. The dead `fee_waived` flag and its three
branches went with it.

**Why removing the cushion is safe.** `swap_exact_quantity_with_trading_account` computes
`quote_left = quote_in − cumulative_quote − paid_fees` as a `u64`, so an under-reservation aborts
rather than merely under-filling. The reservation cannot fall short, but *not* for the reason a
first reading suggests — the dry run and the real fill do **not** allocate identically:

- The dry run allocates by **quote budget**, level by level, and can stop partway through a level
  and still carry a residue onto the next one.
- The order it produces is sized in **base**, and refills greedily: level *k* takes
  `min(level_remaining, base_left)`, so it can pull into the cheap end quantity the dry run had
  spread across dearer levels.

What holds is weaker and sufficient: at every level the market order takes **at least** as much as
the dry run did from the cheapest levels first, so its cumulative cost is **≤** the dry run's
estimate. Under a monotone `floor` the fee follows. Verified rather than argued —
`a_fragmented_book_never_costs_more_than_the_dry_run_reserved` runs 40 thin asks at climbing
prices across 12 input sizes and asserts `cumulative + paid_fees ≤ quote_in` every time.

Per level, `quantity_to_match = floor(L · 1e9 / (1e9 + r))` additionally forces
`matched_quote + fee ≤ L`, with at least one raw unit of slack whenever `r > 0`.

**Re-measured after the fix**, same book and same 1,000 CRED input:

| Rate | Rung | Input never deployed — before | after |
|---|---|---|---|
| 1.10% | coin entry (tier 0) | 2_712_701 (0.271%) | **1** |
| 2.20% | multicoin entry (tier 0) | 5_352_799 (0.535%) | **1** |
| 0.55% | coin top (tier 7) | 1_365_613 (0.137%) | **1** |

One raw unit is the level's own price granularity — quote the book cannot spend at that price —
not a fee reserve. The bid and ask directions now quote the same fee for the same trade.

**Regression tests** (both fail against the unpatched code, verified by reinstating the
multiplier):

| Test | Pins |
|---|---|
| `book_tests::bid_dry_run_reserves_exactly_the_fee_that_settles` | the reservation equals what settles; residue is sub-unit, not a fraction of a percent |
| `book_tests::a_round_trip_costs_exactly_two_taker_fees` | buy-then-sell at one price costs exactly two fees and nothing else — the asymmetry stated as a round trip |

`pool_test_utils::test_order_limit` carried the multiplier in its own expected values; those two
assertions now derive from the plain rate.

---

## N-1 — `locked_balance` aborts on a conversion the ask branch discards (Low) — **new**

**Where.** [order.move:274-303](packages/triex/sources/book/order.move#L274-L303).

```move
public(package) fun locked_balance(self: &Order, maker_fee: u64, price_scaling: u64): Balances {
    ...
    let remaining_quote_quantity = math::qty_to_quote(   // <- unconditional
        remaining_base_quantity,
        order_price,
        price_scaling,
    );

    if (is_bid) { ... } else {
        balances::new(base_quantity, quote_quantity, 0)   // <- never uses it
    }
}
```

An ask locks base and nothing else, and the `else` arm proves it — `quote_quantity` is still zero
there. But the conversion is computed before the branch, and `qty_to_quote` asserts its result
fits in `u64`. So an ask large enough at a high enough price aborts a function that was only ever
going to return its own base quantity.

**Threshold.** `qty · price / 1e9 > 2^64 − 1`. At `MAX_PRICE = 2^63 − 1` that is exactly
`qty ≥ 2_000_000_001` raw base units — **2.000000001 tokens at 9 decimals**. Multicoin pools have
no `/1e9`, so their threshold is `qty · price > 2^64 − 1`, lower by a factor of 1e9 in
price-quantity product.

**Reachability — confirmed end to end, not inferred.** Nothing upstream blocks it: `validate_inputs`
checks no quantity, placing an ask escrows base only (`calculate_partial_fill_balances` takes the
`!is_bid` branch and never converts), and `MAX_PRICE` is an accepted price. Measured through the
ordinary public API:

```
[ PASS ] n1_locked_balance_control          // ask @MAX_PRICE qty 2_000_000_000 -> reads fine
[ PASS ] n1_locked_balance_bricked_by_own_ask // qty 2_000_000_001 -> pool::locked_balance aborts, math::EOverflow
[ PASS ] probe_n1_locked_balance_ask_control
[ PASS ] probe_n1_locked_balance_ask_overflows
[ PASS ] probe_n1_locked_balance_ask_overflows_multicoin
```

**Blast radius, honestly.** `pool::locked_balance` iterates *only the passed account's* open orders
([pool.move:1364-1394](packages/triex/sources/pool.move#L1364-L1394)), so this is self-inflicted:
one account bricks its own locked-funds view and nobody else's. It is recoverable — cancelling the
order restores it, and `cancel_order` does not go through `locked_balance`. The one non-self case
is a delegated trader: a `TradeCap` holder can place the order on the owner's account and break the
owner's view.

Not organic, either. At the canonical coin-pool encoding (`price = human × 1e6`, 9-decimal base)
the trigger is `qty_tokens × human_price > 1.8447e13` — a million tokens at a human price of
18.4 million. Like F-1, it takes a deliberately extreme order.

### The fix

The conversion now lives inside the `is_bid` arm, where its only consumer is
([order.move:273-300](packages/triex/sources/book/order.move#L273-L300)). A pure narrowing — the
`else` arm already ignored the value — so no reachable path that did not previously abort changes
behaviour. The two accumulators the old shape needed (`base_quantity`, `quote_quantity`, both
written exactly once) went with it, and the comment says why the placement matters so the next
reader does not hoist it back out for tidiness.

**Regression tests**, in `integration_locked_balance_tests`:

| Test | Pins |
|---|---|
| `test_locked_balance_ask_past_the_quote_overflow_threshold` | an ask of 2_000_000_001 at `MAX_PRICE` reads as base-only instead of aborting — fails against the hoisted version, verified by reinstating it |
| `test_locked_balance_ask_below_the_quote_overflow_threshold` | the control one raw unit below, so a later change that *moves* the threshold rather than removing it cannot pass by making both cases abort |

---

## F-3 — Fees floor to zero below a per-fill threshold (Low) — **reclassified: the rounding is correct**

`quote_fee::fee_from_scaled_rate` floors. At the 1.10% coin entry rung, any fill whose quote leg
is **under 91 raw units** pays no fee; at the 2.20% multicoin rung, under 46. Measured: a sweep
across **50 levels of 90 raw quote each** returns all **4,500 raw units** of proceeds with **zero
fee**, where the same 4,500 charged once would have paid **49**.

### Why the obvious fix is wrong

The first pass proposed `if (fee == 0 && quote_quantity > 0 && rate > 0) fee = 1`. That was
implemented, measured, and **reverted**. It breaks rule 2: the fee must never exceed the published
rate. Measured effective rates under that rule, against a **published 1.10%**:

| quote leg | levied | vs published |
|---|---|---|
| 1 raw unit | **100%** | 90× |
| 10 | **10%** | 9× |
| 20 | **5%** | 4.5× |
| 90 | 1.111% | 1.01× |
| 91 | 1.0989% | under ✓ |

The overcharge is unbounded *as a rate* precisely where the finding claimed to matter most — a
low-decimal or high-unit-value quote. On a 1-decimal quote a `$2.00` fill would pay `$0.10`: a 5%
fee against a 2.2% schedule. An ask maker whose fill has a one-unit quote leg would receive
**zero** proceeds for base they gave up. And it introduces a per-fill minimum charge that no
`FeePolicy` declares — the policy's only floor is `MIN_TAKER_FEE`, a floor on the *rate*, which is
the system's whole pricing model.

It also creates a griefing edge that did not exist: an attacker resting 99 dust levels makes a
victim's sweep cross 100 fills instead of one, and under a per-fill minimum each of those costs
the victim an extra raw unit. Trivial in money, but it is a new way to make someone else pay more.

Under-collecting sub-unit dust is the correct failure mode here. It is bounded by one raw unit per
fill, it errs against the house, and it conserves.

### What the actual defects are

Two things remain genuinely wrong, and neither is the rounding rule:

1. **No minimum order size.** `min_size`, `lot_size` and `tick_size` are commented out and
   `validate_inputs` checks no quantity at all, so fills sit in the range where the arithmetic
   cannot express a fee *by construction* rather than by accident. This is the real fix, it is the
   same enabler as F-1 and N-1, and it is a product decision rather than an arithmetic one.
2. **The fee is floored per fill rather than per order.** A taker sweep pays `Σ floor(qᵢ · r)`
   where `floor(Σqᵢ · r)` would be both more accurate *and* still within rule 2 — flooring the
   aggregate can never exceed `Σqᵢ · r` either. At `max_fills = 100` that is up to 99 raw units of
   fee foregone per transaction, and in the 50-level measurement above it is the difference
   between 0 and 49.

   Aggregating the taker leg is a sound change and would also make the dry run *more* robust, not
   less: the market order a swap places is sized in base and refills greedily from the best level,
   so it consolidates differently than the quote-sized dry run did, and comparing two aggregates
   under a monotone `floor` is a cleaner relationship than comparing two per-level sums. It is not
   implemented here — it needs the per-fill amounts redistributed for the `OrderFilled` events, and
   the ask-maker leg cannot aggregate the same way because each maker is a separate account.

**Left as is.** No source change. The escrow side could not have been changed regardless: a bid
maker's fee is locked once over the whole order and released over pieces of it, and it is floor's
subadditivity that keeps the releases from outrunning the lock. Round a piece up and a refund gets
paid out of reserve the order never funded — F-4's stranding becomes a leak. Both `quote_fee` and
`fill` now carry that reasoning in-line so the next reader does not re-derive it the hard way.

---

## N-3 — The hub share floors on every recognition event (Info) — **reclassified**

**Where.** [multicoin_vault.move:227-241](packages/triex/sources/vault/multicoin_vault.move#L227-L241).
`credit_operator_share` is called once per recognition *event* — the bid-taker fee, one per
proceeds-fee entry, and the decrement inside `recognize_locked_maker_fees` — and each call floors
independently, so up to ~102 floors per transaction at `max_fills = 100`.

**Measured:** 100 recognitions of 1 raw unit at a 50% share credit the hub **0**; one recognition
of 100 credits **50**. A recognition of 9,999 raw units at the 1bp floor credits **0**.

**This is correct, not defective.** `operator_owed` is a payout obligation, and rule 3 says a
payout rounds down: the hub is never credited value the reserve did not collect, and the remainder
is not lost — it stays in the reserve as treasury revenue, so the path conserves. Rounding the
other way would pay the hub out of the treasury's share on every dust fill. The 500k fuzz confirms
the hub is never over-credited relative to its share of what was actually recognized.

**The one real defect was a sentence, and it is fixed.** The field comment said the figure is
"**Exact at all times** — there is no provisional or unsettled state between a trade and a claim."
True about *settlement timing*, which is what it was arguing, and false about *amount*; a hub
operator would reasonably have taken it for both. Both sites
([multicoin_vault.move:83-94](packages/triex/sources/vault/multicoin_vault.move#L83-L94) and the
`operator_owed` getter on `multicoin_pool`) now say *settled* at all times, and state the per-event
floor and where the remainder goes. No code change.

Note also that F-3 has no bearing here even if the rounding there were changed: what the hub is
credited off is the actual decrement of **bid-maker escrow**, which keeps the plain floor by
necessity.

---

## F-4 — `locked_maker_fees` residue is monotonic and never reconciled (Low) — **not a defect**

Both vaults document this ([vault.move:33-46](packages/triex/sources/vault/vault.move#L33-L46),
[multicoin_vault.move:65-80](packages/triex/sources/vault/multicoin_vault.move#L65-L80)) and
`pool_fee_tests::test_dust_accumulation_stays_bounded` pins it. This pass re-ran the fuzz and
extended it to cover the hub credit, which the first pass did not model.

**500,000 cases**, over both price scalings, nine rates (including the 100% cap), six retention
rates, five operator-share rates, and randomised sequences of partial fills, modify-downs, cancels
and expiries:

```
releases exceeding the lock  : 0
unlock exceeding the reserve : 0
hub credit exceeding its cap : 0
worst stranded locked residue: 6      (over <= 8 release events)
worst hub under-credit       : 6
worst principal drift        : 6
```

- **Zero over-releases.** `Σ(recognized + refunded + retained)` never exceeded the escrow locked at
  placement. The lock floors once over the whole order; every release floors over a piece of it,
  and floor is subadditive — the arithmetic can only strand value, never create it.
- **Zero unlocks exceeding the reserve**, which is what keeps a refund from eating the treasury's
  unencumbered revenue.
- **The hub is never over-credited** relative to its share of what was actually recognized —
  `recognize_locked_maker_fees` credits off `amount.min(self.locked_maker_fees)`, the *real*
  decrement, so F-4's drift under-credits the operator rather than over-crediting. This is a
  genuinely subtle correctness point and the code gets it right.
- **Every drift is ≤ one raw unit per event**, exactly as documented.

What the comments still understate is that the bound is over the **pool's lifetime**, not per
order, and nothing resets it. A market maker who partially fills and re-quotes thousands of times a
day contributes one raw unit per release, permanently. The stranded quote sits in
`quote_fee_reserve` classified as escrow forever: not sweepable, not claimable, not refundable. It
blocks nothing — `withdrawable_quote_fees` stays correct minus the drift — but it is an unbounded,
growing, unattributable balance.

The same subadditivity strands *principal* in `quote_balance` on coin pools (~1 raw unit per
partial fill). Multicoin pools are exact there: `price_scaling = 1` makes the conversion a plain
multiply, which is additive.

**Verdict: not a defect.** It is rule 3 working. The counter is a *liability* line, and it
overstates the liability — the vault believes it owes escrow it does not owe, so it sweeps less
than it could. The money is in the vault either way; only its classification drifts. The opposite
error would be the serious one, and the code is careful to avoid it: `recognize_locked_maker_fees`
credits off `amount.min(self.locked_maker_fees)`, the *actual* decrement, so the drift
under-credits the hub rather than minting a claim on revenue never recognized.

One asymmetry worth noting — **now fixed**: the coin vault computed `reserve − locked` as a plain
subtraction while the multicoin vault saturated at zero. Both were safe — `reserve ≥ locked` is
maintained at every writer, and the fuzz found no counterexample — but the belt the multicoin side
wears was absent on the coin side, and `withdrawable_quote_fees` is a public view as well as the
cap on the admin sweep, so reverting would have been disproportionate to the cause.
[vault.move:207-227](packages/triex/sources/vault/vault.move#L207-L227) now saturates and carries
the same reasoning, pinned by `vault_tests::test_withdrawable_saturates_when_escrow_exceeds_the_reserve`.
A genuine shortfall still fails loudly where it must: the `EInsufficientFeeReserve` assert in
`unlock_quote_fees`, the path that would otherwise pay a maker out of coins the reserve does not
hold.

**Fix**, if wanted: none required for safety. The cheapest option is an admin-gated reconciliation
that recomputes total live escrow from the book and resets `locked_maker_fees` to it — bounded
work, no per-order tracking.

---

## F-5 — Effective cancel-retention on dust escrow reaches 100% (Low, intended)

`quote_fee::split_released_fee` floors the refund so the dust lands in the retained half
([quote_fee.move:35-42](packages/triex/sources/state/quote_fee.move#L35-L42)). Deliberate and
tested (`test_refund_rounding_dust_favors_the_retention`) — it is what lets the caller decrement
`locked_maker_fees` by the full released amount.

Worth restating because it is a *rate* distortion rather than an amount one: at the genesis 20%
retention, a 1-unit escrow refunds 0 and retains 1, i.e. **100% retention**; a 4-unit escrow
retains 25%. Combined with F-3's absence of a minimum order size, a maker cancelling a dust bid
forfeits their entire escrow. Amounts are trivial; the asymmetry is unbounded in percentage terms.

---

## F-6 — `state.accounts` grows without bound from account-less swaps (Low, not a fee bug)

`swap_exact_quantity` mints a fresh `TradingAccount` per call
([pool.move:388](packages/triex/sources/pool.move#L388)). `place_order_int` →
`state::take_pending_turnover` → `update_account` inserts an `Account` keyed by that one-shot ID
([state.move:677-680](packages/triex/sources/state/state.move#L677-L680)), and **nothing anywhere
removes an entry from that table** — re-confirmed this pass by grep: the only other references are
`contains` reads.

The `TradingAccount` object is deleted at the end of the transaction and its turnover ring detached
(`remove_fee_turnover`), but the pool-side `Account` is permanent. Storage is paid once by the
swapper, so there is no unbounded-cost griefing, but the table is a permanent one-way accumulator
on the hottest shared object in the system.

**Fix.** Drop the entry when the account has no open orders and no settled/owed/pending balances at
the end of `place_order_int`, or skip `update_account` entirely for the account-less path.

---

## N-2 — Assignment re-prices a hub immediately, defeating the staging guarantee (Info) — **new**

`stage_operator_share_class` is careful and correct: a new rate always lands at `ctx.epoch() + 1`,
a pending `next` that has come due is promoted before being overwritten, and restaging within the
same epoch replaces the future rather than the present
([fee_policy.move:556-588](packages/triex/sources/fee_policy.move#L556-L588)). Its doc comment
states the reason plainly:

> A hub rate must be pre-announced: it is what an operator underwrites a hosting decision with.

`assign_operator_share_class` is effective immediately, and the comment argues that is safe because
"an assignment can only affect revenue that has not happened yet." That is true about
*retroactivity* — with the split applied at recognition, there is no unsettled basis to re-price.
It does not preserve *pre-announcement*, because both classes' rates are already live:

```
[ PASS ] n2_assignment_bypasses_the_staging_guarantee
   epoch 1: collection is in a 5000bps class, earning 50%
   one assign_operator_share_class -> 0bps, same epoch, same transaction
   one more                        -> 5000bps, same epoch
```

So the property `stage_operator_share_class` exists to guarantee is available in one direction
(re-pricing the class a hub sits in) and not the other (moving the hub to a different class). An
admin can cut a hub's rate to zero with no notice. Everything here is admin-capped, so this is a
governance-surface observation, not a vulnerability — but it is a real gap between the stated
design intent and the implementation, and a hub operator's contract would be written against the
stated intent.

**Fix**, if the guarantee is meant to be uniform: stage the assignment too — record
`(current_class, next_class, effective_epoch)` and resolve it the same way
`operator_share_bps_at` already resolves the rate.

---

## N-4 — The `master_*` integration suites asserted nothing about balances (Info) — **fixed**

`integration_test_utils::check_balance` compared expected against actual for SUI, USDC and SPAM
and then `std::debug::print`ed the mismatches instead of asserting. Every `ExpectedBalances`
threaded through the `master_*` suites was dead weight — and those suites are exactly where a fee
discrepancy would surface, which is why F-2 survived in a green 627-test run.

### What was actually blocking the assertions

The in-tree WARNING said the expectations needed rebuilding from the current fee schedule. That
was true but not the whole story. Three separate things were wrong, and the first one made the
other two unfixable:

1. **Four test helpers minted into the account under test.** `cancel_order`, `cancel_orders` and
   `place_market_order` each minted **1e18** of the quote asset straight into the trading account
   before acting (`cancel_all_orders`, 1e16), captioned "top up quote balance to cover
   quote-denominated fees". So a single cancel moved the account's quote balance by a thousand
   times the starting balance, and no bookkeeping could ever track it. The premise was also wrong:
   a cancel *refunds* quote and charges none. **All four are removed** — the full suite passes
   without them, so they were never load-bearing.
2. **The expectations priced fees with `constants::maybe_apply_fee`** — a flat 2% on bids, 0% on
   asks — which is not what any pool charges. The harness seeds its classes at 1.10% taker /
   0.90% maker with 20% cancel retention.
3. **Cancel retention was not tracked at all**, and neither was the ask-taker fee: several
   checkpoints credited a seller the gross proceeds with no deduction.

### What the fix is

`check_balance` now asserts all three assets (it keeps the actual/expected prints, which is what
made rebuilding the numbers tractable). Every `master_*` expectation is rebuilt on helpers that
state the real model — `maker_principal`, `maker_escrow`, `refunded_on_cancel`,
`retained_on_cancel`, `taker_fee_on`, `maker_fee_on`.

The pay-with-CRED branches in `master_trader_permission_tests` went with it: every pool charges
quote fees now, so the fork was tracking a leg that has been zero since the unified model landed.

**The oracle is independent of the code under test.** First attempt had those helpers delegating
to `quote_fee::fee_from_scaled_rate` and `quote_fee::split_released_fee` — which made the
assertions tautological: a mutant that refunded the whole escrow on cancel moved the "expected"
figure by exactly the same amount and every master test still passed. They now restate the
arithmetic, with the rates read from the schedule the harness seeds.

**Verified by mutation**, since a green suite proves nothing by itself here:

| Mutant | Caught by |
|---|---|
| `split_released_fee` retains nothing | 8 master tests (0 before the oracle was made independent) |
| taker fee never charged at settlement | 6 master tests |
| bid-maker escrow halved at placement | 6 master tests |

Baseline: **629/629**.

**Note for whoever reads the numbers.** The suites now pin real amounts, so the arithmetic in them
is worth trusting — but they exercise the harness-seeded single-rung classes, not
`bootstrap_quote`'s genesis ladder. Mutating the genesis rates is caught by
`fee_policy_bootstrap_tests`, not here; the two sets of tests cover different things and neither
substitutes for the other.

---

## F-7 — `bootstrap_quote(quote_unit)` is unchecked (Informational)

[fee_policy.move:218-251](packages/triex/sources/fee_policy.move#L218-L251) takes `quote_unit` as a
caller-supplied `u128` and only asserts it is non-zero. It is never cross-checked against
`CoinMetadata<QuoteAsset>.decimals`. Passing `1_000_000_000` for a 6-decimal quote raises every
threshold above tier 0 by 1000×, and the only symptom is that no trader ever earns a tier — no
event, no view, no assertion surfaces it. The doc comment flags the risk; nothing in the code
catches it.

Given `create_class` refuses to overwrite an existing class id, recovery means `update_class` with
the corrected ladder — staged to the next epoch, so a bootstrap mistake is observable only by
absence and correctable only with a one-epoch delay.

---

## What was checked and found correct

Half of an audit is the negative space. These were traced (re-traced, where the first pass had
already covered them) and hold on the current tree:

- **Rate snapshotting is consistent end to end.** The maker rate and retention rate resolved at
  placement (`resolve_with_retention`) flow into `OrderInfo` → `Order` → `Fill`, and *the same
  value* prices the escrow locked (`calculate_partial_fill_balances`), the escrow recognized at
  fill (`fill::maker_fee_escrowed`), and the escrow released on cancel/modify/expiry
  (`order::locked_fee_released`). An admin re-pricing a class can never re-price a resting order,
  in either direction.
- **`reserve ≥ locked_maker_fees + operator_owed`** holds at every writer, re-derived per writer:
  a bid fee deposit raises the reserve by `taker + maker` and the encumbrance by
  `maker + floor(taker·bps)`; a proceeds fee raises both by `amount` and `floor(amount·bps)`;
  recognition trades `actual` of locked for `floor(actual·bps)` of owed, a strict decrease; a
  refund lowers reserve and locked by the same amount. Both payout asserts
  (`claim_operator_share`, `unlock_quote_fees`) are therefore unreachable rather than load-bearing,
  and the fuzz found no counterexample in 500k cases.
- **Expired orders cannot double-release.** `account::process_maker_fill` removes the order from
  `open_orders` on `expired() || completed()`
  ([account.move:176-178](packages/triex/sources/state/account.move#L176-L178)) and
  `match_against_book` removes it from the book, so an expiry-refunded order cannot then be
  cancelled for a second refund.
- **Tier resolution agrees between quote and settlement**, including the window-eviction predicate.
  `account_turnover_int` reads `total_at(epoch) + pending_turnover_total(epoch)`, which keeps an
  entry iff `entry_epoch + window > epoch`; the trade path does `roll(epoch)` then
  `record_at(entry_epoch, ..)`, which drops iff `anchor - entry_epoch >= window` — the same
  predicate, written the other way round. So a dry run priced for an account matches what
  settlement charges it, including for a dormant account whose ring has aged out but not rolled.
- **An order never discounts itself.** Taker fees are credited to the ring *after* pricing
  (`record_fee_turnover` at the end of `place_order_int`); maker fees are queued as pending at fill
  and folded on the maker's *next* order. Resting escrow buys no tier progress.
- **The tier ladder cannot invert.** `fee_schedule::validate` asserts strictly ascending thresholds
  and *non-increasing* taker and maker rates on every rung, so more turnover can never cost more.
  Rates are also bound to `FEE_MULTIPLE` and to the min/max caps at write time.
- **No underflow at the rate caps.** `MAX_TAKER_FEE = MAX_MAKER_FEE = 1e9` (100%) and
  `fee_from_scaled_rate` clamps at the same value, so `cumulative_quote - total_taker_fee` and
  `quote_quantity - maker_fee_charged` bottom out at exactly zero.
- **The bid dry run cannot underflow its own input.** `quantity_to_match ≤ input · 1e9/(1e9+rate)`,
  and the loop subtracts at most `matched_quote · (1e9+rate)/1e9 ≤ quantity_to_match·(1e9+rate)/1e9
  ≤ input`. Since `rate > 0` forces `quantity_to_match < L`, there is at least one raw unit of
  slack per level. The cross-check that matters more is against the *real* fill rather than within
  the dry run, and it is measured — see F-2's fragmented-book test.
- **Quote conservation across every fee branch.** Bid-taker fees ride in with the owed quote and
  are split into the reserve; ask-taker and ask-maker fees are carved out of proceeds already in
  `quote_balance`; bid-maker escrow is deposited at placement and either recognized in place or
  moved back to `quote_balance` before settlement pays the refund out. Every branch nets to zero.
- **Expiry is not a cheaper exit than cancel.** `fill::expiry_fee_split` applies the order's
  snapshotted retention, and `state::process_fills` folds the retained share into `recognized`, so
  a near-term `expire_timestamp` cannot dodge the retention.
- **`modify_order` cannot release more than it locked.** `cancel_quantity` is computed before the
  mutation and passed explicitly to both `released_fee_split` and `calculate_cancel_refund`, so
  repeated modify-downs followed by a cancel sum to at most the original escrow (fuzzed).
- **The hub-share batching is correct.** `cancel_all_orders` and `cancel_orders` resolve
  `operator_share_bps_at` once and thread it to every cancel; the single-cancel and modify paths
  resolve lazily and only when escrow was actually retained, so an ask cancel never walks the
  policy. `operator_share_bps_at` is total by construction — every missing piece of configuration
  resolves to zero — which is what keeps a cancel from ever aborting on policy state.
- **The hub share is structurally multicoin-only.** `pool.move` has no `operator_owed`, no
  beneficiary and a one-argument `recognize_locked_maker_fees`. That is not an omission: coin pools
  carry no `collection_id`, so there is nothing to attribute a share to.
- **Per-epoch fee accumulators cannot overflow.** `history.total_fees_collected` resets on every
  epoch rollover, so the `u64` quote leg would need ~1.8e13 quote units of fees in a single epoch.

---

## Reproducing

F-1's regression tests are in the repo (`math.move`, `tests/pool/`). This pass's probes — which
assert the *bugs* — are kept out of the tree, in the session scratchpad at
`/private/tmp/claude-501/-Users-michaelhahn-books-temp-trinary-exchange/f743a868-a974-4f4d-ad27-1850e62c37d1/scratchpad/`:

- `audit2_probe.move` — 11 book- and order-level probes: F-1 (both extremes), F-2 (three rungs +
  the exact ask direction), F-3 (single and per-fill), N-1 (coin and multicoin). Its F-2
  assertions pin the **pre-fix** numbers; read the measurements off the debug output instead.
- `audit3_probe.move` — the re-analysis probes: the effective-rate table that killed the proposed
  F-3 remedy, and the fragmented-book invariant behind F-2's safety argument (the latter now
  shipped in `book_tests`).
- `audit2_e2e.move` — 2 end-to-end probes proving N-1 is reachable through `pool::locked_balance`.
- `audit2_vault.move` — 3 probes on the hub-share rounding (N-3) and the saturating withdrawable.
- `audit2_policy.move` — 1 probe on staging vs. assignment (N-2).
- `sim2.py` — the 500k-case escrow + hub-share conservation fuzz.

Drop the `.move` files into `packages/triex/tests/` and run `sui move test audit2_`; they pass
against the current tree. The first pass's probes, several of which assert the F-1 behaviour
*before* the fix and therefore only pass against `7471b3d`, are still at
`.../3b9818d8-5fc6-467e-9122-b76f1a647368/scratchpad/`.
