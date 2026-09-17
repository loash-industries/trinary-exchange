#!/usr/bin/env python3
"""Rank x book-size cost grid for insert / cancel.

The ask side of one pool is grown in place through five size classes and probed
at many ranks. Seeded asks use a price stride of 10, so a probe order can be
placed at ANY rank n without colliding with a seeded price; rank 1 is top of
book (a new best ask). Every probe is one transaction (proof + place) and the
matching cancel is another; nothing crosses, so no fills are involved and the
book returns to its exact prior shape after each pair.

Two build orders, because hot-buffer occupancy is path-dependent:

  desc (default)  each seeded order is a NEW BEST ask, so it is admitted to the
                  inline buffer and spills the buffer's worst to the tree. The
                  buffer ends up holding the best HOT_SPILL_TARGET..HOT_CAPACITY
                  orders -- the shape a live two-sided book settles into.
                  Seeded ask j (0-based, in placement order) sits at
                  TOP - 10*j; after k placements the rank-n price is
                  TOP - 10*(k-n) and the probe goes at that minus 5.

  asc             each seeded order is WORSE than every standing order, so under
                  unidirectional spill it goes straight to the tree and the
                  buffer never grows past its first order. A real path (a book
                  built outward from one anchor quote) and the adversarial case
                  for a no-refill cache.
                  Seeded ask i sits at MID + 10*(i+1); rank-n probe at
                  MID + 10n - 5.

Usage: python3 ladder.py <variant> [asc|desc] [max_class]
"""
import json, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from driver import (Variant, ptb, gas, placed_events, MID, QTY,
                    PER_MAKER, BUDGET_BIG, RESULTS)

STRIDE = 10
REPS = 3
CLASSES = [("tiny", 8), ("small", 48), ("medium", 128), ("large", 512), ("xl", 2048)]
POSITIONS = [1, 4, 8, 16, 32, 48, 64, 80, 100, 128, 156, 256, 300, 512, 816,
             1024, 1516, 2048]
MAXD = CLASSES[-1][1]
TOP = MID + STRIDE * (MAXD + 1)   # 120,490 — worst ask of the descending build


class Ladder:
    def __init__(self, name, build="desc"):
        self.v = Variant(name)
        self.name = name
        self.build = build
        suffix = "" if build == "desc" else f".{build}"
        self.out_f = os.path.join(RESULTS, f"{name}.ladder{suffix}.jsonl")

    # ---- price ladder ----
    def seed_price(self, j):
        """Price of the j-th seeded order, in placement order."""
        return (TOP - STRIDE * j) if self.build == "desc" \
            else (MID + STRIDE * (j + 1))

    def probe_price(self, k, n):
        """Price that lands at rank n when k orders are standing."""
        if self.build == "desc":
            return TOP - STRIDE * (k - n) - STRIDE // 2
        return MID + STRIDE * n - STRIDE // 2

    def rec(self, row):
        with open(self.out_f, "a") as f:
            f.write(json.dumps(row) + "\n")

    def grow_to(self, pool, placed, target):
        v = self.v
        while placed < target:
            room = PER_MAKER - (placed % PER_MAKER)
            batch = 45 if placed < 300 else (25 if placed < 1024 else 15)
            chunk = min(batch, target - placed, room)
            makers = v.ensure_makers(placed // PER_MAKER + 1)
            acct = makers[placed // PER_MAKER]
            cmds = ["--move-call",
                    f"{v.s['pkg']}::trading_account::generate_proof_as_owner",
                    f"@{acct}", "--assign", "pr"]
            for j in range(chunk):
                cmds += v.place_cmds(pool, acct, self.seed_price(placed + j),
                                     QTY, False, proof_var="pr")
            ptb(cmds, budget=BUDGET_BIG)
            placed += chunk
        return placed

    def probe(self, pool, prober, depth, cls, n):
        v = self.v
        price = self.probe_price(depth, n)
        for rep in range(REPS):
            d = ptb(v.place_cmds(pool, prober, price, QTY, False),
                    budget=BUDGET_BIG)
            self.rec({"variant": self.name, "build": self.build, "class": cls,
                      "depth": depth, "rank": n, "price": price, "rep": rep,
                      "op": "insert", **gas(d)})
            oid = placed_events(d, v.s["pkg"])[0][0]
            d = v.cancel_one(pool, prober, oid)
            self.rec({"variant": self.name, "build": self.build, "class": cls,
                      "depth": depth, "rank": n, "price": price, "rep": rep,
                      "op": "cancel", **gas(d)})

    def run(self, max_class=None):
        v = self.v
        pool = v.new_pool()
        prober = v.new_account(cred_amt=5_000_000_000_000,
                               base_amt=5_000_000_000_000)
        v.s[f"ladder_pool_{self.build}"] = pool
        v.s[f"prober_{self.build}"] = prober
        v.save()
        placed = 0
        t0 = time.time()
        for cls, D in CLASSES:
            if max_class and D > max_class:
                break
            placed = self.grow_to(pool, placed, D)
            print(f"[{self.name}/{self.build}] grown to {cls} ({D}) "
                  f"t={time.time()-t0:.0f}s", flush=True)
            for n in POSITIONS:
                if n > D:
                    continue
                self.probe(pool, prober, D, cls, n)
                print(f"[{self.name}/{self.build}]   {cls} d={D} rank={n} "
                      f"t={time.time()-t0:.0f}s", flush=True)
        print(f"[{self.name}/{self.build}] ladder done in "
              f"{time.time()-t0:.0f}s", flush=True)


if __name__ == "__main__":
    build = sys.argv[2] if len(sys.argv) > 2 else "desc"
    mc = int(sys.argv[3]) if len(sys.argv) > 3 else None
    Ladder(sys.argv[1], build).run(mc)
