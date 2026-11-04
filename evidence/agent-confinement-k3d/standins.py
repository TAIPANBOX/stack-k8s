#!/usr/bin/env python3
"""Reads `kubectl kustomize manifests/ | kubectl create --dry-run=client -o json -f -` on stdin (a stream of JSON
documents, one per object) and writes, as one JSON List on stdout, a stand-in pod and Service for each stack service the
agent-confinement run probes. With `--policies` it writes the NetworkPolicy objects of that rendered set instead.

Each stand-in carries the labels of the real Deployment or StatefulSet whose pod template the real Service selects,
listens on the real container ports (a NetworkPolicy matches the pod's port, not the Service's), and answers HTTP with
busybox httpd. Nothing is hand-written about the stack: a renamed label or port in manifests/ changes what is generated.
Standard library only.
"""
import json
import sys

BUSYBOX = "busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
TARGETS = ["vouchryx", "tokenfuse-gateway", "wardryx", "idryx", "tokenfuse-cloud", "policy-db", "genaryx-console"]

def documents(text):
    decoder, i, found = json.JSONDecoder(), 0, []
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return found
        obj, i = decoder.raw_decode(text, i)
        found.extend(obj["items"] if obj.get("kind") == "List" else [obj])


items = documents(sys.stdin.read())
if not items:
    sys.exit("no object on stdin")
if "--policies" in sys.argv[1:]:
    pols = [i for i in items if i["kind"] == "NetworkPolicy"]
    if not pols:
        sys.exit("no NetworkPolicy in the rendered set")
    json.dump({"apiVersion": "v1", "kind": "List", "items": pols}, sys.stdout)
    print(f"{len(pols)} NetworkPolicy objects in the default apply set: "
          + ", ".join(sorted(p["metadata"]["name"] for p in pols)), file=sys.stderr)
    sys.exit(0)
services = {i["metadata"]["name"]: i for i in items if i["kind"] == "Service"}
workloads = [i for i in items if i["kind"] in ("Deployment", "StatefulSet")]

out = []
for name in TARGETS:
    if name not in services:
        sys.exit(f"no Service {name} in the rendered manifests")
    svc = services[name]
    selector = svc["spec"]["selector"]
    owners = [w for w in workloads
              if all(w["spec"]["template"]["metadata"].get("labels", {}).get(k) == v for k, v in selector.items())]
    if len(owners) != 1:
        sys.exit(f"Service {name}: {len(owners)} workloads match its selector, want exactly one")
    template = owners[0]["spec"]["template"]
    labels = dict(template["metadata"]["labels"])
    named = {}
    for c in template["spec"]["containers"]:
        for p in c.get("ports", []):
            named[p.get("name")] = p["containerPort"]
    mapping = []
    for sp in svc["spec"]["ports"]:
        target = sp.get("targetPort", sp["port"])
        if isinstance(target, str):
            if target not in named:
                sys.exit(f"Service {name}: target port {target} names no container port")
            target = named[target]
        mapping.append((sp["port"], target))
    containers = []
    for _, target in sorted(set(mapping), key=lambda m: m[1]):
        containers.append({
            "name": f"c{target}",
            "image": BUSYBOX,
            "command": ["httpd", "-f", "-p", str(target), "-h", "/"],
            "ports": [{"containerPort": target}],
            "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                                "capabilities": {"drop": ["ALL"]}},
        })
    out.append({
        "apiVersion": "v1", "kind": "Pod",
        "metadata": {"name": f"{name}-standin", "namespace": "agent-stack", "labels": labels},
        "spec": {
            "terminationGracePeriodSeconds": 1,
            "automountServiceAccountToken": False,
            "securityContext": {"runAsNonRoot": True, "runAsUser": 10001, "runAsGroup": 10001,
                                "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": containers,
        },
    })
    out.append({
        "apiVersion": "v1", "kind": "Service",
        "metadata": {"name": name, "namespace": "agent-stack"},
        "spec": {"selector": selector,
                 "ports": [{"name": f"p{port}", "port": port, "targetPort": target} for port, target in mapping]},
    })
json.dump({"apiVersion": "v1", "kind": "List", "items": out}, sys.stdout, indent=1)
