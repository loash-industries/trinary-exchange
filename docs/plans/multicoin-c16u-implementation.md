# Adopting C16u in multicoin pools

**Implementation plan for the recommendation in
[multicoin-book-storage-whitepaper.md](multicoin-book-storage-whitepaper.md) §7.4**

| | |
| --- | --- |
| Scope | `triex::book` and the multicoin plumbing that carries an order id |
| Target | BigVector keyed by encoded `u128`, 16-order inline hot buffer, spill to 12, **no refill** |
| Out of scope | coin pools (`triex::coin_book`), except one defect noted in §6 |
| Status | Phases 0–4 done on `feat/multicoin-c16u`; phase 5 open |
| Branch | `feat/multicoin-c16u`, off `cycle-7` |

---

## 1. Where we actually start from

Three facts change the size of this job from what §8 of the whitepaper implies.

**The implementation already exists and was measured.**
[`multicoin-book-storage-experiment-data/scripts/book_variant.move`](multicoin-book-storage-experiment-data/scripts/book_variant.move)
is a complete 710-line `module triex::book` — BigVector, `Cursor`, hot buffer,
gated spill, unidirectional admission — written against this stack's `order::Order`
and `order_info::OrderInfo`, and it is the artifact the C16u column in every table
was produced from. Its `get_quantity_out` is line-for-line identical to the one on
`HEAD` (only comments stripped and the traversal swapped to `Cursor`), and its
`match_against_book` matches the current `bool`-returning `order_info::match_maker`
rather than the coin fork's three-state `MatchOutcome`. It has not drifted.

**The coin stack already made the same journey.** `f9d3398` converted coin pools to
BigVector + encoded `u128` ids, and the in-flight working-tree change adds the hot
buffer to `coin_book`. So the id codec (`utils::encode_order_id`), the per-side
sequence seeds (`constants::start_bid_order_id` / `start_ask_order_id`), the vendored
`big_vector`, and the `Cursor` pattern are all in the tree and under test. Nothing has
to be invented.

**Deployment is by fresh redeploy, not version migration** — confirmed, not assumed.
Deployments are testnet-only and unaudited (`README.md` §109), so no live multicoin
pool's `Book` layout has to survive this change, and none will be migrated in place.
That is what makes the rest of this plan small; see §7 for what it rules out.

The remaining work is consequently *not* a research port. It is: widen an id type
across eight multicoin files, drop in a book that already exists, rewrite the tests
that assert the flat vector's mechanics, and tell the off-chain consumers.

---

## 2. Decisions to take before writing code

**D1 — Start from the variant, not from `coin_book`.** The variant is this stack's
book; `coin_book` is the other stack's and has since diverged (`MatchOutcome`,
`price_scaling = FLOAT_SCALING`, no `mid_price` / `level2`). Port the variant,
re-attach the explanatory prose the experiment stripped out of `get_quantity_out`,
and delete the experiment levers.

**D2 — Delete the levers rather than keep them configurable.** `HOT_CAPACITY == 0`,
`REFILL_ENABLED` and `top_up` exist to select variants B / C16 / C16u from one file.
Shipping them would keep ~60 lines of unreachable code and a `HOT_REFILL_FLOOR`
constant that means nothing under C16u. Ship `HOT_CAPACITY = 16`, `HOT_SPILL_TARGET
= 12`, no third constant, no `top_up`.

**D3 — Keep the fork; do not re-merge `book` and `coin_book`.** Once multicoin is
BigVector-keyed, the storage rationale for the fork disappears and the two files look
90% alike. They still differ in matching semantics, price scaling and fee plumbing,
and `f9d3398` forked deliberately. Re-merging is a separate project with its own risk;
it should not ride along with this one. Note it in the module docs as follow-up.

**D4 — Accept the error-surface change.** Cancel / modify / lookup of an absent id
will abort inside `big_vector` with `ENotFound` instead of `book::EBookOrderNotFound`,
exactly as the coin side accepted in `f9d3398`. `EBookOrderNotFound` and its public
accessor become dead and should be removed; nothing outside `book.move` references
them today.

**D5 — Order ids change value as well as width.** Per-side counters seeded from
`START_BID_ORDER_ID` / `START_ASK_ORDER_ID`, encoded as `(side << 127) | (price << 64)
| seq`. Bid ids land near 2^127. Any consumer that assumed a small ascending serial
breaks — see §5.

---

## 3. Phase 1 — widen the id to `u128` (flat book unchanged)

A standalone, reviewable commit that compiles and passes the full suite with the
vector book still in place. It de-risks phase 2 by separating a mechanical type change
from a behavioural one.

| File | Change |
| --- | --- |
| `sources/book/order.move` | `order_id: u64` → `u128`, accessor |
| `sources/book/order_info.move` | `order_id`, `maker_order_id`, `taker_order_id`, `set_order_id`, `to_order`, every emitted event struct |
| `sources/book/fill.move` | `maker_order_id` |
| `sources/state/account.move` | `open_orders: VecSet<u64>` → `VecSet<u128>`, `add_order`, `remove_order` |
| `sources/state/state.move` | `RefundedFee.order_id`, `refund_order_id`, the two call sites at 249 / 318 |
| `sources/vault/vault.move` | refund/fee event `order_id` (multicoin-only module; coin uses `coin_vault`) |
| `sources/vault/multicoin_vault.move` | `order_id` at :501 |
| `sources/multicoin_pool.move` | public signatures: `modify_order`, `cancel_order`, `cancel_orders`, `get_order`, `get_orders`, `account_open_orders` |
| `sources/book/book.move` | `next_order_id`, `find_insert_position`, `cancel_order`, `modify_order`, `get_order` parameter types |

Tests: almost free. Only three hardcoded numeric ids exist in the whole multicoin
surface (`order_info.move:253`, `book.move:68`, `pool_test_utils.move:2088` — and the
last is an equality between two ids). Every other test flows the id opaquely out of
`order_info.order_id()`, so widening propagates without touching values.

Cost of the phase: mechanical, roughly 150 changed lines, one afternoon including the
suite run.

Note the one real storage consequence: `Account.open_orders` doubles in width, and
`MAX_OPEN_ORDERS` is 100, so a fully-loaded account record grows ~800 bytes. That is
paid on every transaction that rewrites the account, and it is *not* in any figure in
the whitepaper.

---

## 4. Phase 2 — replace the book

### 4.1 `sources/book/book.move`

Replace wholesale with the variant, modified:

- delete `REFILL_ENABLED`, `HOT_REFILL_FLOOR`, `top_up`, and the `HOT_CAPACITY == 0`
  branch in `inject_limit_order`;
- keep the overflow gate `if (len <= HOT_CAPACITY) return;` at the head of `spill` —
  this is what separates a working buffer from one pinned at `HOT_SPILL_TARGET`
  (whitepaper F5 / §4.5, and see §6 below);
- keep the unidirectional admission branch: with an empty buffer over a populated
  tree, read the tree's best key and admit inline only if the new order beats it;
- restore the prose comments the experiment stripped from `get_quantity_out`;
- replace `find_order_index` and `EBookOrderNotFound` with nothing;
- `shape()` and `drop_for_testing` stay as `#[test_only]`.

New public-package surface for callers: `hot_bids`, `hot_asks`, `side_length`,
`cursor_begin` / `cursor_next` / `cursor_borrow` / `cursor_is_null`.

### 4.2 `sources/multicoin_pool.move`

- `bids()` / `asks()` change return type to `&BigVector<Order>` and acquire the same
  "this is not the whole side" doc warning `pool.move:1471` carries;
- add a `book()` accessor for callers that must walk a side across both stores
  (mirrors `pool.move:1485`);
- everything else is unchanged — the pool calls only `create_order`, `cancel_order`,
  `get_order`, `mid_price`, `get_level2_range_and_ticks` and `price_scaling`, and all
  six keep their shapes.

### 4.3 Second-order consequences to check, not assume

- **Pool creation cost.** Two `BigVector`s means two extra `UID`s per pool at
  creation. Against 100,000+ pools this is a one-off per pool but it is real, and it
  is not in the whitepaper's per-operation figures. Measure it on localnet.
- **`mid_price` and `get_level2_range_and_ticks`** become cursor walks. The coin fork
  *deleted* both (`2ed4a51`) rather than port them; multicoin still exposes them
  publicly, so they must work. They are the two functions in the variant least
  exercised by the experiment — the campaign measured placement, cancel, modify and
  takers, not level2 — so they need their own tests.
- **`cancel_orders` / cancel-all** iterate `open_orders`; with the side carried in
  bit 127 the routing gets simpler, not harder.
- **No multicoin order-query module exists.** `order_query.move` was deleted in
  `f9d3398` and replaced by `coin_order_query.move` for coin pools only. Paginated
  order queries over a deep multicoin book are now possible for the first time, and
  the coin module is a 106-line template. Optional scope — decide explicitly rather
  than by omission.

Cost of the phase: ~700 lines in, ~450 out, plus ~60 lines across the pool. The code
is written; the work is review, the deletions, and the two under-tested views.

---

## 5. Phase 3 — tests

| File | Disposition |
| --- | --- |
| `tests/book/book_tests.move` | 9 of 11 tests are `find_order_index` tests and die with the helper. The two fee tests (`bid_dry_run_reserves_exactly_the_fee_that_settles`, `a_round_trip_costs_exactly_two_taker_fees`) stay and should pass unmodified. |
| `tests/book/book_vector_workload_tests.move` | Its stated purpose — "whether multicoin's `vector<Order>` should adopt BigVector too, rather than settling it by analogy" — is answered. Retarget it to the new book so it stays comparable to `coin_book_workload_tests`, or retire it. |
| **new** `tests/book/book_hot_buffer_tests.move` | Port of the in-flight `coin_book_hot_buffer_tests.move` (397 lines). Must cover the C16u-specific paths the coin version cannot: admission over a populated tree with an empty buffer, and the absence of any refill. |
| **new** `tests/book/book_invariant_tests.move` | Randomised churn asserting the invariant after every operation, plus depth tests past one leaf slice and past one tree level. |
| **new** `tests/book/book_priority_tests.move` | Demotion-freedom: no surviving order may move behind an order it previously ranked ahead of. |
| **new** `tests/book/book_edge_case_tests.move` | Boundaries for insertion, cancellation, filling and the views. |
| `tests/multicoin_pool/*` (~12k lines) | Expected to pass unmodified once phase 1 lands, because ids flow opaquely. Any failure here is a real semantic difference and should be treated as a finding, not a test fix. |
| `tests/gas_benchmarks.move` | Add the multicoin book to the benchmark set alongside the coin one. |

**The invariant that needs property tests.** Whitepaper §8 names it: *every order in a
side's buffer is better-priced than every order in that side's tree*. Under C16u it is
maintained by exactly three places — `inject_limit_order`'s admission test, `spill`,
and the empty-buffer-over-populated-tree branch — and nothing repairs it if one is
wrong, because there is no refill to shuffle orders back into place. A randomised
place/cancel/sweep workload asserting full-side price ordering after every operation
is worth more here than any number of example tests.

Also assert the seam explicitly: a sweep that crosses from buffer into tree fills in
exact price order (the experiment verified this by hand on a 20-order sweep over a
40-deep book; it should be a test).

---

## 6. A defect in the in-flight coin work, found while reading

`coin_book::spill` (working tree, `sources/coin_book/coin_book.move:544`) has no
overflow gate:

```move
fun spill(self: &mut Book, is_bid: bool) {
    let mut len = ...;
    while (len > HOT_SPILL_TARGET) { ... }
}
```

It is called unconditionally at the end of `inject_limit_order`, so the buffer is
pinned at `HOT_SPILL_TARGET = 12` and **every** top-of-book placement above depth 12
pays a tree insert — the buffer never uses the four slots of headroom between 12 and
`HOT_CAPACITY = 16`. This is precisely the defect the experiment brief flagged at
§4.5 and that every measured variant avoided by gating on `len > HOT_CAPACITY`; the
whitepaper records it as "an ungated spill made the cache pay both structures' costs."

One-line fix (`if (len <= HOT_CAPACITY) return;`), independent of this plan, and worth
landing on the coin side before the multicoin port copies the shape.

---

## 7. Phase 4 — validation, and the redeploy assumption

**Re-measure, do not assume.** The whitepaper's numbers came from a vendored variant
on a purpose-built harness. The scripts are in
[`multicoin-book-storage-experiment-data/scripts/`](multicoin-book-storage-experiment-data/scripts/)
and re-runnable: `bootstrap.py` then `driver.py steady <variant>`. Run the real
package through `driver.py` at depths 5 / 30 / 150 / 300 and check the burned-fee
figures land on the C16u column. Anything materially off means the port differs from
what was measured.

**Confirm the ceiling is gone** by driving one book past ~3,000 orders per side —
the exact run that killed the flat vector at 2,973.

**No migration path, by decision.** Existing multicoin pools are abandoned rather than
upgraded. The `Book` layout change makes in-place migration impossible anyway without
work nobody is doing: `Versioned` is used here purely as a version *assertion* —
`load_inner` checks `allowed_versions`, and no migration function exists anywhere in
the package — and a migration could not run in one transaction regardless, because an
old pool holds up to 256 KB of inline book and rewriting that object once is exactly
what Sui's size limit refuses. It would need a bounded, resumable drain of the old
`vector<Order>` into the new book, with the pool halted meanwhile.

Two consequences follow, and both are in the plan's favour:

- **Whatever seeds testnet has to be re-run** against the new package — registry,
  quote approvals, fee classes, pools. Nothing carries over.
- **Order ids cut over cleanly.** There is no mapping from an old `u64` serial to a
  new encoded `u128` key, and now none is needed: no consumer has to translate
  historical ids, because there is no continuous history across the cut. This is why
  §8 can tell the indexer owners "clean cut, no backfill" rather than asking them for
  a translation table.

---

## 8. Phase 5 — off-chain

Smaller than §8 of the whitepaper feared, at least for the SDK.

- **SDK** (`/Users/michaelhahn/books/temp/sdk`): `orderId` is already `bigint | string`
  end to end. The changes are `tx.pure.u64` → `tx.pure.u128` at `transactions.ts:312`
  and `:362` and `armature/trading.ts:227`, the two `BigInt(params.orderId)` sites in
  `TriexClient.ts`, the doc comment at `transactions.ts:292` that says "(u64)", and
  the multicoin branches of `schemas.ts` (`v.order_id`) — the coin branch already
  reads `encodedOrderId`. Roughly a dozen lines.
- **MCP server / app-api / indexer** (not in this repo): every multicoin order-id
  column, cache key and event decoder widens, and **stored ids from before the cut are
  not translatable** — there is no mapping from an old serial to a new encoded key.
  Plan a clean cut at redeploy rather than a backfill.
- **Event schemas.** `OrderPlaced`, `OrderCanceled`, `OrderModified`, `OrderFilled`
  and the vault refund events all change field width. Anything consuming them by BCS
  layout breaks.

This is the part of the job with the least visibility from inside this repo and should
be scoped by whoever owns those consumers before phase 2 lands.

---

## 9. Sequencing and sizing

| Phase | Work | Status |
| --- | --- | --- |
| 0 | Confirm the redeploy decision (§7); take D1–D5 | **Done** — D1–D5 taken as written; fresh redeploy confirmed, no version migration |
| 1 | `u128` widening, flat book intact, suite green | **Done** |
| 2 | Book replacement + pool accessors | **Done** |
| 3 | Test rework + invariant property tests | **Done** |
| 4 | Localnet re-measurement + ceiling run | **Done** — see [multicoin-c16u-verification.md](multicoin-c16u-verification.md) |
| 5 | SDK, then the consumers outside this repo | Open — needs their owners |
| §6 | Coin-side spill gate | **Done** |

### 9.1 What landed

Suite: **778 → 848 passing**, no failures at any step. Every file touched is
`prettier-move` clean, and the package's warning count is unchanged (two
pre-existing warnings, neither in new code).

**Phase 1** widened the order id to `u128` across `book/{order,order_info,fill}`,
`state/{account,state}`, `vault/{vault,multicoin_vault}`, `multicoin_pool` and the
book's own signatures, with the flat vector still in place — a commit that compiles
and passes on its own. Test fallout was as predicted: eleven sites across five
files, all signature widenings, no changed values.

**Phase 2** replaced [book.move](../../packages/triex/sources/book/book.move)
with the variant, minus the experiment levers, and gave `multicoin_pool` the
`BigVector` return types plus a `book()` accessor. `EBookOrderNotFound` is gone;
the two multicoin tests that expected it now expect `big_vector::ENotFound`, the
same change the coin side took in `f9d3398`.

**Phase 3**:
- `book_tests.move` lost its 9 `find_order_index` tests with the helper; the two
  dry-run fee tests pass unmodified.
- `book_vector_workload_tests.move` → `book_workload_tests.move`, retargeted and
  its doc rewritten. One assertion had to move from `bids().length()` to
  `side_length(true)` — the only place in the suite where the tree-is-not-the-side
  distinction actually bit.
- **new** `book_hot_buffer_tests.move`, 13 tests. Not a copy of the coin module:
  `assert_invariant` drops the coin side's "a stocked tree implies a stocked
  buffer" assertion, which is false under one-way spill, and the sweep test asserts
  the buffer is left *empty* rather than refilled. Three tests have no coin
  counterpart — the gated-spill occupancy assertion, the empty-buffer-over-populated-tree
  admission split, and the rebuild-without-touching-the-tree case.
- **new** `book_invariant_tests.move`, 7 tests: four randomised place/cancel/sweep
  workloads over different price bands and seeds, re-checking the full invariant
  after every operation on both sides, plus depth tests for both build orders and
  one that pushes past 1,024 so the tree gains a level.
- **new** `book_priority_tests.move`, 16 tests — see §9.3.
- **new** `book_edge_case_tests.move`, 43 tests — see §9.4.

Two test expectations were wrong on first run and were corrected — a hand-computed
buffer occupancy after 300 improving placements, and a 1,100-order build that
exhausted the test harness's memory on held events before the book did anything.
Neither was a defect in the book.

### 9.2 Phase 4 result

The shipped package reproduces the measured C16u design: **161 of 165 comparable
transactions bit-identical** to the whitepaper's reference run, nine of ten
per-trade depth costs agreeing to the MIST, and the four that differ all transient
first-touch effects — two of them the *reference* being the outlier. One book was
driven to 3,300 orders per side (the flat vector stopped at 2,973) with per-order
storage flat to 0.998 across a twelve-fold depth range, and it still placed,
cancelled and filled 30-order sweeps there at 3.70M MIST of computation against the
flat vector's 82.9M at depth 300. Full write-up in
[multicoin-c16u-verification.md](multicoin-c16u-verification.md).

### 9.3 What is not done

- **Nothing outside this repo has been touched** — SDK, MCP server, indexer.
- **No multicoin order-query module** was added (§4.3). Still an open decision.

Phases 1–4 are on the order of a week of focused work for someone who already knows
this code, and the dominant term is phase 3, not phase 2. Phase 5 is unestimated here
and is the same open question the whitepaper flagged as "the dominant cost of the
recommendation."

The independent one-line coin fix in §6 should go first, on its own.

### 9.3 Demotion-freedom

**Demotion** — a resting order moving behind an order it previously ranked ahead of
— is the one guarantee a market cannot quietly lose, because a book that silently
re-queues is still internally consistent, still passes every ordering assertion, and
is still broken. It gets its own module.

The structural argument is short: read order is key order, and a key is assigned once
in `create_order` and never rewritten — `order::modify` touches `quantity` alone and
`generate_fill` touches `filled_quantity` and `status`. `book_priority_tests` does not
rely on that argument. `assert_no_demotion` compares a side before and after an
operation and requires every survivor to hold its relative place, in either direction
(a promotion for one order is a demotion for whatever it passed), and the named tests
aim it at each mechanism that touches position:

| Mechanism | Covered by |
| --- | --- |
| Time priority within a price level, **both sides** | `same_price_queues_by_arrival_on_both_sides`, `same_price_queue_behind_a_full_buffer_keeps_arrival_order` |
| Equal-price arrival never displacing the earlier order | `equal_price_never_displaces_the_earlier_order` |
| Placement, improving and scattered | `improving_placements_never_demote`, `scattered_placements_never_demote` |
| Spill evicting only the buffer's worst | `spill_evicts_only_the_worst_of_the_buffer` |
| Cancel at **every** position 0–39 in turn | `cancelling_any_position_never_demotes` |
| Cancel draining the buffer in front of a stocked tree | `draining_the_buffer_by_cancel_never_demotes` |
| Partial fill not re-queuing the maker | `partial_fill_keeps_the_maker_at_the_head` |
| Sweeps at **every** depth 1–24 | `sweeps_consume_from_the_front_only` |
| Sweep stopping mid-order | `sweep_stopping_mid_order_leaves_it_in_place` |
| Expired makers retired around live ones | `retiring_expired_makers_never_demotes` |
| Modify-down not re-queuing — the classic demotion bug | `modify_down_never_requeues` (every order on a 25-deep level, in turn) |
| Modify not promoting out of the tree either | `modify_in_the_tree_does_not_promote`, `modifying_the_best_order_keeps_it_best` |
| All of it interleaved | `mixed_workload_never_demotes` (300 random ops, checked after each) |

Both sides get every case rather than one standing in for the other. The sequence
counters run in *opposite* directions (`START_BID_ORDER_ID` descends from `u64::MAX`,
`START_ASK_ORDER_ID` ascends from 1) precisely so "older is better" holds under one
comparison on both sides, and an error there would reverse time priority on exactly
one of them.

**One property this surfaced that was not previously written down:** at a single
price level the buffer holds exactly **one** order and everything behind it goes to
the tree, because no newcomer at an equal price can beat the buffer's resident. A
market where every participant quotes the same price gets no benefit from the inline
buffer at all. That is correct behaviour, it is the extreme of the whitepaper's
"worst-price-last" build (§B.2), and it is now asserted rather than assumed.

### 9.4 Edge cases

`book_edge_case_tests` takes the boundaries. Where a case has a natural "one before,
exactly on, one after" shape, all three are tested rather than the middle one
standing in for its neighbours.

- **Insertion** — empty side on both sides; `HOT_CAPACITY − 1`, exactly, and `+ 1`;
  an order behind a full buffer (which must *not* spill it); admission against the
  tree's best at −1, exactly, and +1; `MIN_PRICE` and `MAX_PRICE` key encoding, with
  the side flag asserted to keep the two key spaces disjoint; both sides loaded at
  once; POST_ONLY crossing and at-the-touch; FOK unfillable and exactly fillable;
  IOC remainder not injected; a crossing limit resting its remainder under the key it
  was allocated *before* matching.
- **Cancellation** — the only order; the four seam positions; back-to-front drain;
  and four abort paths: empty book, same order twice, an order a fill already
  retired, and a well-formed id for the wrong side.
- **Filling** — an empty side; stopping exactly on the seam, one short, one past;
  price-limited rather than quantity-limited; the `MAX_FILLS` cap, asserting the
  untouched tail; expiry at exactly the timestamp (still live) and one tick later
  (retired unfilled); a side of nothing but expired orders; `cancel_maker` retiring
  the maker and filling behind it; `cancel_taker` aborting.
- **Modify** — same quantity, below filled quantity, absent id.
- **Views** — `mid_price` one-sided, and skipping expired orders when the live best
  is behind the seam; level 2 aggregating levels across the seam, its tick cap, and a
  range window that starts inside the side; zero ticks and inverted range; both
  `get_quantity_out` input errors; the dry run agreeing with an identical real taker
  across the seam; and an empty book returning the input rather than aborting.

Two expectations were wrong on first run in this batch too, both mine: a
same-price test that assumed a full buffer (see §9.3), and a price-extremes test that
placed bids opposite `MIN_PRICE`/`MAX_PRICE` asks, where they crossed instead of
resting. Neither was a defect in the book.

