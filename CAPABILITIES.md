# Capability Objects in Trinary Exchange

This document catalogs every capability ("cap") object across the two packages in
this repository — [`triex/`](packages/triex/) and [`token/`](packages/token/) — and spells
out what the operator (Trinary Exchange) can and cannot do with each one.

On Sui, a capability is an object whose *possession* is the authorization: any
function that takes `&SomeCap` as a parameter can only be called by whoever owns
that object. None of the caps below carry data used for auth — they are pure
proof-of-ownership tokens.

| Capability | Package / Module | Held by | Purpose |
|---|---|---|---|
| `TriexAdminCap` | `triex::registry` | Operator (package publisher) | Protocol administration |
| `TreasuryCap<CRED>` | `token::cred` (wrapped in `ProtectedTreasury`) | Nobody — locked in a shared object | CRED supply control (burn-only) |
| `TradeCap` | `triex::trading_account` | Whoever a TradingAccount owner delegates to | Trade on behalf of a TradingAccount |
| `DepositCap` | `triex::trading_account` | Whoever a TradingAccount owner delegates to | Deposit into a TradingAccount |
| `WithdrawCap` | `triex::trading_account` | Whoever a TradingAccount owner delegates to | Withdraw from a TradingAccount |
| `UpgradeCap` (implicit) | Sui framework | Operator (package publisher) | Upgrade the published packages |

---

## 1. `TriexAdminCap` — the operator's protocol cap

Defined in [`registry.move`](packages/triex/sources/registry.move). Minted exactly
once in the package `init` and transferred to the publisher (the operator). It
has `key, store`, so it can be transferred, moved to a multisig, or locked in a
timelock wrapper later.

Every admin entry point takes it as a read-only reference (`_cap:
&TriexAdminCap`). The operator's powers fall into three modules:

### Registry administration (`triex::registry`)

| Function | What the operator can do |
|---|---|
| `set_treasury_address` | Redirect where pool-creation fees are sent. Defaults to the publisher. |
| `enable_version` / `disable_version` | Not callable here any more: the registry's allowed-version set changes only through the `fee_policy` functions of the same name (below), which change `FeePolicy`'s copy in the same call. |
| `add_approved_quote` / `remove_approved_quote` | Manage the approved quote-currency list. Adding enforces a minimum-decimals check on the coin metadata so fee precision stays meaningful (an unchecked variant exists but is `#[test_only]`). |
| `init_trading_account_map` | One-time creation of the owner → trading-account-IDs table on the registry. Idempotent. |

### Pool administration (`triex::pool` — the pair-based order book)

| Function | What the operator can do |
|---|---|
| `create_pool_admin` | Create a pool with **zero creation fee**, bypassing the fee charged on the permissionless `create_pool` path. |
| `stage_pool_fee_class` / `apply_pool_fee_class` | Move a pool to another pricing class, in two steps. `stage_pool_fee_class` announces the move on the shared `FeePolicy` (`PoolFeeClassStaged`) and changes nothing; `apply_pool_fee_class` carries it out, and aborts until the **next epoch** has arrived. This is the only per-pool fee operation: rates themselves live in `triex::fee_policy` (below). A resting order keeps the rates it snapshotted at placement, so a move never re-prices it. |
| `unregister_pool_admin` | Unregister a pool from the registry so the trading pair can be redeployed. The pool object itself keeps operating for existing state, but is marked unregistered. |
| `update_allowed_versions` | Sync a pool's allowed-versions set from the registry. Note: a permissionless equivalent, `update_pool_allowed_versions`, exists, so this is not an exclusive power. |
| `withdraw_pool_fees` | **Withdraw earned quote-denominated trading fees** from the pool vault into a `Coin<QuoteAsset>` for treasury custody. This is the operator's revenue-collection path. Capped at `withdrawable_pool_fees()` — the reserve minus `locked_maker_fees()`, the escrow backing open bid orders — so a sweep can never spend a maker's refundable fee (`EFeesLocked`). Emits a `PoolFeesWithdrawn` event. |

Disabled (commented-out) admin features that may return in future versions:
EWMA volatility controls (`enable_ewma_state`, `set_ewma_params`) and
tick/min-size adjustment.

### MultiCoinPool administration (`triex::multicoin_pool`)

Mirrors the pool module, per collection asset:

- `create_pool_admin` — fee-free pool creation for a `(Collection, asset_id)` pair
- `stage_pool_fee_class` / `apply_pool_fee_class` — the same staged class move
- `unregister_pool_admin`
- `update_allowed_versions` (permissionless equivalent also exists)
- `withdraw_pool_fees` — sweep earned quote fees to treasury, capped at `withdrawable_pool_fees()`

### Fee policy administration (`triex::fee_policy`)

Every fee schedule on the exchange lives in one shared `FeePolicy` object. A
pool stores only the id of the pricing class it belongs to.

| Function | What the operator can do |
|---|---|
| `bootstrap_quote` | Stand up launch pricing for a quote currency: create its coin and multicoin classes on the genesis ladder and register both as the defaults new pools of that quote are born into. |
| `create_class` | Create a pricing class: a **fee-tier ladder** (thresholds, taker rates, maker rates) plus a cancel-retention rate. Live immediately, which is safe because a new class has no pools: a trading pool can only reach it through the staged move above. `fee_schedule::validate` rejects ladders that are empty, exceed 16 tiers, do not start at zero turnover, have non-ascending thresholds, or price more turnover *higher* on either side. |
| `update_class` | Re-price an existing class for **every pool in it**: the ladder and the cancel retention together, staged for the next epoch. Direct admin control of pricing deliberately **replaces DeepBook's upstream proposal/voting system**, which is disabled in this fork (CRED carries no voting rights). |
| `set_default_class` / `set_multicoin_default_class` | Choose the class new pools of a quote are born into. Affects pools created afterwards only. |
| `halt_trading` / `resume_trading` | **The kill switch.** One transaction stops every new order, swap and permissionless pool creation on every pool, because they all read this object. Exits stay open; see below. Idempotent, and announced with `TradingHaltChanged`. |
| `enable_version` / `disable_version` | **The version gate.** Allow or retire a package version, **including the one running**, on the registry and on `FeePolicy` in one call, so the two sets cannot drift. Retiring a version stops that version's code, at once, in every `TradingAccount` entry point that creates an account, moves funds, mints a cap or makes a proof (revoking a cap stays open), in every `FeePolicy` write except `halt_trading`, and in every new order, swap and pool creation on every pool. What it can still do on a pool ends when that pool's cached set is refreshed after the disable (`update_pool_allowed_versions`, permissionless). Both switches are exempt from the gate, so a retired version can always be re-enabled. See below. |

#### How high fees can be set, and how fast

Worth stating plainly, because it bounds everything in the sections above.

**The cap.** `MAX_TAKER_FEE` and `MAX_MAKER_FEE` are both **20%**
(`fee_policy.move`), checked on every rung of every ladder `create_class` and
`update_class` accept. Taker rates keep a 1 bp floor; maker rates may be zero.
`MAX_CANCEL_RETENTION_BPS` is 100%, so a cancel can be configured to refund
none of a bid's fee escrow (never its principal). Launch defaults are far below
the cap: 2.2% / 1.8% taker / maker for multicoin pools, 1.1% / 0.9% for coin
pools, 20% cancel retention — see
[`packages/triex/docs/fee-tiers-explained.md`](packages/triex/docs/fee-tiers-explained.md).

**The notice.** Nothing re-prices a live pool without notice. A pool's pricing
changes in exactly two ways, and both are announced on-chain at least one epoch
boundary before they can take effect:

- *Its class is re-priced* (`update_class`). The new ladder and retention take
  over exactly at the **next epoch boundary**, and are visible beforehand
  through `pool_fee_schedule_next()` and `fee_policy::cancel_retention_bps()`.
- *It is moved to another class* (`stage_pool_fee_class`, then
  `apply_pool_fee_class`). The move is visible from the moment it is staged
  through `pool_fee_class_next()` (the destination's ladder through
  `fee_policy::next_schedule()`), and cannot be applied before the next epoch.
  It lands when the operator applies it, which may be later than the boundary
  but never earlier. Until then the pool's current class keeps pricing it,
  including any re-price of that class, so `pool_fee_schedule_next()` keeps
  reporting the current class.

Neither ever re-prices an order already resting: an order snapshots its maker
rate and its retention at placement.

#### How much of a fee can be diverted to a hub operator

Multicoin pools can pay the storage unit they trade against a share of the fees
recognized on them. `MAX_OPERATOR_SHARE_BPS` is **100%** (`constants.move`), and it
bounds both what the admin can configure and what a recognition can credit — the
vault re-checks it rather than trusting the policy to have done so.

Read it as a bound on redistribution, not on cost: a share divides fees already
collected, so it cannot change what a trader pays, and taker/maker rates, tier
ladders and dry-run quotes are untouched by it. The rate ships at **20% for every
hub** — genesis share class 0, which every collection the admin has not assigned
a class of its own resolves through — and is live from the first fill on a
freshly published `FeePolicy` rather than staged, since there is no earlier epoch
for a launch rate to be announced in. Every *later* change to it, including a
re-price of class 0 itself, takes effect no earlier than the **next epoch
boundary** and is visible on-chain beforehand through `operator_share_bps_at()`.

One consequence of a non-zero launch rate belongs here rather than in a release
note: the share is credited whether or not the collection has a beneficiary
registered yet, and `withdrawable_pool_fees()` subtracts `operator_owed` in full.
Until the admin registers an adapter type and hub owners register through it,
that 20% of multicoin revenue is neither claimable by an operator nor sweepable
by the treasury. It is encumbered, not lost — a later registration pays out the
whole accrued balance, and `claim_operator_share` aborts rather than banking it
for the treasury in the meantime. The share is credited the moment revenue is recognized, at
the rate live in that instant, so a rate change can only affect revenue that has
not happened yet — there is no deferred settlement whose timing anyone could
game, and `operator_owed()` carries no unsettled remainder beside it.

That exactness is about **timing, not amount**. Each recognition credits
`floor(recognized × bps / 10000)`, so the running figure sits at or below the
operator's exact share, by under one raw quote unit per recognition event. The
shortfall stays in the reserve as treasury revenue — it is never lost, and the
share is never paid out of fees that were not collected — but it is not
proportional: because the loss is bounded per *event* rather than per unit of
revenue, any single recognition smaller than `10000 / bps` raw units credits
zero. Low rates are the exposed case (at 1 bp, an event below 10000 raw units
credits nothing), and so is finely fragmented flow. The contracts sum before
flooring wherever a transaction recognizes more than once — per-account fill
proceeds, and the whole of a cancel batch — which is what keeps a market maker
pulling a book of quotes from being credited nothing at all. An operator
reconciling payouts should expect the floored figure, not `bps × revenue`.

Where the share is paid is configuration, not inference: `OperatorPayouts`, a
shared object published beside `FeePolicy`, holds an
explicit `collection_id -> address`, written and re-pointed only through a
witness minted by an admin-registered adapter package
([`triex_hub_operator_adapter`](packages/triex_hub_operator_adapter/)). On every
write the adapter checks that the `StorageUnit` presented is the one the
collection's warehouse `VaultConfig` was initialized for, and that the caller's
`OwnerCap<StorageUnit>` is the cap that storage unit records (`owner_cap_id`) —
not merely one authorized for it, since world lets an AdminACL sponsor mint
further caps. So the address is always one the storage unit's *current* owner
chose — themselves or anyone they name — not whichever sender happened to
deploy a pool first (pool creation itself writes nothing).
Registration is first-write-wins; after it, `update_operator_beneficiary_with_witness`
re-points the mapping. That rotation exists because a storage unit's `OwnerCap`
is transferable: a write-once mapping would keep paying the previous owner after
a sale, with the new owner unable to stop it. Re-pointing to the current address
is a no-op (nothing written, no event), so a hand-over PTB never fails on an
unchanged payee. Every write is on the event stream
— `OperatorBeneficiaryRegistered`, `OperatorBeneficiaryChanged` (with the previous
and new address) and `OperatorBeneficiaryDestroyed` from `fee_policy`, plus the
adapter's own `HubOperatorRegistered` / `HubOperatorChanged`, which add the
storage unit and the signer.

Until the admin pins an adapter type, no registration or rotation path exists
at all. `pin_operator_adapter` pins it for the life of the `OperatorPayouts`
object, and takes the adapter package's `UpgradeCap` to do so: the cap must
still point at the package version that defines the witness type (for
`HubAdapterWitness`, the adapter as first published), and the pin deletes it
(`sui::package::make_immutable`) in the same transaction. So a pinned adapter
can never be upgraded into one that mints its witness without the `OwnerCap`
check, a primitive or another publisher's public type can never be pinned, and
`pinned_operator_adapter()` always names immutable code anyone can audit. A
second pin aborts (`EAdapterPinned`), whatever its type;
`clear_operator_adapter` closes registration and rotation but never unpins, and
`set_operator_adapter` only re-opens the pinned type. So the cap cannot
authorize a witness of its own and register or rotate a mapping to itself.
Moving to a different adapter package takes a fresh publish of Triex. The admin
cap can only **destroy** a mapping (halting payouts, which stay encumbered
until the owner re-registers), never point it somewhere new.

Which adapter gets pinned is the admin's choice, and that remains trust in the
admin. The contracts make it reviewable rather than silent: multicoin pricing
cannot be set up until an adapter is pinned (`bootstrap_quote` and
`set_multicoin_default_class` abort with `ENoPinnedAdapter`), so the pin is
fixed and public before any multicoin pool exists and before any operator share
accrues. Two world-side parties sit in the same trust
set: an AdminACL sponsor can re-point any character's wallet
(`character::update_address`) and so act as any storage unit owner, and the
warehouse_receipts / world `UpgradeCap`s guard the `VaultConfig` and
`owner_cap_id` bindings the adapter relies on. Once world unanchors a storage
unit or deletes its cap, that collection's payout address is frozen at its last
value.

Accrued-but-unclaimed balance pays whoever is configured at claim time, not
whoever was configured when it accrued — a seller who wants the backlog claims
every pool before handing over the `OwnerCap`. The mapping does not follow the
cap: until the buyer rotates it, claims keep paying the seller's choice. A clean
hand-over is one PTB by the seller — borrow the cap, `update_operator` to the
buyer's address, `transfer_owner_cap_with_receipt`. A storage unit can carry
several warehouse collections; each is rotated separately.

Only warehouse_receipts collections can ever get a payout address, but pool
creation accepts any multicoin collection and the default class credits the
share regardless. On any other collection the share accrues to a payee who can
never exist: neither claimable nor sweepable. The admin stops further accrual
by assigning such collections a zero-rate class; what has accrued stays put. `claim_operator_share` is
permissionless, so either side can run it; the `operator_owed()` view and the
claim events are the record of it.

### What the AdminCap can NOT do

The cap's financial reach is limited to **fee revenue and fee rates** — subject
to the 20% cap and the one-epoch notice described above. It cannot:

- Move user funds held in any `TradingAccount` (deposit or withdraw them). It
  *can* freeze them: retiring every allowed version with `disable_version` stops
  every deposit, withdrawal and proof until a version is enabled again. See the
  version gate below.
- Take a hub operator's accrued share: `withdrawable_pool_fees()` subtracts
  `operator_owed` in full — a sweep pays the operator's share to the operator and
  can never reach it. (What the cap *does* keep is the sub-unit flooring
  remainder described above, which is revenue never credited to anyone else.)
- Redirect an operator share: `claim_operator_share` and `withdraw_pool_fees` pay only
  the address `OperatorPayouts` records — registered and rotated only through the pinned
  adapter's witness, destructible but never re-pointable by the cap — and never the caller
- Place or cancel orders on anyone's behalf
- Mint CRED, or burn CRED it doesn't own (see below)
- Change a live pool's tick size, lot size, or min size (that code is disabled).
  Coin pools do enforce a minimum order size, but it is *derived* — the
  fixed-point reciprocal of the order's own price, the smallest quantity that
  still settles for a non-zero quote — so it is a property of the arithmetic and
  not an operator-tunable parameter

The most systemic levers are the halt and the version gate.

**`fee_policy::halt_trading` is the kill switch.** One transaction, and from the
next one on every order placement, every swap and every permissionless pool
creation on every pool aborts, with no per-pool step, because every one of them
already reads the shared `FeePolicy`. A halt stops new activity and nothing
else: cancels, modifies (which can only reduce an order), settled-balance
withdrawals, expired-order cleanup and hub-operator claims stay open, as do
deposits to and withdrawals from a `TradingAccount`. A halt cannot trap anyone's
funds. `resume_trading` lifts it, and resting orders carry on where they were.

**`fee_policy::enable_version` / `disable_version` is the version gate, and
retiring the running version is the full freeze.** The registry and `FeePolicy`
hold the same set of allowed package versions, changed together by these two
calls. The copy on `FeePolicy` is read by every `TradingAccount` entry point and
by every order, swap and pool creation, so one transaction retires a version's
code from all of them at once: no account can be created, funded, drained or
traded from through it, no proof made, no cap minted, nothing new placed on any
pool, and no `FeePolicy` write made except `halt_trading`. Revoking a cap stays
open, so an owner can kill a leaked cap even during a freeze. What a retired
version keeps is each pool whose own cached set has not been refreshed since:
everything there that takes on no new exposure — cancels, modifications and
settled-balance withdrawals (given a proof from a version still allowed),
permissionless settlement, expired-order cleanup, turnover folding and the
admin fee sweep — until `update_pool_allowed_versions` runs for that pool after
the disable. That is one call per pool, which anyone can make and which keeps
working while the version is disabled. The gate itself cancels no order and
moves no funds: what it stops stays where it is.

Its intended use is the end of an upgrade: allow the new version, retire the
old one, which leaves the new one running, then refresh every pool once more so
the old version loses what it kept there. Any package that calls Triex keeps
calling the version it was published or upgraded against, so each has to be
upgraded to the new version before the old one is retired, or its users are
frozen with it — for good, if it can no longer be upgraded. The pinned hub
adapter is such a package by design, which is why `OperatorPayouts` stays
outside the gate: registration's off switch is `clear_operator_adapter`, which
acts on the object and so on every version at once. Any other immutable package
that owns accounts through `new_with_uid_owner_and_caps` is frozen for good once
its version is retired. Retiring the running version with no successor allowed stops every
account, so unlike the halt it traps funds for as long as it lasts.

Both are reversible: `resume_trading` and `enable_version` restore service, and
`disable_version` / `enable_version` (and `halt_trading`) bypass the version gate
themselves so the operator cannot lock itself out. Disabled version numbers are not recycled, so
an archived decoder can never resolve a retired version to a new meaning. Users
should weigh this when assessing operator trust.

---

## 2. `TreasuryCap<CRED>` — locked away, burn-only

Defined behavior in [`cred.move`](packages/token/sources/cred.move). The key design
decision: **the operator does not hold this cap — nobody does.**

At `init`, the module:

1. Creates the CRED currency (6 decimals) and **freezes the coin metadata**
   (name, symbol, icon can never change).
2. Mints the entire fixed supply — 10,000,000,000,000,000 base units
   (10 billion CRED) — to the publisher in a single mint.
3. Locks the `TreasuryCap<CRED>` inside a **shared** `ProtectedTreasury` object
   as a dynamic object field keyed by the module-private `TreasuryCapKey`.

Because the key type is private to the module, the cap can only ever be reached
through the module's own two public functions:

| Function | Who can call | Effect |
|---|---|---|
| `burn(&mut ProtectedTreasury, Coin<CRED>)` | **Anyone** (with CRED they own) | Permanently destroys the coins, reducing total supply. |
| `total_supply(&ProtectedTreasury)` | Anyone | Read-only supply query. |

There is **no public mint path** — `coin::mint` is called exactly once inside
the private `create_coin`. Consequences for the operator:

- The operator **cannot inflate CRED**, ever, even holding the AdminCap.
  CRED is a fixed-supply, deflationary (burn-only) token by construction.
- The operator's CRED position is whatever remains of the initial mint it
  received at publish time — an ordinary token holding, not a capability.
- `triex::pool::burn_cred` and `triex::multicoin_pool::burn_cred`
  (tagged `#feat:rebate`) route pool-held CRED into this burn function,
  wiring the exchange's rebate/burn mechanics to the treasury.

> ⚠️ One caveat: the immutability guarantee holds only as long as the `token`
> package is not upgraded to add a mint entry point. See `UpgradeCap` below.

---

## 3. TradingAccount delegation caps — user-level, not operator-level

Defined in [`trading_account.move`](packages/triex/sources/trading_account.move).
A `TradingAccount` is a shared object holding a user's balances across all
pools. Its **owner** can mint up to 1,000 delegation caps (combined) tied to
that specific account (each cap records its `trading_account_id`):

| Capability | Minted by | Grants the holder |
|---|---|---|
| `TradeCap` | `mint_trade_cap` | Generate a `TradeProof` (`generate_proof_as_trader`) to place/cancel orders and settle against the account's balances. Cannot deposit or withdraw. |
| `DepositCap` | `mint_deposit_cap` | `deposit_with_cap` / `deposit_multicoin_with_cap` — add funds to the account. Cannot withdraw or trade. |
| `WithdrawCap` | `mint_withdraw_cap` | `withdraw_with_cap` / `withdraw_multicoin_with_cap` — pull funds out of the account. Cannot trade. |

The owner can revoke any of the three at any time with `revoke_trade_cap`
(despite the name, it revokes all three kinds by removing the cap ID from the
account's allow-list — the revoked cap object becomes inert).

Minting and using these caps passes the version gate (section 1), like every
other account entry point that creates an account, moves funds or makes a
proof: each takes the shared `FeePolicy`. Revoking one does not, so an owner can
always kill a leaked cap.

**Operator relevance:** these caps give the *operator qua operator* no power.
The `TriexAdminCap` cannot mint, use, or revoke them. Trinary Exchange
would only hold one if a user explicitly minted and transferred it (e.g., a
custody or market-making arrangement), in which case the operator acts as that
user's delegate with exactly the granted scope — and the user can revoke it
unilaterally.

---

## 4. Implicit Sui platform capabilities

These are not defined in this repo but exist for every published Sui package,
and they bound every guarantee above:

- **`UpgradeCap`** — issued to the publisher for each of `token` and
  `triex`. Whoever holds it can upgrade the package (within Sui's
  compatibility rules, which allow *adding* new public functions). An upgrade
  to `token` could, in principle, add a function that borrows the locked
  `TreasuryCap` and mints — so the "no mint" guarantee is really "no mint
  unless the operator upgrades the token package." Operators wanting to make
  fixed supply trustless should burn the `token` package's `UpgradeCap` or
  transfer it to an immutable address. Similarly, the `triex`
  `UpgradeCap` plus the AdminCap's version gate is the intended path for
  protocol upgrades: bump `CURRENT_VERSION` and publish the new version →
  `fee_policy::enable_version` from it → `update_pool_allowed_versions` on each
  pool → upgrade every package that calls Triex to the new version →
  `fee_policy::disable_version` of the old one → `update_pool_allowed_versions`
  on each pool again.
- **CRED `CoinMetadata`** — already frozen at init; not upgradeable-around,
  since the object itself is immutable.

---

## Summary: the operator's actual power surface

With the `TriexAdminCap` (and its `UpgradeCap`s), Trinary Exchange can:

1. **Collect revenue** — sweep trading fees from every pool and redirect
   pool-creation fees.
2. **Set prices of participation** — taker, maker and cancel-retention rates
   per pricing class, as a flat pair or a turnover-tiered ladder, with at least
   one epoch boundary of notice; taker and maker rates up to a 20% cap, cancel
   retention up to 100%; and which quote currencies are allowed.
3. **Control the pool set** — create fee-free pools, unregister pools for
   redeployment.
4. **Gate protocol versions** — enable/disable package versions: the
   full-freeze lever (the halt is the pause that traps nothing). Retiring every
   allowed version freezes every `TradingAccount` as well, until one is enabled
   again.
5. **Upgrade the code** — subject to Sui upgrade rules; this is the root of
   trust everything else rests on.

It cannot custody or move user balances (though the version gate can freeze
them), interfere with user orders, delegate itself into a user's
TradingAccount, or mint CRED (absent a token package upgrade).
