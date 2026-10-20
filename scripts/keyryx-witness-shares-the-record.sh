#!/usr/bin/env bash
# CLAUDE.md invariant 70. The Keyryx witness reads the trailryx record it countersigns, and the record-seal reads
# the witness's attestations, through volumes they can share. Both claims are ReadWriteOnce (Longhorn), so the two
# pods share a volume only on one node: the record-seal is pinned to the witness's node, and the witness is the
# only writer of its attestation directory. keyryx v0.1.2 writes each attestation 0640 and its directories 0750, and the
# witness runs as group 10001, the record plane's group, so the record-seal (uid 10001) reads the attestations directory,
# read only, through TRAILRYX_WITNESS_ATTESTATIONS (CLAUDE.md invariant 73 pins the seal's key beside it).
#
# WHAT THIS CHECKS
#
#   1. keyryx/manifests/59-keyryx.yaml, the witness: KEYRYX_WITNESS_RECORDS is "acme|/var/lib/stack/records" (the
#      tenant trailryx-node uses by default, and the directory it seals into), the trailryx-records claim is mounted
#      read-only there, and the witness Deployment is Recreate (a RWO volume is released before the next pod starts).
#   2. The witness and its root-key-copy init run as group 10001, and the init makes data/attestations, the directory
#      the witness writes its attestations to, before the record-seal can bind it read-only.
#   3. keyryx/record-seal-patch.yaml: the record-seal is pod-affined to the witness's node (hostname topology), mounts
#      the witness state claim READ-ONLY through subPath data/attestations only (never the witness key), and sets
#      TRAILRYX_WITNESS_ATTESTATIONS to that mount.
#   4. keyryx/record-seal-unpatch.yaml removes that affinity and that volume.
#   5. The record-seal command in manifests/40 passes no --tenant, so the default tenant (acme) is the one the witness
#      reads.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
import sys

bad = []


def read(path):
    try:
        return open(path).read()
    except OSError:
        return None


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


m59 = read("keyryx/manifests/59-keyryx.yaml")
if m59 is None:
    print("FAIL keyryx/manifests/59-keyryx.yaml is absent: the witness is measured NOTHING")
    sys.exit(1)
docs59 = re.split(r"\n---\s*\n", m59)
witness = next((d for d in docs59 if re.search(r"^kind: Deployment\s*$", d, re.M)
                and re.search(r"^  name: keyryx-witness\s*$", d, re.M)), None)
if witness is None:
    bad.append("keyryx/manifests/59-keyryx.yaml has no keyryx-witness Deployment")
else:
    w = live(witness)
    if not re.search(r'name: KEYRYX_WITNESS_RECORDS\n\s+value: "?acme\|/var/lib/stack/records"?', w):
        bad.append('the witness does not read the record: KEYRYX_WITNESS_RECORDS must be "acme|/var/lib/stack/records"')
    if not re.search(r"\{ name: trailryx-records, mountPath: /var/lib/stack/records, readOnly: true \}", w) \
            and not re.search(r"- name: trailryx-records\n\s+mountPath: /var/lib/stack/records\n\s+readOnly: true", w):
        bad.append("the witness does not mount the trailryx-records claim read-only at /var/lib/stack/records")
    if not re.search(r"- name: trailryx-records\n\s+persistentVolumeClaim:\s*\{\s*claimName: trailryx-records,\s*readOnly: true\s*\}", w) \
            and not re.search(r"claimName: trailryx-records\s*\n\s*readOnly: true", w):
        bad.append("the witness volume trailryx-records is not a read-only claim of trailryx-records")
    if not re.search(r"runAsUser: 20100\n\s+runAsGroup: 10001\n\s+fsGroup: 10001", w):
        bad.append("the witness does not run as group 10001, so the attestation files it writes are not group-readable by the record seal")
    if not re.search(r"strategy: \{ type: Recreate \}", w):
        bad.append("the witness Deployment is not Recreate, so a RWO volume could be held by the old pod while the new one starts")
    rk = re.search(r"- name: root-key-copy\n(.*?)(?=\n\s+- name: |\n\s+containers:)", w, re.S)
    if rk is None or not re.search(r"mkdir -p /var/lib/keyryx-witness/data/attestations", rk.group(1)):
        bad.append("the witness init root-key-copy does not make data/attestations, the directory the witness writes its attestations to")
    if rk is not None and not re.search(r"runAsGroup: 10001", rk.group(1)):
        bad.append("the witness init root-key-copy does not run as group 10001, so the directories it makes are not group-readable by the record seal")

rs = read("keyryx/record-seal-patch.yaml")
if rs is None:
    bad.append("keyryx/record-seal-patch.yaml is absent")
else:
    t = live(rs)
    if not re.search(r"podAffinity:\s*\n\s+requiredDuringSchedulingIgnoredDuringExecution:\s*\n\s+- labelSelector:\s*\n\s+matchLabels:\s*\n\s+app: keyryx-witness\s*\n\s+topologyKey: kubernetes\.io/hostname", t):
        bad.append("the record-seal is not pod-affined to the witness's node (required, hostname topology): the RWO volumes would not share a node")
    if not re.search(r"name: witness-attestations\n\s+persistentVolumeClaim:\s*\n\s+claimName: keyryx-witness-state\s*\n\s+readOnly: true", t):
        bad.append("the record-seal does not mount the witness state claim read-only for its attestations")
    if not re.search(r"subPath: data/attestations", t) or not re.search(r"mountPath: /var/lib/stack/attestations", t):
        bad.append("the record-seal mounts the witness state without the subPath data/attestations (it would see the witness key)")
    if not re.search(r"- name: TRAILRYX_WITNESS_ATTESTATIONS\n\s+value: /var/lib/stack/attestations\n", t):
        bad.append("the record-seal does not point TRAILRYX_WITNESS_ATTESTATIONS at its read-only attestations directory")
    if "TODO(keyryx-attest-mode)" in rs:
        bad.append("keyryx/record-seal-patch.yaml still names TODO(keyryx-attest-mode): the attestation read is wired, so that TODO is stale")

ru = read("keyryx/record-seal-unpatch.yaml")
if ru is None:
    bad.append("keyryx/record-seal-unpatch.yaml is absent")
else:
    if not re.search(r"affinity: null", ru):
        bad.append("keyryx/record-seal-unpatch.yaml does not remove the pod affinity")
    if not re.search(r"name: witness-attestations\n\s+\$patch: delete", ru):
        bad.append("keyryx/record-seal-unpatch.yaml does not remove the witness-attestations volume")

m40 = read("manifests/40-routines-and-secrets.yaml") or ""
seal = re.search(r"name: record-seal\n.*?(?=\n---|\Z)", m40, re.S)
if seal is None or "trailryx-node read" not in seal.group(0):
    bad.append("manifests/40-routines-and-secrets.yaml: the record-seal command is absent, so the tenant is measured NOTHING")
elif "--tenant" in seal.group(0):
    bad.append("the record-seal passes --tenant, so the tenant the witness reads may differ from the one it seals")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 70.")
    sys.exit(1)
print("OK: the witness reads the record it countersigns through a read-only claim (KEYRYX_WITNESS_RECORDS); the record-seal is pod-affined to the witness's node and reads the attestation subdirectory read-only; TRAILRYX_WITNESS_ATTESTATIONS points at that mount, and the witness and the record seal share group 10001.")
PY
