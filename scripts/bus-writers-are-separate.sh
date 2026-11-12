#!/usr/bin/env bash
# CLAUDE.md invariant 89 (GAPS G3.16): no two planes that write the events bus share a uid, and no pod
# but the bus owner can create, rename or remove a name in the bus directory.
#
# WHY
#
# Until this gate the stack-events claim was mounted at its root, read-write, by every writer, and the
# root of a Longhorn RWX volume is root:root 0777 (measured, evidence/bus-per-producer-longhorn). So any
# plane could append to another plane's stream when they shared a uid (five planes ran as 65532), and
# ANY plane, whatever its uid, could rename a stream away and put its own in its place. Pod Security
# `restricted` forbids the root init stack-single uses, so the layout here is built by an owner uid:
#
#   the Job bus-owner, uid 20000, the only pod that mounts the claim's root read-write, makes
#   streams/ (20000:10001 2750) and every stream in it (20000:<producer gid> 0664);
#   every plane mounts streams/ by subPath, never the root; a producer appends through its own group;
#   every pod but the owner waits, in an init container named bus-ready that mounts the root READ
#   ONLY, for the owner's marker, because kubelet makes a missing subPath itself as root 0777.
#
# WHAT THIS CHECKS (every pod is FOUND: each tracked YAML document, and each YAML document a tracked
# script outside scripts/ and evidence/ writes, that mounts the stack-events claim)
#
#   1. a container mounts the claim only as subPath `streams`, or subPath `conform` for the chain
#      verifier alone, or at the root read only in an init container named bus-ready, or at the root
#      read-write in the Job bus-owner alone;
#   2. every container that mounts streams/ read-write is a writer in WRITERS; its uid is its
#      producer's number, no other stream's writer has that uid, its groups hold its producer's group
#      and no other producer's group;
#   3. every pod but the owner has bus-ready as its FIRST init container, and it waits for the marker;
#   4. the owner runs as 20000, in every producer's group and in at most 16 groups in all (the AUTH_SYS
#      limit, measured: a 17th group is not honoured over NFS), and its script makes the table WRITERS
#      names, gid for gid, streams/ 2750 and each stream 0664;
#   5. no pod anywhere in the manifests runs as the owner's uid.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import subprocess
import sys

sys.path.insert(0, "scripts/lib")
import miniyaml

OWNER_UID = 20000
BUS_GID = 10001
AUTH_SYS_GROUPS = 16

# stream -> (producer uid and gid, the containers that append to it: (file, kind, object, container))
WRITERS = {
    "tokenfuse.ndjson": (20010, [("manifests/10-planes.yaml", "Deployment", "tokenfuse-gateway", "gateway")]),
    "verdryx.ndjson": (20020, [("manifests/10-planes.yaml", "Deployment", "tokenfuse-gateway", "verdryx-slo")]),
    "tokenfuse-cloud.ndjson": (20013, [("manifests/10-planes.yaml", "Deployment", "tokenfuse-cloud", "cloud")]),
    "wardryx.ndjson": (20001, [("manifests/10-planes.yaml", "Deployment", "wardryx", "wardryx")]),
    "console.ndjson": (20030, [("manifests/20-console.yaml", "Deployment", "genaryx-console", "console")]),
    "mockryx.ndjson": (20040, [("manifests/40-routines-and-secrets.yaml", "CronJob", "drills", "mockryx"),
                               ("manifests/52-tokenfuse-mcp-broker.yaml", "CronJob", "drills-broker", "mockryx"),
                               ("manifests/45-heraldyx.yaml", "CronJob", "drills-heraldyx", "mockryx")]),
    "agent-conform.ndjson": (10002, [("manifests/40-routines-and-secrets.yaml", "CronJob", "agent-conform", "agent-conform")]),
    "costcrew.ndjson": (10003, [("manifests/49-costcrew.yaml", "Deployment", "costcrew", "costcrew"),
                                ("manifests/49-costcrew.yaml", "CronJob", "costcrew-crew", "crew")]),
    "typryx.ndjson": (20005, [("manifests/51-typryx.yaml", "Deployment", "typryx", "typryx")]),
    "tokenfuse-mcp.ndjson": (20012, [("manifests/52-tokenfuse-mcp-broker.yaml", "Deployment", "tokenfuse-mcp-broker", "broker")]),
    "vouchryx.ndjson": (20002, [("manifests/54-delegation.yaml", "Deployment", "vouchryx", "vouchryx")]),
}
PRODUCER_GIDS = {gid for gid, _ in WRITERS.values()}
CONFORM = ("manifests/40-routines-and-secrets.yaml", "CronJob", "agent-conform", "agent-conform")
# Pods that take a plane's identity ON PURPOSE, to show what that identity cannot do. Keyed by file, kind and
# name; each must still exist, or the entry is stale.
PROBES = {
    ("security-tests.sh", "Pod", "sec-bus"):
        "security-tests.sh 11c: the probe runs as costcrew (10003) and mounts the bus read-write, to show the "
        "modes refuse its append to another plane's stream and its rename of a name; it is deleted after the run",
}
OWNER = ("manifests/11-bus.yaml", "Job", "bus-owner")

bad = []


def tracked(patterns):
    return subprocess.run(["git", "ls-files"] + patterns, capture_output=True, text=True).stdout.split()


def pod_spec(doc):
    kind = doc.get("kind")
    spec = doc.get("spec") or {}
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
        return ((spec.get("template") or {}).get("spec")) or {}
    if kind == "CronJob":
        return ((((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec")) or {}
    if kind == "Pod":
        return spec
    return None


def documents():
    """(file, doc) for every YAML document that is a pod-bearing object, in tracked YAML and in the
    YAML a tracked script outside scripts/ and evidence/ writes."""
    out = []
    for f in tracked(["*.yaml", "*.yml"]):
        if f.startswith(("evidence/", "docs/", "features/", ".github/")):
            continue
        text = open(f).read()
        if "stack-events" not in text and "runAsUser" not in text:
            continue
        for part in re.split(r"(?m)^---[ \t]*$", text):
            if not re.search(r"(?m)^kind:\s*(Deployment|StatefulSet|DaemonSet|Job|CronJob|Pod)\s*$", part):
                continue
            try:
                for d in miniyaml.load_all(part):
                    out.append((f, d))
            except ValueError as e:
                bad.append(f"{f}: a pod-bearing document cannot be read ({e}), so it is measured NOTHING")
    for f in tracked(["*.sh"]):
        if f.startswith(("scripts/", "evidence/")):
            continue
        text = open(f).read()
        for m in re.finditer(r"<<-?\s*['\"]?YAML['\"]?[^\n]*\n(.*?)\n[ \t]*YAML[ \t]*\n", text, re.S):
            body = m.group(1)
            if "claimName: stack-events" not in body:
                continue
            for part in re.split(r"(?m)^---[ \t]*$", body):
                if not re.search(r"(?m)^kind:\s*(Deployment|Job|CronJob|Pod)\s*$", part):
                    continue
                try:
                    for d in miniyaml.load_all(part):
                        out.append((f, d))
                except ValueError as e:
                    bad.append(f"{f}: a pod document it writes cannot be read ({e}), so it is measured NOTHING")
    return out


def name_of(doc):
    return (doc.get("metadata") or {}).get("name", "?")


def eff(container, pod):
    psc = pod.get("securityContext") or {}
    csc = container.get("securityContext") or {}
    uid = csc.get("runAsUser", psc.get("runAsUser"))
    gid = csc.get("runAsGroup", psc.get("runAsGroup"))
    groups = set()
    if gid is not None:
        groups.add(gid)
    groups.update(psc.get("supplementalGroups") or [])
    if psc.get("fsGroup") is not None:
        groups.add(psc["fsGroup"])
    return uid, groups


docs = documents()
seen_probes = set()
kept = []
for f, d in docs:
    key = (f, d.get("kind"), name_of(d))
    if key in PROBES:
        seen_probes.add(key)
        continue
    kept.append((f, d))
docs = kept
for key in PROBES:
    if key not in seen_probes:
        bad.append(f"{key[0]}: {key[1]} {key[2]}: the PROBES entry matches no pod; remove it")

# 5. nobody runs as the owner
for f, d in docs:
    spec = pod_spec(d)
    if spec is None:
        continue
    key = (f, d.get("kind"), name_of(d))
    if key == OWNER:
        continue
    for c in (spec.get("initContainers") or []) + (spec.get("containers") or []):
        uid, _ = eff(c, spec)
        if uid == OWNER_UID:
            bad.append(f"{f}: {d.get('kind')} {name_of(d)}, container {c.get('name')}, runs as {OWNER_UID}, the bus "
                       "owner's uid: it could rename and replace every stream")

bus_pods = []
for f, d in docs:
    spec = pod_spec(d)
    if spec is None:
        continue
    vols = [v.get("name") for v in spec.get("volumes") or []
            if ((v.get("persistentVolumeClaim") or {}).get("claimName")) == "stack-events"]
    if vols:
        bus_pods.append((f, d, spec, set(vols), {
            v.get("name"): bool(((v.get("persistentVolumeClaim") or {}).get("readOnly")))
            for v in spec.get("volumes") or []}))

if not bus_pods:
    bad.append("no pod mounts the stack-events claim, so this gate measured NOTHING")

found_writers = set()
writer_uids = {}
owner_seen = False
for f, d, spec, vols, claim_ro in bus_pods:
    kind, name = d.get("kind"), name_of(d)
    key = (f, kind, name)
    label = f"{f}: {kind} {name}"
    is_owner = key == OWNER
    owner_seen = owner_seen or is_owner
    inits = spec.get("initContainers") or []
    for ckind, clist in (("init", inits), ("container", spec.get("containers") or [])):
        for c in clist:
            cname = c.get("name")
            for m in c.get("volumeMounts") or []:
                if m.get("name") not in vols:
                    continue
                ro = bool(m.get("readOnly")) or claim_ro.get(m.get("name"), False)
                sub = m.get("subPath")
                where = f"{label}, {ckind} {cname}"
                if sub is None:
                    if is_owner and ckind == "container" and not ro:
                        continue
                    if ckind == "init" and cname == "bus-ready" and ro:
                        continue
                    bad.append(f"{where}: mounts the stack-events root{' read-write' if not ro else ''}; only the owner "
                               "Job may, and only the bus-ready init may read it: mount subPath streams")
                    continue
                if sub == "conform":
                    if (f, kind, name, cname) != CONFORM or ckind != "container":
                        bad.append(f"{where}: mounts subPath conform, the chain verifier's own directory")
                    continue
                if sub != "streams":
                    bad.append(f"{where}: mounts subPath {sub!r} of stack-events; the bus is subPath streams")
                    continue
                if ro:
                    continue
                # 2. a writer
                entry = next(((s, uid) for s, (uid, objs) in WRITERS.items() if (f, kind, name, cname) in objs), None)
                if entry is None:
                    bad.append(f"{where}: mounts the bus read-write and is no writer in WRITERS; mount it readOnly, or "
                               "name its stream in WRITERS and in the owner's table")
                    continue
                stream, want = entry
                found_writers.add((f, kind, name, cname))
                uid, groups = eff(c, spec)
                if uid != want:
                    bad.append(f"{where}: writes {stream} as uid {uid}; its producer's uid is {want}")
                if uid is not None:
                    other = writer_uids.get(uid)
                    if other and other[0] != stream:
                        bad.append(f"{where}: shares uid {uid} with {other[1]}, the writer of {other[0]}")
                    writer_uids.setdefault(uid, (stream, where))
                if want not in groups:
                    bad.append(f"{where}: is not in group {want}, so it cannot append to {stream}")
                foreign = sorted((groups & PRODUCER_GIDS) - {want})
                if foreign:
                    bad.append(f"{where}: carries the group of another producer ({', '.join(map(str, foreign))}), so it "
                               "can append to that producer's stream")
    # 3. the wait for the owner
    if not is_owner:
        if not inits or inits[0].get("name") != "bus-ready":
            bad.append(f"{label}: its first init container is not bus-ready, so a container may start before the "
                       "owner has made streams/, and kubelet then makes it as root 0777")
        else:
            cmd = " ".join(str(x) for x in (inits[0].get("command") or []) + (inits[0].get("args") or []))
            if not re.search(r"until \[ -f /bus/streams/\.layout \]", cmd):
                bad.append(f"{label}: its bus-ready init does not wait for streams/.layout, the owner's marker")

for stream, (uid, objs) in WRITERS.items():
    for o in objs:
        if o not in found_writers:
            bad.append(f"{o[0]}: {o[1]} {o[2]}, container {o[3]}: WRITERS says it appends to {stream}, but no such "
                       "container mounts the bus read-write; the table is stale")

# 4. the owner
if not owner_seen:
    bad.append(f"{OWNER[0]}: no Job {OWNER[2]} mounts the stack-events root, so nothing makes the bus and the owner is "
               "measured NOTHING")
else:
    f, d, spec = next((f, d, s) for f, d, s, _, _ in bus_pods if (f, d.get("kind"), name_of(d)) == OWNER)
    c = (spec.get("containers") or [{}])[0]
    uid, groups = eff(c, spec)
    if uid != OWNER_UID:
        bad.append(f"{f}: the owner runs as {uid}, not {OWNER_UID}")
    missing = sorted(PRODUCER_GIDS - groups)
    if missing:
        bad.append(f"{f}: the owner is not in the group of {', '.join(map(str, missing))}, so it cannot give a stream "
                   "to its producer")
    if BUS_GID not in groups:
        bad.append(f"{f}: the owner is not in the bus group {BUS_GID}")
    if len(groups) > AUTH_SYS_GROUPS:
        bad.append(f"{f}: the owner is in {len(groups)} groups; NFS with AUTH_SYS honours {AUTH_SYS_GROUPS}, so "
                   "chgrp to the later ones is refused on Longhorn RWX")
    script = None
    for d2 in miniyaml.load_all(open(f).read()) if os.path.exists(f) else []:
        if d2.get("kind") == "ConfigMap" and name_of(d2) == "bus-owner":
            script = (d2.get("data") or {}).get("bus-owner.sh")
    if not script:
        bad.append(f"{f}: no ConfigMap bus-owner with bus-owner.sh, so what the owner makes is measured NOTHING")
    else:
        live = "\n".join(l for l in script.split("\n") if not l.lstrip().startswith("#"))
        rows = dict((s, int(g)) for s, g in re.findall(r"^\s*([a-z0-9-]+\.ndjson):(\d+)\b", live, re.M))
        if not rows:
            bad.append(f"{f}: the owner's script names no stream, so its table is measured NOTHING")
        for stream, (gid, _) in WRITERS.items():
            if stream not in rows:
                bad.append(f"{f}: the owner's script does not make {stream}")
            elif rows[stream] != gid:
                bad.append(f"{f}: the owner gives {stream} to group {rows[stream]}; its producer is {gid}")
        for stream in rows:
            if stream not in WRITERS:
                bad.append(f"{f}: the owner makes {stream}, which no writer in WRITERS appends to")
        if not re.search(r'own_dir "\$S" ' + str(BUS_GID) + r" 2750\b", live):
            bad.append(f"{f}: the owner does not make streams/ {OWNER_UID}:{BUS_GID} 2750, so the bus directory is not "
                       "closed to everybody but the owner")
        if not re.search(r'own_file "\$S" "\$\{row%%:\*\}" "\$\{row##\*:\}" 0664\b', live):
            bad.append(f"{f}: the owner does not make each stream 0664 in its producer's group")
        # A producer's group can write the archive and conform/, so a link it plants where the owner writes
        # a temp file would turn the owner's write and chgrp onto another stream (GOTCHAS 164, measured
        # by evidence/bus-per-producer-longhorn/owner-symlink.sh). Every file the owner writes is written
        # in streams/, which only it can write, and moved into place with mv -T, which never follows a link.
        tdef = re.search(r'^\s*T=(\S+)\s*$', live, re.M)
        for target in re.findall(r'>\s*"([^"]+)"', live):
            if not (target.startswith("$S/") or target in ("$f", "$f.tmp") or (target == "$T" and tdef and tdef.group(1).startswith("$S/"))):
                bad.append(f"{f}: the owner writes {target}, outside streams/, where a producer can plant a link in its place")
        for args in re.findall(r'^\s*own_file\s+("[^"]*"|\S+)', live, re.M):
            if args != '"$S"':
                bad.append(f"{f}: own_file is called on {args}, not on streams/, so its temp file may sit where a producer can write")
        for line in re.findall(r'^.*\bmv\b.*$', live, re.M):
            if not re.search(r'\bmv\s+-T\b', line):
                bad.append(f"{f}: the owner moves a file without mv -T: {line.strip()}")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 89.")
    sys.exit(1)

print(f"OK: {len(bus_pods)} pod(s) mount stack-events; {len(found_writers)} writer container(s) for {len(WRITERS)} "
      f"streams, each its producer's own uid and group; only the owner (uid {OWNER_UID}) mounts the bus root "
      "read-write, and every other pod waits for it.")
PY
