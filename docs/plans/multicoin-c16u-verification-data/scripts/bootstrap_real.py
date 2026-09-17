#!/usr/bin/env python3
"""Bootstrap one localnet against the *real* triex package (no variants dir).

Publishes token + multicoin + triex, creates the multicoin Collection, and
writes results/shared.json plus results/<name>.state.json for driver.py.
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "pkg")
RESULTS = os.path.join(ROOT, "results")
NAME = sys.argv[1] if len(sys.argv) > 1 else "mcC16u"


def run(args, cwd=None):
    o = subprocess.run(args, capture_output=True, text=True, cwd=cwd)
    t = o.stdout.strip()
    i = t.find("{")
    if i < 0:
        raise RuntimeError(f"no json: {(o.stderr or t)[:2000]}")
    d = json.loads(t[i:])
    st = d.get("effects", {}).get("status", {})
    if st.get("status") != "success":
        raise RuntimeError(f"failed: {json.dumps(st)[:600]}")
    return d


def publish(pkgdir):
    # `sui client publish` refuses a package that already carries a publication
    # entry for this env, so bootstrap is made re-runnable by clearing it first.
    pub = os.path.join(pkgdir, "Published.toml")
    if os.path.exists(pub):
        os.remove(pub)
    d = run(["sui", "client", "publish", "--gas-budget", "5000000000",
             "--skip-dependency-verification", "--json"], cwd=pkgdir)
    pkg = None
    for c in d.get("objectChanges", []):
        if c.get("type") == "published":
            pkg = c["packageId"]
    return pkg, d


def created_exact(d, t):
    return [c["objectId"] for c in d.get("objectChanges", [])
            if c.get("type") == "created" and c.get("objectType") == t]


def created_sub(d, needle):
    return [c["objectId"] for c in d.get("objectChanges", [])
            if c.get("type") == "created" and needle in c.get("objectType", "")]


def ptb(cmds, budget="5000000000"):
    return run(["sui", "client", "ptb"] + cmds + ["--gas-budget", budget, "--json"])


def main():
    os.makedirs(RESULTS, exist_ok=True)

    token_pkg, d = publish(os.path.join(PKG, "token"))
    cred_coin = created_sub(d, "::coin::Coin<")[0]
    cred_meta = created_sub(d, "::coin::CoinMetadata<")[0]
    print("token", token_pkg, flush=True)

    mc_pkg, d = publish(os.path.join(PKG, "multicoin"))
    print("multicoin", mc_pkg, flush=True)

    d = ptb(["--move-call", f"{mc_pkg}::multicoin::create_collection"])
    # exact, not substring: "::multicoin::Collection" also matches CollectionCap
    collection = created_exact(d, f"{mc_pkg}::multicoin::Collection")[0]
    ccap = created_exact(d, f"{mc_pkg}::multicoin::CollectionCap")[0]
    print("collection", collection, ccap, flush=True)

    json.dump(dict(token_pkg=token_pkg, mc_pkg=mc_pkg, cred_coin=cred_coin,
                   collection=collection, ccap=ccap, cred_meta=cred_meta),
              open(os.path.join(RESULTS, "shared.json"), "w"), indent=1)

    pkg, d = publish(os.path.join(PKG, "triex"))
    # exact match: the versioned wrapper's *Inner child is created in the same tx
    registry = created_exact(d, f"{pkg}::registry::Registry")[0]
    policy = created_exact(d, f"{pkg}::fee_policy::FeePolicy")[0]
    admincap = created_exact(d, f"{pkg}::registry::TriexAdminCap")[0]
    print(f"triex pkg={pkg} reg={registry} pol={policy} cap={admincap}", flush=True)

    json.dump(dict(pkg=pkg, registry=registry, policy=policy, admincap=admincap,
                   accounts=[], taker=None, u128=True),
              open(os.path.join(RESULTS, f"{NAME}.state.json"), "w"), indent=1)
    print("BOOTSTRAP OK")


if __name__ == "__main__":
    main()
