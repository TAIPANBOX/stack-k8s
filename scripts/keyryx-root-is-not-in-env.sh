#!/usr/bin/env bash
# Enforces invariant 55 of CLAUDE.md: a Keyryx root key never reaches a process
# as an environment variable, a secretKeyRef or a literal, and each root key is
# read by exactly one init container, which copies it to memory for its own
# role's main container. Port of stack-single's keyryx-root-is-not-in-env.sh
# (wave 2 design, section 5.1) to the cluster (section 5.2).
#
# WHY
#
# An environment variable is printed by `kubectl describe`, copied into every
# child process and shown in crash reports. A root key read from one is a root
# key the whole pod can see. The key is mounted from a Secret, and the copy into
# a memory-backed volume is the only route the process gets: the copy runs as
# the role's own uid, so the file is the process's and nothing else in the pod
# can read the Secret's own mount.
#
# WHAT THIS CHECKS (every file under keyryx/ that a kubectl apply would send)
#
#   1. no secretKeyRef or secretRef names keyryx-root or keyryx-witness-root;
#   2. no environment variable whose name ends in ROOT_KEY (ROOT_KEY_FILE, a
#      path, is allowed);
#   3. no 64-hex-character literal anywhere (a key written into a manifest);
#   4. the Secret keyryx-root is mounted by one volume, in the custody
#      Deployment's initContainer named root-key-copy and nowhere else.
#
# HOW
#
# No YAML library on this Mac, so the check reads the text the way the other
# gates here do: by known names and by which section of a document a line sits
# in. The manifest is written in that shape (see 59-keyryx.yaml). A subject that
# is absent is a failure with the words "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import os
import re
import sys

files = sorted(glob.glob("keyryx/**/*.yaml", recursive=True))
if not os.path.exists("keyryx/manifests/59-keyryx.yaml"):
    print("keyryx-root-is-not-in-env: keyryx/manifests/59-keyryx.yaml is absent,"
          " so this gate measured NOTHING")
    sys.exit(1)

bad = []
text = {}
for f in files:
    with open(f) as fh:
        text[f] = fh.read()

for f, t in text.items():
    if re.search(r"secret(Key)?Ref:\s*\{?\s*name:\s*keyryx-(witness-)?root\b", t):
        bad.append(f"{f}: a root key is read through a secretKeyRef or secretRef")
    for m in re.finditer(r"^\s*-?\s*name:\s*\"?([A-Z0-9_]*ROOT_KEY)\"?\s*$", t, re.M):
        bad.append(f"{f}: environment variable {m.group(1)} would carry key material")
    if re.search(r"(?<!sha256:)\b[0-9a-f]{64}\b", t):
        bad.append(f"{f}: a 64-hex-character literal (a key written into a manifest)")

mounts = []
for f, t in text.items():
    for m in re.finditer(r"secretName:\s*(keyryx-(witness-)?root)\b", t):
        mounts.append((f, m.group(1), t.count("\n", 0, m.start())))

if len(mounts) != 2:
    bad.append(f"expected exactly two volumes naming a root key Secret, found {len(mounts)}")

custody = text.get("keyryx/manifests/59-keyryx.yaml", "")
docs = re.split(r"\n---\s*\n", custody)


def doc_named(kind, name):
    for d in docs:
        if re.search(rf"^kind:\s*{kind}\s*$", d, re.M) and re.search(
                rf"^  name:\s*{name}\s*$", d, re.M):
            return d
    return None


custody_dep = doc_named("Deployment", "keyryx-custody")
witness_dep = doc_named("Deployment", "keyryx-witness")
if custody_dep is None or witness_dep is None:
    bad.append("the custody or witness Deployment is missing from 59-keyryx.yaml")
else:
    init_part = custody_dep.split("initContainers:", 1)[-1].split("\n      containers:", 1)[0] \
        if "initContainers:" in custody_dep else ""
    if "name: root-key-copy" not in init_part:
        bad.append("the custody Deployment has no initContainer named root-key-copy")
    if "secretName: keyryx-root\n" not in init_part.replace("secretName: keyryx-root", "secretName: keyryx-root\n", 1) \
            and "secretName: keyryx-root" not in custody_dep:
        bad.append("the custody Deployment does not mount keyryx-root")
    main_part = custody_dep.split("\n      containers:", 1)[-1].split("\n      volumes:", 1)[0]
    if "keyryx-root" in main_part:
        bad.append("the custody main container mounts keyryx-root (only root-key-copy may)")
    for name in ("keyryx-root",):
        if not re.search(r"^\s*- name: " + name + r"\s*$", init_part, re.M) and \
                not re.search(r"volumeMounts:[\s\S]*?name: " + name, init_part):
            bad.append("root-key-copy does not mount the keyryx-root Secret")
    if "keyryx-witness-root" in custody_dep:
        bad.append("the custody Deployment names the witness root key")
    if "keyryx-root" in witness_dep:
        bad.append("the witness Deployment names the custody root key")

if bad:
    for b in bad:
        print("FAIL " + b)
    sys.exit(1)

print(f"OK: no root key reaches a process as an environment variable or a literal;"
      f" the custody root key is copied by root-key-copy alone ({len(files)} file(s)).")
PY
