# Trade Hub Revenue Share

*Status: [Rollout 02](#02--on-chain-accrual) is implemented — `fee_basis`,
`hub_registry`, the vault counters, the `FeePolicy` ladder, and
`settle_hub_share` / `claim_hub_share` on `multicoin_pool`. Shipping it is inert
until a collection is assigned a share class; the one thing it does change on day
one is the admin sweep, which now has to settle first
([the wart](#the-one-wart-is-not-free)). [Rollout 03](#03--operator-self-service)
and the [open questions](#open-questions) are outstanding.*

How Triex can pay a storage unit owner (a "trade hub operator") a configurable
share of the trading fees earned on their hub — without moving a coin on the
trading path, and without changing a single public trading signature.

> **In this doc:** [The shape](#the-shape) · [Accounting](#accounting-one-balance-three-claims) ·
> [Timing](#timing-accumulate-the-basis-apply-the-rate-later) ·
> [Configuration](#configuration-per-entity-via-share-classes) ·
> [Attribution](#attribution-who-actually-owns-a-hub) · [Payout](#payout) ·
> [Guardrails](#guardrails) · [Alternative](#alternative-operator-surcharge-not-a-share) ·
> [Rollout](#rollout) · [Open questions](#open-questions)

---

## The shape

Every multicoin pool is keyed by `(collection_id, asset_id, quote)`, and
warehouse-receipts mints exactly one multicoin `Collection` per Storage Unit.
So `collection_id` *is* the storage unit — the pool already knows, on-chain,
which hub its flow belongs to (`multicoin_pool.move:55`). Nothing needs to be
introduced to attribute revenue; the attribution is structural.

Fees from that flow land in one place: the pool's `quote_fee_reserve`, a
`Balance<QuoteAsset>` inside `MultiCoinVault`. Part of that pot is not revenue
at all — a bid maker's fee is escrow until their order resolves, tracked by
the counter `locked_maker_fees`, and the admin sweep is capped at
`reserve − locked` so it can never spend an open order's escrow
(`multicoin_vault.move:111`).

That pattern — **one pot, counters for who is owed what** — is the whole
design. Revenue share adds a second claimant to a structure that already has
one.

---

## Accounting: one balance, three claims

Today the reserve carries two claims against one balance:

```
quote_fee_reserve  (one Balance<QuoteAsset>)
├─ locked_maker_fees        → refunded to the maker on cancel/modify-down/expiry
└─ reserve − locked         → withdraw_pool_fees → treasury
```

`locked_maker_fees` is already a counter claiming part of a shared pot, not a
separate balance. The operator's cut should be the same construction, not a
second one — a second `Balance<QuoteAsset>` would mean escrow is tracked as a
counter while the operator's cut is tracked as a balance, for no reason a
reviewer could reconstruct:

```
quote_fee_reserve  (still one Balance<QuoteAsset>)
├─ locked_maker_fees        → refunded to the maker
├─ hub_owed                 → claim_hub_share → operator
├─ holdback()               → provisional: the operator's share of a basis
│                             nobody has settled yet, at the ceiling rate
└─ reserve − encumbered()   → withdraw_pool_fees → treasury
```

One `Coin` split happens at claim instead of one per fee, and it generalizes — a
referrer, a tribe, or an insurance fund are further counters against the same
pot, where separate balances would each need a dynamic field. Two fields on
`MultiCoinVault` carry it:

| Field | Why |
|---|---|
| `hub_owed: u64` | Settled and claimable, beside `locked_maker_fees` |
| `hub_basis: FeeBasis` | Per-epoch recognized revenue, not yet priced |

`FeeBasis` keeps its own running sum rather than exposing the buckets to be
re-summed. `holdback()` is read inside `withdraw_quote_fees`'s asserts, so it has
to be O(1) — a loop over the window on every reserve read would land in the sweep
path. `fee_turnover` keeps `rolling_sum` for exactly that reason and pays for it
only on eviction; `fee_basis` mirrors it, and both are asserted against a
recomputed sum in tests.

### Keeping it safe

What a shared pot costs is safety-by-construction: with a separate balance the
operator's money physically isn't in the reserve, so forgetting to subtract it
is impossible. With a counter, every reserve read has to subtract every claim.
There are five reserve reads today, all inside the vault:

| Site | Today | Becomes |
|---|---|---|
| `withdrawable_quote_fees` (`multicoin_vault.move:111`) | `reserve − locked` | `reserve − encumbered()` |
| `withdraw_quote_fees` (`multicoin_vault.move:393`) | one assert on the raw reserve, one via `withdrawable_quote_fees` | both via `withdrawable_quote_fees` |
| `unlock_quote_fees` (`multicoin_vault.move:366`) | `assert reserve ≥ amount` | unchanged — escrow is never credited to a drawer |
| `quote_fee_reserve_balance` (`multicoin_vault.move:99`) | raw view | keep, but pair with `hub_owed()` at the pool level |

Route all of them through one accessor:

```
encumbered() = locked_maker_fees + hub_owed + holdback()
holdback()   = ceil(unsettled_basis × MAX_HUB_SHARE_BPS / 10000)
```

and make the review rule mechanical: **nothing inside the vault reads
`quote_fee_reserve.value()` except `encumbered()`'s callers.** (The rule is
about the vault's internals. `quote_fee_reserve_balance` is already a published
view at `multicoin_pool.move:1031` and `pool.move:1303`; it stays raw, paired
with `hub_owed()` and `hub_basis()` so an indexer can do the subtraction
itself.)

The invariant is then `reserve ≥ encumbered()`, and it holds inductively across
all six operations that touch the reserve:

| Operation | Reserve | `locked` | `basis` | `owed` | Holds because |
|---|---|---|---|---|---|
| Taker fee deposited | `+T` | — | `+T` | — | `T ≥ ceil(T × MAX/10000)` for any `MAX ≤ 10000` |
| Maker escrow deposited | `+M` | `+M` | — | — | Escrow is never basis |
| `recognize(d)` | — | `−d` | `+d` | — | `d` leaves `locked` and re-enters at a fraction of itself |
| `unlock(a)` | `−a` | `−a` | — | — | `a ≤ locked` always (see below) |
| `settle` | — | — | `→0` | `+floor(basis × bps/10000)` | `bps ≤ MAX_HUB_SHARE_BPS`, and `floor ≤ ceil` |
| `claim` | `−owed` | — | — | `→0` | The coin is there by the invariant |

Two arithmetic details the invariant actually rests on, both easy to get
backwards:

- **Round the holdback up and `owed` down.** Reversed, `settle` can credit one
  unit more than the holdback reserved and `reserve − encumbered()` underflows.
- **Do the bps math in `u128`.** `basis × MAX_HUB_SHARE_BPS` overflows `u64`
  above ~4.6 × 10¹⁵ raw quote units. `quote_fee::fee_from_scaled_rate` and
  `split_released_fee` both widen before multiplying; match them.

`unlock(a) ≤ locked` is worth spelling out because the whole escrow column
depends on it: `quote_fee::split_released_fee` guarantees `refund + retained ==
basis` exactly, and a release never exceeds what the order locked, so a refund
cannot reach past escrow into revenue. That is why `unlock_quote_fees` needs no
change. The residue drift documented on `locked_maker_fees` only ever leaves
`locked` too *high*, which is the same safe direction.

One loose end to close while instrumenting: `deposit_quote_fees`
(`multicoin_vault.move:347`) joins straight into `quote_fee_reserve` with no
basis accrual and no escrow lock. It has no production caller today — only
tests — but it is `public(package)`, so wiring it up later would silently
underpay the operator. Mark it `#[test_only]` or accrue in it.

> **One hazard worth a test.** `recognize_locked_maker_fees`
> (`multicoin_vault.move:129`) decrements by `amount.min(self.locked_maker_fees)`,
> not by `amount`. Credit the drawer off the *actual decrement*, not the
> requested amount — crediting the requested amount turns the documented
> residue drift into a silent over-credit.

---

## Timing: accumulate the basis, apply the rate later

A counter doesn't have to hold the *split* — it can hold the **basis**: the
revenue recognized, undivided. That single reframing takes the rate off the
trading path entirely.

```
hub_basis[epoch]  ──▶  settle_hub_share  ──▶  hub_owed  ──▶  claim_hub_share
  (every fill,          (permissionless,        (paid to the
   cancel, expiry;        off the hot path;       configured
   one u64 add,           reads &FeePolicy —      address)
   no policy read)        the only place it
                          enters; epoch N basis
                          × epoch N rate)
```

`place_limit_order`, `swap_*`, `cancel_order`, `modify_order` — **every public
trading signature stays exactly as it is**, and no trade reads a new object.

This resolves the one genuinely awkward constraint in the current codebase:
`cancel_order`, `modify_order`, `cancel_orders` and `cancel_all_orders` do not
take `&FeePolicy` — they settle against the retention rate snapshotted on the
order — so a rate read is unavailable at two of the three recognition sites.
Accumulating the basis means no rate is needed there at all. **No cached rate
on the pool, and no sync call.**

What it does cost is an epoch. Bucketing the basis needs `ctx.epoch()`, and
`clock.timestamp_ms()` is not an epoch — the policy stages on epoch numbers, so
nothing else will do. Two `public(package)` vault functions therefore gain an
`epoch: u64`:

| Function | Today | Needs |
|---|---|---|
| `recognize_locked_maker_fees` (`multicoin_vault.move:129`) | `(self, amount)` | `(self, amount, epoch)` |
| `move_quote_to_fee_reserve` (`multicoin_vault.move:329`) | `(self, pool_id, ta_id, amount, timestamp)` | `+ epoch` |

`ctx` is already in scope at all six call sites — `multicoin_pool.move:637`,
`:694`, `:1376` and `pool.move:558`, `:612`, `:1750` — so the change stops at
the package boundary. **Every public and entry signature is untouched; the two
internal ones are not.** Stating it the other way round would be wrong, and the
distinction is the whole reason this is cheap.

### Why the buckets are per epoch

Applying whatever rate happens to be live at settlement would price a whole
accrual window wrong. Keying the basis by epoch and applying epoch *N*'s rate
to epoch *N*'s basis reproduces split-at-recognition exactly — the same accuracy
that would motivate splitting per fee, without the rate ever touching a trade.

**But the hub ladder cannot be shaped like `ClassSchedule`.** `FeePolicy` stages
a fee change one epoch ahead, and that is all it does: `update_class`
(`fee_policy.move:306`) promotes `next` into `current` and overwrites `next`, so
a class holds exactly two rates and no history. After two updates, epoch *N*'s
rate exists only in the `FeeClassUpdated` event stream — off-chain, where
`settle_hub_share` cannot reach it. Copying that struct by analogy would make
"epoch *N*'s rate" unrecoverable precisely when settlement is late, which is
when it matters.

So the hub ladder is **append-only segments**, not current/next:

```
HubShareClassKey: u16 → vector<{ from_epoch: u64, bps: u16 }>
```

The admin appends one segment per re-price, `from_epoch = ctx.epoch() + 1` (the
pre-announcement property, kept explicitly rather than inherited). `settle` for
epoch *N* takes the last segment with `from_epoch ≤ N`. Growth is admin-cadence,
and segments older than the ring floor are prunable, so the vector stays small.

This is not only an accuracy fix — it closes a griefing surface. Settlement is
permissionless, so if epoch *N*'s price were "whatever the ladder resolves to
now," the settle call would be a free option on every staged rate change:
settle early to dodge a cut, wait to capture a hike, and since either party may
call it, whichever party benefits calls first. With the rate pinned to the epoch
that earned it, *when* someone settles cannot change *what* they get — pinned by
`a_late_settlement_uses_the_rate_of_the_epoch_that_earned_it`, which cuts the rate
twice before settling and still pays the original.

> **A second thing not to inherit by analogy.** `cancel_retention_bps` is *not*
> staged. `update_class` writes it unconditionally at `fee_policy.move:311`,
> outside the `effective_epoch` gate at `:306`, so it takes effect immediately —
> harmless there, because orders snapshot retention at placement. "`FeePolicy`
> stages every rate change" is therefore not the uniform precedent it looks
> like. If hub rates are to be pre-announced on-chain — and they should be, it is
> what an operator underwrites a hosting decision with — the `from_epoch` gate
> above has to be written and tested, not inherited.

Bound the buckets with a ring in the shape of `fee_turnover`'s;
`TURNOVER_WINDOW_EPOCHS = 30` is the standing precedent and a defensible number
to publish. See [Payout](#payout) for what eviction must not do quietly.

### Recognition sites

Revenue is recognized at exactly three points. Getting this list wrong is the
single most dangerous mistake available in this design, so it is worth stating
what each one is *not*.

| Recognized | Amount | Where |
|---|---|---|
| Bid taker fee | `taker_fee_amount` from the `QuoteFeeDeposit` — **not** `taker + maker` | `settle_trading_account` (`multicoin_vault.move:210`) |
| Ask fees carved out of proceeds | each `proceeds_fee.amount()` | the proceeds loop, `multicoin_pool.move:1366` / `pool.move:1740` |
| Escrow earned out | the **actual decrement** inside `recognize_locked_maker_fees` | `multicoin_vault.move:129`, reached from placement, `cancel_order`, `modify_order` |

> **`move_quote_to_fee_reserve` is not a recognition site.** It is the shared
> *deposit* primitive, and instrumenting it is the trap. `settle_trading_account`
> calls it with `taker_fee_amount + maker_fee_amount`
> (`multicoin_vault.move:219-224`) and only then classifies the maker half as
> escrow (`:227`). The ask-proceeds loop calls the same function with
> already-earned revenue. From inside, the two are indistinguishable.
>
> Accruing `amount` there *and* the taker half in `settle_trading_account` *and*
> the escrow at earn-out counts one bid order three times: `(T+M) + T + M` for a
> `T + M` fee. That is not a rounding problem. The holdback is
> `ceil(unsettled_basis × MAX_HUB_SHARE_BPS / 10000)`, so an over-stated basis
> can demand more than the reserve holds — maker fee 1000, taker fee 1,
> cancelled at the genesis 20% retention: real revenue 201, basis 1202, holdback
> at a 40% ceiling 480. `reserve − encumbered()` underflows, and a `u64`
> underflow in Move aborts. That permanently kills `withdraw_pool_fees` *and*
> the public `withdrawable_pool_fees()` view for that pool, and `settle` then
> writes `hub_owed > reserve` so `claim_hub_share` aborts forever too. Trading
> keeps working — the trade path never reads that accessor — so the failure is
> silent until someone tries to take money out.

Two ways to implement the table, and the choice is a real one:

- **Instrument the two callers.** `settle_trading_account` accrues
  `taker_fee_amount`; the proceeds loop accrues per fee. Exact and obvious, but
  it means edits in `multicoin_pool.move` and `pool.move`, not the vault alone.
- **Keep it vault-only** *(recommended)*. Accrue `amount` inside
  `move_quote_to_fee_reserve`, then have `settle_trading_account` subtract
  `maker_fee_amount` back off the same bucket on the line where it adds to
  `locked_maker_fees` (`:227`). Same epoch, same call, nets to the taker fee
  exactly — and it keeps one rule worth having: **the basis moves only where
  escrow classification moves.**

The vault-only route is what shipped. It is pinned by
`basis_counts_recognized_revenue_exactly_once`, which asserts the identity

```
hub_unsettled_basis == quote_fee_reserve − locked_maker_fees
```

after placement, after a partial fill, and after cancelling the remainder. That
holds exactly whenever nothing has been settled, swept or claimed — deposits raise
escrow and revenue together, refunds lower both, and recognition moves value
between them — so it catches a double-count and a *missed* site with the same
assertion. Checking only a fill would pass the triple-count.

### The one wart is not free

> **The one wart.** Until a basis is settled, `withdraw_pool_fees` cannot know
> how much of it is the operator's, so its cap must assume the worst — that is
> what `holdback()` is. It uses the compile-time ceiling rather than a rate, so
> `withdraw_pool_fees` still needs no `&FeePolicy` (it has none today:
> `multicoin_pool.move:838`), and the over-lock disappears the moment anyone
> settles. Put `settle_hub_share` ahead of `withdraw_pool_fees` in the same PTB
> and it never binds.
>
> The holdback is also the load-bearing reason the recognition list above must
> be exact. It converts an over-stated basis directly into a claim on coins that
> were never collected.

Worth being straight about what that costs, because "additive, default 0 bps, so
shipping it changes nothing" is true of the *payout* and not of the sweep. The
holdback cannot read a rate, so it binds at the ceiling on **every** multicoin
pool from the first fill after deploy — including pools whose hub is in no share
class at all and whose basis will settle to zero. Nothing is lost, and nothing is
paid out that shouldn't be; but until someone calls `settle_hub_share`, 40% of
each pool's recognized revenue is not sweepable.

So the deploy has one required operational change: **the treasury sweep becomes
settle-then-withdraw**, in one PTB. That is a change to admin tooling, not to any
trading path, and it is pinned by
`test_multicoin_admin_withdraws_quote_fee_reserve` — which now asserts the
withdrawal aborts without the settle in front of it.

---

## Configuration: per entity, via share classes

The exchange already solved "configurable pricing, per group, without
per-pool fan-out" once: `FeePolicy` holds fee *classes*, pools store a 2-byte
class id, and a negotiated deal is just a class with one pool in it. The rate
side of revenue share should reuse that idiom rather than invent a second
configuration surface. The *payout address* should not — see below.

`FeePolicy` is a `key` object with a `UID` (`fee_policy.move:138`) but no
versioned inner, so its struct cannot gain fields on upgrade — **dynamic
fields on its `id` can**. Three tables, all additive, all admin-written:

| Table | Key → value | Purpose |
|---|---|---|
| `HubShareClassKey` | `u16` → `vector<{ from_epoch, bps }>` | The rate ladder, append-only (see [Timing](#why-the-buckets-are-per-epoch)). Re-price every hub in a class in one transaction |
| `HubShareKey` | `ID` (collection) → `u16` | Which class each entity is in. Absent → default class |
| `DefaultHubShareKey` | `u16` | Class for hubs nobody has configured. Ships as class 0 = 0 bps |

### Where the beneficiary must *not* live

The payout address is the one piece of this configuration an operator writes
themselves, and that disqualifies `FeePolicy` from holding it.
`fee_policy.move:7` states the constraint as an invariant on the module:

> *`FeePolicy` must stay read-mostly. Writes are admin-only and epoch-cadence by
> design; nothing on any user-reachable path may ever take it `&mut`.*

Operator self-service rotation is a user-reachable path, and it would take
`&mut` on the single global object every trade on the exchange reads immutably.
Immutable reads of a shared object commute; a write does not. A cap holder could
also simply rotate in a loop. The three tables above are fine there — admin-only,
epoch-cadence, exactly what the invariant allows — but the beneficiary is not.

So it gets its own small shared object:

| Object | Holds | Written by | Read by |
|---|---|---|---|
| `FeePolicy` | rate ladder, class assignment, default class | admin, epoch cadence | `settle_hub_share` |
| `HubRegistry` | `ID` (collection) → `address` | the operator, via the gated setter below | `claim_hub_share` |

`HubRegistry` keeps rotation one write per hub rather than one per pool, and —
the point — **the trading path touches neither object.** Contention is confined
to rotations sequencing against concurrent claims, and neither is on a trade.

This is what "configurable by entity" buys in practice: a standard class at
10%, a launch-partner class at 25%, and a single anchor hub in a class of its
own at 40% — each a one-line table write, each pre-announced on-chain through
`from_epoch` before it takes effect, and each auditable by the operator before
they commit to hosting.

Entity granularity is a product choice the key encodes. `collection_id` is one
storage unit. A tribe running eight hubs is eight collection ids pointing at
one class and one beneficiary address — which is also how you pay a tribe
treasury rather than a character. If per-quote rates are ever wanted, widen
the key to `(collection_id, quote)`; nothing else changes.

---

## Attribution: who actually owns a hub

There is a complete on-chain path from a pool to a named player, and the app
already walks it:

```
MultiCoinPool.collection_id            ← the pool already knows this
  └─ VaultConfig { storage_unit_id }   binds collection ↔ SSU
       └─ StorageUnit.owner_cap_id     an ID, not an address
            └─ OwnerCap<StorageUnit>   an owned Sui object
                 └─ its Sui owner      a wallet address
                      └─ Character.character_address → tribe_id, name
```

`etl-api`'s `AssemblyOwnerService.getOwnersByAssemblyIds` already performs the
assembly → `owner_cap_id` → wallet resolution behind a five-minute cache, and
the characters service indexes `character_address` and `tribe_id`. Resolving a
hub to a player is a solved problem. Whether to *pay* off that resolution is
the open question, and there are three reasons not to:

- **Ownership is a cap-holder, and caps move.** `StorageUnit` stores
  `owner_cap_id`, never an owner address. `transfer_owner_cap_to_address` is
  public, so a hub can change hands at any time — emitting
  `OwnerCapTransferred { previous_owner, owner }`. Anything keyed on "current
  owner" retargets silently, mid-accrual.
- **The holder may be an object, not a wallet.** `receive_owner_cap` and
  `ReturnOwnerCapReceipt` exist so caps can be parked on other objects;
  `etl-api`'s own extractor handles `ObjectOwner` and
  `ConsensusAddressOwner` alongside `AddressOwner`. An owner address that is
  an object id cannot usefully receive a `Coin`. The world module's comments
  flag tribe and corporation caps as future work.
- **Both identity fields are sponsor-mutable.** `update_address` changes a
  character's wallet and `update_tribe` changes their tribe, each gated only
  on `admin_acl.verify_sponsor` — the game server. Keying payment on a
  character's current address, or on tribe membership, means a game-side
  action can redirect money.

### So: resolve for decisions, configure for payment

`HubRegistry`'s `collection_id → address` table stays the source of truth for
where money goes. The ownership walk above is how you *decide* what to put in it,
and how you detect that a hub changed hands.

Rotation can still be trustless without coupling the exchange to the game
world. The SSU owner presents their `OwnerCap<StorageUnit>` and the
`VaultConfig` to a thin adapter package, which checks
`is_authorized(cap, vault_config.storage_unit_id())` and
`vault_config.collection_id() == pool.collection_id()`, then mints a witness for
`set_hub_beneficiary<W: drop>` on `HubRegistry`. Triex stays collection-agnostic
and dependency-free; the operator self-serves; and the standing payout target
remains an explicit address that a hub sale, a parked cap, or a tribe change
cannot silently move.

> **The witness has to be a *registered* type, not just any `drop` type.** A
> bare `<W: drop>` bound authorizes nothing — anyone can publish
> `public struct Fake has drop {}` and call `set_hub_beneficiary<Fake>` to point
> any hub's payouts at themselves. The gate only exists if the callee pins the
> type: store the adapter's `TypeName` (admin-set, one value) and assert
> `type_name::with_defining_ids<W>() == registered`. That is the idiom
> `assert_class_matches_quote` already uses for quote types, and it keeps Triex
> free of any dependency on the adapter — it compares a name, it does not import
> a module.

> **Leave an admin override.** `delete_owner_cap` is sponsor-callable in
> world-contracts. A destroyed cap means the operator can never rotate again
> while the stale address keeps collecting, and no amount of adapter design fixes
> that from the operator's side.

> **Decide the sale case explicitly.** Accrued-but-unclaimed balance pays to
> whoever is configured at claim time, which after a hub sale may be the wrong
> party. Either make "claim before you sell" the convention, or treat the
> accrual events as the settlement record between buyer and seller. Freezing
> claims on cap transfer is not available — the exchange cannot observe it.

---

## Payout

`claim_hub_share<QuoteAsset>(pool, policy, registry, clock, ctx)` settles any
outstanding basis, zeroes `hub_owed`, splits that much off the reserve, and
transfers it to the beneficiary `registry` records for the collection. No
capability required — the destination comes from configuration, not from the
caller, so there is nothing to steal by calling it. That lets Triex run a payout
cron, lets the operator self-serve, and lets either side batch dozens of pools
into one PTB.

Emit:

- `HubShareSettled { pool_id, collection_id, epoch, basis, bps, owed }`
- `HubShareClaimed { pool_id, collection_id, beneficiary, amount, timestamp }`
- `HubBasisForfeited { pool_id, collection_id, epoch, amount }`

Between them an operator reconciles every unit they are owed from events alone,
including the rate each epoch was priced at — the standard the existing
`PoolFeesDeposited` / `PoolFeesRefunded` pair already sets. Every unit of basis
leaves the ring through exactly one of `HubShareSettled` or `HubBasisForfeited`,
which is what makes the pair sufficient.

> **No accrual event.** An earlier draft emitted one per recognition. That lands
> on the hottest path in the exchange — a fill with `N` maker matches recognizes
> `N + 1` times — for a feature that is off for every hub by default, and it buys
> nothing reconciliation needs: `HubShareSettled` already carries each epoch's
> basis, and `PoolFeesDeposited` already carries deposit-level detail. The accrual
> is a `u64` add and nothing else.

That last event is the one not to skip. A ring in `fee_turnover`'s shape evicts
by overwriting a bucket and subtracting it from the running sum, which here means
an unsettled epoch's basis is deleted *and* its holdback released into the next
admin sweep. Copying the shape silently answers "what happens past the ring?" in
the treasury's favour. If that is the intended answer it is a defensible one —
but it has to be emitted, or "reconcile from events alone" stops being true
exactly when an operator most needs it to be.

### The operational shape of a claim

Worth stating plainly, because it is a commitment rather than a detail: settle
and claim are **per pool**, while the beneficiary is **per collection**. Pools
are keyed `(collection_id, asset_id, quote)`, so a hub trading 200 item types is
200 pools, each accruing its own basis and each needing a settle before its
bucket ages out. At a 30-epoch ring that is 200 settles a month per hub, plus
claims — fine automated, impossible by hand. And if Triex runs that cron, the
self-service story in [Rollout 03](#rollout) is about *who controls the payout
address*, not about who does the work. Say which one is being promised.

Expose `hub_owed()` and `hub_basis()` at the pool level beside the existing
`locked_maker_fees()` and `withdrawable_pool_fees()` views
(`multicoin_pool.move:1031`), so the counters are readable without an indexer.

---

## Guardrails

What the mechanism cannot do:

- **Reach escrow.** Only recognized revenue accumulates into the basis. A
  maker's refundable fee is never counted, so cancel refunds cannot come up
  short.
- **Be swept by the admin.** `withdrawable_quote_fees` subtracts every
  counter, and the unsettled basis is held back at the `MAX_HUB_SHARE_BPS`
  ceiling. The treasury cannot take an accrued share.
- **Be over-drawn by the operator.** `claim_hub_share` pays at most
  `hub_owed`, and only to the configured address. `reserve ≥ encumbered()`
  guarantees the coin is there.
- **Change what traders pay.** This divides existing revenue. Taker and maker
  rates, tier ladders and quotes are untouched — dry-run quotes stay exact.
- **Exceed a ceiling.** Bound class rates with `MAX_HUB_SHARE_BPS` and state
  the number in `CAPABILITIES.md` the way `MAX_TAKER_FEE` is stated today, so
  the trust document stays true. Note what this bound is and is not: capping the
  *rate* only caps the payout if the *basis* is exact. A double-counted basis
  pays over the ceiling as measured against revenue actually collected, with the
  rate still nominally in bounds — which is why
  [Recognition sites](#recognition-sites) is the section to review hardest.
- **Serialize the exchange.** The trading path reads no new object and writes one
  `u64` on a pool it already holds mutably — no new event, and no policy read. Both
  `FeePolicy` and `HubRegistry` are touched only by settlement and payout, neither
  of which is on a trade.

---

## Alternative: operator surcharge, not a share

Worth naming because it is a different product, not a variant. Instead of
dividing Triex's fee, let each hub set its own surcharge *on top* of the
protocol rate. Operators then compete on price and traders see hub-level
differences.

| | Share of protocol fee *(recommended)* | Operator surcharge |
|---|---|---|
| Who pays | Triex, out of existing revenue | The trader, on top |
| Quoted price | Unchanged | Changes per hub; must be snapshotted on the order like `maker_fee_rate` |
| Trading path | One `u64` add | Enters order pricing and every dry-run quote |
| Failure mode | Triex's margin compresses | Operators price hubs out of use; fee-tier turnover accounting gets murkier |
| Rollout | Additive; default 0 bps is a no-op | Touches `order`, `book`, indexer decoding |

Both are feasible without breaking public signatures — `resolve_with_retention`
is `public(package)` and the pool has `collection_id` in scope. The share
model is the right first move: reversible, invisible to traders, and it does
not require deciding hub price competition before there are hubs competing.

---

## Rollout

Prove the economics before writing them to chain.

### 01 — Off-chain, this week

Per-pool net revenue is derivable from events today, grouped to a hub through
the `collection_id` on `MultiCoinPoolCreated`. The app already surfaces this per
storage unit in `adminPoolService.fetchStorageUnitFees`. Hold the rate per entity
in a database, pay from treasury, settle manually. No contract change, real
numbers in front of real operators.

**Get the formula right before it pays anyone.** `Σ PoolFeesDeposited −
Σ PoolFeesRefunded` is *not* net revenue — it over-states it by every unit of
bid-maker escrow currently locked against an open order. `PoolFeesDeposited`
carries `taker + maker` for a bid (`multicoin_vault.move:219-224`), and the
maker half is refundable until the order resolves, so an operator paid on that
figure is paid on orders that never traded — the same loophole `fee_turnover`
exists to close on the tier ladder. Two ways to state it correctly:

```
revenue = Σ PoolFeesDeposited − Σ PoolFeesRefunded − locked_maker_fees()
        = withdrawable_pool_fees() + Σ PoolFeesWithdrawn
```

Both are exact up to the residue drift documented on `locked_maker_fees`, which
leaves `locked` slightly high and so under-states revenue — the safe direction
for a manual payout. The views are already public at `multicoin_pool.move:1037`
and `:1042`.

### 02 — On-chain accrual

**Implemented.** What landed:

| Piece | Where |
|---|---|
| Per-epoch basis ring, with reported eviction | `state/fee_basis.move` |
| `hub_owed`, `hub_basis`, `encumbered()`, `holdback()`, settle/claim primitives | `vault/multicoin_vault.move` |
| Append-only rate ladder, class assignment, default class | `fee_policy.move` (dynamic fields) |
| `collection_id -> address` | `hub_registry.move` |
| `settle_hub_share`, `claim_hub_share`, `hub_*` views | `multicoin_pool.move` |
| `HUB_BASIS_WINDOW_EPOCHS = 30`, `MAX_HUB_SHARE_BPS = 4000` | `helper/constants.move` |

Coin pools are untouched: `pool.move` and `vault/vault.move` have no
`collection_id` and therefore no hub, so neither the counters nor the holdback
exist there.

No public or entry trading signature changed. Two `public(package)` vault
functions gained parameters, as
[Timing](#timing-accumulate-the-basis-apply-the-rate-later) sets out.

Default 0 bps means **no hub is paid anything** until a collection is assigned a
class — but see [the wart](#the-one-wart-is-not-free) for the one thing the deploy
does change on day one.

`HubRegistry` writes are admin-only until 03. That is deliberate: the beneficiary
table is useful before the self-service path exists, and shipping it admin-gated
first means the registered-witness setter gets reviewed as an authorization change
rather than as a rider on fee accounting.

### 03 — Operator self-service

The registered-witness beneficiary setter plus the adapter package, so an SSU
owner rotates their own payout address against `OwnerCap<StorageUnit>`. Pair it
with a hub-operator dashboard reading the accrual, settlement, claim and
forfeiture events. Register the adapter's `TypeName` in the same transaction that
publishes it, and keep the admin setter as the override for a destroyed cap.

---

## Open questions

**Is cancel retention shared?** *Answered: yes, provisionally.*
The retained 20% of a cancelled maker's escrow is revenue, but it is anti-spam
revenue, not trade revenue the hub generated. It accrues, because
`recognize_locked_maker_fees` is the same site for a fill's earn-out and a
cancel's retention and splitting them would mean distinguishing two callers that
pass the same figure. Still one line to change, and
`cancel_retention_accrues_to_the_hub` pins the current answer so reversing it has
to be deliberate rather than incidental.

**How deep is the epoch ring, and what happens past it?** *Partly answered.*
`HUB_BASIS_WINDOW_EPOCHS` shipped at **30**, matching `TURNOVER_WINDOW_EPOCHS` —
two trailing per-epoch windows over recognized revenue, and an operator reading
one should not have to learn a second deadline. Eviction forfeits to the treasury
and emits `HubBasisForfeited`, so it is recorded rather than quietly released.

What is still open is whether forfeiting is the right answer at all, and
[the per-pool claim load](#the-operational-shape-of-a-claim) is what decides
whether it ever bites: 30 epochs is generous for one pool and less so for an
operator with a wide inventory and no automation. If the answer is "it should
never happen", the fix is a deeper ring, not a different rule.

**Who runs the settle cron?**
Not a contract question, but the one most likely to decide whether this works. A
basis has to be settled before its bucket ages out, per pool, and
[the claim load](#the-operational-shape-of-a-claim) scales with a hub's inventory
breadth rather than its revenue. Whoever runs it is making a commitment to
operators; if it is Triex, say so, because the trustless rotation in
[Rollout 03](#03--operator-self-service) then controls the destination and not the
timeliness.

**What is the entity of record?**
Storage unit is the natural on-chain key and what this design assumes. If
deals are struck with tribes, the class assignment stays per-collection but
the beneficiary and the negotiation both live at tribe level.

**Who absorbs a hub sale mid-accrual?**
See the note under [Attribution](#attribution-who-actually-owns-a-hub). The
contract cannot arbitrate it; the choice is between a stated convention and
treating the events as the record.

**Does the CRED pool-creation fee get shared?**
Creating a pool for a hub's collection benefits that hub. The creation fee
currently goes whole to the treasury address; routing a slice is independent
of everything above.

**Ceiling and default?**
`MAX_HUB_SHARE_BPS` is a trust commitment as much as a bound — and under this
design it also sets how much of an unsettled basis the treasury has to hold
back.
