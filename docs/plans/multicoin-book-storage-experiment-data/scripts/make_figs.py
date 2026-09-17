#!/usr/bin/env python3
"""Emit the LADDER data blob (JSON) consumed by the whitepaper's figure script,
for both build orders."""
import json, os, statistics, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "results")
VARIANTS = ["A", "B", "C16u", "D64u"]
BUILDS = ["desc", "asc"]
DEPTHS = [8, 48, 128, 512, 2048]
RANKS = [1, 4, 8, 16, 32, 48, 64, 80, 100, 128, 156, 256, 300, 512, 816,
         1024, 1516, 2048]


def load(build):
    g = {}
    for v in VARIANTS:
        suffix = "" if build == "desc" else f".{build}"
        p = os.path.join(RESULTS, f"{v}.ladder{suffix}.jsonl")
        if not os.path.exists(p):
            continue
        for line in open(p):
            r = json.loads(line)
            r["net"] = r["storageCost"] - r["storageRebate"]
            r["burn"] = r["nonRefundableStorageFee"]
            r["comp"] = r["computationCost"]
            g.setdefault((v, r["op"], r["depth"], r["rank"]), []).append(r)
    return g


def steady(rs, m):
    s = [x for x in rs if x["rep"] >= 1] or rs
    return int(statistics.median([x[m] for x in s]))


def slope(xs, ys):
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs)
    return (sum((xs[i] - mx) * (ys[i] - my) for i in range(n)) / den) if den else 0


def reduce_build(g):
    out = {"byDepth": {}, "byRank": {}, "roundTrip": {}, "slopes": {}}
    for op in ("insert", "cancel"):
        out["byDepth"][op] = {}
        for m in ("comp", "net", "burn"):
            out["byDepth"][op][m] = {
                v: [steady(g[(v, op, d, 1)], m) if (v, op, d, 1) in g else None
                    for d in DEPTHS] for v in VARIANTS}
    for D in DEPTHS:
        node = {"ranks": [n for n in RANKS if n <= D]}
        for op in ("insert", "cancel"):
            node[op] = {}
            for m in ("comp", "net", "burn"):
                node[op][m] = {
                    v: [steady(g[(v, op, D, n)], m) if (v, op, D, n) in g else None
                        for n in node["ranks"]] for v in VARIANTS}
        out["byRank"][str(D)] = node
    for v in VARIANTS:
        vals = []
        for d in DEPTHS:
            tot, ok = 0, True
            for op in ("insert", "cancel"):
                k = (v, op, d, 1)
                if k not in g:
                    ok = False
                    break
                tot += steady(g[k], "comp") + steady(g[k], "burn")
            vals.append(tot if ok else None)
        out["roundTrip"][v] = vals
        pts = [(d, steady(g[(v, "insert", d, 1)], "burn")) for d in DEPTHS
               if (v, "insert", d, 1) in g]
        pc = [(d, steady(g[(v, "insert", d, 1)], "comp")) for d in DEPTHS
              if (v, "insert", d, 1) in g]
        out["slopes"][v] = {
            "burn": round(slope([p[0] for p in pts], [p[1] for p in pts]), 1),
            "comp": round(slope([p[0] for p in pc], [p[1] for p in pc]), 1)}
    return out


def main():
    out = {"depths": DEPTHS, "ranks": RANKS, "variants": VARIANTS,
           "builds": BUILDS}
    for b in BUILDS:
        out[b] = reduce_build(load(b))
    dst = os.path.join(RESULTS, "ladder_data.json")
    json.dump(out, open(dst, "w"), separators=(",", ":"))
    print("wrote", dst)

    def row(label, arr, w=13):
        print(f"  {label:>6}: " + " ".join(
            ("—".rjust(w) if x is None else f"{x:{w},}") for x in arr))
    for b in BUILDS:
        print(f"\n########## build = {b} ##########")
        for op in ("insert", "cancel"):
            for m in ("comp", "net", "burn"):
                print(f"\n{op} rank1 {m}  (depths {DEPTHS})")
                for v in VARIANTS:
                    row(v, out[b]["byDepth"][op][m][v])
        print("\nround-trip permanent cost (comp+burn, insert+cancel), rank 1")
        for v in VARIANTS:
            row(v, out[b]["roundTrip"][v])
        a, c = out[b]["roundTrip"]["A"], out[b]["roundTrip"]["C16u"]
        print("  ratio A/C16u: " + " ".join(
            "—".rjust(13) if not (a[i] and c[i]) else f"{a[i]/c[i]:12.2f}x"
            for i in range(len(DEPTHS))))
        print("\nslopes (MIST per standing order, rank-1 insert)")
        for v in VARIANTS:
            s = out[b]["slopes"][v]
            print(f"  {v:>6}: burn {s['burn']:>9}   comp {s['comp']:>7}")
        for D in ("512", "2048"):
            print(f"\nrank sweep, depth {D}, insert burned:")
            node = out[b]["byRank"][D]
            print(f"  {'rank':>5} " + " ".join(f"{v:>12}" for v in VARIANTS))
            for i, n in enumerate(node["ranks"]):
                print(f"  {n:>5} " + " ".join(
                    ("—".rjust(12) if node["insert"]["burn"][v][i] is None
                     else f"{node['insert']['burn'][v][i]:12,}")
                    for v in VARIANTS))


if __name__ == "__main__":
    main()
