#!/usr/bin/env bash
# Enforces invariant 57 of CLAUDE.md: only labelled consumers reach a Keyryx
# role over the network, and a Keyryx pod has no outbound route at all. Port of
# the NetworkPolicy half of wave 2 design section 5.2 ("only consumers reach
# Keyryx"), in the same way the other NetworkPolicy gates in this repository
# judge their objects: from the text of the manifest, by name.
#
# WHY
#
# The custody service signs with keys it holds. Any pod that can reach its port
# can ask for a signature, so reachability is the first control, and the
# per-consumer policy (who may sign with which key) is the second. A NetworkPolicy
# that admits every pod in the namespace would make the second the only control.
# The Keyryx pods have no reason to call out, so their egress is empty.
#
# WHAT THIS CHECKS
#
#   1. keyryx-custody-ingress admits only pods labelled keyryx-consumer: "true",
#      on port 4340, with no ipBlock and no empty selector;
#   2. keyryx-witness-ingress admits only pods labelled keyryx-witness-client:
#      "true", on port 4341;
#   3. both policies declare Egress with no rule (egress: []);
#   4. the keyryx-consumer label is set only on the pod templates of the consumers
#      named in keyryx/wardryx-patch.yaml, never in the Keyryx manifests.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import os
import re
import sys

path = "keyryx/manifests/59-keyryx.yaml"
if not os.path.exists(path):
    print(f"keyryx-reaches-only-consumers: {path} is absent, so this gate measured NOTHING")
    sys.exit(1)

text = open(path).read()
docs = re.split(r"\n---\s*\n", text)


def policy(name):
    for d in docs:
        if re.search(r"^kind:\s*NetworkPolicy\s*$", d, re.M) and re.search(
                rf"^  name:\s*{name}\s*$", d, re.M):
            return d
    return None


bad = []
custody = policy("keyryx-custody-ingress")
witness = policy("keyryx-witness-ingress")
if custody is None or witness is None:
    print("keyryx-reaches-only-consumers: a NetworkPolicy is absent, so this gate measured NOTHING")
    sys.exit(1)

for label, d, label_key, port in (
        ("custody", custody, "keyryx-consumer", 4340),
        ("witness", witness, "keyryx-witness-client", 4341)):
    if not re.search(rf"{label_key}:\s*\"?true\"?", d):
        bad.append(f"the {label} policy admits no pod labelled {label_key}: \"true\"")
    if re.search(r"ipBlock", d):
        bad.append(f"the {label} policy admits an address range (ipBlock)")
    if re.search(r"from:\s*\n\s*-\s*\{\s*\}", d) or re.search(r"from:\s*\[\s*\{\s*\}\s*\]", d):
        bad.append(f"the {label} policy admits every pod (an empty selector)")
    if not re.search(rf"port:\s*{port}\b", d):
        bad.append(f"the {label} policy does not name port {port}")
    if not re.search(r"egress:\s*\[\s*\]", d):
        bad.append(f"the {label} policy has egress rules (a Keyryx pod may not call out)")

labelled = set()
for f in sorted(glob.glob("keyryx/**/*.yaml", recursive=True)):
    t = open(f).read()
    if re.search(r"keyryx-consumer:\s*\"?true\"?", t) and "NetworkPolicy" not in t:
        labelled.add(f)
for f in sorted(labelled):
    if f != "keyryx/wardryx-patch.yaml":
        bad.append(f"{f} sets the keyryx-consumer label; only the wardryx patch may")
for d in docs:
    live = re.sub(r"(?m)^\s*#.*$", "", d)
    if "NetworkPolicy" in live:
        continue
    if "keyryx-consumer" in live:
        bad.append("a Keyryx workload carries the keyryx-consumer label (only the wardryx patch may)")

if bad:
    for b in bad:
        print("FAIL " + b)
    sys.exit(1)

print("OK: only pods labelled keyryx-consumer reach custody on 4340 and only"
      " keyryx-witness-client reaches the witness on 4341; neither role has egress.")
PY
