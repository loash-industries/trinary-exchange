# Plan: Convert pool order storage from `vector<Order>` to `BigVector<Order>`

**Status:** Superseded · 2026-09-13 — replaced by
[coin-pool-bigvector-side-by-side.md](coin-pool-bigvector-side-by-side.md), which converts
only the coin pools and keeps multicoin pools on vectors/serial IDs. Retained for the
reference detail in §1–§3.
**Scope:** `triex::book` and everything that touches order IDs. The `Book` struct is shared by
`Pool<Base, Quote>` (pool.move) and `MultiCoinPool<Quote>` (multicoin_pool.move), so converting it
converts both pool families at once — there is no way to convert only the coin pools without
forking `Book`, and no reason to.

---

## 1. Background and current state

`Book` today stores both sides as flat Move vectors:

```move
public struct Book has store {
    bids: vector<Order>,   // sorted ASCENDING by price  (best bid at END)
    asks: vector<Order>,   // sorted DESCENDING by price (best ask at END)
    next_order_id: u64,    // opaque serial, shared by both sides
    price_scaling: u64,    // 1e9 for normal pools, 1 for multicoin pools
}
```

Consequences of the vector representation:

- **Insert is O(n)** memmove (`inject_limit_order` → binary search + `vector::insert`).
- **Cancel/modify/get by ID is O(n)** linear scan over both sides (`cancel_order`,
  `modify_order`, `get_order`, `find_order_index`).
- **The whole book is one object field** — every order placement rewrites the entire
  bids or asks vector into the transaction effects, so gas grows linearly with book depth
  and the book has a practical size ceiling well below `MAX_OPEN_ORDERS × makers`.

The module was originally derived from DeepBook v3 and was deliberately downgraded to
vectors; the original BigVector implementations are preserved as `#feat:bv` comment blocks
throughout `book.move`, `pool.move`, and `utils.move`. Several prerequisites are already
in place and confirm the code was pre-staged for this conversion:

- `constants.move` already defines `MAX_SLICE_SIZE = 64` and `MAX_FAN_OUT = 64` with accessors.
- `MAX_PRICE = (1u128 << 63) - 1` — exactly the bound required so a price fits in bits
  64–126 of a u128 order key.
- `utils.move` contains commented-out `#feat:bv` helpers and the note "Order IDs are opaque
  `u64` serials" marking the divergence point.

**Reference implementation:** [MystenLabs/deepbookv3](https://github.com/MystenLabs/deepbookv3)
— specifically:

| File (under `packages/deepbook/sources/`) | What to take from it |
| --- | --- |
| `helper/big_vector.move` | The whole module, vendored verbatim |
| `helper/utils.move` | `encode_order_id` / `decode_order_id` |
| `book/book.move` | BigVector-based `create_order`, `match_against_book`, `cancel_order`, `modify_order`, `mid_price`, `get_level2_range_and_ticks`, `book_side(_mut)` |
| `helper/order_query.move` (`iter_orders`) | Slice-based pagination |
| `helper/constants.move` | `START_BID_ORDER_ID`, `START_ASK_ORDER_ID` conventions |

BigVector API (verified against the repo, module `deepbook::big_vector`): a B+-tree keyed
by `u128`, elements in leaf "slices" stored as dynamic fields under the BigVector's own
`UID`. Key operations: `empty(max_slice_size, max_fan_out, ctx)`, `insert(key, val)`,
`remove(key): E`, `borrow(_mut)(key)`, `min_slice()` / `max_slice()` /
`slice_before(key)` / `slice_following(key)` returning `(SliceRef, offset)`,
`next_slice` / `prev_slice` for ordered traversal, `borrow_slice(_mut)`, and
`destroy_empty`. `BigVector<phantom E: store> has key, store` — it is a wrapped object
with its own UID.

---

## 2. Core design decision: order IDs become encoded u128 keys

BigVector is keyed, and ordered iteration comes entirely from key order. The book must be
able to (a) iterate a side in price-time priority and (b) remove/borrow an order given
only its ID. DeepBook solves both with one move: **the order ID *is* the key**, encoded as

```
bit 127        : side (0 = bid, 1 = ask)
bits 64 .. 126 : price (u64, capped at 2^63 - 1 — already our MAX_PRICE)
bits 0 .. 63   : per-side sequence counter
```

with two allocators replacing `next_order_id`:

- `next_bid_order_id` starts at `MAX_U64` and **decrements** → within a price level an
  older bid has a *larger* key → iterating bids from `max_slice()` backwards via
  `prev_slice` yields price-time priority.
- `next_ask_order_id` starts at `0` and **increments** → older asks have *smaller* keys →
  iterating asks from `min_slice()` forwards via `next_slice` yields price-time priority.

This is the scheme the `#feat:bv` comment blocks in `book.move` already assume
(`utils::decode_order_id`, `next_bid_order_id`, `START_BID_ORDER_ID`, the msb math in the
level2 comment block).

**Consequence (the one breaking change):** `order_id` changes type `u64 → u128` across the
entire package surface — `Order`, `OrderInfo`, `Fill`, all events (`OrderPlaced`,
`OrderCanceled`, `OrderModified`, `OrderExpired`, fill events), `Account.open_orders:
VecSet<u64> → VecSet<u128>`, every public entry taking `order_id` / `order_ids` on both
pool types, `order_query`, and off-chain consumers (MCP `prepare_cancel_order` /
`prepare_modify_order` / `orders_open` etc., plus any indexer parsing events — u128 is
serialized as a decimal string in JSON-RPC).

**Alternative considered and rejected:** keep opaque u64 IDs and maintain a
`Table<u64, u128>` sidecar index inside `Book` mapping public ID → BigVector key. It
preserves the external API but adds a dynamic-field write+delete per order lifecycle,
creates a second source of truth, and diverges from the DeepBook code we are restoring.
Since order IDs also become self-describing (side + price decodable from the ID — useful
for clients and for `book_side_mut` dispatch), adopting the encoded key is strictly better.

Bonus available immediately (or as a follow-up): `Order` currently stores `price: u64` and
`is_bid: bool` explicitly. Both become derivable via `utils::decode_order_id(order_id)`,
letting us shrink the resting-order struct like DeepBook does. Recommended as a follow-up
PR, not bundled into the conversion.

---

## 3. Module-by-module changes

### 3.1 New: `sources/helper/big_vector.move`
Vendor `big_vector.move` from deepbookv3 (Apache-2.0, same license/header style this repo
already uses), renaming the module to `triex::big_vector`. Keep functions
`public(package)`. Vendor its test file too (deepbookv3 keeps BigVector tests in
`packages/deepbook/tests/`). No triex-specific edits should be needed — treat it as a
frozen dependency; any local modification must be flagged in review.

*(Why vendor rather than depend on the published DeepBook package: `big_vector` is
`public(package)` inside the deepbook package, so it is not importable; and we don't want
the whole DeepBook dependency for one helper.)*

### 3.2 `helper/constants.move`
- Add `START_BID_ORDER_ID: u64 = MAX_U64` and `START_ASK_ORDER_ID: u64 = 0` (+ accessors).
- `MAX_SLICE_SIZE` / `MAX_FAN_OUT` (64/64) already exist — keep, they match DeepBook.
- Remove nothing yet; `max_fills`, `max_open_orders` are unaffected.

### 3.3 `helper/utils.move`
Restore from DeepBook:
```move
public(package) fun encode_order_id(is_bid: bool, price: u64, order_id: u64): u128
public(package) fun decode_order_id(encoded: u128): (bool /*is_bid*/, u64 /*price*/, u64 /*seq*/)
```
Delete the commented `pop_until` / `pop_n` blocks (they serve DeepBook modules we don't have).

### 3.4 `book/order.move`, `book/order_info.move`, `book/fill.move`
- `order_id`, `maker_order_id`, `taker_order_id`: `u64 → u128` in structs, constructors,
  accessors, and all emitted events.
- `OrderInfo.set_order_id` takes the encoded id; `order_info.validate_inputs` already
  guards `price <= MAX_PRICE` (verify — if not, add the assert; the encoding silently
  corrupts above 2^63).
- Keep `price` / `is_bid` fields on `Order` for now (see §2 bonus).

### 3.5 `book/book.move` — the core rewrite
Restore the `#feat:bv` implementations, adapted for the two triex-specific behaviors the
DeepBook originals don't have: **`price_scaling`** (multicoin pools use 1) and the
**quote-denominated fee model** in `get_quantity_out`. Concretely:

```move
public struct Book has store {
    bids: BigVector<Order>,        // key order: ascending price; older bids higher within level
    asks: BigVector<Order>,        // key order: ascending price; older asks lower within level
    next_bid_order_id: u64,        // MAX_U64, decrementing
    next_ask_order_id: u64,        // 0, incrementing
    price_scaling: u64,
}
```

| Function | Change |
| --- | --- |
| `empty` / `empty_multicoin` | `big_vector::empty(max_slice_size(), max_fan_out(), ctx)` per side — `ctx` params already exist |
| `allocate_order_id` | split per side, encode with `utils::encode_order_id(is_bid, price, seq)` |
| `inject_limit_order` | `self.book_side_mut(order_id).insert(order_id, order)`; **delete** `find_insert_position` |
| `match_against_book` | restore slice-walk version: bids side iterates `min_slice`→`next_slice` (asks) when taker is bid, `max_slice`→`prev_slice` (bids) when taker is ask; after matching, remove filled/expired makers by key from `order_info.fills_ref()` — this replaces the current index-collection removal dance entirely |
| `cancel_order` | `self.book_side_mut(order_id).remove(order_id)` — O(log); signature `u128`; delete the pop_back fast path and both linear scans |
| `modify_order` | `book_side_mut(order_id).borrow_mut(order_id)` + existing quantity checks |
| `get_order` | `book_side(order_id).borrow(order_id).copy_order()` |
| `mid_price` | restore slice-walk version (skip-expired loops per side), keep `math::mul(sum, half())` |
| `get_quantity_out` | keep the current triex fee math verbatim; replace only the iteration: `let (ref, offset) = if (is_bid) self.asks.min_slice() else self.bids.max_slice()` + `next_slice`/`prev_slice` walk, preserving the `max_fills` counter and expiry-skip semantics exactly |
| `get_level2_range_and_ticks` | restore the keyed version: build `key_low`/`key_high` from the price range + side msb, seed with `slice_before(key_high)` (bids) / `slice_following(key_low)` (asks), walk with `prev_slice`/`next_slice`. Note the `#feat:bv` comment block has a typo (`book_side.(ref, offset)`) — take the real body from deepbookv3, not the comment |
| `find_order_index` | delete (only used by the vector representation) |
| new `book_side` / `book_side_mut` | restore from comments: dispatch on `decode_order_id(order_id).is_bid` |

Delete all `#feat:bv` comment blocks as their real versions land — they've done their job.

### 3.6 `state/account.move`, `state/state.move`, `state/history.move`
- `Account.open_orders: VecSet<u64> → VecSet<u128>`; `add_order` / `remove_order` /
  `open_orders()` signatures follow.
- Grep for every other `order_id`-typed field/param in `state/` (`process_cancel`,
  fill processing at `account.move:177`, history records) and flip to u128.

### 3.7 `pool.move` and `multicoin_pool.move`
Mechanical but wide:
- `bids()` / `asks()` accessors return `&BigVector<Order>`.
- All entries taking `order_id: u64` / `order_ids: vector<u64>` → u128
  (`cancel_order`, `cancel_orders`, `modify_order`, `get_order`, `get_orders`,
  `locked_balance` helpers, etc.).
- `cancel_all_orders` (`multicoin_pool.move:707`, and the pool.move twin at ~line 650):
  unchanged shape — it iterates `open_orders().into_keys()` (now `vector<u128>`) and
  cancels by ID; each cancel is now O(log) instead of O(n).
- `MultiCoinPoolInner` / `PoolInner` need no structural change beyond `Book`'s new shape
  (BigVector has `store`, so wrapping inside `Versioned` keeps working; the pool object
  gains child objects for the slices — invisible to callers).

### 3.8 `order_query.move`
Rewrite `iter_orders` on the keyed API (DeepBook has the exact analogue — port it):
- `start_order_id` anchor → `slice_before(start_key)` (bids) / `slice_following(start_key)`
  (asks) instead of the current O(n) `find_start_position` scan; the "start strictly after
  the anchor to avoid repeating pages" behavior falls out of before/following semantics —
  add a regression test for the boundary.
- `end_order_id` stop and `min_expire_timestamp` filter: unchanged logic inside the walk.
- `has_next_page` semantics preserved (existing `order_query_tests.move` is the contract).

There is a second copy of the iteration logic in `multicoin_pool.move` (~lines 983–1070,
`get_open_orders` / level2 helpers) — convert it the same way or, better, funnel both pool
types through shared helpers so the walk exists once.

---

## 4. Migration / deployment

`Book` changes shape *inside* `PoolInner` / `MultiCoinPoolInner`, so this is not a lazy
`Versioned` bump — existing pool objects cannot be reinterpreted, and old u64 order IDs
cannot be mapped onto encoded keys without re-keying every resting order (which would also
invalidate every client-held order ID).

Given the package is pre-mainnet (localnet + three testnets in `Move.toml`), the
recommendation is: **fresh package deploy + fresh pools on all environments; no on-chain
migration.** Announce that testnet order IDs reset. If any environment must preserve
state, the fallback is a `migrate()` entry that drains the old vectors into new BigVectors
re-encoding IDs — but budget for it only if actually needed.

---

## 5. Off-chain impact (flag before merging)

- **MCP server / clients:** `order_id` is u128 everywhere (JSON: decimal string). Affects
  `prepare_cancel_order`, `prepare_modify_order`, `orders_open`, `orders_fills`,
  `market_orderbook`, and any cached IDs.
- **Indexers:** event schemas change (u128 ids). BCS layout of every order event shifts.
- **Nice side effect:** clients can decode side & price from the ID itself.

---

## 6. Test plan

Existing suites are the safety net — the behavioral contract (matching, fees, escrow,
expiry, pagination) must not change, only the storage:

1. **Vendored BigVector unit tests** (port from deepbookv3) — slice split/merge,
   remove-rebalance, min/max/next/prev traversal.
2. **All existing suites green** after conversion: `pool_tests`, the `multicoin_pool/*`
   suites, `order_query_tests`, integration `master_*` tests, `locked_balance_tests`.
   Test utils that fabricate order IDs need the encoding helper.
3. **New depth tests crossing slice boundaries:** > 64 resting orders per side (forces
   multi-slice trees), taker sweep across a slice boundary, cancel/modify of an order in a
   middle slice, level2 range spanning slices, pagination page-break exactly at a slice
   edge.
4. **Order-ID encoding tests:** round-trip encode/decode, bid-counter-descending time
   priority within a level, price = MAX_PRICE boundary.
5. **Gas benchmarks** — `tests/gas_benchmarks.move` already measures depth 10/40/80,
   cancel-at-depth-80, sweeps, cancel-all. Capture the before/after table in the PR
   description. Expected shape: small fixed overhead at trivial depth (dynamic-field
   loads), large wins on insert/cancel at depth, and removal of the depth ceiling.

---

## 7. Suggested PR sequence

| PR | Content | Risk |
| --- | --- | --- |
| 1 | Vendor `big_vector.move` + its tests; add `START_*_ORDER_ID` constants; restore `utils::encode/decode_order_id` with unit tests. All dead code — zero behavior change. | trivial |
| 2 | u128 order-ID plumbing end-to-end (order/order_info/fill/events/account/state/pool APIs/order_query/tests) **while still vector-backed**. Allocators split per side and encode keys; the vector insert comparator keeps working because the same-price tiebreak ("older closer to END") is preserved by the per-side counters for bids and needs one comparator flip for asks — or simply sort by full encoded key. All existing tests updated and green. | mechanical but wide |
| 3 | Swap `Book` storage to `BigVector`; restore the `#feat:bv` implementations per §3.5; rewrite `order_query::iter_orders`; delete vector-only helpers and all `#feat:bv` comments. | the real change |
| 4 | New slice-boundary/depth tests; benchmark before/after; follow-ups (shrink `Order` by deriving price/side from ID; dedupe the multicoin iteration copy). | low |

PRs 2 and 3 can be collapsed into one if the double-touch of every call site feels worse
than one large review — but keeping the ID-type change separate from the storage change
makes both reviewable.

---

## 8. Risks and gotchas

- **The `#feat:bv` comments are stale in places** — one has a syntax typo, another
  references `next_bid_order_id` fields the comments themselves don't declare, and none
  know about `price_scaling` or the triex quote-fee model. Port from the deepbookv3 repo
  as ground truth and use the comments only as a map of *where* things go.
- **Fee logic in `get_quantity_out` and `match_against_book` is triex-specific**
  (quote-denominated fees, penalty multiplier, per-order snapshotted maker rates,
  cancel-retention bps). Only the iteration changes; any diff in fee math is a bug.
- **Expiry semantics parity:** the vector code counts expired makers toward `max_fills`
  in `get_quantity_out` but skips them for quantity; `mid_price`/level2 skip them.
  Preserve exactly — write a characterization test first if unsure.
- **`max_fills = 100 > slice size 64`:** a full sweep touches 2–3 slices; fine, but it's
  why the slice-walk loops must handle `SliceRef::is_null()` mid-iteration.
- **Gas at shallow depth regresses slightly** (each slice touch is a dynamic-field access
  vs. one contiguous vector). The benchmarks decide whether 64/64 is the right tuning;
  DeepBook ships the same values in production.
- **Pool object growth:** each BigVector is a wrapped object with dynamic-field children.
  Pools are shared and never deleted today, so no `destroy_empty` path is needed — note it
  if pool deletion ever lands.
- **Price bound:** encoding corrupts silently above 2^63 − 1; `MAX_PRICE` already equals
  that, so the existing validation assert is the guard — confirm both pool families
  enforce it on the multicoin (`price_scaling = 1`) path too.
