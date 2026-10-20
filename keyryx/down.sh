#!/usr/bin/env bash
# Turn Keyryx off again: wardryx goes back to its 2.1.0 wiring (the
# HMAC approval token of the default install), and the Keyryx Deployments,
# Services and NetworkPolicies are deleted.
#
#   KUBECONFIG=./kubeconfig.yaml ./keyryx/down.sh
#
# Keeps every key and every claim: the two root keys, the wardryx client key,
# the keyryx-state and keyryx-witness-state claims (the signing history and the
# witness's log live there) and the keyryx-policy ConfigMap. Deleting a key or a
# claim is not this script's decision (CLAUDE.md, conventions). Once wardryx has
# signed approvals with Keyryx, its v3 tokens verify only with Keyryx's key set,
# so turning this off does not revoke or re-sign them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
NS="${NS:-agent-stack}"

kubectl -n "$NS" patch deployment wardryx --type strategic --patch-file "$HERE/wardryx-unpatch.yaml"
kubectl -n "$NS" rollout status deployment/wardryx --timeout=300s

# The witness's readers (CLAUDE.md invariant 75) come off before the witness goes: each is pod-affined to it and
# mounts its claim, so a reader left patched could not be scheduled again once the witness is deleted.
unpatch_reader() {
  if kubectl -n "$NS" get deployment "$1" >/dev/null 2>&1; then
    kubectl -n "$NS" patch deployment "$1" --type strategic --patch-file "$HERE/$2"
    kubectl -n "$NS" rollout status "deployment/$1" --timeout=300s
  fi
}
unpatch_reader genaryx-console console-findings-unpatch.yaml
unpatch_reader heraldyx heraldyx-findings-unpatch.yaml

kubectl -n "$NS" delete networkpolicy keyryx-custody-ingress keyryx-witness-ingress --ignore-not-found
kubectl -n "$NS" delete service keyryx-custody keyryx-witness --ignore-not-found
kubectl -n "$NS" delete deployment keyryx-custody keyryx-witness --ignore-not-found
kubectl -n "$NS" delete serviceaccount keyryx-custody keyryx-witness --ignore-not-found
echo "Keyryx is off. Keys, claims and the policy ConfigMap are kept."
