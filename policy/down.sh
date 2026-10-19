#!/usr/bin/env bash
# Turns the admission policy off again (invariant 58 of CLAUDE.md). Reverses policy/up.sh in the
# opposite order: the namespace comes out of the policy first, then the policies, then the controller.
# Pods already running are not touched; a new create is admitted again once the label is gone.
set -euo pipefail

cd "$(dirname "$0")/.."

kubectl label namespace agent-stack policy.sigstore.dev/include- --overwrite >/dev/null 2>&1 || true
kubectl delete -f policy/image-policy.yaml --ignore-not-found
kubectl delete -f policy/policy-controller.yaml --ignore-not-found

echo "agent-stack is no longer opted in, and the policy controller is removed."
