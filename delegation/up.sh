#!/usr/bin/env bash
# Bring up the delegation plane (manifests/54-delegation.yaml): vouchryx, a
# token service that lets the gateway verify a PROVED delegation chain
# instead of trusting a claimed one. GOTCHAS.md entry 105 is the gap this
# closes.
#
#   ./delegation/up.sh --issuer https://idp.example.com \
#                       --audience http://vouchryx:4310 \
#                       --jwks-file /path/to/idp-jwks.json
#
# All three flags are required, and checked BEFORE anything is applied to the
# cluster (CLAUDE.md invariant 24): there is no defensible default trusted
# issuer, the same reason 00-base.yaml ships TRAILRYX_TRUST_DOMAIN as a
# placeholder rather than guessing one (CLAUDE.md invariant 14). --audience
# is the `aud` your own IdP puts on the subject/actor tokens it issues for use
# with THIS vouchryx instance; if you have not decided one yet, its own
# address (http://vouchryx:4310, once this script has applied the manifest)
# is a reasonable choice, but this script does not invent it for you.
#
# vouchryx itself is in the default install and runs agents-only (CLAUDE.md invariant 24, amended
# 2026-10-19). This script is the opt-in step that TRUSTS an upstream identity provider as one more issuer
# of subject tokens, and it is the only path that does. The agent tokens of invariant 54 do not need it.
#
# Idempotent (CLAUDE.md invariant 4): the signing key, the revoke key and the first agent are minted once
# by lib/vouchryx-mint.sh and REUSED on every later run. The revocation store lives on its own
# PersistentVolumeClaim, so a revocation survives a pod restart across runs of this script too.
#
# KUBECONFIG comes from the environment, same as every other script here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-agent-stack}"

ISSUER=""
AUDIENCE=""
JWKS_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --issuer) ISSUER="$2"; shift 2 ;;
    --audience) AUDIENCE="$2"; shift 2 ;;
    --jwks-file) JWKS_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

# ---- requirement 2: refuse before applying anything, naming what is missing
missing=""
[ -n "$ISSUER" ]    || missing="$missing --issuer"
[ -n "$AUDIENCE" ]  || missing="$missing --audience"
[ -n "$JWKS_FILE" ] || missing="$missing --jwks-file"
if [ -n "$missing" ]; then
  die "missing:$missing

   Delegation needs a trusted upstream issuer before this script applies
   anything: there is no default trusted issuer this repository could ship,
   the same reason TRAILRYX_TRUST_DOMAIN ships as a placeholder rather than a
   guess (CLAUDE.md invariant 14). Nothing was applied to the cluster."
fi

[ -f "$JWKS_FILE" ] || die "--jwks-file $JWKS_FILE does not exist. Nothing was applied to the cluster."
python3 -c "
import json, sys
try:
    doc = json.load(open('$JWKS_FILE'))
except Exception as e:
    print('--jwks-file $JWKS_FILE is not valid JSON: ' + str(e))
    sys.exit(1)
keys = doc.get('keys') if isinstance(doc, dict) else None
if not keys:
    print('--jwks-file $JWKS_FILE has no non-empty \"keys\" array, so it is not a JWKS.')
    sys.exit(1)
" || die "nothing was applied to the cluster."

command -v kubectl >/dev/null || die "kubectl not found"
kubectl version -o json >/dev/null 2>&1 || die "no cluster: set KUBECONFIG"
command -v openssl >/dev/null || die "openssl not found (needed to mint the signing key)"

k() { kubectl -n "$NS" "$@"; }

# ---- the operator's trusted issuer, as a ConfigMap: two plain strings and
# the JWKS itself. Applied every run, not "if missing", the same as
# hub/up.sh's own ConfigMap patch: this is DATA the operator supplies, not a
# credential this script mints, so there is nothing here to protect by
# refusing to overwrite it. A JWKS is a set of PUBLIC keys, which is why this
# is a ConfigMap and not a Secret.
k get deployment vouchryx >/dev/null 2>&1 || die "vouchryx is not deployed in $NS: deploy the stack first (it is in the default install). Nothing was applied to the cluster."
say "writing the trusted issuer into vouchryx-trusted-issuers"
TRUSTED_ISSUERS_LINE="${ISSUER}|${AUDIENCE}|/etc/vouchryx/trusted/idp.jwks.json"
# The namespace must already exist: this turns a plane on in an installed
# stack, it does not install one. Never `kubectl apply` a bare Namespace here:
# apply's three-way merge drops every label the install put on it that the
# bare object lacks, Pod Security's `enforce: restricted` first (measured
# 2026-09-27 on forge: security-tests.sh then saw a privileged pod ACCEPTED).
kubectl get namespace "$NS" >/dev/null 2>&1 \
  || die "namespace $NS does not exist: install the stack first. Nothing was applied to the cluster."
k create configmap vouchryx-trusted-issuers \
  --from-literal="issuer=${ISSUER}" \
  --from-literal="audience=${AUDIENCE}" \
  --from-literal="trusted_issuers=${TRUSTED_ISSUERS_LINE}" \
  --from-file="idp.jwks.json=${JWKS_FILE}" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
echo "   issuer=$ISSUER audience=$AUDIENCE"

# ---- the keys and the agent registry: the same objects the default install mints ---------
# vouchryx runs agents-only by default (CLAUDE.md invariant 24, amended). This script adds an upstream
# issuer on top: lib/vouchryx-mint.sh mints the keys and the first agent only when they are absent.
say "vouchryx keys and the registry (kept when they exist)"
k_() { eval "kubectl $*"; }
. "$ROOT/lib/secret-doc.sh"
. "$ROOT/lib/vouchryx-mint.sh" || die "no lib/vouchryx-mint.sh in $ROOT"
note() { printf '   %s\n' "$*"; }
vouchryx_mint_settle

# vouchryx reads its trusted issuers at start, so it is rolled to read the ConfigMap written above.
say "rolling vouchryx to read the trusted issuer"
k rollout restart deployment/vouchryx >/dev/null
k rollout status deployment/vouchryx --timeout=120s \
  || die "vouchryx did not roll out. kubectl -n $NS describe pod -l app=vouchryx"

# The gateway needs no change: it verifies agent tokens against vouchryx's own key set by default, and an
# upstream issuer does not change that key set (invariant 54). Only the console's revoke command is patched.
say "patching genaryx-console (so it can revoke from its own delegation_revoke command)"
k patch deployment genaryx-console --patch-file "$ROOT/manifests/54-delegation-console-patch.yaml" >/dev/null
k rollout status deployment/genaryx-console --timeout=120s \
  || die "genaryx-console did not roll out after the patch. kubectl -n $NS describe pod -l app=genaryx-console"

say "up"
cat <<EOF
   vouchryx:          http://vouchryx:4310 (in-cluster only), trusting one upstream issuer
   gateway door:      agent tokens required by default (invariant 54); unchanged by this script
   revocation poll:   every 12 s (set in 10-planes.yaml and 52-tokenfuse-mcp-broker.yaml)

   Revoke a subject (bearer: the revoke_key inside the vouchryx-keys Secret,
   never printed by this script):

     kubectl -n $NS exec deploy/genaryx-console -- true  # or use the console's
       # own delegation_revoke command, wired above, or:
     REVOKE_KEY=\$(kubectl -n $NS get secret vouchryx-keys -o jsonpath='{.data.revoke_key}' | base64 -d)
     kubectl -n $NS port-forward svc/vouchryx 14310:4310 &
     curl -X POST http://127.0.0.1:14310/v1/revoke \\
       -H "Authorization: Bearer \$REVOKE_KEY" \\
       -d '{"subject":"agent://acme.example/example","actor":"you","reason":"testing"}'

   Next: ./delegation/down.sh to take it back down, or re-run this script
   with the same flags, which reuses the keys it already minted.
EOF
