#!/usr/bin/env bash
# CLAUDE.md invariant 95, on a real cluster: the gateway's FOCUS export reaches the costcrew console.
#
# Run from a checkout on a machine with docker, kind and kubectl (forge: an Incus VM). It builds every
# object it applies FROM THIS TREE'S MANIFESTS, changing only what a kind cluster cannot run as shipped:
#   - stack-events and costcrew-state on kind's default class (stack-events RWO: one node);
#   - the gateway pod keeps its own securityContext, its bus-ready init and focus-export VERBATIM, but
#     its gateway container runs TOKENFUSE_ALLOW_STUB=1 (the built-in stub upstream, invented numbers,
#     no provider and no money) instead of the shipped one with keys and policy; its other sidecars go;
#     focus-export's FOCUS_EXPORT_INTERVAL is 30 instead of 900 so a run takes minutes;
#   - a busybox `caller` container in that pod makes the one call;
#   - the costcrew Deployment and its PVC VERBATIM, with a stack-wiring ConfigMap of two keys.
# Spends nothing. Prints RUN_EXIT=0 only when every step held.
set -uo pipefail
cd "$(dirname "$0")/../.."
CLUSTER="${CLUSTER:-costcrew-focus}"
NS=agent-stack
fail=0
step() { printf '\n== %s\n' "$*"; }
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
k() { kubectl --context "kind-$CLUSTER" "$@"; }
# The live pod of an app: Running, all containers ready, not being deleted (a rollout leaves the old one listed).
live_pod() { k -n "$NS" get pods -l "app=$1" -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    st = p.get("status", {})
    if p["metadata"].get("deletionTimestamp") or st.get("phase") != "Running":
        continue
    if all(c.get("ready") for c in st.get("containerStatuses", [])):
        print(p["metadata"]["name"]); break'; }

grep -qx "$CLUSTER" <<<"$(kind get clusters 2>/dev/null)" || kind create cluster --name "$CLUSTER" --wait 120s >/dev/null || { echo "RUN_EXIT=2"; exit 2; }

step "objects, derived from manifests/"
python3 - >/tmp/costcrew-focus-objects.json <<'PY'
import json, sys
sys.path.insert(0, "scripts/lib")
import miniyaml
def load(p): return [d for d in miniyaml.load_all(open(p).read()) if isinstance(d, dict)]
def find(ds, kind, name): return next(d for d in ds if d.get("kind") == kind and d["metadata"]["name"] == name)
out = [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "agent-stack"}}]
ev = find(load("manifests/00-base.yaml"), "PersistentVolumeClaim", "stack-events")
ev["spec"].pop("storageClassName", None); ev["spec"]["accessModes"] = ["ReadWriteOnce"]
out.append(ev)
out += load("manifests/11-bus.yaml")
gw = find(load("manifests/10-planes.yaml"), "Deployment", "tokenfuse-gateway")
p = gw["spec"]["template"]["spec"]
p["initContainers"] = [c for c in p.get("initContainers", []) if c["name"] == "bus-ready"]
g = next(c for c in p["containers"] if c["name"] == "gateway")
fe = next(c for c in p["containers"] if c["name"] == "focus-export")
data_dir = next(e["value"] for e in g["env"] if e["name"] == "TOKENFUSE_DATA_DIR")
g2 = {"name": "gateway", "image": g["image"], "securityContext": g.get("securityContext"),
      "env": [{"name": "TOKENFUSE_ALLOW_STUB", "value": "1"}, {"name": "TOKENFUSE_ADDR", "value": "127.0.0.1:4100"},
              {"name": "TOKENFUSE_DATA_DIR", "value": data_dir}],
      "volumeMounts": [m for m in g["volumeMounts"] if m["name"] in ("traces",)]}
for e in fe["env"]:
    if e["name"] == "FOCUS_EXPORT_INTERVAL": e["value"] = "30"
caller = {"name": "caller", "image": p["initContainers"][0]["image"], "command": ["sleep", "1000000"],
          "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}}}
p["containers"] = [g2, fe, caller]
keep = {m["name"] for c in p["containers"] + p["initContainers"] for m in c.get("volumeMounts", [])}
p["volumes"] = [v for v in p["volumes"] if v["name"] in keep]
out.append(gw)
cc = load("manifests/49-costcrew.yaml")
st = find(cc, "PersistentVolumeClaim", "costcrew-state"); st["spec"].pop("storageClassName", None)
out += [st, find(cc, "Deployment", "costcrew"),
        {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "stack-wiring", "namespace": "agent-stack"},
         "data": {"TRAILRYX_TRUST_DOMAIN": "acme.example", "COSTCREW_OWNER": "ops@acme.example"}}]
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": out}))
PY
python3 -c 'import json; d=json.load(open("/tmp/costcrew-focus-objects.json")); print("\n".join(i["kind"]+" "+i["metadata"]["name"] for i in d["items"]))'

for pass in 1 2; do
step "apply, pass $pass (the second run is the real test)"
k delete job -n $NS bus-owner --ignore-not-found >/dev/null 2>&1
k apply -f /tmp/costcrew-focus-objects.json >/dev/null || bad "apply"
k -n $NS wait --for=condition=complete job/bus-owner --timeout=180s >/dev/null && ok "bus-owner completed" || { bad "bus-owner did not complete"; k -n $NS logs job/bus-owner | tail -5; }
k -n $NS rollout status deploy/tokenfuse-gateway --timeout=300s >/dev/null && ok "gateway pod ready" || bad "gateway pod not ready"
k -n $NS rollout status deploy/costcrew --timeout=300s >/dev/null && ok "costcrew ready" || bad "costcrew not ready"
done

step "the owner's directories, as a pod of the gateway's identity sees them"
k -n $NS run focus-stat --rm -i --restart=Never --image=busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e \
  --overrides='{"spec":{"securityContext":{"runAsUser":20010,"runAsGroup":20010,"runAsNonRoot":true},"containers":[{"name":"s","image":"busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e","command":["sh","-c","stat -c \"%n %u:%g %a\" /bus/focus /bus/focus/gateway"],"volumeMounts":[{"name":"e","mountPath":"/bus","readOnly":true}]}],"volumes":[{"name":"e","persistentVolumeClaim":{"claimName":"stack-events"}}]}}' 2>/dev/null | tee /tmp/costcrew-focus-stat.txt
grep -q '^/bus/focus 20000:10003 2751$' /tmp/costcrew-focus-stat.txt && grep -q '^/bus/focus/gateway 20000:20010 2775$' /tmp/costcrew-focus-stat.txt \
  && ok "focus/ 20000:10003 2751, focus/gateway 20000:20010 2775" || bad "the owner's directories are not as invariant 95 says"

step "costcrew says where it reads"
k -n $NS logs deploy/costcrew | grep "reading the gateway's export" | tail -1
grep -q "reading the gateway's export from /var/lib/stack/focus/gateway" <<<"$(k -n $NS logs deploy/costcrew)" && ok "costcrew reads /var/lib/stack/focus/gateway" || bad "costcrew does not say it reads the gateway's folder"

step "one call through the gateway (built-in stub upstream)"
GWPOD="$(live_pod tokenfuse-gateway)"
echo "gateway pod: $GWPOD"
k -n $NS exec "$GWPOD" -c caller -- wget -qO- \
  --header 'content-type: application/json' --header 'anthropic-version: 2023-06-01' \
  --header 'x-fuse-agent-id: agent://acme.example/agents/focus-proof' --header 'x-fuse-run-id: focus-proof-1' \
  --post-data '{"model":"claude-sonnet-4-5","max_tokens":16,"messages":[{"role":"user","content":"hello"}]}' \
  http://127.0.0.1:4100/v1/messages | head -c 300; echo
for i in $(seq 1 30); do
  grep -q 'focus-export: gateway: wrote /var/lib/stack/focus/gateway/focus-gateway.csv' <<<"$(k -n $NS logs "$GWPOD" -c focus-export)" && break
  sleep 5
done
k -n $NS logs "$GWPOD" -c focus-export | tail -3
grep -q 'wrote /var/lib/stack/focus/gateway/focus-gateway.csv' <<<"$(k -n $NS logs "$GWPOD" -c focus-export)" && ok "focus-export wrote focus-gateway.csv" || bad "focus-export never wrote the export"

step "the export, as the costcrew pod's mount holds it"
k -n $NS run focus-read --rm -i --restart=Never --image=busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e \
  --overrides='{"spec":{"securityContext":{"runAsUser":10003,"runAsGroup":10003,"runAsNonRoot":true,"supplementalGroups":[10001]},"containers":[{"name":"r","image":"busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e","command":["sh","-c","ls -la /f/gateway; head -c 2000 /f/gateway/focus-gateway.csv; echo; if touch /f/gateway/x 2>/dev/null; then echo WROTE; else echo REFUSED-WRITE; fi"],"volumeMounts":[{"name":"e","mountPath":"/f","subPath":"focus","readOnly":true}]}],"volumes":[{"name":"e","persistentVolumeClaim":{"claimName":"stack-events"}}]}}' 2>/dev/null | tee /tmp/costcrew-focus-read.txt
grep -q 'focus-proof' /tmp/costcrew-focus-read.txt && ok "the export carries the agent's call" || bad "the export does not carry agent://acme.example/agents/focus-proof"
grep -q 'REFUSED-WRITE' /tmp/costcrew-focus-read.txt && ok "costcrew's identity cannot write the export" || bad "costcrew's identity could write the export"
grep -q 'partial' /tmp/costcrew-focus-read.txt && bad "a partial file is left beside the export" || ok "no partial file beside the export"

step "costcrew reads it at start"
k -n $NS rollout restart deploy/costcrew >/dev/null && k -n $NS rollout status deploy/costcrew --timeout=300s >/dev/null
for i in $(seq 1 24); do grep -q "imported the gateway's export\|was not imported" <<<"$(k -n $NS logs deploy/costcrew)" && break; sleep 5; done
k -n $NS logs deploy/costcrew | grep "gateway's export" | tail -3
grep -q "imported the gateway's export" <<<"$(k -n $NS logs deploy/costcrew)" && ok "costcrew imported the gateway's export" || bad "costcrew did not import the export"

echo
[ "$fail" = 0 ] && echo "RUN_EXIT=0" || echo "RUN_EXIT=1"
exit "$fail"
