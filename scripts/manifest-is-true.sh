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
# The document each object came from, so a claim ABOUT an object can be checked
# against the object rather than against its name. `manual_jobs` below is the
# first thing that needs this: "suspended" is a property of the body.
bodies = {}
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
            bodies[(kind.group(1), name.group(1))] = doc

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

# Two kinds of CronJob live here and only one of them is a routine.
#
# `schedules_routines` is the estate's governance work, on a schedule, mapped to
# the name the estate calls it. `manual_jobs` is the other shape: a CronJob that
# exists to be a Job TEMPLATE, shipped suspended, run by a person with
# `kubectl create job --from=cronjob/<name>`. That is Kubernetes' own idiom for
# "a job you trigger by hand", and calling one a routine would put a schedule
# nobody keeps into the estate's map of what runs where.
#
# Both are compared against the manifests, so a CronJob in neither list is still
# a FAIL. What separates them is what is then required of each.
schedules = checked.get("schedules_routines", {})
manual = checked.get("manual_jobs", {})
overlap = sorted(set(schedules) & set(manual))
if overlap:
    print(f"FAIL: {overlap} are listed as BOTH a scheduled routine and a manual job.")
    print("      A CronJob is one or the other; it cannot be both.")
    problems += 1
compare(
    "a CronJob",
    list(schedules) + list(manual),
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
#
# `costcrew-run` is the one exception, added 2026-09-03 when costcrew-crew
# stopped being a suspended manual_jobs template (it now fires daily, gated by
# the console's own cadence switch rather than by Kubernetes suspend). This
# repository knows it as a routine; estate-gates' own ROUTINE_KIND, in that
# other repository, does not yet, so C5 reports `c5.routine-unmapped` for this
# one pair until somebody updates it there. Recorded in components.json's
# `declared` bucket rather than hidden, the same shape as GOTCHAS 93.
ESTATE_ROUTINES = {
    "focus-export", "qryx-trend", "verdryx-drift",
    "idryx-detect", "mockryx-drill", "trailryx-seal",
    "costcrew-run",
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

# "Manual" is a claim about the object, so it is checked against the object.
#
# A CronJob declared manual and NOT suspended runs on whatever schedule its
# manifest happens to carry, on a cluster whose operator was told it runs only
# when they say so. That failure is silent in the direction that matters: the
# first anybody knows is a job that already ran. costcrew-crew is the case this
# was written for, and it is the one CronJob in this namespace that can spend
# money on an account outside the cluster.
for name in sorted(manual):
    why = (manual.get(name) or "").strip()
    if not why:
        print(f"FAIL: components.json calls the CronJob {name!r} a manual job and gives no")
        print("      reason. A category with no reason is a category nobody can review.")
        problems += 1
    body = bodies.get(("CronJob", name))
    if body is None:
        # compare() has already said the CronJob is missing; do not say it twice.
        continue
    if not re.search(r"(?m)^\s*suspend:\s*true\s*$", body):
        print(f"FAIL: components.json calls the CronJob {name!r} a manual job, and its")
        print("      manifest does not set `suspend: true`. It would run on its schedule.")
        problems += 1

# A routine may run here without a CronJob. focus-export does: it is a sidecar
# in the gateway pod, because the volume it reads is an emptyDir that no other
# pod can mount. Counted as run rather than as absent, and checked against the
# pod that is supposed to hold it.
sidecars = checked.get("runs_as_sidecar", {})
for routine, pod in sorted(sidecars.items()):
    if routine not in ESTATE_ROUTINES:
        print(f"FAIL: components.json says {routine!r} runs as a sidecar and it is not")
        print(f"      one of the estate's routines: {sorted(ESTATE_ROUTINES)}")
        problems += 1
    if pod not in objs["Deployment"] | objs["StatefulSet"]:
        print(f"FAIL: components.json says {routine!r} is a sidecar in {pod!r} and no")
        print(f"      such workload exists under {manifests_dir}/.")
        problems += 1
        continue
    # And the container has to actually be there, or the claim is a sentence.
    body = "".join(
        path.read_text()
        for path in sorted(pathlib.Path(manifests_dir).glob("*.yaml"))
    )
    # Anchored to the whole line, because `- name: focus-export` is a PREFIX of
    # `- name: focus-exporter`: a substring test passes on a container that was
    # renamed, which is exactly the change this is meant to catch. Found by
    # planting that rename and watching the first version stay silent.
    if not re.search(rf"(?m)^\s*- name: {re.escape(routine)}\s*$", body):
        print(f"FAIL: components.json says {routine!r} runs as a sidecar and no container")
        print(f"      by that name exists in any manifest.")
        problems += 1

if problems:
    print()
    print(f"{problems} problem(s). components.json and these manifests disagree.")
    sys.exit(1)

missing = sorted(ESTATE_ROUTINES - set(schedules.values()) - set(sidecars))
print(f"OK: {len(checked.get('installs_services', []))} workload(s), {len(schedules)} scheduled "
      f"CronJob(s), {len(manual)} manual job(s) and {len(checked.get('persistent_claims', []))} "
      f"claim(s), each compared with")
print(f"    manifests/ both ways, across {docs} object(s).")
if manual:
    print(f"    Suspended, run by hand: {', '.join(sorted(manual))}.")
if missing:
    print(f"    Not run here at all: {', '.join(missing)}. estate-gates is where that is judged.")
if sidecars:
    print(f"    Run without a CronJob: {', '.join(f'{r} (sidecar in {p})' for r, p in sorted(sidecars.items()))}.")
PY
