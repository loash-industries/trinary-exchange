#!/usr/bin/env bash
#
# Check that only the admin can ever write `FeePolicy` (TRIEX-149).
#
# Every order on every pool reads the shared `FeePolicy`. If any function a
# user can call took it `&mut`, any sender could serialize every trade on the
# exchange behind their own transaction. The rule this enforces:
#
#   - a non-test function a transaction can call — any `public fun`, and any
#     `entry fun` whatever its visibility — that takes `&mut FeePolicy` must
#     also take `&TriexAdminCap`;
#   - any other `public(package)` or private `fun` that takes `&mut FeePolicy`
#     must only ever be called from functions that satisfy the same rule.
#
# The types are matched however they are written: bare, path-qualified
# (`fee_policy::FeePolicy`, `triex::fee_policy::FeePolicy`) or renamed with
# `use ... FeePolicy as X`. A qualified cap only counts if its path names the
# `registry` module that defines it.
#
# It reads the Move sources of the triex package and of every package next to
# it that depends on it (today, triex_hub_operator_adapter). Exits non-zero and
# names each offending function if the rule is broken.
#
# What this cannot check: Sui lets a transaction declare any shared input
# mutable, even one it only passes to functions taking `&FeePolicy` (or to any
# package's generic `fun f<T: key>(x: &mut T)`). That is a property of the
# chain, not of these sources; see the `fee_policy` module docs. It is also a
# source scan, not a type checker: it reads declarations and call sites by
# pattern, so treat a pass as a strong check, not a proof.
#
# Usage: ./build_scripts/check-fee-policy-writers.sh [packages-dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_DIR="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

exec python3 - "$PACKAGES_DIR" <<'PY'
import os, re, sys

packages_dir = sys.argv[1]
sources = []
for pkg in sorted(os.listdir(packages_dir)):
    src = os.path.join(packages_dir, pkg, 'sources')
    if not os.path.isdir(src):
        continue
    for root, _, files in os.walk(src):
        for name in files:
            if name.endswith('.move'):
                sources.append(os.path.join(root, name))

def strip_comments(text):
    # Line comments only: Move has no block comments in these sources, and
    # doc comments are line comments too. Keep the newlines so offsets match.
    return re.sub(r'//[^\n]*', lambda m: ' ' * len(m.group(0)), text)

HEADER = re.compile(
    r'(?P<attrs>(?:#\[[^\]]*\]\s*)*)'
    r'(?P<entry1>entry\s+)?'
    r'(?P<vis>public\s*\(\s*package\s*\)\s*|public\s+)?(?P<entry2>entry\s+)?'
    r'fun\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>{]*>)?\s*\(',
)

def aliases(text, name):
    # `use ... Name as Alias`, in any of its forms (plain, braced, nested).
    return sorted(set(re.findall(r'\b' + name + r'\s+as\s+([A-Za-z_][A-Za-z0-9_]*)', text)))

functions = []  # (file, name, vis, entry, params, body_start, body_end, test_only)
for path in sources:
    text = strip_comments(open(path).read())
    policy_names = ['FeePolicy'] + aliases(text, 'FeePolicy')
    cap_names = ['TriexAdminCap'] + aliases(text, 'TriexAdminCap')
    writes = re.compile(
        r'&\s*mut\s+(?:[A-Za-z_][A-Za-z0-9_]*::)*(?:' + '|'.join(policy_names) + r')\b')
    takes_cap = re.compile(
        r'&\s*(?:mut\s+)?(?:(?:[A-Za-z_][A-Za-z0-9_]*::)*registry::)?(?:'
        + '|'.join(cap_names) + r')\b')
    for m in HEADER.finditer(text):
        # parameters: match the parenthesis opened at the end of the header
        i, depth = m.end(), 1
        while depth:
            depth += {'(': 1, ')': -1}.get(text[i], 0)
            i += 1
        params = text[m.end():i - 1]
        brace = text.index('{', i)
        j, depth = brace + 1, 1
        while depth:
            depth += {'{': 1, '}': -1}.get(text[j], 0)
            j += 1
        vis = (m.group('vis') or '').replace(' ', '')
        functions.append({
            'file': os.path.relpath(path, packages_dir),
            'name': m.group('name'),
            'vis': 'public' if vis == 'public' else ('package' if vis else 'private'),
            'entry': bool(m.group('entry1') or m.group('entry2')),
            'params': params,
            'writes': writes,
            'takes_cap': takes_cap,
            'body': (brace, j),
            'test_only': 'test_only' in m.group('attrs') or '#[test]' in m.group('attrs'),
            'text': text,
        })

def writes_policy(f):
    return f['writes'].search(f['params']) is not None

def has_cap(f):
    return f['takes_cap'].search(f['params']) is not None

def external(f):
    # Callable from a transaction: `public`, or `entry` at any visibility.
    return f['vis'] == 'public' or f['entry']

def callers(target):
    found = []
    call = re.compile(r'(?:\.|::|\b)' + re.escape(target['name']) + r'\s*(?:<[^>()]*>)?\s*\(')
    for f in functions:
        if f is target or f['test_only']:
            continue
        lo, hi = f['body']
        if call.search(f['text'][lo:hi]):
            found.append(f)
    return found

memo = {}
def admin_only(f, stack=()):
    key = (f['file'], f['name'])
    if key in memo:
        return memo[key]
    if key in stack:
        return True  # recursion: decided by the other callers
    if external(f):
        ok = has_cap(f)
    else:
        cs = callers(f)
        ok = all(has_cap(c) or (not external(c) and admin_only(c, stack + (key,))) for c in cs)
    memo[key] = ok
    return ok

writers = [f for f in functions if writes_policy(f) and not f['test_only']]
bad = []
for f in writers:
    ok = admin_only(f)
    how = 'takes &TriexAdminCap' if external(f) and ok else (
        'called only from admin functions' if ok else 'REACHABLE WITHOUT THE ADMIN CAP')
    kind = f['vis'] + (' entry' if f['entry'] else '')
    print(f"{'ok ' if ok else 'BAD'}  {f['file']}: {kind} fun {f['name']} — {how}")
    if not ok:
        bad.append(f)

if not writers:
    print('error: found no function taking &mut FeePolicy; is the packages dir right?', file=sys.stderr)
    sys.exit(2)
if bad:
    print(f'\n{len(bad)} function(s) let a non-admin take &mut FeePolicy.', file=sys.stderr)
    sys.exit(1)
print(f'\nAll {len(writers)} writers of FeePolicy are admin-only.')
PY
