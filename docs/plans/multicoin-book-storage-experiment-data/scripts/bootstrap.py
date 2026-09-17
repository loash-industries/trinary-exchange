#!/usr/bin/env python3
"""Re-bootstrap the localnet: publish shared token/multicoin, then one triex per variant."""
import json, os, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VAR = os.path.join(ROOT, "variants")
RESULTS = os.path.join(ROOT, "results")
SHARED_F = os.path.join(RESULTS, "shared.json")

VARIANTS = {"A": "base", "B": "B", "C16u": "C16u", "D64u": "D64u"}
U128 = {"B", "C16u", "D64u"}


def run(args, cwd=None):
    o = subprocess.run(args, capture_output=True, text=True, cwd=cwd)
    t = o.stdout.strip()
    i = t.find("{")
    if i < 0:
        raise RuntimeError(f"no json: {(o.stderr or t)[:1500]}")
    d = json.loads(t[i:])
    st = d.get("effects", {}).get("status", {})
    if st.get("status") != "success":
        raise RuntimeError(f"failed: {json.dumps(st)[:600]}")
    return d


def publish(pkgdir):
    d = run(["sui", "client", "publish", "--gas-budget", "5000000000",
             "--skip-dependency-verification", "--json"], cwd=pkgdir)
    pkg = None
    for c in d.get("objectChanges", []):
        if c.get("type") == "published":
            pkg = c["packageId"]
    return pkg, d


def created(d, needle):
    out = []
    for c in d.get("objectChanges", []):
        if c.get("type") == "created" and needle in c.get("objectType", ""):
            out.append(c["objectId"])
    return out


def ptb(cmds, budget="5000000000"):
    return run(["sui", "client", "ptb"] + cmds + ["--gas-budget", budget, "--json"])


def main():
    os.makedirs(RESULTS, exist_ok=True)
    base = os.path.join(VAR, "base")

    token_pkg, d = publish(os.path.join(base, "token"))
    cred_coin = created(d, "::coin::Coin<")[0]
    cred_meta = created(d, "::coin::CoinMetadata<")[0]
    print("token", token_pkg, cred_coin, cred_meta, flush=True)

    mc_pkg, d = publish(os.path.join(base, "multicoin"))
    print("multicoin", mc_pkg, flush=True)

    d = ptb(["--move-call", f"{mc_pkg}::multicoin::create_collection"])
    collection = created(d, "::multicoin::Collection")[0]
    ccap = created(d, "::multicoin::CollectionCap")[0]
    print("collection", collection, ccap, flush=True)

    shared = dict(token_pkg=token_pkg, mc_pkg=mc_pkg, cred_coin=cred_coin,
                  collection=collection, ccap=ccap, cred_meta=cred_meta)
    json.dump(shared, open(SHARED_F, "w"), indent=1)

    # propagate the two shared Published.toml files to every variant dir
    for name, sub in VARIANTS.items():
        for dep in ("token", "multicoin"):
            src = os.path.join(base, dep, "Published.toml")
            dst = os.path.join(VAR, sub, dep, "Published.toml")
            if os.path.abspath(src) != os.path.abspath(dst):
                shutil.copyfile(src, dst)

    for name, sub in VARIANTS.items():
        pkg, d = publish(os.path.join(VAR, sub, "triex"))
        registry = created(d, "::registry::Registry")[0]
        policy = created(d, "::fee_policy::")[0]
        admincap = created(d, "::registry::TriexAdminCap")[0]
        print(f"{name}: pkg={pkg} reg={registry} pol={policy} cap={admincap}", flush=True)
        stf = os.path.join(RESULTS, f"{name}.state.json")
        s = {}
        s.update(pkg=pkg, registry=registry, policy=policy, admincap=admincap,
                 accounts=[], taker=None)
        if name in U128:
            s["u128"] = True
        json.dump(s, open(stf, "w"), indent=1)

    print("BOOTSTRAP PUBLISHED OK")


if __name__ == "__main__":
    main()
