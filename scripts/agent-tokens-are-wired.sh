#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 54: the agent-token door is off in every default install, and
# when agent-tokens/up.sh turns it on, every setting it depends on is the one this gate names.
#
# WHY
#
# An agent token is a credential a stopped agent can keep using if one of the doors does not
# honour the revocation list. Each door is switched on by one variable and needs four more to
# fail closed: the issuer and the JWKS it verifies with, a non-empty audience, a revocation list
# that fails closed, and a bound on how old that list may be. Every one of those is a silent
# failure if it drifts: a door with no audience refuses everything or, with an empty one, accepts
# any; a list that fails open keeps a stopped agent working while vouchryx is down. So the
# values are checked here, against the value that is correct, rather than trusted to a reader.
#
# WHAT THIS CHECKS
#
#   1. the gateway patch that turns the door on: TOKENFUSE_AGENT_TOKENS is `accept`; the
#      audience is non-empty and is vouchryx's own issuer; the revocation list fails closed; its
#      age is at most 60 seconds.
#   2. no default manifest names the door, its audience or the registry: only the 58-agent-tokens
#      files do, so `kubectl apply -k manifests/` leaves the door off.
#   3. the vouchryx patch takes the registry and the workload issuer from ConfigMaps (data, not
#      literals), names one audience that is vouchryx's issuer, and mounts the workload JWKS at
#      the path agent-tokens/up.sh writes into the workload issuer line.
#   4. agent-tokens/up.sh refuses before it applies anything, never runs `apply -k`, and writes
#      that same JWKS path.
#   5. the example agent pod is labelled for the network rules, carries no Kubernetes API token,
#      and projects a token whose audience is vouchryx's issuer for at most 600 seconds, with no
#      secret read into its environment.
#   6. the network rules let agent pods reach vouchryx's port and the gateway's, and nothing
#      else; vouchryx accepts port 4310 from agent pods only.
#
# A subject that is gone fails: a missing patch file measures nothing, and this gate says so.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import pathlib
import re
import sys

ISSUER = "http://vouchryx:4310"
fails = []

def fail(msg):
    fails.append(msg)

def read(path):
    p = pathlib.Path(path)
    if not p.exists():
        fail(f"{path} is missing, so this gate measured nothing about it")
        return ""
    return p.read_text(encoding="utf-8")

def live_lines(text):
    return [l for l in text.split("\n") if not l.lstrip().startswith("#")]

def env_value(text, name):
    m = re.search(r'name:\s*' + re.escape(name) + r'\b[^\n]*\n?\s*(?:value:\s*"([^"]*)"|\{[^}]*value:\s*"([^"]*)")', text)
    if not m:
        m = re.search(r'\{\s*name:\s*' + re.escape(name) + r'\s*,\s*value:\s*"([^"]*)"', text)
        return m.group(1) if m else None
    return m.group(1) if m.group(1) is not None else m.group(2)

GW = "manifests/58-agent-tokens-gateway-patch.yaml"
VX = "manifests/58-agent-tokens-vouchryx-patch.yaml"
NET = "manifests/58-agent-tokens-network.yaml"
UP = "agent-tokens/up.sh"
EX = "agent-tokens/example-agent.yaml"
DELEG = "manifests/54-delegation.yaml"
BRK = "manifests/58-agent-tokens-broker-patch.yaml"
BRK_NET = "manifests/58-agent-tokens-broker-network.yaml"

# ---- 1. the gateway patch that turns the door on ---------------------------------------
gw = read(GW)
if gw:
    sw = [l for l in live_lines(gw) if 'TOKENFUSE_AGENT_TOKENS' in l]
    if len(sw) != 1 or env_value(gw, "TOKENFUSE_AGENT_TOKENS") != "accept":
        fail(f"{GW} does not set TOKENFUSE_AGENT_TOKENS to exactly accept once")
    aud = env_value(gw, "TOKENFUSE_DELEGATION_AUDIENCE")
    if not aud:
        fail(f"{GW} leaves TOKENFUSE_DELEGATION_AUDIENCE empty: the agent-token door refuses to start without an audience")
    elif aud != ISSUER:
        fail(f"{GW} sets the audience to {aud!r}, not vouchryx's issuer {ISSUER!r}: an agent token carries that audience")
    if env_value(gw, "TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE") != "closed":
        fail(f"{GW} does not set TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE to closed: a stopped agent would keep working while the list is unreadable")
    age = env_value(gw, "TOKENFUSE_DELEGATION_REVOCATIONS_MAX_AGE_SECS")
    if age is None or not age.isdigit() or int(age) > 60:
        fail(f"{GW} does not bound the revocation list's age at 60 seconds or less (found {age!r})")

delegation = read(DELEG)
if delegation and ISSUER not in delegation:
    fail(f"{DELEG} no longer names vouchryx's issuer {ISSUER}: the audience this gate checks against has moved")

# ---- 2. no default manifest names the door, its audience or the registry -----------------
owned = {GW, VX, NET, BRK, BRK_NET, "manifests/58-agent-tokens-gateway-unpatch.yaml", "manifests/58-agent-tokens-vouchryx-unpatch.yaml", "manifests/58-agent-tokens-broker-unpatch.yaml"}
for path in sorted(glob.glob("manifests/*.yaml")):
    if path in owned:
        continue
    for l in live_lines(pathlib.Path(path).read_text(encoding="utf-8")):
        for name in ("TOKENFUSE_AGENT_TOKENS", "VOUCHRYX_AGENTS", "VOUCHRYX_WORKLOAD_ISSUERS", "VOUCHRYX_ALLOWED_AUDIENCES"):
            if name in l:
                fail(f"{path} names {name}: a default install would turn agent tokens on; only the 58-agent-tokens files may")
                break

# ---- 3. the vouchryx patch --------------------------------------------------------------
vx = read(VX)
if vx:
    for name, key in (("VOUCHRYX_AGENTS", "agents"), ("VOUCHRYX_WORKLOAD_ISSUERS", "issuers")):
        if not re.search(r'name:\s*' + name + r'\s*\n\s*valueFrom:\s*\{\s*configMapKeyRef:\s*\{\s*name:\s*\S+,\s*key:\s*' + key + r'\s*\}', vx):
            fail(f"{VX} does not read {name} from a ConfigMap key {key}: the registry is data, and a literal would not be re-read on a change")
    if env_value(vx, "VOUCHRYX_ALLOWED_AUDIENCES") != ISSUER:
        fail(f"{VX} allows an audience other than vouchryx's issuer {ISSUER}")
    if not re.search(r'mountPath:\s*/etc/vouchryx/workload\b', vx):
        fail(f"{VX} does not mount the workload JWKS at /etc/vouchryx/workload")

# ---- 4. agent-tokens/up.sh ---------------------------------------------------------------
up = read(UP)
if up:
    if any('apply -k' in l for l in live_lines(up)):
        fail(f"{UP} runs apply -k: the default manifest set must stay untouched by this opt-in")
    if "/etc/vouchryx/workload/jwks.json" not in up:
        fail(f"{UP} writes a workload issuer line whose JWKS path is not /etc/vouchryx/workload/jwks.json")
    refuse = up.find('--registry FILE is required')
    first_apply = min([i for i in (up.find('patch deployment vouchryx'), up.find('create configmap vouchryx-agents')) if i >= 0] or [-1])
    if refuse < 0 or first_apply < 0 or refuse > first_apply:
        fail(f"{UP} does not refuse before it applies anything (the refusal must come before the first write)")
    if "vouchryx-trusted-issuers" not in up:
        fail(f"{UP} does not check for the delegation plane's trusted-issuers ConfigMap before it applies")

# ---- 5. the example agent ----------------------------------------------------------------
ex = read(EX)
if ex:
    if not re.search(r'taipanbox\.dev/agent-token:\s*"true"', ex):
        fail(f"{EX} is not labelled taipanbox.dev/agent-token: \"true\", so the network rules do not select it")
    pod = ex.split("template:", 1)[1] if "template:" in ex else ""
    if not re.search(r'automountServiceAccountToken:\s*false', pod):
        fail(f"{EX} does not turn off the default ServiceAccount token on its pod")
    if "serviceAccountName:" not in ex:
        fail(f"{EX} names no ServiceAccount of its own")
    aud = re.search(r'audience:\s*"([^"]*)"', ex)
    if not aud or aud.group(1) != ISSUER:
        fail(f"{EX} projects a token whose audience is not vouchryx's issuer {ISSUER}")
    exp = re.search(r'expirationSeconds:\s*(\d+)', ex)
    if not exp or int(exp.group(1)) > 600:
        fail(f"{EX} projects a token that lives longer than 600 seconds")
    if "secretKeyRef" in ex or "secretRef" in ex:
        fail(f"{EX} reads a Secret into its environment: an agent holds only its projected token")

# ---- 6. the network rules ----------------------------------------------------------------
net = read(NET)
if net:
    if "0.0.0.0/0" in net:
        fail(f"{NET} opens egress to 0.0.0.0/0: agent pods may reach vouchryx and the gateway, and nothing else")
    egress_targets = re.findall(r'podSelector:\s*\{\s*matchLabels:\s*\{\s*app:\s*([\w-]+)', net.split("policyTypes: [\"Ingress\"]")[0])
    if not set(egress_targets) <= {"vouchryx", "tokenfuse-gateway"}:
        fail(f"{NET} lets agent pods reach {sorted(set(egress_targets))}: only vouchryx and the gateway")
    ports = re.findall(r'port:\s*(\d+)', net)
    if not set(ports) <= {"4310", "4100"}:
        fail(f"{NET} opens ports {sorted(set(ports))}: only 4310 (vouchryx) and 4100 (the gateway)")

# ---- 7. the broker: its door, its relayed check, and the key that answers it -------------
MINT = "lib/identity-mint.sh"
brk = read(BRK)
if brk:
    if not re.search(r'TOKENFUSE_AGENT_TOKENS, value: "accept"', brk):
        fail(f"{BRK} does not turn the agent-token door on in the broker")
    if env_value(brk, "TOKENFUSE_DELEGATION_AUDIENCE") != ISSUER:
        fail(f"{BRK} does not set the broker's delegation audience to vouchryx's issuer {ISSUER}")
    if env_value(brk, "TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE") != "closed":
        fail(f"{BRK} does not fail the broker's revocation list closed")
    if env_value(brk, "TOKENFUSE_MCP_TAINT_GATEWAY") != "http://tokenfuse-gateway:4100":
        fail(f"{BRK} does not point the broker's tool-call check at the gateway")
    keyfile = env_value(brk, "TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE")
    if not keyfile:
        fail(f"{BRK}: broker key missing while the door is on: TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE is not set, so a relayed agent token is checked without a key (401)")
    else:
        mount = re.search(r'\{\s*name:\s*taint-key,\s*mountPath:\s*(\S+?),', brk) or re.search(r'mountPath:\s*(\S+)\s*\n[^\n]*name: taint-key', brk)
        if not mount or not keyfile.startswith(mount.group(1).rstrip("/") + "/"):
            fail(f"{BRK} does not mount the broker's key where TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE ({keyfile}) reads it")
        item = re.search(r'secretName:\s*broker-taint-key[^\n]*items:\s*\[\s*\{\s*key:\s*\S+,\s*path:\s*(\S+?)\s*\}', brk)
        if not item or not keyfile.endswith("/" + item.group(1)):
            fail(f"{BRK}: the Secret broker-taint-key is not projected to the file TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE names")
    if env_value(brk, "TOKENFUSE_MCP_TAINT_FAILMODE") != "closed":
        fail(f"{BRK} leaves the broker's taint check to fail open: a relayed call the gateway does not answer would pass")
brk_net = read(BRK_NET)
if brk_net:
    if "0.0.0.0/0" in brk_net:
        fail(f"{BRK_NET} opens the broker's egress to 0.0.0.0/0")
    tg = set(re.findall(r'-\s*podSelector:\s*\{\s*matchLabels:\s*\{\s*app:\s*([\w-]+)', brk_net.split("policyTypes: [\"Ingress\"]")[0]))
    if not tg <= {"tokenfuse-gateway", "vouchryx"}:
        fail(f"{BRK_NET} lets the broker reach {sorted(tg)}: only the gateway and vouchryx")
mint = read(MINT)
if mint:
    if '"key_id":"broker","unit":"broker","agents":["agent://%s/*"]' not in mint:
        fail(f"{MINT} does not mint the broker's client key (id broker) bound to agent://<trust domain>/*: the broker's relayed checks would be refused")
    if 'IDM_BROKER_SECRET=broker-taint-key' not in mint:
        fail(f"{MINT} does not make the Secret broker-taint-key the broker reads its key from")
up_s = read(UP)
if up_s and "broker-taint-key" not in up_s:
    fail(f"{UP} does not refuse a deployed broker whose key is missing")

if fails:
    for f in fails:
        print("FAIL: " + f)
    sys.exit(1)

gates = len([p for p in (GW, VX, NET, UP, EX) if pathlib.Path(p).exists()])
print(f"OK: agent tokens are off in every default manifest; the gateway patch turns the door on with a non-empty audience "
      f"({ISSUER}), a closed revocation list at most 60 s old; vouchryx takes its registry and workload issuer from ConfigMaps; "
      f"the opt-in refuses before it applies; the example agent projects a 600 s token for vouchryx and holds no secret; "
      f"agent pods reach only vouchryx and the gateway ({gates} files judged).")
PY
