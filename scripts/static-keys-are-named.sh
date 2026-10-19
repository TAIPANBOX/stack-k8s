#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 62 (2026-10-19): a static client key is admitted at a door only when its
# key id is named on that door's allow-list, and every name on a list is a key this install mints and
# has a written reason.
#
# WHY
#
# Once agent tokens are required (invariant 54), a static key is the old credential, shared and
# unbound to any one agent. It stays admitted for the clients that cannot sign a DPoP proof, and
# only for them. The list is the whole decision, so it is kept short, named, and checked: a key id
# added to a list by hand, with no reason and no minted secret behind it, would be a second door
# nobody chose. And the operator's own clients are added through one ConfigMap, never by editing a
# manifest, so an operator's edit is not silently reverted by `apply -k` (invariant 14).
#
# WHAT THIS CHECKS
#
# 1. The gateway's list is the stack's own list followed by the operator's: exactly
#    `$(STACK_STATIC_KEY_IDS)$(OPERATOR_STATIC_KEY_IDS)` in manifests/10-planes.yaml.
# 2. STACK_STATIC_KEY_IDS names only the key ids the mint produces (felyx, agents, drills, costcrew,
#    broker), and each has a `# static key <id>: <reason>` line beside it.
# 3. OPERATOR_STATIC_KEY_IDS reads the ConfigMap gateway-static-keys, key operator_key_ids, and that
#    reference is not optional: a gateway with no operator list still starts, with an empty one.
# 4. The MCP broker's list (manifests/52-tokenfuse-mcp-broker.yaml) names only broker-caller, the key
#    the broker's own door mints (it must also be in TOKENFUSE_MCP_KEYS, or the broker refuses to start), with a reason.
# 5. No other manifest sets a static-key list.
# 6. lib/static-keys.sh creates gateway-static-keys when it is absent, and never overwrites it, and
#    the three deploy scripts call static_keys_settle.
# 7. lib/identity-mint.sh mints each of the five stack keys.
#
# A subject that is gone fails: a missing file measures nothing, and this gate says so.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

GATEWAY = pathlib.Path("manifests/10-planes.yaml")
BROKER = pathlib.Path("manifests/52-tokenfuse-mcp-broker.yaml")
MANIFESTS = pathlib.Path("manifests")
STATIC = pathlib.Path("lib/static-keys.sh")
MINT = pathlib.Path("lib/identity-mint.sh")
DEPLOYS = [pathlib.Path(p) for p in ("deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh")]

STACK_IDS = {"felyx", "agents", "drills", "costcrew", "broker"}
BROKER_IDS = {"broker-caller"}

fails = []


def fail(msg):
    fails.append(msg)


for p in [GATEWAY, BROKER, STATIC, MINT] + DEPLOYS:
    if not p.exists():
        print(f"FAIL: {p} does not exist.")
        print("This measured nothing about the static-key allow-lists.")
        sys.exit(1)


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


gw = GATEWAY.read_text()
gwl = live(gw)

m = re.search(r'\{\s*name:\s*TOKENFUSE_AGENT_TOKENS_STATIC_KEYS\s*,\s*value:\s*"([^"]*)"\s*\}', gwl)
if not m or m.group(1) != "$(STACK_STATIC_KEY_IDS)$(OPERATOR_STATIC_KEY_IDS)":
    got = m.group(1) if m else None
    fail(f"{GATEWAY}: TOKENFUSE_AGENT_TOKENS_STATIC_KEYS must be $(STACK_STATIC_KEY_IDS)$(OPERATOR_STATIC_KEY_IDS), found {got!r}")

m = re.search(r'\{\s*name:\s*STACK_STATIC_KEY_IDS\s*,\s*value:\s*"([^"]*)"\s*\}', gwl)
if not m:
    fail(f"{GATEWAY}: STACK_STATIC_KEY_IDS is not set, so the stack's allow-list is not written down anywhere")
    stack_ids = []
else:
    stack_ids = [s for s in m.group(1).split(",") if s]
    for sid in stack_ids:
        if sid not in STACK_IDS:
            fail(f"{GATEWAY}: static key {sid!r} is not one of the stack's minted keys {sorted(STACK_IDS)}")
        if not re.search(r"^\s*#\s*static key " + re.escape(sid) + r":\s*\S", gw, re.M):
            fail(f"{GATEWAY}: static key {sid!r} has no `# static key {sid}: <reason>` line beside it")
    if len(set(stack_ids)) != len(stack_ids):
        fail(f"{GATEWAY}: STACK_STATIC_KEY_IDS names a key id twice")
    for sid in sorted(STACK_IDS - set(stack_ids)):
        # A minted key left off the list is a design choice that must be written down as one.
        if not re.search(r"^\s*#\s*not static-listed: " + re.escape(sid) + r":\s*\S", gw, re.M):
            fail(f"{GATEWAY}: minted key {sid!r} is not on the static list and has no `# not static-listed: {sid}: <reason>` line")

op = re.search(r"name:\s*OPERATOR_STATIC_KEY_IDS\s*\n?\s*valueFrom:\s*\{\s*configMapKeyRef:\s*\{([^}]*)\}\s*\}", gwl)
if not op:
    op = re.search(r'\{\s*name:\s*OPERATOR_STATIC_KEY_IDS\s*,\s*valueFrom:\s*\{\s*configMapKeyRef:\s*\{([^}]*)\}\s*\}\s*\}', gwl)
if not op:
    fail(f"{GATEWAY}: OPERATOR_STATIC_KEY_IDS is not read from a ConfigMap")
else:
    ref = op.group(1)
    if "name: gateway-static-keys" not in ref.replace("name:  ", "name: "):
        fail(f"{GATEWAY}: OPERATOR_STATIC_KEY_IDS does not read ConfigMap gateway-static-keys")
    if "key: operator_key_ids" not in ref:
        fail(f"{GATEWAY}: OPERATOR_STATIC_KEY_IDS does not read key operator_key_ids")
    if "optional" in ref:
        fail(f"{GATEWAY}: OPERATOR_STATIC_KEY_IDS is optional, so a missing list would leave $(OPERATOR_STATIC_KEY_IDS) unexpanded in the gateway's list")

bl = live(BROKER.read_text())
mb = re.search(r'\{\s*name:\s*TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS\s*,\s*value:\s*"([^"]*)"\s*\}', bl)
if not mb:
    fail(f"{BROKER}: TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS is not set, so the broker's list is not written down")
else:
    for bid in [s for s in mb.group(1).split(",") if s]:
        if bid not in BROKER_IDS:
            fail(f"{BROKER}: static key {bid!r} on the broker's list is not one of {sorted(BROKER_IDS)}")
        if not re.search(r"^\s*#\s*broker static key " + re.escape(bid) + r":\s*\S", BROKER.read_text(), re.M):
            fail(f"{BROKER}: broker static key {bid!r} has no `# broker static key {bid}: <reason>` line")

for path in sorted(MANIFESTS.glob("*.yaml")):
    if path in (GATEWAY, BROKER):
        continue
    if re.search(r"AGENT_TOKENS_STATIC_KEYS", live(path.read_text())):
        fail(f"{path} sets a static-key list: the lists live only in 10-planes.yaml and 52-tokenfuse-mcp-broker.yaml")

st = STATIC.read_text()
if not re.search(r"^static_keys_settle\(\)", st, re.M):
    fail(f"{STATIC} does not define static_keys_settle")
if not re.search(r"get\s+configmap\s+gateway-static-keys", st):
    fail(f"{STATIC} does not check for the ConfigMap gateway-static-keys before creating it")
if not re.search(r"operator_key_ids", st):
    fail(f"{STATIC} never writes the key operator_key_ids")

for d in DEPLOYS:
    dt = d.read_text()
    if "lib/static-keys.sh" not in dt:
        fail(f"{d} does not source lib/static-keys.sh")
    elif not re.search(r"^\s*static_keys_settle\b", dt, re.M):
        fail(f"{d} sources lib/static-keys.sh but never calls static_keys_settle")

mt = MINT.read_text()
for kid in ("felyx", "agents", "drills", "broker", "costcrew"):
    if not re.search(r"\b" + kid + r"\b", mt):
        fail(f"{MINT} does not mint the {kid!r} client key, so the allow-list names a key no deploy makes")

if fails:
    for f in fails:
        print(f"FAIL: {f}")
    print()
    print(f"{len(fails)} way(s) a static key is admitted outside the named lists. See CLAUDE.md invariant 62.")
    sys.exit(1)

print(f"OK: the gateway admits static keys only for {sorted(stack_ids)} plus the operator's ConfigMap list; the broker admits "
      f"{sorted(x for x in (mb.group(1).split(',') if mb else []) if x)}; each id has a reason, each stack key is minted, and "
      "no other manifest names a list.")
PY
