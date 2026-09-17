# Market Design Constraints in EVE Frontier

**Why the game forces thousands of shallow markets, and what that costs on Sui**

Status: working document.

Most exchange design assumes the opposite of what the Frontier actually produces.
The default mental model is a handful of deep markets - a few busy order books
where lots of buyers and sellers meet. The Frontier produces the reverse: an
enormous number of small, local, mostly-idle markets, with a thin layer of busy
ones on top.

That shape is not an accident of how players have behaved so far. It falls directly
out of three facts about the game world. And it runs headlong into the way Sui
charges for storage and computation, in a way that makes the naive order-book
implementation not merely expensive but eventually non-functional.

This note traces that chain: game geography → market structure → on-chain cost →
what a venue design has to do about it. The gas figures are measured, not
estimated - they come from an end-to-end experiment against a local Sui network.

---

## Part 1 - The game forces liquidity to be local

### Space is large, and goods move only by being carried

The Frontier's routing infrastructure already covers **24,418 solar systems**, with
a design vision of 100,000. Goods do not teleport between them; they are hauled by
players through a stargate network.

Hauling costs fuel, time, and exposure to attack. That has a direct market
consequence: **the same item genuinely has different prices in different places, and
that difference is not an inefficiency waiting to be corrected.** It is the cost of
moving the item. A trader who buys low in one system and sells high in another is
not exploiting a mistake, they are being paid for transport and risk.

The practical upshot is that liquidity cannot pool. In a conventional market, buyers
and sellers of the same asset converge on one venue because there is no cost to
meeting there. Here, converging is expensive, so **each hub is its own market with
its own price.** There is no single global price for anything.

### Holding inventory is genuinely dangerous

This is the constraint most easily underestimated, because it is mostly ameliorated in real-life 
finance in the last 50+ years: in the Frontier, **the commodities and goods backing your quotes can be
destroyed.**

Resources are deliberately richest where it is least safe - the high-yield zones are
high-risk by design. Assets can be destroyed by hostiles; both players and ferals which enact a base layer of entropy to any infrastructure. Feral entropy runs continuously - holding
order together costs energy, and infrastructure decays if you stop paying for it.

Now connect that to how market depth is normally created. Depth comes from **market
makers**: traders who post both a price they will buy at and a price they will sell
at, earning the gap between them (the *spread*). To do that, they must hold
inventory - goods and currency sitting in one place, waiting.

In virtualized markets (typical cryptocurrency markets) the cost of holding that inventory is just price risk: the value
might move against you. Here there is an additional cost stacked on top:

- **Destruction risk** - the inventory can be taken from you outright or destroyed, providing a base cost to maintaining custody of items.

There are resource custody costs that exists in real-world commodity markets (evidenced by recent events in the Strait of Hormuz and in Russia where Ukraine has targeted
civilian commercial logistics facilities). They raise the minimum
spread a market maker can rationally quote, and they cap how much inventory anyone
wants to commit to any single location. **The economics of providing depth are
structurally worse here than in a conventional venue**, and they get worse the
further you are from safety - which is exactly where the valuable resources are. In EVE Frontier - there is a carrying capacity to space (inherent to the [fuel system](https://whitepaper.evefrontier.com/economy/crude-lenses-premium-fuel-and-their-network-effects)) which drives players to sprawl.

One more multiplier: the tradeable items does not pool across the vastness of space either.
There is a cost to transportation long distance; meaning that
the same commodity at two different stations are, correctly, two different assets
with two different risks of destruction. Even the financial layer is location-bound.

### But profit still pulls toward a few hubs

Everything above pushes custody outward: transport costs money, inventory can be
destroyed, and demand is generated locally. Left alone, those forces would produce a
smooth carpet of small, evenly-sized markets. They do not, and it is important to be
clear about why.

**Distributed custody is a cost constraint, not a preference.** Traders are not
trying to be local; they are being taxed for being remote. Every force that
*optimises profit* points the other way:

- **Spreads narrow where flow concentrates.** A market maker quoting where nobody
  trades earns nothing for the same custody risk. Flow attracts flow, because the
  trader who can round-trip inventory quickly is exposed for less time than one
  waiting for a counterparty.
- **Fixed costs amortise.** Hauling, defending a structure, and paying the energy
  bill that holds infrastructure against feral entropy are largely per-location, not
  per-trade. Doubling the volume through a hub does not double its defence cost, so
  the profit-maximising move is to push more volume through fewer, better-defended
  places.
- **Safety is itself a location.** The same risk that discourages distant inventory
  actively rewards concentrating it somewhere defensible. Defence has increasing
  returns; ten traders sharing one hub's protection each pay less for it than one
  trader alone.
- **Price discovery is a network good.** A quote is worth more where more people can
  see and hit it. That advantage compounds, and it does not decay with distance the
  way physical goods do.

So the equilibrium is not "local markets" and it is not "one global market" - it is
**both at once**. Custody risk sets a floor on how far liquidity will travel;
profit optimisation sets a ceiling on how many places it will bother to sit. What
emerges is a small number of dominant hubs that behave like conventional deep venues,
surrounded by a very long tail of genuinely local books that exist because hauling to
the hub is not worth it for that item, in that quantity, from that place.

This is the empirical pattern in comparable player economies, where trade reliably
collapses onto a handful of systems despite no rule requiring it, and it is why the
depth distribution below is **bimodal rather than merely shallow**. The tail is
produced by the constraints; the head is produced by the incentives. A venue design
that assumes only the first has no answer for the markets that earn the money - and
one that assumes only the second has no answer for the 99% of books that exist
because the first is real.

### What this does to order depth

Put these together - costly transport, dangerous custody, demand that is *locally
derived* (players want materials primarily in order to build a base or upgrade a ship
in a specific location), and the opposing pull of profit toward a few hubs - and the
equilibrium market structure is:

- **A very large number of markets.** Roughly one per item per location, which at
  Frontier scale means on the order of **100,000 discrete order books**.
- **Almost all of them shallow.** The vast majority hold zero to five resting
  orders and trade rarely. Around 95% sit under twenty orders per side.
- **A thin layer of deep ones.** 1% or fewer order books may exceed 150 orders per side - and those few carry much of the game's trading volume (and through it - revenue). These are the hubs, and they are *created* by profit optimisation rather than in spite of it, which means they will keep forming no matter how strongly the geography discourages them.

That last line is the important one, and it sets up the central difficulty. The
markets that generate the **transaction count** are not necessarily the markets that generate
the **revenue**. They are at opposite ends of the distribution.

What this _practically_ means is that we cannot optimize the market for shallow orderbooks OR for deep orderbooks. We have to optimize for _both_ while being sure to smooth the curve in the middle of the orderbook depth distribution.

---

## Part 2 - Sui's fee model punishes exactly this shape

### Two fees, and only one of them comes back

A Sui transaction pays two kinds of fee, and they behave very differently:

**Storage.** You are charged for the bytes of every object your transaction writes,
and refunded - as a *rebate* - for the version you replaced. Most of the money comes
back. What does not come back is a small slice, roughly 1%, which is burned
permanently. The critical detail: **that slice is charged against the entire object
you rewrote, not against the bytes you actually changed.**

**Computation.** You are charged for the work performed. **None of it comes back.**

Both matter, and the second is easy to forget because the storage numbers look
bigger gross. Per transaction, computation is actually the larger permanent cost:
around 1.78M MIST of computation against roughly 0.4M of genuinely-burned storage
for a well-designed book.

### An example - a flat order book pays for its whole depth, every single time

It is worth working one concrete layout through the fee model, because the numbers
are more extreme than intuition suggests. Take the obvious way to store an order
book: one sorted list held inside the pool object. It is simple, and at small sizes
it is the cheapest thing possible.

But because the burned storage slice applies to the whole rewritten object, **every
placement, cancel, and fill rewrites the entire book and burns ~1% of all of it** —
whether the operation touched one order or thirty.

Measured, on the real contract path:

| | Flat list |
|---|---|
| Burned per resting order, every operation | 6,710 MIST |
| Cost per trade at 300 orders deep | 23.97M MIST |
| Gas budget a maker must supply at depth 300 | 217.9M MIST |
| Maximum depth before the market breaks | 2,973 orders/side |

Two things there deserve emphasis.

The **gas budget** row is separate from the burned cost. Most of that 217.9M is
rebated, but the trader still has to *have* it to submit the transaction. That is
working capital a market maker must hold to quote at all - on precisely the deep
books where quoting matters most, and against the backdrop of Part 1 where
committing capital is already dangerous.

The **maximum depth** row is not a cost at all, it is a cliff. At 2,973 orders per
side the pool object crosses Sui's 256,000-byte object limit (measured: 256,083
bytes) and every further order placement simply **fails**. The market stops
accepting orders. That is an outage, and it arrives first at the single largest and
most valuable market you have. Pracitcally, though, the flat vector order books stop being cost effective far sooner than 2,973 orders per side.

### Computation is the other half of the bill

Storage is the headline, but computation produces the most extreme number in the
whole experiment, and it comes from the same root cause.

A flat list has to be *scanned*. Cancelling an order away from the top, modifying
one, or looking one up all walk the list. Worse, after a trade the matching engine
scans the whole side to remove filled orders - once per fill. That is
`depth × fills` work per crossing trade.

Measured, a taker order that sweeps 30 resting orders on a 300-deep book burns
**82,900,000 MIST** of computation - a fee that is never refunded. The same
scanning term is already visible at ten fills (5.34M MIST), and it keeps growing
with depth: about 209 MIST per resting order, paid on every operation, without
bound.

**The design rule that follows is blunt: no linear scan may appear in a matching or
settlement path.** It is the one term measured to grow without bound.

### The collision

Now put Part 1 and Part 2 together, because the tension is the actual design
problem.

The game gives us ~100,000 books, almost all nearly empty, plus a few deep ones
carrying half the revenue. Sui's fee model means:

- **For the ~100,000 shallow books**, the thing that matters is the cost of a market
  that is doing almost nothing. Any fixed per-market overhead is multiplied by five
  orders of magnitude before it earns anything. Here the flat list genuinely wins —
  it has no indirection to pay for.
- **For the deep books**, the flat list is a disaster on both fees and eventually
  stops working altogether. They need storage keyed by price, so that cost tracks
  the orders a trade actually touches rather than the depth of the book.

And that fix is not free for the tail. Any such indirection costs a **fixed +40,000
MIST of computation per operation (+2.3%)** - the price of wider keys and the
indirection itself. Including its storage component the tail penalty is about **58,000 MIST per
operation, roughly +3.0% of total cost, and about 69% of that is computation**, which
means **it cannot be tuned away by adjusting the design's parameters.** It is the
cost of the indirection existing at all.

So the decision is an explicit cross-subsidy:

> The ~95% of markets that transact least pay about 3% more per operation, so that
> the ~1% of markets earning half the revenue can exist at all - and so the largest
> market never hits a wall and stops accepting orders.

That is a defensible trade. But it should be made deliberately, with the number in
hand, rather than discovered afterwards.

### Why simple averages will mislead you here

One trap worth naming, because it caused repeated reversals of judgement during the
analysis.

**Gas is paid per transaction, but revenue is earned per trade, and the two
concentrate at opposite ends of the depth distribution.** Weight your cost numbers
by transaction count and the shallow tail dominates - that is where the protocol's
total gas bill is set, and by that measure the status quo flat list looks fine, even
marginally cheapest. Weight by revenue and the deep books dominate - and by that
measure the flat list is three to six times too expensive.

Both numbers are true. Neither is sufficient alone. The practical discipline is to
**report every cost figure under both weightings and prefer designs whose ranking is
stable across them** - a design that wins without needing the weighting argument
settled is worth more than a marginally cheaper one that depends on settling it.

There is also a forward-looking reason not to optimise for today's transaction mix:
there are currently no markets in the highest-volume class, and the intent is that
cost should not be the reason they never form. Tuning to the present distribution
optimises for the world the ecosystem is trying to grow out of.

---

## Part 3 - What this means for a venue design

1. **Optimise the cost of an idle market, not the cost of a trade.** Most of your
   markets will be empty most of the time. Fixed per-book overhead is the dominant
   term at 100,000 books.
2. **Make cost track how far into the book a trade reaches, not how deep the book
   is.** The vast majority of real order flow lands within ~28 orders of mid and most fills complete there - meaning the highest-turnover part of the book is the first 25-30 orders on each side of the midpoint (this number was taken from deepbook's onchain volume over the last 30days). A flat layout on a 300-deep book pays for roughly ten times
   the orders (storage rotation per object update) that it actually needs.
3. **Prove there is no reachable depth ceiling.** A depth limit is not a cost to be
   weighed against fees; it is an outage at your most valuable market.
4. **Keep any inline cache small.** Bytes held inline are paid for on every rewrite,
   while the benefit - keeping ordinary top-of-book activity out of the slower
   store - saturates within about a dozen orders. Measured, a large inline cache is
   worse than a small one at every depth, and in some ranges worse than the flat
   list it was meant to improve on.
5. **Admit no linear scan into matching or settlement.**
6. **Price the cross-subsidy explicitly**, and decide knowingly that the tail pays
   ~3% for the deep markets' existence.
7. **Put transport and custody risk into the instrument.** Spreads here have a hard
   floor set by destruction risk and decay, not by competition. Anything that
   appears to offer a risk-free return is either mispriced or hiding an insolvency —
   most likely the solvency of the Storage Unit backing a receipt.
8. **Never silently pool location-bound claims.** Receipts redeemable at different
   Storage Units carry different delivery risk. Treating them as one asset nets away
   a risk that has not gone anywhere.

---

## What this note does not cover

Deliberately scoped out, though each independently constrains venue design here:
public order flow and front-running defences; the absence of admin keys, pause
functions, or trade reversal; the choice of a common quote asset as a routing hub
and the risk that concentrates; and the finite gas-sponsorship budget that
subsidises new-player activity - which is really the same quantity as the
per-operation cost above, seen from the other end, since cheaper books buy more
onboarding for the same subsidy.

One genuine open question, rather than an omission: nothing in the source material
settles how matching should behave **across** locations - whether a taker sweeping
one hub should ever reach liquidity at an adjacent system, and at whose hauling
cost. Everything above assumes routing is a client-side concern, because that is
what the current infrastructure implies. It deserves a decision rather than an
inheritance.
