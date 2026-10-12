#!/usr/bin/env bash
# Turn off closing a retained reservation: reverse the two patches
# closure/up.sh applied, each with its own `$patch: delete` counterpart.
#
#   ./closure/down.sh                    # keeps the closure-keys Secret
#   ./closure/down.sh --delete-secrets   # removes it too
#
# Taking closing off is not the same decision as forgetting the secret: a
# later ./closure/up.sh reuses it. `kubectl apply -k manifests/` cannot undo a
# patch, for the reason manifests/54-delegation-gateway-unpatch.yaml names.
#
# KUBECONFIG comes from the environment, same as every other script here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-agent-stack}"
DELETE_SECRETS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --delete-secrets) DELETE_SECRETS=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
k() { kubectl -n "$NS" "$@"; }

say "restoring tokenfuse-gateway to its default env"
if k get deployment tokenfuse-gateway >/dev/null 2>&1; then
  k patch deployment tokenfuse-gateway --type strategic \
    --patch-file "$ROOT/manifests/57-closure-gateway-unpatch.yaml" >/dev/null
  k rollout status deployment/tokenfuse-gateway --timeout=120s || true
fi

say "restoring genaryx-console to its default env"
if k get deployment genaryx-console >/dev/null 2>&1; then
  k patch deployment genaryx-console --type strategic \
    --patch-file "$ROOT/manifests/57-closure-console-unpatch.yaml" >/dev/null
  k rollout status deployment/genaryx-console --timeout=180s || true
fi

if [ "$DELETE_SECRETS" = 1 ]; then
  say "removing closure-keys (--delete-secrets)"
  k delete secret closure-keys --ignore-not-found=true >/dev/null
else
  cat <<EOF

  Left as it is, on purpose:
    secret closure-keys   (the closure secret)

  Re-running ./closure/up.sh reuses it. Pass --delete-secrets to remove it here.
EOF
fi
