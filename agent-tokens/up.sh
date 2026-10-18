#!/usr/bin/env bash
# Turns on agent tokens on a cluster that already runs the delegation plane (CLAUDE.md
# invariant 54; WAVE1-DESIGN 1.2 to 1.7). Opt-in: `kubectl apply -k manifests/` never touches
# any of what this applies, and it changes nothing until you run it.
#
#   ./agent-tokens/up.sh --registry agents.txt            # apply
#   ./agent-tokens/up.sh --registry agents.txt --check-only
#
# agents.txt holds one line per agent, and nothing else:
#
#   agent://<trust domain>/<path>|<unit>|<org>|sha256:<64 hex>                 an enrolment key (agents outside the cluster)
#   agent://<trust domain>/<path>|<unit>|<org>|workload:<issuer>#<subject>     a pod's projected token (agents in the cluster)
#
# For a workload the <issuer> is this cluster's service-account issuer and the subject is
# system:serviceaccount:agent-stack:<ServiceAccount>; this script reads the issuer and the JWKS
# from the cluster itself, so the operator writes the subject and nothing else.
#
# It refuses before applying anything unless the delegation plane is up: agent tokens are
# verified by the same vouchryx and the same revocation list (54-delegation*.yaml, delegation/up.sh).
set -euo pipefail

cd "$(dirname "$0")/.."
NS=agent-stack
REGISTRY=""
CHECK_ONLY=0

die() { printf '%s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --registry) [ $# -ge 2 ] || die "--registry needs a file"; REGISTRY="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ---- 1. refuse before applying anything ------------------------------------------------
[ -n "$REGISTRY" ] || die "--registry FILE is required. Nothing was applied."
[ -s "$REGISTRY" ] || die "--registry $REGISTRY is missing or empty. Nothing was applied."
if ! awk -F'|' 'NF == 4 && $1 ~ /^agent:\/\/[^ ]+\/[^ ]+$/ && ($4 ~ /^sha256:[0-9a-f]+$/ || $4 ~ /^workload:[^#]+#[^#]+$/) { ok++ } END { exit (ok > 0 && ok == NR) ? 0 : 1 }' "$REGISTRY"; then
  die "$REGISTRY does not hold only lines of agent://<td>/<path>|<unit>|<org>|<credential>, with a sha256: or workload:<issuer>#<subject> credential. Nothing was applied."
fi
command -v kubectl >/dev/null || die "kubectl not found"
kubectl version -o json >/dev/null 2>&1 || die "no cluster: set KUBECONFIG"
kubectl -n "$NS" get deployment vouchryx >/dev/null 2>&1 \
  || die "vouchryx is not deployed in $NS: run delegation/up.sh first. Nothing was applied."
kubectl -n "$NS" get configmap vouchryx-trusted-issuers >/dev/null 2>&1 \
  || die "the delegation plane's ConfigMap vouchryx-trusted-issuers is missing: run delegation/up.sh first. Nothing was applied."
kubectl -n "$NS" get deployment tokenfuse-gateway >/dev/null 2>&1 \
  || die "tokenfuse-gateway is not deployed in $NS. Nothing was applied."
BROKER=0
if kubectl -n "$NS" get deployment tokenfuse-mcp-broker >/dev/null 2>&1; then
  # The broker relays an agent token to the gateway's tool-call check with its own key (id
  # `broker`, invariant 54). Without that key the relayed check is refused 401, so refuse here.
  kubectl -n "$NS" get secret broker-taint-key >/dev/null 2>&1 \
    || die "the broker is deployed but Secret broker-taint-key is missing: deploy so it is minted with the gateway's keys (lib/identity-mint.sh), or give the broker's key by hand. Nothing was applied."
  kubectl -n "$NS" get secret gateway-client-keys >/dev/null 2>&1 \
    || die "Secret gateway-client-keys is missing: the gateway has no client keys to hold the broker's. Nothing was applied."
  kubectl -n "$NS" get secret gateway-client-keys -o jsonpath='{.data.client_keys}' | base64 --decode | tr ',' '\n' | grep -q ':broker$' \
    || die "the gateway's client keys have no entry for the broker (key id broker): add one, or deploy to mint them. Nothing was applied."
  BROKER=1
fi

ISSUER="$(kubectl get --raw /.well-known/openid-configuration | python3 -c 'import sys,json; print(json.load(sys.stdin)["issuer"])')" \
  || die "could not read the cluster's service-account issuer. Nothing was applied."
JWKS_TMP="$(mktemp)"
trap 'rm -f "$JWKS_TMP" "$ISS_TMP" 2>/dev/null || true' EXIT
ISS_TMP="$(mktemp)"
kubectl get --raw /openid/v1/jwks > "$JWKS_TMP" || die "could not read the cluster's JWKS at /openid/v1/jwks. Nothing was applied."
python3 - "$JWKS_TMP" <<'PY' || die "the cluster's /openid/v1/jwks has no keys. Nothing was applied."
import json, sys
doc = json.load(open(sys.argv[1]))
sys.exit(0 if doc.get("keys") else 1)
PY

echo "cluster issuer: $ISSUER"
if [ "$CHECK_ONLY" = 1 ]; then
  echo "--check-only: the registry, the delegation plane and the cluster's issuer are as expected. Nothing was applied."
  exit 0
fi

# ---- 2. the data: the registry and the workload issuer, as ConfigMaps ---------------------
printf '%s|http://vouchryx:4310|/etc/vouchryx/workload/jwks.json\n' "$ISSUER" > "$ISS_TMP"
kubectl -n "$NS" create configmap vouchryx-agents --from-file="agents=$REGISTRY" --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
kubectl -n "$NS" create configmap vouchryx-workload --from-file="issuers=$ISS_TMP" --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
kubectl -n "$NS" create configmap vouchryx-workload-jwks --from-file="jwks.json=$JWKS_TMP" --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
echo "   registry, workload issuer and JWKS written as ConfigMaps (the secrets are digests and public keys only)"

# ---- 3. the switch: vouchryx reads the registry, the gateway accepts agent tokens ---------
echo "patching vouchryx (registry and workload issuer)"
kubectl -n "$NS" patch deployment vouchryx --patch-file manifests/58-agent-tokens-vouchryx-patch.yaml >/dev/null
kubectl -n "$NS" rollout status deployment/vouchryx --timeout=180s >/dev/null || die "vouchryx did not roll out with the registry. kubectl -n $NS logs deploy/vouchryx"
echo "patching tokenfuse-gateway (agent tokens accept)"
kubectl -n "$NS" patch deployment tokenfuse-gateway --patch-file manifests/58-agent-tokens-gateway-patch.yaml >/dev/null
kubectl -n "$NS" rollout status deployment/tokenfuse-gateway --timeout=180s >/dev/null || die "tokenfuse-gateway did not roll out with agent tokens on. kubectl -n $NS logs deploy/tokenfuse-gateway"

# ---- 4. the network agent pods need, and nothing else ------------------------------------
kubectl -n "$NS" apply -f manifests/58-agent-tokens-network.yaml >/dev/null
if [ "$BROKER" = 1 ]; then
  echo "patching tokenfuse-mcp-broker (agent tokens, and its own key for the tool-call check)"
  kubectl -n "$NS" patch deployment tokenfuse-mcp-broker --patch-file manifests/58-agent-tokens-broker-patch.yaml >/dev/null
  kubectl -n "$NS" rollout status deployment/tokenfuse-mcp-broker --timeout=180s >/dev/null || die "tokenfuse-mcp-broker did not roll out with agent tokens on. kubectl -n $NS logs deploy/tokenfuse-mcp-broker"
  kubectl -n "$NS" apply -f manifests/58-agent-tokens-broker-network.yaml >/dev/null
fi
echo "agent tokens are on: label an agent pod taipanbox.dev/agent-token=true (see agent-tokens/example-agent.yaml)."
echo "A stop is one call to vouchryx: POST http://vouchryx:4310/v1/revoke with ban:true, bearer = the revoke_key in the vouchryx-keys Secret."
