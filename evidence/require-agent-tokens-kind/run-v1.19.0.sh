#!/usr/bin/env bash
# Measured on the stack-k8s v1.5.0 pin set (CLAUDE.md invariants 24, 54, 62, 63): tokenfuse v1.19.0 at the gateway
# and the broker, wardryx v2.3.0, vouchryx v0.6.0, all from the product manifests. The product files are applied
# where the run can hold them: manifests/54-delegation.yaml (vouchryx, agents-only), manifests/58-agent-tokens-network.yaml
# (the agent-pod network), and the vouchryx minting of lib/vouchryx-mint.sh and lib/static-keys.sh, run as the deploy
# runs them. The gateway, the broker and wardryx are stand-in manifests (gateway-door.yaml, broker-door.yaml,
# wardryx.yaml) whose door env is copied from the product, with their images read from the product manifests.
# Stand-ins: the provider (upstream), the MCP upstream, Postgres for wardryx, and the egress rules in
# stand-in-network.yaml. Not run: the rest of the stack (Longhorn, Calico, the console, the policy controller).
#
# Needs KUBECONFIG at a kind cluster you may create objects in. Secrets stay in a scratch directory removed on exit.
# Run:  KUBECONFIG=... ./evidence/require-agent-tokens-kind/run-v1.19.0.sh | tee evidence/require-agent-tokens-kind/output-v1.19.0.txt
set -uo pipefail
EV="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$EV/../.." && pwd)"
: "${KUBECONFIG:?point KUBECONFIG at a kind cluster}"
NS=agent-stack
W="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$W"; }
trap cleanup EXIT
die() { echo "!! $*" >&2; exit 2; }
cd "$W"

# The images are the product's: read from the manifests, never typed here (invariant 7).
TF_IMAGE="$(grep -o 'ghcr\.io/taipanbox/tokenfuse:v[^ ]*@sha256:[0-9a-f]*' "$REPO/manifests/10-planes.yaml" | head -1)"
WD_IMAGE="$(grep -o 'ghcr\.io/taipanbox/wardryx:v[^ ]*@sha256:[0-9a-f]*' "$REPO/manifests/10-planes.yaml" | head -1)"
[ -n "$TF_IMAGE" ] && [ -n "$WD_IMAGE" ] || die "could not read the tokenfuse and wardryx images from manifests/10-planes.yaml"
echo "== images (from the product manifests): gateway and broker $TF_IMAGE ; wardryx $WD_IMAGE"

echo "== setup (cluster: $(kubectl config current-context), namespace $NS)"
kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null || die "the old namespace did not go"
kubectl create namespace "$NS" >/dev/null || die "no namespace"
cat <<'YAML' | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: stack-events }
spec: { accessModes: ["ReadWriteOnce"], resources: { requests: { storage: 1Gi } } }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: stack-wiring }
data: { TRAILRYX_TRUST_DOMAIN: "tails.example" }
YAML

# The keys and the registry, minted by the product's own library (lib/vouchryx-mint.sh, lib/static-keys.sh).
k_() { eval "kubectl $*"; }
ROOT="$W"                      # the enrolment key lands in the scratch directory, not the repository
note() { printf '   %s\n' "$*"; }
die_lib() { die "$*"; }
. "$REPO/lib/gen.sh" || die "no lib/gen.sh"
. "$REPO/lib/secret-doc.sh" || die "no lib/secret-doc.sh"
. "$REPO/lib/vouchryx-mint.sh" || die "no lib/vouchryx-mint.sh"
. "$REPO/lib/static-keys.sh" || die "no lib/static-keys.sh"
vouchryx_mint_settle || die "vouchryx_mint_settle refused"
static_keys_settle || die "static_keys_settle refused"
cp "$W/agent-enrol-key" "$W/operator.secret" || die "no enrolment key"
for k in felyx agents drills costcrew broker broker-caller stranger; do openssl rand -hex 24 > "$W/$k.secret"; done
openssl rand -hex 24 > "$W/gateway-admin.secret"; openssl rand -hex 24 > "$W/declassify.secret"
cp "$W/broker.secret" "$W/wardryx.pep"   # the policy-plane key the gateway and the broker present (invariant 52)
openssl rand -hex 24 > "$W/wardryx-gw.secret"; cp "$W/wardryx-gw.secret" "$W/wardryx.pep"
sec() { cat "$W/$1.secret"; }
secret_doc gateway-client-keys "client_keys=$(sec felyx):felyx,$(sec agents):agents,$(sec drills):drills,$(sec costcrew):costcrew,$(sec broker):broker,$(sec stranger):stranger" \
  | kubectl -n "$NS" create -f - >/dev/null || die "gateway-client-keys"
secret_doc kind-stack-keys "gateway_admin=$(sec gateway-admin)" "declassify_key=$(sec declassify)" \
  "wardryx_gateway=$(sec wardryx-gw)" "wardryx_keys=$(sec wardryx-gw):default:pep" \
  | kubectl -n "$NS" create -f - >/dev/null || die "kind-stack-keys"
secret_doc gateway-upstream-key "anthropic_key=stand-in-provider-key" | kubectl -n "$NS" create -f - >/dev/null || die "upstream key"
kubectl -n "$NS" create secret generic broker-taint-key --from-file=client_key=<(printf '%s' "$(sec broker)") >/dev/null || die "broker-taint-key"
secret_doc tokenfuse-mcp-broker-keys "TOKENFUSE_MCP_KEYS=$(sec broker-caller):broker-caller" | kubectl -n "$NS" create -f - >/dev/null || die "broker keys"
kubectl -n "$NS" create configmap upstream-stub --from-file=server.py="$EV/upstream-stub.py" >/dev/null || die "upstream-stub"
kubectl -n "$NS" create configmap mcp-stub --from-file=server.py="$EV/mcp-stub.py" >/dev/null || die "mcp-stub"

echo "== vouchryx: manifests/54-delegation.yaml as the default install applies it (no IdP, no trusted issuer)"
kubectl -n "$NS" apply -f "$REPO/manifests/54-delegation.yaml" >/dev/null || die "54 did not apply"
kubectl -n "$NS" apply -f "$REPO/manifests/58-agent-tokens-network.yaml" >/dev/null || die "58 network did not apply"
kubectl -n "$NS" rollout status deployment/vouchryx --timeout=240s >/dev/null || die "vouchryx did not roll out without an IdP"

echo "== wardryx (product image), its own Postgres, and the stand-in network"
kubectl -n "$NS" apply -f "$EV/stand-in-dns.yaml" -f "$EV/stand-in-network.yaml" >/dev/null || die "network stand-ins"
sed "s#@@WARDRYX_IMAGE@@#$WD_IMAGE#" "$EV/wardryx.yaml" | kubectl -n "$NS" apply -f - >/dev/null || die "wardryx did not apply"
kubectl -n "$NS" rollout status deployment/policy-db --timeout=240s >/dev/null || die "policy-db did not roll out"
kubectl -n "$NS" rollout status deployment/wardryx --timeout=240s >/dev/null || die "wardryx did not roll out"

echo "== the stand-ins: provider and MCP upstream; gateway and broker with the product door env"
kubectl -n "$NS" apply -f "$EV/upstream.yaml" -f "$EV/mcp-stub.yaml" >/dev/null || die "stand-ins"
sed "s#@@TOKENFUSE_IMAGE@@#$TF_IMAGE#" "$EV/gateway-door.yaml" | kubectl -n "$NS" apply -f - >/dev/null || die "gateway"
sed "s#@@TOKENFUSE_IMAGE@@#$TF_IMAGE#" "$EV/broker-door.yaml" | kubectl -n "$NS" apply -f - >/dev/null || die "broker"
for d in upstream mcp-stub tokenfuse-gateway tokenfuse-mcp-broker; do
  kubectl -n "$NS" rollout status deployment/$d --timeout=240s >/dev/null || die "$d did not roll out"
done

echo "== port-forwards"
kubectl -n "$NS" port-forward svc/vouchryx 24310:4310 >/dev/null 2>&1 & PIDS+=($!)
kubectl -n "$NS" port-forward svc/tokenfuse-gateway 24400:4100 >/dev/null 2>&1 & PIDS+=($!)
kubectl -n "$NS" port-forward svc/tokenfuse-mcp-broker 24420:4200 >/dev/null 2>&1 & PIDS+=($!)
kubectl -n "$NS" port-forward svc/wardryx 24430:8090 >/dev/null 2>&1 & PIDS+=($!)
sleep 4
for port in 24310 24400 24420 24430; do for i in $(seq 1 30); do curl -s -m 3 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break; sleep 1; done; done

echo "== checks: gateway $TF_IMAGE, broker $TF_IMAGE, wardryx $WD_IMAGE, vouchryx v0.6.0"
PYTHONPATH="$EV/../agent-tokens-kind" python3 "$EV/checks.py" "$W"
rc=$?
echo "== the refusal reasons vouchryx journalled (the HTTP body carries the code only)"
cat <<'YAML' | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ev-reader }
spec:
  restartPolicy: Never
  containers:
    - name: r
      image: busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
      command: ["sleep", "120"]
      volumeMounts: [{ name: ev, mountPath: /ev, readOnly: true }]
  volumes: [{ name: ev, persistentVolumeClaim: { claimName: stack-events } }]
YAML
kubectl -n "$NS" wait --for=condition=Ready pod/ev-reader --timeout=120s >/dev/null 2>&1
kubectl -n "$NS" exec ev-reader -- sh -c 'grep -o "\"reason\":\"[a-z_]*\"" /ev/vouchryx.ndjson | sort | uniq -c' 2>/dev/null
kubectl -n "$NS" delete pod ev-reader --wait=false >/dev/null 2>&1
echo "== exit $rc"
exit $rc
