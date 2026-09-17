# Interaction Depth

**Storage economics for a heterogeneous on-chain order book, measured end-to-end on Sui**

Triex · Protocol Engineering · Technical Report TR-2026-09

| | |
| --- | --- |
| Subject | `triex::book` as used by `triex::multicoin_pool` |
| Experiment run | 16 September 2026 · local Sui network, sui 1.73.1 · ~4,800 measured transactions |
| Status | Concluded — recommendation adopted for review |
| Pre-registration | [multicoin-book-storage-experiment.md](multicoin-book-storage-experiment.md) (§-refs throughout refer to it) |
| Data & scripts | [multicoin-book-storage-experiment-data/](multicoin-book-storage-experiment-data/) |
| Result summary | [multicoin-book-storage-experiment-results.md](multicoin-book-storage-experiment-results.md) |

---

## Abstract

Sui charges a small, permanently burned storage fee against the *entire* object a
transaction rewrites, not against the bytes that changed. An order book held as a
flat inline vector therefore pays for its whole depth on every placement, cancel
and fill, while a tree-structured book pays only for the slices it touches.
Because the protocol operates 100,000+ books whose depths span three orders of
magnitude, one storage design must serve both regimes.

We built six storage variants differing only in book layout, deployed each to a
local network, and measured real transaction effects across depths 0–300 —
separating book construction from steady-state churn, and reporting every result
under both a transaction-weighted and a revenue-weighted denominator.

The flat vector's cost grows at **6,710 MIST per resting order** and terminates in
a hard failure at **2,973 orders per side**, where the pool object exceeds Sui's
256 KB limit and the market stops accepting orders. We recommend a **BigVector
keyed by encoded `u128` order ids, fronted by a 16-order inline buffer that spills
to the tree and never refills from it**. It burns the least of any design under all
three weightings tested, has no depth ceiling, and its worst migration transaction
costs less than one routine placement on a 300-deep flat book. It concedes one
thing, measured and reported here: a fixed ~2.3% computation premium per operation,
which makes the status quo marginally cheaper on the shallowest books.

---

## 1. The cost shape that drives everything

A Sui transaction is charged `storageCost` for every object it writes, sized by the
object's new bytes, and refunded `storageRebate` for the version it replaced. Most
of the charge returns. What does not return is `nonRefundableStorageFee` — roughly
1% — and it is levied against the **whole rewritten object**, irrespective of how
many bytes actually changed.

This produces a cost shape with no analogue in conventional storage engines. In an
ordinary database, touching one row of a million-row table costs one row's worth of
write. Here, touching one order in a book held inline costs a fraction of a percent
of *the entire book* — and it costs it again on the next transaction, and the next.

### 1.1 Book depth is not interaction depth

The distinction that organises this entire report:

- **Book depth** — the number of orders resting on a side. A flat inline vector's
  cost tracks *this*: it rewrites everything, whether the trade touched one order
  or thirty.
- **Interaction depth** — the number of orders an operation actually reaches.
  Production telemetry puts 99% of placements within 28 ticks of mid, and most
  fills complete within ~30 orders. A tree's cost tracks *this*.

On a 300-order book where trades land within ~30 of mid, a flat vector pays for
roughly ten times the orders it needed. The gap between these two numbers is the
entire economic case for changing the storage layout, and every measurement below
is designed to size it.

### 1.2 Why this is not merely an efficiency question

The flat vector's weakness and the exchange's income sit in the same place. Cost
grows linearly with book depth and carries a hard depth ceiling; both bite hardest
exactly where trades are most valuable. A transaction-weighted average cannot
surface this, because deep books are ~1% of transactions — which is precisely why
§2.1 of the brief required two denominators, and why its §7 decision procedure
refuses to simply take the transaction-weighted winner.

There is a second, forward-looking reason. Today the protocol has *no* markets in
the highest-volume class. The intent is that storage cost should not be the reason
such markets never form. A design chosen purely on today's transaction mix
optimises for the distribution the protocol is trying to outgrow.

---

## 2. Design constraints

These are the operating conditions the design must satisfy. They are the
experiment's weighting inputs: if any are materially wrong, the conclusion moves.

| Constraint | Value |
| --- | --- |
| Breadth of pools | 100,000+ order books exist |
| The long tail | Vast majority hold 0–5 standing orders, trade rarely |
| Typical active market | < 20 standing orders per side (~95% of markets) |
| Mid band | 30–60 standing orders (~3–5%) |
| Deep | > 150 standing orders (~1%) |
| Very deep | > 300 standing orders (~0.1%) |
| Where trades land | 99% of orders within 28 of mid; most fills within ~30 |
| Deep-book share of *transactions* | ~1% or less |
| Deep-book share of *revenue* | ~50% earned on books of depth 150+ |
| Per-account order cap | `MAX_OPEN_ORDERS` = 100 per pool |
| Object size limit | 256,000 bytes (Sui maximum) |

### 2.1 Two denominators, and why both are mandatory

This distribution caused repeated reversals of judgement during earlier analysis,
for one structural reason: **gas is paid per transaction, but revenue is earned per
trade, and the two concentrate in different places.** Weight by transactions and
shallow books dominate — that is where the protocol's total gas bill is set. Weight
by revenue and deep books dominate — that is where per-trade cost becomes a
competitiveness question on the trades that fund the exchange.

A design good under only one weighting is not good enough. We therefore report
every composite under three vectors: transaction share, revenue share, and a
*future-shifted* vector in which the high-volume deep markets the protocol intends
to enable carry most of the volume. A design that wins without needing the
weighting question resolved is worth more than a marginally cheaper design that
depends on getting it right.

### 2.2 The ceiling is a different kind of constraint

A flat vector holds the whole book inline, so a sufficiently deep market pushes the
pool object past Sui's maximum object size and the book stops accepting new orders.
This is not a cost that scales down with the tail's weight — it is a cliff. Its
location had never been measured. Locating it was a required output, because a
design whose depth limit is reachable by markets we expect to have is disqualified
regardless of its fee numbers.

---

## 3. Candidate designs

All candidates are storage-layout choices for one side of the book. None changes
matching semantics or price-time priority.

**A — Flat vector (status quo).** Sorted `vector<Order>` inline in the pool object,
best price at the end. Cheapest structure at low depth — nothing indirect to pay
for. Cost grows linearly and without bound; carries the depth ceiling. Cancel away
from the top is an O(n) scan, and the post-match removal pass scans the whole side
per fill, giving O(depth × fills) per crossing trade.

**B — Bare BigVector.** Orders in dynamic-field slices, keyed by an encoded `u128`
id. Cost tracks interaction depth; no ceiling. Pays a dynamic-field write on
*every* operation, including on a 5-order book.

**C — BigVector + fixed hot buffer.** As B, plus the best N orders of each side
held inline. Operations at the top of book touch no dynamic field. The buffer sits
in the pool object permanently, so it enlarges every rewrite whether or not the
operation used it.

**D — BigVector + shrinking hot cache (mode switch).** As C, but while a side holds
fewer than `CAP` orders it *is* the whole book — a flat vector with no dynamic
field in existence. On exceeding `CAP`, the furthest orders spill into the tree,
leaving a floor of `FLOOR` inline. Intent: flat-vector economics below `CAP`, tree
economics above it, no ceiling ever.

### 3.1 The unidirectional refinement

Designs C and D as originally specified move orders in both directions: they spill
to the tree on overflow and *refill* from the tree when the buffer drains. The
refinement tested here removes the return path entirely — orders spill from buffer
to tree and never travel back. Matching and cancels drain the tree in place, and
the buffer repopulates naturally, because any newly posted order at a competitive
price beats the tree's best key and is admitted inline. These variants carry a `u`
suffix. §6 F6 shows this is the single largest improvement found.

### 3.2 A prerequisite common to B, C and D

`BigVector` is keyed, but multicoin order ids are opaque ascending `u64` serials
whose priority is positional. A tree keyed on that id would sort by insertion time,
not price. All tree variants therefore require encoded `u128` keys —
`(price << 64) | seq`, with the bid side complemented so higher is better — which
is a breaking change to every stored order id and to the order-management API. §8
accounts for this cost, which appears nowhere in the gas measurements.

### Variants measured

| Variant | Design | CAP | spill to | refill floor | Return path |
| --- | --- | --- | --- | --- | --- |
| A | flat `vector<Order>` (status quo) | — | — | — | n/a |
| B | bare BigVector | 0 | — | — | n/a |
| C16 | + fixed hot buffer | 16 | 12 | 8 | bidirectional |
| **C16u** | **+ hot buffer, spill-only** | **16** | **12** | — | **none** |
| D32 | mode switch, mid CAP | 32 | 16 | 8 | bidirectional |
| D64 | mode switch, brief's §D.1 sizing | 64 | 30 | 8 | bidirectional |
| D64u | as D64, spill-only | 64 | 30 | — | none |

All seven built from one base commit; the only differences are `book.move` and the
id-width plumbing the `u128` key forces. Every hot-buffer variant gates spill on
genuine overflow (`len > CAP`), avoiding the defect noted in §4.5 of the brief,
where an ungated spill made the cache pay both structures' costs.

---

## 4. Method

### 4.1 Why Move unit tests cannot answer this

`sui move test` and the repository's gas-benchmark harness measure Move VM abstract
gas — instruction and memory cost — and are **blind to storage entirely**. Since
the burned storage fee is the primary metric, unit-test benchmarks cannot address
the question at all. They were used for correctness only. Every number in this
report comes from the effects of a real transaction on a running node.

### 4.2 Deployment

For each variant, in sequence on one local network (`sui start --force-regenesis
--with-faucet`, package-size protocol override to admit the larger builds, which
does not alter storage pricing): publish `token`, then a vendored `multicoin`, then
the variant; create and share a multicoin `Collection`; approve CRED as quote and
`bootstrap_quote` its fee classes; create the pool through `create_pool_admin` to
avoid the creation fee; create, fund and share `TradingAccount`s, rotating them so
no account exceeds `MAX_OPEN_ORDERS`.

### 4.3 One operation, one transaction

Each measured operation is its own programmable transaction, containing exactly a
`generate_proof_as_owner` call and the operation under test — for example
`multicoin_pool::place_limit_order`. Batching placements would rewrite the pool
object once and measure nothing. Gas is read directly from that transaction's
effects: `nonRefundableStorageFee` (primary), `computationCost` (secondary,
quantised by Sui into 10,000-MIST buckets — 0.57% of a typical operation here, and
effectively deterministic in practice), and gross `storageCost` / `storageRebate`,
which set the budget a trader must supply even though most of it returns.

Measured operations: placement at top of book and at ~28 from mid; cancel in both
positions; cancel of a deep resting order; modify-down; and crossing IOC takers
filling 1, 10 and 30 orders. Depths: 0, 5, 10, 15, 20, 30, 45, 60, 100, 150, 300
orders per side, plus a run that deepens one book until placement fails.

### 4.4 Construction and steady state are reported separately

These give opposite answers for cache-bearing designs, and conflating them produced
misleading conclusions in earlier work. *Construction* builds a book from empty,
each placement a new best price — the worst case for a cache, which overflows
continuously. *Steady state* takes a book already at depth *d* and churns at the
top, which is what live markets do and what carries the weight in the decision.
Steady-state books were seeded best-price-last so that cache variants rest in the
shape a live deep book actually settles into; orders consumed by taker sweeps were
restored between measurements.

### 4.5 Confound control

The only clean comparison is between variants differing solely in book storage. All
seven were built from the same base commit with the same state layer and fee
architecture, published to the same network, and driven by the same script from one
funding address, strictly sequentially.

---

## 5. Headline result

Cost of an executed trade — one taker fill plus the five maker place/cancel cycles
that surround it — as a function of book depth, in MIST of burned storage fee:

| depth | A (flat) | B (bare tree) | **C16u** |
| --- | --- | --- | --- |
| 5 | 2,225,660 | 2,750,288 | 2,371,124 |
| 10 | 2,700,407 | 3,276,968 | 2,880,020 |
| 15 | 3,011,500 | 3,885,475 | 3,339,820 |
| 20 | 3,404,420 | 3,569,568 | 3,413,844 |
| 30 | 4,190,260 | 3,912,328 | 3,547,604 |
| 45 | 5,369,020 | 4,021,008 | 3,748,244 |
| 60 | 6,547,780 | 4,129,688 | 4,030,711 |
| 100 | 9,575,620 | 4,433,688 | 4,252,884 |
| 150 | 13,201,656 | 4,678,408 | 4,313,684 |
| 300 | 23,967,816 | 4,458,008 | **4,277,204** |

| Headline | Value |
| --- | --- |
| Flat-vector ceiling | **2,973** orders/side, then the market halts |
| Flat-vector slope | **6,710** MIST burned per resting order, every op |
| Crossover depth | **≈20–25** orders/side (coin-stack prior: ~26) |
| Deep-book saving | **5.6×** cheaper per trade at depth 300 |

The flat vector rises from 2.23M MIST at depth 5 to **23.97M at depth 300**, a
10.8× increase over a 60× increase in depth, and it does not stop rising. C16u
moves from 2.37M to 4.28M over the same span — 1.8× — and is essentially flat
beyond depth 100. At depth 300 the status quo costs **5.6× more per trade**;
extrapolated to its own ceiling it would cost roughly fifty times more, in the
moment before the market stops functioning.

Gross storage follows the same shape and matters for a different reason: at depth
300 a placement on the flat vector requires 217.9M MIST of `storageCost` against
39.3M for C16u. Nearly all is rebated, but the trader must still supply it as gas
budget, so the flat vector raises the working capital a market maker needs by 5.5×
on exactly the books where quoting matters most.

---

## 6. Findings

**F1. The flat vector fails where the revenue is. (§1.2 confirmed.)**
Every operation pays 6,710 MIST per resting order — least-squares across depths
5–300; local slopes range 6,536–7,144, and the figure closely matches the ~6,827
measured previously on the coin stack, so the shape transfers between stacks.
Cancel, modify and taker costs sit within a few percent of placement at every
depth, because all four rewrite the same object. The tree variants' slope above
depth 30 is 207–294 MIST per order: flat, for practical purposes.

**F2. The depth ceiling is real, and it is a cliff. (§8.1 answered.)**
Driving one book deeper until placement failed located the limit at **2,973 orders
per side**: the pool object reached 256,083 bytes against a 256,000-byte maximum,
and every further placement aborts with `MoveObjectTooBig`. The market does not
become expensive — it stops accepting orders. For contrast, the unidirectional tree
variant was driven to 3,240 orders per side and placed and filled normally, at 648k
MIST per placement with flat computation. There is no ceiling to find.

**F3. The crossover sits at depth ≈20–25. (Coin-stack prior of ~26 confirmed.)**
Below it the flat vector's absence of indirection wins; above it the trees win, and
the gap widens monotonically. Per-operation crossovers: cancel ~20, taker ~20,
placement ~22–25. On burned fee the tree tail tax at depth 5 is about 9% per
operation — roughly 18k MIST — attributable to the wider `u128` ids and the empty
BigVector roots. Counting computation as well (F4), the true tail tax is **~58k MIST
per operation, or +3.0% of its total cost**, of which the computation premium is
69%; the total-cost crossover accordingly sits a little later, near depth 25–30.

**F4. Computation does differ between designs — by a small fixed premium, and by
an unbounded term on the flat vector. (§4.3 partly refuted, §8.7 answered.)**
The instrument is finer than the brief assumed: Sui quantises computation into
**10,000-MIST buckets — 0.57% of a typical operation, not ~3%** — and the figures
are effectively deterministic, with 300 of 308 repeated measurements bit-identical.
At that resolution three effects separate cleanly, and the claim that storage
layout leaves computation untouched does not survive.

*(a) A fixed tree premium of +40,000 MIST per operation (+2.3%)*, reproduced on all
eight operation types at depths 5–20. It is the price of the wider `u128` key, the
`BigVector` root access and the hot-buffer scan. Per modelled trade — eleven
operations — it is +440,000 MIST, and it is the larger half of the tail tax (§8).

*(b) The flat vector's computation grows with depth; the trees' does not.* Fitted
over 300 construction placements, A rises at **209 MIST per resting order** against
21 for C16u — the O(n) scans in `cancel_order`, `modify_order` and `get_order`. Per
trade the two effects cancel near depth 100–150: the trees cost 2.3% more at depth
5, 1.1% more at 60, then 4.0% *less* at 150 and 30.0% less at 300.

*(c) On multi-fill sweeps, computation becomes the dominant cost of the whole
transaction — for the flat vector only.* Its O(depth × fills) removal scan costs
**82.9M MIST** on a 30-order sweep at depth 300, against 2.57–3.45M for every keyed
variant, and the effect is already plain at ten fills (5.34M against ~2.0M). Any
keyed variant eliminates it as a side effect of keyed removal.

Computation per 10-order sweep (MIST):

| depth | A | B | **C16u** |
| --- | --- | --- | --- |
| 30 | 2,060,000 | 2,160,000 | 2,010,000 |
| 60 | 2,260,000 | 2,270,000 | 2,080,000 |
| 150 | 2,880,000 | 2,250,000 | **2,080,000** |
| 300 | 5,340,000 | 2,200,000 | **2,010,000** |

The practical consequence is narrower than the storage result: away from sweeps
these differences are tens of thousands of MIST against storage differences of
hundreds of thousands, so storage still decides the design. But computation is not
a non-axis — it is what makes the status quo cheapest on the transaction-weighted
total (§7.1), and on sweeps it is the largest single number in the experiment.

**F5. A small buffer beats a large one everywhere. (§D.1.4 of the brief refuted.)**
The brief reasoned that `FLOOR` should be sized to interaction depth, ~28–30
orders. The measurements contradict this. Each inline order costs ~7.1k MIST on
*every* operation, because the pool object is rewritten whole, while the benefit —
keeping churn off the tree — saturates at about a dozen orders. D64 pays 598–678k
per churn operation at depth 150+ against C16u's 385–393k, and in the 45–64 band it
is worse than the flat vector it was meant to improve on. Computation agrees
independently: fitted over the construction runs, the 64-order buffer costs 75 MIST
of computation per resting order against C16u's 21, because a larger inline vector
is a larger thing to scan. The correct reading of the earlier finding is sharper
than the brief's: a hot cache is an asset only while it is *small*.

Placement cost by buffer capacity (MIST burned, top-of-book placement):

| depth | 0 (bare tree) | **16 (C16u)** | 32 (D32) | 64 (D64) | A (flat) |
| --- | --- | --- | --- | --- | --- |
| 30 | 344,204 | **311,600** | 418,760 | 418,760 | 370,576 |
| 150 | 417,164 | **384,560** | 498,864 | 598,880 | 1,191,452 |
| 300 | 400,444 | **384,560** | 477,432 | 670,320 | 2,171,852 |

**F6. Unidirectional spill is the largest single improvement found.**
Refill-on-drain makes every sweep that empties the buffer pay tree removals to
repopulate it, and the repopulated buffer then re-spills on the following
placements — paying twice for one sweep. Removing the return path cuts 10-order
sweep cost by 42–47% with no compensating loss: churn costs are identical,
construction costs are bit-for-bit identical, and nothing degrades afterwards,
because fresh quotes beat the tree's best key and rebuild the buffer inline with no
tree traffic at all. The one structural cost — a placement into an empty buffer
above a populated tree must read the tree's best key to preserve the ordering
invariant — is invisible in the data, since reads price as computation and
computation did not move.

10-order crossing taker (MIST burned):

| depth | C16 (refills) | **C16u (spill-only)** | saving | B (bare tree) |
| --- | --- | --- | --- | --- |
| 45 | 810,008 | **467,476** | −42% | 673,588 |
| 60 | 823,536 | **485,716** | −41% | 687,116 |
| 100 | 771,856 | **424,916** | −45% | 635,436 |
| 300 | 841,776 | **449,236** | −47% | 705,356 |

**F7. The migration cliff needs no amortisation. (§8.4 answered.)**
The brief flagged that the transaction crossing `CAP` pays the whole migration at
once, and suggested amortising it. Measured, the worst single construction
transaction across all variants was 991k MIST (D64) and 692k for C16u — less than
one-third of a single routine placement on a 300-deep flat book (2.13M). Gross
storage stayed ordinary. With `CAP` 16 spilling to 12, the migration is four tree
inserts; no smoothing mechanism is warranted.

**F8. Construction favours the small buffer too. (§5.4 separation maintained.)**
Building one side from empty to 300, each placement a new best price — the cache's
adversarial case — cumulative burn was: flat vector 347.6M MIST; C16/C16u
**106.5M**; bare tree 108.0M; D32 118.8M; D64 160.0M. Even in the regime designed
to punish it, the small buffer matches the bare tree, because spill batches
amortise, while the large buffers pay their inline bytes on all 300 rewrites.

---

## 7. Decision

### 7.1 Composites under all three weightings

Per-depth costs aggregated with three weight vectors: transaction share (deep books
~1%), revenue share (~50% on books 150+), and a future-shifted vector moving volume
toward the deep markets the protocol intends to enable. MIST per executed trade:

| Measure · weighting | A | B | C16 | **C16u** | D32 | D64 | D64u |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Burned fee · transaction | 2,988,025 | 3,193,951 | 2,869,899 | **2,824,653** | 3,018,587 | 3,132,079 | 3,117,109 |
| Burned fee · revenue | 11,297,941 | 4,188,991 | 3,932,983 | **3,914,461** | 4,778,057 | 5,928,522 | 5,945,706 |
| Burned fee · future-shifted | 13,350,843 | 4,325,890 | 4,095,435 | **4,075,011** | 4,986,472 | 6,319,649 | 6,339,484 |
| Total cost · transaction | **21,916,569** | 22,532,507 | 22,188,776 | 22,139,397 | 22,343,086 | 22,457,919 | 22,436,082 |
| Total cost · revenue | 32,725,881 | 23,823,497 | 23,484,565 | **23,421,275** | 24,382,521 | 25,473,012 | 25,474,234 |
| Total cost · future-shifted | 35,515,194 | 24,012,954 | 23,692,308 | **23,617,088** | 24,655,824 | 25,911,384 | 25,904,307 |

On burned fee — the permanently destroyed, design-sensitive part of the bill, and
the brief's primary metric — C16u is first under all three weightings. Per §7 of
the brief, "choose the design whose ranking is stable under both weightings," the
decision therefore does not require resolving the transaction-versus-revenue
question at all, which is the strongest form the result could take.

**One exception must be stated plainly.** On *total* cost under *transaction*
weighting, the status quo is cheapest: 21.92M MIST against C16u's 22.14M, a margin
of 1.0%. The mechanism is the tree's fixed computation premium from F4: +40,000 MIST
per operation, or +440,000 per modelled trade, which at shallow depth exceeds
everything the tree saves on storage. Transaction weighting places half its mass at
depth 5, where the tree is genuinely the more expensive design, so that average
reports it. This is not a dilution artefact and not noise — it is a real regime, and
a reader who weights shallow-book transactions above everything else should know the
status quo wins that particular average by one percent.

It does not change the recommendation, for three reasons. The premium is bounded and
small where it applies, while the flat vector's penalty above the crossover is
unbounded: by depth 300 the same total-cost measure favours C16u by 2.2×. The same
measure favours C16u under both other weightings. And the two gates below disqualify
the status quo independently of any average.

### 7.2 The two gates

The brief set two gates any design must clear before winning on a
transaction-weighted average, and applied them to the status quo specifically.

**Gate 1 — deep-market per-trade cost.** The flat vector costs 13.2M MIST per trade
at depth 150 and 24.0M at depth 300, against 4.31M and 4.28M for C16u. It is three
to six times more expensive at the point of sale on the books earning half the
revenue. *Failed.*

**Gate 2 — the ceiling.** 2,973 orders per side is roughly ten times the deepest
band the protocol currently models, but it is a hard stop, and it would be reached
first by the single largest and most valuable market. A market that stops accepting
orders is an outage, not a cost. *Failed.*

The status quo is therefore disqualified on its own terms, independent of the
averages.

### 7.3 Optimal design per use case

| Use case | Share of markets | Cheapest measured | Margin |
| --- | --- | --- | --- |
| Tail — 0–5 orders, trades rarely | vast majority | A | by ~6–9%/op (~18k MIST) over C16u |
| Typical — ≤20 orders | ~95% | A ≈ C16u | inside the crossover band, <5% apart |
| Mid band — 30–60 | ~3–5% | C16u | A is 20–65% worse; D64 worse than A here |
| **Deep — 100–300 (~50% of revenue)** | ~1% | **C16u** | 5.6× cheaper per trade than A |
| **Very deep — >300** | ~0.1%, growing | **C16u** | A halts at 2,973; C16u has no ceiling |
| **Sweep-heavy order flow** | — | **C16u** | 42–47% under C16; below bare tree too |
| Pure deep-sweep flow, no maker churn | negligible | D64u | 21% under C16u on 30-order sweeps only |

The final row is the one regime where a large cache wins: a 30-order sweep stays
entirely inside a 64-order buffer. It does not change the decision, because the same
buffer costs 74% more per churn operation and churn outnumbers sweeps by roughly ten
to one in any realistic flow — but it is the honest boundary of the recommendation.

### 7.4 Recommendation

> **BigVector keyed by encoded `u128` order ids, fronted by a 16-order inline hot
> buffer that spills to 12 on genuine overflow and never refills from the tree.**
>
> Parameters: `HOT_CAPACITY = 16`, `HOT_SPILL_TARGET = 12`, no refill path. Spill
> gated on `len > HOT_CAPACITY`. Tree geometry unchanged from `constants`
> (slice 16, fan-out 64).

Note what this design is, structurally. At `CAP` 16 a book of sixteen or fewer
orders is entirely inline with no dynamic field in existence — which is precisely
design D's "flat-vector mode below `CAP`" property, obtained at a cache size small
enough to be free. The mode switch the brief proposed is therefore realised, but at
16 rather than 64, and without the return path that made the switch expensive. The
designs did not need to be chosen between so much as correctly parameterised.

---

## 8. Costs and risks of adoption

The gas measurements above are one side of the ledger. These are the other, and none
of them appear in any figure in this report.

**The breaking `u128` order-id migration.** Every stored order id changes width and
meaning. Inside the package this reaches `modify_order`, `cancel_order`,
`cancel_orders`, `get_order`, the fill, state, account and vault plumbing, and every
emitted event. The experiment's own conversion touched eight source files
mechanically and compiled cleanly, so the in-package work is tractable and well
understood. The real bill is external: indexers, the SDK, app-api and any downstream
consumer that has persisted or parsed an order id. **This is the dominant cost of
the recommendation and it has not been estimated here.**

**A permanent tax on the long tail.** The markets that transact least pay about
**58k MIST more per operation** — +3.0% of its total cost — being ~18k of burned
storage and ~40k of computation (F4). That is on the order of $0.0002 at recent
prices. Multiplied across 100,000+ books it is real but small, and it is the price
of removing the ceiling. Note the composition: most of this tax is computation, so
it cannot be tuned away by resizing the buffer — it is the cost of the `u128` key
and the indirection itself.

**Placements behind the buffer.** An order resting outside the best 16 pays a tree
write the flat vector does not: +60–130k MIST. This is already counted in every
composite above, but it is worth naming, because it is the one routine operation
that gets unambiguously worse.

**Invariant surface.** The design rests on one invariant — every order in a side's
buffer is better-priced than every order in that side's tree — which the ordering of
buffer, spill and admission logic must maintain. Fill ordering across the
buffer/tree seam was verified during the run (a 20-order sweep on a 40-deep book
filled in exact price order), but this invariant is the natural focus for review and
property testing.

---

## 9. Threats to validity

**Local network, not mainnet.** Absolute MIST figures are at localnet reference gas
price with mainnet storage pricing constants. Ratios, crossovers and slopes are what
transfer; absolute costs should be re-derived at the live gas price.

**Modelled weight vectors.** The three weightings encode the brief's stated
distribution, not measured telemetry. The conclusion is robust to this because C16u
ranks first under all three on burned fee — including two that disagree sharply
about where volume sits — but the *size* of its margin does depend on the vector.

**Synthetic order flow.** Churn is modelled as five maker place/cancel cycles per
executed trade, with 10% of trades as 30-order sweeps. The ranking is insensitive to
this over any plausible range; only a flow that is almost entirely deep sweeps with
negligible maker churn reverses it in favour of a large cache (§7.3, final row).

**Depth stickiness untested.** The brief asked whether book depth is monotone in
practice, because designs with a large mode switch depend on it. That question is
unanswerable locally — it needs production history. It is also now moot: at `CAP` 16
with no refill there is no mode boundary whose oscillation costs anything, since a
spill is four orders and a refill does not exist. The recommendation is therefore
indifferent to the answer, which is a further argument for it.

**One run per configuration.** Storage fees are deterministic functions of object
size, so repetition adds nothing for the primary metric; the figures reproduced
exactly where measurements were repeated. Computation proved effectively
deterministic too — 300 of 308 repeated cells were bit-identical — and its
10,000-MIST bucket resolves differences down to 0.57%, so the computation effects in
F4 are measurements rather than noise. The eight cells that did vary were
first-cycle spill transactions, a real regime rather than scatter: at depth 100 the
first D32 placement paid 1.97M against 1.77M for the two that followed it.

---

## Appendix A — Measured data

Full per-operation, per-depth tables for all seven variants are in
[multicoin-book-storage-experiment-results.md](multicoin-book-storage-experiment-results.md)
and in machine-readable form at
[multicoin-book-storage-experiment-data/results/](multicoin-book-storage-experiment-data/results/)
(one JSON record per measured transaction, plus `analysis_final.txt` with every
table this report draws on).

Construction summary — 300 single-transaction placements, each a new best price:

| Measure | A | B | C16 | **C16u** | D32 | D64 | D64u |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Cumulative burn to depth 300 | 347,629,928 | 107,982,472 | 106,507,692 | **106,507,692** | 118,839,528 | 159,968,448 | 159,968,448 |
| Worst single transaction | 2,128,228 | 592,648 | 691,752 | **691,752** | 784,776 | 991,040 | 991,040 |
| Depth of worst transaction | 299 | 264 | 256 | 256 | 168 | 239 | 239 |

C16 and C16u are identical here, as are D64 and D64u: during pure construction the
buffer never drains, so the refill path is never exercised. That the pairs agree
bit-for-bit is a control confirming refill behaviour is the only difference between
them.

Computation on a single top-of-book placement (MIST) — the fixed tree premium and
its crossover:

| depth | A | B | C16 | **C16u** | D32 | D64 | D64u |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 5 | **1,720,000** | 1,760,000 | 1,760,000 | 1,760,000 | 1,760,000 | 1,760,000 | 1,760,000 |
| 20 | **1,720,000** | 1,760,000 | 1,760,000 | 1,760,000 | 1,760,000 | 1,760,000 | 1,760,000 |
| 60 | **1,740,000** | 1,770,000 | 1,770,000 | 1,770,000 | 1,770,000 | 1,780,000 | 1,780,000 |
| 150 | 1,760,000 | 1,780,000 | **1,770,000** | **1,770,000** | 1,780,000 | 1,780,000 | 1,780,000 |
| 300 | 1,790,000 | 1,780,000 | **1,770,000** | **1,770,000** | 1,780,000 | 1,780,000 | 1,780,000 |

Fitted computation slope over the 300 construction placements (MIST per resting
order): A 209.5 · B 22.4 · C16 21.3 · **C16u 21.7** · D32 27.9 · D64 75.2 ·
D64u 75.6.

Computation on a 30-order crossing taker (MIST) — the flat vector's removal scan:

| depth | A | B | C16 | C16u | D32 | D64 | D64u |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 30 | 2,980,000 | 3,180,000 | 2,840,000 | 2,760,000 | 2,560,000 | 2,560,000 | 2,560,000 |
| 60 | 4,680,000 | 3,630,000 | 3,540,000 | 3,170,000 | 3,310,000 | 2,820,000 | 2,820,000 |
| 150 | 11,900,000 | 3,720,000 | 3,660,000 | 3,170,000 | 3,200,000 | 2,810,000 | 2,810,000 |
| 300 | **82,900,000** | 3,450,000 | 3,390,000 | 2,980,000 | 3,140,000 | 2,570,000 | 2,570,000 |

---

## Appendix B — Cost curves by book size and rank

The campaign in §4–§7 samples book depth to 300 and holds the operation at top of
book or at rank 28. This appendix separates the two dimensions and pushes both much
further out: *how deep is the book*, and *how far into it does this operation reach*.
It answers directly what §7 answers only in aggregate — which layout is right for
which market — and it revises finding 5, because at this resolution the inline buffer
earns much less on churn than the weighted composites suggested.

Interactive versions of the five figures described here are in the HTML build of
this report (`multicoin-book-storage-experiment-data/whitepaper.html`, §11), with
a control to switch between the two build orders below. Figure 10 there is the
whole grid at once — twenty panels, one per design and book size, each plotting
the insert and its matching cancel against rank, with a metric switch for net
storage, burned fee and computation. Every cell is tabulated in
[multicoin-book-storage-position-cost-data.md](multicoin-book-storage-position-cost-data.md).

### B.1 Method

One pool per design. The ask side is grown in place through five size classes —
**tiny 8**, **small 48**, **medium 128**, **large 512**, **xl 2,048** standing orders
— and at every size a dedicated prober account places one limit order at rank `n` and
then cancels it, so the book returns to its exact prior shape. Seeded asks use a price
stride of 10, which leaves room to place a probe at *any* rank without colliding with a
seeded price. Rank 1 is top of book, a new best ask. Nothing crosses, so no fills are
involved: this isolates the insert and cancel paths from matching entirely.

Ranks probed: 1, 4, 8, 16, 32, 48, 64, 80, 100, 128, 156, 256, 300, 512, 816, 1,024,
1,516 and 2,048, at every class large enough to hold them — 51 cells per design, three
repetitions each, two operations per repetition, one transaction per operation.
**2,448 measured transactions** across the two build orders. Every number is read from a
transaction's own `effects.gasUsed`; the tabulated value is the median of repetitions 2
and 3, because the first touch of a given price by the prober carries one-off growth in
its account map.

Two metrics, both per operation:

- **net storage** — `storageCost − storageRebate`, the storage deposit that moves in this
  transaction. Positive on an insert, because the object written is larger than the one it
  replaces; negative on a cancel, because the deposit comes back. The two do not cancel
  exactly, and the residue is the burned fee.
- **computation** — `computationCost`. Never rebated, and quantised into 10,000-MIST
  buckets, so every difference below is a resolved measurement rather than an estimate.

### B.2 Two build orders, because buffer occupancy is path-dependent

A property this grid surfaced and the §4–§7 campaign could not: under unidirectional
spill the inline buffer's occupancy depends on the order in which the book was assembled,
and that difference is worth more than any parameter choice.

An order is admitted to the buffer only if it beats the buffer's worst resident. So if a
book is built by quoting successively *better* prices — the normal competitive case —
every new order enters the buffer and pushes the buffer's worst down into the tree, and
the buffer settles holding the best twelve to sixteen orders. But if a book is built
outward from one anchor quote, each new order successively *worse* than the last, then
nothing ever beats the buffer's worst, every order goes straight to the tree, and the
buffer never grows past its first member. Both are real market paths, so the grid is run
twice and the two runs bracket the behaviour of any cached design.

| build | buffer ends holding | C16u burn, rank 1 | C16u burn, rank 32 |
| --- | --- | --- | --- |
| **best-price-last** — each quote improves the best | the best 12–16 orders | 260,832 | 350,436 |
| **worst-price-last** — each quote sits behind the last | one order | 175,104 | 264,708 |

Depth 2,048, MIST. The direction is the one finding 5 predicts: inline orders are
rewritten on every operation, so a populated buffer costs about 85,000 MIST more per
operation and earns it back only where it keeps the operation out of a dynamic field.
Figures quoted below are the **best-price-last** build, the shape a contested two-sided
book settles into.

### B.3 Top of book as the book deepens (best-price-last)

Burned fee for one insert at rank 1, MIST:

| depth | A | B | **C16u** | D64u |
| --- | --- | --- | --- | --- |
| 8 (tiny) | 208,544 | 257,564 | **225,112** | 225,112 |
| 48 (small) | 469,984 | 257,564 | **260,832** | 510,872 |
| 128 (medium) | 992,940 | 257,564 | **260,832** | 582,312 |
| 512 (large) | 3,527,312 | 257,564 | **253,688** | 575,168 |
| 2,048 (xl) | 13,542,060 | 257,564 | **260,832** | 546,592 |

Net storage for the same insert (positive = deposit posted), MIST:

| depth | A | B | **C16u** | D64u |
| --- | --- | --- | --- | --- |
| 8 (tiny) | +922,944 | +1,215,164 | **+1,061,112** | +1,061,112 |
| 48 (small) | +1,184,384 | +1,215,164 | **+1,096,832** | +1,346,872 |
| 128 (medium) | +1,707,340 | +1,215,164 | **+1,096,832** | +1,418,312 |
| 512 (large) | +4,241,712 | +1,215,164 | **+1,089,688** | +1,411,168 |
| 2,048 (xl) | +14,256,460 | +1,215,164 | **+1,096,832** | +1,382,592 |

Net storage for a cancel at rank 1 — note the sign change on the flat vector, MIST:

| depth | A | B | **C16u** | D64u |
| --- | --- | --- | --- | --- |
| 8 (tiny) | −498,712 | −690,460 | **−602,528** | −602,528 |
| 48 (small) | −237,272 | −690,460 | **−566,808** | −316,768 |
| 128 (medium) | +285,684 | −690,460 | **−566,808** | −245,328 |
| 512 (large) | +2,795,508 | −690,460 | **−573,952** | −252,472 |
| 2,048 (xl) | +12,834,804 | −690,460 | **−566,808** | −281,048 |

Computation for the insert at rank 1, MIST:

| depth | A | B | **C16u** | D64u |
| --- | --- | --- | --- | --- |
| 8 (tiny) | 1,720,000 | 1,760,000 | **1,760,000** | 1,760,000 |
| 48 (small) | 1,720,000 | 1,760,000 | **1,760,000** | 1,760,000 |
| 128 (medium) | 1,740,000 | 1,760,000 | **1,760,000** | 1,770,000 |
| 512 (large) | 1,820,000 | 1,760,000 | **1,760,000** | 1,770,000 |
| 2,048 (xl) | 2,130,000 | 1,760,000 | **1,760,000** | 1,760,000 |

Fitted slopes over the five classes (MIST per standing order, rank-1 insert): burned fee — A **6,535.7**, B 0.0, C16u 6.6, D64u 59.2; computation — A **202.9**, all keyed designs 0.

### B.4 Rank sweep inside the xl book (depth 2,048, best-price-last)

Burned fee for an insert at rank `n`, MIST. The step in each buffered column is the
rank at which the order stops landing in the inline buffer.

| rank | A | B | **C16u** | D64u |
| --- | --- | --- | --- | --- |
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

### B.5 Permanent cost of one place-and-cancel round trip at top of book

`computation + burned`, summed over the insert and the cancel — the part of the bill
that never comes back, MIST.

**best-price-last build**

| depth | A | B | **C16u** | D64u | A ÷ C16u |
| --- | --- | --- | --- | --- | --- |
| 8 (tiny) | 3,844,232 | 4,024,704 | **3,958,584** | 3,958,584 | 0.97× |
| 48 (small) | 4,367,112 | 4,024,704 | **4,030,024** | 4,530,104 | 1.08× |
| 128 (medium) | 5,453,024 | 4,024,704 | **4,030,024** | 4,692,984 | 1.35× |
| 512 (large) | 10,657,220 | 4,024,704 | **4,015,736** | 4,678,696 | 2.65× |
| 2,048 (xl) | 31,331,264 | 4,034,704 | **4,030,024** | 4,601,544 | 7.77× |

**worst-price-last build**

| depth | A | B | **C16u** | D64u | A ÷ C16u |
| --- | --- | --- | --- | --- | --- |
| 8 (tiny) | 3,844,232 | 4,024,704 | **3,838,568** | 3,838,568 | 1.00× |
| 48 (small) | 4,367,112 | 4,024,704 | **3,838,568** | 3,838,568 | 1.14× |
| 128 (medium) | 5,453,024 | 4,024,704 | **3,838,568** | 3,838,568 | 1.42× |
| 512 (large) | 10,632,672 | 4,024,704 | **3,838,568** | 3,863,116 | 2.77× |
| 2,048 (xl) | 31,355,812 | 4,034,704 | **3,838,568** | 3,838,568 | 8.17× |

### B.6 What the curves show

1. **Book depth is the only thing that matters — and only for the flat vector.** A
   top-of-book insert into the flat vector burns 208,544 MIST at depth 8 and
   **13,542,060 at depth 2,048**: a straight line at 6,536 MIST per standing order, the
   same slope as the 6,710 fitted over depths 5–300 in finding 1, now confirmed nearly
   seven times further out. Fitted over the same five sizes the keyed designs come out at
   7, 0 and 59 MIST per order — flat, and flat in the strong sense that most of their
   cells are bit-identical across a 256-fold change in book size.

2. **Rank inside the book is nearly free information.** Moving the operation from rank 1
   to rank 2,048 of a 2,048-deep flat book changes its burned fee by 0.2%, because the
   object is rewritten whole wherever the order lands. For the keyed designs rank matters
   in exactly one place: the step where the order stops landing in the inline buffer and
   starts landing in a `BigVector` slice — between rank 8 and 32 for C16u, worth
   **89,604 MIST per operation**, and between 48 and 80 for D64u. Everywhere else both
   are flat. This is the practical content of *interaction depth*: a layout only has to
   be fast where orders actually land.

3. **In a flat book deeper than about 85 orders, cancelling stops being a refund and
   becomes a charge.** Net storage on a top-of-book cancel is −498,712 MIST at depth 8 —
   money back, which is what deleting an order ought to do — and **+12,834,804 at depth
   2,048**. The non-refundable slice is levied on the whole rewritten object, so past a
   certain depth it exceeds the deposit released by removing one order. Every keyed
   design refunds at every depth. On a deep flat book a maker cannot withdraw a quote
   without paying for all the depth standing behind it, which turns quoting into a
   one-way ratchet.

4. **Computation has the same shape an order of magnitude smaller, so away from matching
   this is a storage decision.** The flat vector's insert computation rises from 1.72M to
   2.13M MIST between depth 8 and 2,048 — 203 MIST per standing order, matching the 209
   fitted in finding 3 — while the keyed designs hold flat at 1.76M. Against storage
   differences of millions these are differences of hundreds of thousands: the keyed
   designs are 2.3% more expensive on computation at depth 8 and 17.4% cheaper at depth
   2,048, crossing near depth 100–150, while storage crosses between depth 8 and 48. The
   computation blow-up of finding 3(c) is a property of the multi-fill sweep path, not of
   single-order operations.

5. **Revision to finding 5: on churn alone the 16-order buffer is close to cost-neutral,
   not positive.** At rank 1 the buffer saves a slice write worth 89,604 MIST — and the
   twelve to sixteen inline orders it holds cost 92,872 MIST to rewrite, on *every*
   operation including the ones that never touch them. The two almost exactly cancel: at
   depth 2,048 the bare tree burns 257,564 per top-of-book insert against C16u's 260,832,
   and at every deeper rank the bare tree is *cheaper*, 257,564 against 350,436. Per
   inline order that tax is 7,144 MIST — the same ~7.1k finding 5 measured independently,
   so the grid confirms the mechanism and then shows that the benefit it was supposed to
   buy is, for pure insert and cancel traffic, approximately zero.

   This does not move §7's decision, and it is worth being precise about why. C16u's
   margin over the bare tree was never on churn: it is on sweeps, where refill-free
   draining cuts a ten-order taker by 42–47% (finding 6), and on construction, where
   spill batching beats it (finding 8). What the grid removes is a churn benefit the
   weighted composites appeared to credit but which does not survive being resolved
   per-rank. The correct statement is that a small buffer is *free* on churn and valuable
   on matching.

6. **A large buffer is unambiguously bad, at every rank and every size.** Finding 5
   refuted the brief's §D.1.4 sizing using weighted composites; the grid shows it
   pointwise, which is stronger. D64u's *cheapest* operation — a buffer hit — burns
   546,592 MIST at depth 2,048, which is 1.56× C16u's *most expensive* one, a tree write
   at 350,436, and 2.12× the bare tree's 257,564. Thirty inline orders are rewritten on
   every operation whether or not it touches them, and the extra eighteen ranks of
   coverage never repay that. There is no rank and no book size in the grid where the
   64-order buffer is the better choice.

7. **The buffer boundary carries a spill transaction, and it is cheap.** Inserting exactly
   at the buffer's edge pushes it over capacity and pays the spill in the same
   transaction: C16u's rank-16 insert burns 375,516 MIST against 350,436 for an ordinary
   tree write, and D64u's rank-64 insert 661,276 against 636,196 — a 7% and 4% surcharge
   on one rank. That is the migration cost finding 7 declined to amortise, now visible as
   a single point on a curve rather than as a maximum over a construction run.

8. **The flat vector does have one O(1) operation, and it buys nothing.** On
   computation, row A of the matrix is the only place in the grid with real
   structure. Cancelling at rank 1 of the 2,048-deep book costs 2,110,000 MIST
   against 2,560,000 at rank 4 — a 450,000 discontinuity — because
   `cancel_order` carries an explicit fast path that `pop_back`s the best price
   in constant time rather than scanning for it. Past that rank the cancel curve
   declines mildly (2,560,000 → 2,360,000 at rank 2,048) while the insert curve
   rises mildly (2,130,000 → 2,310,000): the O(n) position scan and the O(n)
   element shift trade off in opposite directions as the operation moves deeper.
   All of it is ±10% on a quantity where the same operation is paying 13.5M MIST
   of *storage*. A genuine constant-time path, on the axis that does not decide
   anything — the tidiest illustration of this report's thesis, that the
   complexity which matters on Sui is the cost of the bytes you rewrite, not the
   steps you execute.

### B.7 Which design for which market

Read down the flat-vector column of the round-trip table in §B.5. It is cheapest in
exactly one row — the tiny class, by **2.9%** — and from the small class onward it loses
monotonically: 1.08× at 48, 1.35× at 128, 2.65× at 512 and **7.77×** at 2,048, where it
is also two-thirds of the way to the object-size limit that stops it outright at 2,973.
The keyed designs are within 0.2% of each other in every row, and none of them varies
with depth at all.

That is the cross-subsidy of §7, now priced exactly rather than averaged. The shallow
tail pays 114,352 MIST per round trip — 2.9% — in the class where the absolute numbers
are smallest and the transaction counts lowest. What it buys is a 7.77× reduction at the
head and the removal of a hard ceiling. And the transaction-weighted result that makes
the flat vector look competitive in §7.1 rests on a fixed computation premium that scales
with nothing: by the large class it has already reversed sign.

One caveat on the absolute levels. This grid was measured on a fresh localnet with its
own pool and account objects, so its MIST figures are not directly comparable in level
with Appendix A's — only in slope, ratio and shape. Where the two overlap they agree:
6,536 against 6,710 MIST per standing order on burned fee, 203 against 209 on
computation, and 7,144 per inline order on the buffer tax.

---

## Appendix C — Reproducing the run

The measurement driver, analysis script, campaign runner and the parameterised
variant book source are committed at
[multicoin-book-storage-experiment-data/scripts/](multicoin-book-storage-experiment-data/scripts/).
`book_variant.move` carries the four levers at the top of the file
(`HOT_CAPACITY`, `HOT_SPILL_TARGET`, `HOT_REFILL_FLOOR`, `REFILL_ENABLED`); setting
them reproduces any of the six tree variants. Operational hazards encountered and
worked around — the CLI's cached chain id after `--force-regenesis`, the vendored
`multicoin` dependency, the registry's one-pool-per-(collection, asset, quote) rule,
and maker-rotation alignment against `MAX_OPEN_ORDERS` — are documented in the
driver's comments.
