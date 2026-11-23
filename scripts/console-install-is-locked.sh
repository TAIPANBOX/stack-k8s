#!/usr/bin/env bash
#
# Enforces CLAUDE.md invariant 93: the console's web assets install only from their lockfile, with a
# pnpm pinned by version and by the sha512 of its tarball.
#
# WHY
#
# Until 2026-11-23 images/console.Dockerfile copied `pnpm-lock.yam[l]`, a glob that matches nothing
# without failing, and ran `pnpm install --frozen-lockfile || npm install`. A missing lockfile, or one
# the frozen install refused, fell through to `npm install`, which resolves every range in
# package.json against the registry of that day. The console image is published under a version tag
# and signed, so the tag would have named a different set of JavaScript dependencies from one build to
# the next, with nothing in the build log but a warning. `corepack enable` alone also took whichever
# pnpm the base image's corepack chose.
#
# WHAT THIS CHECKS, in every stage of every images/*Dockerfile* that installs JavaScript packages
#
#   1. The lockfile is copied by its literal name, `pnpm-lock.yaml`, with no glob character, so a
#      missing lockfile stops the build at the COPY.
#   2. The install is `pnpm install --frozen-lockfile`, and nothing on that RUN line can install
#      otherwise: no `npm install`, `npm ci`, `yarn`, no `||` fallback and no `pnpm install` without
#      --frozen-lockfile.
#   3. pnpm is activated through `corepack prepare pnpm@<x.y.z>+sha512.<128 hex> --activate`, before
#      the install, on the same RUN line.
#
# A Dockerfile set with no JavaScript install at all is "measured NOTHING", never a pass.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import glob
import re
import sys

files = sorted(f for f in glob.glob("images/*Dockerfile*"))
if not files:
    print("FAIL: no images/*Dockerfile*, so this gate measured NOTHING.")
    sys.exit(1)

INSTALLS = re.compile(r"\b(?:pnpm|npm|yarn)\s+(?:install|ci|add)\b|\byarn\b(?!\.lock)")
problems = []
subjects = 0
for path in files:
    text = open(path).read()
    # Join continuation lines so one RUN instruction is one string; drop comment lines.
    logical = re.sub(r"\\\n", " ", "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#")))
    stages = re.split(r"(?im)^\s*FROM\s", logical)
    for stage in stages[1:]:
        name = stage.split("\n", 1)[0].strip()
        runs = re.findall(r"(?im)^\s*RUN\s+(.+)$", stage)
        js = [r for r in runs if INSTALLS.search(r)]
        if not js:
            continue
        subjects += 1
        where = f"{path}, stage `{name}`"
        copies = re.findall(r"(?im)^\s*COPY\s+(.+)$", stage)
        lock_copies = [c for c in copies if "pnpm-lock" in c]
        if not lock_copies:
            problems.append(f"{where}: installs packages and copies no pnpm-lock.yaml")
        for c in lock_copies:
            for src in c.split()[:-1]:
                if "pnpm-lock" in src and (re.search(r"[\[\]*?]", src) or not src.endswith("/pnpm-lock.yaml") and src != "pnpm-lock.yaml"):
                    problems.append(f"{where}: copies the lockfile as {src!r}, a pattern a missing file passes; name pnpm-lock.yaml literally")
        for r in js:
            if re.search(r"\|\|", r):
                problems.append(f"{where}: the install line carries an `||` fallback: {r.strip()[:160]}")
            if re.search(r"\bnpm\s+(?:install|ci)\b|\byarn\b", r):
                problems.append(f"{where}: installs with npm or yarn, which does not read pnpm-lock.yaml: {r.strip()[:160]}")
            for m in re.finditer(r"\bpnpm\s+install\b([^&|;]*)", r):
                if "--frozen-lockfile" not in m.group(1):
                    problems.append(f"{where}: `pnpm install` without --frozen-lockfile, so the lockfile can be rewritten in the build")
            prep = re.search(r"corepack\s+prepare\s+pnpm@(\S+)\s+--activate", r)
            if not prep:
                problems.append(f"{where}: pnpm is not activated by `corepack prepare pnpm@<version>+sha512.<hash> --activate` on the install line")
            else:
                if not re.fullmatch(r"\d+\.\d+\.\d+\+sha512\.[0-9a-f]{128}", prep.group(1)):
                    problems.append(f"{where}: pnpm is pinned as {prep.group(1)!r}, not as an exact version with the sha512 of its tarball")
                inst = re.search(r"\bpnpm\s+install\b", r)
                if inst and inst.start() < prep.start():
                    problems.append(f"{where}: pnpm installs before corepack activates the pinned pnpm")

if subjects == 0:
    print("FAIL: no Dockerfile stage under images/ installs JavaScript packages, so this gate measured NOTHING.")
    sys.exit(1)
if problems:
    for p in problems:
        print("FAIL: " + p)
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 93.")
    sys.exit(1)
print(f"OK: {subjects} stage(s) install JavaScript packages only from pnpm-lock.yaml, with a frozen install "
      "and a pnpm pinned by version and sha512.")
PY
