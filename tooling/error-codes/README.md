# Error codes

Maps Move abort codes to user-facing labels, and decodes the error string that
`sui_getTransactionBlock` returns.

## Why this exists

The `effects.status.error` field on a failed transaction is not structured data. It is
the `Display` impl of `ExecutionFailureStatus`, which for an abort renders as:

```
Move Runtime Abort. Location: 0xa9ec…309::multicoin_pool::create_multicoin_pool (function index 3) at offset 45, Abort Code: 1 in command 0
```

The raw `u64` and nothing else — no constant name, no message. Sui *can* resolve a
constant name, but only through `sui-package-resolver`'s `resolve_clever_error`, which
fetches the module's constant pool; `SuiClient` does not do it for you. So a client that
wants to show "Pool creation fee is incorrect" has to parse that string and look the
code up itself.

This package does both, and generates the lookup table from the Move sources so it
cannot drift out of sync with them.

## Usage

```bash
node generate.mjs                                   # regenerate the catalog
node generate.mjs --check                           # CI: fail if the catalog is stale
node --test decode.test.mjs                         # tests

node bin/decode-abort.mjs --digest <digest>         # decode a real failed transaction
node bin/decode-abort.mjs --error "<error string>"  # decode a string you already have
```

`--digest` reads `$SUI_RPC_URL`, defaulting to Sui testnet. Override with `--rpc <url>`.

From code:

```js
import { explainAbort, formatAbort } from '@triex/error-codes'
import catalog from '@triex/error-codes/catalog' with { type: 'json' }

const explained = explainAbort(effects.status.error, catalog.byModule)
// { resolution: 'resolved', module: 'multicoin_pool', constant: 'EInvalidFee',
//   label: 'Invalid fee', code: 1, declaredAt: 'packages/triex/sources/multicoin_pool.move:33', … }
formatAbort(explained) // "Invalid fee (multicoin_pool::create_multicoin_pool, EInvalidFee=1)"
```

`resolution` is one of `resolved`, `unknown-code` (our module, code not in the catalog —
regenerate) or `external-module` (the abort came from a dependency such as `sui::coin`).
Non-abort failures such as `InsufficientGas` come back as `kind: 'other'` with the
original string preserved.

Labels come from the `///` doc comment above a constant when there is one, and are
otherwise derived from the name (`EInvalidFee` → "Invalid fee"). Adding a doc comment to
a constant is the way to improve a label.

## Codes are keyed by module, not globally

An abort always carries its package and module, so `(module, code)` is unambiguous —
`EInvalidFee = 1` in `pool` and `EInvalidFee = 1` in `multicoin_pool` do not collide.
That is why the constants stay small and readable instead of carrying a package prefix
in their numeric value. The generator enforces uniqueness *within* a module and fails if
two constants share a code.

## Clever errors

`decode.mjs` also handles clever errors, so the catalog keeps working if the constants
move to `#[error(code = N)]`:

```move
#[error(code = 1)]
const EInvalidFee: vector<u8> = b"Pool creation fee is incorrect";
```

The compiler then packs `| 1-bit tag | 15-bit code | 16-bit source line | 16-bit
identifier index | 16-bit constant index |` into the abort code. `unpackAbortCode`
recovers `N` and the source line with pure arithmetic — no package fetch — and the
catalog lookup is unchanged, so migration is incremental: convert a module at a time and
regenerate.

Two caveats if you migrate:

- Use `#[error]` **with** an explicit `code = N`. Without one the code is derived from
  the source line and changes on any reformat, leaving nothing stable to key on. The
  generator fails on un-keyed clever errors.
- `code = 0` is indistinguishable from "no explicit code", so the generator rejects it.

## Numbering gaps

`generate.mjs` reports gaps in each module's numbering. They are harmless — the codes
only need to be unique — but they mark where constants were deleted, and several modules
have accumulated them (`multicoin_pool` is missing 2–7, 10, 12, 15–19). Worth closing if
the constants are ever renumbered; not worth a breaking change on its own.
