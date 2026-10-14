#!/usr/bin/env bash
#
# Enforces invariant 45 of CLAUDE.md: cluster DNS keeps a replica through a drain,
# and the installers change k3s's coredns only in ways k3s's own reconcile leaves
# alone.
#
# WHAT THIS IS ABOUT
#
# k3s v1.36 ships coredns as a plain manifest (manifests/coredns.yaml in k3s, not a
# HelmChart, so a HelmChartConfig cannot reach it) with no replica count, a topology
# spread over host names (DoNotSchedule) and over zones (ScheduleAnyway), and no
# PodDisruptionBudget. The installers scale it to two (invariant 12). Two replicas
# with no budget still lose all DNS when two nodes are drained at once. A budget is
# an object of our own, which k3s's reconcile of its manifest never touches; a patch
# to k3s's Deployment would be undone the next time k3s re-applies the manifest, so
# none is allowed.
#
# What it cannot hold, and the GOTCHAS entry says why: a node that DIES keeps its
# replica's address in the kube-dns Service until the node is marked NotReady.
#
# WHAT THIS CHECKS, over every installer (a tracked *.sh that installs a k3s server
# with INSTALL_K3S_VERSION, found as k3s-token-is-reused.sh finds them):
#
#   A. It applies a policy/v1 PodDisruptionBudget named coredns in kube-system that
#      selects k8s-app: kube-dns with minAvailable 1, after it scales coredns.
#   B. Only when there are two replicas or more (`if [ "$DNS_WANT" -ge 2 ]`): with
#      one replica a budget of one would block every drain of that node for good.
#   C. The budget is the same document in every installer: three copies of a block
#      drift (GOTCHAS 90, 101, 102).
#   D. No code line patches, edits, sets or applies k3s's coredns Deployment; only
#      `scale` is allowed, because the manifest sets no replica count.
#   E. verify.sh checks the budget on a multi-node cluster.
#   F. The replica policy: two replicas, three from five nodes, one alone, the same three
#      lines in every installer and before the scale (invariant 45).
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no installer, or an installer whose DNS
# step cannot be found, is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import os, re, subprocess, sys

problems = []
tracked = subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True).stdout.split()


def code_lines(path):
    return [(i + 1, l) for i, l in enumerate(open(path).read().split("\n")) if not l.lstrip().startswith("#")]


installers = []
for p in tracked:
    if not os.path.isfile(p) or p.startswith("scripts/"):
        continue
    live = code_lines(p)
    if any(re.search(r"sh -s - serv[e]r", l) for _, l in live) and any("INSTALL_K3S_VERSION=" in l for _, l in live):
        installers.append(p)
if not installers:
    print("FAIL: no tracked script installs a k3s server, so this measured NOTHING about cluster DNS.")
    sys.exit(1)

WANT = [
    "apiVersion: policy/v1",
    "kind: PodDisruptionBudget",
    "metadata: { name: coredns, namespace: kube-system, labels: { app.kubernetes.io/managed-by: stack-k8s } }",
    "spec:",
    "  minAvailable: 1",
    "  selector: { matchLabels: { k8s-app: kube-dns } }",
]
docs = {}
for p in installers:
    live = code_lines(p)
    scale = [n for n, l in live if re.search(r"scale deployment coredns --replicas=", l)]
    if not scale:
        problems.append(f"{p}: installs a k3s server and never scales coredns, so its DNS step cannot be found")
        continue
    kinds = [n for n, l in live if "'kind: PodDisruptionBudget'" in l]
    if not kinds:
        problems.append(f"{p}: never applies a PodDisruptionBudget for coredns, so two nodes drained at once take every replica")
        continue
    k = kinds[0]
    if k < scale[0]:
        problems.append(f"{p}: applies the coredns budget at line {k}, above the scale at line {scale[0]}")
    # the printf block that carries the document: the quoted lines around `kind:`
    lines = dict(live)
    start = k
    while start - 1 in lines and re.match(r"\s*'[^']*' \\$", lines[start - 1]):
        start -= 1
    end = k
    while end + 1 in lines and re.match(r"\s*'[^']*' \\$", lines[end + 1]):
        end += 1
    doc = [re.match(r"\s*'([^']*)' \\$", lines[n]).group(1) for n in range(start, end + 1)]
    docs[p] = doc
    if doc != WANT:
        problems.append(f"{p}: the coredns budget is not the document this gate holds:\n      " + "\n      ".join(doc))
    after = "\n".join(lines[n] for n in range(end + 1, min(end + 4, max(lines) + 1)) if n in lines)
    if not re.search(r'k_ "apply -f -"', after):
        problems.append(f"{p}: the coredns budget at line {k} is not piped to `k_ \"apply -f -\"`")
    guard = [n for n, l in live if re.match(r'\s*if \[ "\$DNS_WANT" -ge 2 \]; then\s*$', l) and n < start]
    if not guard or any(re.match(r"\s*fi\s*$", lines[n]) for n in range(guard[-1] + 1, start) if n in lines):
        problems.append(f"{p}: applies the coredns budget outside `if [ \"$DNS_WANT\" -ge 2 ]`: with one replica, a budget of one blocks every drain of that node")
    for n, l in live:
        if re.search(r"\b(patch|edit|set \S+|apply)\b[^|]*\b(deploy|deployment|deployments)[ /]coredns\b", l) or \
           re.search(r"\b(patch|edit)\b.*-n kube-system\b.*\bcoredns\b", l) and "pdb" not in l:
            problems.append(f"{p}:{n}: changes k3s's coredns Deployment beyond its replica count; k3s re-applies its manifest and undoes it:\n      {l.strip()}")

if len({tuple(d) for d in docs.values()}) > 1:
    problems.append("the coredns budget differs between installers: " + ", ".join(sorted(docs)))

v = open("verify.sh").read() if os.path.isfile("verify.sh") else ""
if not re.search(r"get pdb coredns -o jsonpath='\{\.spec\.minAvailable\}'", v):
    problems.append("verify.sh does not check the coredns disruption budget, so a cluster without one passes")

# F. The replica policy: one replica on one node, two on two to four nodes, three on five or
#    more. The same three lines, in that order, sit before the scale in every installer.
POLICY = [
    "DNS_WANT=2",
    '[ "${#ALL_NODES[@]}" -ge 5 ] && DNS_WANT=3',
    '[ "${#ALL_NODES[@]}" -lt 2 ] && DNS_WANT=1',
]
for p in installers:
    live = code_lines(p)
    stripped = [l.strip() for _, l in live]
    at = [i for i, s_ in enumerate(stripped) if s_ == POLICY[0]]
    if not at or stripped[at[0]:at[0] + len(POLICY)] != POLICY:
        problems.append(f"{p}: the replica policy is not the three lines this gate holds, in order: " + " ; ".join(POLICY))
        continue
    scale_at = [n for n, l in live if re.search(r"scale deployment coredns --replicas=", l)]
    if scale_at and live[at[0]][0] > scale_at[0]:
        problems.append(f"{p}: the replica policy comes after the scale it sets")

if problems:
    for p in problems:
        print("FAIL: " + p)
    print()
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 45.")
    sys.exit(1)
print(f"OK: {len(installers)} installer(s) ({', '.join(installers)}) give coredns the same budget of one,")
print("    only with two replicas or more, after the scale, and leave k3s's Deployment to k3s; verify.sh checks it.")
print("    The replica policy is the same in every installer: two, three from five nodes, one alone.")
PY
