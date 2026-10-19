#!/usr/bin/env bash
# Measured on the stack-k8s v1.2.0 pin set (CLAUDE.md invariant 54, GOTCHAS 137): tokenfuse v1.18.0 at
# the gateway and the broker, vouchryx v0.6.0 from manifests/54-delegation.yaml, the agent audience
# https://vouchryx.agent-stack.invalid. The product files are applied where they exist: vouchryx, and the
# agent-token door through agent-tokens/up.sh. Stand-ins: the provider (upstream), the MCP upstream, the
# gateway and the broker base (gateway-base-v1.18.0.yaml, broker-base-v1.18.0.yaml: the product env minus
# the door), and the DNS and upstream network rules.
# Needs KUBECONFIG at a cluster you may create objects in (kind is enough). Secrets live in a scratch
# directory that is removed on exit. Run: ./evidence/agent-tokens-kind/run-v1.18.0.sh | tee output-v1.18.0.txt
set -uo pipefail
EV="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$EV/../.." && pwd)"
: "${KUBECONFIG:?point KUBECONFIG at a kind cluster}"
NS=agent-stack
W="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; [ -n "${KEEP:-}" ] || rm -rf "$W"; }
trap cleanup EXIT
die() { echo "!! $*" >&2; exit 2; }
cd "$W"

echo "== setup (cluster: $(kubectl config current-context), namespace $NS)"
# A fresh namespace every run: a secret that already exists is not replaced by create, and a stale one
# would pair with this run's files and refuse every call.
kubectl delete namespace "$NS" --ignore-not-found --wait=true >/dev/null || die "the old namespace did not go"
kubectl create namespace "$NS" >/dev/null || die "no namespace"
cat <<'YAML' | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: stack-events }
spec: { accessModes: ["ReadWriteOnce"], resources: { requests: { storage: 1Gi } } }
YAML
openssl ecparam -genkey -name prime256v1 -noout -out signing.pem 2>/dev/null
REVOKE="$(openssl rand -hex 32)"; printf '%s' "$REVOKE" > revoke.key
ENROL="$(openssl rand -hex 24)"; printf '%s' "$ENROL" > enrol.secret
GW="$(openssl rand -hex 24)"; printf '%s' "$GW" > gw-client.secret
BRK="$(openssl rand -hex 24)"; printf '%s' "$BRK" > broker.secret
DIGEST="$(printf '%s' "$ENROL" | shasum -a 256 | cut -d' ' -f1)"
kubectl -n "$NS" create secret generic vouchryx-keys --from-file=signing.pem=signing.pem --from-literal=revoke_key="$REVOKE" >/dev/null
kubectl -n "$NS" create secret generic gateway-client-keys --from-literal=client_keys="$GW:gateway-caller,$BRK:broker" >/dev/null
kubectl -n "$NS" create secret generic broker-taint-key --from-file=client_key=broker.secret >/dev/null
kubectl -n "$NS" create secret generic gateway-upstream-key --from-literal=anthropic_key=stand-in-provider-key >/dev/null
kubectl -n "$NS" create secret generic tokenfuse-mcp-broker-keys --from-literal=TOKENFUSE_MCP_KEYS="$BRK:broker-caller" >/dev/null
kubectl get --raw /openid/v1/jwks > jwks.json || die "no cluster JWKS"
kubectl -n "$NS" create configmap vouchryx-trusted-issuers \
	--from-literal=trusted_issuers="https://idp.stand-in.invalid|http://vouchryx:4310|/etc/vouchryx/trusted/idp.jwks.json" \
	--from-file=idp.jwks.json=jwks.json >/dev/null
kubectl -n "$NS" create configmap upstream-stub --from-file=server.py="$EV/upstream-stub.py" >/dev/null
kubectl -n "$NS" create configmap mcp-stub --from-file=server.py="$EV/mcp-stub.py" >/dev/null

echo "== the delegation plane: vouchryx v0.6.0 from manifests/54-delegation.yaml"
kubectl -n "$NS" apply -f "$REPO/manifests/54-delegation.yaml" >/dev/null || die "54 did not apply"
kubectl -n "$NS" rollout status deployment/vouchryx --timeout=240s >/dev/null || die "vouchryx did not roll out"
kubectl -n "$NS" port-forward svc/vouchryx 24310:4310 >/dev/null 2>&1 & VX_PF=$!
for i in $(seq 1 30); do curl -fsS -o jwks-vx.json http://127.0.0.1:24310/.well-known/jwks.json 2>/dev/null && break; sleep 1; done
[ -s jwks-vx.json ] || die "vouchryx's JWKS did not answer through the port-forward"
kill "$VX_PF" 2>/dev/null; wait "$VX_PF" 2>/dev/null; sleep 1   # a forward holds one pod: this one dies with the rollout that up.sh makes
kubectl -n "$NS" create configmap vouchryx-jwks --from-file=jwks.json=jwks-vx.json >/dev/null

echo "== the stand-ins: provider, gateway base, MCP upstream, broker base"
kubectl -n "$NS" apply -f "$EV/upstream.yaml" >/dev/null || die "upstream"
kubectl -n "$NS" apply -f "$EV/gateway-base-v1.18.0.yaml" >/dev/null || die "gateway base"
kubectl -n "$NS" apply -f "$EV/mcp-stub.yaml" >/dev/null || die "mcp stub"
kubectl -n "$NS" apply -f "$EV/broker-base-v1.18.0.yaml" >/dev/null || die "broker base"
kubectl -n "$NS" apply -f "$EV/stand-in-dns.yaml" -f "$EV/stand-in-52-upstream.yaml" -f "$EV/stand-in-gateway-upstream.yaml" >/dev/null || die "network stand-ins"
for d in upstream tokenfuse-gateway mcp-stub tokenfuse-mcp-broker; do
	kubectl -n "$NS" rollout status deployment/$d --timeout=240s >/dev/null || die "$d did not roll out"
done

echo "== the agent-token door: agent-tokens/up.sh (registry and patches from the repository)"
printf 'agent://k2.example/agents/enrolled-agent|enrolled|k2.example|sha256:%s\n' "$DIGEST" > agents.txt
(cd "$REPO" && ./agent-tokens/up.sh --registry "$W/agents.txt") || die "agent-tokens/up.sh refused"

echo "== vouchryx's JWKS from the pod serving now (up.sh rolled it; the signing key is the same secret, but a
   gateway that read the first pod's keys refuses every token it did not mint: GOTCHAS 136-style check)"
kubectl -n "$NS" port-forward svc/vouchryx 24310:4310 >/dev/null 2>&1 & PIDS+=($!)
sleep 2; for i in $(seq 1 30); do curl -fsS -o jwks-now.json http://127.0.0.1:24310/.well-known/jwks.json 2>/dev/null && break; sleep 1; done
[ -s jwks-now.json ] || die "vouchryx's JWKS did not answer after up.sh"
kubectl -n "$NS" delete configmap vouchryx-jwks --ignore-not-found >/dev/null
kubectl -n "$NS" create configmap vouchryx-jwks --from-file=jwks.json=jwks-now.json >/dev/null
kubectl -n "$NS" rollout restart deployment/tokenfuse-gateway deployment/tokenfuse-mcp-broker >/dev/null
for d in tokenfuse-gateway tokenfuse-mcp-broker; do kubectl -n "$NS" rollout status deployment/$d --timeout=240s >/dev/null || die "$d did not roll out with the new JWKS"; done
kubectl -n "$NS" port-forward svc/tokenfuse-gateway 24400:4100 >/dev/null 2>&1 & PIDS+=($!)
kubectl -n "$NS" port-forward svc/tokenfuse-mcp-broker 24420:4200 >/dev/null 2>&1 & PIDS+=($!)
sleep 4

for port in 24400 24420; do for i in $(seq 1 30); do curl -fsS -m 3 -o /dev/null http://127.0.0.1:$port/healthz 2>/dev/null && break; sleep 1; done; done
echo "== checks (tokenfuse $(kubectl -n "$NS" get deploy tokenfuse-gateway -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://;s/@.*//'), vouchryx v0.6.0)"
PYTHONPATH="$EV" python3 "$EV/checks-v1.18.0.py" 3
rc=$?
echo "== the refusal reasons, from vouchryx's event journal (the HTTP body carries the code, not the reason)"
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
kubectl -n "$NS" wait --for=condition=Ready pod/ev-reader --timeout=120s >/dev/null
kubectl -n "$NS" exec ev-reader -- sh -c 'grep "delegation_denied" /ev/vouchryx.ndjson | grep -o "\"reason\":\"[a-z_]*\"" | sort | uniq -c'
if ! kubectl -n "$NS" exec ev-reader -- grep -q 'audience_not_allowed' /ev/vouchryx.ndjson; then
	echo "!! no audience_not_allowed refusal in the journal"; rc=1
fi
kubectl -n "$NS" delete pod ev-reader --wait=false >/dev/null 2>&1
echo "== exit $rc"
exit $rc
