#!/usr/bin/env bash
# Take the delegation plane down and restore the gateway and the console to
# their default env.
#
#   ./delegation/down.sh [--delete-secrets]
#
# Requirement 5: removes what up.sh added, and restores the gateway (and the
# console) to their default env.
#
# NOT by re-applying the kustomization. That was tried first, on the theory
# that `kubectl apply -k` reverts what it manages (CLAUDE.md invariant 14's
# own words) the same way 55-copilot-cloud.yaml's header says "delete the
# Secret and re-apply the manifests" undoes ITS patch. It does not work for
# a `kubectl patch --patch-file`: that command never touches the
# `kubectl.kubernetes.io/last-applied-configuration` annotation `apply`'s own
# three-way diff reads, so apply sees no difference between what it applied
# last time and what it wants now, and leaves the patch's additions exactly
# where they are. Measured 2026-09-27 on forge: every TOKENFUSE_DELEGATION_*
# env var and the vouchryx-jwks volume were still on the live Deployment
# after `kubectl apply -k manifests/`. So this script explicitly reverses
# each patch with its own `$patch: delete` counterpart
# (manifests/54-delegation-gateway-unpatch.yaml,
# manifests/54-delegation-console-unpatch.yaml), which is the same mechanism
# `up.sh` uses to add the fields, run in reverse.
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

say "restoring tokenfuse-gateway to its default env"
if k get deployment tokenfuse-gateway >/dev/null 2>&1; then
  k patch deployment tokenfuse-gateway --type strategic \
    --patch-file "$ROOT/manifests/54-delegation-gateway-unpatch.yaml" >/dev/null
  k rollout status deployment/tokenfuse-gateway --timeout=120s || true
fi

say "restoring genaryx-console to its default env"
if k get deployment genaryx-console >/dev/null 2>&1; then
  k patch deployment genaryx-console --type strategic \
    --patch-file "$ROOT/manifests/54-delegation-console-unpatch.yaml" >/dev/null
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
