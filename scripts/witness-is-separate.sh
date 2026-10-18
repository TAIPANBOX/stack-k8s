#!/usr/bin/env bash
# Enforces invariant 56 of CLAUDE.md: the Keyryx witness and the Keyryx custody
# service are two workloads that share nothing but the image. Port of stack-single's
# witness-is-separate.sh (wave 2 design, section 3.4 and 5.1) to the cluster
# (section 5.2).
#
# WHY
#
# The witness exists to disagree with custody when custody has been compromised
# and signed something it should not have. If the witness shares custody's
# service account, state volume, root key or uid, one compromise reads both,
# and the disagreement is gone. The witness also reads the event streams, so it
# mounts them read-only: a witness that can write the record it checks is not a
# witness.
#
# WHAT THIS CHECKS (keyryx/manifests/59-keyryx.yaml)
#
#   1. the two Deployments name different ServiceAccounts, and each runs as its
#      own non-root uid, and the two uids differ;
#   2. each role mounts only its own state claim (keyryx-state for custody,
#      keyryx-witness-state for the witness) and only its own root key Secret;
#   3. the witness mounts the events claim stack-events with readOnly: true;
#   4. the witness writes its alerts outside the events directory;
#   5. both Deployments set their own data directory and root key file.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import sys

path = "keyryx/manifests/59-keyryx.yaml"
if not os.path.exists(path):
    print(f"witness-is-separate: {path} is absent, so this gate measured NOTHING")
    sys.exit(1)

text = open(path).read()
docs = re.split(r"\n---\s*\n", text)


def deployment(name):
    for d in docs:
        if re.search(r"^kind:\s*Deployment\s*$", d, re.M) and re.search(
                rf"^  name:\s*{name}\s*$", d, re.M):
            return d
    return None


custody = deployment("keyryx-custody")
witness = deployment("keyryx-witness")
bad = []
if custody is None or witness is None:
    print("witness-is-separate: the custody or witness Deployment is absent,"
          " so this gate measured NOTHING")
    sys.exit(1)


def sa(d):
    m = re.search(r"serviceAccountName:\s*(\S+)", d)
    return m.group(1) if m else None


def uid(d):
    m = re.search(r"runAsUser:\s*(\d+)", d)
    return int(m.group(1)) if m else None


if sa(custody) is None or sa(witness) is None or sa(custody) == sa(witness):
    bad.append("the two Deployments do not name two different ServiceAccounts")
if uid(custody) is None or uid(witness) is None or uid(custody) == uid(witness):
    bad.append("the two Deployments do not run as two different uids")
if uid(custody) == 0 or uid(witness) == 0:
    bad.append("a Keyryx role runs as uid 0")

for label, d in (("custody", custody), ("witness", witness)):
    for m in re.finditer(r"claimName:\s*(\S+)", d):
        claim = m.group(1)
        if claim not in ("keyryx-state", "keyryx-witness-state", "stack-events"):
            bad.append(f"{label} mounts an unexpected claim {claim}")
if "claimName: keyryx-witness-state" in custody or "claimName: keyryx-state" in witness:
    bad.append("a role mounts the other role's state claim")
if "secretName: keyryx-witness-root" in custody or "secretName: keyryx-root" in witness:
    bad.append("a role mounts the other role's root key Secret")
if "claimName: stack-events" in custody:
    bad.append("custody mounts the event streams")

# The witness's stack-events mount must be read only. Read the volumeMount that
# names the events volume and look for readOnly: true in the lines after it.
mount = re.search(r"-\s*name:\s*events\s*\n\s*mountPath:[^\n]*\n(\s*readOnly:\s*true)?",
                  witness)
if mount is None or mount.group(1) is None:
    bad.append("the witness mounts the event streams without readOnly: true")

alerts = re.search(r"KEYRYX_WITNESS_ALERTS\s*\n?\s*value:\s*\"?([^\"\n]+)", witness)
if alerts is None:
    bad.append("the witness does not name its alert file (KEYRYX_WITNESS_ALERTS)")
elif alerts.group(1).startswith("/var/lib/agent-stack") or "/events" in alerts.group(1):
    bad.append("the witness writes its alerts into the event directory")

for label, d, data in (("custody", custody, "/var/lib/keyryx/"),
                       ("witness", witness, "/var/lib/keyryx-witness/")):
    if "KEYRYX_DATA" not in d and "KEYRYX_WITNESS_DATA" not in d:
        bad.append(f"{label} does not set its own data directory")

if bad:
    for b in bad:
        print("FAIL " + b)
    sys.exit(1)

print("OK: custody and witness share no ServiceAccount, uid, state claim or root key;"
      " the witness reads the event streams read-only and writes its alerts elsewhere.")
PY
