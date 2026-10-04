#!/usr/bin/env bash
#
# Measure the Move VM gas each benchmark in `benchmarks/gas_benchmarks.move` costs.
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
PACKAGES_DIR="$(cd "$PKG_DIR/.." && pwd)"

# The benchmarks live outside `tests/` to keep them out of the default test
# build, which is close to the Move VM's per-package arena limit. Measure in a
# scratch copy of `packages/` (so the local `token` dependency still resolves)
# with the benchmarks dropped into its `tests/`.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
tar -C "$PACKAGES_DIR" --exclude build -cf - . | tar -C "$SCRATCH" -xf -
BENCH_PKG="$SCRATCH/$(basename "$PKG_DIR")"
cp "$PKG_DIR"/benchmarks/*.move "$BENCH_PKG/tests/"
cd "$BENCH_PKG"

# The full suite plus the benchmarks is over that limit too, so drop every test
# module the benchmarks don't reach. Starting from the benchmark files, keep any
# test module a kept file names, until nothing new turns up.
module_of() { sed -n 's/^module triex::\([A-Za-z0-9_]*\).*/\1/p' "$1" | head -1; }
KEEP="$(cd tests && for f in "$PKG_DIR"/benchmarks/*.move; do basename "$f"; done)"
while :; do
  added=0
  while IFS= read -r f; do
    grep -qxF "$f" <<<"$KEEP" && continue
    name="$(module_of "tests/$f")"
    [[ -z "$name" ]] && continue
    if (cd tests && grep -qw "$name" $KEEP); then
      KEEP="$KEEP"$'\n'"$f"
      added=1
    fi
  done < <(cd tests && find . -name '*.move' | sed 's|^\./||')
  (( added )) || break
done
while IFS= read -r f; do
  grep -qxF "$f" <<<"$KEEP" || rm "tests/$f"
done < <(cd tests && find . -name '*.move' | sed 's|^\./||')

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
  bench_cancel_all_at_depth_80
  bench_modify_at_depth_80
  bench_makers_10
  bench_taker_sweeps_01
  bench_taker_sweeps_10
  bench_market_sweeps_10
  bench_swap_base_for_quote_10
  bench_ladder_1_tier
  bench_ladder_8_tiers
  bench_behind_best_one
  bench_behind_best_two
  bench_behind_best_ten
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

# A result of -1 means the bench exceeded CEILING. It reads back as unmeasured, so
# the differentials below skip it instead of subtracting a sentinel.
get() {
  local want="$1" i
  for i in "${!NAMES[@]}"; do
    if [[ "${NAMES[$i]}" == "$want" ]]; then
      if (( RESULTS[i] >= 0 )); then printf '%s' "${RESULTS[$i]}"; fi
      return 0
    fi
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
cancelall80="$(get bench_cancel_all_at_depth_80)"
modify80="$(get bench_modify_at_depth_80)"
m10="$(get bench_makers_10)"
mkt10="$(get bench_market_sweeps_10)"
swap10="$(get bench_swap_base_for_quote_10)"
s1="$(get bench_taker_sweeps_01)"; s10="$(get bench_taker_sweeps_10)"
l1="$(get bench_ladder_1_tier)"; l8="$(get bench_ladder_8_tiers)"
bb1="$(get bench_behind_best_one)"; bb2="$(get bench_behind_best_two)"
bb10="$(get bench_behind_best_ten)"

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

echo
echo "order lifecycle at book depth 80 (each minus the 80-order baseline):"
if [[ -n "$d80" && -n "$cancel80" ]]; then
  printf '  cancel one (worst-priced)   %10d\n' $(( cancel80 - d80 ))
fi
if [[ -n "$d80" && -n "$modify80" ]]; then
  printf '  modify one down             %10d\n' $(( modify80 - d80 ))
fi
if [[ -n "$d80" && -n "$cancelall80" ]]; then
  printf '  cancel all 80              %10d  (%d each)\n' \
    $(( cancelall80 - d80 )) $(( (cancelall80 - d80) / 80 ))
fi

if [[ -n "$s1" && -n "$s10" ]]; then
  printf '\nmarginal cost per additional fill in one order: %d\n' $(( (s10 - s1) / 9 ))
fi

if [[ -n "$m10" ]]; then
  echo
  echo "consuming a 10-order book, by entry point (each minus that book):"
  [[ -n "$s10"   ]] && printf '  crossing limit order       %10d\n' $(( s10 - m10 ))
  [[ -n "$mkt10" ]] && printf '  market order               %10d\n' $(( mkt10 - m10 ))
  [[ -n "$swap10" ]] && printf '  manager-less swap          %10d\n' $(( swap10 - m10 ))
fi

if [[ -n "$bb1" && -n "$bb2" ]]; then
  echo
  echo "resting behind the best bid on a thin book:"
  printf '  first order behind a 1-order book  %10d\n' $(( bb2 - bb1 ))
  if [[ -n "$bb10" ]]; then
    printf '  each of the next 8                 %10d\n' $(( (bb10 - bb2) / 8 ))
  fi
fi

if [[ -n "$l1" && -n "$l8" ]]; then
  printf '\nTRIEX-137 tier resolution, 8-rung ladder vs 1-rung, over 10 orders:\n'
  printf '  total %d, per order %d\n' $(( l8 - l1 )) $(( (l8 - l1) / 10 ))
fi
