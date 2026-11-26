#!/usr/bin/env bash
# Before the manifests are applied (CLAUDE.md invariant 58): on a cluster that already enforces admission,
# this tree's policies go in first, so an image this release names for the first time is admitted by the
# apply that names it. Without it, a release that renames an image (the console, genaryx-console to genaryx,
# stack-k8s 1.19.0) is refused by `no-match-policy: deny` in the middle of `apply -k`, the launcher stops
# there, and policy/up.sh, which would apply the new policy, runs only after the apply. On a cluster with no
# policy controller yet it does nothing: policy/up.sh installs the controller after the apply, as before.
# A policy this tree no longer has is removed by policy/up.sh, after the apply, never here, so a pod of the
# old release that is recreated mid-rollout is still admitted.
set -euo pipefail
cd "$(dirname "$0")/.."
KUBECTL="${KUBECTL:-kubectl}"

crd="$($KUBECTL get crd clusterimagepolicies.policy.sigstore.dev --ignore-not-found -o name)" \
  || { echo "admission: could not ask the cluster whether a policy controller is installed" >&2; exit 1; }
if [ -z "$crd" ]; then
  echo "admission: no policy controller on this cluster yet, so nothing to refresh before the apply"
  exit 0
fi
$KUBECTL apply -f policy/image-policy.yaml
echo "admission: this release's policies are in before its manifests"
