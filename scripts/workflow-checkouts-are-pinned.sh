#!/usr/bin/env bash
# CLAUDE.md invariant 68. A workflow that checks out ANOTHER repository names the commit it builds, as a
# full 40-hex SHA, and never a branch, a tag or no ref at all. Without a ref, a published image is built
# from whatever that repository's main held when the tag was pushed, so the image's contents are not
# what the tag says. The SHAs are written once per workflow, in its top-level `env:` block, and each
# checkout reads them from there.
#
# WHAT THIS CHECKS
#
#   1. Every `actions/checkout` step in .github/workflows/*.yml whose `repository:` names something other
#      than this repository has a `ref:` that is either a literal 40-hex SHA, or `${{ env.NAME }}` where
#      the workflow's top-level `env:` block sets NAME to a 40-hex SHA.
#   2. A checkout with no `ref:`, a branch, a tag or a short SHA is refused.
#   3. The workflow's top-level `env:` block exists when a checkout reads from it.
#
# A checkout of this repository itself (no `repository:`) is not judged: it is the commit the tag names.
#
# Since stack-k8s 1.19.0 no workflow here checks out another repository: the console image, which was a
# composition of five, is built and signed by genaryx's own release workflow. The rule stays, as a guard on
# the next workflow that does. So the subject is every checkout step: none at all is "measured NOTHING",
# never a pass, and checkouts that all name this repository are counted and reported, not hidden.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import re
import sys

HEX40 = re.compile(r"^[0-9a-f]{40}$")
bad = []
checked = 0
steps = 0
files = sorted(glob.glob(".github/workflows/*.yml"))
if not files:
    print("FAIL: no workflow under .github/workflows/, so this measured NOTHING")
    sys.exit(1)

for path in files:
    lines = open(path).read().split("\n")
    # The top-level env block: a line `env:` at column 0, and the `NAME: value` lines under it.
    env = {}
    in_env = False
    for line in lines:
        if re.match(r"^env:\s*$", line):
            in_env = True
            continue
        if in_env:
            if line and not line.startswith(" ") and not line.startswith("#"):
                in_env = False
                continue
            m = re.match(r"^\s{2}([A-Z][A-Z0-9_]*):\s*['\"]?([^'\"\s#]+)['\"]?\s*(#.*)?$", line)
            if m:
                env[m.group(1)] = m.group(2)

    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*)- uses:\s*actions/checkout@", lines[i])
        if not m:
            i += 1
            continue
        steps += 1
        indent = len(m.group(1))
        j = i + 1
        block = []
        while j < len(lines):
            s = lines[j]
            if s.strip() and (len(s) - len(s.lstrip())) <= indent:
                break
            block.append(s)
            j += 1
        text = "\n".join(block)
        i = j
        repo_m = re.search(r"^\s*repository:\s*(\S+)\s*$", text, re.M)
        if repo_m is None:
            continue  # this repository: not judged
        repo = repo_m.group(1).strip("'\"")
        if repo == "TAIPANBOX/stack-k8s":
            continue
        checked += 1
        where = f"{path}: checkout of {repo}"
        ref_m = re.search(r"^\s*ref:\s*(.+?)\s*$", text, re.M)
        if ref_m is None:
            bad.append(f"{where} has no ref:, so it builds whatever that repository's main held")
            continue
        ref = ref_m.group(1).strip("'\"")
        env_m = re.fullmatch(r"\$\{\{\s*env\.([A-Z][A-Z0-9_]*)\s*\}\}", ref)
        if env_m:
            name = env_m.group(1)
            if name not in env:
                bad.append(f"{where} reads ref from env.{name}, which the workflow's top-level env: block does not set")
            elif not HEX40.match(env[name]):
                bad.append(f"{where}: env.{name} is {env[name]!r}, not a full 40-hex commit")
            continue
        if not HEX40.match(ref):
            bad.append(f"{where}: ref {ref!r} is not a full 40-hex commit (a branch, a tag or a short SHA moves)")

if steps == 0:
    print("FAIL: no actions/checkout step found in any workflow, so this measured NOTHING")
    sys.exit(1)

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 68.")
    sys.exit(1)

print(f"OK: {steps} checkout step(s) in {len(files)} workflow(s); {checked} of them check out another repository, "
      "each at a full 40-hex commit (literal, or named in its workflow's top-level env: block).")
PY
