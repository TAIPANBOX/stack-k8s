#!/usr/bin/env bash
# Enforces invariant 22 in CLAUDE.md: every installer that installs Longhorn
# sets its node-down-pod-deletion-policy to
# delete-both-statefulset-and-deployment-pod, after the install.
#
# WHY
#
# A pod on a node that dies holds its Longhorn volume until that node comes
# back. Evicted, it sits Terminating on the dead node; a StatefulSet or a
# Recreate Deployment does not start its replacement until the old pod is
# confirmed gone, and a dead node confirms nothing. Longhorn ships
# `do-nothing` for this case. Measured on GCP 2026-09-26 (N2/G1, policy-db's
# VM stopped): as shipped, the policy store was down until the VM returned;
# with this setting alone, about 400 s; with it and the manifests' 30 s
# tolerations (invariant 21), about 150 s. GOTCHAS 109.
#
# The trap this gate exists for is the one this repository has hit three times
# (GOTCHAS 90, 101, 102): a block copied into three installers, then changed in
# one or two of them.
#
# WHAT IS A SUBJECT
#
# A tracked shell script outside scripts/ with a non-comment line that applies
# Longhorn's own deploy/longhorn.yaml. Found, not listed: a fourth cloud is a
# subject the day it lands. For each, a non-comment line AFTER that apply must
# patch settings.longhorn.io node-down-pod-deletion-policy to the value above.
# No subject at all is a failure that says it measured nothing.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
import subprocess
import sys

VALUE = "delete-both-statefulset-and-deployment-pod"
files = [f for f in subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True,
                                   check=True).stdout.split() if not f.startswith("scripts/")]
subjects = 0
failures = []
for f in files:
    lines = open(f).read().split("\n")
    live = [(i, l) for i, l in enumerate(lines) if not l.lstrip().startswith("#")]
    applies = [i for i, l in live
               if "apply" in l and "longhorn/longhorn/" in l and "deploy/longhorn.yaml" in l]
    if not applies:
        continue
    subjects += 1
    first = applies[0]
    patches = [(i, l) for i, l in live if "node-down-pod-deletion-policy" in l and "patch" in l]
    after = [(i, l) for i, l in patches if i > first]
    if not patches:
        failures.append(f"{f}:{first + 1} installs Longhorn and never sets node-down-pod-deletion-policy, "
                        f"so a volume on a dead node stays held until the node returns")
    elif not after:
        failures.append(f"{f}:{patches[0][0] + 1} sets node-down-pod-deletion-policy BEFORE Longhorn is "
                        f"applied at line {first + 1}, where the setting does not exist yet")
    elif not any(VALUE in l for _, l in after):
        bad = after[0][1].strip()[:120]
        failures.append(f"{f}:{after[0][0] + 1} sets node-down-pod-deletion-policy, but not to {VALUE}: {bad}")

if subjects == 0:
    print("FAIL: no tracked script outside scripts/ applies Longhorn's deploy/longhorn.yaml.")
    print("      That is not health: the installers moved, or this check no longer knows")
    print("      how to find them. This measured nothing, and it is not entitled to say OK.")
    sys.exit(1)
for msg in failures:
    print(f"FAIL: {msg}")
if failures:
    print()
    print(f"{len(failures)} of {subjects} Longhorn installer(s) leave a dead node's volumes held.")
    sys.exit(1)
print(f"OK: {subjects} installer(s) apply Longhorn, each setting node-down-pod-deletion-policy="
      f"{VALUE} after it.")
PY
