#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE_DIR="$PKG_DIR/build/triexbook/bytecode_modules"

MODULES=(
  account
  balances
  book
  constants
  ewma
  fee_policy
  fee_schedule
  fee_turnover
  fill
  history
  math
  multicoin_pool
  multicoin_vault
  order
  order_info
  order_query
  pool
  quote_fee
  registry
  state
  trading_account
  utils
  vault
)

if [[ ! -d "$MODULE_DIR" ]]; then
  echo "error: module directory not found: $MODULE_DIR" >&2
  echo "hint: run 'sui move build' from $PKG_DIR first" >&2
  exit 1
fi

args=()
for m in "${MODULES[@]}"; do
  f="$MODULE_DIR/$m.mv"
  if [[ ! -f "$f" ]]; then
    echo "error: missing module file: $f" >&2
    exit 1
  fi
  args+=(--module "$f")
done

# NOTE: this checks the *bytecode verifier's* metering limits — a publish-time
# safety check on module complexity. It does not measure the gas a function
# costs at runtime. For that, use ./gas-benchmark.sh.
#
# Known broken on sui 1.74.1: `sui move build` emits Move bytecode version 7
# with the Sui flavor (header magic `deadc0de`), and this CLI's meter cannot
# read it. `--module` reports BAD_MAGIC / "Binary header not allowed" and
# `--package` panics as unimplemented, both identically on modules no branch has
# touched — so it is a toolchain problem, not a package one. Rewriting the
# header to the plain Move magic only advances the failure to UNKNOWN_VERSION,
# so there is no sound workaround: metering doctored bytecode would say nothing
# about what actually publishes.
#
# The module list above is kept current so this works again on a CLI that can
# read v7. The command exits 0 even when it fails, so detection is by output.
out="$(sui client verify-bytecode-meter "${args[@]}" 2>&1 || true)"

# It also needs a reachable fullnode to fetch the protocol config, so a
# connection failure is a "could not run", not a pass.
if grep -qiE "tcp connect error|Connection refused|service is currently unavailable" <<<"$out"; then
  cat >&2 <<DIAG
error: bytecode metering could not run -- no reachable Sui node.

  active env: $(sui client active-env 2>/dev/null || echo unknown)

This command fetches the protocol config over RPC. Point the CLI at a reachable
network (\`sui client switch --env testnet\`) or start a local one, then retry.
DIAG
  exit 1
fi

if grep -qiE "Failed to deserialize|BAD_MAGIC|Binary header not allowed|UNKNOWN_VERSION|not yet implemented" <<<"$out"; then
  cat >&2 <<DIAG
error: bytecode metering could not run on this toolchain.

  sui version: $(sui --version 2>/dev/null || echo unknown)
  reported:    $(printf '%s' "$out" | grep -iE "BAD_MAGIC|Binary header|UNKNOWN_VERSION|not yet implemented|Failed to deserialize" | head -1 | sed 's/^[[:space:]]*//')

This is a CLI incompatibility with Move bytecode version 7, not a fault in the
package -- it reproduces on modules this repo has not changed. The package
builds and tests clean regardless. Bytecode metering stays unverified until the
CLI can read v7.
DIAG
  exit 1
fi

echo "$out"
echo "bytecode metering passed for ${#MODULES[@]} modules"
