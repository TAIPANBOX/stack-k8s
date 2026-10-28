#!/usr/bin/env bash
# CLAUDE.md invariant 74. The stack runs tokenfuse v1.20.2, pinned by tag and digest, and each tokenfuse door accepts
# a proof only for the addresses that door is reached at (tokenfuse invariant 141). So each door names only its own
# service's two origins, the Service name and the cluster-internal name. wardryx's agent-token door names all four,
# because it verifies the proof of an agent calling either service. A proof minted for one door is therefore refused
# at the other, which keeps the audience binding of each door.
#
# WHAT THIS CHECKS
#
#   1. manifests/10-planes.yaml and manifests/52-tokenfuse-mcp-broker.yaml: every tokenfuse image is the release pin
#      below (tokenfuse and tokenfuse-control-plane, each by tag and digest).
#   2. The gateway's Deployment: TOKENFUSE_DELEGATION_ORIGINS names exactly the gateway's own two origins, and its
#      single origin, TOKENFUSE_DELEGATION_URL, is one of them.
#   3. The broker's Deployment: TOKENFUSE_DELEGATION_ORIGINS and TOKENFUSE_MCP_PROOF_ORIGINS each name exactly the
#      broker's own two origins, and its single origin, TOKENFUSE_DELEGATION_URL, is one of them.
#   4. wardryx's Deployment: WARDRYX_AGENT_TOKEN_DOOR_ORIGINS names exactly the union of the gateway's and the
#      broker's own origins.
#   5. Every entry in those lists is an origin, scheme://host[:port] with nothing after the port.
#
# An absent subject is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
import sys

PINS = {
    "tokenfuse": ("v1.20.2", "sha256:a7462174b4d5e312dc3f177700d140c92090bf7bd4af8c3185f09fbfafb556af"),
    "tokenfuse-control-plane": ("v1.20.2", "sha256:4eb1723763796ee8df19dd427296c6fe84fbda539b47c71c83ff6f56f9fad5c4"),
}
GATEWAY = ["http://tokenfuse-gateway:4100", "http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100"]
BROKER = ["http://tokenfuse-mcp-broker:4200", "http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200"]
WARDRYX = GATEWAY + BROKER
ORIGIN = re.compile(r"^https?://[a-z0-9.-]+(:[0-9]{1,5})?$")
bad = []


def read(path):
    try:
        return open(path).read()
    except OSError:
        print(f"FAIL {path} is absent: the tokenfuse pins and door origins are measured NOTHING")
        sys.exit(1)


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


def deployment(text, name):
    for d in re.split(r"\n---\s*\n", text):
        if re.search(r"^kind: Deployment\s*$", d, re.M) and re.search(r"^  name: %s\s*$" % re.escape(name), d, re.M):
            return live(d)
    return None


def env_value(doc, name):
    m = re.search(r'name: %s, value: "([^"]*)"' % re.escape(name), doc)
    return None if m is None else m.group(1)


def check_list(label, doc, name, expected, must_contain=None):
    value = env_value(doc, name)
    if value is None:
        bad.append(f"{label}: {name} is not set")
        return
    entries = value.split(",")
    for e in entries:
        if not ORIGIN.match(e):
            bad.append(f"{label}: {name} entry {e!r} is not an origin (scheme://host[:port], nothing after the port)")
    if sorted(entries) != sorted(expected):
        bad.append(f"{label}: {name} is {','.join(entries)}, and must name exactly {','.join(expected)}")
    if must_contain is not None and must_contain not in entries:
        bad.append(f"{label}: TOKENFUSE_DELEGATION_URL {must_contain} is not one of its {name}")


p10 = read("manifests/10-planes.yaml")
p52 = read("manifests/52-tokenfuse-mcp-broker.yaml")

for path, text in (("manifests/10-planes.yaml", p10), ("manifests/52-tokenfuse-mcp-broker.yaml", p52)):
    found = re.findall(r"image: ghcr\.io/taipanbox/(tokenfuse(?:-control-plane)?):([^@\s]+)@(sha256:[0-9a-f]{64})", live(text))
    if not found:
        print(f"FAIL {path} names no tokenfuse image: the tokenfuse pin is measured NOTHING")
        sys.exit(1)
    for name, tag, dig in found:
        if (tag, dig) != PINS[name]:
            bad.append(f"{path}: {name} is {tag}@{dig}, which is not the release pin {PINS[name][0]}@{PINS[name][1]}")

gw = deployment(p10, "tokenfuse-gateway")
if gw is None:
    print("FAIL manifests/10-planes.yaml has no tokenfuse-gateway Deployment: the gateway's origins are measured NOTHING")
    sys.exit(1)
check_list("tokenfuse-gateway", gw, "TOKENFUSE_DELEGATION_ORIGINS", GATEWAY,
           must_contain=env_value(gw, "TOKENFUSE_DELEGATION_URL"))

wf = deployment(p10, "wardryx")
if wf is None:
    print("FAIL manifests/10-planes.yaml has no wardryx Deployment: the agent-token door's origins are measured NOTHING")
    sys.exit(1)
check_list("wardryx", wf, "WARDRYX_AGENT_TOKEN_DOOR_ORIGINS", WARDRYX)

br = deployment(p52, "tokenfuse-mcp-broker")
if br is None:
    print("FAIL manifests/52-tokenfuse-mcp-broker.yaml has no tokenfuse-mcp-broker Deployment: the broker's origins are measured NOTHING")
    sys.exit(1)
for n in ("TOKENFUSE_DELEGATION_ORIGINS", "TOKENFUSE_MCP_PROOF_ORIGINS"):
    check_list("tokenfuse-mcp-broker", br, n, BROKER, must_contain=env_value(br, "TOKENFUSE_DELEGATION_URL"))

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 74.")
    sys.exit(1)
print("OK: the stack runs tokenfuse v1.20.2 by tag and digest; each tokenfuse door names only its own two origins, wardryx's agent-token door names their union, and every entry is an origin.")
PY
