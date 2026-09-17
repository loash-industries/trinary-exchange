# Phase 4 — does the shipped book cost what the experiment measured?

**Real-transaction verification of the C16u port in `triex::book`**

| | |
| --- | --- |
| Subject | `triex::book` on `feat/multicoin-c16u`, driven through `multicoin_pool` |
| Run | 17 September 2026 · local Sui network, sui 1.73.1 · 239 recorded transactions — 165 single-operation, 74 ceiling batches carrying 3,300 placements |
| Reference | the C16u column of [multicoin-book-storage-whitepaper.md](multicoin-book-storage-whitepaper.md), measured 16 September on a vendored variant |
| Data & scripts | [multicoin-c16u-verification-data/](multicoin-c16u-verification-data/) |
| Verdict | **Reproduced.** 161 of 165 comparable transactions are bit-identical; the ceiling is gone. |

---

## 1. What this checks, and why it needed checking

The whitepaper's C16u figures came from a *variant* — a purpose-built copy of
`book.move` in a vendored tree, driven by a harness that never ran the real
package. The recommendation was adopted on those numbers. Phase 4 asks the only
question that matters afterwards: **does the book we actually shipped cost what
the book we measured cost?**

It is not a repeat of the experiment. The comparison is one-sided and specific:
same operations, same depths, same seeding order, same driver — the reference
column fixed, the shipped package substituted for the variant. A material gap
would mean the port diverged from what was measured, and the storage case for the
change would have to be re-argued rather than inherited.

The Move suite cannot answer this. `sui move test` prices computation and is blind
to storage entirely, so the 789 tests on this branch establish that the book is
*correct*, not that it is *cheap*. Every number below comes from the effects of a
real transaction on a running node.

---

## 2. Method

One localnet (`sui start --force-regenesis --with-faucet`, package-size protocol
override, which does not alter storage pricing). Publish `token`, a vendored
`multicoin`, then the real `triex` package from the branch — no variant, no edits.
Approve CRED as quote, `bootstrap_quote` its fee classes, and drive the campaign
with the experiment's own [`driver.py`](multicoin-book-storage-experiment-data/scripts/driver.py),
unmodified.

Each measured operation is its own programmable transaction containing exactly a
`generate_proof_as_owner` call and the operation under test. Depths 0–300, eleven
classes, seeded best-price-last so the buffer rests in the shape a live deep book
settles into. Two scripts were added, both in
[multicoin-c16u-verification-data/scripts/](multicoin-c16u-verification-data/scripts/):
`bootstrap_real.py`, which publishes the real package instead of a variants tree,
and `compare.py`, which diffs the result against the reference cell by cell.

### 2.1 One confound found and removed

The first pass reported `taker_1` at depth 5 as +21.2% against the reference. It
was not a book difference: `storageCost` was *identical* (30,278,400) and the whole
gap sat in `storageRebate`, meaning the prior version of some object was larger —
account state, not book state. The cause was a `driver.py smoke` run executed
before measurement, which left the first maker and the taker carrying turnover-ring
entries the reference run's fresh accounts did not have.

Resetting the accounts and re-measuring reproduced the reference exactly
(231,724 burned, rebate 22,940,676 — bit-identical). The whole matrix was then
re-run from clean accounts, and that is what §3 reports; the contaminated pass was
discarded and is not published here.

The episode is worth keeping in view for its own sake: the same discipline the
whitepaper applied to its ladder run (§B.1, "the first touch of a given price by
the prober carries one-off growth in its account map") applies to this one, and a
21% gap that looked like a porting defect was an artifact of account history. The
tell was that `storageCost` matched exactly while the rebate did not — a book
difference would have moved both.

---

## 3. Result

**161 of 165 comparable transactions are bit-identical to the reference.**

Cost of an executed trade — one taker fill plus the five maker place/cancel cycles
around it — in MIST of burned storage fee:

| depth | whitepaper C16u | shipped package | delta |
| --- | --- | --- | --- |
| 5 | 2,371,124 | 2,371,124 | 0.0% |
| 10 | 2,880,020 | 2,880,020 | 0.0% |
| 15 | 3,339,820 | 3,339,820 | 0.0% |
| 20 | 3,413,844 | 3,413,844 | 0.0% |
| 30 | 3,547,604 | 3,547,604 | 0.0% |
| 45 | 3,748,244 | 3,748,244 | 0.0% |
| 60 | 4,030,711 | **3,948,884** | −2.0% |
| 100 | 4,252,884 | 4,252,884 | 0.0% |
| 150 | 4,313,684 | 4,313,684 | 0.0% |
| 300 | 4,277,204 | 4,277,204 | 0.0% |

Nine of ten depths agree to the MIST. The tenth is cheaper here, for a reason
given below.

### 3.1 The four transactions that differ

| op | depth | cycle | reference | shipped | note |
| --- | --- | --- | --- | --- | --- |
| `place_top` | 0 | 0 | 187,948 | **138,852** | first-touch account growth; cycles 1–2 identical in both |
| `place_restore` | 20 | 0 | 354,388 | **403,484** | first touch of a fresh maker account |
| `place_top` | 60 | 1 | **397,176** | 348,080 | one-off spike in the *reference*; shipped run gave 348,080 three times |
| `taker_30` | 300 | 0 | 931,380 | 932,596 | +0.13% |

Three of the four move by exactly one account-growth quantum — 49,096 MIST, once
in each direction — and the fourth by 0.13%. None is a steady-state value: every
cell that settles, settles on the same number.

The depth-60 row is worth naming, because it is the reference that is anomalous.
Its three cycles read 348,080 / 397,176 / 348,080; the shipped package gives
348,080 three times. This is precisely the first-cycle spill variance §9 of the
whitepaper reported ("the eight cells that did vary were first-cycle spill
transactions, a real regime rather than scatter"). The −2.0% at depth 60 in the
headline table is that single reference sample, not a saving in the port.

### 3.2 Computation

Every computation cell agrees to within one 10,000-MIST bucket — the instrument's
resolution — and most agree exactly. The deviations are uniformly −0.6% or less
and are quantisation, not signal.

---

## 4. The ceiling is gone

The flat vector this book replaces stopped accepting orders at **2,973 per side**,
where the pool object reached 256,083 bytes against a 256,000-byte maximum
(whitepaper F2). One book on the shipped package was driven to **3,300 orders per
side with no failure of any kind** — the run ended because it hit its own limit,
not the book's.

Per-order storage cost does not grow with depth:

| | mean `storageCost` per resting order |
| --- | --- |
| depth 200–800 | 2,320,239 |
| depth 2,500+ | 2,316,493 |
| ratio | **0.998** |

Flat to two parts in a thousand across a twelve-fold increase in depth. The flat
vector's equivalent slope was 6,710 MIST of *burned fee* per resting order, on
every operation.

### 4.1 It still trades there

A book that accepts orders but cannot fill them is not a working market, so the
deep book was exercised rather than merely counted. At ~3,330 asks per side:

| op | burned | computation | result |
| --- | --- | --- | --- |
| `place_top` | 145,996 | 1,750,000 | ok |
| `cancel_top` | 183,464 | 1,730,000 | ok |
| `taker_1` | 362,748 | 1,800,000 | 1 fill |
| `taker_10` | 1,049,940 | 2,340,000 | 10 fills |
| `taker_30` | 1,034,588 | 3,700,000 | 30 fills |

Computation on the 30-fill sweep is **3.70M MIST at depth 3,330**. The flat vector
spent **82.9M** on the same sweep at depth 300 — a book eleven times shallower —
because its removal pass scanned the whole side per fill. That is the O(depth ×
fills) term keyed removal eliminates, observed on the shipped code.

Placement here is cheaper than the depth-300 steady-state figure (145,996 against
384,560) for a structural reason, not a lucky one: the ceiling run builds prices
ascending, so nothing ever beats the buffer's first resident and the buffer holds
one order. That is the "worst-price-last" build of whitepaper §B.2, and it costs
less per operation precisely because there is almost nothing inline to rewrite.

---

## 5. What this does and does not establish

**Established.** The shipped `triex::book` reproduces the measured C16u design, to
the MIST, on every steady-state operation the experiment measured. The depth
ceiling that disqualified the flat vector does not exist here, and the book trades
normally well past where the flat vector stopped.

**Not established, and not in scope.** These are localnet figures at localnet
reference gas price with mainnet storage constants; ratios and slopes transfer,
absolute MIST should be re-derived at the live gas price (whitepaper §9). Nothing
here re-argues the *design* — the weightings, the crossover, the choice of 16 over
64 — all of which rest on the original campaign's seven-variant comparison. This
run substitutes one thing for one thing and asks whether the substitution held.

It held.
