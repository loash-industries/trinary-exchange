#!/usr/bin/env bash
#
# Measure the Move VM gas each benchmark in `tests/gas_benchmarks.move` costs.
#
# `sui move test --gas-limit N` aborts a test that spends more than N, so the
# smallest N a benchmark survives is exactly the gas it needs. This binary
# searches that threshold for each benchmark and prints a table, plus the
# differentials that are the point of the exercise.
#
# What the numbers are: Move VM abstract gas — instruction and memory cost.
# What they are not: Sui computation + storage fees. Use them to compare
# operations against each other and to watch how cost grows with book depth.
# For fee prediction you need a real network; see README notes.
#
# Usage:
#   ./build_scripts/gas-benchmark.sh              # all benchmarks
#   ./build_scripts/gas-benchmark.sh bench_depth  # only matching ones
#   PRECISION=20 ./build_scripts/gas-benchmark.sh # coarser (5%), faster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PKG_DIR"

# Stop when the bracket is within 1/PRECISION of the answer.
PRECISION="${PRECISION:-100}"
# Where the exponential bracket starts, and the ceiling that means "no answer".
START="${START:-100000}"
CEILING="${CEILING:-100000000000}"

FILTER="${1:-}"

BENCHES=(
  bench_baseline
  bench_depth_10
  bench_depth_40
  bench_depth_80
  bench_cancel_at_depth_80
  bench_taker_sweeps_01
  bench_taker_sweeps_10
  bench_ladder_1_tier
  bench_ladder_8_tiers
)

if ! command -v sui >/dev/null 2>&1; then
  echo "error: sui not found on PATH" >&2
  exit 1
fi

# Exit status of one benchmark at a given gas limit. Also guards against a
# filter that matches more than one test, which would silently measure the max
# of several benchmarks instead of the one asked for.
passes() {
  local limit="$1" name="$2" out
  out="$(sui move test --gas-limit "$limit" "$name" 2>/dev/null || true)"
  local total
  total="$(printf '%s' "$out" | sed -n 's/.*Total tests: \([0-9]*\).*/\1/p' | tail -1)"
  if [[ "$total" != "1" ]]; then
    echo "error: filter '$name' matched ${total:-0} tests, expected 1" >&2
    exit 1
  fi
  printf '%s' "$out" | grep -q "Test result: OK"
}

declare -a NAMES=() RESULTS=()

for bench in "${BENCHES[@]}"; do
  if [[ -n "$FILTER" && "$bench" != *"$FILTER"* ]]; then
    continue
  fi

  printf '%-28s ' "$bench" >&2

  # Bracket from below by doubling until it passes.
  hi="$START"
  lo=0
  while ! passes "$hi" "$bench"; do
    lo="$hi"
    hi=$(( hi * 2 ))
    printf '.' >&2
    if (( hi > CEILING )); then
      echo " exceeds ceiling ($CEILING)" >&2
      lo=-1
      break
    fi
  done

  if (( lo == -1 )); then
    NAMES+=("$bench"); RESULTS+=(-1)
    continue
  fi

  # Narrow: lo always fails, hi always passes.
  while (( (hi - lo) * PRECISION > hi )); do
    mid=$(( (lo + hi) / 2 ))
    if passes "$mid" "$bench"; then hi="$mid"; else lo="$mid"; fi
    printf '.' >&2
  done

  printf ' %s\n' "$hi" >&2
  NAMES+=("$bench"); RESULTS+=("$hi")
done

get() {
  local want="$1" i
  for i in "${!NAMES[@]}"; do
    if [[ "${NAMES[$i]}" == "$want" ]]; then printf '%s' "${RESULTS[$i]}"; return; fi
  done
  printf ''
}

echo
printf '%-28s %14s\n' "benchmark" "move vm gas"
printf '%-28s %14s\n' "----------------------------" "--------------"
for i in "${!NAMES[@]}"; do
  printf '%-28s %14s\n' "${NAMES[$i]}" "${RESULTS[$i]}"
done

# Differentials. Each is only printed when both of its inputs were measured, so
# a filtered run degrades to just the table rather than printing nonsense.
base="$(get bench_baseline)"
d10="$(get bench_depth_10)"; d40="$(get bench_depth_40)"; d80="$(get bench_depth_80)"
cancel80="$(get bench_cancel_at_depth_80)"
s1="$(get bench_taker_sweeps_01)"; s10="$(get bench_taker_sweeps_10)"
l1="$(get bench_ladder_1_tier)"; l8="$(get bench_ladder_8_tiers)"

echo
echo "derived"
echo "-------"

if [[ -n "$base" && -n "$d10" && -n "$d40" && -n "$d80" ]]; then
  echo "cost per resting order, by where it lands in the book:"
  printf '  orders  1-10   %10d each\n' $(( (d10 - base) / 10 ))
  printf '  orders 11-40   %10d each\n' $(( (d40 - d10) / 30 ))
  printf '  orders 41-80   %10d each\n' $(( (d80 - d40) / 40 ))
  echo "  (rising with depth means order placement is O(book depth))"
fi

if [[ -n "$d80" && -n "$cancel80" ]]; then
  printf '\ncancel of the worst-priced order at depth 80: %d\n' $(( cancel80 - d80 ))
fi

if [[ -n "$s1" && -n "$s10" ]]; then
  printf '\nmarginal cost per additional fill in one order: %d\n' $(( (s10 - s1) / 9 ))
fi

if [[ -n "$l1" && -n "$l8" ]]; then
  printf '\nTRIEX-137 tier resolution, 8-rung ladder vs 1-rung, over 10 orders:\n'
  printf '  total %d, per order %d\n' $(( l8 - l1 )) $(( (l8 - l1) / 10 ))
fi
