#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 24 as amended on 2026-10-19: vouchryx is in the default install and
# runs agents-only, with no upstream identity provider. An upstream trusted issuer stays opt-in and
# is named in advance by delegation/up.sh.
#
# WHY
#
# Agent tokens are the door credential of the default install (invariant 54), and the one service
# that issues them is vouchryx. Before this change vouchryx sat outside the default apply set and
# needed a trusted-issuers ConfigMap that only an IdP could supply, so a default install could not
# run agent tokens at all. The fix is to put it in the default set and let its IdP inputs be
# optional. That is also the shape a regression takes: one line that makes an IdP input required
# again, or one that drops the minting of vouchryx's keys, turns the default install red at start
# with nothing in the gate suite noticing. This gate reads the text for those lines.
#
# WHAT THIS CHECKS
#
# 1. manifests/kustomization.yaml names manifests/54-delegation.yaml in its resources: (vouchryx is
#    in the default install).
# 2. Every reference to the IdP inputs (the trusted-issuers ConfigMap and its JWKS volume) in
#    manifests/54-delegation.yaml is optional, so vouchryx starts with no IdP configured.
# 3. The default install mints vouchryx's keys (lib/vouchryx-mint.sh, called by the three deploy
#    scripts), and it mints them only when they are absent.
# 4. delegation/up.sh, the opt-in IdP path, still refuses before it applies anything when it is
#    not given its three inputs.
# 5. The console's delegation wiring stays opt-in (manifests/54-delegation-console-patch.yaml is
#    not in the default set, and manifests/20-console.yaml carries no GENARYX_VOUCHRYX_* variable).
#
# A subject that is gone fails: a missing file measures nothing, and this gate says so.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

KUSTOMIZATION = pathlib.Path("manifests/kustomization.yaml")
PLANE = pathlib.Path("manifests/54-delegation.yaml")
CONSOLE_PATCH = pathlib.Path("manifests/54-delegation-console-patch.yaml")
CONSOLE = pathlib.Path("manifests/20-console.yaml")
UP = pathlib.Path("delegation/up.sh")
VMINT = pathlib.Path("lib/vouchryx-mint.sh")
DEPLOYS = [pathlib.Path(p) for p in ("deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh")]

errors = []

for p in [KUSTOMIZATION, PLANE, CONSOLE_PATCH, CONSOLE, UP, VMINT] + DEPLOYS:
    if not p.exists():
        print(f"FAIL: {p} does not exist.")
        print("This measured nothing about whether vouchryx runs agents-only by default.")
        sys.exit(1)


def live(text):
    return [l for l in text.splitlines() if not l.lstrip().startswith("#")]


# 1. vouchryx is in the default apply set.
ktext = KUSTOMIZATION.read_text()
m = re.search(r"^resources:\s*$", ktext, re.M)
resources = []
if m:
    for line in ktext[m.end():].splitlines():
        if not line.strip():
            continue
        im = re.match(r"^\s*-\s+(\S+)\s*$", line)
        if not im:
            break
        resources.append(im.group(1))
if not resources:
    print(f"FAIL: {KUSTOMIZATION} has no resources: block, so this measured nothing.")
    sys.exit(1)
if PLANE.name not in resources:
    errors.append(f"{PLANE} is not in {KUSTOMIZATION}'s resources: vouchryx must be in the default install (invariant 24, amended)")

# 2. The IdP inputs are optional wherever they are read.
plane_code = live(PLANE.read_text())
for n, line in enumerate(plane_code, 1):
    if "vouchryx-trusted-issuers" in line and "optional: true" not in line:
        errors.append(f"{PLANE} line {n} reads the trusted-issuers ConfigMap without optional: true, so vouchryx needs an IdP to start")
if not any("vouchryx-trusted-issuers" in l for l in plane_code):
    errors.append(f"{PLANE} no longer names the trusted-issuers ConfigMap at all, so the opt-in IdP path has no subject")

# 3. The default install mints vouchryx's keys, only when they are absent.
vtext = VMINT.read_text()
if not re.search(r"get\s+secret\s+vouchryx-keys", vtext):
    errors.append(f"{VMINT} does not check for the Secret vouchryx-keys before minting it, so a re-run could replace the signing key")
if not re.search(r"vouchryx_mint_settle\s*\(\s*\)", vtext):
    errors.append(f"{VMINT} does not define vouchryx_mint_settle, the function the deploy scripts call")
for d in DEPLOYS:
    dtext = d.read_text()
    if "lib/vouchryx-mint.sh" not in dtext:
        errors.append(f"{d} does not source lib/vouchryx-mint.sh, so the default install would start vouchryx with no keys")
    elif not re.search(r"^\s*vouchryx_mint_settle\b", dtext, re.M):
        errors.append(f"{d} sources lib/vouchryx-mint.sh but never calls vouchryx_mint_settle")

# 4. The IdP path still refuses before it applies anything.
utext = UP.read_text()
if not re.search(r'missing:\$missing|missing="\$missing', utext) or "Nothing was applied" not in utext:
    errors.append(f"{UP} no longer refuses before applying when --issuer, --audience or --jwks-file is missing")

# 5. The console's delegation wiring stays opt-in.
ctext = KUSTOMIZATION.read_text()
if CONSOLE_PATCH.name in ctext:
    errors.append(f"{CONSOLE_PATCH} is in the default kustomization: the console's revoke wiring must stay opt-in")
for n, line in enumerate(live(CONSOLE.read_text()), 1):
    if re.search(r"GENARYX_VOUCHRYX_\w+", line):
        errors.append(f"{CONSOLE} line {n} sets a GENARYX_VOUCHRYX_* variable: the console's revoke wiring is opt-in (delegation/up.sh)")

if errors:
    for e in errors:
        print(f"FAIL: {e}")
    print()
    print(f"{len(errors)} way(s) vouchryx is not agents-only in the default install. See CLAUDE.md invariant 24.")
    sys.exit(1)

print("OK: vouchryx is in the default apply set with no IdP required, its keys are minted by the deploy only when absent, "
      "the IdP path still refuses before it applies, and the console's revoke wiring stays opt-in.")
PY
