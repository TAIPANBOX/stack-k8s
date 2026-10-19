#!/usr/bin/env bash
# CLAUDE.md invariant 59, GOTCHAS 136, measured. heraldyx 0.8.0 on a fresh 1 GiB claim, from the
# manifest's own Deployment (manifests/45-heraldyx.yaml, taken as kubectl reads it), twice:
#   noinit  the Deployment without its precreate-streams init container
#   init    the Deployment as the manifest now has it
# The bus volume is replaced by an emptyDir and the mail transport is left unset, so the only thing
# this run exercises is the journal. Needs KUBECONFIG at a cluster you may create namespaces in (kind
# is enough). It creates and deletes the two namespaces it names and nothing else.
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${KUBECONFIG:?point KUBECONFIG at a kind cluster}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
M=manifests/45-heraldyx.yaml

# 1. the Deployment, as kubectl reads it from the tracked manifest
awk -v d="$W" 'BEGIN{n=0; f=d "/doc-0.yaml"} /^---[[:space:]]*$/{n++; f=d "/doc-" n ".yaml"; next} {print > f}' "$M"
dep="$(grep -l '^kind: Deployment' "$W"/doc-*.yaml | head -1)"
[ -n "$dep" ] || { echo "no Deployment in $M: nothing measured" >&2; exit 2; }
kubectl create --dry-run=client -f "$dep" -o json >"$W/deploy.json" || exit 2

# 2. two namespaces: the manifest's own Deployment with and without its init container
python3 - "$W" <<'PY'
import copy, json, sys
W = sys.argv[1]
base = json.load(open(f"{W}/deploy.json"))
def variant(ns, with_init):
    d = copy.deepcopy(base)
    d["metadata"] = {"name": d["metadata"]["name"], "namespace": ns}
    d.pop("status", None)
    d["spec"].pop("strategy", None)
    s = d["spec"]["template"]["spec"]
    if not with_init:
        s.pop("initContainers", None)
    s["volumes"] = [
        {"name": "state", "persistentVolumeClaim": {"claimName": "heraldyx-state"}} if v["name"] == "state"
        else {"name": v["name"], "emptyDir": {}} for v in s["volumes"]]
    return d
docs = []
for ns, wi in (("pins-noinit", False), ("pins-init", True)):
    docs.append({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}})
    docs.append({"apiVersion": "v1", "kind": "PersistentVolumeClaim",
                 "metadata": {"name": "heraldyx-state", "namespace": ns},
                 "spec": {"accessModes": ["ReadWriteOnce"], "resources": {"requests": {"storage": "1Gi"}}}})
    docs.append(variant(ns, wi))
open(f"{W}/test.json", "w").write("\n---\n".join(json.dumps(x) for x in docs))
PY
kubectl delete namespace pins-noinit pins-init --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f "$W/test.json" >/dev/null || { echo "apply failed" >&2; exit 2; }

# 3. read the result after the pods have had time to start
sleep 60
for ns in pins-noinit pins-init; do
	echo "===== $ns"
	kubectl -n "$ns" get pods -l app=heraldyx -o wide 2>&1 | tail -n +1
	kubectl -n "$ns" get pod -l app=heraldyx -o jsonpath='{range .items[*]}restarts={.status.containerStatuses[0].restartCount}{"\n"}{end}'
	echo "--- journal record lines in the log:"
	kubectl -n "$ns" logs deploy/heraldyx --all-containers 2>&1 | grep -c '^[0-9/: ]*record:' || true
	echo "--- last log lines:"
	kubectl -n "$ns" logs deploy/heraldyx 2>&1 | tail -n 4 | cut -c1-200
	echo "--- the init container (ls -ln of the journal volume), if this variant has one:"
	kubectl -n "$ns" logs deploy/heraldyx -c precreate-streams 2>/dev/null || echo "(no init container in this variant)"
done

# 4. remove what this run created
kubectl delete namespace pins-noinit pins-init --ignore-not-found --wait=false >/dev/null 2>&1
