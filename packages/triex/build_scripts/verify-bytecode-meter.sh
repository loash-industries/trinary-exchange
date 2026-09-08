#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODULE_DIR="$PKG_DIR/build/triexbook/bytecode_modules"

MODULES=(
  account
  balance_manager
  balances
  book
  constants
  ewma
  fill
  governance
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
  trade_params
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

RUST_BACKTRACE=1 sui client verify-bytecode-meter "${args[@]}"
