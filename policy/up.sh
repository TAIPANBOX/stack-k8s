#!/usr/bin/env bash
# Turns on the admission policy for the stack's namespace (invariant 58 of CLAUDE.md).
#
# Opt-in, like identity/up.sh and closure/up.sh: no manifest names this directory, so
# `kubectl apply -k manifests/` leaves the controller and the policy alone. Run it once the stack
# is applied, against the cluster the current kubeconfig names.
#
# Order matters. The controller goes in first and its webhook must answer before anything else;
# the policies follow; the namespace is opted in last. A namespace opted in before its webhook
# answers refuses every pod create in it, which is the closed direction, but it also refuses the
# stack's own restarts until the webhook is up, so the wait is not optional.
#
# Usage: policy/up.sh          (no flags; KUBECONFIG selects the cluster)
set -euo pipefail

cd "$(dirname "$0")/.."

kubectl get namespace agent-stack >/dev/null

kubectl apply -f policy/policy-controller.yaml
kubectl -n cosign-system rollout status deployment/webhook --timeout=300s
kubectl apply -f policy/image-policy.yaml
kubectl label namespace agent-stack policy.sigstore.dev/include=true --overwrite

echo "agent-stack is opted in: an image under ghcr.io/taipanbox/ must carry the release signature,"
echo "and an upstream image must be pinned by digest and listed in policy/image-policy.yaml."
