#!/usr/bin/env bash
# Turns agent tokens off again: reverses what agent-tokens/up.sh applied. The delegation plane
# stays as it was. Standing bans are kept in vouchryx's revocation file: lift them first if a
# banned agent must come back.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=agent-stack
kubectl -n "$NS" delete -f manifests/58-agent-tokens-network.yaml --ignore-not-found >/dev/null
kubectl -n "$NS" patch deployment tokenfuse-gateway --patch-file manifests/58-agent-tokens-gateway-unpatch.yaml >/dev/null
kubectl -n "$NS" rollout status deployment/tokenfuse-gateway --timeout=180s >/dev/null
kubectl -n "$NS" patch deployment vouchryx --patch-file manifests/58-agent-tokens-vouchryx-unpatch.yaml >/dev/null
kubectl -n "$NS" rollout status deployment/vouchryx --timeout=180s >/dev/null
for cm in vouchryx-agents vouchryx-workload vouchryx-workload-jwks; do
  kubectl -n "$NS" delete configmap "$cm" --ignore-not-found >/dev/null
done
echo "agent tokens are off; the delegation plane is unchanged."
