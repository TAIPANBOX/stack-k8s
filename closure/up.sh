#!/usr/bin/env bash
# Turn on closing a retained reservation (tokenfuse D8): one secret, shared by
# the gateway, which verifies closure tokens, and the console, which mints
# them after a passkey assertion. A retained reservation is a call the
# provider may have billed that the gateway could not settle; a person closes
# it with evidence.
#
#   ./closure/up.sh
#
# Off by default: `kubectl apply -k manifests/` never applies either patch
# beside this script. This script is the only path that turns closing on.
#
# Idempotent (CLAUDE.md invariant 4): the secret is minted once into the
# closure-keys Secret and REUSED on every later run, never regenerated. It is
# hex with no trailing newline, because the console trims whitespace from the
# file it reads and the gateway reads its variable as given.
#
# It takes effect only with a tokenfuse image that serves
# POST /v1/retained/close and a console image with the close command; an
# older image ignores both settings.
#
# KUBECONFIG comes from the environment, same as every other script here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-agent-stack}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,23p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"
kubectl version -o json >/dev/null 2>&1 || die "no cluster: set KUBECONFIG"
k() { kubectl -n "$NS" "$@"; }

# The namespace must already exist: this turns a feature on in an installed
# stack, it does not install one, and it never applies a Namespace object
# (GOTCHAS 114).
kubectl get namespace "$NS" >/dev/null 2>&1 \
  || die "namespace $NS does not exist: install the stack first. Nothing was applied to the cluster."
k get deployment tokenfuse-gateway >/dev/null 2>&1 \
  || die "no tokenfuse-gateway Deployment in $NS. Nothing was applied to the cluster."
k get deployment genaryx-console >/dev/null 2>&1 \
  || die "no genaryx-console Deployment in $NS. Nothing was applied to the cluster."

# ---- the secret, minted once and reused --------------------------------------
if k get secret closure-keys >/dev/null 2>&1; then
  say "closure-keys already exists, reusing the closure secret"
else
  say "minting the closure secret (generated here, never committed, never printed)"
  CLOSURE_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  [ "${#CLOSURE_SECRET}" -eq 64 ] || die "could not read 32 bytes from /dev/urandom"
  # on stdin as a manifest (CLAUDE.md invariant 60): the value is on no command line
  . "$ROOT/lib/secret-doc.sh"
  secret_doc closure-keys "secret=$CLOSURE_SECRET" | k create -f - >/dev/null
  unset CLOSURE_SECRET
  echo "   created secret closure-keys (secret). Its value is not printed above."
fi

# ---- the two patches ---------------------------------------------------------
say "giving tokenfuse-gateway the closure secret"
k patch deployment tokenfuse-gateway \
  --patch-file "$ROOT/manifests/57-closure-gateway-patch.yaml" >/dev/null
k rollout status deployment/tokenfuse-gateway --timeout=120s \
  || die "tokenfuse-gateway did not roll out. kubectl -n $NS describe deployment tokenfuse-gateway"

say "giving genaryx-console the file holding the same secret"
k patch deployment genaryx-console \
  --patch-file "$ROOT/manifests/57-closure-console-patch.yaml" >/dev/null
k rollout status deployment/genaryx-console --timeout=180s \
  || die "genaryx-console did not roll out. kubectl -n $NS describe deployment genaryx-console"

say "closing a retained reservation is on"
echo "   The gateway verifies closure tokens with the closure-keys Secret, and the"
echo "   console mints them from the same bytes after a passkey assertion."
echo "   To turn it off: ./closure/down.sh"
