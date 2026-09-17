#!/usr/bin/env python3
"""End-to-end gas experiment driver for the multicoin book storage variants.

Every measured operation is its own transaction against a local Sui network,
driven through the full production path:
  trading_account::generate_proof_as_owner + multicoin_pool::<op> in one PTB.
Gas figures are read from the transaction's own effects.

State (package ids, account ids, order-id maps) is persisted per variant in
results/<variant>.state.json; measurements append to results/<variant>.jsonl.
"""
import json, os, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "results")
SHARED_F = os.path.join(RESULTS, "shared.json")

CLOCK = "@0x6"
EXPIRE = "1899999999999"
QTY = 10
MID = 100_000  # asks seeded at MID+1 .. MID+d, best ask = MID+1
PER_MAKER = 90  # stay under MAX_OPEN_ORDERS=100 per account per pool
SEED_BATCH = 45  # placements per seeding PTB
BUDGET_SMALL = "5000000000"
BUDGET_BIG = "30000000000"

DEPTHS = [0, 5, 10, 15, 20, 30, 45, 60, 100, 150, 300]


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def ptb(cmds, budget=BUDGET_SMALL, retries=2):
    """Run sui client ptb, return parsed JSON. Raises on failure."""
    cmd = ["sui", "client", "ptb"] + cmds + ["--gas-budget", budget, "--json"]
    for attempt in range(retries + 1):
        out = sh(cmd)
        txt = out.stdout.strip()
        # The CLI sometimes prefixes warnings; find the JSON object.
        i = txt.find("{")
        if i >= 0:
            try:
                d = json.loads(txt[i:])
            except json.JSONDecodeError:
                d = None
            if d is not None:
                st = d.get("effects", {}).get("status", {})
                if st.get("status") == "success":
                    return d
                raise RuntimeError(f"tx failed: {json.dumps(st)[:400]}")
        if attempt < retries:
            time.sleep(1.0)
            continue
        raise RuntimeError(
            f"ptb error: {(out.stderr or out.stdout)[:600]}"
        )


def gas(d):
    g = d["effects"]["gasUsed"]
    return {k: int(g[k]) for k in (
        "computationCost", "storageCost", "storageRebate", "nonRefundableStorageFee")}


def created(d, needle):
    for c in d.get("objectChanges", []):
        if c.get("type") == "created" and needle in c.get("objectType", ""):
            yield c["objectId"]


def placed_events(d, pkg):
    """[(order_id_str, price, trading_account_id)] from OrderPlaced events."""
    out = []
    for e in d.get("events", []):
        if e["type"].startswith(pkg) and e["type"].endswith("::order_info::OrderPlaced"):
            pj = e["parsedJson"]
            out.append((str(pj["order_id"]), int(pj["price"]), pj["trading_account_id"]))
    return out


class Variant:
    def __init__(self, name):
        self.name = name
        self.state_f = os.path.join(RESULTS, f"{name}.state.json")
        self.out_f = os.path.join(RESULTS, f"{name}.jsonl")
        self.s = json.load(open(self.state_f)) if os.path.exists(self.state_f) else {}
        self.shared = json.load(open(SHARED_F))

    def save(self):
        json.dump(self.s, open(self.state_f, "w"), indent=1)

    def rec(self, row):
        with open(self.out_f, "a") as f:
            f.write(json.dumps(row) + "\n")

    # ---------- setup ----------
    def setup(self, pkg, registry, policy, admincap):
        sh_ = self.shared
        cred = f"{sh_['token_pkg']}::cred::CRED"
        ptb([
            "--move-call", f"{pkg}::registry::add_approved_quote<{cred}>",
            f"@{registry}", f"@{sh_['cred_meta']}", f"@{admincap}",
            "--move-call", f"{pkg}::fee_policy::bootstrap_quote<{cred}>",
            f"@{policy}", "1u16", "2u16", "1000000u128", f"@{admincap}",
        ])
        self.s.update(pkg=pkg, registry=registry, policy=policy, admincap=admincap,
                      accounts=[], taker=None)
        self.save()
        print(f"[{self.name}] quote approved + fee classes bootstrapped")

    def new_account(self, cred_amt, base_amt):
        sh_ = self.shared
        pkg = self.s["pkg"]
        cred = f"{sh_['token_pkg']}::cred::CRED"
        cmds = ["--move-call", f"{pkg}::trading_account::new", "--assign", "acct"]
        if cred_amt:
            cmds += ["--split-coins", f"@{sh_['cred_coin']}", f"[{cred_amt}]",
                     "--assign", "pay",
                     "--move-call", f"{pkg}::trading_account::deposit<{cred}>",
                     "acct", "pay.0"]
        if base_amt:
            cmds += ["--move-call", f"{sh_['mc_pkg']}::multicoin::mint_balance",
                     f"@{sh_['ccap']}", f"@{sh_['collection']}", "1u64", f"{base_amt}u64",
                     "--assign", "bal",
                     "--move-call", f"{pkg}::trading_account::deposit_multicoin",
                     "acct", "bal"]
        cmds += ["--move-call", f"0x2::transfer::public_share_object<{pkg}::trading_account::TradingAccount>",
                 "acct"]
        d = ptb(cmds)
        acct = next(created(d, "::trading_account::TradingAccount"))
        return acct

    def ensure_makers(self, n):
        while len(self.s["accounts"]) < n:
            a = self.new_account(cred_amt=1_000_000_000_000, base_amt=1_000_000_000_000)
            self.s["accounts"].append(a)
            self.save()
        return self.s["accounts"]

    def ensure_taker(self):
        if not self.s.get("taker"):
            self.s["taker"] = self.new_account(cred_amt=50_000_000_000_000, base_amt=1_000_000)
            self.save()
        return self.s["taker"]

    # ---------- pool / orders ----------
    def new_pool(self):
        s, sh_ = self.s, self.shared
        cred = f"{sh_['token_pkg']}::cred::CRED"
        cmds = []
        if s.get("last_pool"):
            # registry allows one pool per (collection, asset, quote): retire the old one
            cmds += ["--move-call",
                     f"{s['pkg']}::multicoin_pool::unregister_pool_admin<{cred}>",
                     f"@{s['last_pool']}", f"@{s['registry']}", f"@{s['admincap']}"]
        cmds += ["--move-call", f"{s['pkg']}::multicoin_pool::create_pool_admin<{cred}>",
                 f"@{s['registry']}", f"@{s['policy']}", f"@{sh_['collection']}",
                 "1u64", f"@{s['admincap']}"]
        d = ptb(cmds)
        pool = next(created(d, "::multicoin_pool::MultiCoinPool<"))
        s["last_pool"] = pool
        self.save()
        return pool

    def place_cmds(self, pool, acct, price, qty, is_bid, order_type=0, proof_var=None):
        """Commands for one placement; proof generated unless proof_var given."""
        s, sh_ = self.s, self.shared
        cred = f"{sh_['token_pkg']}::cred::CRED"
        cmds = []
        pv = proof_var
        if pv is None:
            pv = "p"
            cmds += ["--move-call", f"{s['pkg']}::trading_account::generate_proof_as_owner",
                     f"@{acct}", "--assign", pv]
        cmds += ["--move-call", f"{s['pkg']}::multicoin_pool::place_limit_order<{cred}>",
                 f"@{pool}", f"@{s['policy']}", f"@{acct}", pv,
                 f"{order_type}u8", "0u8", f"{price}u64", f"{qty}u64",
                 "true" if is_bid else "false", f"{EXPIRE}u64", CLOCK]
        return cmds

    def place_one(self, pool, acct, price, qty=QTY, is_bid=False, order_type=0):
        d = ptb(self.place_cmds(pool, acct, price, qty, is_bid, order_type))
        return d

    def seed(self, pool, prices, start_maker=0):
        """Batch-place asks at the given prices (unmeasured). Returns {price: (id, acct)}.

        Placed in DESCENDING price order (each ask a new best), so hot-buffer
        variants end with the buffer holding the best orders of the side --
        the shape a live deep book settles into."""
        prices = sorted(prices, reverse=True)
        makers = self.ensure_makers(start_maker + (len(prices) + PER_MAKER - 1) // PER_MAKER)
        idmap = {}
        i = 0
        while i < len(prices):
            chunk = prices[i:i + SEED_BATCH]
            cmds, cur_proof = [], {}
            for j, p in enumerate(chunk):
                gi = i + j
                acct = makers[start_maker + gi // PER_MAKER]
                if acct not in cur_proof:
                    pv = f"pr{len(cur_proof)}"
                    cmds += ["--move-call",
                             f"{self.s['pkg']}::trading_account::generate_proof_as_owner",
                             f"@{acct}", "--assign", pv]
                    cur_proof[acct] = pv
                cmds += self.place_cmds(pool, acct, p, QTY, False,
                                        proof_var=cur_proof[acct])
            d = ptb(cmds, budget=BUDGET_BIG)
            for oid, price, tacct in placed_events(d, self.s["pkg"]):
                # map account object id back to our account address list
                idmap[price] = (oid, tacct)
            i += len(chunk)
        # resolve trading_account_id -> account object id (they are the same id)
        return {p: (oid, tid) for p, (oid, tid) in idmap.items()}

    def fmt_oid(self, oid):
        """Order id literal for PTB: u64 for A, u128 for tree variants."""
        return f"{oid}u128" if self.s.get("u128") else f"{oid}u64"

    def cancel_one(self, pool, acct, oid):
        s, sh_ = self.s, self.shared
        cred = f"{sh_['token_pkg']}::cred::CRED"
        return ptb([
            "--move-call", f"{s['pkg']}::trading_account::generate_proof_as_owner",
            f"@{acct}", "--assign", "p",
            "--move-call", f"{s['pkg']}::multicoin_pool::cancel_order<{cred}>",
            f"@{pool}", f"@{s['policy']}", f"@{acct}", "p", self.fmt_oid(oid), CLOCK,
        ])

    def modify_one(self, pool, acct, oid, new_qty):
        s, sh_ = self.s, self.shared
        cred = f"{sh_['token_pkg']}::cred::CRED"
        return ptb([
            "--move-call", f"{s['pkg']}::trading_account::generate_proof_as_owner",
            f"@{acct}", "--assign", "p",
            "--move-call", f"{s['pkg']}::multicoin_pool::modify_order<{cred}>",
            f"@{pool}", f"@{s['policy']}", f"@{acct}", "p", self.fmt_oid(oid),
            f"{new_qty}u64", CLOCK,
        ])

    def taker_bid(self, pool, k):
        """IOC bid crossing the k best asks (prices MID+1..MID+k, qty 10 each)."""
        taker = self.ensure_taker()
        d = ptb(self.place_cmds(pool, taker, MID + k, QTY * k, True, order_type=1),
                budget=BUDGET_BIG)
        return d

    # ---------- runs ----------
    def run_construction(self, n=300):
        """Fresh pool; place n asks, each a new best price, one tx each."""
        pool = self.new_pool()
        makers = self.ensure_makers((n + PER_MAKER - 1) // PER_MAKER)
        t0 = time.time()
        for i in range(n):
            price = MID + 1000 - i  # strictly descending: every order a new best
            acct = makers[i // PER_MAKER]
            d = self.place_one(pool, acct, price)
            self.rec({"phase": "construction", "i": i, "depth_before": i,
                      "op": "place_new_best", **gas(d)})
            if (i + 1) % 50 == 0:
                print(f"[{self.name}] construction {i+1}/{n} ({time.time()-t0:.0f}s)",
                      flush=True)
        self.s["construction_pool"] = pool
        self.save()

    def run_steady(self, depths=None):
        depths = depths or DEPTHS
        for d_ in depths:
            self.steady_at_depth(d_)

    def steady_at_depth(self, depth):
        name = self.name
        pool = self.new_pool()
        prices = [MID + 1 + i for i in range(depth)]
        idmap = self.seed(pool, prices) if depth else {}
        makers = self.ensure_makers(max(1, (depth + PER_MAKER - 1) // PER_MAKER))
        m0 = makers[0]
        t0 = time.time()

        def rec(op, d, extra=None):
            row = {"phase": "steady", "depth": depth, "op": op, **gas(d)}
            if extra:
                row.update(extra)
            self.rec(row)

        # place/cancel churn at top of book, 3 cycles
        for c in range(3):
            d = self.place_one(pool, m0, MID)  # new best ask
            rec("place_top", d, {"cycle": c})
            ev = placed_events(d, self.s["pkg"])
            oid = ev[0][0]
            d = self.cancel_one(pool, m0, oid)
            rec("cancel_top", d, {"cycle": c})

        # place/cancel at ~28 from best (or at the tail for shallow books)
        off = min(28, depth) if depth else 28
        for c in range(2):
            p28 = MID + 1 + off  # sits right at/behind the 28th order
            d = self.place_one(pool, m0, p28)
            rec("place_28", d, {"cycle": c, "offset": off})
            oid = placed_events(d, self.s["pkg"])[0][0]
            d = self.cancel_one(pool, m0, oid)
            rec("cancel_28", d, {"cycle": c, "offset": off})

        # modify down + cancel deep resting order (depth>=1)
        if depth >= 1:
            tgt_price = MID + 1 + min(27, depth - 1)  # ~28th order or last
            oid, tacct = idmap[tgt_price]
            d = self.modify_one(pool, tacct, oid, QTY // 2)
            rec("modify_down", d)
            d = self.cancel_one(pool, tacct, oid)
            rec("cancel_resting", d)
            d = self.place_one(pool, tacct, tgt_price)  # restore
            rec("place_restore", d)
            idmap[tgt_price] = (placed_events(d, self.s["pkg"])[0][0], tacct)

        # taker fills; restores go to fresh maker accounts so no account
        # exceeds MAX_OPEN_ORDERS in this pool
        n_seed_makers = (depth + PER_MAKER - 1) // PER_MAKER
        for k in [1, 10, 30]:
            if depth < max(k, 2):
                continue
            d = self.taker_bid(pool, k)
            rec(f"taker_{k}", d)
            # restore consumed makers (unmeasured)
            re_prices = [MID + 1 + i for i in range(k)]
            newmap = self.seed(pool, re_prices, start_maker=n_seed_makers)
            idmap.update(newmap)

        print(f"[{name}] steady depth {depth} done ({time.time()-t0:.0f}s)", flush=True)

    def run_ceiling(self, batch=50, limit=6000):
        """A only: deepen one book until placement fails."""
        pool = self.new_pool()
        n = 0
        while n < limit:
            makers = self.ensure_makers(n // PER_MAKER + 2)
            acct = makers[n // PER_MAKER]
            chunk = min(batch, PER_MAKER - (n % PER_MAKER))
            prices = [MID + 1 + n + i for i in range(chunk)]
            cmds, pv = [], "pr"
            cmds += ["--move-call",
                     f"{self.s['pkg']}::trading_account::generate_proof_as_owner",
                     f"@{acct}", "--assign", pv]
            for p in prices:
                cmds += self.place_cmds(pool, acct, p, QTY, False, proof_var=pv)
            try:
                d = ptb(cmds, budget=BUDGET_BIG, retries=0)
            except RuntimeError as e:
                self.rec({"phase": "ceiling", "failed_at": n, "batch": chunk,
                          "err": str(e)[:300]})
                print(f"[{self.name}] ceiling: batch failed at depth {n}: {str(e)[:200]}")
                # bisect: try singles until failure
                while True:
                    try:
                        d = self.place_one(pool, acct, MID + 1 + n)
                        g = gas(d)
                        self.rec({"phase": "ceiling", "i": n, "op": "place", **g})
                        n += 1
                    except RuntimeError as e2:
                        self.rec({"phase": "ceiling", "failed_single_at": n,
                                  "err": str(e2)[:300]})
                        print(f"[{self.name}] ceiling located: {n} orders/side")
                        return n
                    if n % 25 == 0:
                        print(f"[{self.name}] ceiling probe {n}")
            g = gas(d)
            self.rec({"phase": "ceiling", "i": n, "batch": chunk, **g})
            n += chunk
            if n % 500 == 0:
                print(f"[{self.name}] ceiling {n} orders ({g['storageCost']} storage)",
                      flush=True)
        print(f"[{self.name}] ceiling not reached by {limit}")
        return None


def main():
    os.makedirs(RESULTS, exist_ok=True)
    cmd = sys.argv[1]
    if cmd == "shared":
        # record shared ids: token_pkg mc_pkg cred_coin collection ccap
        d = dict(zip(["token_pkg", "mc_pkg", "cred_coin", "collection", "ccap", "cred_meta"],
                     sys.argv[2:8]))
        json.dump(d, open(SHARED_F, "w"), indent=1)
        print("shared saved")
        return
    v = Variant(sys.argv[2])
    if cmd == "setup":
        v.setup(*sys.argv[3:7])
        if len(sys.argv) > 7 and sys.argv[7] == "u128":
            v.s["u128"] = True
            v.save()
    elif cmd == "construction":
        v.run_construction(int(sys.argv[3]) if len(sys.argv) > 3 else 300)
    elif cmd == "steady":
        depths = [int(x) for x in sys.argv[3].split(",")] if len(sys.argv) > 3 else None
        v.run_steady(depths)
    elif cmd == "ceiling":
        v.run_ceiling()
    elif cmd == "smoke":
        pool = v.new_pool()
        print("pool", pool)
        m = v.ensure_makers(1)[0]
        d = v.place_one(pool, m, MID + 5)
        print("place gas", gas(d))
        ev = placed_events(d, v.s["pkg"])
        print("events", ev)
        d = v.cancel_one(pool, m, ev[0][0])
        print("cancel gas", gas(d))
        d = v.place_one(pool, m, MID + 6)
        oid = placed_events(d, v.s["pkg"])[0][0]
        d = v.modify_one(pool, m, oid, 5)
        print("modify gas", gas(d))
        idmap = v.seed(pool, [MID + 10 + i for i in range(5)])
        print("seeded", len(idmap))
        d = v.taker_bid(pool, 2)
        print("taker gas", gas(d))
        print("SMOKE OK")


if __name__ == "__main__":
    main()
