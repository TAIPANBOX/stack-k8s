#!/usr/bin/env bash
# Enforces the refusal half of invariant 43 in CLAUDE.md: a deploy that would apply
# the manifests onto a cluster whose policy-db claim is on another class stops,
# with one sentence naming GOTCHAS 129, BEFORE the first `apply -k`.
#
# WHY
#
# A StatefulSet's claim template cannot change in place. On a cluster already running
# policy-db on Longhorn's default class, `kubectl apply -k` is refused for that object
# (measured on a local kind cluster, 2026-10-14), and the deploy scripts run under
# `set -euo pipefail`, so the deploy used to stop halfway through step 3.
# lib/policy-store.sh is the one copy of the check, and each of the three deploy
# scripts calls it right after the step 3 banner.
#
# WHAT IS CHECKED
#
# A. Behaviour. lib/policy-store.sh is sourced under a fake kubectl (`k_`) that answers
#    six scenarios, and each run must end as stated:
#      fresh              no policy-db: returns, and the apply runs
#      stack              policy-db on stack-policy: returns, and the apply runs
#      old                policy-db on longhorn: refuses, names GOTCHAS 129, no apply
#      default            policy-db with no class: refuses, names the default class, no apply
#      unreachable-name   the cluster cannot be asked: refuses, no apply
#      unreachable-class  the claim cannot be read: refuses, no apply
#    A refusal must print its sentence on stderr and must never reach the apply.
#
# B. Placement. Every tracked shell script outside scripts/ with a live
#    `k_ "apply -k .../manifests"` (the three deploy scripts today) must source
#    lib/policy-store.sh and call policy_store_guard on a live line BEFORE its first
#    such apply.
#
# No subject at all is a failure that says it measured nothing.
#
# WHAT THIS DOES NOT SHOW
#
# It does not run a deploy. The fake kubectl answers what the check asks, not what a
# real API server would answer. The live refusal on a real cluster is not a gate.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import subprocess
import sys
import tempfile

LIB = "lib/policy-store.sh"
failures = []


def measured_nothing(what):
    print(f"FAIL: {what}")
    print("      That is not health: the subject is gone or this check no longer finds it.")
    print("      This measured nothing, and it is not entitled to say OK.")
    sys.exit(1)


if not os.path.isfile(LIB):
    measured_nothing(f"{LIB} is missing")
lib_text = open(LIB).read()
if not re.search(r"^policy_store_guard\(\)", lib_text, re.M):
    measured_nothing(f"{LIB} does not define policy_store_guard")

# ---- A: behaviour under a fake kubectl ------------------------------------
HARNESS = r'''
set -euo pipefail
die() { echo "!! $*" >&2; exit 1; }
k_() {
  printf '%s\n' "$*" >> "$LOG"
  case "$*" in
    *"--ignore-not-found -o name"*)
      case "$SCENARIO" in
        unreachable-name) return 1 ;;
        fresh) return 0 ;;
        *) echo "statefulset.apps/policy-db"; return 0 ;;
      esac ;;
    *"jsonpath="*)
      case "$SCENARIO" in
        unreachable-class) return 1 ;;
        stack) echo stack-policy ;;
        old) echo longhorn ;;
        default) : ;;
      esac
      return 0 ;;
    apply*) echo applied; return 0 ;;
  esac
  return 0
}
. "$LIB"
policy_store_guard
k_ "apply -k /root/stack-k8s/" "manifests"
echo DONE
'''

# scenario: (expect, needle-on-stderr-or-None)
SCENARIOS = {
    "fresh": ("ok", None),
    "stack": ("ok", None),
    "old": ("refuse", "policy-db already exists on a claim of class 'longhorn'"),
    "default": ("refuse", "class 'the default class'"),
    "unreachable-name": ("refuse", "could not ask the cluster"),
    "unreachable-class": ("refuse", "could not read policy-db's claim class"),
}
REFUSAL_MUST_NAME = "GOTCHAS 129"

tmp = tempfile.mkdtemp(prefix="policy-guard-")
try:
    for scenario, (expect, needle) in SCENARIOS.items():
        log = os.path.join(tmp, scenario + ".log")
        env = dict(os.environ, SCENARIO=scenario, LOG=log, LIB=os.path.abspath(LIB))
        run = subprocess.run(["bash", "-c", HARNESS], env=env, capture_output=True, text=True)
        applied = os.path.exists(log) and any(l.startswith("apply") for l in open(log).read().split("\n"))
        if expect == "ok":
            if run.returncode != 0 or "DONE" not in run.stdout:
                failures.append(f"scenario {scenario}: expected the deploy to go on, got exit "
                                f"{run.returncode} and {run.stderr.strip()[:160]!r}")
            elif not applied:
                failures.append(f"scenario {scenario}: the deploy went on but never reached the apply")
            continue
        if run.returncode == 0 or "DONE" in run.stdout:
            failures.append(f"scenario {scenario}: expected a refusal, but the deploy reached the apply")
        if applied:
            failures.append(f"scenario {scenario}: a refusal still reached the apply")
        if needle and needle not in run.stderr:
            failures.append(f"scenario {scenario}: refusal does not say {needle!r}")
        if scenario == "old" and REFUSAL_MUST_NAME not in run.stderr:
            failures.append(f"scenario {scenario}: refusal lacks {REFUSAL_MUST_NAME!r}, so it does not point at the migration")
finally:
    subprocess.run(["rm", "-rf", tmp])

# ---- B: placement in every deploy script ----------------------------------
files = [f for f in subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True,
                                   check=True).stdout.split()
         if not f.startswith("scripts/") and os.path.isfile(f)]
subjects = 0
for f in files:
    lines = open(f).read().split("\n")
    live = [(i, l) for i, l in enumerate(lines) if not l.lstrip().startswith("#")]
    applies = [i for i, l in live if re.search(r'k_ "apply -k[^"]*manifests"', l)]
    if not applies:
        continue
    subjects += 1
    first = applies[0]
    sourced = [i for i, l in live if l.lstrip().startswith(". ") and "lib/policy-store.sh" in l]
    guards = [i for i, l in live if re.match(r"^\s*policy_store_guard\b", l)]
    if not sourced:
        failures.append(f"{f} applies manifests/ and does not source lib/policy-store.sh")
    if not guards:
        failures.append(f"{f} applies manifests/ and does not call policy_store_guard before it")
    elif guards[0] > first:
        failures.append(f"{f}:{guards[0] + 1} calls policy_store_guard after its first apply -k at line {first + 1}")

if subjects == 0:
    measured_nothing("no tracked script outside scripts/ applies manifests/ with apply -k")

for msg in failures:
    print(f"FAIL: {msg}")
if failures:
    print()
    print(f"{len(failures)} problem(s) in the refusal before apply, across {subjects} deploy script(s).")
    sys.exit(1)
print(f"OK: a deploy refuses an old policy-db claim before its first apply, in {subjects} deploy script(s), "
      f"across {len(SCENARIOS)} scenarios with a fake kubectl.")
PY
