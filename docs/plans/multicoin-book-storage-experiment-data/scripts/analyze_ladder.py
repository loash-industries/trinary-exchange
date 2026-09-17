#!/usr/bin/env python3
"""Reduce the position x book-size grid to per-cell figures and emit JSON + a
markdown raw-results table.

Metrics per operation, straight from the transaction's own effects:
  computation  = computationCost                       (never rebated)
  net_storage  = storageCost - storageRebate           (deposit moved this tx)
  burned       = nonRefundableStorageFee               (permanently lost)
  total_perm   = computation + burned                  (what never comes back)

rep 0 of each cell is the first touch of the prober account at that price and
carries one-off account-map growth; the steady value is the median of reps >= 1.
Both are reported.
"""
import json, os, statistics, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "results")
VARIANTS = ["A", "B", "C16u", "D64u"]
LABEL = {
    "A": "A — flat vector",
    "B": "B — BigVector, no hot buffer",
    "C16u": "C16u — BigVector + 16/12 buffer, unidirectional",
    "D64u": "D64u — BigVector + 64/30 buffer, unidirectional",
}


def load():
    rows = []
    for v in VARIANTS:
        p = os.path.join(RESULTS, f"{v}.ladder.jsonl")
        if not os.path.exists(p):
            continue
        for line in open(p):
            r = json.loads(line)
            r["net_storage"] = r["storageCost"] - r["storageRebate"]
            r["burned"] = r["nonRefundableStorageFee"]
            r["computation"] = r["computationCost"]
            r["total_perm"] = r["computation"] + r["burned"]
            rows.append(r)
    return rows


def cells(rows):
    """{(variant, op, depth, rank): {metric: steady, metric+'_first': rep0}}"""
    acc = {}
    for r in rows:
        k = (r["variant"], r["op"], r["depth"], r["rank"])
        acc.setdefault(k, []).append(r)
    out = {}
    for k, rs in acc.items():
        rs.sort(key=lambda x: x["rep"])
        steady = [x for x in rs if x["rep"] >= 1] or rs
        c = {"class": rs[0]["class"], "n_reps": len(rs)}
        for m in ("computation", "net_storage", "burned", "total_perm",
                  "storageCost", "storageRebate"):
            c[m] = int(statistics.median([x[m] for x in steady]))
            c[m + "_first"] = rs[0][m]
            c[m + "_spread"] = max(x[m] for x in steady) - min(x[m] for x in steady)
        out[k] = c
    return out


def fmt(n):
    return f"{n:,}"


def main():
    rows = load()
    C = cells(rows)
    depths = sorted({k[2] for k in C})
    ranks = sorted({k[3] for k in C})
    json.dump({f"{k[0]}|{k[1]}|{k[2]}|{k[3]}": v for k, v in C.items()},
              open(os.path.join(RESULTS, "ladder_cells.json"), "w"), indent=0)

    # --- console summary: top-of-book by depth ---
    for op in ("insert", "cancel"):
        print(f"\n### {op} at rank 1 (top of book) ###")
        print(f"{'depth':>6} | " + " | ".join(f"{v:>26}" for v in VARIANTS))
        print(f"{'':>6} | " + " | ".join(f"{'comp / netstore / burn':>26}" for v in VARIANTS))
        for d in depths:
            cellsr = []
            for v in VARIANTS:
                c = C.get((v, op, d, 1))
                cellsr.append("—".rjust(26) if not c else
                              f"{c['computation']/1e6:7.3f}M {c['net_storage']/1e6:8.3f}M {c['burned']/1e3:6.1f}k")
            print(f"{d:>6} | " + " | ".join(cellsr))

    # --- rank sweep inside the XL book ---
    print("\n### rank sweep, depth 2048 — computation (M MIST) ###")
    print(f"{'rank':>6} | " + " | ".join(f"{v:>10}" for v in VARIANTS))
    for n in ranks:
        line = []
        for v in VARIANTS:
            c = C.get((v, "insert", 2048, n))
            line.append("—".rjust(10) if not c else f"{c['computation']/1e6:10.3f}")
        print(f"{n:>6} | " + " | ".join(line))

    # --- slopes: computation per resting order, rank-1 insert ---
    print("\n### rank-1 insert: computation slope vs depth ###")
    for v in VARIANTS:
        pts = [(d, C[(v, "insert", d, 1)]["computation"]) for d in depths
               if (v, "insert", d, 1) in C]
        if len(pts) < 2:
            continue
        n = len(pts)
        mx = sum(p[0] for p in pts) / n
        my = sum(p[1] for p in pts) / n
        num = sum((p[0] - mx) * (p[1] - my) for p in pts)
        den = sum((p[0] - mx) ** 2 for p in pts)
        slope = num / den
        print(f"  {v:>5}: {slope:9.2f} MIST per resting order   "
              f"intercept {my - slope*mx:,.0f}   "
              f"d8={pts[0][1]:,} d2048={pts[-1][1]:,}")


if __name__ == "__main__":
    main()
