#!/usr/bin/env bash
# CLAUDE.md invariant 59: every stream file a Go writer appends to on the shared event volume
# (or its own journal volume) is created before the writer starts, by an init container that runs
# as the writer's own uid, mode 0640, in the group the readers are in; and every reader of the bus
# files is in that group (fsGroup or supplementalGroups 10001).
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
#   2. Every reader in READERS: its pod is in group 10001, the group the bus files are created in.
#
# Not a writer here: keyryx-witness. Its alerts file sits in a directory its own uid created in
# root-key-copy, so openAppend's ownership test passes without a precreate, and nothing on the bus
# reads it.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import sys

# file, kind, object name, the file the writer appends to, the uid it appends as,
# the group the file is created in, the volume it lives on
WRITERS = [
    ("10-planes.yaml", "Deployment", "wardryx", "/var/lib/stack/events/wardryx.ndjson", 65532, 10001, "events"),
    ("40-routines-and-secrets.yaml", "CronJob", "agent-conform", "/var/lib/stack/events/agent-conform.ndjson", 10002, 10001, "events"),
    # the drills image is distroless nonroot (mockryx Dockerfile, USER 65532:65532); the pod names no runAsUser
    ("40-routines-and-secrets.yaml", "CronJob", "drills", "/var/lib/stack/events/mockryx.ndjson", 65532, 10001, "events"),
    ("51-typryx.yaml", "Deployment", "typryx", "/var/lib/stack/events/typryx.ndjson", 65532, 10001, "events"),
    ("54-delegation.yaml", "Deployment", "vouchryx", "/var/lib/stack/events/vouchryx.ndjson", 65532, 10001, "events"),
    ("54-delegation.yaml", "Deployment", "vouchryx", "/var/lib/stack/delegation/revocations.ndjson", 65532, 10001, "delegation-state"),
    ("49-costcrew.yaml", "Deployment", "costcrew", "/var/lib/stack/events/costcrew.ndjson", 65532, 10001, "events"),
    ("49-costcrew.yaml", "CronJob", "costcrew-crew", "/var/lib/stack/events/costcrew.ndjson", 65532, 10001, "events"),
    # heraldyx opens its own dispatch journal on its state volume with the same writer, so a fresh
    # volume (no file yet, root-owned directory) cannot open its journal without this, and runs
    # on with no record of what it sent (GOTCHAS 136).
    ("45-heraldyx.yaml", "Deployment", "heraldyx", "/var/lib/stack/heraldyx/sent.ndjson", 65532, 65532, "state"),
    ("47-scopyx.yaml", "Deployment", "scopyx", "/var/lib/scopyx/events.ndjson", 65532, 65532, "journal"),
    ("48-scopyx-browser.yaml", "Deployment", "scopyx", "/var/lib/scopyx/events.ndjson", 65532, 65532, "journal"),
]

# file, kind, object name: readers of the bus files, which must be in group 10001
READERS = [
    ("10-planes.yaml", "Deployment", "idryx"),
    ("40-routines-and-secrets.yaml", "CronJob", "identity-sweep"),
    ("45-heraldyx.yaml", "Deployment", "heraldyx"),
]

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
    if not re.search(rf"mountPath:\s*{re.escape(os.path.dirname(target))}\b", entry):
        bad.append(f"{label}: the init container does not mount {os.path.dirname(target)}")
    m = re.search(r"runAsUser:\s*(\d+)", pod_sc or "")
    if m is None:
        if not (kind == "CronJob" and name == "drills"):
            bad.append(f"{label}: the writer names no runAsUser, so its uid cannot be checked")
    elif int(m.group(1)) != uid:
        bad.append(f"{label}: the writer runs as {m.group(1)}, but the table says {uid}")

for path, kind, name in READERS:
    doc = find(path, kind, name)
    label = f"{path}: {kind} {name} (reader)"
    if doc is None:
        bad.append(f"{label}: the object is absent, so this reader is measured NOTHING")
        continue
    ind = containers_indent(doc)
    sc = block(doc, "securityContext", ind) if ind is not None else None
    if not sc or not re.search(r"supplementalGroups:\s*\[[^\]]*\b10001\b|fsGroup:\s*10001\b", sc):
        bad.append(f"{label}: the pod is not in group 10001, so it cannot read the bus files created in it")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 59.")
    sys.exit(1)

print(f"OK: {len(WRITERS)} writer entries create their stream file before they start, as their own uid, "
      f"in the right group; {len(READERS)} reader(s) are in group 10001.")
PY
