#!/usr/bin/env bash
# Installs the admission policy for the stack's namespace (invariant 58 of CLAUDE.md).
#
# No manifest names this directory, so `kubectl apply -k manifests/` leaves the controller and the
# policies alone. It runs against the cluster the current kubeconfig names, or the client KUBECTL
# names. deploy.sh runs it with --enforce after the manifests are applied (the default install).
#
# Two steps. This installs the controller and the policies, which refuse nothing while no namespace
# is opted in. Opting agent-stack in (--enforce) is what refuses images: an image under
# ghcr.io/taipanbox/ must carry a legacy .sig signature that its own repository's workflow made, and
# an image no policy covers is refused. Measured for this pin on kind: policy/README.md.
#
# Order matters. The controller goes in first and its webhook must answer before anything else;
# the policies follow; the namespace is opted in last. A namespace opted in before its webhook
# answers refuses every pod create in it.
#
# Usage: policy/up.sh             install the controller and the policies, opt nothing in
#        policy/up.sh --enforce   the same, then opt agent-stack in (refuses unverified images)
set -euo pipefail

cd "$(dirname "$0")/.."

# KUBECTL names the client, as verify.sh does: deploy.sh runs this on the first node with
# KUBECTL="/usr/local/bin/k3s kubectl", the way its other steps run kubectl there.
KUBECTL="${KUBECTL:-kubectl}"

ENFORCE=0
case "${1:-}" in
  "") ;;
  --enforce) ENFORCE=1 ;;
  *) echo "usage: policy/up.sh [--enforce]" >&2; exit 2 ;;
esac

$KUBECTL get namespace agent-stack >/dev/null

$KUBECTL apply -f policy/policy-controller.yaml
$KUBECTL -n cosign-system rollout status deployment/webhook --timeout=300s
# The single policy this file used to apply, before one per repository: a cluster that ran it would keep
# admitting any repository's signature for every TAIPANBOX image, because apply does not prune.
$KUBECTL delete clusterimagepolicy taipanbox-signed --ignore-not-found >/dev/null
$KUBECTL apply -f policy/image-policy.yaml
# The operator's own entries (policy/operator-image-policy.example.yaml is the template): applied when the
# copy is present and holds an entry, before the namespace is labelled, so an agent image the operator
# lists is admitted from its first pod. `grep` finds an entry, so a copy of the bare template is skipped.
if [ -f policy/operator-image-policy.yaml ] && grep -q '^kind: ClusterImagePolicy' policy/operator-image-policy.yaml; then
  $KUBECTL apply -f policy/operator-image-policy.yaml
fi

if [ "$ENFORCE" = 1 ]; then
  $KUBECTL label namespace agent-stack policy.sigstore.dev/include=true --overwrite
  echo "agent-stack is opted in: an image under ghcr.io/taipanbox/ must carry a signature the controller can"
  echo "verify, and an upstream image must be pinned by digest and listed in policy/image-policy.yaml."
else
  echo "installed: the controller and the policies. agent-stack is NOT opted in, so nothing is refused."
  echo "policy/up.sh --enforce opts it in; read policy/README.md first (the signatures are not yet found)."
fi
