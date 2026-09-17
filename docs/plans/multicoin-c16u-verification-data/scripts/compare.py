#!/usr/bin/env python3
"""Compare the real package's measured gas against the C16u reference run.

Reference rows come from the experiment's own results directory (the vendored
variant that produced the whitepaper's C16u column); the new rows come from this
harness. Same operations, same depths, same seeding order, so the two are
directly comparable — a material gap means the port differs from what was
measured, which is the whole point of the check.
"""
import json, os, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "/Users/michaelhahn/books/triex/triex/trinary-exchange"
REF = os.path.join(REPO, "docs/plans/multicoin-book-storage-experiment-data/results")
NEW = os.path.join(HERE, "results")

OPS = ["place_top", "cancel_top", "place_28", "cancel_28",
       "modify_down", "cancel_resting", "taker_1", "taker_10", "taker_30"]
CHURN = 5


def table(path):
    acc = defaultdict(lambda: defaultdict(list))
    if not os.path.exists(path):
        return {}
    for line in open(path):
        r = json.loads(line)
        if r.get("phase") != "steady" or "nonRefundableStorageFee" not in r:
            continue
        acc[r["depth"]][r["op"]].append(r)
    out = {}
    for d, ops in acc.items():
        out[d] = {op: (sum(x["nonRefundableStorageFee"] for x in rs) / len(rs),
                       sum(x["computationCost"] for x in rs) / len(rs))
                  for op, rs in ops.items()}
    return out


def trade_cost(t, d):
    try:
        return t[d]["taker_1"][0] + CHURN * (t[d]["place_top"][0] + t[d]["cancel_top"][0])
    except KeyError:
        return None


def main():
    ref = table(os.path.join(REF, "C16u.jsonl"))
    new = table(os.path.join(NEW, sys.argv[1] + ".jsonl"))
    depths = sorted(d for d in new if d in ref)

    print("Burned storage fee (nonRefundableStorageFee), MIST\n")
    hdr = f"{'op':<16}{'depth':>7}{'reference':>14}{'measured':>14}{'delta':>12}{'':>4}"
    print(hdr)
    print("-" * len(hdr))
    worst = 0.0
    for op in OPS:
        for d in depths:
            a = ref[d].get(op)
            b = new[d].get(op)
            if not a or not b:
                continue
            da = (b[0] - a[0]) / a[0] * 100 if a[0] else 0.0
            worst = max(worst, abs(da))
            flag = "" if abs(da) < 2 else ("  <-" if abs(da) < 10 else "  <<<")
            print(f"{op:<16}{d:>7}{a[0]:>14,.0f}{b[0]:>14,.0f}{da:>11.1f}%{flag}")
    print()

    print("Computation, MIST\n")
    print(hdr)
    print("-" * len(hdr))
    for op in OPS:
        for d in depths:
            a = ref[d].get(op)
            b = new[d].get(op)
            if not a or not b:
                continue
            da = (b[1] - a[1]) / a[1] * 100 if a[1] else 0.0
            flag = "" if abs(da) < 2 else ("  <-" if abs(da) < 10 else "  <<<")
            print(f"{op:<16}{d:>7}{a[1]:>14,.0f}{b[1]:>14,.0f}{da:>11.1f}%{flag}")
    print()

    print("Cost of an executed trade (taker_1 + 5 x place/cancel), burned MIST\n")
    print(f"{'depth':>7}{'reference':>14}{'measured':>14}{'delta':>12}")
    print("-" * 47)
    for d in depths:
        a, b = trade_cost(ref, d), trade_cost(new, d)
        if a is None or b is None:
            continue
        print(f"{d:>7}{a:>14,.0f}{b:>14,.0f}{(b-a)/a*100:>11.1f}%")
    print(f"\nlargest per-op burned-fee deviation: {worst:.1f}%")


if __name__ == "__main__":
    main()
