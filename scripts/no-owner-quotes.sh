#!/usr/bin/env bash
# CLAUDE.md invariant 34: this repository is public, and it carries no quote of
# the owner, no `@<owner>` provenance marker and no "<owner> said / asked /
# decided" attribution.
#
# WHY
#
# A decision still has to be recorded, because a later reader must know it is
# not to be re-derived. The public form is `@decided YYYY-MM-DD` followed by a
# paraphrase, never edited afterwards. The verbatim words, and the marker that
# names the person, live in private places only. Until 2026-10-08 nothing held
# that here, and 16 findings in 8 files had accumulated: four owner markers
# (GOTCHAS.md, components.json, a manifest comment, a range-run plan), two
# quotes, three more mentions by name, and Ukrainian text in two documents.
#
# WHAT THIS CHECKS
#
# Every text file `git ls-files` lists (a file with a NUL byte is binary and
# skipped), every line:
#
#   - the owner's provenance marker, `@` and the first name, any case;
#   - any Cyrillic letter: the owner writes in Ukrainian, this repository is in
#     English, and Cyrillic here has only ever been a quote, a file name from a
#     private note, or a probe's output that belongs translated;
#   - a guillemet, the quotation mark those quotes are written in;
#   - the owner's first name or surname as a word, unless the line is a
#     copyright, author or maintainer line. A name as the copyright holder is
#     ownership, not a quote; anywhere else in a public file it has only ever
#     been an attribution ("<name>'s call", "in <name>'s words").
#
# The name is built from pieces below so this file does not trip itself, and
# the harness plants its faults the same way.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no tracked text file at all is a
# failure that says it measured nothing.
#
# WHAT IT DOES NOT DO. It cannot see a quote in English with no name beside it
# ("he said 'do it all'"), a paraphrase that is really a quote, or anything in
# git history: a rewrite here leaves the old text in earlier commits.
set -uo pipefail
# The repository this file lives in (it sits in scripts/), whatever directory it
# was called from. Not `git rev-parse --show-toplevel` from inside scripts/: in a
# git hook GIT_DIR is set, and then the top level is wherever the shell stands.
cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import re
import subprocess
import sys

FIRST = "Yur" + "ii"
LAST = "Kost" + "iuk"

marker = re.compile("@" + FIRST.lower() + r"\b", re.I)
cyrillic = re.compile("[\u0400-\u052f]")
guillemet = re.compile("[\u00ab\u00bb]")
name = re.compile(r"\b(" + FIRST + "|" + LAST + r")\b", re.I)
ownership = re.compile(r"copyright|\u00a9|\(c\)|\bauthors?\b|\bmaintainers?\b", re.I)

out = subprocess.run(["git", "ls-files", "-z"], capture_output=True)
if out.returncode != 0:
    print("FAIL: git ls-files failed, so this gate measured NOTHING.")
    sys.exit(1)
paths = [p for p in out.stdout.decode("utf-8", "replace").split("\0") if p]

scanned = 0
problems = []
for p in paths:
    try:
        raw = open(p, "rb").read()
    except OSError:
        continue
    if b"\0" in raw:
        continue
    scanned += 1
    for no, line in enumerate(raw.decode("utf-8", "replace").split("\n"), 1):
        kinds = []
        if marker.search(line):
            kinds.append("the owner's provenance marker (write `@decided YYYY-MM-DD` and a paraphrase)")
        if cyrillic.search(line):
            kinds.append("Cyrillic text (a quote, or something that belongs translated)")
        if guillemet.search(line):
            kinds.append("a guillemet, the quotation mark of a quote")
        if name.search(line) and not ownership.search(line):
            kinds.append("the owner's name outside a copyright or author line (an attribution)")
        for k in kinds:
            problems.append(f"{p}:{no}: {k}")

if scanned == 0:
    print("FAIL: no tracked text file was found, so this gate measured NOTHING.")
    sys.exit(1)
if problems:
    for m in problems:
        print("FAIL: " + m)
    print()
    print(f"{len(problems)} problem(s) in {scanned} tracked text files. A public repository carries no")
    print("quote of the owner and no attribution by name; record the decision as `@decided")
    print("YYYY-MM-DD` and a paraphrase. See CLAUDE.md invariant 34.")
    sys.exit(1)
print(f"OK: {scanned} tracked text files, no owner marker, no Cyrillic, no guillemet, and the owner's")
print("    name only on a copyright or author line. See CLAUDE.md invariant 34.")
PY
