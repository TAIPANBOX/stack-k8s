#!/usr/bin/env bash
# Enforces invariant 6 of CLAUDE.md: never claim a cloud is validated without a
# run.
#
# PORTABILITY.md already has the discipline. It says so itself: in the GCP
# column, bold was measured on a live cluster, italics was established at a desk
# with nothing running and nothing spent, and blank means it needs more of the
# run. The Hetzner column is the baseline and the AWS column carries its own run
# date and an evidence file, so both are measured throughout.
#
# What was missing is anything keeping that true. A new row added as plain text
# in the GCP column reads as measured to everyone who skims, and skimming is
# what a comparison sheet is for. This repository has already learned that a
# number in a document is a claim with no owner; a formatting convention is the
# same thing with fewer characters.
#
# HEADER ROWS ARE FOUND EXACTLY, not guessed. A markdown header is the row
# immediately above the `|---|` delimiter. The first draft of this check guessed
# by looking for provider names in cells and reported the silicon-comparison
# header as an unmarked claim, because its cells name machine types.
#
# This file is the ONE copy of this check.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

python3 - <<'PY'
import pathlib
import re
import sys

doc = pathlib.Path("PORTABILITY.md")
lines = doc.read_text().splitlines()
problems = []

try:
    start = next(i for i, l in enumerate(lines) if l.startswith("## 3."))
except StopIteration:
    print("FAIL: PORTABILITY.md has no section 3, so the comparison sheet was not checked")
    sys.exit(1)

# A markdown header row is the one directly above the delimiter.
headers = {
    i - 1
    for i, l in enumerate(lines)
    if re.match(r"^\s*\|(\s*:?-{3,}:?\s*\|)+\s*$", l)
}

checked = 0
for i in range(start, len(lines)):
    line = lines[i]
    if not line.strip().startswith("|"):
        continue
    if i in headers or re.match(r"^\s*\|(\s*:?-{3,}:?\s*\|)+\s*$", line):
        continue

    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 4:
        continue

    gcp = cells[3]
    if not gcp:
        continue  # blank means "needs more of the run", which is the honest state
    checked += 1
    if not gcp.startswith(("**", "_", "*")):
        problems.append(
            f"PORTABILITY.md:{i + 1} the GCP cell {gcp[:48]!r} is neither bold nor "
            f"italic. Bold means measured on a live cluster, italics means "
            f"established at a desk with nothing spent, blank means it needs the "
            f"run. Plain text reads as measured to everybody who skims, and "
            f"skimming is what a comparison sheet is for."
        )

if checked == 0:
    problems.append("no GCP cells were inspected at all, so this check measured nothing")

# Every provider's claims must be datable.
for provider, pattern in (
    ("Hetzner", r"Written (\d{4}-\d{2}-\d{2})"),
    ("AWS", r"Run on (\d{4}-\d{2}-\d{2})"),
    ("GCP", r"at a desk on (\d{4}-\d{2}-\d{2})"),
):
    if not re.search(pattern, "\n".join(lines)):
        problems.append(
            f"the {provider} column has no dated provenance line matching "
            f"/{pattern}/. A cloud claim without a date cannot be told from one "
            f"that was true a year ago."
        )

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print()
    print("See CLAUDE.md invariant 6.")
    sys.exit(1)

print(f"OK: {checked} GCP claims, every one marked measured or desk-established;")
print("    all three provider columns carry a dated provenance line.")
PY
