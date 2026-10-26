#!/usr/bin/env bash
# CLAUDE.md invariant 72. The Keyryx custody and witness run one release of keyryx, pinned by tag and digest, and
# the record seal runs the trailryx-node release that pins Keyryx's key by its thumbprint (invariant 73). A tag and
# its digest are pinned together, and the custody and the witness are the same image.
#
# WHAT THIS CHECKS
#
#   1. keyryx/manifests/59-keyryx.yaml: every keyryx image is the release pin below, custody and witness alike.
#   2. manifests/40-routines-and-secrets.yaml: the record-seal's trailryx-node is the release pin below.
#
# The release pins are held here so that moving a pin is a visible edit to this gate and to the manifest together.
# An absent subject is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
import sys

PINS = {
    "keyryx": ("v0.1.3", "sha256:26d5d49cd4a67eb463f35895de96e628e2304183775bf031170e190c579c0147"),
    "trailryx-node": ("v1.5.0", "sha256:f15215cd9708724e83fbd8493f2bf7d2a11980b37edf3b887081d8e17da18bab"),
}
bad = []


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


def images(path, name):
    try:
        text = open(path).read()
    except OSError:
        print(f"FAIL {path} is absent: the {name} pin is measured NOTHING")
        sys.exit(1)
    found = re.findall(r"image: ghcr\.io/taipanbox/%s:([^@\s]+)@(sha256:[0-9a-f]{64})" % re.escape(name), live(text))
    if not found:
        print(f"FAIL {path} names no {name} image: the pin is measured NOTHING")
        sys.exit(1)
    return found


for tag, dig in images("keyryx/manifests/59-keyryx.yaml", "keyryx"):
    if (tag, dig) != PINS["keyryx"]:
        bad.append(f"keyryx/manifests/59-keyryx.yaml: a keyryx image is {tag}@{dig}, which is not the release pin "
                   f"{PINS['keyryx'][0]}@{PINS['keyryx'][1]}")
for tag, dig in images("manifests/40-routines-and-secrets.yaml", "trailryx-node"):
    if (tag, dig) != PINS["trailryx-node"]:
        bad.append(f"manifests/40-routines-and-secrets.yaml: the record-seal's trailryx-node is {tag}@{dig}, which is not "
                   f"the release pin {PINS['trailryx-node'][0]}@{PINS['trailryx-node'][1]}")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 72.")
    sys.exit(1)
print("OK: custody, the witness and the record seal run the release pins: keyryx v0.1.3 and trailryx-node v1.5.0, each by tag and digest.")
PY
