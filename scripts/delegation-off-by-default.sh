#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 24: the delegation plane is off by default.
#
# WHY
#
# GOTCHAS.md entry 105 named the gap this closes: nothing here turned
# delegation on, so a wardryx policy carrying `deny_if_chain_unproven` or
# `require_root_principal` refused only callers honest enough to say they had
# not proven it. The fix (manifests/54-delegation.yaml, applied only by
# delegation/up.sh) must not become the thing invariant 3 already guards
# against: a plane an operator gets whether or not they asked for it. Every
# other gate here reads `manifests/*.yaml` unconditionally, so a manifest
# that is correct on its own can still be wrong by being IN the default apply
# set, which is exactly the shape closed-by-default.sh and hub-entry-is-
# narrow.sh already guard for their own opt-in files.
#
# WHAT THIS CHECKS
#
# 1. manifests/kustomization.yaml's resources: list does not name
#    manifests/54-delegation.yaml.
# 2. Neither manifests/10-planes.yaml (the gateway) nor manifests/20-console.yaml
#    (the console), the two files the default apply set DOES include, carries
#    any TOKENFUSE_DELEGATION_* or GENARYX_VOUCHRYX_* environment variable
#    name. Those only ever arrive through delegation/up.sh's two `kubectl
#    patch` calls, never through a manifest kustomize applies.
# 3. manifests/54-delegation.yaml and both patch files it names actually
#    exist, so an empty glob cannot read as agreement that delegation is off.
#
# What this does NOT check: that delegation/up.sh itself refuses without a
# trusted issuer (that is a behaviour of a script, not a fact about a
# manifest, and is exercised directly by hand in the PR that added this gate);
# and that a running cluster's gateway actually has the door shut (that needs
# a live cluster, which CLAUDE.md invariants 4 and 5 already say this
# repository cannot hold in a gate).
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

KUSTOMIZATION = pathlib.Path("manifests/kustomization.yaml")
DELEGATION = pathlib.Path("manifests/54-delegation.yaml")
GATEWAY_PATCH = pathlib.Path("manifests/54-delegation-gateway-patch.yaml")
CONSOLE_PATCH = pathlib.Path("manifests/54-delegation-console-patch.yaml")
DEFAULT_GATEWAY = pathlib.Path("manifests/10-planes.yaml")
DEFAULT_CONSOLE = pathlib.Path("manifests/20-console.yaml")

errors = []

for p in (DELEGATION, GATEWAY_PATCH, CONSOLE_PATCH):
    if not p.exists():
        print(f"FAIL: {p} does not exist.")
        print("This measured nothing about whether delegation is off by default.")
        sys.exit(1)

if not KUSTOMIZATION.exists():
    print(f"FAIL: {KUSTOMIZATION} does not exist.")
    print("This measured nothing about whether delegation is off by default.")
    sys.exit(1)

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

if DELEGATION.name in resources:
    errors.append(
        f"{DELEGATION} is listed in {KUSTOMIZATION}'s resources: it must stay "
        "opt-in, applied only by delegation/up.sh, never by the default "
        "kubectl apply -k")

DELEGATION_ENV = re.compile(r"\b(TOKENFUSE_DELEGATION_\w+|GENARYX_VOUCHRYX_\w+)\b")

for path in (DEFAULT_GATEWAY, DEFAULT_CONSOLE):
    if not path.exists():
        errors.append(f"{path} does not exist, so this measured nothing about its env vars")
        continue
    body = path.read_text()
    found = sorted(set(DELEGATION_ENV.findall(body)))
    if found:
        errors.append(
            f"{path} carries {found}, a delegation env var, in the manifest "
            "the default apply set installs. Those may only arrive through "
            "delegation/up.sh's kubectl patch, never through a manifest.")

if errors:
    for e in errors:
        print(f"FAIL: {e}")
    print()
    print(f"{len(errors)} way(s) delegation is not off by default. See CLAUDE.md invariant 24.")
    sys.exit(1)

print("OK: manifests/54-delegation.yaml stays out of the default apply set, and "
      "neither the default gateway nor the default console manifest carries a "
      "delegation env var.")
PY
