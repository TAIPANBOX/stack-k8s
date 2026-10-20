#!/usr/bin/env bash
# CLAUDE.md invariant 69. Keyryx is part of every install, not opt-in: each launcher installs custody and the
# witness, signs the record through custody, and patches wardryx's approval signer through it, unless the
# operator names --without-keyryx, which is the weaker setting. The record is sealed by trailryx-node under
# the key trailryx-root, which custody holds; the witness reads the record from the shared stream directory.
#
# WHAT THIS CHECKS
#
#   1. lib/keyryx-install.sh defines keyryx_install_settle and keyryx_remove_settle, and marks the one line
#      the install cannot yet hold (the trailryx pin, TRAILRYX_KEYRYX_KID, trailryx#112) as a named TODO.
#   2. Each launcher (deploy.sh, cloud/gcp/deploy-gcp.sh, cloud/aws/deploy-aws.sh) defaults KEYRYX_INSTALL to 1,
#      parses --without-keyryx, sources the library, installs after its last `apply -k` when the default holds,
#      and removes the wiring when the operator opts out.
#   3. keyryx/record-seal-patch.yaml sets the record-seal's signer to keyryx: TRAILRYX_SIGNER, the custody URL,
#      the consumer credential file, and the label that lets the pod reach custody. It never sets
#      TRAILRYX_WITNESS_ATTESTATIONS: the record-seal patch sets it to its read-only mount, and the library never does.
#   4. keyryx/policy.json.tmpl grants trailryx-node the sign operation on trailryx-root, the key trailryx signs under.
#   5. keyryx/wardryx-patch.yaml and keyryx/wardryx-unpatch.yaml pin the same wardryx image as manifests/10-planes.yaml.
#      The patch runs after apply; a different image there would roll wardryx back on every default install.
#   6. manifests/59-keyryx.yaml gives the witness KEYRYX_WITNESS_EVENTS, the directory of the shared stream files.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
import sys

bad = []
LIB = "lib/keyryx-install.sh"
LAUNCHERS = ["deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh"]


def read(path):
    try:
        return open(path).read()
    except OSError:
        return None


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


lib = read(LIB)
if lib is None:
    bad.append(f"{LIB} is absent: the Keyryx install is measured NOTHING")
else:
    for fn in ("keyryx_install_settle()", "keyryx_remove_settle()"):
        if fn not in lib:
            bad.append(f"{LIB} does not define {fn}")
    if "keyryx_pin_trailryx_kid()" not in lib:
        bad.append(f"{LIB} does not pin the record seal to custody's trailryx-root key (keyryx_pin_trailryx_kid, invariant 73)")
    if re.search(r"TRAILRYX_WITNESS_ATTESTATIONS", live(lib)):
        bad.append(f"{LIB} sets TRAILRYX_WITNESS_ATTESTATIONS, which belongs to the record-seal patch (invariant 70)")

for path in LAUNCHERS:
    text = read(path)
    if text is None:
        bad.append(f"{path} is absent: its Keyryx step is measured NOTHING")
        continue
    t = live(text)
    if not re.search(r'^KEYRYX_INSTALL="\$\{KEYRYX_INSTALL:-1\}"', t, re.M):
        bad.append(f"{path} does not default KEYRYX_INSTALL to 1, so Keyryx is not on by default")
    if not re.search(r"--without-keyryx\)", t):
        bad.append(f"{path} does not parse --without-keyryx")
    if not re.search(r'\. "\$ROOT/lib/keyryx-install\.sh"', t):
        bad.append(f"{path} does not source lib/keyryx-install.sh")
    applies = [m.start() for m in re.finditer(r'k_ "apply -k[^"]*manifests"', t)]
    installs = [m.start() for m in re.finditer(r'^\s*keyryx_install_settle\s*$', t, re.M)]
    removes = [m.start() for m in re.finditer(r'^\s*keyryx_remove_settle\s*$', t, re.M)]
    if not installs:
        bad.append(f"{path} never calls keyryx_install_settle")
    elif not applies or installs[0] < applies[-1]:
        bad.append(f"{path} installs Keyryx before its last apply -k, so the apply reverts the wardryx patch")
    if not removes:
        bad.append(f"{path} never calls keyryx_remove_settle, so an opt-out leaves the signer on")
    if not re.search(r'if \[ "\$KEYRYX_INSTALL" = 1 \]', t):
        bad.append(f"{path} has no KEYRYX_INSTALL guard around the install and the removal")

rs = read("keyryx/record-seal-patch.yaml")
if rs is None:
    bad.append("keyryx/record-seal-patch.yaml is absent: the record-seal signer is measured NOTHING")
else:
    for name, value in (("TRAILRYX_SIGNER", "keyryx"),
                        ("TRAILRYX_KEYRYX_URL", "http://keyryx-custody.agent-stack.svc.cluster.local:4340"),
                        ("TRAILRYX_KEYRYX_CREDENTIAL_FILE", "/run/keyryx-client/credential")):
        if not re.search(rf"name: {name}\n\s+value: \"?{re.escape(value)}\"?", rs):
            bad.append(f"keyryx/record-seal-patch.yaml does not set {name}={value}")
    if not re.search(r'keyryx-consumer: "true"', rs):
        bad.append("keyryx/record-seal-patch.yaml does not label the pod keyryx-consumer, so custody refuses it")
    if not re.search(r"name: TRAILRYX_WITNESS_ATTESTATIONS\n\s+value: \"?/var/lib/stack/attestations\"?", rs):
        bad.append("keyryx/record-seal-patch.yaml does not point TRAILRYX_WITNESS_ATTESTATIONS at its attestations directory, so the seal reads no witness attestation")

pol = read("keyryx/policy.json.tmpl")
if pol is None:
    bad.append("keyryx/policy.json.tmpl is absent: the custody policy is measured NOTHING")
else:
    if not re.search(r'"name": "trailryx-root"\s*,\s*"alg": "ES384"', pol):
        bad.append("keyryx/policy.json.tmpl does not declare the ES384 key trailryx-root (the one trailryx-node pins, invariant 73)")
    if not re.search(r'"grants": \{"trailryx-root": \["sign"\]\}', pol) or "@TRAILRYX_DIGEST@" not in pol:
        bad.append("keyryx/policy.json.tmpl does not grant trailryx-node the sign operation on trailryx-root by digest")

m10 = read("manifests/10-planes.yaml") or ""
pin = re.search(r"image: (ghcr\.io/taipanbox/wardryx:v[0-9.]+@sha256:[0-9a-f]{64})", m10)
if pin is None:
    bad.append("manifests/10-planes.yaml has no wardryx image to compare the Keyryx patches with")
else:
    for path in ("keyryx/wardryx-patch.yaml", "keyryx/wardryx-unpatch.yaml"):
        body = read(path) or ""
        img = re.search(r"image: (ghcr\.io/taipanbox/wardryx:v[0-9.]+@sha256:[0-9a-f]{64})", body)
        if img is None or img.group(1) != pin.group(1):
            bad.append(f"{path} pins {img.group(1) if img else 'no image'}, but manifests/10-planes.yaml pins {pin.group(1)}: the patch would roll wardryx back")

m59 = read("keyryx/manifests/59-keyryx.yaml")
if m59 is None:
    bad.append("keyryx/manifests/59-keyryx.yaml is absent: the witness is measured NOTHING")
elif not re.search(r"name: KEYRYX_WITNESS_EVENTS\n\s+value: /var/lib/stack/events", m59):
    bad.append("keyryx/manifests/59-keyryx.yaml does not point the witness at the shared stream directory (KEYRYX_WITNESS_EVENTS)")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 69.")
    sys.exit(1)
print("OK: Keyryx is installed by default in all three launchers, opted out only by --without-keyryx; the record is sealed through custody under trailryx-root; the witness reads the stream directory; the wardryx patches pin the same image as the manifest.")
PY
