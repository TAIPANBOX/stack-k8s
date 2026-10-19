#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 54 as amended on 2026-10-19: the agent token is the door credential
# of the default install, and every door verifies it the same way.
#
# WHY
#
# An agent token is a credential a stopped agent could keep using if a door did not honour the
# revocation list, and a door that accepts a token for any audience lets a token minted for another
# service in. Each door needs the same five settings to fail closed: the issuer, the one audience,
# a revocation list that fails closed, a bound on how old that list may be, and the same JWKS. A
# drift in any one is silent: an empty audience admits any, a list that fails open keeps a stopped
# agent working while vouchryx is down, and a door left on `accept` admits static keys beside the
# tokens. So the values are read here and compared with the value that is correct.
#
# WHAT THIS CHECKS
#
#   1. the gateway (manifests/10-planes.yaml) runs TOKENFUSE_AGENT_TOKENS=require under the
#      governed profile, with the issuer, the one audience, a closed revocation list at most 60 s
#      old, and a JWKS file its init container fetches from vouchryx's own /.well-known/jwks.json.
#   2. the MCP broker (manifests/52-tokenfuse-mcp-broker.yaml) runs the same door: require, the
#      same audience, the same revocation settings, and its tool-call check closed with its own key.
#   3. vouchryx (manifests/54-delegation.yaml) allows that audience and no other, and issues under
#      the issuer the doors verify against.
#   4. the agent-pod network (manifests/58-agent-tokens-network.yaml) is in the default set, lets an
#      agent pod reach vouchryx's port and the gateway's, and opens nothing else. It also names the MCP
#      broker as the one other caller of the gateway, on its port 4100 only: the broker's tool-call check
#      is not an agent pod, and this file must hold it without 30-network-policy.yaml's planes-ingress.
#   5. the example agent (agent-tokens/example-agent.yaml) takes no Kubernetes API token, asks for
#      the one audience, and projects a workload token for vouchryx's issuer.
#   6. agent-tokens/up.sh only writes the registry: it refuses before it writes anything, and it
#      applies no manifest (the door is on by default, so no switch remains).
#
# A subject that is gone fails: a missing file measures nothing, and this gate says so.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys
import urllib.parse

ISSUER = "http://vouchryx:4310"
# The one audience an agent token carries. tokenfuse refuses an agent audience that is not an absolute
# https URL (its invariant 126), so this is one. Nothing serves it: it names a token's audience.
AUDIENCE = "https://vouchryx.agent-stack.invalid"
JWKS = "http://vouchryx:4310/.well-known/jwks.json"
REVOCATIONS = "http://vouchryx:4310/v1/revocations"

fails = []


def fail(msg):
    fails.append(msg)


_aud = urllib.parse.urlsplit(AUDIENCE)
if _aud.scheme != "https" or not _aud.netloc:
    fail(f"the agent-token audience {AUDIENCE!r} is not an absolute https URL (tokenfuse invariant 126)")


def read(path):
    p = pathlib.Path(path)
    if not p.exists():
        fail(f"{path} is missing, so this gate measured nothing about it")
        return ""
    return p.read_text(encoding="utf-8")


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


def flow_values(text, name):
    """Every value of a one-line env entry `{ name: NAME, value: "V" }` in the file."""
    return re.findall(r'\{\s*name:\s*' + re.escape(name) + r'\s*,\s*value:\s*"([^"]*)"\s*\}', live(text))


def expect_one(path, text, name, want):
    got = flow_values(text, name)
    if got != [want]:
        fail(f"{path}: {name} must be exactly {want!r} once, found {got!r}")


GW = "manifests/10-planes.yaml"
BR = "manifests/52-tokenfuse-mcp-broker.yaml"
VX = "manifests/54-delegation.yaml"
NET = "manifests/58-agent-tokens-network.yaml"
EX = "agent-tokens/example-agent.yaml"
UP = "agent-tokens/up.sh"
KUST = "manifests/kustomization.yaml"

gw = read(GW)
br = read(BR)
vx = read(VX)
net = read(NET)
ex = read(EX)
up = read(UP)
kust = read(KUST)

# 0. the tokenfuse image that reads the governed profile and the static-key list is v1.19.0 or later
for path, text in ((GW, gw), (BR, br)):
    for m in re.finditer(r"ghcr\.io/taipanbox/tokenfuse:v(\d+)\.(\d+)\.(\d+)@sha256:[0-9a-f]{64}", live(text)):
        ver = tuple(int(x) for x in m.groups())
        if ver < (1, 19, 0):
            fail(f"{path}: tokenfuse is pinned at v{'.'.join(map(str, ver))}, which predates the governed profile and the static-key list (v1.19.0)")
# 1. the gateway
expect_one(GW, gw, "TOKENFUSE_PROFILE", "governed")
expect_one(GW, gw, "TOKENFUSE_AGENT_TOKENS", "require")
expect_one(GW, gw, "TOKENFUSE_DELEGATION_AUDIENCE", AUDIENCE)
expect_one(GW, gw, "TOKENFUSE_DELEGATION_ISSUER", ISSUER)
expect_one(GW, gw, "TOKENFUSE_DELEGATION_REVOCATIONS", REVOCATIONS)
expect_one(GW, gw, "TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE", "closed")
expect_one(GW, gw, "TOKENFUSE_DELEGATION_REVOCATIONS_MAX_AGE_SECS", "60")
expect_one(GW, gw, "TOKENFUSE_DELEGATION_JWKS", "/etc/tokenfuse/delegation/jwks.json")
def init_block(text, name):
    m = re.search(r"name: " + re.escape(name) + r"(.*?)\n      containers:", live(text), re.S)
    return m.group(1) if m else ""

if JWKS not in init_block(gw, "fetch-vouchryx-jwks"):
    fail(f"{GW}: the gateway's init container fetch-vouchryx-jwks does not fetch vouchryx's JWKS from {JWKS}, so its door has no key set")

# 2. the broker
expect_one(BR, br, "TOKENFUSE_PROFILE", "governed")
expect_one(BR, br, "TOKENFUSE_AGENT_TOKENS", "require")
expect_one(BR, br, "TOKENFUSE_DELEGATION_AUDIENCE", AUDIENCE)
expect_one(BR, br, "TOKENFUSE_DELEGATION_ISSUER", ISSUER)
expect_one(BR, br, "TOKENFUSE_DELEGATION_REVOCATIONS", REVOCATIONS)
expect_one(BR, br, "TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE", "closed")
expect_one(BR, br, "TOKENFUSE_DELEGATION_REVOCATIONS_MAX_AGE_SECS", "60")
expect_one(BR, br, "TOKENFUSE_MCP_TAINT_FAILMODE", "closed")
expect_one(BR, br, "TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE", "/run/taint/key")
if JWKS not in init_block(br, "fetch-vouchryx-jwks"):
    fail(f"{BR}: the broker's init container fetch-vouchryx-jwks does not fetch vouchryx's JWKS from {JWKS}")

# 3. vouchryx
expect_one(VX, vx, "VOUCHRYX_ALLOWED_AUDIENCES", AUDIENCE)
expect_one(VX, vx, "VOUCHRYX_ISSUER", ISSUER)

# 4. the agent-pod network: in the default set, two egress targets, no open internet
def kust_resources(text):
    m = re.search(r"^resources:\s*$", text, re.M)
    out = []
    if m:
        for line in text[m.end():].splitlines():
            if not line.strip():
                continue
            im = re.match(r"^\s*-\s+(\S+)\s*$", line)
            if not im:
                break
            out.append(im.group(1))
    return out

if NET.split("manifests/")[1] not in kust_resources(kust):
    fail(f"{NET} is not in {KUST}'s resources: an agent pod's network is part of the default install")
if re.search(r"ipBlock|0\.0\.0\.0/0", live(net)):
    fail(f"{NET} opens an ipBlock or 0.0.0.0/0 egress: agent pods may reach the open internet")
# The documents of the file, by metadata.name. The broker's door is judged on its own document, below.
BROKER_DOC = "gateway-ingress-mcp-broker"
net_docs = {}
for doc in re.split(r"(?m)^---\s*$", live(net)):
    nm = re.search(r"(?m)^  name:\s*(\S+)\s*$", doc)
    if nm:
        net_docs[nm.group(1)] = doc
agent_net = "\n".join(d for n, d in net_docs.items() if n != BROKER_DOC)
egress_targets = re.findall(r"app:\s*(\S+?)\s*\}", agent_net)
if set(egress_targets) != {"tokenfuse-gateway", "vouchryx"}:
    fail(f"{NET} selects {sorted(set(egress_targets))} as agent-pod peers, not exactly vouchryx and the gateway")

# 4b. the broker's own door into the gateway: its tool-call check (CLAUDE.md invariant 51) is a call from the
#     MCP broker to the gateway's /v1/fuse/check-tool-call. The gateway's Ingress is restricted by this file
#     as soon as it is selected here, so the broker must be named here, on the one port it calls, or the call is
#     dropped and the broker refuses every tool call closed (JSON-RPC -32004; kind run, evidence/require-agent-tokens-kind).
broker = net_docs.get(BROKER_DOC, "")
if not broker:
    fail(f"{NET} has no {BROKER_DOC}: the MCP broker's tool-call check has no door into the gateway unless 30-network-policy.yaml is also applied")
else:
    sel = re.search(r"(?ms)^spec:\s*\n\s*podSelector:(.*?)policyTypes", broker)
    if not sel or not re.search(r"app:\s*tokenfuse-gateway\s*\}", sel.group(1)):
        fail(f"{NET}: {BROKER_DOC} does not select the gateway (app: tokenfuse-gateway) for Ingress")
    if not re.search(r'policyTypes:\s*\["Ingress"\]', broker):
        fail(f"{NET}: {BROKER_DOC} does not declare Ingress in its policyTypes")
    frm = re.search(r"(?ms)^  ingress:(.*?)ports:", broker)
    frm_text = frm.group(1) if frm else ""
    if re.findall(r"app:\s*(\S+?)\s*\}", frm_text) != ["tokenfuse-mcp-broker"] or re.search(r"namespaceSelector|ipBlock", frm_text):
        fail(f"{NET}: {BROKER_DOC} does not admit exactly the MCP broker (app: tokenfuse-mcp-broker) to the gateway")
    if re.findall(r"port:\s*(\d+)", broker) != ["4100"] or re.findall(r"protocol:\s*(\w+)", broker) != ["TCP"]:
        fail(f"{NET}: {BROKER_DOC} does not open exactly TCP 4100, the gateway's port")

# 5. the example agent
pod = live(ex)[live(ex).find("kind: Deployment"):] if "kind: Deployment" in live(ex) else ""
if not re.search(r"automountServiceAccountToken:\s*false", pod) or re.search(r"automountServiceAccountToken:\s*true", live(ex)):
    fail(f"{EX} does not set automountServiceAccountToken: false on the agent pod (its Deployment)")
if f'audience: "{ISSUER}"' not in ex:
    fail(f"{EX} does not project a workload token for vouchryx's issuer {ISSUER}")
if f'value: "{AUDIENCE}"' not in ex:
    fail(f"{EX} does not ask vouchryx for the agent audience {AUDIENCE}")

# 6. agent-tokens/up.sh writes the registry and nothing else
if "Nothing was written" not in up or "--registry" not in up:
    fail(f"{UP} no longer refuses before it writes the registry")
if re.search(r"kubectl\s+apply\s+-k|patch\s+deployment\s+tokenfuse-gateway", live(up)):
    fail(f"{UP} patches a door or applies a kustomization: the door is on by default and up.sh must not switch it")

if fails:
    for f in fails:
        print(f"FAIL: {f}")
    print()
    print(f"{len(fails)} way(s) the agent-token door is not required and wired in the default install. See CLAUDE.md invariant 54.")
    sys.exit(1)

print("OK: the gateway and the broker require agent tokens under the governed profile, with one audience, a closed "
      "revocation list at most 60 s old and vouchryx's JWKS; vouchryx allows that audience only; the agent-pod network "
      "reaches vouchryx and the gateway and nothing else; the example agent takes no API token; up.sh only writes the registry.")
PY
