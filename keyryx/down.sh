#!/usr/bin/env bash
# Turn Keyryx off again: every object the Keyryx install patched is unpatched
# (wardryx back to the approval token of the default install, the record-seal
# back to its own signer, the console and heraldyx off the witness's claim), and
# then the Keyryx Deployments, Services and NetworkPolicies are deleted.
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
ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-agent-stack}"
KEYRYX_NS="$NS"

command -v kubectl >/dev/null || { echo "keyryx/down.sh: kubectl is needed" >&2; exit 1; }
die() { echo "keyryx/down.sh: $*" >&2; exit 1; }

# The library's k_ takes one argument string, as in keyryx/up.sh. Every string it runs is written in
# lib/keyryx-install.sh; none is built from input.
k_() { eval "kubectl $*"; }

. "$ROOT/lib/keyryx-install.sh"

# Every object lib/keyryx-install.sh patches is unpatched first, through the same keyryx_remove_settle the
# opt-out runs (wardryx, the record-seal, the console, heraldyx), BEFORE anything is deleted: the record-seal and
# the two readers are pod-affined to the witness, so one left patched could not be scheduled again once the
# witness is gone, and the record-seal would still sign through a custody that is no longer there. The same step
# lets a running record-seal Job finish and deletes any other one still bound to the witness, since a Job keeps the
# template it was made from and a Pending one would hold back every later seal (concurrencyPolicy Forbid).
keyryx_remove_settle
for dep in wardryx genaryx-console heraldyx; do
  # A failed read stops here: inside `[ -n "$(...)" ]` it would read as "not installed" and skip the wait.
  found="$(kubectl -n "$NS" get deployment "$dep" --ignore-not-found -o name)" \
    || die "could not read deployment $dep to wait for its rollout off Keyryx"
  if [ -n "$found" ]; then
    kubectl -n "$NS" rollout status "deployment/$dep" --timeout=300s
  fi
done

kubectl -n "$NS" delete networkpolicy keyryx-custody-ingress keyryx-witness-ingress --ignore-not-found
kubectl -n "$NS" delete service keyryx-custody keyryx-witness --ignore-not-found
kubectl -n "$NS" delete deployment keyryx-custody keyryx-witness --ignore-not-found
kubectl -n "$NS" delete serviceaccount keyryx-custody keyryx-witness --ignore-not-found
echo "Keyryx is off. Keys, claims and the policy ConfigMap are kept."
