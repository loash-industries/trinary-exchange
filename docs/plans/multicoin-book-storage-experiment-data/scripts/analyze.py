#!/usr/bin/env python3
"""Analysis for the multicoin book storage experiment.

Reads results/<variant>.jsonl, produces:
  - per-op, per-depth burned-fee and computation tables (steady state)
  - construction curves (cumulative + marginal burned fee)
  - migration cliff detection for C/D variants
  - transaction-weighted and revenue-weighted composites (two denominators)
  - volume-weighted average trade cost (VWATC) under present-day and
    future-shifted market distributions
"""
import json, os, sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "results")

VARIANTS = ["A", "B", "C16", "C16u", "D32", "D64", "D64u"]
DEPTHS = [0, 5, 10, 15, 20, 30, 45, 60, 100, 150, 300]

# --- depth-class model (documented assumptions, from the experiment brief) ---
# transaction share: deep books are ~1% or less of transactions; the tail and
# typical (<20) markets carry nearly all of them.
TX_W = {5: 0.50, 10: 0.20, 15: 0.10, 20: 0.08, 30: 0.05, 45: 0.03,
        60: 0.02, 100: 0.01, 150: 0.007, 300: 0.003}
# revenue share: ~50% of revenue on books 150+; mid band also substantial.
REV_W = {5: 0.05, 10: 0.05, 15: 0.05, 20: 0.05, 30: 0.10, 45: 0.10,
         60: 0.10, 100: 0.10, 150: 0.25, 300: 0.25}
# future-shifted: high-volume (deep) markets grow to dominate volume.
FUT_W = {5: 0.02, 10: 0.02, 15: 0.03, 20: 0.03, 30: 0.05, 45: 0.05,
         60: 0.10, 100: 0.15, 150: 0.25, 300: 0.30}

# per-executed-trade operation mix: one taker fill plus maker churn around it.
# CHURN = maker place+cancel cycles per executed trade.
CHURN = 5


def load(variant):
    rows = []
    p = os.path.join(RESULTS, f"{variant}.jsonl")
    if not os.path.exists(p):
        return rows
    for line in open(p):
        rows.append(json.loads(line))
    return rows


def steady_table(rows):
    """{depth: {op: (mean_burn, mean_comp, mean_storage, n)}}"""
    acc = defaultdict(lambda: defaultdict(list))
    for r in rows:
        if r.get("phase") != "steady" or "nonRefundableStorageFee" not in r:
            continue
        acc[r["depth"]][r["op"]].append(r)
    out = {}
    for d, ops in acc.items():
        out[d] = {}
        for op, rs in ops.items():
            out[d][op] = (
                sum(x["nonRefundableStorageFee"] for x in rs) / len(rs),
                sum(x["computationCost"] for x in rs) / len(rs),
                sum(x["storageCost"] for x in rs) / len(rs),
                len(rs),
            )
    return out


def construction_curve(rows):
    return sorted(
        [r for r in rows if r.get("phase") == "construction" and "nonRefundableStorageFee" in r],
        key=lambda r: r["i"])


def op_cost(tab, depth, op, field=0, fallback=None):
    if depth in tab and op in tab[depth]:
        return tab[depth][op][field]
    return fallback


def trade_cost(tab, depth):
    """Volume-weighted average cost per executed trade at a depth:
    one 1-order taker fill + CHURN maker place/cancel cycles, burned fee."""
    t = op_cost(tab, depth, "taker_1")
    p = op_cost(tab, depth, "place_top")
    c = op_cost(tab, depth, "cancel_top")
    if t is None or p is None or c is None:
        return None
    return t + CHURN * (p + c)


def weighted(tab, weights, fn):
    tot, wsum = 0.0, 0.0
    for d, w in weights.items():
        v = fn(tab, d)
        if v is None:
            continue
        tot += w * v
        wsum += w
    return tot / wsum if wsum else None


def fmt(x, w=12):
    if x is None:
        return " " * (w - 3) + "  -"
    return f"{x:{w},.0f}"


def main():
    tabs, cons = {}, {}
    for v in VARIANTS:
        rows = load(v)
        tabs[v] = steady_table(rows)
        cons[v] = construction_curve(rows)

    print("=" * 100)
    print("STEADY STATE: mean nonRefundableStorageFee (MIST burned) per op")
    ops = ["place_top", "cancel_top", "place_28", "cancel_28", "modify_down",
           "cancel_resting", "taker_1", "taker_10", "taker_30"]
    for op in ops:
        print(f"\n--- {op} ---")
        print("depth " + "".join(f"{v:>12}" for v in VARIANTS))
        for d in DEPTHS:
            row = f"{d:5} "
            for v in VARIANTS:
                row += fmt(op_cost(tabs[v], d, op))
            print(row)

    print("\n" + "=" * 100)
    print("STEADY STATE: mean computationCost per op (buckets of ~3%)")
    for op in ["place_top", "taker_1", "taker_30"]:
        print(f"\n--- {op} ---")
        print("depth " + "".join(f"{v:>12}" for v in VARIANTS))
        for d in DEPTHS:
            row = f"{d:5} "
            for v in VARIANTS:
                row += fmt(op_cost(tabs[v], d, op, field=1))
            print(row)

    print("\n" + "=" * 100)
    print("CONSTRUCTION: marginal burned fee at selected depths (per placement)")
    marks = [5, 10, 15, 20, 30, 45, 60, 100, 150, 200, 250, 299]
    print("depth " + "".join(f"{v:>12}" for v in VARIANTS))
    for m in marks:
        row = f"{m:5} "
        for v in VARIANTS:
            c = cons[v]
            r = next((x for x in c if x["i"] == m), None)
            row += fmt(r["nonRefundableStorageFee"] if r else None)
        print(row)

    print("\nCONSTRUCTION: cumulative burned fee to depth 300")
    for v in VARIANTS:
        c = cons[v]
        if c:
            print(f"  {v:5} {sum(r['nonRefundableStorageFee'] for r in c):>14,.0f} "
                  f"({len(c)} placements)")

    # migration cliff: max marginal construction fee and where
    print("\nMIGRATION CLIFF (construction max marginal burn)")
    for v in VARIANTS:
        c = cons[v]
        if not c:
            continue
        mx = max(c, key=lambda r: r["nonRefundableStorageFee"])
        print(f"  {v:5} max {mx['nonRefundableStorageFee']:>10,} at depth {mx['i']}")

    print("\n" + "=" * 100)
    print(f"VWATC: cost per executed trade = taker_1 + {CHURN}x(place_top+cancel_top), burned fee")
    print("depth " + "".join(f"{v:>12}" for v in VARIANTS))
    for d in DEPTHS:
        row = f"{d:5} "
        for v in VARIANTS:
            row += fmt(trade_cost(tabs[v], d))
        print(row)

    print("\nWEIGHTED COMPOSITES (burned fee per executed trade)")
    print(f"{'weighting':<22}" + "".join(f"{v:>12}" for v in VARIANTS))
    for name, w in [("transaction-weighted", TX_W), ("revenue-weighted", REV_W),
                    ("future-shifted", FUT_W)]:
        row = f"{name:<22}"
        for v in VARIANTS:
            row += fmt(weighted(tabs[v], w, trade_cost))
        print(row)

    print("\nTOTAL TRADER COST (computation + burned fee) per executed trade,")
    print("with a 10% share of trades executing as 30-order sweeps:")
    def total_trade(tab, depth):
        t1b = op_cost(tab, depth, "taker_1"); t1c = op_cost(tab, depth, "taker_1", 1)
        pb = op_cost(tab, depth, "place_top"); pc = op_cost(tab, depth, "place_top", 1)
        cb = op_cost(tab, depth, "cancel_top"); cc = op_cost(tab, depth, "cancel_top", 1)
        if None in (t1b, pb, cb):
            return None
        t30b = op_cost(tab, depth, "taker_30"); t30c = op_cost(tab, depth, "taker_30", 1)
        taker_b = t1b if t30b is None else 0.9 * t1b + 0.1 * t30b
        taker_c = t1c if t30c is None else 0.9 * t1c + 0.1 * t30c
        return (taker_b + taker_c) + CHURN * ((pb + pc) + (cb + cc))
    print("depth " + "".join(f"{v:>14}" for v in VARIANTS))
    for d in DEPTHS:
        row = f"{d:5} "
        for v in VARIANTS:
            row += fmt(total_trade(tabs[v], d), w=14)
        print(row)
    print(f"\n{'weighting':<22}" + "".join(f"{v:>14}" for v in VARIANTS))
    for name, w in [("transaction-weighted", TX_W), ("revenue-weighted", REV_W),
                    ("future-shifted", FUT_W)]:
        row = f"{name:<22}"
        for v in VARIANTS:
            row += fmt(weighted(tabs[v], w, total_trade), w=14)
        print(row)

    # ceiling
    rows = load("A")
    fails = [r for r in rows if r.get("phase") == "ceiling" and
             ("failed_at" in r or "failed_single_at" in r)]
    if fails:
        print("\nCEILING (A):", json.dumps(fails, indent=1)[:500])


if __name__ == "__main__":
    main()
