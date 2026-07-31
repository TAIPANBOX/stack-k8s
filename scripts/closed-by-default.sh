#!/usr/bin/env bash
# Enforces invariant 3 of CLAUDE.md: the stack comes up closed.
#
# `kubectl apply -k manifests/` is the standard install command, and what it
# includes is a decision made on the operator's behalf. Two files are excluded
# from `resources:` on purpose, and the kustomization says why at length:
#
#   50-loadbalancer.yaml   publishes the console on a public address AND starts
#                          a meter. Over plain HTTP that is a sign-in page
#                          served to the whole internet, and a Hetzner lb11
#                          bills hourly from the moment it exists.
#   secrets.example.yaml   holds placeholders, and applying placeholders is how
#                          a cluster ends up authenticating with REPLACE_ME.
#
# Both exclusions are one careless `resources:` edit away from being undone, and
# neither failure announces itself: the first shows up as a working install with
# an unexpected public address and an unexpected invoice, the second as a
# cluster that authenticates and should not.
#
# So this check reads kustomization.yaml, resolves every file it does include,
# and fails if any of them publishes beyond the cluster or is the placeholder
# secrets file.
#
# This file is the ONE copy of this check. The local hook calls it, and CI would
# call the same file if this repo ever gets CI.

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

kustomization = pathlib.Path("manifests/kustomization.yaml")
text = kustomization.read_text()

# resources: is a plain list of filenames. Parsed by hand rather than with a
# YAML library so this script keeps the repo's zero-extra-tooling posture.
m = re.search(r"^resources:\s*$", text, re.M)
if not m:
    print(f"FAIL: no resources: block in {kustomization}")
    sys.exit(1)

resources = []
for line in text[m.end():].splitlines():
    if not line.strip():
        continue
    item = re.match(r"^\s*-\s+(\S+)\s*$", line)
    if not item:
        break  # end of the list
    resources.append(item.group(1))

if not resources:
    print(f"FAIL: resources: block in {kustomization} is empty")
    sys.exit(1)

EXPOSING = re.compile(r"^\s*type:\s*(LoadBalancer|NodePort)\s*$", re.M)
HOST_NET = re.compile(r"^\s*hostNetwork:\s*true\s*$", re.M)
HOST_PORT = re.compile(r"^\s*hostPort:\s*\d+", re.M)

fail = False

for name in resources:
    path = pathlib.Path("manifests") / name

    if not path.exists():
        print(f"FAIL: kustomization lists {name}, which does not exist")
        fail = True
        continue

    if path.name == "secrets.example.yaml":
        print(f"FAIL: {name} is in resources: and holds placeholder secrets")
        print("      Applying placeholders is how a cluster ends up")
        print("      authenticating with the word REPLACE_ME.")
        fail = True
        continue

    body = path.read_text()

    m2 = EXPOSING.search(body)
    if m2:
        kind = m2.group(1)
        line = body[: m2.start()].count("\n") + 1
        print(f"FAIL: {name}:{line} is in the default apply set and is a {kind} Service")
        print("      The standard install must not publish the stack, and on a")
        print("      managed cloud a LoadBalancer also starts billing the hour")
        print("      it is created. Keep it out of resources: and let the")
        print("      operator apply it explicitly.")
        fail = True

    if HOST_NET.search(body) or HOST_PORT.search(body):
        print(f"FAIL: {name} uses hostNetwork or hostPort in the default apply set")
        print("      That reaches the node's own interfaces, which is the same")
        print("      exposure by another route.")
        fail = True

if fail:
    print()
    print("The stack comes up closed. Publishing it is the operator's explicit")
    print("decision and, on a managed cloud, their explicit spend.")
    print("See CLAUDE.md invariant 3.")
    sys.exit(1)

print(f"OK: {len(resources)} manifests in the default apply set, none publishes beyond the cluster.")
PY
