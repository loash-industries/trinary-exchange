# Trading Fees, Explained Simply

*A plain-language guide to how trading fees work on trinary-exchange. Every claim
here traces back to the Move source — see the file references at the bottom of
each section if you want to check the code yourself.*

## The big idea

Think of it like an airline status program, not a tax bracket.

With a tax bracket, different slices of your income get taxed at different
rates, all in the same paycheck. That's **not** how this works.

Here, you have a *status level* — eight of them — based on how active a trader
you've been recently. **Whatever level you're at when you place a trade, that
entire trade gets priced at that level's rate.** There's no blending. A
whale-sized trade from an entry-level trader is charged 100% at the entry rate.

The trading you do *right now* helps you level up for your *next* trade —
it doesn't retroactively discount the trade you're currently making.

*(Code: `state/fee_schedule.move` — the module doc states the step-function rule
outright.)*

## Your "activity score"

Your level is based on a rolling activity score, not your all-time volume.

- The exchange looks at the **fees you have actually paid** over the trailing
  **30 epochs** — think of an epoch as roughly "one day," so about a month of
  activity.
- **It counts fees, not trade size.** This trips people up: a threshold of
  "20,000 CRED" means 20,000 CRED of *fees paid*, which at the entry rate is
  roughly 2 million CRED of actual trading. The score is a measure of what
  you've contributed, not what you've moved.
- Only fees from trades that actually happened count. If you place a buy order
  and later cancel it before it fills, that never counted toward your score —
  parking a big order and cancelling it can't be used to farm a better rate.
  (The protocol does keep a share of a cancelled bid's escrow as revenue, but
  that share deliberately does *not* count toward your score either.)
- The score is a rolling window, so it ages out. If you stop trading for about a
  month, your score drains back to zero and you fall back to the entry level.

*(Code: `state/fee_turnover.move` — a 30-bucket ring buffer;
`TURNOVER_WINDOW_EPOCHS = 30` in `helper/constants.move:79`. The "retention is
revenue but not score" rule is in `state/state.move`, `recognize_retention`.)*

## Your level is exchange-wide, not per pool

Your activity score lives on **your own `BalanceManager`** — your account object
— and is tracked **per quote asset**.

That means trading on *any* pool quoted in CRED lifts your level on *every*
other pool quoted in CRED, standard and multi-coin alike. Activity doesn't reset
at the pool boundary, and you don't have to rebuild status on each new market
you touch.

The one boundary that does exist is the quote asset: your CRED score and your
USDC score are separate ladders, because a level threshold is a sum of quote
units and the two aren't comparable.

*(Code: `balance_manager.move` — `TurnoverKey { quote }` keys the score by quote
asset; `pool.move` / `multicoin_pool.move` read it during order placement.)*

## What determines your rate on any given trade

1. Any fees you earned as a maker on this pool get folded into your score first.
2. The exchange finds the highest level your score qualifies for.
3. Your **entire** order is priced at that level's rate.
4. *Only after* the trade settles does the fee you just paid get added to your
   score — which might bump you up a level for your *next* trade.

This ordering matters: a trade can never discount itself.

One consequence worth knowing: if you place an order that rests on the book, the
rate is **frozen onto that order at placement**. Later fee changes, and even
your own promotion to a better level, never re-price an order that's already
resting.

*(Code: `pool.move`, `place_order_int`; `fee_policy.move`, `resolve_with_retention()`.)*

## Who sets the levels and rates, and how

There is **one shared fee-policy object** for the whole exchange. Pools do not
own their pricing — each pool stores only a 2-byte *class id* pointing into it.

A **class** is a pricing group: "standard CRED pools" is a class, "multi-coin
CRED pools" is another, and a single negotiated market-maker deal is just a class
with one pool in it. Re-pricing a class re-prices every pool in it, in one
transaction.

The exchange's admin (holding `TriexbookAdminCap`) configures classes. Built-in
guardrails, enforced no matter what the admin sets:

- **Up to 16 levels** per class.
- **The entry level always starts at zero activity** — every trader has a tier.
- **Thresholds must strictly increase** going up the ladder.
- **Rates can only get better (or stay the same) as you move up, never worse.**
  More trading activity is never allowed to cost you more.
- **Taker fees have a floor** of 1 basis point — never discountable to zero.
  **Maker fees have no floor**; 0% is a legal top-tier maker rate.
- Rate changes on an existing class **take effect the next epoch**, never
  mid-epoch, so nobody's in-flight trade is re-priced out from under them.

*(Code: `fee_policy.move` — `create_class`, `update_class`, `set_default_class`;
`state/fee_schedule.move`, `validate()`.)*

## Setting the exchange up at launch

The policy object **ships empty**. Until an admin configures a quote asset, *no
pool of that quote can be created at all* — pool creation looks up that quote's
default class and aborts if there isn't one.

`fee_policy::bootstrap_quote<QuoteAsset>` does the whole setup for one quote in a
single transaction: it creates the coin-pool class and the multi-coin class on
the genesis ladder below, and registers both as the defaults new pools are born
into. Run it once per approved quote, immediately after publish and before
creating any pools.

It takes the quote's decimal scale (`1_000_000` for a 6-decimal asset like CRED
or USDC, `1_000_000_000` for SUI) because level thresholds are sums of quote
units and have to be scaled to the asset they price.

*(Code: `fee_policy.move`, `bootstrap_quote()`.)*

## The actual numbers today

Both pool kinds launch on an **eight-level ladder** that halves the entry rate by
the top level. Multi-coin is the premium venue; standard coin pools price at half
of it.

| Level | Score needed (fees paid, in quote units) | Coin pool taker / maker | Multi-coin taker / maker |
|---|---|---|---|
| 0 | 0 | 1.100% / 0.900% | 2.200% / 1.800% |
| 1 | 20,000 | 1.012% / 0.828% | 2.024% / 1.656% |
| 2 | 100,000 | 0.924% / 0.756% | 1.848% / 1.512% |
| 3 | 500,000 | 0.836% / 0.684% | 1.672% / 1.368% |
| 4 | 2,000,000 | 0.748% / 0.612% | 1.496% / 1.224% |
| 5 | 10,000,000 | 0.682% / 0.558% | 1.364% / 1.116% |
| 6 | 50,000,000 | 0.616% / 0.504% | 1.232% / 1.008% |
| 7 | 200,000,000 | 0.550% / 0.450% | 1.100% / 0.900% |

These rungs target sustained institutional flow. As a rough sense of scale, level
1 is about 2 million quote of actual trading in a month; the upper rungs are
deliberately far out and function as headroom rather than as levels most traders
will see.

Each rung is a fixed discount off the entry rate — 0/8/16/24/32/38/44/50 percent
— applied to the taker and maker columns alike, so the spread between the two
sides keeps its ratio all the way up.

Bounds the admin must stay within when setting *any* level's rate:

| Rule | Value |
|---|---|
| Minimum taker fee (floor, all levels) | 0.01% (1 basis point) |
| Maximum taker or maker fee | 100% |
| Rate granularity | 0.01 basis points |
| Maximum levels per class | 16 |
| Cancellation retention (share of a cancelled bid's escrow the exchange keeps) | up to 100%; launch default 20% |

These launch numbers are a starting configuration, not a constant of the
universe — an admin can restage any class for the next epoch at any time, and
because your score is stored raw (never a cached tier), a schedule change
re-prices everyone on their next trade with no migration.

*(Code: `fee_policy.move` — `coin_taker_fees()`, `coin_maker_fees()`,
`multicoin_taker_fees()`, `multicoin_maker_fees()`, `genesis_thresholds()`,
and the `MIN_TAKER_FEE` / `MAX_TAKER_FEE` / `MAX_MAKER_FEE` /
`FEE_MULTIPLE` / `MAX_CANCEL_RETENTION_BPS` constants;
`MAX_FEE_TIERS` in `helper/constants.move:83`.)*

## Quick glossary

| Plain English | Code term |
|---|---|
| Activity score | `fee_turnover` (a `FeeTurnover` ring) |
| Rolling ~30-day window | `TURNOVER_WINDOW_EPOCHS` |
| Level / tier | `FeeTier` |
| Fee ladder | `FeeSchedule` |
| Pricing group of pools | `ClassSchedule`, keyed by a pool's `fee_class` |
| The one shared config object | `FeePolicy` |
| Someone who trades instantly against the book | taker |
| Someone whose resting order gets filled later | maker |
| Admin sets up a quote at launch | `bootstrap_quote` |
| Admin re-prices a class (next epoch) | `update_class` |
