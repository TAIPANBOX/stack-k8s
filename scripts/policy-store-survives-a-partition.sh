#!/usr/bin/env bash
# Enforces invariant 43 in CLAUDE.md: the policy store's volume is bound to the
# `stack-policy` StorageClass, every installer that installs Longhorn creates
# that class with the parameters below, and no installer turns Longhorn's
# automatic salvage off.
#
# WHY
#
# policy-db is the only durable store of wardryx's approvals and freezes
# (GOTCHAS 14). On 2026-10-14 (GCP, stack-k8s v1.1.44) a two-minute network cut
# of the node that held its engine left every replica of its volume in error:
# the volume had no backend, the kubelet's format step then ran against a device
# it could not read, and Postgres refused to start afterwards (GOTCHAS 127).
# The class below is the part of the fix that Longhorn's default class does not
# give: a replica on the workload's node (dataLocality best-effort) so the
# engine keeps one healthy replica when the other nodes are unreachable, the
# revision counter on (disableRevisionCounter false) so a salvage picks the
# replica with the newest data rather than a heuristic, a failed replica kept
# for 48 h (staleReplicaTimeout 2880) so it can be salvaged or reused, and
# Retain so deleting the claim does not delete the data.
#
# The trap this gate exists for is the one GOTCHAS 90, 101 and 102 record: a
# block copied into three installers and then changed in one of them.
#
# WHAT IS A SUBJECT
#
# A. manifests/15-policy-store.yaml: the policy-db StatefulSet's
#    volumeClaimTemplates names storageClassName `stack-policy`. Without it the
#    claim takes whichever class is the default, which is Longhorn's `longhorn`.
#
# B. Every tracked shell script outside scripts/ that applies Longhorn's
#    deploy/longhorn.yaml (the same discovery as longhorn-releases-a-dead-node.sh).
#    Each must write a StorageClass named stack-policy in a heredoc, apply that
#    file, and carry the parameters below. It must not mark the class default.
#
# C. No such installer patches Longhorn's auto-salvage setting to false.
#
# No subject at all is a failure that says it measured nothing.
#
# WHAT THIS DOES NOT SHOW
#
# It reads text. It does not show that Longhorn schedules a replica on the
# workload's node, or that a partitioned engine keeps serving. That is the live
# partition run, which is not a gate. See GOTCHAS 127.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import subprocess
import sys

MANIFEST = "manifests/15-policy-store.yaml"
CLASS = "stack-policy"
TOP = {"provisioner": "driver.longhorn.io", "reclaimPolicy": "Retain"}
PARAMS = {
    "numberOfReplicas": "3",
    "dataLocality": "best-effort",
    "disableRevisionCounter": "false",
    "staleReplicaTimeout": "2880",
    "fsType": "ext4",
}

failures = []


def measured_nothing(what):
    print(f"FAIL: {what}")
    print("      That is not health: the subject is gone or this check no longer finds it.")
    print("      This measured nothing, and it is not entitled to say OK.")
    sys.exit(1)


# ---- A: the claim names the class -----------------------------------------
if not os.path.isfile(MANIFEST):
    measured_nothing(f"{MANIFEST} is missing")
mlines = open(MANIFEST).read().split("\n")
vct = [i for i, l in enumerate(mlines) if re.match(r"^\s*volumeClaimTemplates:\s*$", l)]
if not vct:
    measured_nothing(f"{MANIFEST} has no volumeClaimTemplates")
policy_db = [i for i, l in enumerate(mlines) if re.match(r"^\s*name: policy-db\s*$", l) and i < vct[0]]
if not policy_db:
    measured_nothing(f"{MANIFEST} has no policy-db StatefulSet before its claim template")
named = [l for l in mlines[vct[0]:] if re.match(r"^\s*storageClassName:", l)]
if not named:
    failures.append(f"{MANIFEST}: the policy-db claim template names no storageClassName, so it takes "
                    f"the default class (Longhorn's `longhorn`, dataLocality disabled, revision counter off)")
else:
    value = named[0].split(":", 1)[1].strip().strip('"')
    if value != CLASS:
        failures.append(f"{MANIFEST}: the policy-db claim names `{value}`, not `{CLASS}`")

# ---- B: every Longhorn installer writes the class --------------------------
files = [f for f in subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True,
                                   check=True).stdout.split()
         if not f.startswith("scripts/") and os.path.isfile(f)]
installers = []
for f in files:
    lines = open(f).read().split("\n")
    live = [l for l in lines if not l.lstrip().startswith("#")]
    if any("apply" in l and "longhorn/longhorn/" in l and "deploy/longhorn.yaml" in l for l in live):
        installers.append((f, lines))

if not installers:
    measured_nothing("no tracked script outside scripts/ applies Longhorn's deploy/longhorn.yaml")

for f, lines in installers:
    names = [i for i, l in enumerate(lines) if re.match(r"^\s*name: " + CLASS + r"\s*$", l)]
    if not names:
        failures.append(f"{f} installs Longhorn and never creates the {CLASS} StorageClass")
        continue
    i = names[0]
    heredocs = [j for j in range(i) if "<<'YAML'" in lines[j]]
    if not heredocs:
        failures.append(f"{f}: the {CLASS} StorageClass is not written by a <<'YAML' heredoc")
        continue
    start = heredocs[-1]
    ends = [j for j in range(i, len(lines)) if lines[j].strip() == "YAML"]
    if not ends:
        failures.append(f"{f}: the {CLASS} heredoc has no closing YAML line")
        continue
    end = ends[0]
    block = lines[start + 1:end]

    kv = {}
    dups = []
    for l in block:
        if l.lstrip().startswith("#"):
            continue
        m = re.match(r"^\s*([A-Za-z][A-Za-z0-9]*):\s*(.*?)\s*$", l)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip().strip('"')
        if key in kv:
            dups.append(key)
        kv[key] = val
    for key in dups:
        failures.append(f"{f}: the {CLASS} class sets `{key}` twice; the second one wins silently")

    for key, want in TOP.items():
        if kv.get(key) != want:
            failures.append(f"{f}: the {CLASS} class has {key}={kv.get(key)!r}, want {want!r}")
    for key, want in PARAMS.items():
        if kv.get(key) != want:
            failures.append(f"{f}: the {CLASS} class has parameter {key}={kv.get(key)!r}, want {want!r}")
    if any("is-default-class" in l and "true" in l for l in block):
        failures.append(f"{f}: the {CLASS} class is marked as the default class, which moves every unnamed claim onto it")

    m = re.search(r"/tmp/(" + re.escape(CLASS) + r"\.yaml)", lines[start])
    if not m:
        failures.append(f"{f}: the {CLASS} heredoc does not write to /tmp/{CLASS}.yaml")
    else:
        applied = [j for j in range(end + 1, len(lines))
                   if "apply" in lines[j] and ("/tmp/" + m.group(1)) in lines[j]
                   and not lines[j].lstrip().startswith("#")]
        if not applied:
            failures.append(f"{f}: nothing applies /tmp/{m.group(1)} after it is written")

# ---- C: auto-salvage stays on ----------------------------------------------
for f, lines in installers:
    for j, l in enumerate(lines, 1):
        if l.lstrip().startswith("#"):
            continue
        if "auto-salvage" in l and "patch" in l and re.search(r"\bfalse\b", l):
            failures.append(f"{f}:{j} turns Longhorn's auto-salvage off, so an all-replicas-faulty volume "
                            f"is never salvaged on its own")

if failures:
    for msg in failures:
        print(f"FAIL: {msg}")
    print()
    print(f"{len(failures)} problem(s) across the policy store's volume and {len(installers)} Longhorn installer(s).")
    sys.exit(1)

print(f"OK: policy-db claims {CLASS}, and {len(installers)} Longhorn installer(s) create it with "
      f"dataLocality best-effort, revision counter on, 2880-minute stale timeout and Retain; "
      f"no installer turns auto-salvage off.")
PY
