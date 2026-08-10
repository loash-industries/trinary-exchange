# trinary-exchange

Sui Move smart contracts for **TriexBook** — a decentralized central limit order
book (CLOB) exchange built on [Sui](https://sui.io). This repository contains the
on-chain Move packages that power the exchange and its native fee/governance token.

## Packages

| Package | Path | Description |
| --- | --- | --- |
| `triexbook` | [`packages/triexbook/`](packages/triexbook/) | The core exchange: order book, matching engine, pools (Book / State / Vault), balance manager, multi-coin pool, and on-chain governance. |
| `token` | [`packages/token/`](packages/token/) | The `CRED` token (`cred.move`) used to pay trading fees, stake, and participate in pool governance. |

`triexbook` depends on `token` via a local path (`token = { local = "../token" }`),
so the two packages must remain siblings in this repo. It also pulls in the external
[`multicoin`](https://github.com/Algorithmic-Warfare/multicoin) package as a git
dependency.

## Architecture

A `Pool` is composed of three distinct parts that define the flow for every action:

1. **Book** — reads/writes the order book; fills and places orders.
2. **State** — maintains per-user data, volumes, historic volumes, and governance.
3. **Vault** — settles user funds after an action executes.

The `BalanceManager` is a shared object holding all balances for a single account.
It has one owner and up to 1000 traders, and is required as an input to (almost) all
interactions with the exchange. A single `BalanceManager` can be used across all pools.

See [`packages/triexbook/README.md`](packages/triexbook/README.md) for the full protocol
description, and [`CAPABILITIES.md`](CAPABILITIES.md) for the trust model and the full list
of admin capabilities.

## Prerequisites

- [Sui CLI](https://docs.sui.io/references/cli) (`sui move` — matching the toolchain
  in each package's `Move.lock`)
- A configured Sui client environment for the network you intend to build/deploy against

## Build & Test

Each package is a standard Sui Move package. From a package directory:

```bash
# Build
sui move build

# Run the Move unit tests (triexbook)
cd packages/triexbook
sui move test

# Format Move sources
sui move format
```

Helper shell scripts live in
[`packages/triexbook/build_scripts/`](packages/triexbook/build_scripts/) — e.g.
`verify-bytecode-meter.sh`, which checks the compiled modules against Sui's bytecode
metering limits.

## Environments

Published package addresses per environment are declared in each package's `Move.toml`
under `[environments]` (e.g. `testnet_utopia`, `testnet_stillness`, `testnet_wip`,
`localnet`) and recorded in the accompanying `Published.toml` files. All current
deployments are on Sui testnet.

## Repository layout

```
trinary-exchange/
├── CAPABILITIES.md       # Trust model & admin capability reference
└── packages/
    ├── token/            # CRED token package
    │   ├── Move.toml
    │   └── sources/cred.move
    └── triexbook/        # Core CLOB exchange package
        ├── Move.toml
        ├── sources/          # book, state, vault, pool, multicoin_pool, registry, ...
        ├── tests/            # Move unit + integration tests
        └── build_scripts/    # Bytecode-meter verification helper
```

> Note: `build/` output and `.env*` files are git-ignored and regenerated locally —
> see [`.gitignore`](.gitignore).

## Security

All deployments are on Sui **testnet** only and the code is **unaudited** — use at
your own risk. See [`CAPABILITIES.md`](CAPABILITIES.md) for the operator trust model.

## License

Apache-2.0 — see [LICENSE](LICENSE). The `triexbook` package is a modified
derivative of [DeepBook v3](https://github.com/MystenLabs/deepbookv3),
Copyright (c) Mysten Labs, Inc. (Apache-2.0); see the notice of changes in
[`packages/triexbook/README.md`](packages/triexbook/README.md#license).
