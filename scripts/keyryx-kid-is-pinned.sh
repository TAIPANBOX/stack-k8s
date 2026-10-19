#!/usr/bin/env bash
# CLAUDE.md invariant 73. trailryx-node v1.5.0 signs under the one Keyryx key its deployment names by the RFC 7638
# thumbprint (TRAILRYX_KEYRYX_KID, the `kid` custody publishes for it). The launcher takes that kid from custody's own
# key set once custody is up, pins it for the record seal, keeps the pin on a re-run, and changes it only when the
# operator names the successor on purpose (KEYRYX_ROTATE_KID). Nothing about the key but its kid is printed.
#
# WHAT THIS CHECKS
#
#   1. keyryx/policy.json.tmpl: trailryx-root is an ES384 key, the only algorithm trailryx-node takes (P-384).
#   2. lib/keyryx-install.sh: keyryx_pin_trailryx_kid exists, keyryx_install_settle runs it before the record-seal
#      patch, and TODO(trailryx-kid) is gone.
#   3. keyryx/record-seal-patch.yaml: TRAILRYX_KEYRYX_KID is read from the stack-wiring ConfigMap, not optional, and
#      never a literal in the patch.
#   4. Behaviour, with a stub kubectl and fixed key sets, through the library's own function:
#        one ES384 key, first install             pins it
#        two ES384 keys, first install            refused: more than one
#        no ES384 key                             refused
#        the pin is in the set, on a re-run       kept, nothing written
#        the pin is no longer in the set          refused, naming KEYRYX_ROTATE_KID
#        KEYRYX_ROTATE_KID names a successor      re-pinned to it
#        KEYRYX_ROTATE_KID names no ES384 key     refused
#        the probe pod fails                      refused
#        a kid that is not a thumbprint           refused
#      In every case the output must not contain a coordinate of the key.
#
# An absent subject is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

GATE_ROOT="$(pwd)" TMP_DIR="$tmp" python3 - <<'PY'
import json
import os
import re
import subprocess
import sys

ROOT = os.environ["GATE_ROOT"]
TMP = os.environ["TMP_DIR"]
bad = []


def read(path):
    try:
        return open(os.path.join(ROOT, path)).read()
    except OSError:
        return None


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


lib = read("lib/keyryx-install.sh")
policy = read("keyryx/policy.json.tmpl")
patch = read("keyryx/record-seal-patch.yaml")
if lib is None:
    print("FAIL lib/keyryx-install.sh is absent: the trailryx pin is measured NOTHING")
    sys.exit(1)
if policy is None:
    print("FAIL keyryx/policy.json.tmpl is absent: the trailryx-root algorithm is measured NOTHING")
    sys.exit(1)
if patch is None:
    print("FAIL keyryx/record-seal-patch.yaml is absent: the record seal's pin is measured NOTHING")
    sys.exit(1)

# 1. The custody key the record seal signs under is P-384.
if not re.search(r'\{"name": "trailryx-root", "alg": "ES384"\}', policy):
    bad.append("keyryx/policy.json.tmpl does not declare trailryx-root as ES384: trailryx-node takes only a P-384 key")

# 2. The pin is taken before the record seal is patched, and the TODO is gone.
if "keyryx_pin_trailryx_kid()" not in lib:
    bad.append("lib/keyryx-install.sh defines no keyryx_pin_trailryx_kid")
m = re.search(r"keyryx_install_settle\(\) \{\n(.*?)\n\}", lib, re.S)
if m is None:
    bad.append("lib/keyryx-install.sh has no keyryx_install_settle to order the pin in")
else:
    body = m.group(1)
    pin_at = body.find("keyryx_pin_trailryx_kid")
    seal_at = body.find("keyryx_patch_record_seal")
    if pin_at < 0:
        bad.append("keyryx_install_settle does not call keyryx_pin_trailryx_kid")
    elif seal_at >= 0 and pin_at > seal_at:
        bad.append("keyryx_install_settle patches the record seal before it pins the kid")
if "TODO(trailryx-kid)" in lib:
    bad.append("lib/keyryx-install.sh still carries TODO(trailryx-kid): the pin is in, so the TODO is stale")

# 3. The record seal reads the pin from the ConfigMap, not from a literal.
envm = re.search(r"- name: TRAILRYX_KEYRYX_KID\n\s+valueFrom: \{ ?configMapKeyRef: \{ ?name: stack-wiring, key: TRAILRYX_KEYRYX_KID(, optional: false)? ?\} ?\}", patch)
if envm is None:
    bad.append("keyryx/record-seal-patch.yaml does not read TRAILRYX_KEYRYX_KID from the stack-wiring ConfigMap, not optional")
if re.search(r"TRAILRYX_KEYRYX_KID[^\n]*value:", live(patch)):
    bad.append("keyryx/record-seal-patch.yaml sets TRAILRYX_KEYRYX_KID as a literal: the kid is a deploy-time fact")

# 4. Behaviour, through the library's own function, against a stub kubectl.
KID1 = "K" * 43
KID2 = "L" * 43
KIDX = "M" * 43
KIDBAD = "short"
MARK = "MARKERX" + "a" * 57


def key(kid, crv="P-384"):
    alg = "ES384" if crv == "P-384" else "ES256"
    return {"kty": "EC", "crv": crv, "alg": alg, "kid": kid, "x": MARK, "y": "b" * 64, "use": "sig"}


SNIP = r'''
set -u
ROOT="$GATE_ROOT"
die() { echo "refused: $*" >&2; exit 3; }
k_() {
  case "$1" in
    *"get configmap stack-wiring"*) printf '%s' "$STUB_PIN" ;;
    *"delete pod keyryx-jwks-probe"*) : ;;
    *"create -f -"*) cat > "$STUB_OUT/probe.yaml" ;;
    *"get pod keyryx-jwks-probe"*) printf '%s' "$STUB_PHASE" ;;
    *"logs keyryx-jwks-probe"*) cat "$STUB_OUT/jwks.json" ;;
    *"patch configmap stack-wiring"*) cat > "$STUB_OUT/patch.json" ;;
    *) echo "UNEXPECTED kubectl call: $1" >&2; exit 9 ;;
  esac
}
. "$GATE_ROOT/lib/keyryx-install.sh"
keyryx_pin_trailryx_kid
'''

CASES = [
    ("pins the one ES384 key on a first install", [key(KID1)], "", None, "Succeeded", "pinned", KID1, None),
    ("refuses two ES384 keys on a first install", [key(KID1), key(KID2)], "", None, "Succeeded", "refused", None, "more than one"),
    ("refuses a key set with no ES384 key", [key(KID1, "P-256")], "", None, "Succeeded", "refused", None, "no ES384 key"),
    ("keeps the pin on a re-run when it is still in the set", [key(KID1), key(KID2)], KID2, None, "Succeeded", "kept", None, None),
    ("refuses a pin the set no longer holds", [key(KID1)], KID2, None, "Succeeded", "refused", None, "KEYRYX_ROTATE_KID"),
    ("re-pins on purpose to the named successor", [key(KID1), key(KID2)], KID1, KID2, "Succeeded", "pinned", KID2, None),
    ("refuses a rotation to a kid the set does not hold", [key(KID1)], KID1, KIDX, "Succeeded", "refused", None, "names no ES384 key"),
    ("refuses when the probe pod fails", [key(KID1)], "", None, "Failed", "refused", None, "probe"),
    ("refuses a kid that is not a thumbprint", [key(KIDBAD)], "", None, "Succeeded", "refused", None, "43-character"),
]

for n, (name, keys, pin, rot, phase, expect, kid, needle) in enumerate(CASES):
    d = os.path.join(TMP, f"case{n}")
    os.makedirs(d)
    with open(os.path.join(d, "jwks.json"), "w") as f:
        json.dump({"keys": keys}, f)
    env = {"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", TMP), "GATE_ROOT": ROOT,
           "STUB_PIN": pin, "STUB_PHASE": phase, "STUB_OUT": d}
    if rot:
        env["KEYRYX_ROTATE_KID"] = rot
    p = subprocess.run(["bash", "-c", SNIP], env=env, capture_output=True, text=True, timeout=60)
    out = p.stdout + p.stderr
    patched = os.path.join(d, "patch.json")
    if MARK in out:
        bad.append(f"{name}: the output carries a coordinate of the key")
    if expect == "pinned":
        if p.returncode != 0:
            bad.append(f"{name}: exited {p.returncode}: {out.strip()[:200]}")
        elif not os.path.exists(patched):
            bad.append(f"{name}: no patch wrote the pin")
        else:
            got = json.load(open(patched)).get("data", {}).get("TRAILRYX_KEYRYX_KID")
            if got != kid:
                bad.append(f"{name}: pinned {got!r}, want {kid!r}")
    elif expect == "kept":
        if p.returncode != 0:
            bad.append(f"{name}: exited {p.returncode}: {out.strip()[:200]}")
        if os.path.exists(patched):
            bad.append(f"{name}: a re-run rewrote a pin it should have kept")
    else:
        if p.returncode == 0:
            bad.append(f"{name}: accepted a key set it must refuse")
        if os.path.exists(patched):
            bad.append(f"{name}: wrote a pin before refusing")
        if needle and needle not in out:
            bad.append(f"{name}: refused without saying why (wanted {needle!r}): {out.strip()[:200]}")
    if expect == "pinned" and n == 0:
        probe = open(os.path.join(d, "probe.yaml")).read() if os.path.exists(os.path.join(d, "probe.yaml")) else ""
        for want in ("keyryx-consumer: \"true\"", "runAsNonRoot: true", "/v1/jwks/trailryx-root", "automountServiceAccountToken: false"):
            if want not in probe:
                bad.append(f"the probe pod does not carry {want!r}")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 73.")
    sys.exit(1)
print("OK: the record seal is pinned to the one ES384 key custody publishes, kept on a re-run, re-pinned only on a named rotation, refused with a reason when the key set cannot give one, and no coordinate of the key is printed.")
PY
