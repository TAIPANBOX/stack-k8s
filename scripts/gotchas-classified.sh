#!/usr/bin/env bash
# Enforces invariant 1 of CLAUDE.md: every gotcha says whose fault it was.
#
# GOTCHAS.md is the value of this repo, and the labels are the reason it can be
# believed. An unlabelled entry is an observation, and it quietly improves our
# own record by not counting against it.
#
# THE VOCABULARY IS FOUR-WAY, NOT TWO-WAY. This matters, and the first version
# of this script got it wrong:
#
#   Platform.                    Kubernetes, the distro or the cloud does this
#                                to everyone.
#   Ours, ...                    Our mistake. Qualified further as "and fixed",
#                                "and unfixed in this shape", "and unresolved by
#                                design", or "meeting a platform fact".
#   The stack's own contract.    A property of OUR SERVICES that is not a bug.
#                                Neither a platform trap nor a mistake.
#   Upstream.                    Somebody else's project does this to everyone.
#
# A check that knows only Platform and Ours reports the ten "stack's own
# contract" entries and the two "Upstream" ones as unclassified, which is what
# happened, and it put a wrong number into CLAUDE.md and into a pull request
# before anybody read the file properly.
#
# This check cannot tell a correct label from a self-serving one. That part is
# judgement, and CLAUDE.md says so.
#
# This file is the ONE copy of this check. The local hook calls it, and CI would
# call the same file if this repo ever gets CI.

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys
from collections import Counter

text = pathlib.Path("GOTCHAS.md").read_text()

heads = list(re.finditer(r"^## (\d+)\.\s*(.+)$", text, re.M))
if not heads:
    print("FAIL: no numbered gotcha sections found in GOTCHAS.md")
    sys.exit(1)

FAULT = re.compile(r"\*\*(Platform|Ours[^*]*|The stack's own contract|Upstream)\.?\*\*")

# The label belongs near the top of the entry, not buried in the body, so a
# stray bold word deep in a code discussion cannot satisfy the check.
HEAD_WINDOW = 600

counts = Counter()
missing = []

for i, h in enumerate(heads):
    start = h.end()
    end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
    m = FAULT.search(text[start:end][:HEAD_WINDOW])
    if not m:
        missing.append((h.group(1), h.group(2).strip()))
        continue
    label = m.group(1)
    counts["Ours" if label.startswith("Ours") else label] += 1

if missing:
    for num, title in missing:
        print(f"FAIL: gotcha {num} has no classification: {title[:70]}")
    print()
    print("Every entry says whose fault it was, in the first few lines:")
    print("  **Platform.**                  the platform does this to everyone")
    print("  **Ours, and fixed.**           our mistake, and what we did")
    print("  **The stack's own contract.**  a property of our services, not a bug")
    print("  **Upstream.**                  another project does this to everyone")
    print()
    print("See CLAUDE.md invariant 1.")
    sys.exit(1)

total = len(heads)
summary = ", ".join(f"{v} {k.lower()}" for k, v in counts.most_common())
print(f"OK: {total} gotchas, all classified ({summary}).")
PY
