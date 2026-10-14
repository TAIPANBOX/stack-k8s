# The refusal that runs BEFORE a deploy applies the manifests onto a cluster whose
# policy store sits on another storage class. Sourced by deploy.sh,
# cloud/gcp/deploy-gcp.sh and cloud/aws/deploy-aws.sh, not run. CLAUDE.md
# invariant 43; GOTCHAS 129.
#
# Why it exists: a StatefulSet's claim template cannot change in place. On a
# cluster that already runs policy-db on Longhorn's default class, `apply -k`
# is refused for that one object while the others apply, and under
# `set -euo pipefail` the deploy then stops in the middle of step 3. This check
# turns that into one sentence before anything is applied.
#
#   . "$ROOT/lib/policy-store.sh" || die "no lib/policy-store.sh in $ROOT"
#   policy_store_guard          # before the first `apply -k` of manifests/
#
# Needs in scope, from the deploy script: die() and k_ (its kubectl runner, which
# runs `k3s kubectl` on the first server).
#
# There is no opt-out flag on purpose. An opt-out would only reproduce the
# refusal in the middle of the apply. The way past it is the migration in
# GOTCHAS 129, after which policy-db is on stack-policy and this returns 0.
policy_store_guard() {
  local existing cls
  existing="$(k_ "-n agent-stack get statefulset policy-db --ignore-not-found -o name")" \
    || die "could not ask the cluster whether policy-db exists, so the manifests were not applied"
  [ -n "$existing" ] || return 0
  cls="$(k_ "-n agent-stack get statefulset policy-db -o jsonpath='{.spec.volumeClaimTemplates[0].spec.storageClassName}'")" \
    || die "could not read policy-db's claim class, so the manifests were not applied"
  [ "$cls" = "stack-policy" ] && return 0
  die "policy-db already exists on a claim of class '${cls:-the default class}', not stack-policy, and applying the manifests would be refused partway through, so nothing was applied: migrate the policy store first as GOTCHAS 129 describes (scale policy-db to 0, copy its pgdata off the volume, create a stack-policy claim, restore into it, then deploy again)."
}
