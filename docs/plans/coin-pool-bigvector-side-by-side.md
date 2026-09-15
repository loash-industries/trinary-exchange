# Plan: Coin pools on BigVector + encoded order IDs, side-by-side with multicoin pools

**Status:** Implemented · 2026-09-13 — landed as a single change; see
[§9 Implementation notes](#9-implementation-notes-as-built) for deviations from this plan and
the measured gas results.
**Supersedes:** [bigvector-order-storage.md](bigvector-order-storage.md) (full-conversion
approach — replaced by this side-by-side design).

## Goal

Coin pools (`Pool<Base, Quote>`, pool.move) move to **BigVector order storage with
DeepBook-style encoded `u128` order IDs**. Multicoin pools (`MultiCoinPool<Quote>`,
multicoin_pool.move) **stay exactly as they are**: `vector<Order>` storage, opaque serial
`u64` order IDs. Both trading types live in the same package permanently.

**Delineation rule (decided):** wherever the two trading types would conflict in a shared
module, fork fully — the coin implementation gets a `coin_`-prefixed parallel file/module;
the existing un-prefixed module becomes multicoin-only and is left untouched. No shared
module is widened or branched to serve both.

**Reference:** deepbookv3 is checked out in the workspace at
`../deepbookv3/packages/deepbook/` (relative to `trinary-exchange/`). Port from those
files as ground truth — the `#feat:bv` comment blocks in book.move are only a map of
where things go (at least one has a syntax typo, and none know about the triex quote-fee
model).

---

## 1. Conflict inventory

Which modules the two pool types share today, and what happens to each:

| Module | Coupling | Verdict |
| --- | --- | --- |
| `book/book.move` | Book storage + order-ID allocation, used by both pools | **Fork** → `coin_book` |
| `book/order.move` | `Order.order_id: u64`, `OrderCanceled`/`OrderModified` events | **Fork** → `coin_order` |
| `book/order_info.move` | `OrderInfo`/matching, order-ID fields, placement events | **Fork** → `coin_order_info` |
| `book/fill.move` | `maker_order_id`/`taker_order_id: u64` | **Fork** → `coin_fill` |
| `state/account.move` | `open_orders: VecSet<u64>` | **Fork** → `coin_account` |
| `state/state.move` | Threads `Order`/`OrderInfo`/`Fill`/`Account` through fills | **Fork** → `coin_state` |
| `vault/vault.move` | Coin `Vault` struct **plus** `QuoteFeeDeposit` + fee-event emitters reused by `multicoin_vault` (`vault.move:339,371,847` call sites); `PoolFeesRefunded.order_id: u64` | **Fork** → `coin_vault`; `vault.move` stays as the multicoin fee-event helper (see §3.4) |
| `pool.move` | Coin-only already; name doesn't collide with `multicoin_pool.move` | **Convert in place** (no rename needed by the rule; `coin_pool.move` optional) |
| `order_query.move` | Coin-only already (imports only `triex::pool`; multicoin has its own inline queries) | **Convert in place + rename** → `coin_order_query.move` |
| `state/balances.move`, `state/quote_fee.move`, `helper/math.move`, `state/history.move`, `state/fee_turnover.move`, `state/ewma.move`, `state/fee_schedule.move`, `fee_policy.move`, `trading_account.move`, `registry.move`, `vault/multicoin_vault.move` | No order-ID or book-storage coupling (verified by grep) | **Shared, untouched** |
| `helper/constants.move`, `helper/utils.move` | Additive only | **Shared, extended** (§3.5) |

Net effect: `multicoin_pool.move` and everything it imports are not edited at all. Zero
behavior, API, or event-schema change for multicoin clients — the multicoin test suites
passing unmodified is the proof of isolation.

---

## 2. The two stacks after the split

```
                     multicoin (unchanged)              coin (new design)
entry module         multicoin_pool.move                pool.move
book                 book.move        vector<Order>     coin_book.move    BigVector<Order>
                     serial u64 next_order_id           per-side encoded u128 keys
order                order.move       order_id: u64     coin_order.move   order_id: u128
matching/placement   order_info.move                    coin_order_info.move
fills                fill.move                          coin_fill.move
account state        account.move  VecSet<u64>          coin_account.move VecSet<u128>
pool state           state.move                         coin_state.move
vault                multicoin_vault.move (+ vault.move coin_vault.move
                     event helpers, u64 ids)            (u128 ids)
order queries        inline in multicoin_pool.move      coin_order_query.move (slice-based)
shared primitives    balances · quote_fee · math · history · fee_turnover · ewma ·
                     fee_schedule · fee_policy · trading_account · registry · constants · utils
new container        —                                  helper/big_vector.move (vendored)
```

Struct and function names inside `coin_*` modules stay unprefixed (`Order`, `Book`,
`create_order`, …) — the module path is the delineation (`triex::coin_order::Order` vs
`triex::order::Order`), which also gives every coin event a distinct type for indexers.

---

## 3. Design of the coin stack

### 3.1 Encoded order IDs (the DeepBook scheme)

```
bit 127        : side (0 = bid, 1 = ask)
bits 64 .. 126 : price (MAX_PRICE is already 2^63 − 1 — the exact required bound)
bits 0 .. 63   : per-side sequence counter
```

- `next_bid_order_id` starts at `MAX_U64` and **decrements**; `next_ask_order_id` starts
  at `0` and **increments**. Key order alone then yields price-time priority: bids
  iterate `max_slice()` → `prev_slice`, asks `min_slice()` → `next_slice`.
- The order ID **is** the BigVector key, so cancel/modify/get are `O(log)` by key with no
  sidecar index, and `coin_book::book_side(_mut)` dispatches on the decoded side bit.
- IDs are self-describing: clients can decode side and price from the ID.

### 3.2 `helper/big_vector.move` — vendored

Copy `../deepbookv3/packages/deepbook/sources/helper/big_vector.move` verbatim as
`triex::big_vector` (Apache-2.0, same header style), keep `public(package)`, and vendor
its tests from `../deepbookv3/packages/deepbook/tests/`. Treat as a frozen dependency —
any local edit must be flagged in review. (It can't be imported from the published
DeepBook package: it's `public(package)` there.) It's a generic container, not a
trading-type implementation, so it takes no `coin_` prefix.

### 3.3 `coin_book/` — fork of `book/`, ported to BigVector

New directory `sources/coin_book/` with `coin_book.move`, `coin_order.move`,
`coin_order_info.move`, `coin_fill.move`. The latter three are forks of their originals
with `u64 → u128` order-ID plumbing; `coin_book.move` is the real rewrite:

```move
public struct Book has store {
    bids: BigVector<Order>,        // triex::coin_order::Order
    asks: BigVector<Order>,
    next_bid_order_id: u64,        // MAX_U64, decrementing
    next_ask_order_id: u64,        // 0, incrementing
}
```

Port function bodies from `../deepbookv3/packages/deepbook/sources/book/book.move`,
keeping two triex-isms intact:

| Function | Port note |
| --- | --- |
| `empty` | `big_vector::empty(max_slice_size(), max_fan_out(), ctx)` per side; no `empty_multicoin`, and `price_scaling` can be dropped — the coin book always uses `FLOAT_SCALING`, so bake it into the qty↔quote math |
| `create_order` / `allocate_order_id` | per-side allocators + `utils::encode_order_id` |
| `inject_limit_order` | `book_side_mut(id).insert(id, order)`; `find_insert_position` is not forked |
| `match_against_book` | slice walk + post-match removal of filled/expired makers by key from `fills_ref()`; replaces the index-collection removal dance |
| `cancel_order` / `modify_order` / `get_order` | `remove` / `borrow_mut` / `borrow` by key; linear scans and the pop_back fast path are not forked |
| `mid_price`, `get_level2_range_and_ticks` | ~~keyed versions (`slice_before(key_high)` / `slice_following(key_low)`), preserving expiry-skip semantics~~ — ported as planned, then **removed** from the coin path on 2026-09-15; see §9 deviation 5 |
| `get_quantity_out` | **keep the triex fee math byte-for-byte** (quote-denominated fees, penalty multiplier, `quote_fee::fee_from_scaled_rate`); change only the iteration to a slice walk with the same `max_fills` counter and expiry behavior |
| `find_order_index` | not forked (vector-only helper) |

`coin_order.move` keeps the `price`/`is_bid` fields for now even though they're
decodable from the ID — dropping them is a follow-up, not part of the split.

### 3.4 `state/` and `vault/` forks

- `coin_account.move`: `open_orders: VecSet<u128>`; `add_order`/`remove_order`/fill
  processing follow.
- `coin_state.move`: fork of `state.move` importing `coin_account`/`coin_fill`/
  `coin_order`/`coin_order_info`; shared `history`/`balances`/`fee_turnover` imports
  unchanged.
- `coin_vault.move`: fork of `vault.move` — `Vault<Base, Quote>`, `QuoteFeeDeposit`, and
  the `PoolFeesDeposited`/`PoolFeesRefunded`/`PoolFeesWithdrawn` events with
  `order_id: u128`. `vault.move` itself is left in place because `multicoin_vault.move`
  calls its emitters and uses its `QuoteFeeDeposit` (u64 ids); once `pool.move` switches
  to `coin_vault`, the `Vault` struct in `vault.move` is dead code — strip it in the
  cleanup PR so `vault.move` ends up as the multicoin fee-event helper it actually is.

### 3.5 Shared modules, extended additively

- `constants.move`: add `START_BID_ORDER_ID = MAX_U64`, `START_ASK_ORDER_ID = 0`
  (+ accessors). `MAX_SLICE_SIZE`/`MAX_FAN_OUT` (64/64) already exist and match DeepBook.
- `utils.move`: restore `encode_order_id` / `decode_order_id` from
  `../deepbookv3/packages/deepbook/sources/helper/utils.move`; delete the stale
  commented `pop_until`/`pop_n` blocks and the "opaque u64 serials" note (now
  multicoin-specific — move it to a comment in `book.move`).

### 3.6 `pool.move` and `coin_order_query.move`

- `pool.move`: switch imports to the `coin_*` stack; all `order_id: u64` /
  `vector<u64>` params and returns become `u128`; `bids()`/`asks()` return
  `&BigVector<Order>`; delete the `#feat:bv` comment blocks as the real versions land.
- `order_query.move` → `coin_order_query.move`: port `iter_orders` from
  `../deepbookv3/packages/deepbook/sources/order_query.move` — the `start_order_id`
  anchor becomes `slice_before`/`slice_following` on the key instead of the O(n)
  `find_start_position` scan; `end_order_id`, `min_expire_timestamp`, and
  `has_next_page` semantics are preserved (existing `order_query_tests.move` is the
  contract, updated to u128 ids).

---

## 4. Keeping the fork honest (duplication policy)

The cost of full delineation is ~6 forked files whose logic is 95% identical. Manage it:

- **Diff-minimal forks:** keep function order, names, and comments identical to the
  original so `diff sources/book/order.move sources/coin_book/coin_order.move` shows
  only the ID-type and storage deltas. Resist drive-by refactors in either copy.
- **Fix-both rule:** any bug fix or fee-logic change touching a forked pair must land in
  both files in the same PR. Add this to the PR checklist / CLAUDE.md.
- **Shared primitives stay single-source:** fee math (`quote_fee`), balance accounting
  (`balances`), turnover, history, and policy modules are exactly the places where
  divergence would be a financial bug — they remain shared, and nothing in this plan
  forks them.

---

## 5. Migration / deployment

- **Multicoin pools:** nothing to migrate — no struct, API, or event changes. Existing
  pools keep working through the same `Versioned` inner.
- **Coin pools:** `PoolInner` changes shape (Book, State, Vault all change type), so
  existing coin pools cannot be lazily upgraded, and old serial u64 IDs can't be re-keyed
  without invalidating client-held IDs. Pre-mainnet recommendation: **fresh coin-pool
  deploys on all environments** (localnet + the three testnets in `Move.toml`); announce
  that coin-pool order IDs reset and change type.

### Off-chain impact
- Coin-pool order IDs become u128 (JSON: decimal string) and self-describing; MCP tools
  (`prepare_cancel_order`, `prepare_modify_order`, `orders_open`, `orders_fills`,
  `market_orderbook`) must carry per-pool-type ID width.
- Coin-pool events move to new types (`triex::coin_order::OrderCanceled`, etc.) —
  indexers subscribe to both event families and get an unambiguous per-trading-type
  stream, which is cleaner than today's shared types.

---

## 6. Test plan

1. **Vendored BigVector tests** (from `../deepbookv3/packages/deepbook/tests/`).
2. **Isolation proof:** all `multicoin_pool/*` suites, `trading_account_tests`, and
   multicoin integration tests pass **without a single edit**.
3. **Coin suites updated:** `tests/pool/*` (8 files + `pool_test_utils.move`),
   `order_query_tests.move`, coin-side integration `master_*` tests — u128 IDs via
   `utils::encode_order_id`, same behavioral assertions (matching, fees, escrow,
   retention, expiry must not change).
4. **New slice-boundary tests:** > 64 resting orders per side, taker sweep across a
   slice boundary (`max_fills = 100 > slice size 64` means sweeps span 2–3 slices),
   cancel/modify in a middle slice, level2 range and pagination page-break at a slice
   edge, bid-counter-descending time priority, `MAX_PRICE` boundary encode/decode.
5. **Gas benchmarks:** `gas_benchmarks.move` runs against coin pools — capture
   before/after at depth 10/40/80 and cancel-all; expect small fixed overhead at trivial
   depth, large wins at depth, and removal of the depth ceiling. The multicoin numbers
   double as the vector-baseline comparison.

---

## 7. PR sequence

| PR | Content | Risk |
| --- | --- | --- |
| 1 | Vendor `big_vector.move` + tests; `START_*_ORDER_ID` constants; `utils::encode/decode_order_id` + unit tests. Dead code, zero behavior change. | trivial |
| 2 | **Mechanical fork:** create all `coin_*` files as verbatim copies (only module names/imports changed); switch `pool.move`, `vault` usage, and `order_query.move`→`coin_order_query.move` onto the copies. Coin pools still vector/u64-serial — every existing test passes unchanged. This isolates the parallel-file churn from the design change. | mechanical, wide |
| 3 | **Coin redesign:** u128 encoded IDs through `coin_order`/`coin_order_info`/`coin_fill`/`coin_account`/`coin_state`/`coin_vault`; `coin_book` rewritten on BigVector (§3.3); `coin_order_query` slice pagination; `pool.move` API to u128. Coin tests updated. | the real change |
| 4 | **Cleanup + proof:** strip dead `Vault` from `vault.move`; delete `#feat:bv` comments from multicoin-side `book.move`; slice-boundary tests; benchmark table; docs/CLAUDE.md note on the fix-both rule. Optional follow-up: slim `coin_order::Order` by deriving price/side from the ID. | low |

PR 2 is the one to review structurally (files identical to originals?); PR 3 is the one
to review semantically (fee math unchanged? iteration order preserved?).

---

## 8. Risks and gotchas

- **Silent drift between forked pairs** is the long-term risk — mitigations in §4. The
  fee/escrow logic in `coin_order_info`/`coin_fill` is the highest-stakes copy.
- **Fee math in `get_quantity_out` / `match_against_book`:** only iteration changes; any
  diff in fee outcomes between PR 2 and PR 3 test runs is a bug. Consider
  characterization tests pinned before PR 3.
- **Expiry parity:** the vector code counts expired makers toward `max_fills` in
  `get_quantity_out` but skips their quantity; `mid_price`/level2 skip them entirely.
  Preserve exactly in the ported bodies.
- **Two event families:** anything downstream that assumes one `OrderCanceled` type
  (indexer, MCP, analytics) must be updated in the same release window as PR 3.
- **`vault.move` residue:** until the PR 4 cleanup, `vault.move` carries a dead `Vault`
  struct — harmless but confusing; don't skip the cleanup.
- **Pool object growth (coin side):** each BigVector is a wrapped object with
  dynamic-field slice children. Coin pools are shared and never deleted, so no
  `destroy_empty` path is needed today; note it if pool deletion ever lands.
- **Shallow-depth gas regression (coin side):** slice access is a dynamic-field load vs
  one contiguous vector read. Benchmarks decide if 64/64 tuning is right; DeepBook ships
  these values in production.

---

## 9. Implementation notes (as built)

Landed as one change rather than the four PRs of §7 (the sequencing was for reviewability,
not correctness). Final state: **617 tests pass**, sources and tests build clean, and the
package's total warning count went *down* (107 → 104).

### What shipped

New, delineated coin stack (all `public(package)` boundaries unchanged):

| File | Notes |
| --- | --- |
| `sources/helper/big_vector.move` | Vendored verbatim from deepbookv3; only the module path and its two `use fun` aliases repointed. Header marks it frozen. |
| `sources/coin_book/coin_book.move` | The rewrite. `BigVector<Order>` per side, per-side id allocators, keyed cancel/modify/get, slice-walk matching. (Level2 and mid-price were ported, then removed — see §9 deviation 5.) |
| `sources/coin_book/coin_order.move`, `coin_order_info.move`, `coin_fill.move` | Forks; `u128` order ids, otherwise line-for-line their originals. |
| `sources/state/coin_account.move`, `coin_state.move` | Forks; `VecSet<u128>` open orders, `u128` refund ids. |
| `sources/vault/coin_vault.move` | Fork; `u128` ids on the refund path. |
| `sources/coin_order_query.move` | Slice-based pagination, replacing the deleted `order_query.move`. |
| `tests/coin_book/coin_book_slice_tests.move` | New: 8 depth tests above the 64-order slice boundary. |
| `tests/helper/big_vector_tests.move` | Vendored (21 tests). |

Shared and extended: `helper/utils.move` (order-id codec + `pop_until`/`pop_n`, with new
codec tests), `helper/constants.move` (`START_BID_ORDER_ID` / `START_ASK_ORDER_ID`).
`sources/vault/vault.move` kept only the fee-event helpers `multicoin_vault` shares; its
coin `Vault` moved to `coin_vault.move`. `tests/vault/vault_tests.move` →
`coin_vault_tests.move`, `tests/order_query_tests.move` → `coin_order_query_tests.move`.

### Isolation held
No file under `multicoin_pool.move`, `vault/multicoin_vault.move`, or `tests/multicoin_pool/`
was edited, and every multicoin suite passes unmodified. The multicoin tests reach into the
coin stack only for `pool::create_pool_admin` and for `vault::PoolFeesRefunded` — both of
which kept their signatures.

### Deviations from the plan

1. **`price_scaling` kept on the coin `Book`** (§3.3 proposed dropping it). Dropping it
   would have rippled into `coin_order`'s and `coin_state`'s shared fee/escrow signatures,
   which is exactly the churn §4's diff-minimal rule exists to prevent. It is a single u64,
   set once to `FLOAT_SCALING`.
2. **`coin_book` has no `EBookOrderNotFound`.** The id *is* the storage key, so the book
   never searches and never gets the chance to raise its own code — a cancel/modify/lookup
   of an absent id aborts inside `big_vector` with `ENotFound`. The 11 coin tests that
   assert "order is gone" now expect `big_vector::ENotFound`. The multicoin book keeps
   code 8.
3. **`iter_orders` anchor-miss behaviour changed.** The vector version fell back to the top
   of the book and re-served page one when `start_order_id` named no live order. Keyed
   seeking never does that — but the "returns an empty page" claim first written here was
   **wrong**, and the doc comment and test that asserted it were both corrected on
   2026-09-15. `slice_before` / `slice_following` seek by *position*, not by presence: an
   anchor that has been filled or cancelled resolves to the slot it would have occupied
   and the page resumes from its neighbour. Only an anchor outside the side's key range
   yields an empty page, which is what the original test (anchor `999`) actually pinned.
   `test_stale_in_range_anchor_resumes_from_its_neighbour` now covers the real case.
   The exclusive-anchor contract is preserved on **both** sides: `slice_before` is already
   strictly-before for bids, and the ask path explicitly steps over an exact hit because
   `slice_following` is inclusive.
5. **`mid_price` and `get_level2_range_and_ticks` were removed from the coin path**
   (2026-09-15), along with the `pool::mid_price`, `pool::get_level2_range` and
   `pool::get_level2_ticks_from_mid` wrappers and `constants::e_incorrect_mid_price`.
   Neither view was reachable from any on-chain caller, and a sweep of the workspace —
   `sdks/`, `triex-app-api`, `etl-api` — found no off-chain caller either: the app computes
   its mid client-side from best bid/ask and sources the book from the ETL indexer. They
   were also the two views that reported unfillable dust as real depth (see §10.3), so
   removing them closed that defect by deletion. Multicoin keeps both. Re-adding a public
   function later is a compatible upgrade if an integrator ever needs them.
4. **`book.move` was touched after all**, comments only — verified by diffing the
   non-comment lines, which are byte-identical. 294 lines of commented-out BigVector code
   were deleted (they are now real code in `coin_book.move`, so keeping them was a drift
   hazard) and the header now states that the vector book is multicoin's permanent choice
   rather than a staging post. Its unused `FLOAT_SCALING` constructor was also dropped.

### Measured gas: the honest result

`--statistics` on `tests/gas_benchmarks.move`, vector book vs BigVector, in computation
units (absolute figures minus their common base):

| benchmark | vector | bigvector | change |
| --- | --- | --- | --- |
| `bench_depth_10` | 13,545 | 15,504 | +14.5% |
| `bench_depth_40` | 73,235 | 78,570 | +7.3% |
| `bench_depth_80` | 246,078 | 269,127 | +9.4% |
| `bench_depth_300` *(new)* | 1,180,332 | 1,271,532 | +7.7% |
| `bench_cancel_at_depth_80` | 249,813 | 276,153 | +10.5% |
| `bench_modify_at_depth_80` | 248,639 | 272,327 | +9.5% |
| `bench_cancel_all_at_depth_80` | 444,522 | 519,921 | +17.0% |

**BigVector is more expensive on computation at every depth measured, and there is no
crossover in range.** Two things explain it, and neither is a defect:

- `MAX_SLICE_SIZE` is 64, so depth 80 is *two* slices and depth 300 is about five. Each
  slice touch is a dynamic-field load, which in the Move VM costs more than the vector
  memmove it replaces. The gap does narrow with depth (14.5% → 7.7%), but slowly.
- **The unit-test gas meter models computation only, not storage.** The primary reason for
  this conversion is that the vector book rewrites the entire bids-or-asks vector into the
  object on every placement: that is storage I/O, it grows the pool object without bound,
  and it puts a hard ceiling on book depth at Sui's max object size. None of that is
  visible here, so these numbers measure the cost side of the trade and not the benefit.

So the conversion should be justified as **removing the depth ceiling and making
cancel/modify/lookup O(log n) by key, at a measured ~8–17% computation-gas cost** — not as
a computation win. If shallow-book gas matters more than depth headroom for coin pools,
the 64/64 slice tuning is the dial to turn, and that decision is now measurable. A
`bench_depth_600` was written and dropped: it exceeds the test harness's per-test time
budget.

---

## 10. Follow-up: the gaps the DeepBook comparison surfaced, and one it introduced

A systematic comparison against DeepBook v3 (`../deepbookv3`, upstream `5f21dea8`) after the
conversion landed turned up two defects worth fixing immediately (§10.1, §10.2). Both were
pre-existing triex behaviour, not products of the BigVector work.

§10.3 is different in kind and worth reading as a cautionary note: it is a defect the §10.2
fix *introduced*, caught in review before merge. The fix was right about which fills to
refuse and wrong about how the caller should read that refusal.

### 10.1 The kill switch did not exist, in two independent ways

`registry::disable_version` asserted `version != constants::current_version()`, so the running
package could not be halted at all: the only response to a live exploit was to publish a new
package first. DeepBook has no such assert.

Removing it alone would not have been enough, and this is the part worth remembering. Pools
cache `allowed_versions` in `PoolInner` and check the *cached* copy, so a registry-level
disable only bites once it is pushed to each pool via `update_allowed_versions` (admin) or the
permissionless `update_pool_allowed_versions`. Both read `registry::allowed_versions()`, which
went through the **version-gated** `load_inner()`. So disabling the running version made
`allowed_versions()` abort, which made both propagation paths abort — the flag would flip and
no pool could ever observe it. DeepBook's `allowed_versions()` reads `load_value()` directly
for exactly this reason ([their registry.move:400-403](https://github.com/MystenLabs/deepbookv3/blob/main/packages/deepbook/sources/registry.move)).

Both are fixed: the assert is gone (code 6 left unrecycled), and `allowed_versions()` now
bypasses the gate with a comment explaining that gating it would be circular. Four tests in
`tests/registry_kill_switch_tests.move` pin the halt, the *propagate-while-halted* step, its
permissionlessness, and recovery.

### 10.2 Fills could settle for zero quote

`qty_to_quote` floors, so any fill of fewer than `FLOAT_SCALING / price` base units converted
to **zero** quote: the taker received base without paying, while the maker's `filled_quantity`
advanced uncompensated. Reproduced before fixing — a taker buying 999 raw base units against
an ask at a raw price of `1e6` received all 999 for 0 quote and 0 fees.

The economic loss is bounded under one raw quote unit per fill, so this is a rounding leak
rather than a drain, but it is still base moving for no payment. It is also specific to the
coin pools: multicoin's `price_scaling == 1` path multiplies instead of dividing, so no fill
can floor to zero there.

**Fixed without introducing a configured size parameter**, which is the point. A per-pool tick
size, lot size or minimum order size — DeepBook's approach — cannot be sized here: coin pools
list bases priced anywhere from `0.000000001` to `10,000,000,000` quote, and pool creation is
permissionless, so nobody trustworthy is choosing the number. Instead the bound is *derived*
from each order's own price by `math::min_qty_for_nonzero_quote`, the fixed-point reciprocal
of the price, which self-sizes across the whole range:

| raw price | human price (9-dec quote) | bound |
| --- | --- | --- |
| 1 | 0.000000001 | 1,000,000,000 |
| 1e6 | 0.001 | 1,000 |
| 1e9 | 1.0 | 1 |
| max_price | — | 1 |

Three enforcement points:
- `coin_order_info::match_maker` declines a **live** fill worth zero quote, and reports
  *why* via `MatchOutcome` so the book walk knows whether to stop or to step over — see
  §10.3, where treating that refusal as terminal turned out to wedge the whole side.
  Expiries are exempt: they move no quote, they return the maker's own principal.
- `coin_order_info::validate_inputs` rejects a limit order below the bound at its own price,
  since it could never produce an acceptable fill and would rest as unfillable dust. Market
  orders are exempt: they match at each maker's price, not the sentinel they carry, and never
  rest. This reuses DeepBook's code 1, `EOrderBelowMinimumSize`.
- `coin_order::modify` applies the same bound to the remainder a modify-down leaves
  (added 2026-09-15). Checking only `original_quantity` at placement left one modify able
  to park a healthy order below the bound; see §10.3.

`coin_book::get_quantity_out` walks the same way the matcher does, so a quote never promises
a fill the matcher would decline, nor hides liquidity the matcher would reach.

**Deliberately *not* done: quantizing fills to a multiple of the bound.** The first attempt did,
and `pool_quote_decimal_precision_tests::test_q6_fractional_price_fee_captured` caught it — a
6-decimal quote puts ordinary prices near `1e6`, so the bound is ~667 raw units and quantizing
shaved *normal* trades. Only the zero case is refused; the taker keeps a rounding benefit under
one raw quote unit per fill, as in any fixed-point book. Escrow is safe either way, since
sum-of-floors never exceeds the floor-of-sum a bid maker locked at placement.

Seven tests in `tests/coin_book/coin_book_zero_quote_tests.move` pin the arithmetic, the
placement and match-time enforcement points, the market-order path, and — importantly — that
an ordinary fill is *not* truncated. Eight more in `tests/coin_book/coin_book_dust_tests.move`
cover the blocker case and the `modify` bound (§10.3).

### 10.3 The zero-quote guard wedged the whole book side

Found by review of PR #13 (`docs/reviews/pr-13-bigvector-coin-pools.md`) and fixed on
2026-09-15. The guard added in §10.2 was correct about *what* to refuse and wrong about
*what that means for the walk*.

`match_maker` returned `false` for a zero-quote fill — the same `false` it returns when the
price no longer crosses or the taker is filled — and `match_against_book` reads `false` as
`break`. One resting order under the bound at the best price therefore made **every order
behind it unreachable**: across all worse price levels, on both sides, for limit and market
takers alike. Reproduced, and the repros now live in `coin_book_dust_tests.move`.

It was reachable two ways. Accidentally, since nothing re-checked the *remaining* quantity
after a partial fill — an ordinary taker leaving a sub-bound residue created a blocker.
Deliberately and cheaply, since `modify` asserted only `filled < new < quantity`: rest a
legal order inside the spread, modify it to 1 unit, and the side is dead for the cost of two
transactions. With `expire_timestamp = max_u64` it never aged out, and only the attacker
could cancel it.

Three changes:

1. **`match_maker` returns `MatchOutcome`** — `Filled` / `Skipped` / `Stopped` — instead of
   a bool that meant both "this maker cannot trade" and "the book cannot trade". Only
   `Stopped` ends the walk. Using a three-state type rather than a second bool is the point:
   the overloading *was* the bug, so it is now unrepresentable.
2. **A maker that can never fill again is retired on sight**, via the path an expiry already
   takes: no quote moves, the maker's own principal is returned, the order leaves the book.
   Skipping alone would have left a weaker wedge — `max_fills` is 100, so ~100 planted dust
   orders would still exhaust every taker's budget permanently. The test is read off the
   **maker's own remaining quantity**, never off the crossing amount; reading `matchable`
   instead would let any taker arriving with a small residue evict a healthy resting order.
   `a_healthy_maker_survives_a_taker_carrying_a_sub_bound_residue` pins that.
3. **`coin_order::modify` re-applies the bound**, closing the deliberate route.

`get_quantity_out` carried the identical `break` in both arms and was fixed in the same
change — necessarily, not incidentally: fixing only the matcher would have created a
dry-run/settlement divergence that did not previously exist, since the quote would
under-report liquidity the matcher now fills straight through.

The two views that reported such dust as real depth, `mid_price` and
`get_level2_range_and_ticks`, were removed instead of fixed — see §9 deviation 5.

### Still open from the comparison

Not addressed here, in rough priority: hoisting `validate_proof` to the top of
`place_order_int` / `cancel_order` / `modify_order` (currently ~80 lines after the first state
write — not exploitable, since settlement validates unconditionally and an abort reverts, but
fragile); `client_order_id`, which is absent everywhere and is a breaking ABI change once
frozen; `cancel_live_order(s)`, whose absence makes cancel-replace races abort wholesale;
`coin_account::update` never being called, so `Account.epoch` never advances and volumes
accumulate for the pool's lifetime; `burn_cred` always burning zero; `place_post_only_limit_order`;
inverse quoting (`get_quantity_in`); non-aborting top-of-book getters; renaming
`pool_trade_params` to reflect that it reports the entry rung; and binding a pool to a specific
`FeePolicy` object id.
