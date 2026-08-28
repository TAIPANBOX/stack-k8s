#!/usr/bin/env bash
#
# Enforces: components.json says what this launcher actually installs.
#
# WHY A LAUNCHER HAS A MANIFEST AT ALL
#
# Sixteen repositories in this estate declare what they BUILD, and a check in
# each proves that declaration against its own toolchain. A launcher builds
# nothing of its own. What it can say, and nothing else can, is what it
# INSTALLS.
#
# AND THERE IS ALREADY A SECOND OPINION
#
# estate-gates' C5 reads all three launchers from one central file: `register
# <name>` out of a shell script in stack-up, compose service keys in
# stack-single, Kubernetes kinds here. One parser, three grammars, none of it
# living where the fact lives. This is the other statement of the same fact,
# made where it does.
#
# THE ROUTINE NAMES ARE THE PART WORTH CHECKING TWICE
#
# This is the only deployment whose routines are called something else: a
# CronJob here is `crypto-trend` and the estate calls that routine
# `qryx-trend`. C5 carries that map and its own comment says an unmapped
# routine is a FAIL rather than a skip, because one it does not know is one it
# silently would not compare. The map is in components.json too, as a pair per
# CronJob, so a rename on either side is visible from both.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# Every observed list is checked for being empty first. A manifests/ directory
# that stops yielding Deployments must read as "measured nothing", not as
# agreement about an empty stack.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - components.json manifests <<'PY'
import collections
import json
import pathlib
import re
import sys

manifest_path, manifests_dir = sys.argv[1:3]

manifest = json.load(open(manifest_path))
components = manifest.get("components") or []
if not components:
    print("FAIL: components.json declares no component, so this measured NOTHING.")
    sys.exit(1)
checked = components[0]["checked"]

# Every object in every document, by kind. A `---` separated stream, read the
# way kubectl reads it rather than the way a grep would.
objs = collections.defaultdict(set)
docs = 0
for path in sorted(pathlib.Path(manifests_dir).glob("*.yaml")):
    for doc in path.read_text().split("\n---"):
        kind = re.search(r"(?m)^kind:\s*(\w+)", doc)
        if not kind:
            continue
        docs += 1
        name = re.search(r"(?m)^\s*name:\s*([a-z0-9-]+)", doc)
        if name:
            objs[kind.group(1)].add(name.group(1))

if docs == 0:
    print(f"FAIL: no Kubernetes object under {manifests_dir}/, so this measured NOTHING.")
    print("      Either the manifests moved or they stopped declaring a kind.")
    sys.exit(1)

problems = 0


def compare(label, declared, observed, empty_means):
    global problems
    if not observed:
        print(f"FAIL: {empty_means}, so this measured NOTHING about that list.")
        print("      That is not the same as the list being empty.")
        problems += 1
        return
    for name in sorted(set(observed) - set(declared)):
        print(f"FAIL: this launcher installs {name!r} ({label}) and components.json does not say so")
        problems += 1
    for name in sorted(set(declared) - set(observed)):
        print(f"FAIL: components.json says this launcher installs {name!r} ({label}) and it does not")
        problems += 1


compare(
    "a long-running workload",
    checked.get("installs_services", []),
    sorted(objs["Deployment"] | objs["StatefulSet"]),
    "no Deployment and no StatefulSet under manifests/",
)

schedules = checked.get("schedules_routines", {})
compare(
    "a CronJob",
    list(schedules),
    sorted(objs["CronJob"]),
    "no CronJob under manifests/",
)

compare(
    "a persistent claim",
    checked.get("persistent_claims", []),
    sorted(objs["PersistentVolumeClaim"]),
    "no PersistentVolumeClaim under manifests/",
)

# The map has to name a routine the estate knows, or it is a private nickname
# for a private nickname and C5 could not use it.
ESTATE_ROUTINES = {
    "focus-export", "qryx-trend", "verdryx-drift",
    "idryx-detect", "mockryx-drill", "trailryx-seal",
}
for local, routine in sorted(schedules.items()):
    if routine not in sorted(ESTATE_ROUTINES):
        print(f"FAIL: components.json maps the CronJob {local!r} to {routine!r}, which is")
        print(f"      not one of the estate's routines: {sorted(ESTATE_ROUTINES)}")
        problems += 1
if len(set(schedules.values())) != len(schedules):
    dupes = [r for r, n in collections.Counter(schedules.values()).items() if n > 1]
    print(f"FAIL: two CronJobs are mapped to the same routine {dupes}. One routine runs")
    print("      once per deployment, so this map cannot be right.")
    problems += 1

if problems:
    print()
    print(f"{problems} problem(s). components.json and these manifests disagree.")
    sys.exit(1)

missing = sorted(ESTATE_ROUTINES - set(schedules.values()))
print(f"OK: {len(checked.get('installs_services', []))} workload(s), {len(schedules)} CronJob(s) "
      f"and {len(checked.get('persistent_claims', []))} claim(s), each compared with")
print(f"    manifests/ both ways, across {docs} object(s).")
if missing:
    print(f"    Not scheduled here: {', '.join(missing)}. estate-gates is where that is judged.")
PY
