#!/usr/bin/env bash
# CLAUDE.md invariant 71. A failed pack ends the record-seal run non-zero, with trailryx-node's own words in the log.
# The one exception is the case trailryx-node reports as "there is nothing sealed here to pack": that run exits 0,
# prints the known line, and does not verify. Before this rule the job's fallback exited 0 on every failure, so a
# run that sealed nothing read as a quiet night (GOTCHAS 90 is the same shape, found on a live cluster).
#
# WHAT THIS CHECKS
#
#   1. manifests/40-routines-and-secrets.yaml, the record-seal CronJob: its script is read from the manifest and run
#      here by sh, with stand-in trailryx-node and trailryx-verify on PATH, no network, no write under /var/lib and
#      no cluster.
#   2. Four runs, each over one event file so the import loop runs:
#        ok      the pack succeeds: exit 0, and the verifier runs on it;
#        empty   the pack reports nothing sealed: exit 0, the known line printed, and no verifier run;
#        failed  the pack fails for another reason, whose message also contains the word "nothing": exit non-zero,
#                the reason printed, and the known line NOT printed;
#        absent  the CronJob, or its pack step, is not in the manifest: measured NOTHING, never a pass.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp" <<'PY'
import os
import re
import subprocess
import sys

tmp = sys.argv[1]
bad = []
MANIFEST = "manifests/40-routines-and-secrets.yaml"

try:
    text = open(MANIFEST).read()
except OSError:
    print(f"FAIL {MANIFEST} is absent: the record-seal is measured NOTHING")
    sys.exit(1)

docs = re.split(r"\n---\s*\n", text)
seal = next((d for d in docs if re.search(r"^kind: CronJob\s*$", d, re.M)
             and re.search(r"^  name: record-seal\s*$", d, re.M)), None)
if seal is None:
    print("FAIL manifests/40-routines-and-secrets.yaml has no record-seal CronJob: the pack is measured NOTHING")
    sys.exit(1)

lines = seal.split("\n")
idx = None
for k, l in enumerate(lines):
    if l.strip() == "args:" and k + 1 < len(lines) and lines[k + 1].strip() == "- |":
        idx = k + 1
        break
if idx is None:
    print("FAIL the record-seal CronJob has no `args: - |` script: the pack is measured NOTHING")
    sys.exit(1)
body_indent = (len(lines[idx]) - len(lines[idx].lstrip())) + 2
body = []
for l in lines[idx + 1:]:
    if l.strip() == "":
        body.append("")
        continue
    if len(l) - len(l.lstrip()) < body_indent:
        break
    body.append(l[body_indent:])
script = "\n".join(body) + "\n"
if "trailryx-node read" not in script or "trailryx-verify" not in script:
    print("FAIL the record-seal script has no pack step (trailryx-node read, then trailryx-verify): measured NOTHING")
    sys.exit(1)

script_path = os.path.join(tmp, "seal.sh")
with open(script_path, "w") as f:
    f.write(script)

bindir = os.path.join(tmp, "bin")
os.makedirs(bindir)
NODE = """#!/bin/sh
case "$1" in
  events) exit 0 ;;
  read)
    echo "read" >> "$STUB_LOG"
    case "$STUB_PACK" in
      ok) echo "pack written"; exit 0 ;;
      empty) echo "trailryx-node: there is nothing sealed here to pack" >&2; exit 2 ;;
      failed) echo "trailryx-node: nothing was written to /var/lib/stack/records: Permission denied (os error 13)" >&2; exit 2 ;;
    esac ;;
esac
echo "stub: unexpected $*" >&2
exit 9
"""
VERIFY = """#!/bin/sh
echo "verified" >> "$STUB_LOG"
exit 0
"""
for name, body_text in (("trailryx-node", NODE), ("trailryx-verify", VERIFY)):
    p = os.path.join(bindir, name)
    with open(p, "w") as f:
        f.write(body_text)
    os.chmod(p, 0o755)

events = os.path.join(tmp, "events")
os.makedirs(events)
with open(os.path.join(events, "bus.ndjson"), "w") as f:
    f.write("{}\n")


def run(mode):
    log = os.path.join(tmp, "log-" + mode)
    env = {"PATH": bindir + ":/usr/bin:/bin", "EVENTS_DIR": events,
           "TRAILRYX_TRUST_DOMAIN": "test.invalid", "STUB_PACK": mode, "STUB_LOG": log}
    p = subprocess.run(["sh", script_path], env=env, capture_output=True, text=True, timeout=20)
    seen = open(log).read() if os.path.exists(log) else ""
    return p.returncode, p.stdout + p.stderr, seen


KNOWN = "nothing sealed here to pack yet"

rc, out, seen = run("ok")
if rc != 0 or "verified" not in seen:
    bad.append(f"a pack that succeeds does not end the run zero with its verifier run (exit {rc})")

rc, out, seen = run("empty")
if rc != 0 or KNOWN not in out:
    bad.append(f"the known empty case does not exit 0 with its line when nothing is sealed (exit {rc})")
if "verified" in seen:
    bad.append("the verifier runs on a pack that was never written")

rc, out, seen = run("failed")
if rc == 0:
    bad.append("a failed pack exits 0 (the run reads as a quiet night)")
if "Permission denied" not in out:
    bad.append("a failed pack does not say why in the log")
if KNOWN in out:
    bad.append("a failed pack prints the known empty line, so a real failure reads as nothing to seal")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 71.")
    sys.exit(1)
print("OK: a failed pack ends the record-seal run non-zero with its reason in the log; only the known empty case exits 0, without verifying (four stand-in runs).")
PY
