#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 77: the NetworkPolicy says which side of the line it sits on, and what it says matches
# the labels, the ports and the files the cluster actually has.
#
# WHY
#
# manifests/30-network-policy.yaml read, for months, as "the same rule the PDP enforces per call, enforced per packet".
# The agent-stack namespace holds the stack's own planes and no agent workload; the agents a customer runs are outside
# it and no policy here confines them. A header that reads as confining agents is a claim nobody had measured, and a
# reader who trusts it leaves an agent unconfined. The fix is prose, and prose drifts: the label an operator is told to
# put on an agent pod is one string that the policy, the overlay, the example, the README and the proof script all have
# to agree on, and a rename in one of them is silent. This gate reads each of them and compares.
#
# WHAT THIS CHECKS
#
#   1. manifests/58-agent-tokens-network.yaml: the policy `agent-token-pods-egress` selects exactly one label, and its
#      egress rules name the apps and ports an agent pod may reach. Those are the subject of everything below.
#   2. the header of manifests/30-network-policy.yaml states the boundary (the heading, "no agent workload", "NOT in it"),
#      names that label as key=value, names the overlay and the proof script, and no longer carries the old claim.
#   3. README.md has the section "What the NetworkPolicy confines, and where your agents run", with the same statements,
#      the same label, the manifests it names, the apps and ports 58 opens, and the evidence run it cites, which must
#      end with RUN_EXIT=0 (its two outputs, with the policy enforced and with it not). Every repository path it names exists.
#   4. the pods that carry the label (the overlay's agent, the example agent) carry exactly it, in the namespace the
#      policies apply to; the overlay is in no default apply set and no launcher applies it.
#   5. agent-tokens/confine-check.sh probes as open exactly the (app, port) pairs 58 opens, and names the same label.
#
# A subject that is gone fails: a missing file measures nothing, and this gate says so.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import os
import re
import sys

fails = []


def fail(msg):
    fails.append(msg)


def read(path):
    if not os.path.exists(path):
        fail(f"{path} is missing, so this gate measured nothing about it")
        return ""
    return open(path, encoding="utf-8").read()


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


NET30 = "manifests/30-network-policy.yaml"
NET58 = "manifests/58-agent-tokens-network.yaml"
README = "README.md"
OVERLAY_DIR = "agent-tokens/confined-agent"
OVERLAY = OVERLAY_DIR + "/agent.yaml"
OVERLAY_K = OVERLAY_DIR + "/kustomization.yaml"
OVERLAY_R = OVERLAY_DIR + "/README.md"
EXAMPLE = "agent-tokens/example-agent.yaml"
CHECK = "agent-tokens/confine-check.sh"
EVIDENCE = "evidence/agent-confinement-k3d"
KUST = "manifests/kustomization.yaml"
SECTION = "What the NetworkPolicy confines, and where your agents run"
NAMESPACE = "agent-stack"

n30, n58, readme = read(NET30), read(NET58), read(README)
overlay, overlay_k, overlay_r, example = read(OVERLAY), read(OVERLAY_K), read(OVERLAY_R), read(EXAMPLE)
check, kust = read(CHECK), read(KUST)

# ---- 1. the policy under description ----------------------------------------------------------------
docs58 = re.split(r"\n---\s*\n", live(n58))
egress_doc = next((d for d in docs58 if re.search(r"^\s*name:\s*agent-token-pods-egress\s*$", d, re.M)), "")
LABEL_KEY = LABEL_VAL = None
OPEN = set()
if not egress_doc:
    fail(f"{NET58} has no NetworkPolicy agent-token-pods-egress, so there is no policy to describe")
else:
    ns = re.search(r"^\s*namespace:\s*(\S+)\s*$", egress_doc, re.M)
    if not ns or ns.group(1) != NAMESPACE:
        fail(f"{NET58}: agent-token-pods-egress is not in namespace {NAMESPACE}")
    sel = re.search(r"podSelector:\s*\{\s*matchLabels:\s*\{([^}]*)\}\s*\}", egress_doc)
    pairs = re.findall(r'([A-Za-z0-9./-]+)\s*:\s*"?([A-Za-z0-9._-]+)"?', sel.group(1)) if sel else []
    if len(pairs) != 1:
        fail(f"{NET58}: agent-token-pods-egress must select exactly one label, found {pairs!r}")
    else:
        LABEL_KEY, LABEL_VAL = pairs[0]
    egress_part = egress_doc.split("egress:", 1)[1] if "egress:" in egress_doc else ""
    for rule in re.split(r"\n\s*-\s+to:", "\n" + egress_part)[1:]:
        app = re.search(r"matchLabels:\s*\{\s*app:\s*([A-Za-z0-9-]+)\s*\}", rule)
        port = re.search(r"port:\s*(\d+)", rule)
        if app and port:
            OPEN.add((app.group(1), int(port.group(1))))
        else:
            fail(f"{NET58}: an egress rule of agent-token-pods-egress names no app and one port: {rule.strip()!r}")
    if not OPEN:
        fail(f"{NET58}: agent-token-pods-egress has no egress rule this gate can read, so it measured nothing")

AGENT_FAMILY = re.compile(r"taipanbox\.dev/agent-[a-z-]+")
LABEL = f"{LABEL_KEY}={LABEL_VAL}" if LABEL_KEY else None


def same_label(where, text):
    """Every taipanbox.dev/agent-* label in `text` is the one 58 selects, and it is written key=value once."""
    if LABEL_KEY is None:
        return
    for tok in sorted(set(AGENT_FAMILY.findall(text))):
        if tok != LABEL_KEY:
            fail(f"{where} names a label {tok} that {NET58} does not select (it selects {LABEL_KEY})")
    if LABEL not in text:
        fail(f"{where} does not state the label as {LABEL}, the one {NET58} selects")


# ---- 2. the header of 30 ------------------------------------------------------------------------------
header_lines = []
for line in n30.split("\n"):
    if line.startswith("#"):
        header_lines.append(line)
    elif line.strip() == "" and not header_lines:
        continue
    else:
        break
header = "\n".join(header_lines)
if n30 and not header:
    fail(f"{NET30} has no leading comment block, so it states no boundary")
for need, why in (
    ("WHICH SIDE OF THE LINE THIS POLICY SITS ON", "the heading of the boundary paragraph"),
    (NAMESPACE, "the namespace the policies apply to"),
    ("no agent workload", "that the namespace holds none"),
    ("NOT in it", "that the customer's agents are outside the namespace"),
    (OVERLAY_DIR, "the overlay that puts an agent under 58"),
    (CHECK, "the script that proves it"),
):
    if header and need not in header:
        fail(f"{NET30}: the header does not say {need!r} ({why})")
if header:
    same_label(f"{NET30}: the header", header)
OLD_CLAIMS = ("enforced per packet", "governance story told at the network layer")
for old in OLD_CLAIMS:
    if old in n30:
        fail(f"{NET30} carries the old claim {old!r}, which read as confining agents it does not confine")

# ---- 3. the README ------------------------------------------------------------------------------------
section = ""
if readme:
    m = re.search(r"^#{2,3} " + re.escape(SECTION) + r"\s*$", readme, re.M)
    if not m:
        fail(f"{README} has no section {SECTION!r}")
    else:
        rest = readme[m.end():]
        nxt = re.search(r"^#{1,3} ", rest, re.M)
        section = rest[:nxt.start()] if nxt else rest
        if len(re.findall(r"^#{2,3} " + re.escape(SECTION) + r"\s*$", readme, re.M)) != 1:
            fail(f"{README} has the section {SECTION!r} more than once")
for old in OLD_CLAIMS:
    if old in readme:
        fail(f"{README} carries the old claim {old!r}")
if section:
    for need, why in (
        (NAMESPACE, "the namespace the policies apply to"),
        ("Your agents are not in it", "that the customer's agents are outside the namespace"),
        (NET30.split("/")[-1], "the default-deny file"),
        (NET58.split("/")[-1], "the agent-pod file"),
        (OVERLAY_DIR, "the overlay"),
        (CHECK, "the proof script"),
        (EVIDENCE, "the measured run it cites"),
        ("no label", "what a pod with no label gets"),
    ):
        if need not in section:
            fail(f"{README}: the section {SECTION!r} does not say {need!r} ({why})")
    same_label(f"{README}: the section {SECTION!r}", section)
    for app, port in sorted(OPEN):
        names = {app, app.split("-")[-1]}
        if not any(n in section for n in names) or str(port) not in section:
            fail(f"{README}: the section {SECTION!r} does not state {app} on port {port}, which {NET58} opens")
    for path in sorted(set(re.findall(r"`((?:manifests|agent-tokens|evidence)/[A-Za-z0-9._/-]+)`", section))):
        if not os.path.exists(path):
            fail(f"{README}: the section {SECTION!r} names {path}, which does not exist")

# the runs the README cites must have ended green
for name in ("output-enforcing.txt", "output-not-enforcing.txt"):
    path = f"{EVIDENCE}/{name}"
    if not os.path.exists(path):
        fail(f"{path} is missing, so a run the README cites is not on record")
        continue
    last = [l for l in open(path, encoding="utf-8").read().split("\n") if l.startswith("RUN_EXIT=")]
    if not last or not last[-1].startswith("RUN_EXIT=0"):
        fail(f"{path} does not end with RUN_EXIT=0 ({last[-1] if last else 'no RUN_EXIT line'})")
for must in (EVIDENCE + "/run.sh", EVIDENCE + "/standins.py"):
    if not os.path.exists(must):
        fail(f"{must} is missing, so the run the README cites cannot be repeated")

# ---- 4. the pods that carry the label, and what applies the overlay ----------------------------------------
def pod_labels(where, text):
    m = re.search(r"template:\s*\n\s*metadata:\s*\n\s*labels:\s*\{([^}]*)\}", live(text))
    if not m:
        fail(f"{where} has no Deployment pod template with a labels line this gate can read")
        return None
    return dict(re.findall(r'([A-Za-z0-9./-]+)\s*:\s*"?([A-Za-z0-9._-]+)"?', m.group(1)))


if LABEL_KEY is not None:
    for where, text in ((OVERLAY, overlay), (EXAMPLE, example)):
        labels = pod_labels(where, text) if text else None
        if labels is not None:
            if labels.get(LABEL_KEY) != LABEL_VAL:
                fail(f"{where}: the pod does not carry {LABEL}, so {NET58} does not select it (labels: {labels})")
            extra = [k for k in labels if AGENT_FAMILY.fullmatch(k) and k != LABEL_KEY]
            if extra:
                fail(f"{where}: the pod carries {extra}, another agent-token label than the {LABEL_KEY} that {NET58} selects")
if overlay:
    for m in re.finditer(r"^\s*namespace:\s*(\S+)\s*$", live(overlay), re.M):
        if m.group(1) != NAMESPACE:
            fail(f"{OVERLAY} puts an object in namespace {m.group(1)}, where {NET30} and {NET58} do not apply")
if overlay_k:
    if not re.search(r"^namespace:\s*" + NAMESPACE + r"\s*$", live(overlay_k), re.M):
        fail(f"{OVERLAY_K} does not set namespace {NAMESPACE}")
    if "agent.yaml" not in live(overlay_k):
        fail(f"{OVERLAY_K} does not list agent.yaml as a resource")
if kust and (re.search(r"confined-agent", live(kust)) or re.search(r"agent-tokens/", live(kust))):
    fail(f"{OVERLAY_DIR} is in {KUST}, so it is in the default apply set; it is optional by design")
launchers = ["deploy.sh", "install.sh", "build.sh"] + sorted(glob.glob("cloud/*/deploy-*.sh")) + sorted(glob.glob("cloud/*/install-*.sh"))
for sh in launchers:
    if os.path.exists(sh) and "confined-agent" in live(open(sh, encoding="utf-8").read()):
        fail(f"{sh} applies or names {OVERLAY_DIR}, which no launcher may: it is optional by design")
if overlay_r:
    same_label(f"{OVERLAY_R}", overlay_r)

# ---- 5. the proof script probes what 58 opens ---------------------------------------------------------------
if check:
    if LABEL_KEY is not None:
        for tok in sorted(set(AGENT_FAMILY.findall(live(check)))):
            if tok != LABEL_KEY:
                fail(f"{CHECK} names a label {tok} that {NET58} does not select (it selects {LABEL_KEY})")
        if LABEL not in check and LABEL_KEY not in live(check):
            fail(f"{CHECK} does not name the label {LABEL_KEY} that {NET58} selects")
    probed = {(m.group(1), int(m.group(2)))
              for m in re.finditer(r'^expect agent "\$NS" "\$AGENT_POD" ([a-z0-9-]+) (\d+) open\s*$', check, re.M)}
    for app, port in sorted(OPEN - probed):
        fail(f"{CHECK} has no open row for {app}:{port}, which {NET58} opens, so the proof does not cover it")
    for app, port in sorted(probed - OPEN):
        fail(f"{CHECK} expects {app}:{port} open, which {NET58} does not open")
    if not re.search(r'^NS="\$\{NS:-' + NAMESPACE + r'\}"\s*$', check, re.M):
        fail(f"{CHECK} does not default NS to {NAMESPACE}")
    if len(re.findall(r'expect agent "\$NS" "\$AGENT_POD" .* blocked\s*(?:;|$)', check, re.M)) < 4:
        fail(f"{CHECK} has fewer than four blocked rows for the agent pod, which is not a confinement proof")

if fails:
    print("FAIL: the NetworkPolicy's stated boundary and what the cluster has disagree:")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print(f"OK: {NET30} and the README state the boundary and agree with {NET58}: label {LABEL}, "
      f"{len(OPEN)} paths open ({', '.join(f'{a}:{p}' for a, p in sorted(OPEN))}), the overlay and the proof script carry the same label.")
PY
