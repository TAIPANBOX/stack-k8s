#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 92: every Gherkin scenario under features/ is bound to a check that
# exists, and every binding names a check that exists.
#
# WHY
#
# `features/*.feature` is what a person reads instead of the diff: Given, When, Then, in plain words.
# It is worth that only while each scenario is backed by something that runs. This repository has no
# BDD runner on purpose (a runner is a second step-definition language beside the shell gates), so
# the backing is named in a comment under the scenario. Until 2026-11-23 the binding was by eye, and by
# eye is how a scenario outlives the test it names: two bindings pointed at teeth cases that had been
# renamed ("an installer turns automatic salvage off", "xcaddy loses Caddy's version"), and the
# scenarios still read true while nothing ran under them.
#
# THE FORMS A BINDING TAKES HERE, AND HOW EACH IS RESOLVED
#
#   # -> gates-have-teeth.sh "<name>"            a `run_case "<name>"` in scripts/gates-have-teeth.sh
#   # -> <gate>.sh check "<n>"                    the quoted text appears in that script
#   # -> <gate>.sh checks "<a>", "<b>" and "<c>"  each quoted text appears in that script
#   # -> <gate>.sh case <X>                       that script has a `# ---- <X>:` or `# ---- <W>, <X>:` header
#   # -> security-tests.sh "<name>"               the quoted text appears in security-tests.sh
#   # -> evidence/<path>[, what in it]            the path is a tracked file of this repository
#   # -> measured live on <where> <date>: <path>  a run recorded outside this repository; it cannot be
#                                                 resolved here, so it is counted and named in the OK
#                                                 line rather than passed in silence
#
# A binding in any other shape is a problem: a form this gate does not know is a form it cannot check.
#
# THE TWO DIRECTIONS
#
#   1. No scenario without a test: every `Scenario:` has at least one binding line before the next
#      scenario (or the end of the file).
#   2. No binding pointing at nothing: every binding resolves as above.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No feature file, no scenario, no binding, or no teeth harness to resolve against: each fails.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import glob
import os
import re
import subprocess
import sys

features = sorted(glob.glob("features/*.feature"))
if not features:
    print("FAIL: there is no features/*.feature, so this gate measured NOTHING.")
    sys.exit(1)
try:
    teeth = open("scripts/gates-have-teeth.sh").read()
except OSError:
    print("FAIL: scripts/gates-have-teeth.sh is not there, so no binding can be resolved.")
    sys.exit(1)
cases = set(re.findall(r'^\s*run_case\s+"([^"]+)"', teeth, re.M))
if not cases:
    print("FAIL: scripts/gates-have-teeth.sh has no run_case, so no binding can be resolved.")
    sys.exit(1)

try:
    tracked = set(subprocess.run(["git", "ls-files"], capture_output=True, text=True,
                                 check=True).stdout.split("\n"))
except (OSError, subprocess.CalledProcessError):
    tracked = None


def script_text(name):
    for path in (os.path.join("scripts", name), name):
        try:
            return open(path).read()
        except OSError:
            continue
    return None


def resolve(target):
    """None when the binding resolves, else the reason it does not; 'external' for a recorded run."""
    m = re.fullmatch(r'gates-have-teeth\.sh\s+"([^"]+)"', target)
    if m:
        if m.group(1) in cases:
            return None
        return f'gates-have-teeth.sh has no run_case "{m.group(1)}": the scenario names a test that is gone'
    m = re.fullmatch(r"([\w.-]+\.sh)\s+(checks?)\s+(.+)", target)
    if m:
        text = script_text(m.group(1))
        if text is None:
            return f"{m.group(1)} is not a script here"
        names = re.findall(r'"([^"]+)"', m.group(3))
        if not names:
            return f"{m.group(1)} {m.group(2)} names no quoted check"
        missing = [n for n in names if n not in text]
        return f"{m.group(1)} has no check {missing}" if missing else None
    m = re.fullmatch(r"([\w.-]+\.sh)\s+case\s+(\S+)", target)
    if m:
        text = script_text(m.group(1))
        if text is None:
            return f"{m.group(1)} is not a script here"
        for header in re.findall(r"^# ---- ([^:\n]+):", text, re.M):
            if m.group(2) in [h.strip() for h in header.split(",")]:
                return None
        return f"{m.group(1)} has no case {m.group(2)} (no `# ---- {m.group(2)}:` header)"
    m = re.fullmatch(r'([\w.-]+\.sh)\s+"([^"]+)"', target)
    if m:
        text = script_text(m.group(1))
        if text is None:
            return f"{m.group(1)} is not a script here"
        return None if m.group(2) in text else f'{m.group(1)} never says "{m.group(2)}"'
    m = re.match(r"(evidence/[^\s,]+)", target)
    if m:
        path = m.group(1)
        if tracked is None:
            return "git ls-files could not be read, so an evidence path cannot be resolved"
        return None if path in tracked else f"{path} is not a tracked file of this repository"
    if re.match(r"measured live on \S+ \d{4}-\d{2}-\d{2}: \S+", target):
        return "external"
    return f"a binding this gate does not know how to resolve: {target!r}"


problems = []
external = []
scenarios = bindings = 0
for f in features:
    current = None
    bound = {}
    for n, line in enumerate(open(f).read().split("\n"), 1):
        m = re.match(r"^\s*Scenario(?: Outline)?:\s*(.+?)\s*$", line)
        if m:
            current = (n, m.group(1))
            bound[current] = 0
            scenarios += 1
            continue
        b = re.match(r"^\s*#\s*->\s*(.+?)\s*$", line)
        if not b:
            continue
        if current is None:
            problems.append(f"{f}:{n}: a binding with no scenario above it")
            continue
        bindings += 1
        bound[current] += 1
        why = resolve(b.group(1))
        if why == "external":
            external.append(f"{f}:{n}")
        elif why is not None:
            problems.append(f"{f}:{n}: {why}")
    for (n, title), count in bound.items():
        if count == 0:
            problems.append(f'{f}:{n}: scenario "{title}" is bound to no test')

if scenarios == 0:
    print("FAIL: no Scenario: in features/, so this gate measured NOTHING.")
    sys.exit(1)
if bindings == 0:
    print("FAIL: no `# -> ...` binding anywhere, so this gate measured NOTHING.")
    sys.exit(1)
if problems:
    for p in problems:
        print("FAIL: " + p)
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 92.")
    sys.exit(1)
ext = f"; {len(external)} name a run recorded outside this repository ({', '.join(external)})" if external else ""
print(f"OK: {scenarios} scenario(s) in {len(features)} feature file(s), every one bound; "
      f"{bindings} binding(s), each resolved to a check that exists{ext}.")
PY
