# Capability Objects in Trinary Exchange

This document catalogs every capability ("cap") object across the two packages in
this repository — [`triexbook/`](packages/triexbook/) and [`token/`](packages/token/) — and spells
out what the operator (Trinary Exchange) can and cannot do with each one.

On Sui, a capability is an object whose *possession* is the authorization: any
function that takes `&SomeCap` as a parameter can only be called by whoever owns
that object. None of the caps below carry data used for auth — they are pure
proof-of-ownership tokens.

| Capability | Package / Module | Held by | Purpose |
|---|---|---|---|
| `TriexbookAdminCap` | `triexbook::registry` | Operator (package publisher) | Protocol administration |
| `TreasuryCap<CRED>` | `token::cred` (wrapped in `ProtectedTreasury`) | Nobody — locked in a shared object | CRED supply control (burn-only) |
| `TradeCap` | `triexbook::balance_manager` | Whoever a BalanceManager owner delegates to | Trade on behalf of a BalanceManager |
| `DepositCap` | `triexbook::balance_manager` | Whoever a BalanceManager owner delegates to | Deposit into a BalanceManager |
| `WithdrawCap` | `triexbook::balance_manager` | Whoever a BalanceManager owner delegates to | Withdraw from a BalanceManager |
| `UpgradeCap` (implicit) | Sui framework | Operator (package publisher) | Upgrade the published packages |

---

## 1. `TriexbookAdminCap` — the operator's protocol cap

Defined in [`registry.move`](packages/triexbook/sources/registry.move). Minted exactly
once in the package `init` and transferred to the publisher (the operator). It
has `key, store`, so it can be transferred, moved to a multisig, or locked in a
timelock/governance wrapper later.

Every admin entry point takes it as a read-only reference (`_cap:
&TriexbookAdminCap`). The operator's powers fall into three modules:

### Registry administration (`triexbook::registry`)

| Function | What the operator can do |
|---|---|
| `set_treasury_address` | Redirect where pool-creation fees are sent. Defaults to the publisher. |
| `enable_version` / `disable_version` | Control which package versions may interact with the protocol. The current version cannot be disabled. These two functions are themselves exempt from version checks, so an admin can always recover from a bad version state. |
| `add_stablecoin` / `remove_stablecoin` | Manage the stablecoin whitelist, which determines which pools qualify as "stable pools". |
| `add_approved_quote` / `remove_approved_quote` | Manage the approved quote-currency list. Adding enforces a minimum-decimals check on the coin metadata so fee precision stays meaningful (an unchecked variant exists but is `#[test_only]`). |
| `init_balance_manager_map` | One-time creation of the owner → balance-manager-IDs table on the registry. Idempotent. |

### Pool administration (`triexbook::pool` — the pair-based order book)

| Function | What the operator can do |
|---|---|
| `create_pool_admin` | Create a pool with **zero creation fee**, bypassing the fee charged on the permissionless `create_pool` path. |
| `set_next_epoch_fee` | Directly set the trading fee for the next epoch. Per the in-code comment, this deliberately **replaces the CRED-governance proposal/voting system** with direct admin control. |
| `unregister_pool_admin` | Unregister a pool from the registry so the trading pair can be redeployed. The pool object itself keeps operating for existing state, but is marked unregistered. |
| `update_allowed_versions` | Sync a pool's allowed-versions set from the registry. Note: a permissionless equivalent, `update_pool_allowed_versions`, exists, so this is not an exclusive power. |
| `withdraw_pool_fees` | **Withdraw accumulated quote-denominated trading fees** from the pool vault into a `Coin<QuoteAsset>` for treasury custody. This is the operator's revenue-collection path. Emits a `PoolFeesWithdrawn` event. |

Disabled (commented-out) admin features that may return in future versions:
EWMA volatility controls (`enable_ewma_state`, `set_ewma_params`) and
tick/min-size adjustment.

### MultiCoinPool administration (`triexbook::multicoin_pool`)

Mirrors the pool module, per collection asset:

- `create_pool_admin` — fee-free pool creation for a `(Collection, asset_id)` pair
- `set_next_epoch_fee`
- `unregister_pool_admin`
- `update_allowed_versions` (permissionless equivalent also exists)
- `withdraw_pool_fees` — sweep accrued quote fees to treasury

### What the AdminCap can NOT do

The cap's financial reach is limited to **fee revenue and fee rates**. It cannot:

- Touch user funds held in any `BalanceManager` (deposit, withdraw, or freeze them)
- Place or cancel orders on anyone's behalf
- Mint CRED, or burn CRED it doesn't own (see below)
- Change a live pool's tick size, lot size, or min size (that code is disabled)

The most systemic lever is `enable_version` / `disable_version`: disabling a
version effectively freezes all protocol interaction through that package
version, which functions as an emergency stop for old code but also as a
soft kill switch. Users should weigh this when assessing operator trust.

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
- `triexbook::pool::burn_cred` and `triexbook::multicoin_pool::burn_cred`
  (tagged `#feat:rebate`) route pool-held CRED into this burn function,
  wiring the exchange's rebate/burn mechanics to the treasury.

> ⚠️ One caveat: the immutability guarantee holds only as long as the `token`
> package is not upgraded to add a mint entry point. See `UpgradeCap` below.

---

## 3. BalanceManager delegation caps — user-level, not operator-level

Defined in [`balance_manager.move`](packages/triexbook/sources/balance_manager.move).
A `BalanceManager` is a shared object holding a user's balances across all
pools. Its **owner** can mint up to 1,000 delegation caps (combined) tied to
that specific manager (each cap records its `balance_manager_id`):

| Capability | Minted by | Grants the holder |
|---|---|---|
| `TradeCap` | `mint_trade_cap` | Generate a `TradeProof` (`generate_proof_as_trader`) to place/cancel orders and settle against the manager's balances. Cannot deposit or withdraw. |
| `DepositCap` | `mint_deposit_cap` | `deposit_with_cap` / `deposit_multicoin_with_cap` — add funds to the manager. Cannot withdraw or trade. |
| `WithdrawCap` | `mint_withdraw_cap` | `withdraw_with_cap` / `withdraw_multicoin_with_cap` — pull funds out of the manager. Cannot trade. |

The owner can revoke any of the three at any time with `revoke_trade_cap`
(despite the name, it revokes all three kinds by removing the cap ID from the
manager's allow-list — the revoked cap object becomes inert).

**Operator relevance:** these caps give the *operator qua operator* no power.
The `TriexbookAdminCap` cannot mint, use, or revoke them. Trinary Exchange
would only hold one if a user explicitly minted and transferred it (e.g., a
custody or market-making arrangement), in which case the operator acts as that
user's delegate with exactly the granted scope — and the user can revoke it
unilaterally.

---

## 4. Implicit Sui platform capabilities

These are not defined in this repo but exist for every published Sui package,
and they bound every guarantee above:

- **`UpgradeCap`** — issued to the publisher for each of `token` and
  `triexbook`. Whoever holds it can upgrade the package (within Sui's
  compatibility rules, which allow *adding* new public functions). An upgrade
  to `token` could, in principle, add a function that borrows the locked
  `TreasuryCap` and mints — so the "no mint" guarantee is really "no mint
  unless the operator upgrades the token package." Operators wanting to make
  fixed supply trustless should burn the `token` package's `UpgradeCap` or
  transfer it to an immutable/governance address. Similarly, the `triexbook`
  `UpgradeCap` plus the AdminCap's `enable_version` is the intended path for
  protocol upgrades (new version published → `enable_version` →
  `update_pool_allowed_versions` on each pool).
- **CRED `CoinMetadata`** — already frozen at init; not upgradeable-around,
  since the object itself is immutable.

---

## Summary: the operator's actual power surface

With the `TriexbookAdminCap` (and its `UpgradeCap`s), Trinary Exchange can:

1. **Collect revenue** — sweep trading fees from every pool and redirect
   pool-creation fees.
2. **Set prices of participation** — trading fee per epoch per pool, which
   coins count as stablecoins, which quote currencies are allowed.
3. **Control the pool set** — create fee-free pools, unregister pools for
   redeployment.
4. **Gate protocol versions** — enable/disable package versions, the de facto
   pause mechanism.
5. **Upgrade the code** — subject to Sui upgrade rules; this is the root of
   trust everything else rests on.

It cannot custody or move user balances, interfere with user orders, delegate
itself into a user's BalanceManager, or mint CRED (absent a token package
upgrade).
