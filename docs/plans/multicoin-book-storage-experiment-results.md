# Multicoin order book storage: experiment results

Companion to [multicoin-book-storage-experiment.md](multicoin-book-storage-experiment.md)
(the pre-registered brief). The full argument, constraints and decision rationale
are written up as a whitepaper in
[multicoin-book-storage-whitepaper.md](multicoin-book-storage-whitepaper.md); this
document is the measurement record behind it.
Run 2026-09-16 against a local Sui network (sui 1.73.1, `--force-regenesis`,
protocol package-size override per §6.2 of the brief). Raw per-transaction data,
driver, and the variant book source are in
[multicoin-book-storage-experiment-data/](multicoin-book-storage-experiment-data/).

**Every figure below is read from real transaction effects on a local network,
through the full production path** — `trading_account::generate_proof_as_owner`
+ `multicoin_pool::place_limit_order` / `cancel_order` / `modify_order` in one
PTB per measured operation, exactly the §6.1 setup sequence (CRED quote,
`bootstrap_quote`, `create_pool_admin`, shared trading accounts, maker rotation
under `MAX_OPEN_ORDERS`). Move unit-test gas was not used for anything.

---

## Verdict

**Winner: BigVector + small hot buffer (16/12/8) with unidirectional spill —
"C16u".** It is design C's geometry carrying design D's mode-switch property
and the unidirectional refinement proposed for D2: orders spill from the inline
buffer to the tree on genuine overflow and *never travel back*; matching and
cancels drain the tree in place, and new placements repopulate the buffer
naturally because they beat the tree's best key.

C16u ranks **first under all three weightings** — transaction-weighted,
revenue-weighted, and a future-shifted distribution where deep markets dominate
— so per §7 the decision does not depend on resolving the weighting question.

Burned fee per executed trade (taker fill + 5 maker place/cancel cycles), MIST:

| weighting | A (flat) | B (bare tree) | C16 | **C16u** | D32 | D64 | D64u |
|---|---|---|---|---|---|---|---|
| transaction-weighted | 2,988,025 | 3,193,951 | 2,869,899 | **2,824,653** | 3,018,587 | 3,132,079 | 3,117,109 |
| revenue-weighted | 11,297,941 | 4,188,991 | 3,932,983 | **3,914,461** | 4,778,057 | 5,928,522 | 5,945,706 |
| future-shifted | 13,350,843 | 4,325,890 | 4,095,435 | **4,075,011** | 4,986,472 | 6,319,649 | 6,339,484 |

Total trader cost (computation + burned fee, 10% of trades as 30-order sweeps)
puts C16u first under revenue and future-shifted weighting. Under **transaction**
weighting on that measure the status quo is cheapest — 21,916,569 vs C16u's
22,139,397, a 1.0% margin. The mechanism is finding 3's fixed computation
premium: +40,000 MIST/op, +440,000 per trade, which at shallow depth exceeds
everything the tree saves on storage, and transaction weighting puts half its
mass at depth 5. It does not move the decision: C16u leads
the same measure under both other weightings, and A is disqualified by the §7
gates regardless of any average.

The status quo (A) fails both §7 gates: at depth 300 a trade costs 5.6× C16u
and grows without bound, and its depth ceiling — **2,973 orders per side**,
measured, `MoveObjectTooBig` at 256 KB — is reachable by markets we expect to
have. A market that deep stops accepting orders entirely; the tree variants
were driven to 3,240 orders and beyond without incident.

---

## Variants measured

All variants built from the same base (cycle-7 + in-flight hot-buffer work);
they differ **only** in `triex::book` storage. B–D variants carry the encoded
`u128` order-id migration (`(price << 64) | seq`, bid side keyed so higher is
better), per-side sequence counters, and `BigVector` slices (geometry 16/64
from `constants`). The hot-buffer implementation gates `spill()` on genuine
overflow (`len > HOT_CAPACITY`), avoiding the §4.5 defect, and spills down to
`HOT_SPILL_TARGET`.

| variant | design | CAP | spill-to | refill floor | refill |
|---|---|---|---|---|---|
| A | flat `vector<Order>` (status quo) | — | — | — | — |
| B | bare BigVector | 0 | — | — | — |
| C16 | + fixed hot buffer | 16 | 12 | 8 | bidirectional |
| C16u | + hot buffer, unidirectional | 16 | 12 | — | none |
| D32 | mode-switch, mid CAP | 32 | 16 | 8 | bidirectional |
| D64 | mode-switch, brief's §D.1 sizing | 64 | 30 | 8 | bidirectional |
| D64u | as D64, unidirectional | 64 | 30 | — | none |

Depths 0–300 per side; construction (300 single-tx placements, each a new best
price — worst case for cache designs) measured separately from steady state
(seeded book, then top-of-book churn, placements/cancels at ~28 from mid,
modify-down, and IOC taker sweeps of 1/10/30), per §5.4.

---

## The eight findings

### 1. The flat vector fails exactly where the revenue is (§1.2 confirmed)

Steady-state burned fee per top-of-book placement, MIST:

| depth | A | B | C16 | C16u |
|---|---|---|---|---|
| 5 | 191,976 | 238,564 | 209,760 | 209,760 |
| 20 | 299,136 | 315,324 | 315,805 | 299,440 |
| 30 | 370,576 | 344,204 | 311,600 | 311,600 |
| 60 | 584,896 | 363,964 | 348,080 | 364,445 |
| 150 | 1,191,452 | 417,164 | 384,560 | 384,560 |
| 300 | 2,171,852 | 400,444 | 400,925 | 384,560 |

A grows at **~6,710 MIST per resting order** (least-squares over depths 5-300;
local slopes 6,536-7,144 — the multicoin analogue of the coin stack's ~6,827) and every operation on the book pays it — cancel,
modify and taker costs are within a few percent of placement at every depth.
The tree variants are flat from depth ~30 onward. At depth 300 the flat vector
burns 5.4× more per operation; extrapolated to its ceiling (~2,973) it would
burn ~21M MIST per operation — 55× the tree — right before the market stops
accepting orders at all.

### 2. The crossover is at depth ≈ 20–25 (coin-stack prior: ~26 — confirmed)

Per-op crossovers vs A: cancel_top ~20, taker_1 ~20, place_top ~22–25,
VWATC-per-trade ~20. Below that the flat vector's zero indirection wins; the
tree variants' tail tax at depth 5 is +9% per op *on burned fee* (u128 ids,
BigVector roots, slightly larger `Order`). Including computation the true tail
tax is **~58k MIST/op, +3.0% of total cost**, of which the computation premium
is 69%; the total-cost crossover therefore sits slightly later, near depth 25–30.

### 3. Computation DOES differ — a fixed tree premium plus A's unbounded scans (§4.3 partly refuted, §8.7 answered)

Corrected after re-examination. Sui's computation bucket here is **10,000 MIST —
0.57% of an operation, not the ~3% the brief assumed** — and computation is
effectively deterministic (300 of 308 repeated cells bit-identical), so
differences of 40,000 MIST are four buckets wide and are measurements, not noise.
Three real effects:

- **Fixed tree premium: +40,000 MIST/op (+2.3%)**, reproduced on all 8 operation
  types at depths 5–20 — the `u128` key, BigVector root access and hot-buffer
  scan. Per modelled trade (11 ops) that is +440,000 MIST.
- **A's computation grows with depth; the trees' does not.** Fitted over 300
  construction placements: A 209 MIST per resting order, C16u 21, D64 75 (a
  bigger inline buffer is a bigger thing to scan — an independent argument for a
  small cache). Per trade the effects cancel near depth 100–150; beyond it A is
  worse, by 4% at 150 and 30% at 300.
- **Sweeps: A's O(depth × fills) removal scan dominates the whole transaction.**
  30-order sweep at depth 300 costs A **82.9M MIST** vs 2.57–3.45M for every
  keyed variant (~$0.29 at $3.50/SUI); already visible at 10 fills (5.34M vs
  ~2.0M). Any keyed variant fixes this for free.

Net effect on the decision: away from sweeps these are tens of thousands of MIST
against storage differences of hundreds of thousands, so storage still decides
the design — but computation is what makes A cheapest on the transaction-weighted
total, and on sweeps it is the largest number in the experiment.

### 4. A fixed-size *small* buffer beats the brief's D sizing (§D.1.4 refuted)

The brief hypothesised `FLOOR` should be sized to interaction depth (~28–30).
Measured, that is wrong: every inline order costs ~7.1k MIST *on every
operation* (the pool object is rewritten whole), while the benefit — keeping
churn off the tree — saturates at a dozen orders. D64/D64u (30–64 inline) pay
598–678k per churn op at depth 150+ vs C16/C16u's 384–400k; in the 45–64 band
they are worse than the flat vector itself. D32 sits in between, dominated
everywhere. **Optimal: CAP 16, spill-to 12.** "A hot cache is only an asset
while it is small" is the multicoin restatement of prior finding 4.

Large-CAP mode-switch designs buy nothing at the tail either: a book of ≤16
orders under C16/C16u is *already* entirely inline with an empty tree — design
D's "flat-vector mode below CAP" property at CAP=16.

**Revised by phase 2.** The *direction* holds and gets stronger — the rank grid
shows D64u's cheapest operation (546,592 burned, a buffer hit at depth 2,048) is
1.56× C16u's most expensive one (350,436, a tree write) and 2.12× the bare
tree's 257,564, at every rank and every size. But the grid also shows the
16-order buffer earning roughly *nothing* on churn rather than a positive
margin: it saves one slice write worth 89,604 MIST at rank 1 and its 12–16
inline orders cost 92,872 to rewrite on every operation, so the bare tree is
level with C16u at rank 1 and cheaper at every deeper rank. C16u's margin over B
is on sweeps (finding 5) and construction (finding 8), not churn. The accurate
statement is **a small buffer is free on churn and valuable on matching**; the
composites in the verdict table appeared to credit a churn benefit that does not
survive being resolved per-rank. See
[multicoin-book-storage-position-cost-data.md](multicoin-book-storage-position-cost-data.md).

### 5. Unidirectional spill wins — the D2 hypothesis is right, at C16 geometry

Refill-on-drain (`top_up`) makes every taker sweep that empties the buffer pay
tree *removals* to repopulate it, and the repopulated buffer re-spills on the
next placements. Disabling refill entirely:

Taker sweep burned fee, C16 (bidirectional) vs C16u (unidirectional), MIST:

| depth | taker_10 C16 | taker_10 C16u | taker_30 C16 | taker_30 C16u |
|---|---|---|---|---|
| 45 | 810,008 | 467,476 (−42%) | 838,204 | 810,008 |
| 100 | 771,856 | 424,916 (−45%) | 1,062,936 | 969,684 |
| 300 | 841,776 | 449,236 (−47%) | 1,024,632 | 931,380 |

Churn costs are identical (refill never triggered there), construction is
identical, and nothing degrades after a sweep: the next maker placements beat
the tree's best key and land inline, restoring the buffer without any tree
traffic. The one structural cost — when the buffer is empty and the tree is
not, a placement pays one dynamic-field *read* to compare against the tree's
best key — is invisible in the data (reads are priced as computation, which
stayed flat; prior finding 3 held).

### 6. The migration cliff needs no amortisation (§8.4 answered)

Worst single construction transaction: C16u 692k, D64 991k MIST burned — a
one-off smaller than **half of one routine placement** on a 300-deep flat
vector (2.13M). Gross storage (gas budget) stayed ordinary. Spill batches of
4 (CAP 16 → 12) amortise naturally; no smoothing mechanism is warranted.

### 7. The ceiling is real and measured (§8.1 answered)

A stops accepting orders at **2,973 per side** (pool object 256,083 bytes >
256,000 max). This is ~15× the deepest market band the brief models (>300 =
0.1% of markets) — far, but reachable by the exact market the exchange most
wants: the largest one. The tree variants have no ceiling; D64u was driven to
3,240 orders per side and placed/filled normally (648k burn per placement,
~3.3× cheaper than A's cost at its own ceiling, with computation flat).

### 8. Construction favors the small buffer too (§5.4 separation held)

Cumulative burn building one side from empty to 300, each placement a new best
price (the cache's worst case): A 347.6M; **C16/C16u 106.5M**; B 108.0M;
D32 118.8M; D64/D64u 160.0M. Even in its adversarial regime the small buffer
matches the bare tree, because spill batches amortise; the large buffers pay
their inline bytes on all 300 rewrites.

---

## Phase 2 — rank × book-size cost grid (run 2026-09-16, same localnet)

A second campaign resolves the two dimensions the first one conflates —
*how deep is the book* and *how far into it does the operation reach* — and
pushes book size to 2,048 per side. Four designs (A, B, C16u, D64u), five size
classes (8 / 48 / 128 / 512 / 2,048), eighteen ranks, place-and-cancel at each,
three repetitions, one transaction per measured operation, two build orders:
**2,448 measured transactions**. Nothing crosses, so this isolates insert and
cancel from matching entirely. Full grid, both build orders and all repetitions:
[multicoin-book-storage-position-cost-data.md](multicoin-book-storage-position-cost-data.md).

Seeded asks use a price stride of 10 so a probe can be placed at any rank without
colliding with a seeded price; rank 1 is a new best ask. Absolute MIST levels are
not comparable with the phase-1 tables (fresh pool and account objects) — slopes,
ratios and shapes are, and where the two overlap they agree: 6,536 vs 6,710 MIST
per standing order on burned fee, 203 vs 209 on computation, 7,144 per inline order.

### New: buffer occupancy is path-dependent

An order enters the hot buffer only if it beats the buffer's worst resident. A book
built by successively *better* quotes therefore ends with the buffer holding the best
12–16 orders; a book built outward from one anchor quote, each quote worse than the
last, sends everything to the tree and never grows the buffer past its first member.
Both are real paths and they differ by ~85k MIST/op, so the grid is run twice.
The primary run is best-price-last (the shape a contested two-sided book settles
into); figures below are that run. This refines §8.5's "depth stickiness" question:
there is no oscillating mode boundary, but there *is* a build-order dependence, and
it is a level effect rather than a cliff.

### Top of book (rank 1) as the book deepens

Burned fee for one insert, MIST:

| depth | A | B | **C16u** | D64u |
|---|---|---|---|---|
| 8 (tiny) | 208,544 | 257,564 | **225,112** | 225,112 |
| 48 (small) | 469,984 | 257,564 | **260,832** | 510,872 |
| 128 (medium) | 992,940 | 257,564 | **260,832** | 582,312 |
| 512 (large) | 3,527,312 | 257,564 | **253,688** | 575,168 |
| 2,048 (xl) | 13,542,060 | 257,564 | **260,832** | 546,592 |

Net storage for a cancel — the flat vector's refund becomes a charge past ~depth 85:

| depth | A | B | **C16u** | D64u |
|---|---|---|---|---|
| 8 (tiny) | −498,712 | −690,460 | **−602,528** | −602,528 |
| 48 (small) | −237,272 | −690,460 | **−566,808** | −316,768 |
| 128 (medium) | +285,684 | −690,460 | **−566,808** | −245,328 |
| 512 (large) | +2,795,508 | −690,460 | **−573,952** | −252,472 |
| 2,048 (xl) | +12,834,804 | −690,460 | **−566,808** | −281,048 |

Computation for the insert:

| depth | A | B | **C16u** | D64u |
|---|---|---|---|---|
| 8 (tiny) | 1,720,000 | 1,760,000 | **1,760,000** | 1,760,000 |
| 48 (small) | 1,720,000 | 1,760,000 | **1,760,000** | 1,760,000 |
| 128 (medium) | 1,740,000 | 1,760,000 | **1,760,000** | 1,770,000 |
| 512 (large) | 1,820,000 | 1,760,000 | **1,760,000** | 1,770,000 |
| 2,048 (xl) | 2,130,000 | 1,760,000 | **1,760,000** | 1,760,000 |

Permanent cost of one place+cancel round trip (`computation + burned`, both ops):

| depth | A | B | **C16u** | D64u | A ÷ C16u |
|---|---|---|---|---|---|
| 8 (tiny) | 3,844,232 | 4,024,704 | **3,958,584** | 3,958,584 | 0.97× |
| 48 (small) | 4,367,112 | 4,024,704 | **4,030,024** | 4,530,104 | 1.08× |
| 128 (medium) | 5,453,024 | 4,024,704 | **4,030,024** | 4,692,984 | 1.35× |
| 512 (large) | 10,657,220 | 4,024,704 | **4,015,736** | 4,678,696 | 2.65× |
| 2,048 (xl) | 31,331,264 | 4,034,704 | **4,030,024** | 4,601,544 | 7.77× |

### Rank sweep inside the 2,048-deep book

Burned fee for an insert at rank `n`, MIST. The step in each buffered column is the
rank at which the order stops landing inline; the point above each step is the insert
that lands exactly at the edge and pays the spill in the same transaction.

| rank | A | B | **C16u** | D64u |
|---|---|---|---|---|
| 1 | 13,542,060 | 257,564 | **260,832** | 546,592 |
| 4 | 13,542,060 | 257,564 | **260,832** | 546,592 |
| 8 | 13,542,060 | 257,564 | **260,832** | 546,592 |
| 16 | 13,542,060 | 257,564 | **375,516** | 546,592 |
| 32 | 13,542,060 | 257,564 | **350,436** | 546,592 |
| 48 | 13,542,060 | 257,564 | **350,436** | 546,592 |
| 64 | 13,542,060 | 257,564 | **350,436** | 661,276 |
| 80 | 13,542,060 | 257,564 | **350,436** | 636,196 |
| 100 | 13,542,060 | 257,564 | **350,436** | 636,196 |
| 128 | 13,542,060 | 257,564 | **350,436** | 636,196 |
| 156 | 13,542,060 | 257,564 | **350,436** | 636,196 |
| 256 | 13,542,060 | 257,564 | **350,436** | 636,196 |
| 300 | 13,542,060 | 257,564 | **350,436** | 636,196 |
| 512 | 13,542,060 | 257,564 | **350,436** | 636,196 |
| 816 | 13,542,060 | 257,564 | **350,436** | 636,196 |
| 1,024 | 13,542,060 | 257,564 | **350,436** | 636,196 |
| 1,516 | 13,542,060 | 282,112 | **350,436** | 636,196 |
| 2,048 | 13,566,608 | 257,564 | **350,436** | 636,196 |

### What phase 2 establishes

1. **Depth is the only axis that matters, and only for A.** 6,536 MIST per standing
   order on burned fee, confirmed nearly 7× further out than phase 1. Every keyed
   design is flat — most cells bit-identical across a 256-fold change in book size.
   Round-trip ratio A ÷ C16u: 0.97× at depth 8, **7.77× at 2,048**.
2. **Rank is nearly free.** Rank 1 → 2,048 in a 2,048-deep flat book moves burned fee
   0.2%. For keyed designs rank matters in exactly one place: the buffer boundary,
   worth 89,604 MIST/op for C16u.
3. **A's cancel flips sign.** −498,712 MIST at depth 8 (refund) → **+12,834,804** at
   2,048 (charge). Past ~depth 85 a maker cannot withdraw a quote without paying for
   the depth behind it. Keyed designs refund at every depth.
4. **Away from matching this is a storage decision.** A's insert computation rises 203
   MIST/order (1.72M → 2.13M); keyed designs flat at 1.76M, 2.3% dearer at depth 8 and
   17.4% cheaper at 2,048. Storage crosses between depth 8 and 48, computation near
   100–150. Finding 3(c)'s blow-up belongs to the sweep path, not single-order ops.
5. **Finding 4 revised** (see above): the small buffer is free on churn, not positive;
   the large buffer is bad at every rank and size.
6. **The spill at the buffer edge is cheap** — C16u rank-16 insert 375,516 vs 350,436
   ordinary, a 7% surcharge on one rank. Confirms finding 6 pointwise.
7. **A's one constant-time path doesn't help it.** `cancel_order` fast-paths the
   best price with `pop_back`, so rank-1 cancel costs 2,110,000 MIST against
   2,560,000 at rank 4 — a 450,000 discontinuity, and the only real structure in
   the computation grid. Beyond rank 1 the cancel curve drifts down and the insert
   curve drifts up as the O(n) scan and the O(n) shift trade off. All ±10% on an
   axis where the same operation pays 13.5M of storage.

The verdict is unchanged. C16u remains first or within 0.2% of first at every book
size, has no ceiling, and wins sweeps outright; A is cheapest in exactly one class
(tiny, by 2.9% — 114,352 MIST per round trip) and loses monotonically from depth 48 up.

## Where each design is optimal (per use-case)

| use-case | cheapest measured | note |
|---|---|---|
| Tail (0–5 orders, trades rarely) | A, by ~3.0%/op total | ~58k MIST/op: ~18k burned storage + ~40k computation |
| Typical (≤20) | A ≈ C16u | inside the crossover band; differences < 5% |
| Mid band (30–60) | C16/C16u | A already 20–65% worse; D64 worse than A here |
| Deep (100–300) | C16u | 5.6× cheaper than A per trade; unidirectional wins sweeps |
| Very deep (>300 → 2,973) | C16u/B | A approaches ceiling then **halts** |
| Sweep-heavy flow | C16u | refill-free; beats even bare B |

One design must serve all rows (§2); C16u is first or within noise of first in
every row except the tail, where the gap is ~18k MIST (~$0.00006) per
operation on markets that transact least. That is the price of removing an
outage cliff and a 5.6× per-trade premium from the markets that earn half the
revenue — and of not blocking the high-volume markets the system intends to
grow into (the future-shifted weighting, where C16u's margin is widest).

## Costs of adopting it (not measured here, acknowledged per §7)

- The breaking `u128` order-id migration: every stored order id,
  `modify_order` / `cancel_order` / `cancel_orders` / `get_order`, fill/state/
  account/vault plumbing, events, and downstream consumers. The experiment's
  conversion (in the data directory) touched 8 source files mechanically; the
  ecosystem cost (indexers, SDK, app-api) is the real bill.
- The tail pays ~3.0% more per operation in total cost (~58k MIST: ~18k burned
  storage + ~40k computation), permanently. Most of it is computation, so it
  cannot be tuned away by resizing the buffer — it is the cost of the `u128` key
  and the indirection itself.
- `place_28`-style placements behind the buffer pay a tree write the flat
  vector doesn't (+60–130k MIST) — already counted in the composites above.

## Answers to §8's open questions

1. **Ceiling**: 2,973 orders/side.
2. **Crossover**: ~20–25 end-to-end (coin prior ~26 — shape transferred).
3. **Computation axis**: not flat. A fixed +2.3%/op tree premium, plus A's
   O(n) growth (209 vs 21 MIST/resting-order) crossing over near depth 100–150,
   plus A's O(depth × fills) sweep scan (82.9M at depth 300 / 30 fills). Storage
   still decides the design, but "purely a storage optimisation" is too strong:
   the computation premium is what wins A the transaction-weighted total.
4. **CAP/FLOOR**: 16/12, refill disabled. Migration cliff ≤ ~1M one-off; no
   amortisation needed.
5. **Depth stickiness**: not testable locally; C16u makes it moot — there is
   no mode boundary whose oscillation costs anything (spill batches are 4
   orders, refill doesn't exist).
6. **Band transit**: moot for the same reason.
7. **Removal scan**: yes, measurable, large (see finding 3); fixed by any
   keyed variant.

## Method notes and confounds controlled

- All variants from one base; only `book.move` (+ the id-width plumbing it
  forces) differs. A shared localnet, one funding address, sequential runs.
- Absolute MIST figures are at localnet reference gas price (1,000) and
  mainnet storage pricing constants; ratios and crossovers are what transfer.
- Computation quantises to 10,000 MIST (0.57%/op) and is effectively
  deterministic, so the computation effects above are resolved measurements. The
  8 of 308 repeated cells that varied were first-cycle spill transactions — a
  real regime, not scatter (D32 at depth 100: 1.97M then 1.77M, 1.77M).
- Steady-state books seeded best-price-last so cache variants settle into
  their real resting shape (buffer = best 12–16); taker-consumed orders were
  restored between measurements; maker accounts rotated under
  `MAX_OPEN_ORDERS = 100`.
- Weighting vectors (documented in `scripts/analyze.py`) encode §2's
  distribution: deep ≤1% of transactions, ~50% of revenue on 150+; the
  future-shifted vector moves volume share toward deep markets per the
  expectation that today's zero high-volume markets is not the end state.
  C16u ranks first under all three, so the conclusion does not hinge on the
  exact vector.
- Known driver hazards from §6.2 all reproduced and were worked around
  (stale CLI chain-id cache, vendored multicoin, registry's one-pool-per-
  (collection, asset, quote) rule handled by unregistering between scenarios).
