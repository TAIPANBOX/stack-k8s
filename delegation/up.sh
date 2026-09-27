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
# Off by default: `kubectl apply -k manifests/` never applies
# manifests/54-delegation.yaml or either patch beside it. This script is the
# only path that turns delegation on.
#
# Idempotent (CLAUDE.md invariant 4): the signing key and the revoke key are
# generated once, into the vouchryx-keys Secret, and REUSED on every later
# run, never regenerated or dropped (the same stance hub/add-site.sh takes on
# a site's keys). The revocation store lives on its own PersistentVolumeClaim,
# so a revocation survives a pod restart across runs of this script too.
#
# KUBECONFIG comes from the environment, same as every other script here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-agent-stack}"

ISSUER=""
AUDIENCE=""
JWKS_FILE=""
REVOCATIONS_INTERVAL_MS="12000"

while [ $# -gt 0 ]; do
  case "$1" in
    --issuer) ISSUER="$2"; shift 2 ;;
    --audience) AUDIENCE="$2"; shift 2 ;;
    --jwks-file) JWKS_FILE="$2"; shift 2 ;;
    --revocations-interval-ms) REVOCATIONS_INTERVAL_MS="$2"; shift 2 ;;
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
say "writing the trusted issuer into vouchryx-trusted-issuers"
TRUSTED_ISSUERS_LINE="${ISSUER}|${AUDIENCE}|/etc/vouchryx/trusted/idp.jwks.json"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
k create configmap vouchryx-trusted-issuers \
  --from-literal="issuer=${ISSUER}" \
  --from-literal="audience=${AUDIENCE}" \
  --from-literal="trusted_issuers=${TRUSTED_ISSUERS_LINE}" \
  --from-file="idp.jwks.json=${JWKS_FILE}" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
echo "   issuer=$ISSUER audience=$AUDIENCE"

# ---- the signing key and the revoke key, minted once and reused -----------
# Requirement 3: never regenerated or dropped once they exist, the same
# stance hub/add-site.sh takes on a site's keys.
if k get secret vouchryx-keys >/dev/null 2>&1; then
  say "vouchryx-keys already exists, reusing the signing key and revoke key"
else
  say "minting the signing key and the revoke key (generated here, never committed)"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  ( umask 077
    openssl ecparam -genkey -name prime256v1 -noout -out "$TMP/signing.pem" 2>/dev/null
  ) || die "could not mint the EC P-256 signing key"
  REVOKE_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  k create secret generic vouchryx-keys \
    --from-file="signing.pem=$TMP/signing.pem" \
    --from-literal="revoke_key=$REVOKE_KEY" >/dev/null
  rm -rf "$TMP"
  trap - EXIT
  echo "   created secret vouchryx-keys (signing.pem, revoke_key). Neither value is printed above."
fi

# ---- apply the plane itself -------------------------------------------------
say "applying manifests/54-delegation.yaml"
kubectl apply -f "$ROOT/manifests/54-delegation.yaml" 2>&1 | sed 's/^/   /'

say "waiting for vouchryx to roll out"
k rollout status deployment/vouchryx --timeout=120s \
  || die "vouchryx did not roll out. kubectl -n $NS describe pod -l app=vouchryx"

# ---- fetch vouchryx's OWN served JWKS, the trap this manifest's header
# names: a JWKS minted any other way does not carry the RFC 7638 thumbprint
# vouchryx actually signs with, and every token is refused BadToken. Reached
# by port-forward: the NetworkPolicy above narrows the Service to the gateway
# and the console, and port-forward attaches to the pod's network namespace
# directly rather than crossing it, the same reason hub/up.sh reads the
# hub-ingress pod's own logs instead of asking through its Service.
say "fetching vouchryx's own JWKS (its /.well-known/jwks.json, not the operator's)"
PF_LOG="$(mktemp)"
kubectl -n "$NS" port-forward svc/vouchryx 14310:4310 >"$PF_LOG" 2>&1 &
PF_PID=$!
# Under `set -e`, a failing command INSIDE an EXIT trap overrides the
# script's own exit status, which is what happened here the first time this
# ran on forge: the script printed "up" and every step had already succeeded,
# but `kill "$PF_PID"` found the port-forward already reaped (the main flow
# above kills it explicitly) and the whole run reported exit 1 anyway. Each
# cleanup command needs its own `|| true`, not a shared one after the `;`.
trap 'kill "$PF_PID" 2>/dev/null || true; rm -f "$PF_LOG" "$JWKS_TMP" 2>/dev/null || true' EXIT
JWKS_TMP="$(mktemp)"
ok=0
for _ in $(seq 1 30); do
  if curl -fsS -o "$JWKS_TMP" http://127.0.0.1:14310/.well-known/jwks.json 2>/dev/null; then
    ok=1
    break
  fi
  sleep 1
done
kill "$PF_PID" 2>/dev/null || true
wait "$PF_PID" 2>/dev/null || true
[ "$ok" = 1 ] || die "could not reach vouchryx's /.well-known/jwks.json through a port-forward after 30s.
   $(cat "$PF_LOG" 2>/dev/null)"
python3 -c "
import json, sys
doc = json.load(open('$JWKS_TMP'))
keys = doc.get('keys') if isinstance(doc, dict) else None
if not keys:
    print('vouchryx served a JWKS with no keys, which cannot be right for a Ready pod.')
    sys.exit(1)
" || die "vouchryx's own JWKS looked wrong; nothing was patched onto the gateway."
kubectl -n "$NS" create configmap vouchryx-jwks --from-file="jwks.json=$JWKS_TMP" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
echo "   stored in the vouchryx-jwks ConfigMap"

# ---- point the gateway and the console at it -------------------------------
say "patching tokenfuse-gateway (delegation door on)"
k patch deployment tokenfuse-gateway --patch-file "$ROOT/manifests/54-delegation-gateway-patch.yaml" >/dev/null
k rollout status deployment/tokenfuse-gateway --timeout=120s \
  || die "tokenfuse-gateway did not roll out after the patch. kubectl -n $NS describe pod -l app=tokenfuse-gateway"

say "patching genaryx-console (so it can revoke from its own delegation_revoke command)"
k patch deployment genaryx-console --patch-file "$ROOT/manifests/54-delegation-console-patch.yaml" >/dev/null
k rollout status deployment/genaryx-console --timeout=120s \
  || die "genaryx-console did not roll out after the patch. kubectl -n $NS describe pod -l app=genaryx-console"

say "up"
cat <<EOF
   vouchryx:          http://vouchryx:4310 (in-cluster only)
   gateway door:      ON, delegation chains reaching the PDP are verified
   revocation poll:   every ${REVOCATIONS_INTERVAL_MS}ms

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
