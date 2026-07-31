#!/usr/bin/env bash
# Enforces invariant 1 of CLAUDE.md: every NEW gotcha carries a classification.
#
# GOTCHAS.md is the value of this repo, and the labels are the reason it can be
# believed. Each entry should say whose fault it was: the platform's, or ours,
# with "ours" split into fixed, unfixed in this shape, and unresolved by design.
# An unlabelled entry is an observation, and it quietly improves our own record
# by not counting against it.
#
# WHY THIS IS A RATCHET AND NOT A FLAT CHECK
#
# When this gate was written, 30 of the 70 entries had no label. Classifying
# them retroactively is not a mechanical job: only the person who hit the trap
# knows whether it was the platform's behaviour or our own mistake, and guessing
# would produce exactly the flattering ledger the labels exist to prevent.
#
# So the current 30 are pinned in scripts/gotchas-unclassified.txt as a
# baseline. The gate fails when the baseline GROWS, that is when a new entry
# arrives without a label. It also fails when a baselined entry gets classified
# but is not removed from the baseline, so the list can only shrink and never
# silently absorbs a new omission.
#
# To close one: label it in GOTCHAS.md, delete its number from the baseline file,
# both in the same commit.
#
# This file is the ONE copy of this check. The local hook calls it, and CI would
# call the same file if this repo ever gets CI.

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

BASELINE = pathlib.Path("scripts/gotchas-unclassified.txt")
text = pathlib.Path("GOTCHAS.md").read_text()

heads = list(re.finditer(r"^## (\d+)\.\s*(.+)$", text, re.M))
if not heads:
    print("FAIL: no numbered gotcha sections found in GOTCHAS.md")
    sys.exit(1)

LABEL = re.compile(r"\*\*(Platform|Ours)\b[^*]*\*\*")

unlabelled = set()
platform = ours = 0

for i, h in enumerate(heads):
    start = h.end()
    end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
    m = LABEL.search(text[start:end])
    if not m:
        unlabelled.add(int(h.group(1)))
    elif m.group(1) == "Platform":
        platform += 1
    else:
        ours += 1

baseline = set()
if BASELINE.exists():
    for line in BASELINE.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            baseline.add(int(line))

new = sorted(unlabelled - baseline)
fixed_but_still_listed = sorted(baseline - unlabelled)

fail = False

for num in new:
    title = next(h.group(2).strip() for h in heads if int(h.group(1)) == num)
    print(f"FAIL: gotcha {num} has no classification: {title[:70]}")
    fail = True

if new:
    print()
    print("A new entry must say whose fault it was: **Platform.** or")
    print("**Ours, and fixed.** or **Ours, and unfixed in this shape.** or")
    print("**Ours, and unresolved by design.** See CLAUDE.md invariant 1.")
    print()

for num in fixed_but_still_listed:
    print(f"FAIL: gotcha {num} is now classified but is still in {BASELINE}")
    fail = True

if fixed_but_still_listed:
    print()
    print("Remove it from the baseline in the same commit that labels it, so the")
    print("list only ever shrinks.")

if fail:
    sys.exit(1)

total = len(heads)
print(
    f"OK: {total} gotchas, {platform} platform, {ours} ours, "
    f"{len(unlabelled)} unclassified (all baselined, none new)."
)
PY
