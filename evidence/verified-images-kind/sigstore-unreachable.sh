#!/usr/bin/env bash
# CLAUDE.md invariant 58, measured on a kind cluster: what the admission policy does when Sigstore
# and the image registry are unreachable from the policy controller.
#
# The stack's namespace is opted in with the default install's step (policy/up.sh --enforce, the
# same step deploy.sh and the cloud launchers run). Then the policy controller's egress is cut with a
# NetworkPolicy in its namespace that allows DNS and the API server only. Then:
#   (a) a NEW pod with a signed, digest-pinned TAIPANBOX image, without restarting the controller;
#   (b) the controller is restarted, and a NEW pod with the same image is created.
# Expected: both refused (fail closed). Whatever is admitted is reported as admitted, with the
# reason the output gives, and nothing in the repository is changed for it.
#
# Two controls run in the same cut: an UNSIGNED TAIPANBOX image, and a SIGNED digest that the
# controller has not verified before (tokenfuse-control-plane). Both must be refused for the cut to
# mean anything. The restarted controller must be the only one left before (b) is tested, because
# a rollout keeps the old pod serving until its endpoint is removed.
#
# Step 0 first checks that this cluster's CNI enforces NetworkPolicy at all: a policy that denies
# egress must stop a probe pod from reaching the API server. If it does not, the cut in step 3 would
# measure nothing, and this script says so and stops.
#
# Usage: KUBECONFIG=<kubeconfig of a throwaway kind cluster> evidence/verified-images-kind/sigstore-unreachable.sh
# It creates and deletes only the namespaces and objects it names. Output: stdout, saved by the caller.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$REPO" || exit 1
: "${KUBECONFIG:?point KUBECONFIG at the throwaway kind cluster}"

NS=agent-stack
CTRL=cosign-system
PROBE_NS=np-probe
# Both digests come from the manifests, so the image measured is the one the stack pins.
SIGNED=$(grep -o 'ghcr.io/taipanbox/tokenfuse:v1[0-9.]*@sha256:[0-9a-f]\{64\}' manifests/10-planes.yaml | head -1)
PROBE_IMG=$(grep -o 'busybox@sha256:[0-9a-f]\{64\}' manifests/10-planes.yaml | head -1)
[ -n "$SIGNED" ] && [ -n "$PROBE_IMG" ] || { echo "FAIL: could not read the pinned images from manifests/10-planes.yaml"; exit 1; }
echo "signed, pinned image under test: $SIGNED"
echo "probe image: $PROBE_IMG"

API_IP=$(kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}')
API_PORT=$(kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[0].ports[0].port}')
echo "API server endpoint: $API_IP:$API_PORT"

# A new namespace gets its default ServiceAccount from the controller a moment later; a pod
# created before that is refused with "serviceaccount default not found", which the probe
# below would read as "unreachable". Wait for it instead.
wait_sa() { # namespace
  for _ in $(seq 1 60); do
    kubectl -n "$1" get serviceaccount default >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "FAIL: no default ServiceAccount in $1 after 60 s"; return 1
}

pod() { # name image -> the create's own answer, verbatim
  cat <<YAML | kubectl -n "$NS" create -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: $1
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: $2
YAML
}

echo
echo "== 0. does this CNI enforce NetworkPolicy? (a deny-all egress must stop a probe reaching the API server)"
kubectl create namespace "$PROBE_NS" >/dev/null 2>&1
wait_sa "$PROBE_NS" || exit 2
cat <<YAML | kubectl -n "$PROBE_NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: probe}
spec:
  restartPolicy: Never
  containers: [{name: c, image: $PROBE_IMG, command: ["sleep", "600"]}]
YAML
kubectl -n "$PROBE_NS" wait --for=condition=Ready pod/probe --timeout=180s >/dev/null 2>&1
reach() { kubectl -n "$PROBE_NS" exec probe -- wget -q -T 5 --no-check-certificate -O /dev/null "https://$API_IP:$API_PORT/version" >/dev/null 2>&1; }
if reach; then before=reachable; else before=unreachable; fi
echo "  before any policy: the API server is $before from the probe"
cat <<YAML | kubectl -n "$PROBE_NS" apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all-egress}
spec:
  podSelector: {}
  policyTypes: [Egress]
YAML
sleep 3
if reach; then after=reachable; else after=unreachable; fi
echo "  with deny-all egress: the API server is $after from the probe"
if [ "$before" = reachable ] && [ "$after" = unreachable ]; then
  echo "  RESULT: this CNI enforces NetworkPolicy egress; the cut below is a real cut."
else
  echo "  RESULT: NetworkPolicy is NOT enforced here (before=$before, after=$after). The cut below would measure nothing; stopping."
  kubectl delete namespace "$PROBE_NS" --wait=false >/dev/null 2>&1
  exit 3
fi
kubectl delete namespace "$PROBE_NS" --wait=false >/dev/null 2>&1

echo
echo "== 1. the default install's admission: policy/up.sh --enforce (controller, webhook, policies, namespace)"
kubectl create namespace "$NS" >/dev/null 2>&1
wait_sa "$NS" || exit 2
KUBECTL=kubectl policy/up.sh --enforce 2>&1 | sed 's/^/  /'
kubectl -n "$CTRL" rollout status deployment/webhook --timeout=240s 2>&1 | sed 's/^/  /'
echo "  running controller image: $(kubectl -n "$CTRL" get deployment webhook -o jsonpath='{.spec.template.spec.containers[0].image}')"

echo
echo "== 2. baseline, Sigstore reachable: a NEW pod with the signed pinned image"
out=$(pod sig-before "$SIGNED"); echo "  $out"
sleep 2

echo
echo "== 3. cut the policy controller's egress: DNS and the API server only"
cat <<YAML | kubectl -n "$CTRL" apply -f - >/dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: cut-controller-egress}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
      ports:
        - {port: 53, protocol: UDP}
        - {port: 53, protocol: TCP}
    - to:
        - ipBlock: {cidr: $API_IP/32}
      ports:
        - {port: $API_PORT, protocol: TCP}
YAML
sleep 3
# the cut is checked from inside the namespace the controller runs in: a probe there must not reach ghcr.io
cat <<YAML | kubectl -n "$CTRL" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: egress-probe}
spec:
  restartPolicy: Never
  containers: [{name: c, image: $PROBE_IMG, command: ["sleep", "600"]}]
YAML
kubectl -n "$CTRL" wait --for=condition=Ready pod/egress-probe --timeout=180s >/dev/null 2>&1
if kubectl -n "$CTRL" exec egress-probe -- wget -q -T 8 -O /dev/null https://ghcr.io/v2/ >/dev/null 2>&1; then
  echo "  probe in $CTRL reaches ghcr.io: the cut did NOT take"
else
  echo "  probe in $CTRL cannot reach ghcr.io (the cut holds for that namespace)"
fi
if kubectl -n "$CTRL" exec egress-probe -- wget -q -T 8 -O /dev/null https://tuf-repo-cdn.sigstore.dev/ >/dev/null 2>&1; then
  echo "  probe in $CTRL reaches tuf-repo-cdn.sigstore.dev: the cut did NOT take"
else
  echo "  probe in $CTRL cannot reach tuf-repo-cdn.sigstore.dev"
fi
kubectl -n "$CTRL" delete pod egress-probe --wait=false >/dev/null 2>&1

echo
echo "== 4a. Sigstore unreachable, controller NOT restarted: a NEW pod with the signed pinned image"
webhook_before=$(kubectl -n "$CTRL" get pods -l role=webhook -o jsonpath='{.items[0].metadata.name}')
echo "  the controller pod that verified the baseline: $webhook_before"
out=$(pod sig-during-cut "$SIGNED"); echo "  $out"
if echo "$out" | grep -q 'created'; then verdict_a=ADMITTED; else verdict_a=REFUSED; fi
echo "  verdict (a): $verdict_a"
sleep 2

echo
echo "== 4b. Sigstore unreachable, controller RESTARTED: a NEW pod with the signed pinned image"
kubectl -n "$CTRL" rollout restart deployment/webhook 2>&1 | sed 's/^/  /'
kubectl -n "$CTRL" rollout status deployment/webhook --timeout=240s 2>&1 | sed 's/^/  /'
kubectl -n "$CTRL" wait --for=delete pod/"$webhook_before" --timeout=240s 2>&1 | sed 's/^/  /'
webhook_after=$(kubectl -n "$CTRL" get pods -l role=webhook -o jsonpath='{.items[0].metadata.name}')
echo "  the only controller pod now: $webhook_after (the baseline pod is gone)"
out=$(pod sig-after-restart "$SIGNED"); echo "  $out"
if echo "$out" | grep -q 'created'; then verdict_b=ADMITTED; else verdict_b=REFUSED; fi
echo "  verdict (b): $verdict_b"

echo
echo "== 4c. control: a signed digest this controller has never verified (tokenfuse-control-plane)"
out=$(pod sig-fresh-control "ghcr.io/taipanbox/tokenfuse-control-plane:v1.18.0@sha256:c6160a8eed3d83d9caf42b426e82444cfe48a14027cb90ad4338340587a9d372"); echo "  $out"
if echo "$out" | grep -q 'created'; then verdict_c=ADMITTED; else verdict_c=REFUSED; fi
echo "  verdict (c): $verdict_c"

echo
echo "== 4d. control: an UNSIGNED TAIPANBOX image (the mockryx digest run.sh uses for its unsigned probe)"
out=$(pod unsigned-control "ghcr.io/taipanbox/mockryx@sha256:758d31650f43b283762da81c8543e3c5dea000d7360a9fb4df8f408f1503c5c7"); echo "  $out"
if echo "$out" | grep -q 'created'; then verdict_d=ADMITTED; else verdict_d=REFUSED; fi
echo "  verdict (d): $verdict_d"

echo
echo "== 5. the controller's own account of the signature fetches it could not make (the cut's effect)"
kubectl -n "$CTRL" logs "$webhook_after" --tail=2000 2>/dev/null | grep -o 'failed validSignatures[^"]*' | cut -c1-200 | sort | uniq -c | sed 's/^/  /' | head -6

echo
echo "== 6. cleanup of the pods this run created (the cut and the controller stay until the cluster goes)"
kubectl -n "$NS" delete pod sig-before sig-during-cut sig-after-restart sig-fresh-control unsigned-control --ignore-not-found --wait=false >/dev/null 2>&1
echo "  summary: baseline, reachable: ADMITTED. During the cut, the running controller: (a) $verdict_a."
echo "  After a restart, a controller with no verification in memory: (b) $verdict_b. Control, fresh signed digest: (c) $verdict_c. Control, unsigned: (d) $verdict_d."
