# Review — PR #13: Coin pools on BigVector, encoded u128 order ids, kill switch + zero-quote fix

**PR:** [loash-industries/trinary-exchange#13](https://github.com/loash-industries/trinary-exchange/pull/13)
**Branch:** `triex-bigvector-coin-pools` → `cycle-7`
**Diff reviewed:** `origin/cycle-7...origin/triex-bigvector-coin-pools` — 53 files, +8,679 / −2,049
**Date:** 2026-09-15
**Focus:** newly-introduced security issues, accounting flaws, and overflow / underflow / precision breaks

---

## Resolution status — updated 2026-09-15

Assessed for validity after the fact; every finding reproduced. Two severities were
corrected on assessment and are shown below. Current state:

| # | Finding | Severity (filed → assessed) | Status |
| --- | --- | --- | --- |
| 1 | Dust residue wedges an entire book side | Critical → **Critical** | **Fixed** — `MatchOutcome`, retire-on-sight, `modify` bound |
| 2 | Multicoin pools do need migration | High → **Medium** | **Closed, won't fix** — full protocol re-deploy, so no in-place upgrade |
| 3 | `get_quantity_out` under-quotes on the same dust | Medium → **Low** | **Fixed** — both arms step over, required by the §1 fix |
| 4 | Depth views advertise liquidity the matcher refuses | Low → **Low** | **Fixed by removal** — both views deleted from the coin path |
| 5 | `iter_orders` documented behaviour ≠ actual | Low → **Low** | **Fixed** — doc corrected to match positional seeking, real test added |

Severity notes from the assessment:

- **#1 was if anything understated.** The wedge spans *all* worse price levels, not just the
  blocker's own, affects both sides, and blocks limit and market takers alike.
- **#2 was overstated at High.** The alarming half — old bytes deserialized against a new
  layout — is unreachable, as the finding itself concedes: the upgrade verifier rejects
  field removal first, so it fails closed. The project is testnet-only and the re-deploy
  moots it entirely. The finding's supporting diff numbers were also misread: the four test
  files are cited as `(+111)`, `(+100)`, `(+99)`, `(+46)` but are actually `+1/−110`,
  `+26/−74`, `+8/−91`, `+2/−44` — overwhelmingly deletions, 37 insertions against 319.
- **#3 was overstated at Medium.** It is not independent: the inline comments show it was a
  deliberate mirror of the matcher, there was no exploitable dry-run/settlement divergence,
  and it disappears when #1 is fixed properly.
- **#5's evidence was understated.** The PR's own regression test passes for the wrong
  reason — anchor `999` sits below the entire bid keyspace, so it pins "out of range", not
  "stale". A genuinely stale mid-book anchor returns 5 orders, not an empty page.

Implementation is recorded in
[`docs/plans/coin-pool-bigvector-side-by-side.md`](../plans/coin-pool-bigvector-side-by-side.md)
§9 deviation 5 and §10.3.

---

## Summary

One critical, newly-introduced availability defect: the zero-quote fill guard added in the
second commit halts the matching loop instead of skipping the offending maker, so a single
sub-lot residue at the best price makes every order behind it unreachable. It is reachable
accidentally through an ordinary partial fill, and deliberately through `modify_order` for
the cost of one order plus one modify.

Separately, the PR's claim that multicoin pools need no migration does not hold — three
structs reachable from a live multicoin pool's `Versioned` value change shape while
`CURRENT_VERSION` stays at `4`, with no migration function in the tree.

The escrow and fee arithmetic on the coin side is conservative and holds; the vendored
`big_vector.move` is genuinely verbatim; the order-id codec has no overflow at its bounds;
and the kill-switch fix is correct and recoverable. Full suite passes 755/755 on the branch
as-is.

| # | Severity | Finding | Location |
| --- | --- | --- | --- |
| 1 | **Critical** | Dust residue wedges an entire book side | `coin_order_info.move` + `coin_book.move` |
| 2 | **High** | Multicoin pools do need migration | `multicoin_pool.move`, `account.move`, `history.move` |
| 3 | Medium | `get_quantity_out` under-quotes on the same dust | `coin_book.move` |
| 4 | Low | Depth views advertise liquidity the matcher refuses | `coin_book.move` |
| 5 | Low | `iter_orders` documented behaviour ≠ actual behaviour | `coin_order_query.move` |

---

## 1. Critical — the zero-quote guard wedges an entire book side

**Newly introduced by commit `05bb039` ("restore the kill switch and reject zero-quote fills").**

`coin_order_info::match_maker` declines a dust fill by returning `false`:

```move
if (!expired) {
    let matchable = self.remaining_quantity().min(maker.quantity() - maker.filled_quantity());
    if (math::qty_to_quote(matchable, maker.price(), self.price_scaling) == 0) {
        return false
    };
};
```

`coin_book::match_against_book` reads `false` as *stop matching*, not *skip this maker*:

```move
while (!ref.is_null() && current_fills < max_fills) {
    let maker_order = slice_borrow_mut(book_side.borrow_slice_mut(ref), offset);
    if (!order_info.match_maker(maker_order, timestamp)) break;   // <-- terminal
    ...
}
```

Before this commit, `false` meant only "price no longer crosses" or "nothing left to fill" —
both correct terminal conditions. The new guard overloads the same return value with "this
one maker is unfillable". Because dust sorts by price like any other order, a residue at the
best price makes everything behind it unreachable.

### 1a. Reachable accidentally

`coin_order_info::validate_inputs` checks `original_quantity` against
`math::min_qty_for_nonzero_quote`. Nothing re-checks the *remaining* quantity after a partial
fill, so any fill that leaves a sub-lot residue creates a blocker.

Repro (passes on the branch):

```move
#[test]
fun repro_dust_residue_blocks_the_whole_ask_side() {
    let scaling = constants::float_scaling();
    let lot = math::min_qty_for_nonzero_quote(CHEAP_PRICE, scaling);   // CHEAP_PRICE = 1_000_000
    assert!(lot == 1_000, 0);

    // 1. Alice rests an ask of 1_999 base at CHEAP_PRICE. 1_999 >= lot, so it
    //    passes the new placement floor.
    pool_test_utils::place_limit_order<SUI, USDC>(
        ALICE, pool_id, maker,
        constants::no_restriction(), constants::self_matching_allowed(),
        CHEAP_PRICE, 1_999, false, constants::max_u64(), &mut test,
    );

    // 2. Bob takes exactly `lot`. The maker is left resting 999 base — below the
    //    floor, which nothing re-checks after a partial fill.
    let bob = pool_test_utils::place_limit_order<SUI, USDC>(
        BOB, pool_id, taker1,
        constants::immediate_or_cancel(), constants::self_matching_allowed(),
        CHEAP_PRICE, lot, true, constants::max_u64(), &mut test,
    );
    assert!(bob.executed_quantity() == lot, 1);

    // 3. Alice rests a second, perfectly healthy ask behind it at the same price.
    pool_test_utils::place_limit_order<SUI, USDC>(
        ALICE, pool_id, maker,
        constants::no_restriction(), constants::self_matching_allowed(),
        CHEAP_PRICE, 5_000, false, constants::max_u64(), &mut test,
    );

    // 4. Carol crosses for 5_000. The 999-unit dust sorts first; `match_maker`
    //    refuses it and returns false, which `match_against_book` reads as
    //    "stop matching". Carol fills nothing.
    let carol = pool_test_utils::place_limit_order<SUI, USDC>(
        CAROL, pool_id, taker2,
        constants::immediate_or_cancel(), constants::self_matching_allowed(),
        CHEAP_PRICE, 5_000, true, constants::max_u64(), &mut test,
    );
    assert!(carol.executed_quantity() == 0, 2);   // <-- book is wedged
}
```

### 1b. Reachable deliberately, and cheaply

`coin_order::modify` asserts only `filled_quantity < new_quantity < quantity`, with no
min-size re-check:

```move
public(package) fun modify(self: &mut Order, new_quantity: u64, timestamp: u64) {
    assert!(
        new_quantity > self.filled_quantity &&
    new_quantity < self.quantity,
        EInvalidNewQuantity,
    );
    assert!(timestamp <= self.expire_timestamp, EOrderExpired);
    self.quantity = new_quantity;
}
```

So an attacker does not need to wait for a partial fill. Repro (passes on the branch):

```move
#[test]
fun repro_modify_down_to_dust_wedges_the_book() {
    // Attacker rests a legal 2_000 ask at CHEAP_PRICE...
    let atk = pool_test_utils::place_limit_order<SUI, USDC>(
        ALICE, pool_id, attacker,
        constants::no_restriction(), constants::self_matching_allowed(),
        CHEAP_PRICE, 2_000, false, constants::max_u64(), &mut test,
    );
    // ...with honest liquidity behind it.
    pool_test_utils::place_limit_order<SUI, USDC>(
        ALICE, pool_id, attacker,
        constants::no_restriction(), constants::self_matching_allowed(),
        CHEAP_PRICE, 50_000, false, constants::max_u64(), &mut test,
    );

    // One modify turns it into an unfillable blocker.
    pool_test_utils::modify_order<SUI, USDC>(
        ALICE, pool_id, attacker, atk.order_id(), 1, &mut test,
    );
    assert!(math::qty_to_quote(1, CHEAP_PRICE, scaling) == 0, 0);

    let carol = pool_test_utils::place_limit_order<SUI, USDC>(
        CAROL, pool_id, victim,
        constants::immediate_or_cancel(), constants::self_matching_allowed(),
        CHEAP_PRICE, 50_000, true, constants::max_u64(), &mut test,
    );
    assert!(carol.executed_quantity() == 0, 1);
}
```

Cost: one order plus one modify, repeatable. With `expire_timestamp = max_u64` the dust never
ages out (the expiry branch of `match_maker` is exempt from the guard, so an expiring blocker
would clear itself — a permanent one will not). Only the attacker can cancel it; there is no
permissionless cleanup path, and the PR itself notes `cancel_live_order(s)` is absent.

### Blast radius

The bound bites whenever raw price < `FLOAT_SCALING`, i.e. whenever the quote has fewer
decimals than the base. With `price = human × QUOTE_UNIT × FLOAT_SCALING / BASE_UNIT`, a
SUI/USDC pool at a human price of 3.5 has raw price `3.5e6` and a floor of 286 base units
(≈ 2.86e-7 SUI). This is the ordinary configuration, not an exotic one — the PR's own fixture
uses `CHEAP_PRICE: u64 = 1_000_000` and describes it as "entirely ordinary for a cheap base".

### Fix direction

- Separate "cannot match at all" from "skip this maker" so `match_against_book` advances past
  dust rather than breaking. A third state (or an out-param) on `match_maker` is the minimal
  change; `continue`-style advancement in the caller is the alternative.
- Re-apply `math::min_qty_for_nonzero_quote` in `coin_order::modify`, so a modify-down cannot
  land below the floor.
- Apply the same skip-don't-break treatment to the two `break`s in `get_quantity_out` (§3).

---

## 2. High — multicoin pools do need migration

The PR body states: *"Multicoin pools need no migration."* Three structs reachable from a live
multicoin pool's `Versioned` inner value change shape in this diff:

| Struct | File | Change |
| --- | --- | --- |
| `MultiCoinPoolInner` | `sources/multicoin_pool.move` | drops `quote_type: TypeName` |
| `Account` | `sources/state/account.move` | drops `epoch`, `active_stake`, `inactive_stake`, `created_proposal`, `voted_proposal` |
| `History` | `sources/state/history.move` | restructured entirely — `Volumes`, the `historic_volumes` Table and `balance_to_burn` all removed |

`Account` and `History` are nested inside `State`, which is a field of `MultiCoinPoolInner`.
`MultiCoinPoolInner` is read back through `versioned::load_value`:

```move
public(package) fun load_inner<QuoteAsset>(
    self: &MultiCoinPool<QuoteAsset>,
): &MultiCoinPoolInner<QuoteAsset> {
    let inner: &MultiCoinPoolInner<QuoteAsset> = self.inner.load_value();
    ...
}
```

`constants::CURRENT_VERSION` is unchanged at `4` on both sides of the diff, and there is no
`migrate` function anywhere under `sources/`. So an existing pool's bytes — written under
version 4 with the old layout — would be deserialized against the new layout.

Ahead of that, removing fields from public structs is not a compatible package upgrade; the
upgrade verifier rejects it before any pool is touched.

**Either** the multicoin side needs a version bump plus a migration path, **or** the PR
description needs to say that multicoin pools redeploy too. This is a deployment blocker
either way.

### Related description inaccuracy

"every multicoin test passes unmodified / byte-identical" does not hold —
`tests/book/book_tests.move` (+111), `tests/state/state_tests.move` (+100),
`tests/state/account_tests.move` (+99) and `tests/integration/test_utils.move` (+46) all
changed, following the struct edits above.

---

## 3. Medium — `get_quantity_out` under-quotes on the same dust

Both arms of `coin_book::get_quantity_out` carry the same defect:

```move
// bid arm
if (matched_base_quantity > 0 && matched_quote_quantity == 0) break;
// ask arm
if (matched_base_quantity > 0 && matched_quote_quantity == 0) break;
```

The quoting view stops at the first dust order and reports whatever it had accumulated, so an
aggregator sees zero (or truncated) liquidity behind the blocker.

This is at least *consistent* with the matcher — the dry run and the settlement path agree, so
there is no dry-run/settlement divergence to exploit. But both are wrong in the same way, and
both should be fixed together.

---

## 4. Low — depth views advertise liquidity the matcher refuses

`get_level2_range_and_ticks` accumulates `order.quantity() - order.filled_quantity()` for every
non-expired order, and `mid_price` takes the first non-expired order on each side. Neither
applies the zero-quote bound, so:

- level2 reports depth at a price level that includes unfillable dust, and
- a dust order at the top of book sets the reported mid.

Secondary to §1 — if dust stops being a blocker it is still not tradeable — but worth closing
in the same change.

---

## 5. Low — `iter_orders` documented behaviour ≠ actual behaviour

`coin_order_query::iter_orders` documents, and the PR body asserts:

> an anchor that names no live order yields an empty page rather than silently restarting from
> the top of the book — a stale id is a caller error, not a request for page one.

`big_vector::slice_before` / `slice_following` position relative to a key without requiring the
key to exist — both route through `find_leaf(key)` and return the neighbouring position. A
stale anchor therefore serves the page *around* the missing key, not an empty page.

An off-chain paginator written against the documented contract would silently re-serve orders
rather than surfacing the stale cursor. Fix the doc, or make the behaviour match it.

---

## Verified sound

These were checked and hold, so the findings above are the residue rather than the whole story.

**`big_vector.move` is genuinely verbatim.** Diffed against
`deepbookv3/packages/deepbook/sources/helper/big_vector.move` with `deepbook::` → `triex::`
normalised: 9 changed lines, all of them the added vendoring header comment. No local edits to
the tree logic.

**Order-id codec has no overflow at its bounds.**
`encode_order_id(false, MAX_PRICE, u64::MAX)` lands exactly on `2^128 - 1`;
`decode_order_id`'s `(encoded >> 64) as u64` cannot exceed `u64::MAX` for either side. The side
bit partitions the keyspace so one codec keys two independent trees without collision, and the
opposed sequence counters (bids descending from `2^64-1`, asks ascending from `1`) give
price-time priority under plain key order on both sides. Market-order sentinels
(`max_price()` for bids, `min_price()` for asks) are both inside the encodable range, and
market orders correctly skip the placement floor — they price at each maker's level, not at
the sentinel they carry.

**Escrow conservation on the coin side holds.** Every payout against a bid maker's locked quote
is a sum of floors over a common divisor, so for any split of the original quantity `Q` into
fills `qᵢ`, modify-down deltas and a final remainder `R`:

```
Σᵢ floor(qᵢ·p/S) + floor(R·p/S)  ≤  floor(Q·p/S)
```

A bid maker can never be refunded more principal, or more fee escrow, than they locked, under
any interleaving of fills, repeated modify-downs and a final cancel. The same subadditivity
covers `quote_fee::fee_from_scaled_rate` applied per-release. The rounding residue accrues to
the pool's quote balance rather than being overpaid — the safe direction — and
`coin_vault` documents the matching one-unit-per-release drift in `locked_maker_fees`. This
residue is pre-existing on the coin side (multicoin's `price_scaling == 1` multiplies rather
than divides, so it has none), not introduced here.

**`quote_to_qty_capped` puts the clamp ahead of the downcast.** The dividend is at most
`(2^64-1) × 1e9 < 2^128`, so no `u64` input overflows the intermediate, and the clamp
guarantees the result fits. A level resting near `MIN_PRICE` no longer aborts on a quantity
whose answer was only ever going to be the cap.

**`min_qty_for_nonzero_quote` is correct and tight.** `div_round_up(1, price)` is
`ceil(FLOAT_SCALING / price)`; the `price == 0` guard prevents the division by zero on a path
that `MIN_PRICE = 1` already makes unreachable for a resting order; and the multicoin branch
correctly returns `1`, since a bare product cannot floor to zero.

**Kill switch fix is correct and recoverable.** `disable_version` can now halt the running
version (the `ECannotDisableCurrentVersion` assert is gone, and the code is left unrecycled so
archived decoders do not resolve it to a new meaning). `registry::allowed_versions()` reads
`self.inner.load_value()` directly rather than through the version-gated `load_inner()`, which
is what lets the disable actually propagate to pools that cache it. `enable_version` reaches
`load_value_mut` the same way, so the halt is reversible — not a one-way door.

**Ownership asserts after book mutation are safe.** `pool::cancel_order` and
`pool::modify_order` mutate the book before asserting `order.trading_account_id() ==
trading_account.id()`, but a Move abort reverts the whole transaction, so there is no
half-applied state. (The PR already notes `validate_proof` running late as a known fragility
it does not fix.)

**Test suite:** `sui move test` → **755 passed, 0 failed** on the branch as-is.

---

## Repro artifacts

Both repro tests in §1 were written into `packages/triex/tests/coin_book/` as
`zz_dust_block_repro_tests.move` and `zz_dust_block_repro2_tests.move`, run, and removed —
the working tree is clean. The code is inlined above; drop either file back in to reproduce.
