#!/usr/bin/env bash
# Enforces invariant 21 in CLAUDE.md: every Deployment and StatefulSet leaves a
# dead node within 60 seconds, and every container that serves a port in a
# Deployment that ROLLS sleeps before it stops.
#
# WHY
#
# Every Deployment here is one replica. Kubernetes gives every pod a default
# NoExecute toleration of 300 s for node.kubernetes.io/unreachable and
# node.kubernetes.io/not-ready, so a pod on a node that dies is not evicted for
# five minutes after the node is marked NotReady. Measured on k3d on forge,
# 2026-09-26, stack-k8s v1.1.10: `docker kill` of the node running the gateway
# left it unreachable for 360 s and idryx for 347 s (47 s to NotReady, then the
# 300 s). Nothing was broken; the configuration said five minutes and charged
# exactly that, the same shape as the coredns finding behind invariant 12.
#
# The same cluster's rolling upgrade from v1.1.7 refused 3 gateway probes in a
# 0.8 s window: the old pod stopped the moment it was told to, while kube-proxy
# was still routing to its endpoint. A short preStop sleep lets the endpoint
# leave the Service before the process stops accepting.
#
# WHAT IS A SUBJECT
#
# Every Deployment and StatefulSet the kustomization includes carries NoExecute
# tolerations for BOTH node.kubernetes.io/unreachable and
# node.kubernetes.io/not-ready with tolerationSeconds of at most 60.
#
# The first version of this gate excluded the Recreate Deployments and the
# StatefulSet, the ones holding a ReadWriteOnce claim, on the premise that
# evicting them early cannot move their volume. On Longhorn that premise is
# wrong once the installers set node-down-pod-deletion-policy (invariant 22):
# measured on GCP 2026-09-26, policy-db's VM stopped, the policy store was down
# until the VM returned as shipped, about 400 s with the Longhorn setting alone,
# about 150 s with it and 30 s tolerations. GOTCHAS 109.
#
# In addition, in a Deployment that ROLLS (strategy not Recreate), every
# container that declares a containerPort has `lifecycle.preStop.sleep.seconds`
# of at least 1 and below the pod's terminationGracePeriodSeconds (30 when
# unset). A Recreate Deployment or a StatefulSet never runs two pods at once,
# so there is no endpoint hand-over for the sleep to cover.
#
# Subjects are found from manifests/kustomization.yaml, not listed, and no
# subject at all is a failure that says it measured nothing. Parsed by
# indentation, the same technique and the same helpers as
# gateway-cache-is-off.sh.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

MAX_TOLERATION = 60
TAINTS = ["node.kubernetes.io/unreachable", "node.kubernetes.io/not-ready"]

POD_TEMPLATE_KINDS = {
    "Deployment":  ["spec", "template", "spec"],
    "StatefulSet": ["spec", "template", "spec"],
    "Job":         ["spec", "template", "spec"],
    "CronJob":     ["spec", "jobTemplate", "spec", "template", "spec"],
}


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_blank_or_comment(line):
    s = line.strip()
    return s == "" or s.startswith("#")


def block_end(lines, header_idx, header_indent):
    j = header_idx + 1
    n = len(lines)
    while j < n:
        if not is_blank_or_comment(lines[j]) and indent_of(lines[j]) <= header_indent:
            return j
        j += 1
    return n


def find_child(lines, start, end, key, indent):
    j = start
    while j < end:
        line = lines[j]
        if is_blank_or_comment(line):
            j += 1
            continue
        cur = indent_of(line)
        if cur < indent:
            return None
        if cur == indent and line.strip() == key + ":":
            return j
        j += 1
    return None


def locate_pod_spec(lines, kind_line_idx, path):
    start, end, indent = kind_line_idx, len(lines), -2
    idx = None
    for key in path:
        indent += 2
        idx = find_child(lines, start, end, key, indent)
        if idx is None:
            return None
        start = idx + 1
        end = block_end(lines, idx, indent)
    return idx, indent


def container_blocks(lines, pod_idx, pod_indent):
    """Find containers: under the pod spec and split it into one block per
    list item. Returns a list of (start_idx, end_idx, item_indent)."""
    field_indent = pod_indent + 2
    containers_idx = find_child(lines, pod_idx + 1, block_end(lines, pod_idx, pod_indent),
                                 "containers", field_indent)
    if containers_idx is None:
        return []
    c_end = block_end(lines, containers_idx, field_indent)

    # List items are "<item_indent>- name: ..."; item_indent is whatever the
    # first "- " under containers: uses, read rather than assumed, since this
    # repo is not perfectly uniform about list-item indent.
    item_indent = None
    j = containers_idx + 1
    while j < c_end:
        line = lines[j]
        if not is_blank_or_comment(line) and line.lstrip().startswith("- "):
            item_indent = indent_of(line)
            break
        j += 1
    if item_indent is None:
        return []

    starts = []
    j = containers_idx + 1
    while j < c_end:
        line = lines[j]
        if (not is_blank_or_comment(line) and indent_of(line) == item_indent
                and line.lstrip().startswith("- ")):
            starts.append(j)
        j += 1

    blocks = []
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else c_end
        blocks.append((s, e, item_indent))
    return blocks



def list_items(lines, start, end):
    """Split a YAML list block into item texts, one per "- " at the first
    item indent found."""
    item_indent = None
    for j in range(start, end):
        if not is_blank_or_comment(lines[j]) and lines[j].lstrip().startswith("- "):
            item_indent = indent_of(lines[j])
            break
    if item_indent is None:
        return []
    starts = [j for j in range(start, end)
              if not is_blank_or_comment(lines[j]) and indent_of(lines[j]) == item_indent
              and lines[j].lstrip().startswith("- ")]
    return ["\n".join(lines[s:(starts[i + 1] if i + 1 < len(starts) else end)])
            for i, s in enumerate(starts)]


def strategy_is_recreate(lines, kind_idx):
    spec_idx = find_child(lines, kind_idx, len(lines), "spec", 0)
    if spec_idx is None:
        return False
    end = block_end(lines, spec_idx, 0)
    for j in range(spec_idx + 1, end):
        line = lines[j]
        if is_blank_or_comment(line) or indent_of(line) != 2:
            continue
        if line.strip().startswith("strategy:"):
            text = "\n".join(lines[j:block_end(lines, j, 2)])
            return re.search(r"type:\s*\"?Recreate\"?", text) is not None
    return False


def grace_seconds(lines, pod_idx, pod_indent):
    end = block_end(lines, pod_idx, pod_indent)
    for j in range(pod_idx + 1, end):
        line = lines[j]
        if indent_of(line) == pod_indent + 2 and line.strip().startswith("terminationGracePeriodSeconds:"):
            return int(line.split(":", 1)[1].split("#")[0].strip())
    return 30


def toleration_problems(lines, pod_idx, pod_indent, where):
    field = pod_indent + 2
    pod_end = block_end(lines, pod_idx, pod_indent)
    j = None
    for k in range(pod_idx + 1, pod_end):
        if indent_of(lines[k]) == field and lines[k].strip() == "tolerations:":
            j = k
            break
    if j is None:
        return [f"{where}: no tolerations, so the default 300 s wait on a dead node stands"]
    items = list_items(lines, j + 1, block_end(lines, j, field))
    problems = []
    for taint in TAINTS:
        match = [t for t in items if re.search(r"key:\s*\"?" + re.escape(taint) + r"\"?", t)]
        if not match:
            problems.append(f"{where}: no toleration for {taint}, so the default 300 s stands")
            continue
        t = match[0]
        if not re.search(r"effect:\s*\"?NoExecute\"?", t):
            problems.append(f"{where}: the {taint} toleration is not effect NoExecute")
        m = re.search(r"tolerationSeconds:\s*(\d+)", t)
        if not m:
            problems.append(f"{where}: the {taint} toleration has no tolerationSeconds, which means forever")
        elif int(m.group(1)) > MAX_TOLERATION:
            problems.append(f"{where}: tolerationSeconds {m.group(1)} for {taint}, above {MAX_TOLERATION}")
    return problems


def prestop_seconds(block_text):
    m = re.search(r"preStop:\s*\{\s*sleep:\s*\{\s*seconds:\s*(\d+)", block_text)
    if m:
        return int(m.group(1))
    m = re.search(r"preStop:\s*\n\s*sleep:\s*\n\s*seconds:\s*(\d+)", block_text)
    if m:
        return int(m.group(1))
    return None


def check_document(fname, doc_first_line, lines):
    kind = kind_idx = None
    for i, line in enumerate(lines):
        if not is_blank_or_comment(line) and indent_of(line) == 0 and line.startswith("kind:"):
            kind, kind_idx = line.split(":", 1)[1].strip(), i
            break
    if kind not in ("Deployment", "StatefulSet"):
        return None
    rolls = kind == "Deployment" and not strategy_is_recreate(lines, kind_idx)
    name = "(unnamed)"
    for line in lines:
        if line.strip().startswith("name:"):
            name = line.split(":", 1)[1].strip()
            break
    located = locate_pod_spec(lines, kind_idx, POD_TEMPLATE_KINDS[kind])
    if located is None:
        return [f"{fname}: {kind} {name} has no pod spec this check can find"]
    pod_idx, pod_indent = located
    where = f"{fname}:{doc_first_line + pod_idx + 1} {kind} {name}"
    problems = toleration_problems(lines, pod_idx, pod_indent, where)
    if not rolls:
        return problems
    grace = grace_seconds(lines, pod_idx, pod_indent)
    serving = 0
    for start, end, _ in container_blocks(lines, pod_idx, pod_indent):
        text = "\n".join(lines[start:end])
        if "containerPort" not in text:
            continue
        serving += 1
        cname = re.search(r"name:\s*(\S+)", text).group(1)
        s = prestop_seconds(text)
        if s is None:
            problems.append(f"{where}, container {cname}: serves a port and has no preStop sleep, so it stops while still in the Service")
        elif s < 1 or s >= grace:
            problems.append(f"{where}, container {cname}: preStop sleep {s} s, needs at least 1 and below the {grace} s grace period")
    if serving == 0:
        problems.append(f"{where}: rolls, but no container declares a port, so nothing here can say it drains")
    return problems


subjects = 0
failures = []
kustomization = pathlib.Path("manifests/kustomization.yaml")
text = kustomization.read_text()
m = re.search(r"^resources:\s*$", text, re.M)
if not m:
    print(f"FAIL: no resources: block in {kustomization}, so this measured nothing")
    sys.exit(1)
resources = []
for line in text[m.end():].splitlines():
    if not line.strip():
        continue
    item = re.match(r"^\s*-\s+(\S+)\s*$", line)
    if not item:
        break
    resources.append(item.group(1))

for rname in resources:
    path = pathlib.Path("manifests") / rname
    if not path.exists() or path.name == "secrets.example.yaml":
        continue
    doc, doc_start = [], 0
    all_lines = path.read_text().split("\n")
    for n, line in enumerate(all_lines + ["---"]):
        if line.rstrip() == "---":
            if doc:
                r = check_document(str(path), doc_start, doc)
                if r is not None:
                    subjects += 1
                    failures.extend(r)
            doc, doc_start = [], n + 1
        else:
            doc.append(line)

if subjects == 0:
    print("FAIL: no Deployment or StatefulSet was found under any manifest")
    print("      manifests/kustomization.yaml includes. That is not health: the")
    print("      planes moved, or this check no longer knows how to find them.")
    print("      This measured nothing about leaving a dead node, and it is not")
    print("      entitled to say OK.")
    sys.exit(1)

for f in failures:
    print(f"FAIL: {f}")
if failures:
    print()
    print(f"{len(failures)} problem(s) across {subjects} workload(s). A single replica")
    print("that keeps the default toleration sits on a dead node for 300 s after it is")
    print("marked NotReady, measured on 2026-09-26 as 360 s of a refused gateway.")
    sys.exit(1)

print(f"OK: {subjects} Deployment(s) and StatefulSet(s), each leaves a dead node within {MAX_TOLERATION} s,")
print("    and every container that serves a port in a rolling Deployment sleeps before it stops.")
PY
