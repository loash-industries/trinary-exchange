# Trading Fees, Explained Simply

*A plain-language guide to how trading fees work on trinary-exchange. Every claim
here traces back to the Move source — see the file references at the bottom of
each section if you want to check the code yourself.*

## The big idea

Think of it like an airline status program, not a tax bracket.

With a tax bracket, different slices of your income get taxed at different
rates, all in the same paycheck. That's **not** how this works.

Here, you have a *status level* — Bronze, Silver, Gold, however many levels
the exchange defines — based on how active a trader you've been recently.
**Whatever level you're at when you place a trade, that entire trade gets
priced at that level's rate.** There's no blending. A whale-sized trade from
a Bronze-level trader is charged 100% at the Bronze rate.

The trading you do *right now* helps you level up for your *next* trade —
it doesn't retroactively discount the trade you're currently making.

## Your "activity score"

Your level is based on a rolling activity score, not your all-time volume.

- The exchange looks at the fees you've actually paid (or earned, if you're
  a market maker whose order got filled) over the **trailing ~30 trading
  epochs** — think of an epoch as roughly "one day," so about a month of
  activity.
- Only fees from trades that actually happened count. If you place a buy
  order and later cancel it before it fills, that never counted toward your
  score in the first place — parking a big order and cancelling it can't be
  used to farm a better rate.
- The score is a rolling window, so it ages out. If you stop trading for
  about a month, your score drains back to zero and you fall back to the
  entry level.

*(Code: `fee_turnover.move` — the rolling window is `TURNOVER_WINDOW_EPOCHS`
= 30 epochs.)*

## What determines your rate on any given trade

1. Right before your order is built, the exchange checks your current
   activity score.
2. It finds the highest level your score qualifies for.
3. Your **entire** order is priced at that level's rate.
4. *After* the trade settles, the fees involved get added to your score —
   which might bump you up a level for your *next* trade.

This ordering matters: a trade can never discount itself. You always trade
at the rate you'd already earned, and only benefit from that trade's volume
starting with the next one.

*(Code: `fee_schedule.move`, `resolve()`; `state.move`,
`resolve_trade_rates()`.)*

## How you move up

Simple: keep trading. Two kinds of activity count toward your score:

- **Taker fees you pay** — when your order matches immediately against
  existing orders on the book.
- **Maker fees you earn out** — when an order you placed earlier sits on the
  book and later gets filled by someone else's trade.

Both count only once the trade actually executes — not when you place the
order.

## How you move down

You don't get bumped down mid-trade for trading less. Instead, your score
simply reflects a **trailing** window, so it naturally decays if your recent
activity slows down. Go quiet for about a month and you're back to square
one — the entry-level rate.

## Levels are per pool, not exchange-wide

Every trading pool — each standard pool and each multi-coin pool — has its
**own, completely independent** fee ladder and its own copy of your activity
score.

That means:

- Climbing to a high level on one pool (say, a SUI/USDC pool) gives you
  **no** benefit on any other pool. A different pool, even one you trade
  constantly, tracks your activity separately and starts you at its entry
  level.
- There's no shared or global fee schedule anywhere — an admin configures
  each pool's ladder one pool at a time, and different pools can (and
  typically will) end up with different numbers of levels, thresholds, and
  rates.

*(Code: `pool.move` / `multicoin_pool.move` — each `Pool` /
`MulticoinPool` embeds its own `State`, and `state.move` embeds the
`Governance` — which owns the fee ladder — and the `accounts` table — which
tracks everyone's activity score — inside that same per-pool `State`. Both
live and reset per pool.)*

## Who sets the levels and rates, and how

The exchange's admin (holding a special admin permission) configures the fee
ladder — how many levels there are, the activity threshold to reach each
one, and the taker/maker rate at each level — **separately for each pool.**

A few built-in guardrails, enforced automatically no matter what the admin
sets:

- **Up to 16 levels** per trading pool.
- **The entry level always starts at zero activity** — every trader, even a
  brand-new one, has some tier.
- **Thresholds must strictly increase** as you go up the ladder — no
  duplicate or out-of-order levels.
- **Rates can only get better (or stay the same) as you move up, never
  worse.** More trading activity is never allowed to cost you more.
- **Taker fees have a floor** (a minimum rate that always applies, at any
  level) — they can never be discounted to zero. **Maker fees have no
  floor** — a maker rate of 0% is allowed at the top of the ladder.
- Rate changes don't take effect immediately — they're scheduled for the
  *next* epoch, so nobody's current trade gets re-priced out from under
  them mid-flight.

*(Code: `governance.move`, `set_next_fee_schedule()`;
`fee_schedule.move`, `validate()`.)*

## The actual numbers today

When a trading pool is first created, it starts on a single flat level (no
tiers yet) at these rates, until the admin configures a real multi-level
ladder:

| Pool type | Taker fee | Maker fee |
|---|---|---|
| Standard pool | 2.2% | 1.8% |
| Multi-coin pool | 1.1% | 0.9% |

Bounds the admin must stay within when setting *any* level's rate:

| Rule | Value |
|---|---|
| Minimum taker fee (floor, all levels) | 0.01% (1 basis point) |
| Maximum taker or maker fee | 100% |
| Cancellation retention (share of a cancelled bid's escrow the exchange can keep) | up to 100%, defaults to 20% |

**Important caveat:** beyond that single starting level, there's no
hard-coded "Level 2 costs X%, Level 3 costs Y%" table in the exchange's
code. The number of levels, their activity thresholds, and their discounted
rates are whatever the admin has actually configured for a given pool at any
given time — the code only fixes the *rules* those levels must obey (listed
above), not specific tier numbers beyond the starting rate.

*(Code: `governance.move` — `DEFAULT_TAKER_FEE`, `DEFAULT_MAKER_FEE`,
`DEFAULT_TAKER_FEE_MULTICOIN`, `DEFAULT_MAKER_FEE_MULTICOIN`,
`MIN_TAKER_FEE`, `MAX_TAKER_FEE`, `MAX_MAKER_FEE`,
`DEFAULT_CANCEL_RETENTION_BPS`, `MAX_CANCEL_RETENTION_BPS`.)*

## Quick glossary

| Plain English | Code term |
|---|---|
| Activity score | `fee_turnover` |
| Rolling ~30-day window | `TURNOVER_WINDOW_EPOCHS` |
| Level / tier | `FeeTier` |
| Fee ladder | `FeeSchedule` |
| Someone who trades instantly against the book | taker |
| Someone whose resting order gets filled later | maker |
| Admin sets next level's rates | `set_next_epoch_fee_schedule` |
