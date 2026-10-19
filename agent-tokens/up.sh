#!/usr/bin/env bash
# Writes the agent registry that vouchryx enrols agents from, and, for a cluster that runs an agent pod, the
# workload issuer that pod's projected token is checked against (CLAUDE.md invariant 54).
#
# The agent-token door is ON in every default install: the gateway and the MCP broker require an agent token,
# and this script switches nothing. Its only job is the registry. The default install enrols the operator's
# own agent at deploy time (lib/vouchryx-mint.sh); run this to enrol more, or to add an agent pod.
#
#   ./agent-tokens/up.sh --registry agents.txt            # write the registry, roll vouchryx
#   ./agent-tokens/up.sh --registry agents.txt --check-only
#
# THE FILE REPLACES THE REGISTRY. Put every agent in it, the operator's own included. Its line is
# `agent://<td>/agents/operator|agents|stack|sha256:<digest>` (the digest of the key in agent-enrol-key).
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
# It refuses before writing anything unless vouchryx and the gateway are deployed and, when the broker is
# deployed, the broker's key is minted and on the gateway's list.
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
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# ---- 1. refuse before writing anything -------------------------------------------------
[ -n "$REGISTRY" ] || die "--registry FILE is required. Nothing was written."
[ -s "$REGISTRY" ] || die "--registry $REGISTRY is missing or empty. Nothing was written."
if ! awk -F'|' 'NF == 4 && $1 ~ /^agent:\/\/[^ ]+\/[^ ]+$/ && ($4 ~ /^sha256:[0-9a-f]+$/ || $4 ~ /^workload:[^#]+#[^#]+$/) { ok++ } END { exit (ok > 0 && ok == NR) ? 0 : 1 }' "$REGISTRY"; then
  die "$REGISTRY does not hold only lines of agent://<td>/<path>|<unit>|<org>|<credential>, with a sha256: or workload:<issuer>#<subject> credential. Nothing was written."
fi
command -v kubectl >/dev/null || die "kubectl not found"
kubectl version -o json >/dev/null 2>&1 || die "no cluster: set KUBECONFIG"
kubectl -n "$NS" get deployment vouchryx >/dev/null 2>&1 \
  || die "vouchryx is not deployed in $NS: deploy the stack first. Nothing was written."
kubectl -n "$NS" get secret vouchryx-keys >/dev/null 2>&1 \
  || die "Secret vouchryx-keys is missing: lib/vouchryx-mint.sh mints it on deploy. Nothing was written."
kubectl -n "$NS" get deployment tokenfuse-gateway >/dev/null 2>&1 \
  || die "tokenfuse-gateway is not deployed in $NS. Nothing was written."
if kubectl -n "$NS" get deployment tokenfuse-mcp-broker >/dev/null 2>&1; then
  # The broker relays an agent token to the gateway's tool-call check with its own key (id `broker`, invariant 54).
  kubectl -n "$NS" get secret broker-taint-key >/dev/null 2>&1 \
    || die "the broker is deployed but Secret broker-taint-key is missing: deploy so it is minted with the gateway's keys (lib/identity-mint.sh). Nothing was written."
  kubectl -n "$NS" get secret gateway-client-keys -o jsonpath='{.data.client_keys}' | base64 --decode | tr ',' '\n' | grep -q ':broker$' \
    || die "the gateway's client keys have no entry for the broker (key id broker): deploy to mint them. Nothing was written."
fi

ISSUER="$(kubectl get --raw /.well-known/openid-configuration | python3 -c 'import sys,json; print(json.load(sys.stdin)["issuer"])')" \
  || die "could not read the cluster's service-account issuer. Nothing was written."
JWKS_TMP="$(mktemp)"
ISS_TMP="$(mktemp)"
trap 'rm -f "$JWKS_TMP" "$ISS_TMP" 2>/dev/null || true' EXIT
kubectl get --raw /openid/v1/jwks > "$JWKS_TMP" || die "could not read the cluster's JWKS at /openid/v1/jwks. Nothing was written."
python3 - "$JWKS_TMP" <<'PY' || die "the cluster's /openid/v1/jwks has no keys. Nothing was written."
import json, sys
doc = json.load(open(sys.argv[1]))
sys.exit(0 if doc.get("keys") else 1)
PY

echo "cluster issuer: $ISSUER"
if [ "$CHECK_ONLY" = 1 ]; then
  echo "--check-only: the registry, vouchryx and the cluster's issuer are as expected. Nothing was written."
  exit 0
fi

# ---- 2. the registry and the workload issuer, as ConfigMaps (data, not secrets) ---------
printf '%s|http://vouchryx:4310|/etc/vouchryx/workload/jwks.json\n' "$ISSUER" > "$ISS_TMP"
kubectl -n "$NS" create configmap vouchryx-agents --from-file="agents=$REGISTRY" --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
kubectl -n "$NS" create configmap vouchryx-workload --from-file="issuers=$ISS_TMP" --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
kubectl -n "$NS" create configmap vouchryx-workload-jwks --from-file="jwks.json=$JWKS_TMP" --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
echo "   registry, workload issuer and JWKS written as ConfigMaps (digests and public keys only)"

# ---- 3. vouchryx reads the registry at start: roll it ----------------------------------
kubectl -n "$NS" rollout restart deployment/vouchryx >/dev/null
kubectl -n "$NS" rollout status deployment/vouchryx --timeout=180s >/dev/null || die "vouchryx did not roll out with the registry. kubectl -n $NS logs deploy/vouchryx"
echo "vouchryx rolled with the registry. An agent pod is labelled taipanbox.dev/agent-token=true (see agent-tokens/example-agent.yaml)."
echo "A stop is one call to vouchryx: POST http://vouchryx:4310/v1/revoke with ban:true, bearer = the revoke_key in the vouchryx-keys Secret."
