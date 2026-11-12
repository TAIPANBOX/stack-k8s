#!/usr/bin/env bash
# CLAUDE.md invariant 59: every stream file a Go writer appends to on a volume of its own (a journal,
# a revocation list, the witness's findings) is created before the writer starts, by an init container
# that runs as the writer's own uid, mode 0640; and every pod that mounts the events bus is in the bus
# group 10001 (fsGroup or supplementalGroups), the group that may enter and read it.
#
# The streams ON the bus are not in this table since invariant 89 (GAPS G3.16): the bus owner makes
# each of them, 20000:<producer gid> 0664, before any plane starts, and
# scripts/bus-writers-are-separate.sh holds that. A precreate init on the bus could not work any more:
# the planes mount streams/ by subPath, and nothing but the owner may create a name in it.
#
# WHY
#
# agent-stack-go v2 (event/create.go) creates a missing stream file only when its directory belongs
# to the process. The volume root belongs to root, so a writer with no file yet refuses to start
# (wardryx v2.2.1 exits 1 with "does not exist and its directory is not owned by this process"),
# and agent-conform's bus verifier exits 2 at its first finding. An existing file is opened as it
# is. So the file is made up front, by the writer's own uid, which needs no root and which Pod
# Security `restricted` allows. stack-single does the same with a root init service, which a
# restricted namespace cannot run. GOTCHAS 135.
#
# WHAT THIS CHECKS
#
#   1. Every writer in WRITERS: its object exists, its pod has an init container named
#      precreate-streams that runs busybox by digest, as the writer's uid and never as root, in the
#      group named in the table, mounts the volume the file lives on, and creates the exact path
#      (umask 027 or chmod 0640). The writer's pod runs as the uid the table names.
#   2. Every pod that mounts the stack-events claim is in group 10001, the group the bus files are
#      created in. The pods are FOUND, not listed: every tracked YAML document that is a pod-bearing
#      object (Deployment, StatefulSet, DaemonSet, Job, CronJob, Pod) with a volume whose
#      persistentVolumeClaim names stack-events. A pod that mounts it without the group fails, unless
#      it is in EXCEPTIONS with the reason it does not need the group. An exception that now complies,
#      or that matches no pod, fails too: the list never outlives the pod it describes. A pod counts
#      as in the group when the pod-level securityContext has fsGroup 10001, supplementalGroups with
#      10001, or runAsGroup 10001; a container-level runAsGroup is not counted (named limit).
#
# keyryx-witness is a writer here since invariant 75: its findings file, alerts/keyryx.ndjson on its own
# claim keyryx-witness-state, is read by the console and heraldyx through a subPath mount of alerts/, so
# the file and its directory are made up front, like the bus files, before either reader can mount them.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import subprocess
import sys

# file, kind, object name, the file the writer appends to, the uid it appends as,
# the group the file is created in, the volume it lives on
WRITERS = [
    # vouchryx's revocation list, on its own claim (fsGroup 65532 keeps the files an earlier uid wrote
    # writable to the group), as vouchryx's own uid since invariant 89.
    ("54-delegation.yaml", "Deployment", "vouchryx", "/var/lib/stack/delegation/revocations.ndjson", 20002, 20002, "delegation-state"),
    # heraldyx opens its own dispatch journal on its state volume with the same writer, so a fresh
    # volume (no file yet, root-owned directory) cannot open its journal without this, and runs
    # on with no record of what it sent (GOTCHAS 136).
    ("45-heraldyx.yaml", "Deployment", "heraldyx", "/var/lib/stack/heraldyx/sent.ndjson", 65532, 65532, "state"),
    ("47-scopyx.yaml", "Deployment", "scopyx", "/var/lib/scopyx/events.ndjson", 65532, 65532, "journal"),
    ("48-scopyx-browser.yaml", "Deployment", "scopyx", "/var/lib/scopyx/events.ndjson", 65532, 65532, "journal"),
    # The Keyryx witness's findings (CLAUDE.md invariant 75), on its own state claim and not the bus; the
    # console and heraldyx read it in group 10001.
    ("keyryx/manifests/59-keyryx.yaml", "Deployment", "keyryx-witness", "/var/lib/keyryx-witness/alerts/keyryx.ndjson", 20100, 10001, "keyryx-witness-state"),
]

# Pods that mount the stack-events claim WITHOUT group 10001, each with the reason it does not need it.
# Keyed by repository-relative file, kind and object name. Every entry must still mount the claim and
# still lack the group, or the gate says so. Empty since invariant 89: a plane that writes the bus must
# enter streams/, which only the bus group may, so costcrew, costcrew-crew and vouchryx joined it.
EXCEPTIONS = {}


def discovered_mounters():
    """Pod-bearing objects in every tracked YAML document that mount the stack-events claim, found by
    what they are: a volume whose persistentVolumeClaim names the claim, in a non-comment line."""
    files = subprocess.run(["git", "ls-files", "*.yaml", "*.yml"], capture_output=True, text=True).stdout.split()
    found = []
    for f in files:
        if f.startswith(("evidence/", "docs/", "features/", ".github/")):
            continue
        try:
            text = open(f).read()
        except (OSError, UnicodeDecodeError):
            continue
        for d in re.split(r"\n---\s*\n", text):
            live = "\n".join(l for l in d.split("\n") if not l.lstrip().startswith("#"))
            if not re.search(r"claimName:\s*stack-events(?![\w.-])", live):
                continue
            kind = re.search(r"^kind:\s*(\S+)\s*$", live, re.M)
            if not kind or kind.group(1) not in ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pod"):
                continue
            name = re.search(r"^  name:\s*(\S+)\s*$", live, re.M)
            found.append((f, kind.group(1), name.group(1) if name else "?", live))
    return found


def in_group_10001(doc):
    ind = containers_indent(doc)
    sc = block(doc, "securityContext", ind) if ind is not None else None
    if not sc:
        return False
    return bool(re.search(r"\bfsGroup:\s*10001\b|supplementalGroups:\s*\[[^\]]*\b10001\b|\brunAsGroup:\s*10001\b", sc))

bad = []
docs_cache = {}


def docs_of(path):
    if path not in docs_cache:
        full = path if os.path.exists(path) else os.path.join("manifests", path)
        if not os.path.exists(full):
            docs_cache[path] = None
        else:
            docs_cache[path] = re.split(r"\n---\s*\n", open(full).read())
    return docs_cache[path]


def find(path, kind, name):
    docs = docs_of(path)
    if docs is None:
        return None
    for d in docs:
        if re.search(rf"^kind:\s*{kind}\s*$", d, re.M) and re.search(rf"^  name:\s*{re.escape(name)}\s*$", d, re.M):
            return d
    return None


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def containers_indent(doc):
    m = re.search(r"^( *)containers:\s*$", doc, re.M)
    return len(m.group(1)) if m else None


def block(doc, key, ind):
    """The text of `key:` at exactly `ind` spaces (flow style is one line) and the deeper lines under it.
    Comment and blank lines are skipped, so a comment can never be read as a setting."""
    ls = doc.split("\n")
    for i, line in enumerate(ls):
        if line.startswith(" " * ind + key + ":") and indent_of(line) == ind:
            out = [line]
            for nxt in ls[i + 1:]:
                s = nxt.strip()
                if s == "" or s.startswith("#"):
                    continue
                if indent_of(nxt) > ind:
                    out.append(nxt)
                else:
                    break
            return "\n".join(out)
    return None


def init_entry(init, name):
    """The one list item of an initContainers block whose name is `name`, up to the next item."""
    if init is None:
        return None
    ls = init.split("\n")
    for i, line in enumerate(ls):
        if re.match(rf"^\s*- name:\s*{re.escape(name)}\s*$", line):
            item_ind = indent_of(line)
            out = [line]
            for nxt in ls[i + 1:]:
                s = nxt.strip()
                if s and indent_of(nxt) == item_ind and s.startswith("- "):
                    break
                if s and indent_of(nxt) < item_ind:
                    break
                out.append(nxt)
            return "\n".join(out)
    return None


for path, kind, name, target, uid, gid, vol in WRITERS:
    doc = find(path, kind, name)
    label = f"{path}: {kind} {name} -> {target}"
    if doc is None:
        bad.append(f"{label}: the object is absent, so this writer is measured NOTHING")
        continue
    ind = containers_indent(doc)
    if ind is None:
        bad.append(f"{label}: no containers block, so this writer is measured NOTHING")
        continue
    pod_sc = block(doc, "securityContext", ind)
    entry = init_entry(block(doc, "initContainers", ind), "precreate-streams")
    if entry is None:
        bad.append(f"{label}: no precreate-streams init container creates the file before the writer starts")
        continue
    if not re.search(r"image: busybox@sha256:[0-9a-f]{64}", entry):
        bad.append(f"{label}: the init container does not run busybox by digest")
    if target not in entry:
        bad.append(f"{label}: the init container does not create {target}")
    if not re.search(r"umask 027|chmod 0640", entry):
        bad.append(f"{label}: the init container does not set the file to 0640")
    if re.search(r"runAsUser:\s*0\b", entry):
        bad.append(f"{label}: the init container runs as root")
    m = re.search(r"runAsUser:\s*(\d+)", entry)
    if not m or int(m.group(1)) != uid:
        bad.append(f"{label}: the init container does not run as the writer's uid {uid}")
    m = re.search(r"runAsGroup:\s*(\d+)", entry)
    if not m or int(m.group(1)) != gid:
        bad.append(f"{label}: the init container does not create the file in group {gid}")
    if not re.search(rf"name:\s*{re.escape(vol)}\b", entry):
        bad.append(f"{label}: the init container does not mount the volume {vol}")
    # The mount is the file's directory, or an ancestor of it when the init makes the directory itself
    # (the Keyryx witness's alerts/, on its own state claim, invariant 75).
    d = os.path.dirname(target)
    mps = re.findall(r"mountPath:\s*(\S+)", entry)
    exact = any(mp.rstrip("/") == d for mp in mps)
    ancestor = any(d.startswith(mp.rstrip("/") + "/") for mp in mps) and re.search(rf"mkdir -p {re.escape(d)}(?![\w/.-])", entry)
    if not (exact or ancestor):
        bad.append(f"{label}: the init container does not mount {d}, nor an ancestor of it with a mkdir -p of {d}")
    m = re.search(r"runAsUser:\s*(\d+)", pod_sc or "")
    if m is None:
        if not (kind == "CronJob" and name == "drills"):
            bad.append(f"{label}: the writer names no runAsUser, so its uid cannot be checked")
    elif int(m.group(1)) != uid:
        bad.append(f"{label}: the writer runs as {m.group(1)}, but the table says {uid}")

mounters = discovered_mounters()
if not mounters:
    bad.append("no pod mounts stack-events in any tracked YAML, so this gate measured NOTHING about the readers")
found_keys = set()
for path, kind, name, doc in mounters:
    key = (path, kind, name)
    found_keys.add(key)
    label = f"{path}: {kind} {name} (mounts stack-events)"
    compliant = in_group_10001(doc)
    if key in EXCEPTIONS:
        if compliant:
            bad.append(f"{label}: now in group 10001, so its EXCEPTIONS entry is stale; remove it")
        continue
    if not compliant:
        bad.append(f"{label}: the pod is not in group 10001, so it cannot read the bus files created in it; "
                   "add fsGroup or supplementalGroups 10001, or name it in EXCEPTIONS with its reason")
for key in EXCEPTIONS:
    if key not in found_keys:
        bad.append(f"{key[0]}: {key[1]} {key[2]}: the EXCEPTIONS entry matches no pod that mounts stack-events; remove it")
for path, kind, name, target, uid, gid, vol in WRITERS:
    if vol == "events" and (f"manifests/{path}", kind, name) not in found_keys:
        bad.append(f"{path}: {kind} {name}: writes stack-events but the discovery does not find it mounting the claim")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 59.")
    sys.exit(1)

print(f"OK: {len(WRITERS)} writer entries create their stream file before they start, as their own uid, "
      f"in the right group; {len(found_keys)} pod(s) mount stack-events, {len(found_keys) - len(EXCEPTIONS)} "
      f"of them in group 10001 and {len(EXCEPTIONS)} named exception(s).")
PY
