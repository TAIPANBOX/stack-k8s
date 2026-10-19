#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 63 (2026-10-19, decision D3(b)): wardryx verifies the agent's token and
# its DPoP proof itself, and never takes the enforcement point's word for who the agent is.
#
# WHY
#
# A door (the gateway or the broker) is an enforcement point: it asks wardryx for a decision and says
# which agent is calling. Before this change wardryx believed that claim. With the five settings
# below, wardryx checks the token's signature, issuer, audience, expiry and revocation, and checks the
# proof's key binding and freshness, and answers 403 when the asserted agent is not the token's
# subject. Each setting is needed: a partial set refuses to start, and a wrong value (another issuer,
# another audience, a door origin the agents do not use) refuses every agent or admits one it should
# not. The proof must be required. Turning that off is a silent downgrade to a bearer token.
#
# WHAT THIS CHECKS
#
#   1. wardryx (manifests/10-planes.yaml) runs image v2.3.0 or later, the first release that verifies.
#   2. The five settings are present and equal to the stack's values: the issuer is vouchryx's, the
#      audience is the one the doors and vouchryx share, the JWKS and the revocation list are vouchryx's
#      own endpoints, and the door origins name the gateway and, when it is deployed, the broker.
#   3. The proof is required: WARDRYX_AGENT_TOKEN_REQUIRE_PROOF is unset or 1, never 0.
#   4. The gateway's audience (TOKENFUSE_DELEGATION_AUDIENCE) is the audience wardryx accepts.
#   5. The network lets wardryx reach vouchryx's port for its key set and revocations, and vouchryx
#      accepts that connection from wardryx and from nothing else new.
#
# A subject that is gone fails: a missing file measures nothing, and this gate says so.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

ISSUER = "http://vouchryx:4310"
AUDIENCE = "https://vouchryx.agent-stack.invalid"
JWKS_URL = "http://vouchryx:4310/.well-known/jwks.json"
REVOCATION_URL = "http://vouchryx:4310/v1/revocations"
GATEWAY_ORIGIN = "http://tokenfuse-gateway:4100"
BROKER_ORIGIN = "http://tokenfuse-mcp-broker:4200"
MIN_WARDRYX = (2, 3, 0)

PLANES = pathlib.Path("manifests/10-planes.yaml")
VOUCHRYX = pathlib.Path("manifests/54-delegation.yaml")
fails = []


def fail(msg):
    fails.append(msg)


for p in (PLANES, VOUCHRYX):
    if not p.exists():
        print(f"FAIL: {p} does not exist.")
        print("This measured nothing about whether wardryx verifies agent tokens.")
        sys.exit(1)


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


planes = live(PLANES.read_text())
vx = live(VOUCHRYX.read_text())


def flow_values(name):
    return re.findall(r'\{\s*name:\s*' + re.escape(name) + r'\s*,\s*value:\s*"([^"]*)"\s*\}', planes)


# 1. the image
m = re.search(r"ghcr\.io/taipanbox/wardryx:v(\d+)\.(\d+)\.(\d+)@sha256:[0-9a-f]{64}", planes)
if not m:
    fail(f"{PLANES}: the wardryx image is not pinned as a v<semver> tag with a sha256 digest")
else:
    ver = tuple(int(x) for x in m.groups())
    if ver < MIN_WARDRYX:
        fail(f"{PLANES}: wardryx is pinned at v{'.'.join(map(str, ver))}, which predates the agent-token check (2.3.0)")

# 2. the five settings
want = {
    "WARDRYX_AGENT_TOKEN_ISSUER": [ISSUER],
    "WARDRYX_AGENT_TOKEN_AUDIENCES": [AUDIENCE],
    "WARDRYX_AGENT_TOKEN_JWKS_URL": [JWKS_URL],
    "WARDRYX_AGENT_TOKEN_REVOCATION_URL": [REVOCATION_URL],
}
for name, value in want.items():
    got = flow_values(name)
    if got != value:
        fail(f"{PLANES}: {name} must be {value[0]!r} once, found {got!r}")
origins = flow_values("WARDRYX_AGENT_TOKEN_DOOR_ORIGINS")
if len(origins) != 1:
    fail(f"{PLANES}: WARDRYX_AGENT_TOKEN_DOOR_ORIGINS must be set once, found {origins!r}")
else:
    listed = [o.strip() for o in origins[0].split(",")]
    if GATEWAY_ORIGIN not in listed:
        fail(f"{PLANES}: WARDRYX_AGENT_TOKEN_DOOR_ORIGINS does not name the gateway {GATEWAY_ORIGIN}, so every gateway proof is refused")
    if BROKER_ORIGIN not in listed:
        fail(f"{PLANES}: WARDRYX_AGENT_TOKEN_DOOR_ORIGINS does not name the broker {BROKER_ORIGIN}, so every broker proof is refused")
    for o in listed:
        if not re.fullmatch(r"https?://[a-z0-9.\-]+:\d+", o):
            fail(f"{PLANES}: door origin {o!r} is not scheme://host:port with nothing after the port")

# 3. the proof is required
for v in flow_values("WARDRYX_AGENT_TOKEN_REQUIRE_PROOF"):
    if v != "1":
        fail(f"{PLANES}: WARDRYX_AGENT_TOKEN_REQUIRE_PROOF is {v!r}; the proof is required by default and must not be switched off")

# 4. the gateway's audience is the one wardryx accepts
gw_aud = flow_values("TOKENFUSE_DELEGATION_AUDIENCE")
if gw_aud != [AUDIENCE]:
    fail(f"{PLANES}: the gateway's TOKENFUSE_DELEGATION_AUDIENCE is {gw_aud!r}, not the audience wardryx accepts ({AUDIENCE})")

# 5. the network
kust = pathlib.Path("manifests/kustomization.yaml").read_text()
if "54-delegation.yaml" not in kust:
    fail("manifests/kustomization.yaml does not carry 54-delegation.yaml, so wardryx's key set has no source in the default install")
if not re.search(r"name:\s*wardryx-egress-vouchryx\b", vx):
    fail("manifests/54-delegation.yaml has no NetworkPolicy wardryx-egress-vouchryx, so wardryx cannot reach vouchryx")
else:
    block = re.search(r"name:\s*wardryx-egress-vouchryx\b.*?(?=\n---|\Z)", vx, re.S).group(0)
    if not re.search(r"podSelector:\s*\{\s*matchLabels:\s*\{\s*app:\s*wardryx\s*\}", block):
        fail("wardryx-egress-vouchryx does not select the wardryx pods")
    if not re.search(r"port:\s*4310", block):
        fail("wardryx-egress-vouchryx does not open port 4310")
ing = re.search(r"name:\s*vouchryx-ingress\b.*?(?=\n---|\Z)", vx, re.S)
if not ing or not re.search(r"app:\s*wardryx\b", ing.group(0)):
    fail("vouchryx-ingress does not admit wardryx, so wardryx's JWKS poll and revocation poll are refused")

if fails:
    for f in fails:
        print(f"FAIL: {f}")
    print()
    print(f"{len(fails)} way(s) wardryx does not verify agent tokens in the default install. See CLAUDE.md invariant 63.")
    sys.exit(1)

print("OK: wardryx v2.3.0 or later verifies agent tokens: the issuer, the one audience, vouchryx's JWKS and revocation "
      "list, the gateway and broker door origins; the proof is required; the gateway's audience matches; the network "
      "reaches vouchryx from wardryx.")
PY
