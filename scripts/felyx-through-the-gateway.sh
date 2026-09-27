#!/usr/bin/env bash
# CLAUDE.md invariant 25: Felyx, the console's copilot, reaches its model
# through this stack's own gateway by default, and nothing in manifests/ lets it
# go around the gateway.
#
# WHAT THIS CHECKS, in manifests/20-console.yaml's console container:
#   GENARYX_COPILOT_BASE_URL is the gateway Service (http://tokenfuse-gateway:4100),
#   GENARYX_COPILOT_LOCAL_HOSTNAMES allow-lists exactly that Service name,
#   GENARYX_COPILOT_AGENT_ID is built from TRAILRYX_TRUST_DOMAIN;
# and in every file under manifests/: no GENARYX_COPILOT_ALLOW_REMOTE, which
# would skip the residency check and send Felyx past the meter.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no console container, or no copilot
# variable in it at all, is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re, sys, pathlib
errors = []
console = pathlib.Path("manifests/20-console.yaml")
if not console.exists():
    print("FAIL: manifests/20-console.yaml is gone, so this measured nothing"); sys.exit(1)
env = {}
for m in re.finditer(r"-\s*\{\s*name:\s*(GENARYX_COPILOT_\w+),\s*value:\s*\"([^\"]*)\"\s*\}", console.read_text()):
    env[m.group(1)] = m.group(2)
if not env:
    print("FAIL: the console carries no GENARYX_COPILOT_* variable, so this measured nothing"); sys.exit(1)
want = {
    "GENARYX_COPILOT_BASE_URL": "http://tokenfuse-gateway:4100",
    "GENARYX_COPILOT_LOCAL_HOSTNAMES": "tokenfuse-gateway",
}
for k, v in want.items():
    if env.get(k) != v:
        errors.append(f"{console}: {k} is {env.get(k)!r}, not {v!r}: Felyx would not reach its model through this stack's gateway")
aid = env.get("GENARYX_COPILOT_AGENT_ID", "")
if aid != "agent://$(TRAILRYX_TRUST_DOMAIN)/genaryx/felyx":
    errors.append(f"{console}: GENARYX_COPILOT_AGENT_ID is {aid!r}: Felyx's agent id must follow the install's trust domain")
for f in sorted(pathlib.Path("manifests").glob("*.yaml")):
    for n, line in enumerate(f.read_text().splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        if "GENARYX_COPILOT_ALLOW_REMOTE" in line:
            errors.append(f"{f}:{n} sets GENARYX_COPILOT_ALLOW_REMOTE: Felyx would skip the residency check and go around the gateway")
if errors:
    for e in errors: print(f"FAIL: {e}")
    sys.exit(1)
print("OK: Felyx reaches its model through tokenfuse-gateway by Service name, under agent://<trust domain>/genaryx/felyx, and no manifest lets it go around.")
PY
