#!/usr/bin/env bash
# CLAUDE.md invariant 97: Keyryx custody announces every rotation and revocation into its own stream,
# keyryx-custody.ndjson, in custody/ beside the bus; heraldyx reads it; no network admin key is set anywhere.
#
# WHY
#
# keyryx v0.2.0 serves rotation and revocation only on the admin unix socket in its data directory, and refuses
# to start without KEYRYX_EVENTS (a key change nobody hears of is not one it makes) or with KEYRYX_ADMIN_KEYS set
# to anything but empty. It writes its announcements only into a regular file with one link that its own uid owns
# (internal/announce/bus.go), never through a link. Every file in streams/ belongs to the bus owner (uid 20000,
# invariant 89), so custody's stream cannot sit there: the owner makes custody/ (20000:20101 0771), custody's
# precreate init makes the file as custody's uid in the bus group, 0640, and heraldyx reads it in that group.
# A custody whose file is in the wrong place does not start; one whose file heraldyx cannot read announces to
# nobody, which looks exactly like a quiet night.
#
# WHAT THIS CHECKS
#
#   1. the custody container sets KEYRYX_EVENTS to /var/lib/stack/events/keyryx-custody.ndjson (stack-single's
#      path), outside KEYRYX_DATA, and mounts the events claim there as subPath custody, read-write;
#   1b. its bus-ready init waits for custody/ as the owner makes it (20000:20101:771), not only for the marker;
#   2. it runs as uid 20101 in group 10001 (so the file it makes is readable by the bus group) and the pod
#      carries group 20101 (so it may create a name in custody/);
#   3. no tracked file sets KEYRYX_ADMIN_KEYS, in a manifest's env or a shell assignment, in code;
#   4. keyryx/heraldyx-findings-patch.yaml names the file in HERALDYX_EVENTS and mounts custody/ read only
#      at its directory, and the unpatch takes both away again;
#   5. the README names the two admin commands and how to reach them (kubectl exec into custody).
#
# The owner's custody/ and its group are scripts/bus-writers-are-separate.sh's, the precreate init is
# scripts/stream-files-are-precreated.sh's, the stem and heraldyx's version scripts/bus-names-match-the-
# source-rule.sh's. A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import subprocess
import sys

sys.path.insert(0, "scripts/lib")
import miniyaml

EVENTS = "/var/lib/stack/events/keyryx-custody.ndjson"
HERALDYX_DIR = "/var/lib/stack/keyryx-custody"
CUSTODY_UID, BUS_GID = 20101, 10001
MANIFEST = "keyryx/manifests/59-keyryx.yaml"
PATCH, UNPATCH = "keyryx/heraldyx-findings-patch.yaml", "keyryx/heraldyx-findings-unpatch.yaml"

bad = []


def load(path):
    if not os.path.exists(path):
        print(f"FAIL {path} is absent, so this gate measured NOTHING")
        sys.exit(1)
    try:
        return list(miniyaml.load_all(open(path).read()))
    except ValueError as e:
        print(f"FAIL {path} cannot be read ({e}), so this gate measured NOTHING")
        sys.exit(1)


def env_of(c):
    return {e.get("name"): e.get("value") for e in c.get("env") or []}


docs = load(MANIFEST)
dep = next((d for d in docs if d.get("kind") == "Deployment" and (d.get("metadata") or {}).get("name") == "keyryx-custody"), None)
if dep is None:
    print(f"FAIL {MANIFEST}: no Deployment keyryx-custody, so this gate measured NOTHING")
    sys.exit(1)
spec = ((dep.get("spec") or {}).get("template") or {}).get("spec") or {}
c = next((x for x in spec.get("containers") or [] if x.get("name") == "keyryx"), None)
if c is None:
    print(f"FAIL {MANIFEST}: keyryx-custody has no container keyryx, so this gate measured NOTHING")
    sys.exit(1)

# 1. the stream, outside the data directory, on custody/
env = env_of(c)
events = env.get("KEYRYX_EVENTS")
data = env.get("KEYRYX_DATA")
if events is None:
    bad.append(f"{MANIFEST}: custody does not set KEYRYX_EVENTS, and keyryx v0.2.0 refuses to start without it")
elif events != EVENTS:
    bad.append(f"{MANIFEST}: custody's KEYRYX_EVENTS is {events}, not {EVENTS}, the path stack-single uses and heraldyx is given")
if data and events and (events == data or events.startswith(data.rstrip("/") + "/")):
    bad.append(f"{MANIFEST}: KEYRYX_EVENTS {events} is inside KEYRYX_DATA {data}, which no reader of the bus can read")
claims = {v.get("name"): v.get("persistentVolumeClaim") or {} for v in spec.get("volumes") or []}
mnt = [m for m in c.get("volumeMounts") or []
       if (claims.get(m.get("name")) or {}).get("claimName") == "stack-events"]
want_dir = os.path.dirname(EVENTS)
if not any(m.get("mountPath") == want_dir and m.get("subPath") == "custody" and not m.get("readOnly")
           and not (claims.get(m.get("name")) or {}).get("readOnly") for m in mnt):
    bad.append(f"{MANIFEST}: custody does not mount the events claim at {want_dir} as subPath custody, read-write, "
               "so the directory of KEYRYX_EVENTS is not custody/ and custody refuses to start or writes where nobody reads")

# kubelet makes a missing subPath as root 0777, and the owner refuses a directory it did not make, so custody
# waits for custody/ as the owner leaves it, not only for a marker an earlier layout may have written.
ready = next((x for x in spec.get("initContainers") or [] if x.get("name") == "bus-ready"), None)
rcmd = " ".join(str(x) for x in ((ready or {}).get("command") or []) + ((ready or {}).get("args") or []))
if not re.search(r'stat -c %u:%g:%a /bus/custody\b[^\]]*\]?[^=]*=\s*20000:20101:771', rcmd):
    bad.append(f"{MANIFEST}: custody's bus-ready does not wait for /bus/custody to be 20000:20101:771, so on an upgrade "
               "kubelet can make custody/ as root first and the bus owner then refuses it on every run")

# 2. who custody runs as
psc = spec.get("securityContext") or {}
csc = c.get("securityContext") or {}
uid = csc.get("runAsUser", psc.get("runAsUser"))
gid = csc.get("runAsGroup", psc.get("runAsGroup"))
groups = set(psc.get("supplementalGroups") or []) | ({psc["fsGroup"]} if psc.get("fsGroup") is not None else set())
if uid != CUSTODY_UID:
    bad.append(f"{MANIFEST}: custody runs as uid {uid}, not {CUSTODY_UID}, the uid the owner's custody/ and the precreate are for")
if gid != BUS_GID:
    bad.append(f"{MANIFEST}: custody runs in group {gid}, not {BUS_GID}: a stream it makes itself would be "
               "unreadable by heraldyx, which reads in the bus group")
if CUSTODY_UID not in groups and gid != CUSTODY_UID:
    bad.append(f"{MANIFEST}: custody's pod is not in group {CUSTODY_UID}, so it cannot create a name in custody/")

# 3. no network admin key, anywhere in code
files = subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.split()
skip_prefix = ("docs/releases/", "evidence/", "features/")
skip = {"GOTCHAS.md", "CLAUDE.md", "README.md", "scripts/keyryx-custody-announces.sh", "scripts/gates-have-teeth.sh"}
seen = 0
for f in files:
    if f in skip or f.startswith(skip_prefix) or not os.path.isfile(f):
        continue
    try:
        text = open(f).read()
    except (UnicodeDecodeError, OSError):
        continue
    seen += 1
    for n, line in enumerate(text.split("\n"), 1):
        code = line.split("#", 1)[0] if not f.endswith(".json") else line
        if re.search(r"\bname:\s*[\"']?KEYRYX_ADMIN_KEYS\b|\bKEYRYX_ADMIN_KEYS=|\"KEYRYX_ADMIN_KEYS\"\s*:", code):
            bad.append(f"{f}:{n}: sets KEYRYX_ADMIN_KEYS; keyryx v0.2.0 refuses to start when it is set, and rotation is "
                       "the admin socket's alone")
if seen == 0:
    bad.append("no tracked file could be read, so the search for KEYRYX_ADMIN_KEYS measured NOTHING")

# 4. heraldyx reads it, and the unpatch takes it away
want_file = HERALDYX_DIR + "/" + os.path.basename(EVENTS)
for path, adds in ((PATCH, True), (UNPATCH, False)):
    pd = next((d for d in load(path) if d.get("kind") == "Deployment"), None)
    pspec = (((pd or {}).get("spec") or {}).get("template") or {}).get("spec") or {}
    hc = next((x for x in pspec.get("containers") or [] if x.get("name") == "heraldyx"), None)
    if hc is None:
        bad.append(f"{path}: no heraldyx container, so what heraldyx reads is measured NOTHING")
        continue
    hev = (env_of(hc).get("HERALDYX_EVENTS") or "").split(",")
    mounts = hc.get("volumeMounts") or []
    if adds:
        if want_file not in hev:
            bad.append(f"{path}: HERALDYX_EVENTS does not name {want_file}, so custody's key_revoked reaches nobody")
        if not any(m.get("mountPath") == HERALDYX_DIR and m.get("subPath") == "custody" and m.get("readOnly")
                   and m.get("name") == "events" for m in mounts):
            bad.append(f"{path}: heraldyx does not mount the events volume at {HERALDYX_DIR} as subPath custody, read only")
    else:
        if want_file in hev:
            bad.append(f"{path}: the unpatch leaves {want_file} in HERALDYX_EVENTS")
        if not any(m.get("mountPath") == HERALDYX_DIR and m.get("$patch") == "delete" for m in mounts):
            bad.append(f"{path}: the unpatch does not delete the mount at {HERALDYX_DIR} (by mountPath, the merge key)")

# 5. the operator is told how to rotate
readme = open("README.md").read() if os.path.exists("README.md") else ""
for cmd in ("keyryx admin rotate", "keyryx admin revoke"):
    if not re.search(r"kubectl[^\n`]*exec[^\n`]*keyryx-custody[^\n`]*" + re.escape(cmd), readme):
        bad.append(f"README.md does not show `kubectl ... exec ... keyryx-custody ... {cmd}`, the one way to reach the admin socket")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 97.")
    sys.exit(1)

print(f"OK: custody announces into {EVENTS} on custody/ (uid {CUSTODY_UID}, group {BUS_GID}), heraldyx reads it at "
      f"{want_file}, the unpatch takes it away, and no tracked file of {seen} sets KEYRYX_ADMIN_KEYS.")
PY
