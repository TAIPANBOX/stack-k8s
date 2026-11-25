#!/usr/bin/env bash
# CLAUDE.md invariant 96. Every container that reads the whole events bus has a memory limit of at least 1Gi.
#
# WHY
#
# The bus is never rotated, so what a reader of every stream holds grows with the cluster's age. On forge
# (stack-single, 2026-11-25) the keyryx witness was killed at its 256 MiB ceiling in a loop while it re-hashed the
# bus, and the install's checks failed. Here the witness had 512Mi, the chain verifier 256Mi and heraldyx 128Mi:
# the same failure, later.
#
# WHAT THIS CHECKS: for each (file, container) in READERS, the container exists and its `limits` memory is at least
# 1Gi. An absent container or limit is reported, never passed.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re, sys

READERS = [
    ("keyryx/manifests/59-keyryx.yaml", "keyryx-witness", "re-hashes every stream to witness its chain"),
    ("manifests/40-routines-and-secrets.yaml", "agent-conform", "re-reads every stream to check its prev_hash chain"),
    ("manifests/40-routines-and-secrets.yaml", "trailryx", "seals the whole bus into the record"),
    ("manifests/40-routines-and-secrets.yaml", "idryx-rescan", "loads every stream it scores"),
    ("manifests/45-heraldyx.yaml", "heraldyx", "reads every stream it alerts on"),
]
UNIT = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024}
bad = []
for path, name, why in READERS:
    text = open(path).read()
    m = re.search(r"^(\s+)- name: %s\n" % re.escape(name), text, re.M)
    if not m:
        bad.append("%s: no container %s, so its memory limit measured NOTHING" % (path, name))
        continue
    indent = len(m.group(1))
    rest = text[m.end():]
    end = re.search(r"^ {0,%d}- name: " % indent, rest, re.M)
    block = rest[:end.start()] if end else rest
    lim = re.search(r"limits: \{[^}]*memory: (\d+)(Ki|Mi|Gi)", block)
    if not lim:
        bad.append("%s: container %s has no memory limit" % (path, name))
        continue
    mib = int(lim.group(1)) * UNIT[lim.group(2)]
    if mib < 1024:
        bad.append("%s: container %s is limited to %s%s, below 1Gi, and it %s on a bus that is never rotated"
                   % (path, name, lim.group(1), lim.group(2), why))
if bad:
    for b in bad:
        print("FAIL bus-readers: " + b)
    sys.exit(1)
print("OK: bus-readers (invariant 96): %d readers of the whole bus each have at least 1Gi of memory" % len(READERS))
PY
