#!/usr/bin/env bash
# Take the delegation plane down and restore the gateway and the console to
# their default env.
#
#   ./delegation/down.sh [--delete-secrets]
#
# Requirement 5: removes what up.sh added, and restores the gateway (and the
# console) to their default env by re-applying the kustomization, the same
# mechanism 55-copilot-cloud.yaml's own header already documents ("delete the
# Secret and re-apply the manifests"). `kubectl apply -k` reverts what it
# manages (CLAUDE.md invariant 14's own words), and the delegation env vars
# and the volumes that carry them are fields of Deployments the kustomization
# already manages, so this is not a new mechanism, it is the same one.
#
# Leaves the vouchryx-keys Secret and the vouchryx-trusted-issuers ConfigMap
# in place by default, the same stance hub/down.sh takes on stack-keys: taking
# the plane down is not the same decision as revoking or forgetting a
# credential, and this script does not make that decision on its own
# initiative. Pass --delete-secrets to remove them too (this is a lab
# teardown convenience, not something a production down.sh should reach for
# without being asked).
#
# The revocation store (vouchryx-state PVC) is deleted always: it is a
# PersistentVolumeClaim that provisions a real, billed disk (CLAUDE.md's
# components.json note on persistent claims), and it holds nothing an
# operator would want back once the plane it served is gone.
#
# KUBECONFIG comes from the environment, same as every other script here.
# Idempotent: running it again once everything is already gone reports so and
# exits 0.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-agent-stack}"
DELETE_SECRETS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --delete-secrets) DELETE_SECRETS=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
k() { kubectl -n "$NS" "$@"; }

say "removing manifests/54-delegation.yaml (vouchryx, its NetworkPolicies, its PVC)"
kubectl delete -f "$ROOT/manifests/54-delegation.yaml" --ignore-not-found=true --wait=true 2>&1 | sed 's/^/   /'

say "restoring tokenfuse-gateway and genaryx-console to their default env"
kubectl apply -k "$ROOT/manifests" 2>&1 | sed 's/^/   /'
if k get deployment tokenfuse-gateway >/dev/null 2>&1; then
  k rollout status deployment/tokenfuse-gateway --timeout=120s || true
fi
if k get deployment genaryx-console >/dev/null 2>&1; then
  k rollout status deployment/genaryx-console --timeout=120s || true
fi

say "removing vouchryx-jwks (vouchryx's served JWKS, cached at enable time)"
k delete configmap vouchryx-jwks --ignore-not-found=true >/dev/null

if [ "$DELETE_SECRETS" = 1 ]; then
  say "removing vouchryx-keys and vouchryx-trusted-issuers (--delete-secrets)"
  k delete secret vouchryx-keys --ignore-not-found=true >/dev/null
  k delete configmap vouchryx-trusted-issuers --ignore-not-found=true >/dev/null
else
  cat <<EOF

  Left as they are, on purpose:
    secret    vouchryx-keys              (the signing key and the revoke key)
    configmap vouchryx-trusted-issuers   (the operator's issuer, audience, JWKS)

  Taking the plane down is not the same decision as revoking or forgetting a
  credential. Re-running ./delegation/up.sh with the same flags reuses both.
  Pass --delete-secrets to remove them here instead.
EOF
fi

cat <<EOF

  Confirm the gateway verifies no delegation chain any more:
    kubectl -n $NS get deployment tokenfuse-gateway -o jsonpath='{.spec.template.spec.containers[?(@.name=="gateway")].env[*].name}'
    (must not list any TOKENFUSE_DELEGATION_* name)
EOF
