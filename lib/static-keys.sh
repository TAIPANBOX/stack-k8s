# The operator's own static-key list for the gateway, created empty once. Sourced by deploy.sh,
# cloud/gcp/deploy-gcp.sh and cloud/aws/deploy-aws.sh, not run. CLAUDE.md invariant 62 (2026-10-19).
#
# The gateway admits a static client key only when its key id is on its allow-list (invariant 62).
# The list is two parts: the stack's own, written in manifests/10-planes.yaml with a reason beside each
# id, and the operator's, read from the ConfigMap gateway-static-keys, key operator_key_ids. The
# operator's part is a ConfigMap and not a manifest line on purpose: `kubectl apply -k` would put a
# manifest's value back over an edit (invariant 14), and this ConfigMap is not in any manifest.
#
# The value is a comma-separated list that begins with a comma, or is empty:
#
#   ,claude-code,ci-runner
#
# To add a client, edit that ConfigMap and roll the gateway, which reads the list at start:
#
#   kubectl -n agent-stack patch configmap gateway-static-keys --type merge -p '{"data":{"operator_key_ids":",claude-code"}}'
#   kubectl -n agent-stack rollout restart deployment/tokenfuse-gateway
#
# Created only when absent, and never rewritten: a re-run keeps the operator's list.
#
#   . "$ROOT/lib/static-keys.sh" || die "no lib/static-keys.sh in $ROOT"
#   static_keys_settle                   # after `apply -k`
#
# Needs in scope, from the caller: die(), note() and k_ (its kubectl runner, given ONE string).
if ! declare -F die >/dev/null; then die() { printf '!! %s\n' "$*" >&2; exit 1; }; fi
if ! declare -F note >/dev/null; then note() { printf '   %s\n' "$*"; }; fi

static_keys_settle() {
  if k_ "-n agent-stack get configmap gateway-static-keys -o name" >/dev/null 2>&1; then
    note "ConfigMap gateway-static-keys present: the operator's static-key list is kept"
    return 0
  fi
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: gateway-static-keys\n  namespace: agent-stack\ndata:\n  operator_key_ids: ""\n' \
    | k_ "-n agent-stack create -f -" >/dev/null \
    || die "could not create ConfigMap gateway-static-keys"
  note "created ConfigMap gateway-static-keys with an empty operator list (the stack's own keys are on the list in 10-planes.yaml)"
}
