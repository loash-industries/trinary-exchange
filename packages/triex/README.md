# triex

Sui Move package implementing [**Trinary Exchange**](../../README.md):
a decentralized central limit order book
(CLOB) derived from Mysten Labs' DeepBook (Apache-2.0). It provides
permissionless trading pools, an order matching engine, per-account balance
management, fee collection, admin controls, and a gas-price volatility
tracker.

The package ships two parallel pool implementations:

| | Standard pool | MultiCoin pool |
| --- | --- | --- |
| Module | `triexbook::pool` | `triexbook::multicoin_pool` |
| Pool type | `Pool<BaseAsset, QuoteAsset>` | `MultiCoinPool<QuoteAsset>` |
| Base asset | A Sui `Coin<BaseAsset>` type | A [multicoin](https://github.com/Algorithmic-Warfare/multicoin) balance identified at runtime by `(collection_id, asset_id)` |
| Vault storage | `Balance<BaseAsset>` + `Balance<QuoteAsset>` | Dual storage: quote/CRED in Sui `Balance`s, base in a dynamic object field keyed by `(collection_id, asset_id)` |
| Price scaling | `FLOAT_SCALING` (1e9) | `1` (prices encoded directly in quote units) |
| Registry key | `(base_type, quote_type)` | `(collection_id, asset_id, quote_type)` |

MultiCoin pools additionally require their quote currency to be on the
registry's approved-quote list.

## Architecture

Every pool is composed of three parts, and every action flows through them in
order:

1. **Book** (`sources/book/`) — the order book itself. Places, matches,
   modifies, and cancels orders; produces `Fill`s.
2. **State** (`sources/state/`) — per-account data, epoch volume history,
   trade parameters, and fee accounting. Processes each action's
   results and computes settlement amounts.
3. **Vault** (`sources/vault/`) — holds the pool's assets and settles the
   computed balances against the user's `BalanceManager` at the end of the
   action.

Two shared objects sit alongside the pools:

- **`Registry`** (`sources/registry.move`) — singleton created at publish
  time. Tracks all pools (preventing duplicates per asset pair), the treasury
  address, allowed package versions, approved quote/stable coins, and the
  `TriexbookAdminCap` capability that gates all admin functions.
- **`BalanceManager`** (`sources/balance_manager.move`) — holds all of one
  account's balances (both regular coins and multicoin assets) and is passed
  into nearly every exchange interaction; one manager works across all pools.
  The owner authorizes each action with a `TradeProof`, generated either
  directly (`generate_proof_as_owner`) or by a delegated trader holding a
  `TradeCap` (`generate_proof_as_trader`). Scoped `DepositCap` /
  `WithdrawCap` capabilities allow delegated deposits/withdrawals.

## Trading interface

The public entry points live in `triexbook::pool` and
`triexbook::multicoin_pool` (mirrored signatures):

- **Pool creation** — `create_permissionless_pool` (burns a CRED creation
  fee), plus admin-gated `create_pool_admin` / `unregister_pool_admin`.
- **Orders** — `place_limit_order`, `place_market_order`, `modify_order`,
  `cancel_order`, `cancel_orders`, `cancel_all_orders`. Limit orders support
  the restrictions `NO_RESTRICTION`, `IMMEDIATE_OR_CANCEL`, `FILL_OR_KILL`,
  and `POST_ONLY`, plus self-matching options (allow, cancel-taker,
  cancel-maker) and expiry timestamps.
- **Swaps** — `swap_exact_base_for_quote`, `swap_exact_quote_for_base`, and
  `..._with_manager` variants for one-shot taker trades without maintaining
  resting orders.
- **Settlement** — `withdraw_settled_amounts` (and a
  `withdraw_settled_amounts_permissionless` variant) to move settled funds
  from the pool back to a `BalanceManager`.
- **Queries** — `mid_price`, `get_quantity_out`, `get_level2_range`,
  `get_level2_ticks_from_mid`, `account_open_orders`, `locked_balance`,
  `vault_balances`, and paginated order iteration via
  `triexbook::order_query` (`OrderPage`).

### Fees

Pools support two fee modes:

- **CRED fees** — fees denominated in `CRED` (from the sibling
  [`token`](../token/) package), the protocol's neutral trading currency;
  `burn_cred` burns collected CRED. CRED is not a governance token — it is
  used only to pay fees and confers no voting or staking rights.
- **Quote fees** — the `..._with_quote_fees` order variants accrue fees in
  the pool's quote currency into a `quote_fee_reserve`
  (`triexbook::quote_fee`), which the admin sweeps with
  `withdraw_pool_fees`.

Trade parameters are admin-set per epoch (`set_next_epoch_fee`); the original
DeepBook stake/proposal/vote system, flash loans, and referral system are
present in the source but disabled (commented out) — none of them are part of
this protocol. An optional
EWMA state (`triexbook::ewma`) tracks smoothed reference gas price mean and
variance and can add a taker-fee penalty when the current gas price's z-score
signals congestion.

### Versioning

The package uses a versioned inner-object pattern: the registry keeps a set of
allowed package versions (`enable_version` / `disable_version`,
`update_pool_allowed_versions`), letting old package versions be disabled
after upgrades.

## Source layout

```
sources/
├── pool.move             # Public trading interface (standard pools)
├── multicoin_pool.move   # Public trading interface (multicoin pools)
├── balance_manager.move  # BalanceManager + TradeCap/DepositCap/WithdrawCap
├── registry.move         # Pool registry, TriexbookAdminCap, versioning
├── order_query.move      # Paginated order iteration (OrderPage)
├── book/                 # Order book: book, order, order_info, fill
├── state/                # state, account, history, governance, trade_params,
│                         # balances, quote_fee, ewma
├── vault/                # vault (standard), multicoin_vault (dual storage)
└── helper/               # constants, fixed-point math, utils
```

## Dependencies

Declared in [`Move.toml`](Move.toml):

- `token` — local sibling package (`../token`) providing the `CRED` coin and
  its protected treasury.
- `multicoin` — git dependency on
  [Algorithmic-Warfare/multicoin](https://github.com/Algorithmic-Warfare/multicoin),
  the multi-asset balance standard used for multicoin pool base assets.

## Build & test

```bash
# From this directory
sui move build

# Run the full Move test suite
sui move test
```

Tests live under `tests/`, organized to mirror the sources: `pool/`,
`multicoin_pool/`, `book/`, `state/`, `vault/`, plus `integration/`
(end-to-end master flows, level-2 queries, trader permissions).

### Scripts

- [`build_scripts/verify-bytecode-meter.sh`](build_scripts/verify-bytecode-meter.sh)
  — runs `sui client verify-bytecode-meter` over every compiled module to
  confirm the package stays within Sui's bytecode metering limits.

## Deployments

Environments are declared in `Move.toml` under `[environments]`; published
addresses are recorded in [`Published.toml`](Published.toml). All current
deployments are on Sui testnet (chain id `4c78adac`):

| Environment | Package ID |
| --- | --- |
| `testnet_stillness` | `0x291b9da738dffedd18d7c5049e5e6792270202e03f3c9d9db4c7097670bf6eb2` |
| `testnet_utopia` | `0xc0e6294ba180e4998eab5d36aa72584d78f9c780706c6ff8a456c06ca6e4a2dd` |
| `testnet_wip` | `0xa9ec4afe4757ad2b90102e02b133fcd0cb7cc526722524ce20fcdf53be4ec309` |

## License

Apache-2.0 — see [LICENSE](../../LICENSE).

This package is a modified derivative of
[DeepBook v3](https://github.com/MystenLabs/deepbookv3),
Copyright (c) Mysten Labs, Inc., licensed under Apache-2.0. Original copyright
and license headers are retained in the source files.

**Notice of changes** (per Apache-2.0 §4(b)): the Move sources in this package
have been modified from the original DeepBook v3 code. Notable changes include
renaming the package and modules to `triexbook`, replacing the DEEP token with
the `CRED` token, adding the MultiCoin pool/vault variants
(`multicoin_pool`, `multicoin_vault`) with runtime-identified base assets and
adjusted price scaling, adding quote-denominated fee collection
(`quote_fee`), adding the EWMA gas-price fee penalty (`ewma`), and disabling
the upstream staking/voting, flash loan, and referral features.
