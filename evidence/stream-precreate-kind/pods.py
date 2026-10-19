#!/usr/bin/env python3
"""Print the two test pods for invariant 59, from the manifests as they stand.

usage: pods.py fixed|unfixed

`fixed` copies each writer's initContainers block verbatim out of manifests/, so the pod that runs
is the one the manifests describe. `unfixed` drops that block and nothing else, which is the red
run. The writers are run with the agent-stack-go v2 images, the ones that refuse a missing stream
in a directory they do not own (v2.2.1 wardryx, v2.0.1 agent-conform); the pins in the manifests
are not moved by this change.
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
MAN = os.path.join(ROOT, "manifests")
WARDRYX_IMG = "ghcr.io/taipanbox/wardryx:v2.2.1@sha256:67718da5ef5551767156ef0ea893765f448c484fcbb5dcce5923a0ca83b8c309"
AC_IMG = "ghcr.io/taipanbox/agent-conform:v2.0.1@sha256:445608e976247b94f4c3877541fdd4ae3f2aa623b18365ee7215a99f75b85e4c"
BUSYBOX = "busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"


def doc(path, kind, name):
    for d in re.split(r"\n---\s*\n", open(os.path.join(MAN, path)).read()):
        if re.search(rf"^kind:\s*{kind}\s*$", d, re.M) and re.search(rf"^  name:\s*{name}\s*$", d, re.M):
            return d
    raise SystemExit(f"not found: {path} {kind} {name}")


def init_block(d, ind):
    ls = d.split("\n")
    s = next(i for i, l in enumerate(ls) if l == " " * ind + "initContainers:")
    out = []
    for l in ls[s + 1:]:
        if l.strip() == "" or l.strip().startswith("#"):
            continue
        if len(l) - len(l.lstrip(" ")) > ind:
            out.append(l[ind:])
        else:
            break
    return "\n".join(["initContainers:"] + out)


def pod_sc(d, ind):
    for l in d.split("\n"):
        if l.startswith(" " * ind + "securityContext:") and len(l) - len(l.lstrip(" ")) == ind:
            return l[ind:]
    raise SystemExit("no pod-level securityContext")


def pod(name, ns, sc, init, container, volume):
    head = f"""apiVersion: v1
kind: Pod
metadata:
  name: {name}
  namespace: {ns}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  {sc}
"""
    if init:
        head += "  " + init.replace("\n", "\n  ") + "\n"
    return head + f"""  containers:
{container}
  volumes:
  - name: events
    persistentVolumeClaim: {{ claimName: stack-events }}
"""


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "fixed"
    if mode not in ("fixed", "unfixed"):
        raise SystemExit("usage: pods.py fixed|unfixed")
    ns = os.environ.get("EV_NS", "ev-test")
    keep = mode == "fixed"

    d = doc("10-planes.yaml", "Deployment", "wardryx")
    print(pod("wardryx", ns, pod_sc(d, 6), init_block(d, 6) if keep else "",
              f"""  - name: wardryx
    image: {WARDRYX_IMG}
    args: ["serve", "-addr", "0.0.0.0:8090", "-events", "/var/lib/stack/events/wardryx.ndjson"]
    env: [{{ name: WARDRYX_KEYS, value: "k0123456789abcdef0123456789abcdef:acme:admin" }}]
    securityContext: {{ allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {{ drop: ["ALL"] }} }}
    volumeMounts: [{{ name: events, mountPath: /var/lib/stack/events }}]""", None))
    print("---")

    d = doc("40-routines-and-secrets.yaml", "CronJob", "agent-conform")
    print(pod("agent-conform", ns, pod_sc(d, 10), init_block(d, 10) if keep else "",
              f"""  - name: agent-conform
    image: {AC_IMG}
    args: ["watch-dir", "-out", "/var/lib/stack/events/agent-conform.ndjson", "-state", "/var/lib/stack/events/agent-conform.state.json", "/var/lib/stack/events"]
    securityContext: {{ allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {{ drop: ["ALL"] }} }}
    volumeMounts: [{{ name: events, mountPath: /var/lib/stack/events }}]""", None))


main()
