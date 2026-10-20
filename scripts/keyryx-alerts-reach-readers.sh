#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 75: the Keyryx witness's findings reach the console and
# heraldyx, the two readers see them through a read-only mount, and the witness never
# writes the bus it witnesses.
#
# WHY
#
# The witness exists to notice when a stream on the bus, or a sealed record, was
# rewritten after it was seen. A witness that could write the bus could add lines to
# the record it vouches for. So its findings are a file of their own, keyryx.ndjson, on
# a claim of their own, keyryx-alerts, and the readers that turn a finding into a mail or
# an incident mount that claim read only. Until this, the file sat on the witness's own
# ReadWriteOnce state claim, and no other pod read it.
#
# WHAT THIS CHECKS (manifests/00-base.yaml, keyryx/manifests/59-keyryx.yaml, and every
# tracked YAML document that mounts the claim)
#
#   1. the claim keyryx-alerts exists, ReadWriteMany, on the stack-rwx class, and is not
#      the bus claim stack-events;
#   2. the witness names its findings file in KEYRYX_WITNESS_ALERTS, the file is called
#      keyryx.ndjson (the stem heraldyx 0.8.0 reads as source keyryx), it is not under the
#      bus directory, and it sits under the witness's read-write mount of keyryx-alerts;
#   3. the witness mounts stack-events read only, and no claim read-write but its own
#      state and keyryx-alerts;
#   4. every other pod that mounts keyryx-alerts mounts it read only, on the volume and on
#      every mount of it;
#   5. the console and heraldyx each mount it and are told to read the file there: the
#      console by an entry of GENARYX_EVENTS_EXTRA, heraldyx by an entry of HERALDYX_EVENTS
#      (the file, or its directory), and each runs in the bus group 10001 the file is
#      created in.
#
# That the file is created before the witness starts, by its own uid, mode 0640, is
# invariant 59's gate (scripts/stream-files-are-precreated.sh), which lists the witness.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import os
import posixpath
import re
import subprocess
import sys

CLAIM = "keyryx-alerts"
BUS = "/var/lib/stack/events"
NAME = "keyryx.ndjson"
READERS = [
    ("manifests/20-console.yaml", "Deployment", "genaryx-console", "GENARYX_EVENTS_EXTRA"),
    ("manifests/45-heraldyx.yaml", "Deployment", "heraldyx", "HERALDYX_EVENTS"),
]
WITNESS = ("keyryx/manifests/59-keyryx.yaml", "Deployment", "keyryx-witness")


def nothing(msg):
    print(f"keyryx-alerts: {msg}, so this gate measured NOTHING")
    sys.exit(1)


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


def docs_of(path):
    if not os.path.exists(path):
        return None
    return [live(d) for d in re.split(r"\n---\s*\n", open(path).read())]


def find(path, kind, name):
    for d in docs_of(path) or []:
        if re.search(rf"^kind:\s*{kind}\s*$", d, re.M) and re.search(rf"^  name:\s*{re.escape(name)}\s*$", d, re.M):
            return d
    return None


def items(doc):
    """Every YAML list item, block or flow style, as (text, indent)."""
    ls = doc.split("\n")
    out = []
    for i, line in enumerate(ls):
        m = re.match(r"^(\s*)- (.*)$", line)
        if not m:
            continue
        ind = len(m.group(1))
        body = [line]
        for nxt in ls[i + 1:]:
            if not nxt.strip():
                continue
            if len(nxt) - len(nxt.lstrip(" ")) <= ind:
                break
            body.append(nxt)
        out.append(("\n".join(body), ind))
    return out


def field(text, key):
    """A key's value, quoted (commas allowed inside) or bare, in block or flow style."""
    m = re.search(rf"(?:^|[{{,\s]){key}:\s*\"([^\"\n]*)\"", text, re.M)
    if m:
        return m.group(1).strip()
    m = re.search(rf"(?:^|[{{,\s]){key}:\s*([^\",}}\n]+?)\s*(?:[,}}]|$)", text, re.M)
    return m.group(1).strip() if m else None


def first_name(text):
    m = re.match(r"^\s*- (?:\{\s*)?name:\s*\"?([A-Za-z0-9._-]+)", text)
    return m.group(1) if m else None


def volumes_for(doc, claim):
    """(volume name, pvc readOnly) for each volume of doc whose claim is `claim`."""
    out = []
    for text, _ in items(doc):
        if "persistentVolumeClaim" not in text or "mountPath" in text:
            continue
        if field(text, "claimName") == claim:
            out.append((first_name(text), field(text, "readOnly") == "true"))
    return out


def mounts_of(doc, vname):
    out = []
    for text, _ in items(doc):
        if "mountPath" in text and first_name(text) == vname and "persistentVolumeClaim" not in text:
            out.append((field(text, "mountPath"), field(text, "readOnly") == "true"))
    return out


def env_value(doc, var):
    for text, _ in items(doc):
        if first_name(text) == var:
            v = field(text, "value")
            if v is not None:
                return v
    return None


def in_bus_group(doc):
    return bool(re.search(r"\bfsGroup:\s*10001\b|supplementalGroups:\s*\[[^\]]*\b10001\b|\brunAsGroup:\s*10001\b", doc))


bad = []

# 1. the claim
base = docs_of("manifests/00-base.yaml")
if base is None:
    nothing("manifests/00-base.yaml is absent")
pvc = next((d for d in base if re.search(r"^kind:\s*PersistentVolumeClaim\s*$", d, re.M)
            and re.search(rf"^  name:\s*{CLAIM}\s*$", d, re.M)), None)
if pvc is None:
    nothing(f"no PersistentVolumeClaim {CLAIM} in manifests/00-base.yaml")
if "ReadWriteMany" not in pvc:
    bad.append(f"the claim {CLAIM} is not ReadWriteMany, so a reader on another node cannot mount it")
if not re.search(r"storageClassName:\s*stack-rwx\b", pvc):
    bad.append(f"the claim {CLAIM} is not on the stack-rwx class")

# 2. and 3. the witness
wit = find(*WITNESS)
if wit is None:
    nothing("the keyryx-witness Deployment is absent")
alerts = env_value(wit, "KEYRYX_WITNESS_ALERTS")
if not alerts:
    bad.append("the witness names no KEYRYX_WITNESS_ALERTS, so keyryx writes its findings into the bus it reads")
    alerts = ""
if alerts and (alerts == BUS or alerts.startswith(BUS + "/")):
    bad.append(f"the witness writes its findings to {alerts}, on the bus it witnesses")
if alerts and posixpath.basename(alerts) != NAME:
    bad.append(f"the findings file is {posixpath.basename(alerts)}, not {NAME}: heraldyx reads source keyryx only from a file of that stem")
wvols = volumes_for(wit, CLAIM)
wmount = None
for vname, _ in wvols:
    for mp, ro in mounts_of(wit, vname):
        if alerts and (alerts.startswith(mp.rstrip("/") + "/")):
            wmount = (mp, ro)
if not wvols:
    bad.append(f"the witness does not mount the claim {CLAIM}")
elif wmount is None:
    bad.append(f"the witness's findings file {alerts} is not under its mount of {CLAIM}")
elif wmount[1]:
    bad.append(f"the witness mounts {CLAIM} read only, so it cannot write its findings")
for text, _ in items(wit):
    if "persistentVolumeClaim" not in text:
        continue
    claim, vname = field(text, "claimName"), first_name(text)
    for mp, ro in mounts_of(wit, vname):
        if claim == "stack-events" and not ro:
            bad.append("the witness mounts stack-events read-write: it writes the bus it witnesses")
        elif claim not in ("stack-events", "keyryx-witness-state", CLAIM) and not ro:
            bad.append(f"the witness mounts {claim} read-write, beside its state and its findings")

# 4. nobody else writes the findings
files = subprocess.run(["git", "ls-files", "*.yaml", "*.yml"], capture_output=True, text=True).stdout.split()
mounters = []
for f in files:
    if f.startswith(("evidence/", "docs/", "features/", ".github/")):
        continue
    for d in docs_of(f) or []:
        if not re.search(rf"claimName:\s*{CLAIM}(?![\w.-])", d):
            continue
        kind = re.search(r"^kind:\s*(\S+)\s*$", d, re.M)
        if not kind or kind.group(1) not in ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod"):
            continue
        name = re.search(r"^  name:\s*(\S+)\s*$", d, re.M)
        mounters.append((f, kind.group(1), name.group(1) if name else "?", d))
for f, kind, name, d in mounters:
    if (f, kind, name) == WITNESS:
        continue
    for vname, pvc_ro in volumes_for(d, CLAIM):
        if not pvc_ro:
            bad.append(f"{f}: {kind} {name} mounts the claim {CLAIM} without readOnly: true on the volume")
        for mp, ro in mounts_of(d, vname):
            if not ro:
                bad.append(f"{f}: {kind} {name} mounts {CLAIM} read-write at {mp}: only the witness writes its findings, readers read only")

# 5. the readers read it
rel = posixpath.relpath(alerts, wmount[0]) if (alerts and wmount) else NAME
for path, kind, name, var in READERS:
    d = find(path, kind, name)
    if d is None:
        nothing(f"{path}: the {kind} {name} is absent")
    vols = volumes_for(d, CLAIM)
    if not vols:
        bad.append(f"{name} does not mount the claim {CLAIM}, so it does not read the witness's findings")
        continue
    there = None
    for vname, _ in vols:
        for mp, _ in mounts_of(d, vname):
            there = posixpath.join(mp, rel)
    entries = [e.strip() for e in (env_value(d, var) or "").split(",") if e.strip()]
    if there is None or not any(e == there or there.startswith(e.rstrip("/") + "/") for e in entries):
        bad.append(f"{name} does not read the witness's findings: {var} names {', '.join(entries) or 'nothing'}, not {there}")
    if not in_bus_group(d):
        bad.append(f"{name} is not in the bus group 10001, which the findings file is created in")

if bad:
    for b in bad:
        print("FAIL keyryx-alerts: " + b)
    sys.exit(1)
print(f"OK: the witness writes {alerts} on the claim {CLAIM}; the console and heraldyx mount it read only and read it;")
print(f"    the witness mounts the bus read only, and no other pod writes its findings ({len(mounters)} pod(s) mount the claim)")
PY
