#!/usr/bin/env bash
# CLAUDE.md invariant 74. The stack runs tokenfuse v1.20.0, pinned by tag and digest, and the gateway and the MCP
# broker name every address they are reached at in the cluster as their door origins. TOKENFUSE_DELEGATION_ORIGINS
# and TOKENFUSE_MCP_PROOF_ORIGINS are read beside the single-origin variables (tokenfuse invariant 141): a proof is
# accepted when its htu names one of them at the route's path, so a list that omits an address refuses every caller
# that reaches the door at that address.
#
# WHAT THIS CHECKS
#
#   1. manifests/10-planes.yaml and manifests/52-tokenfuse-mcp-broker.yaml: every tokenfuse image is the release pin
#      below (tokenfuse and tokenfuse-control-plane, each by tag and digest).
#   2. The gateway's Deployment carries TOKENFUSE_DELEGATION_ORIGINS, and that list is exactly the gateway's
#      addresses below. Its single origin, TOKENFUSE_DELEGATION_URL, is one of them.
#   3. The broker's Deployment carries TOKENFUSE_DELEGATION_ORIGINS and TOKENFUSE_MCP_PROOF_ORIGINS, each exactly the
#      broker's addresses below. Its single origin, TOKENFUSE_DELEGATION_URL, is one of them.
#   4. Every entry in those lists is an origin, scheme://host[:port] with nothing after the port.
#
# An absent subject is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
import sys

PINS = {
    "tokenfuse": ("v1.20.0", "sha256:84f6856dcfe609410429774c965bbc531d063b29c640871dd44b1c34b07ba628"),
    "tokenfuse-control-plane": ("v1.20.0", "sha256:ab2510b3687455341fcc207361b8ed4801c4c7460f3ddc8b243603b6a982ca88"),
}
GATEWAY = ["http://tokenfuse-gateway:4100", "http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100"]
BROKER = ["http://tokenfuse-mcp-broker:4200", "http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200"]
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
    docs = re.split(r"\n---\s*\n", text)
    for d in docs:
        if re.search(r"^kind: Deployment\s*$", d, re.M) and re.search(r"^  name: %s\s*$" % re.escape(name), d, re.M):
            return live(d)
    return None


def env_value(doc, name):
    m = re.search(r'name: %s, value: "([^"]*)"' % re.escape(name), doc)
    return None if m is None else m.group(1)


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


def origins_of(doc, label, names):
    if doc is None:
        return None
    for n in names:
        value = env_value(doc, n)
        if value is None:
            bad.append(f"{label}: the Deployment sets no {n}, so the door is measured NOTHING")
            continue
        entries = value.split(",")
        for e in entries:
            if not ORIGIN.match(e):
                bad.append(f"{label}: {n} entry {e!r} is not an origin (scheme://host[:port], nothing after the port)")
        return n, entries
    return None


gw = deployment(p10, "tokenfuse-gateway")
if gw is None:
    print("FAIL manifests/10-planes.yaml has no tokenfuse-gateway Deployment: the gateway's origins are measured NOTHING")
    sys.exit(1)
gw_url = env_value(gw, "TOKENFUSE_DELEGATION_URL")
got = origins_of(gw, "tokenfuse-gateway", ["TOKENFUSE_DELEGATION_ORIGINS"])
if got is not None:
    _, entries = got
    if sorted(entries) != sorted(GATEWAY):
        bad.append(f"tokenfuse-gateway: TOKENFUSE_DELEGATION_ORIGINS is {','.join(entries)}, and must name exactly {','.join(GATEWAY)}")
    if gw_url not in entries:
        bad.append(f"tokenfuse-gateway: TOKENFUSE_DELEGATION_URL {gw_url} is not one of its TOKENFUSE_DELEGATION_ORIGINS")
else:
    bad.append("tokenfuse-gateway: TOKENFUSE_DELEGATION_ORIGINS is not set")

br = deployment(p52, "tokenfuse-mcp-broker")
if br is None:
    print("FAIL manifests/52-tokenfuse-mcp-broker.yaml has no tokenfuse-mcp-broker Deployment: the broker's origins are measured NOTHING")
    sys.exit(1)
br_url = env_value(br, "TOKENFUSE_DELEGATION_URL")
for n in ("TOKENFUSE_DELEGATION_ORIGINS", "TOKENFUSE_MCP_PROOF_ORIGINS"):
    got = origins_of(br, "tokenfuse-mcp-broker", [n])
    if got is None:
        if env_value(br, n) is None:
            bad.append(f"tokenfuse-mcp-broker: {n} is not set")
        continue
    _, entries = got
    if sorted(entries) != sorted(BROKER):
        bad.append(f"tokenfuse-mcp-broker: {n} is {','.join(entries)}, and must name exactly {','.join(BROKER)}")
    if br_url not in entries:
        bad.append(f"tokenfuse-mcp-broker: TOKENFUSE_DELEGATION_URL {br_url} is not one of its {n}")

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 74.")
    sys.exit(1)
print("OK: the stack runs tokenfuse v1.20.0 by tag and digest, and the gateway and the MCP broker name every address they are reached at as their door origins; every entry is an origin.")
PY
