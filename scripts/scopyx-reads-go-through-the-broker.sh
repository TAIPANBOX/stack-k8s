#!/usr/bin/env bash
# CLAUDE.md invariant 78 (G2.1). A read of the web by an agent passes tokenfuse's MCP broker, which labels the
# run from the act, and nothing else can reach scopyx.
#
# From tokenfuse v1.21.0 the broker reports the fetch it saw to the gateway, so the run carries the `web` label
# from the act and not from a tool name the agent reported. That only holds if the read cannot go round the
# broker: scopyx admits the broker and nobody else, the key that opens it is in the broker's vault and the agent
# holds a handle, and an agent pod can reach the broker.
#
# WHAT THIS CHECKS (text of the manifests, comments skipped)
#
#   A. manifests/52, the broker. Its upstream list names scopyx at http://scopyx:4300. Its classification is
#      `scopyx=web`, and the taint gateway that classification needs is set (the broker exits 2 on a label with no
#      gateway). TOKENFUSE_MCP_REQUIRE_SECRET_SCOPES is 1, and TOKENFUSE_MCP_SECRET_SCOPES is NOT an env value of
#      the Deployment: an env value shadows envFrom, so a literal there would hide the per-agent rules the
#      operator adds to the Secret. `broker-egress-scopyx` lets the broker reach app: scopyx on 4300, and only that.
#   B. manifests/47 and 48, scopyx. Both take the key in params._meta (SCOPYX_ACCEPT_KEY_IN_META). 47's
#      `scopyx-ingress` admits the broker on 4300 and nothing else: not a plane, not the console.
#   C. manifests/58, the agent-token pods. They may reach the broker on 4200, and the broker admits them on 4200.
#   D. The whole of manifests/. No NetworkPolicy lets a pod other than the broker reach app: scopyx, and no
#      ingress rule other than `scopyx-ingress` selects scopyx.
#
# An absent subject is "measured NOTHING", never a pass.
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import re
import sys

bad = []


def read(path):
    try:
        return open(path).read()
    except OSError:
        print(f"FAIL {path} is absent: the scopyx wiring is measured NOTHING")
        sys.exit(1)


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


def docs(text):
    return re.split(r"\n---\s*\n", text)


def named(text, kind, name):
    for d in docs(text):
        if re.search(r"^kind: %s\s*$" % kind, d, re.M) and re.search(r"^  name: %s\s*$" % re.escape(name), d, re.M):
            return live(d)
    return None


def env_value(doc, name):
    m = re.search(r'name: %s, value: "([^"]*)"' % re.escape(name), doc)
    return None if m is None else m.group(1)


# ---- A. the broker ----------------------------------------------------------------------------------------
t52 = read("manifests/52-tokenfuse-mcp-broker.yaml")
broker = named(t52, "Deployment", "tokenfuse-mcp-broker")
if broker is None:
    print("FAIL manifests/52 has no Deployment tokenfuse-mcp-broker: the broker's wiring is measured NOTHING")
    sys.exit(1)
ups = env_value(broker, "TOKENFUSE_MCP_UPSTREAMS")
if ups is None or "scopyx=http://scopyx:4300" not in ups.split(","):
    bad.append("manifests/52: TOKENFUSE_MCP_UPSTREAMS does not name scopyx=http://scopyx:4300, so an agent has no way to reach scopyx")
if env_value(broker, "TOKENFUSE_MCP_UPSTREAM_LABELS") != "scopyx=web":
    bad.append("manifests/52: TOKENFUSE_MCP_UPSTREAM_LABELS is not exactly scopyx=web, so a read through the broker is not labelled from the act")
gw = env_value(broker, "TOKENFUSE_MCP_TAINT_GATEWAY")
if not gw:
    bad.append("manifests/52: TOKENFUSE_MCP_TAINT_GATEWAY is empty or absent, and the broker exits 2 on a classification with no taint gateway")
if env_value(broker, "TOKENFUSE_MCP_REQUIRE_SECRET_SCOPES") != "1":
    bad.append("manifests/52: TOKENFUSE_MCP_REQUIRE_SECRET_SCOPES is not 1, so a vault entry with no rule is resolvable by any agent for any tool")
if re.search(r"name: TOKENFUSE_MCP_SECRET_SCOPES\b", broker):
    bad.append("manifests/52: TOKENFUSE_MCP_SECRET_SCOPES is an env value of the Deployment; it shadows the Secret, so the rules the operator adds there for each agent are never read")
pol = named(t52, "NetworkPolicy", "broker-egress-scopyx")
if pol is None:
    bad.append("manifests/52: no NetworkPolicy broker-egress-scopyx, so the broker cannot reach scopyx under default deny")
else:
    if not re.search(r"podSelector: \{ matchLabels: \{ app: tokenfuse-mcp-broker \} \}\s*\n\s*policyTypes: \[\"Egress\"\]", pol):
        bad.append("manifests/52: broker-egress-scopyx does not select the broker for Egress")
    tos = re.findall(r"podSelector: \{ matchLabels: \{ app: ([a-z-]+) \} \}", pol.split("egress:", 1)[-1])
    ports = re.findall(r"port: (\d+)", pol)
    if tos != ["scopyx"] or ports != ["4300"]:
        bad.append(f"manifests/52: broker-egress-scopyx reaches {tos} on {ports}, not scopyx on 4300 alone")

# ---- B. scopyx -------------------------------------------------------------------------------------------
t47 = read("manifests/47-scopyx.yaml")
t48 = read("manifests/48-scopyx-browser.yaml")
for label, text in (("manifests/47", t47), ("manifests/48", t48)):
    dep = named(text, "Deployment", "scopyx")
    if dep is None:
        bad.append(f"{label}: no Deployment scopyx")
    elif env_value(dep, "SCOPYX_ACCEPT_KEY_IN_META") != "1":
        bad.append(f"{label}: scopyx does not take the key in params._meta (SCOPYX_ACCEPT_KEY_IN_META), so the broker cannot hand it the key")
ing = named(t47, "NetworkPolicy", "scopyx-ingress")
if ing is None:
    bad.append("manifests/47: no NetworkPolicy scopyx-ingress, so who may reach scopyx is not stated")
else:
    froms = re.findall(r"podSelector: \{ matchLabels: \{ ([a-z]+): ([a-z-]+) \} \}", ing.split("ingress:", 1)[-1])
    if froms != [("app", "tokenfuse-mcp-broker")]:
        bad.append(f"manifests/47: scopyx-ingress admits {froms}, not the MCP broker alone: a pod that reaches scopyx reads the web without the broker's label")
    if re.findall(r"port: (\d+)", ing) != ["4300"]:
        bad.append("manifests/47: scopyx-ingress is not on port 4300 alone")

# ---- C. the agent-token pods ----------------------------------------------------------------------------
t58 = read("manifests/58-agent-tokens-network.yaml")
eg = named(t58, "NetworkPolicy", "agent-token-pods-egress")
if eg is None or not re.search(r"app: tokenfuse-mcp-broker \} \}\s*\n\s*ports:\s*\n\s*- \{ protocol: TCP, port: 4200 \}", eg):
    bad.append("manifests/58: agent-token-pods-egress does not let an agent pod reach the broker on 4200, so it cannot read the web")
bi = named(t58, "NetworkPolicy", "broker-ingress-agent-token-pods")
if bi is None:
    bad.append("manifests/58: no NetworkPolicy broker-ingress-agent-token-pods, so the broker does not admit an agent pod")
else:
    if not re.search(r"podSelector: \{ matchLabels: \{ app: tokenfuse-mcp-broker \} \}\s*\n\s*policyTypes: \[\"Ingress\"\]", bi):
        bad.append("manifests/58: broker-ingress-agent-token-pods does not select the broker for Ingress")
    if not re.search(r"taipanbox\.dev/agent-token: \"true\"", bi) or re.findall(r"port: (\d+)", bi) != ["4200"]:
        bad.append("manifests/58: broker-ingress-agent-token-pods is not the agent-token pods on 4200 alone")

# ---- D. nothing else reaches scopyx --------------------------------------------------------------------
seen = 0
for path in sorted(glob.glob("manifests/*.yaml")):
    for d in docs(read(path)):
        if not re.search(r"^kind: NetworkPolicy\s*$", d, re.M):
            continue
        seen += 1
        d = live(d)
        name = (re.search(r"^  name: (\S+)", d, re.M) or [None, "?"])[1]
        sel = re.search(r"^  podSelector: \{ matchLabels: \{ app: ([a-z-]+) \} \}", d, re.M)
        subject = sel.group(1) if sel else None
        egress = d.split("egress:", 1)[1] if "egress:" in d else ""
        if re.search(r"app: scopyx\b", egress) and subject != "tokenfuse-mcp-broker":
            bad.append(f"{path}: NetworkPolicy {name} lets {subject or 'a selector this gate cannot read'} reach scopyx; only the broker may")
        if subject == "scopyx" and "ingress:" in d and name != "scopyx-ingress":
            bad.append(f"{path}: NetworkPolicy {name} admits traffic into scopyx; scopyx-ingress is the one rule that says who")
if seen == 0:
    print("FAIL no NetworkPolicy was read under manifests/: who may reach scopyx is measured NOTHING")
    sys.exit(1)

if bad:
    for b in bad:
        print("FAIL " + b)
    sys.exit(1)
print(f"OK: the broker fronts scopyx and labels it scopyx=web with its taint gateway set and its secret scopes required; scopyx takes the key in _meta and admits the broker alone; an agent-token pod reaches the broker on 4200; none of {seen} NetworkPolicies lets another pod reach scopyx.")
PY
