#!/usr/bin/env bash
# Enforces CLAUDE.md invariants 69, 70 and 75 at the one place a text check cannot: each
# strategic-merge patch under keyryx/ applies to the object it names, and its unpatch takes
# that object back to exactly what the default install applies.
#
# WHY
#
# `--without-keyryx` and keyryx/down.sh rest on the unpatches. A strategic merge keys each
# list by its own merge key, and a delete that names the wrong key (a volumeMount by `name`
# where the key is `mountPath`) is refused by the API server, so nothing is reverted: the
# affinity, the mount and the setting all stay, and down.sh, which runs under `set -e`,
# stops there. Every other gate here reads text and would pass that.
#
# WHAT IT RUNS
#
# `kubectl patch --local` (no cluster, no kubeconfig) for each pair below, against the object
# as the default install renders it (`kubectl kustomize manifests/`, or the opt-in manifest
# that holds it), and requires: the patch applies and changes the object; the unpatch applies
# to the patched object; and the result equals the object before the patch. The wardryx
# patch's one placeholder is filled with a fixed date. Empty maps and nulls are dropped before
# the comparison (an emptied label map means no labels), as are empty lists; a list that holds
# anything is compared whole. It refuses to report OK with no
# kubectl, no object or no patch: "measured NOTHING".
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
if ! command -v kubectl >/dev/null 2>&1; then
	echo "keyryx-patches-round-trip: no kubectl on PATH, so this gate measured NOTHING"
	exit 1
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/keyryx-round-trip.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if ! KUBECONFIG=/dev/null kubectl kustomize manifests/ >"$work/default.yaml" 2>"$work/kustomize.err"; then
	echo "keyryx-patches-round-trip: kubectl kustomize manifests/ failed ($(tail -1 "$work/kustomize.err")), so this gate measured NOTHING"
	exit 1
fi
python3 - "$work" <<'PY'
import json, os, re, subprocess, sys

work = sys.argv[1]
# (source of the object, kind, name, patch, unpatch)
PAIRS = [
    ("default", "Deployment", "wardryx", "keyryx/wardryx-patch.yaml", "keyryx/wardryx-unpatch.yaml"),
    ("default", "CronJob", "record-seal", "keyryx/record-seal-patch.yaml", "keyryx/record-seal-unpatch.yaml"),
    ("default", "Deployment", "genaryx-console", "keyryx/console-findings-patch.yaml", "keyryx/console-findings-unpatch.yaml"),
    ("manifests/45-heraldyx.yaml", "Deployment", "heraldyx", "keyryx/heraldyx-findings-patch.yaml", "keyryx/heraldyx-findings-unpatch.yaml"),
]
FILL = {"@WARDRYX_APPROVAL_V2_UNTIL@": "2026-01-01T00:00:00Z"}


def nothing(msg):
    print(f"keyryx-patches-round-trip: {msg}, so this gate measured NOTHING")
    sys.exit(1)


def obj(source, kind, name):
    path = os.path.join(work, "default.yaml") if source == "default" else source
    if not os.path.exists(path):
        return None
    for d in re.split(r"\n---\s*\n", open(path).read()):
        if re.search(rf"^kind:\s*{kind}\s*$", d, re.M) and re.search(rf"^  name:\s*{re.escape(name)}\s*$", d, re.M):
            return d + "\n"
    return None


def patch(src_file, patch_file):
    r = subprocess.run(["kubectl", "patch", "--local", "-f", src_file, "--type", "strategic",
                        "--patch-file", patch_file, "-o", "json"],
                       capture_output=True, text=True, env=dict(os.environ, KUBECONFIG="/dev/null"))
    return r.returncode, r.stdout, (r.stderr.strip().splitlines() or ["?"])[-1]


def where(a, b, path=""):
    if a == b:
        return None
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            w = where(a.get(k), b.get(k), path + "." + k)
            if w:
                return w
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            w = where(x, y, f"{path}[{i}]")
            if w:
                return w
    return f"{path}: {json.dumps(a)[:100]} became {json.dumps(b)[:100]}"


def pruned(o):
    """Drop empty maps, empty lists and nulls: an unpatch that deletes the last label leaves
    `labels: {}`, and one that deletes the last variable leaves `env: []`, which Kubernetes reads
    as none. A list that still holds anything is compared whole, so a mount left behind counts."""
    if isinstance(o, dict):
        out = {k: pruned(v) for k, v in o.items()}
        return {k: v for k, v in out.items() if v not in (None, {}, [])}
    if isinstance(o, list):
        return [pruned(x) for x in o]
    return o


noop = os.path.join(work, "noop.json")
open(noop, "w").write("{}\n")
bad = []
for source, kind, name, p, u in PAIRS:
    for f in (p, u):
        if not os.path.exists(f):
            nothing(f"{f} is absent")
    text = obj(source, kind, name)
    if text is None:
        nothing(f"no {kind} {name} in {source}")
    base_f = os.path.join(work, f"{name}.yaml")
    open(base_f, "w").write(text)
    pf = os.path.join(work, f"{name}.patch.yaml")
    body = open(p).read()
    for k, v in FILL.items():
        body = body.replace(k, v)
    open(pf, "w").write(body)
    rc, base, err = patch(base_f, noop)
    if rc != 0:
        bad.append(f"{kind} {name}: the object as the install renders it does not read ({err})")
        continue
    rc, patched, err = patch(base_f, pf)
    if rc != 0:
        bad.append(f"{p}: does not apply to {kind} {name}: {err}")
        continue
    if pruned(json.loads(patched)) == pruned(json.loads(base)):
        bad.append(f"{p}: applies to {kind} {name} and changes nothing")
        continue
    pj = os.path.join(work, f"{name}.patched.json")
    open(pj, "w").write(patched)
    rc, back, err = patch(pj, u)
    if rc != 0:
        bad.append(f"{u}: refused on the patched {kind} {name}, so it reverts nothing: {err}")
        continue
    w = where(pruned(json.loads(base)), pruned(json.loads(back)))
    if w:
        bad.append(f"{u}: does not take {kind} {name} back to what the default install applies: {w}")

if bad:
    for b in bad:
        print("FAIL keyryx-patches-round-trip: " + b)
    sys.exit(1)
print(f"OK: {len(PAIRS)} Keyryx patches apply to their objects, and each unpatch takes its object back exactly")
PY
