#!/usr/bin/env bash
# Installs the admission policy for the stack's namespace (invariant 58 of CLAUDE.md).
#
# Opt-in, like identity/up.sh and closure/up.sh: no manifest names this directory, so
# `kubectl apply -k manifests/` leaves the controller and the policies alone. It runs against the
# cluster the current kubeconfig names.
#
# Two steps, and the second is a decision, not a default. This installs the controller and the
# policies, which refuse nothing while no namespace is opted in. Opting agent-stack in (--enforce)
# is what refuses images, and as of 2026-10-19 it refuses every TAIPANBOX image, signed or not: the
# controller finds no signature on them (policy/README.md, "Blocked"). So --enforce is for a
# cluster where that is known to be resolved, and never for a stack that is running.
#
# Order matters. The controller goes in first and its webhook must answer before anything else;
# the policies follow; the namespace is opted in last. A namespace opted in before its webhook
# answers refuses every pod create in it.
#
# Usage: policy/up.sh             install the controller and the policies, opt nothing in
#        policy/up.sh --enforce   the same, then opt agent-stack in (refuses unverified images)
set -euo pipefail

cd "$(dirname "$0")/.."

ENFORCE=0
case "${1:-}" in
  "") ;;
  --enforce) ENFORCE=1 ;;
  *) echo "usage: policy/up.sh [--enforce]" >&2; exit 2 ;;
esac

kubectl get namespace agent-stack >/dev/null

kubectl apply -f policy/policy-controller.yaml
kubectl -n cosign-system rollout status deployment/webhook --timeout=300s
kubectl apply -f policy/image-policy.yaml

if [ "$ENFORCE" = 1 ]; then
  kubectl label namespace agent-stack policy.sigstore.dev/include=true --overwrite
  echo "agent-stack is opted in: an image under ghcr.io/taipanbox/ must carry a signature the controller can"
  echo "verify, and an upstream image must be pinned by digest and listed in policy/image-policy.yaml."
else
  echo "installed: the controller and the policies. agent-stack is NOT opted in, so nothing is refused."
  echo "policy/up.sh --enforce opts it in; read policy/README.md first (the signatures are not yet found)."
fi
