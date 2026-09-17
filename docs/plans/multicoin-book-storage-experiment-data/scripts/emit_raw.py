#!/usr/bin/env python3
"""Emit the rank x book-size grid as a markdown raw-results file."""
import json, os, statistics, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "results")
VARIANTS = ["A", "B", "C16u", "D64u"]
BUILDS = [("desc", "best-price-last"), ("asc", "worst-price-last")]
CLASSES = [("tiny", 8), ("small", 48), ("medium", 128), ("large", 512), ("xl", 2048)]
POSITIONS = [1, 4, 8, 16, 32, 48, 64, 80, 100, 128, 156, 256, 300, 512, 816,
             1024, 1516, 2048]
DESC = {
    "A": "flat `vector<Order>`, price-ordered, no index",
    "B": "`BigVector<Order>` keyed by `(price<<64)|seq`, no inline buffer",
    "C16u": "`BigVector` + 16-order inline buffer, spill-to-12, no refill",
    "D64u": "`BigVector` + 64-order inline buffer, spill-to-30, no refill",
}


def load(v, build):
    suffix = "" if build == "desc" else f".{build}"
    p = os.path.join(RESULTS, f"{v}.ladder{suffix}.jsonl")
    if not os.path.exists(p):
        return []
    rows = [json.loads(l) for l in open(p)]
    for r in rows:
        r["net_storage"] = r["storageCost"] - r["storageRebate"]
        r["burned"] = r["nonRefundableStorageFee"]
        r["computation"] = r["computationCost"]
        r["build"] = build
    return rows


def grid(build):
    g = {}
    for v in VARIANTS:
        for r in load(v, build):
            g.setdefault((v, r["op"], r["depth"], r["rank"]), []).append(r)
    return g


def steady(rs, m):
    s = [x for x in rs if x["rep"] >= 1] or rs
    return int(statistics.median([x[m] for x in s]))


def f(n):
    return f"{n:,}"


def fsign(n):
    return ("+" if n >= 0 else "−") + f"{abs(n):,}"


def main():
    G = {b: grid(b) for b, _ in BUILDS}
    out = []
    W = out.append

    W("# Rank × book-size cost grid — raw localnet measurements")
    W("")
    W("Companion data file to "
      "[`multicoin-book-storage-experiment-results.md`]"
      "(multicoin-book-storage-experiment-results.md) and to Appendix B of the "
      "*Interaction Depth* whitepaper. Every number below is read from a real "
      "transaction's own `effects.gasUsed` on a local Sui network — nothing is "
      "modelled, extrapolated, or averaged across designs.")
    W("")
    W("## 1. What was measured")
    W("")
    W("For each candidate book layout, the ask side of one pool is grown in "
      "place through five size classes. At every size a dedicated *prober* "
      "account places one limit order at rank `n` and then cancels it, so the "
      "book returns to its exact prior shape. Each measured operation is its "
      "own transaction through the production entry points "
      "(`trading_account::generate_proof_as_owner` + "
      "`multicoin_pool::place_limit_order` / `cancel_order` in one PTB). "
      "Nothing crosses, so no fills are involved and the insert/cancel path is "
      "isolated from matching.")
    W("")
    W("Seeded asks use a price stride of 10, so a probe can be placed at *any* "
      "rank without colliding with a seeded price. Rank 1 is top of book — a "
      "new best ask.")
    W("")
    W("| Class | Ask-side depth | Ranks probed |")
    W("|---|---:|---|")
    for cls, D in CLASSES:
        ns = [n for n in POSITIONS if n <= D]
        W(f"| {cls} | {D} | {', '.join(str(n) for n in ns)} |")
    W("")
    W("| Design | Layout |")
    W("|---|---|")
    for v in VARIANTS:
        W(f"| **{v}** | {DESC[v]} |")
    W("")
    W("### 1.1 Two build orders")
    W("")
    W("Hot-buffer occupancy is **path-dependent** under unidirectional spill, "
      "so the grid is run twice. The two runs bracket the real behaviour of a "
      "cached design and neither alone is representative.")
    W("")
    W("| Build | Seeding | Resulting buffer state |")
    W("|---|---|---|")
    W("| **desc** (primary) | each seeded order is a **new best** ask "
      "(`TOP − 10j`) | every order is admitted inline and spills the buffer's "
      "worst to the tree, so the buffer ends holding the best 12–16 orders — "
      "the shape a live two-sided book settles into |")
    W("| **asc** | each seeded order is **worse** than everything standing "
      "(`MID + 10(i+1)`) | no order beats the buffer's worst, so all of them "
      "go straight to the tree and the buffer never grows past its first "
      "order — a book built outward from a single anchor quote, and the "
      "adversarial case for a no-refill cache |")
    W("")
    W("The difference is large and it is not noise: with a populated buffer "
      "C16u pays more per operation (the inline bytes are rewritten every "
      "time) but keeps ranks 1–12 off the tree; with an empty buffer it pays "
      "less per operation but sends rank 2 and beyond to the tree. Both "
      "columns are reported throughout.")
    W("")
    W("### 1.2 Metrics")
    W("")
    W("| Column | Definition |")
    W("|---|---|")
    W("| `comp` | `computationCost` — execution. Never rebated. Quantised "
      "into 10,000-MIST buckets. |")
    W("| `net storage` | `storageCost − storageRebate` — the storage deposit "
      "that moved in this transaction. Positive on an insert (the object "
      "written is larger than the one replaced), negative on a cancel (the "
      "deposit comes back). The two do not cancel exactly; the residue is the "
      "burned fee. |")
    W("| `burned` | `nonRefundableStorageFee` — the ~1% slice of "
      "`storageCost` that is permanently destroyed. Charged against the "
      "**whole rewritten object**, not the delta. |")
    W("| `storage cost` / `rebate` | the gross components, for audit. |")
    W("")
    W("All figures in MIST. Chain config: protocol version 126, reference gas "
      "price 1,000, `storage_gas_price` 76, `storage_rebate_rate` 9,900 "
      "(99%), `max_move_object_size` 256,000. Three repetitions per cell; "
      "`rep 0` is the first touch of a given price by the prober account and "
      "carries one-off account-map growth, so the tabulated value is the "
      "**median of reps 1–2** and every repetition appears in the full dump "
      "in §5.")
    W("")

    # ---- section 2: top of book vs depth ----
    W("## 2. Top of book (rank 1) as the book deepens")
    W("")
    for op in ("insert", "cancel"):
        for bi, (b, blabel) in enumerate(BUILDS):
            W(f"### 2.{(0 if op=='insert' else 2)+bi+1} "
              f"{op.capitalize()} at rank 1 — {b} build ({blabel})")
            W("")
            W("| Depth | " + " | ".join(
                f"{v} comp | {v} net storage | {v} burned" for v in VARIANTS)
              + " |")
            W("|---" + "|---:" * (3 * len(VARIANTS)) + "|")
            for cls, D in CLASSES:
                cells = []
                for v in VARIANTS:
                    rs = G[b].get((v, op, D, 1))
                    if not rs:
                        cells += ["—", "—", "—"]
                    else:
                        cells += [f(steady(rs, "computation")),
                                  fsign(steady(rs, "net_storage")),
                                  f(steady(rs, "burned"))]
                W(f"| {D} ({cls}) | " + " | ".join(cells) + " |")
            W("")

    W("### 2.5 Permanent cost of one place+cancel round trip at rank 1")
    W("")
    W("`computation + burned`, summed over the insert and the cancel — the "
      "part of the bill that never comes back.")
    W("")
    for b, blabel in BUILDS:
        W(f"**{b} build ({blabel})**")
        W("")
        W("| Depth | " + " | ".join(VARIANTS) + " | A ÷ C16u |")
        W("|---" + "|---:" * (len(VARIANTS) + 1) + "|")
        for cls, D in CLASSES:
            vals = {}
            for v in VARIANTS:
                tot, ok = 0, True
                for op in ("insert", "cancel"):
                    rs = G[b].get((v, op, D, 1))
                    if not rs:
                        ok = False
                        break
                    tot += steady(rs, "computation") + steady(rs, "burned")
                vals[v] = tot if ok else None
            ratio = ("—" if not (vals.get("A") and vals.get("C16u"))
                     else f"{vals['A']/vals['C16u']:.2f}×")
            W(f"| {D} ({cls}) | " +
              " | ".join(f(vals[v]) if vals[v] else "—" for v in VARIANTS) +
              f" | {ratio} |")
        W("")

    # ---- section 3: rank sweeps ----
    W("## 3. Rank sweeps inside each book size")
    W("")
    metrics = [("computation", "computation"), ("net_storage", "net storage"),
               ("burned", "burned")]
    for mi, (metric, label) in enumerate(metrics):
        W(f"### 3.{mi+1} Insert — {label}")
        W("")
        for cls, D in CLASSES:
            W(f"**{cls} — depth {D}**")
            W("")
            W("| Rank | " + " | ".join(
                f"{v} ({b})" for b, _ in BUILDS for v in VARIANTS) + " |")
            W("|---" + "|---:" * (len(VARIANTS) * len(BUILDS)) + "|")
            for n in POSITIONS:
                if n > D:
                    continue
                cells = []
                for b, _ in BUILDS:
                    for v in VARIANTS:
                        rs = G[b].get((v, "insert", D, n))
                        if not rs:
                            cells.append("—")
                        else:
                            val = steady(rs, metric)
                            cells.append(fsign(val) if metric == "net_storage"
                                         else f(val))
                W(f"| {n} | " + " | ".join(cells) + " |")
            W("")

    W("### 3.4 Cancel — burned, by rank")
    W("")
    for cls, D in CLASSES:
        W(f"**{cls} — depth {D}**")
        W("")
        W("| Rank | " + " | ".join(
            f"{v} ({b})" for b, _ in BUILDS for v in VARIANTS) + " |")
        W("|---" + "|---:" * (len(VARIANTS) * len(BUILDS)) + "|")
        for n in POSITIONS:
            if n > D:
                continue
            cells = []
            for b, _ in BUILDS:
                for v in VARIANTS:
                    rs = G[b].get((v, "cancel", D, n))
                    cells.append("—" if not rs else f(steady(rs, "burned")))
            W(f"| {n} | " + " | ".join(cells) + " |")
        W("")

    # ---- section 4: fitted slopes ----
    W("## 4. Fitted slopes, rank-1 insert")
    W("")
    W("Least squares over the five size classes, MIST per standing order.")
    W("")
    W("| Design | burned (desc) | computation (desc) | burned (asc) | "
      "computation (asc) |")
    W("|---" + "|---:" * 4 + "|")
    for v in VARIANTS:
        cells = []
        for b, _ in BUILDS:
            for m in ("burned", "computation"):
                pts = [(D, steady(G[b][(v, "insert", D, 1)], m))
                       for _, D in CLASSES if (v, "insert", D, 1) in G[b]]
                if len(pts) < 2:
                    cells.append("—")
                    continue
                n = len(pts)
                mx = sum(p[0] for p in pts) / n
                my = sum(p[1] for p in pts) / n
                den = sum((p[0] - mx) ** 2 for p in pts)
                sl = sum((p[0] - mx) * (p[1] - my) for p in pts) / den
                cells.append(f"{sl:,.1f}")
        # reorder to burned(desc), comp(desc), burned(asc), comp(asc)
        W(f"| {v} | " + " | ".join(cells) + " |")
    W("")

    # ---- section 5: full dump ----
    W("## 5. Full per-transaction dump")
    W("")
    W("Every measured transaction, unaggregated.")
    W("")
    W("| Design | Build | Class | Depth | Rank | Probe price | Op | Rep | "
      "comp | storage cost | rebate | net storage | burned |")
    W("|---|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|")
    allrows = []
    for b, _ in BUILDS:
        for v in VARIANTS:
            allrows += load(v, b)
    allrows.sort(key=lambda r: (r["build"], VARIANTS.index(r["variant"]),
                                r["depth"], r["rank"], r["op"], r["rep"]))
    for r in allrows:
        W(f"| {r['variant']} | {r['build']} | {r['class']} | {r['depth']} | "
          f"{r['rank']} | {r.get('price','—')} | {r['op']} | {r['rep']} | "
          f"{f(r['computation'])} | {f(r['storageCost'])} | "
          f"{f(r['storageRebate'])} | {fsign(r['net_storage'])} | "
          f"{f(r['burned'])} |")
    W("")
    W(f"Rows: {len(allrows)}.")
    W("")
    W("## 6. Reproducing")
    W("")
    W("```")
    W("# one local network, one address, strictly sequential")
    W("SUI_PROTOCOL_CONFIG_OVERRIDE_ENABLE=1 \\")
    W("SUI_PROTOCOL_CONFIG_OVERRIDE_max_move_package_size=512000 \\")
    W("  sui start --force-regenesis --with-faucet")
    W("python3 scripts/bootstrap.py        # publish token, multicoin, 4x triex")
    W("./scripts/run_ladder.sh desc        # primary grid")
    W("./scripts/run_ladder.sh asc         # empty-buffer contrast")
    W("python3 scripts/make_figs.py        # reductions + figure data")
    W("python3 scripts/emit_raw.py         # this file")
    W("```")
    W("")

    dst = sys.argv[1] if len(sys.argv) > 1 else os.path.join(RESULTS, "raw.md")
    open(dst, "w").write("\n".join(out) + "\n")
    print(f"wrote {dst} ({len(out)} lines, {len(allrows)} tx rows)")


if __name__ == "__main__":
    main()
