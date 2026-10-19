#!/usr/bin/env bash
# Removes the admission policy again (invariant 58 of CLAUDE.md). The order is the point: the
# webhooks go first, so nothing is checked while the policies and the controller are removed; the
# namespace then finishes terminating on its own, which can take minutes. Pods already running are
# not touched.
set -euo pipefail

cd "$(dirname "$0")/.."

kubectl label namespace agent-stack policy.sigstore.dev/include- --overwrite >/dev/null 2>&1 || true
kubectl delete validatingwebhookconfiguration validating.clusterimagepolicy.sigstore.dev policy.sigstore.dev --ignore-not-found
kubectl delete mutatingwebhookconfiguration defaulting.clusterimagepolicy.sigstore.dev policy.sigstore.dev --ignore-not-found
kubectl delete -f policy/image-policy.yaml --ignore-not-found
kubectl delete clusterimagepolicy taipanbox-signed --ignore-not-found
if [ -f policy/operator-image-policy.yaml ]; then
  kubectl delete -f policy/operator-image-policy.yaml --ignore-not-found
fi
kubectl delete -f policy/policy-controller.yaml --ignore-not-found --wait=false

echo "admission is off: the webhooks are gone. The cosign-system namespace finishes terminating on its own."
