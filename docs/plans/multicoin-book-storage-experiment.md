# Multicoin order book storage: experiment brief

**Scope: `triex::book` as used by `triex::multicoin_pool`, and nothing else.**

This document defines an experiment, not a conclusion. It states the problem, the
usage constraints the design must satisfy, the candidate designs, and the only
testing mechanism that produces trustworthy numbers. It exists so the experiment
can be run once, cleanly, and produce a decision.

Coin pools (`triex::coin_book`, `triex::pool`) are explicitly **out of scope**.
They already run a `BigVector` with encoded `u128` keys and are a separate
decision. Where this document cites measurements taken on the coin stack, it says
so, and those figures are treated as priors to be re-established on multicoin —
not as evidence about multicoin.

---

## 1. The problem

Multicoin pools store each side of the book as a flat, sorted `vector<Order>`
held inline in the pool object ([book.move](../../packages/triex/sources/book/book.move)).
Every mutation therefore rewrites the whole side.

On Sui that has a specific and unusual cost shape. A transaction is charged
`storageCost` for every object it writes, sized by the object's *new* bytes, and
refunded `storageRebate` for the version it replaced. Most of the charge comes
back. What does not come back is `nonRefundableStorageFee` — roughly 1% — and it
is levied against the **entire rewritten object**, not against the bytes that
actually changed.

So a flat vector burns ~1% of the whole book on every placement, cancel and fill,
regardless of how many orders the operation touched. A tree structure rewrites
only the slices it touched and burns ~1% of those.

The difficulty is that our pools are not homogeneous. The structure that is
cheapest for a 6-order book is not the structure that is cheapest for a 300-order
book, and we run enormous numbers of both. **We need one storage design that is
acceptable across the whole distribution, optimising two costs at once: the
un-rebateable storage fee and the on-chain computation cost.**

### 1.1 The distinction that drives everything

**Book depth and interaction depth are different numbers.**

- A flat vector's cost tracks **book depth** — it rewrites everything inline,
  whether the trade touched one order or thirty.
- A tree's cost tracks **interaction depth** — it rewrites only the slices reached.

On a 300-order book where trades land within ~30 of mid, a flat vector pays for
roughly ten times the orders it needed to. Any candidate design should be
evaluated against this gap explicitly, because it is where the designs actually
differ.

### 1.2 The motivating hypothesis

The status quo is not failing everywhere. It is expected to fail **specifically on
the large markets**, and those are the markets that carry the largest share of
volume and revenue.

This matters because it puts the flat vector's weakness and the exchange's income
in the same place. Its cost grows linearly with book depth and it carries a hard
depth ceiling; both bite hardest exactly where trades are most valuable. A
transaction-weighted average will not surface this — deep books are ~1% of
transactions — which is precisely why §2.1 requires both denominators and why the
decision criteria in §7 do not simply take the transaction-weighted winner.

The experiment's job is to establish whether this is true and at what depth it
begins to bite, not to assume it. But it is the reason the work is being done, and
a result that says "the flat vector is fine on average" without examining the deep
markets specifically has not answered the question.

---

## 2. Constraints

These are the operating conditions the design must be good at. They are stated
as the experiment's weighting inputs; if any are wrong the conclusion moves, so
they should be confirmed against production telemetry before the run.

| Constraint | Value |
| --- | --- |
| Breadth of pools | 100,000+ order books exist |
| The long tail | The vast majority hold 0–5 standing orders and trade rarely |
| Typical active market | < 20 standing orders per side (~95% of markets) |
| Mid band | 30–60 standing orders (~3–5% of markets) |
| Deep | > 150 standing orders (~1% of markets) |
| Very deep | > 300 standing orders (~0.1% of markets) |
| Where trades land | 99% of orders placed within 28 of mid; most trades fill within ~30 |
| Deep-book share of **transactions** | ~1% or less |
| Deep-book share of **revenue** | ~50% is earned on books of depth 150+ |
| Mid-band share of revenue | Also substantial |

### 2.1 Two denominators, and why both matter

This distribution has caused repeated reversals of judgement during analysis, for
one reason: **gas is paid per transaction, but revenue is earned per trade, and
the two concentrate in different places.**

- Weight by **transactions** and shallow books dominate — that is where the total
  protocol gas bill is set.
- Weight by **revenue** and deep books dominate — that is where per-trade cost
  becomes a competitiveness question on the trades that fund the exchange.

A design that is only good under one weighting is not good enough. **Report every
result under both**, and prefer designs whose ranking is stable across them. A
design that wins without needing the weighting question resolved is worth more
than a marginally cheaper design that depends on getting it right.

### 2.2 Hard limits

- **Depth ceiling.** A flat vector holds the whole book inline, so a sufficiently
  deep market pushes the pool object past Sui's maximum object size and the book
  stops accepting new orders. This is a cliff, not a cost, and does not scale down
  with the tail's weight. Where it sits has never been measured; the experiment
  should find it.
- **`MAX_OPEN_ORDERS` = 100** per trading account. Any book deeper than 100 in a
  test must be built across several accounts.

---

## 3. The levers

Four candidate designs. All four are storage-layout choices for one side of the
book; none changes matching semantics, price-time priority, or the public order
API except where noted.

### A. Flat vector (status quo)

`vector<Order>` inline in the pool object, sorted, best price at the end.

- Cheapest structure at low depth — nothing indirect to pay for.
- Cost grows linearly and without bound as the book deepens.
- Carries the depth ceiling.
- Cancel away from the top is an O(n) scan; the post-match removal pass scans the
  whole side for every fill ([book.move](../../packages/triex/sources/book/book.move),
  the `to_remove` loop), which is O(depth × fills) per crossing trade.

### B. Bare BigVector

Replace the vector with `BigVector<Order>`, orders living in dynamic-field slices.

- Cost tracks interaction depth; flat as books deepen; no ceiling.
- Pays a dynamic-field write on *every* operation, including on a 5-order book.
- **Prerequisite:** `BigVector` is keyed, and multicoin's order ids are opaque
  ascending `u64` serials — priority is positional, enforced at insert time by
  `find_insert_position`. A tree keyed on that id would sort by insertion time,
  not price. This design requires encoded `u128` keys
  (`(price << 64) | seq`, with the bid side complemented so higher is better),
  which is a **breaking change to every stored order id** and to
  `modify_order` / `cancel_order` / `cancel_orders` / `get_order`, plus the
  fill/state/account/vault plumbing and every downstream consumer.

### C. BigVector + fixed hot cache

As B, plus the best N orders of each side held inline in the pool object, with the
tree behind them. Operations at the top of the book touch no dynamic field.

- Same `u128` prerequisite as B.
- The inline cache sits in the pool object **permanently**, so it enlarges every
  pool rewrite whether or not the operation used it.

### D. BigVector + shrinking hot cache (mode switch)

As C, but the cache size is not fixed. While a side holds fewer than `CAP` orders
it *is* the whole book — a flat vector, with an empty tree and no dynamic field in
existence. On exceeding `CAP`, spill the furthest orders from mid into the tree,
leaving a small hot cache of `FLOOR`. Draining the tree returns the side to
flat-vector mode automatically, with no mode flag.

- Intent: flat-vector economics for the ~95% of markets below `CAP`, tree
  economics above it, and no depth ceiling ever.
- Two parameters to fit: `CAP` (where the switch happens) and `FLOOR` (how much
  stays inline in deep mode).
- Same `u128` prerequisite as B.
- **Known hazard:** the transaction that crosses `CAP` pays the whole migration
  (`CAP − FLOOR` tree inserts plus slice allocations) in one go. This is a gas
  cliff for one unlucky trader and should probably be amortised — spill a few per
  operation while above the threshold rather than all at once. Measure it before
  deciding.

#### D.1 Depth is sticky, and that shapes the design

The design assumption behind D is that **book depth is close to monotone in
practice**: a side that reaches 64 is likely to go on to 80, 100, 120 or more, and
unlikely to fall back and stay there. The mode switch is therefore effectively
one-way over a market's life, not an oscillation. Four consequences:

1. **Thrash is not the main risk.** Elaborate hysteresis on the return path buys
   little, because markets rarely return. `CAP` can be chosen as a *graduation
   signal* — the depth at which "this market is becoming a deep market" is
   reliable — rather than as the midpoint of an oscillation.
2. **The migration cost amortises over the market's whole deep lifetime.** One
   expensive transaction spread across the remaining life of a high-volume book is
   a much weaker objection than it first appears. It remains a per-trader UX spike
   worth smoothing, but it should not drive the choice of `CAP`.
3. **The band between the crossover and `CAP` is a transit corridor, not a resting
   state.** If the tree becomes cheaper somewhere near depth 26 but `CAP` is 64,
   markets are in the more expensive mode between those points — but they pass
   through quickly on the way up and few transactions land there. This makes a
   higher `CAP` more defensible than a naive crossover analysis suggests, and it
   is directly testable: measure how many transactions a market actually executes
   while transiting the band.
4. **`FLOOR` should be sized for the deep regime, not the shallow one.** Once a
   market has graduated it stays deep, so the inline cache lives most of its life
   alongside a populated tree — the regime where prior finding 4 says a large
   inline cache is a liability. Size `FLOOR` to the interaction depth (~28–30 from
   mid) and no larger.

The stickiness assumption is itself testable against production history and should
be confirmed: if books in fact oscillate around the threshold, consequences 1 and
2 reverse and the design needs real hysteresis.

---

## 4. Prior evidence (coin stack — treat as hypotheses, not results)

Measured on the **coin** pool path against a local network, so the absolute
figures do not transfer to multicoin: a different `Order` field set, a different
`price_scaling`, and a different state layer. The *shapes* are what carry over,
and they are what the multicoin experiment should confirm or refute.

1. **Un-rebateable storage per placement grew at ~6,827 MIST per extra resting
   order for the flat vector, against ~1,316 for the tree.** The gap widens
   without bound with depth.

2. **The crossover was around depth 26.** Below it the flat vector was cheaper;
   above it the tree was. At depth 15 the bare tree was ~30–40% *worse* than the
   flat vector; at depth 200 (extrapolated) it was ~2.7× better.

3. **Storage layout barely moves computation.** With an inline cache large enough
   to hold the whole book — so no dynamic field is touched at all — computation
   still rose ~2.4% versus a bare tree. Dynamic-field access appears to be priced
   almost entirely as *storage* in Sui's gas model, not as computation. The large
   computation differences observed between stacks tracked the **state and fee
   architecture**, not the order book.
   *Implication: this is probably a storage-optimisation problem with a
   computation constraint, not a joint optimisation. Confirm early — it decides
   how much effort the computation axis deserves.*

4. **A fixed inline cache inverts.** At depth 15 (cache holds the whole book) it
   was 12.1% *better* than a bare tree on burned fee; at depth 60 (book has
   outgrown it) it was 20.1% *worse*, because the cache enlarges every pool
   rewrite while a tree still sits behind it. **A hot cache is only an asset while
   it is the entire book.** This is the strongest argument for design D over C,
   and for keeping `FLOOR` small.

5. **A defect worth not reproducing.** In the coin implementation, `spill()` trims
   to its target on *every* insert rather than only on overflow, so the cache
   never exceeds the spill target and every top-of-book placement still writes the
   tree — paying both structures' costs. Any implementation of C or D must gate
   the spill on genuine overflow (`if (len <= CAP) return;`) or it will measure as
   strictly worse than both alternatives.

---

## 5. What to measure

### 5.1 Metrics

Per transaction, read from the transaction's own effects:

- `nonRefundableStorageFee` — **the primary metric.** Permanently burned, charged
  on the whole rewritten object.
- `computationCost` — secondary. Note that Sui quantises this into buckets;
  differences below ~3% should be treated as no measured difference unless they
  reproduce exactly across repeated cycles.
- `storageCost` / `storageRebate` — record them. Gross storage sets the gas budget
  a trader must supply even though most of it returns.

### 5.2 Operations

Each measured as its **own transaction**. Batching several placements into one
programmable transaction rewrites the pool object once and measures nothing.

| Operation | Why |
| --- | --- |
| Place resting order at top of book | The dominant maker action |
| Place resting order ~28 from mid | The stated edge of real order flow |
| Cancel at top of book | Dominant maker action |
| Cancel ~28 from mid | Exercises the cache/tree seam |
| Place-and-cancel cycle, steady state | The churn that market makers actually generate |
| Crossing taker filling 1 order | The common trade |
| Crossing taker filling ~10–30 orders | Sweeps that span the seam |
| Modify down | Touches an order in place |

### 5.3 Depths

`0, 5, 10, 15, 20, 30, 45, 60, 100, 150, 300` standing orders per side, plus a
run that deepens one book until placement fails, to locate the ceiling.

Depths above 100 require rotating several trading accounts
(`MAX_OPEN_ORDERS = 100`).

### 5.4 Distinguish construction from steady state

These give **opposite** answers for cache-bearing designs and must be reported
separately.

- **Construction** — building a book up from empty, each placement a new best
  price. This is the worst case for designs C and D: the cache overflows
  continuously and spills.
- **Steady state** — a book already at depth d, churning at the top. This is what
  live markets do, and what should carry the weight in the final decision.

Prior runs that conflated these produced misleading conclusions in both
directions.

---

## 6. Test mechanism

**Local network deployment only.** Scripts driving real transactions against a
local Sui node, reading gas from transaction effects.

Move unit tests are **not** an acceptable instrument here. `sui move test` and
`build_scripts/gas-benchmark.sh` measure Move VM abstract gas — instruction and
memory cost — and are blind to storage entirely. Since storage is the primary
metric, unit-test benchmarks cannot answer this question. They remain useful for
correctness and for coarse computation comparisons.

### 6.1 Setup sequence per variant

1. `sui start --force-regenesis --with-faucet`, then fund the active address from
   the faucet.
2. Publish `token`, then `multicoin`, then the `triex` variant under test.
3. `multicoin::new_collection(ctx)` → share the `Collection`, keep the
   `CollectionCap`. Multicoin pools identify the base asset as
   `(collection_id, asset_id)` at runtime rather than by coin type, so this step
   has no equivalent in the coin-pool setup.
4. Publish or reuse a freely-mintable quote coin. `CRED` has no public mint and
   the suites' `USDC` is `#[test_only]`, so neither works on a real network.
5. `registry::add_approved_quote<Quote>` and `fee_policy::bootstrap_quote<Quote>`.
6. `multicoin_pool::create_pool_admin<Quote>` — avoids the pool creation fee.
7. `trading_account::new`, fund quote via `deposit`, fund the base side via
   `deposit_multicoin`, then share the account.
8. Drive orders through `multicoin_pool::place_limit_order<Quote>` with a
   `TradeProof` generated inside the same programmable transaction.

### 6.2 Operational hazards

Each of these cost real time to diagnose during earlier runs.

- **A legacy `[addresses]` block in a `Move.toml` silently suppresses
  `[environments]`**, and publishing fails with a misleading "package does not
  define a localnet environment". Remove the block.
- **The `multicoin` git dependency cannot be published from the `~/.move` cache** —
  manifest edits there are ignored. Vendor it to a normal directory.
- **The CLI caches a chain id per environment in `~/.sui/sui_config/client.yaml`.**
  After `--force-regenesis` the cached id is stale and every publish fails on a
  chain-id mismatch. Update `chain_id` in that file. `-e localnet` maps to
  `--build-env` and is rejected by `publish`.
- **A one-time witness must be named for its own module**, so a package providing
  two coins needs two modules.
- **Package size**: at least one `triex` variant exceeds Sui's default 102,400-byte
  package limit. Start the node with
  `SUI_PROTOCOL_CONFIG_OVERRIDE_ENABLE=1 SUI_PROTOCOL_CONFIG_OVERRIDE_max_move_package_size=512000`.
  This does not alter storage pricing.
- **Do not edit the working tree while a measurement run is in flight** — a failed
  compile silently invalidates results. Run each variant from its own git
  worktree.
- **Run variants from separate worktrees but one at a time**, or gas-coin
  contention from the same address can cause failures.

### 6.3 Controlling for confounds

The only clean comparisons are between variants that differ **solely** in book
storage — same package, same state layer, same fee architecture. Comparisons
across `main` and `cycle-7` mix the book change with an entirely different account
and fee stack and cannot attribute a difference to the book. Build every variant
from the same base commit.

---

## 7. Deciding

The experiment should produce, for each of A–D:

1. Burned fee and computation per operation, at each depth, separated into
   construction and steady state.
2. Those figures weighted two ways — by transaction share and by revenue share —
   per §2.1.
3. For C and D, the fitted `CAP` / `FLOOR`, and the measured cost of the migration
   transaction that crosses `CAP`.
4. For A, the measured depth at which placement fails.

**Choose the design whose ranking is stable under both weightings.**

Where they disagree, do not default to the transaction-weighted winner. Deep books
are ~1% of transactions and ~50% of revenue, so transaction weighting
systematically under-prices the markets the exchange earns from. Two gates apply
before a design can win on its transaction-weighted average:

1. **Deep-market per-trade cost.** What does an order cost on a 150-, 300- and
   500-deep book? A design that is cheap on average and expensive there is failing
   at the point of sale on half the revenue.
2. **The ceiling.** If a design's depth limit is reachable by markets we expect to
   have, it is disqualified regardless of its fee numbers. A market that stops
   accepting orders is not a cost, it is an outage, and it would happen to the
   largest market first.

A result favouring A (status quo) remains possible and should not be argued away —
B, C and D all require a breaking `u128` order-id migration whose cost appears
nowhere in these measurements. But A can only win by clearing both gates above.
"Acceptable on average" is not sufficient for A specifically, because the
hypothesis in §1.2 is that its failure is concentrated precisely where the
averages hide it.

---

## 8. Open questions the experiment should close

- Where does the flat vector's depth ceiling actually sit, in orders per side?
- Is the crossover depth on multicoin near the ~26 seen on the coin stack?
- Does the computation axis matter at all, or is prior finding 3 general — i.e. is
  this purely a storage optimisation?
- For design D, what `CAP` and `FLOOR` minimise weighted cost, and does the
  migration transaction need amortising to stay within a sane gas budget?
- Is depth actually sticky (§D.1)? Confirm against production history: of the
  markets that have ever reached 64 on a side, what fraction went on to exceed
  100, and what fraction fell back below 64 and stayed there?
- How many transactions does a market execute while transiting the band between
  the crossover depth and `CAP`? If few, a higher `CAP` costs almost nothing.
- Does the O(depth × fills) removal scan in the current matching path show up as a
  measurable computation cost at depth 150+, and is it worth fixing independently
  of the storage question?
