#!/usr/bin/env bash
# Mint a new site's two keys and hand them the settings to reach this hub.
#
#   ./hub/add-site.sh SITE_NAME
#
# Needs manifests/53-hub-entry.yaml already up (./hub/up.sh) and tokenfuse-cloud
# running v1.2.0 or newer: that release is what names a site from its own Cloud
# key and carries the least-privilege `ingest` role (tokenfuse invariant 65).
# An older Cloud rejects a 4-segment key and has no `ingest` role at all, so
# a site added against one would either fail outright or, worse, need an
# admin-scoped key just to phone home.
#
# KUBECONFIG comes from the environment, same as every other script here.
#
# Idempotent in the sense that matters here (CLAUDE.md invariant 4): running
# it twice for the SAME site name refuses the second time rather than minting
# a second credential or dropping the first. It reads the existing key lists,
# appends, and writes back; it never regenerates or drops a key that is
# already there.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
NS="${NS:-agent-stack}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $0 SITE_NAME"
SITE="$1"

command -v kubectl >/dev/null || die "kubectl not found"
kubectl version -o json >/dev/null 2>&1 || die "no cluster: set KUBECONFIG"

# ---- the name, checked BEFORE anything is minted ---------------------------
# tokenfuse's own grammar (crates/cloud/src/keys.rs, is_valid_site_name):
# ^[a-z0-9][a-z0-9._-]{0,62}$. A name this script accepted and the Cloud then
# refused would still have spent one working credential on nothing: better to
# refuse here, for free.
case "$SITE" in
  [a-z0-9]*) ;;
  *) die "'$SITE' does not start with a lowercase letter or digit (tokenfuse's own rule: ^[a-z0-9][a-z0-9._-]{0,62}\$)" ;;
esac
if printf '%s' "$SITE" | grep -qE '[^a-z0-9._-]'; then
  die "'$SITE' has a character outside [a-z0-9._-] (tokenfuse's own rule: ^[a-z0-9][a-z0-9._-]{0,62}\$)"
fi
[ "${#SITE}" -le 63 ] || die "'$SITE' is ${#SITE} characters, over the 63-character limit"

# ---- the Cloud's version -----------------------------------------------------
IMAGE="$(kubectl -n "$NS" get deployment tokenfuse-cloud \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="cloud")].image}' 2>/dev/null || true)"
[ -n "$IMAGE" ] || die "no tokenfuse-cloud Deployment in $NS. Is the stack up? kubectl apply -k manifests/"
TAG="${IMAGE##*:}"
case "$TAG" in
  v*) VER="${TAG#v}" ;;
  *) die "tokenfuse-cloud's image ($IMAGE) has no vX.Y.Z tag this script can read" ;;
esac
python3 -c "
import sys
want = (1, 2, 0)
got = tuple(int(p) for p in '$VER'.split('.')[:3])
sys.exit(0 if got >= want else 1)
" || die "tokenfuse-cloud is running $TAG, older than v1.2.0.
   A Cloud older than that rejects a 4-segment key (org:role:site) and has no
   ingest role, so a site key minted against it would not work as intended.
   Pin manifests/10-planes.yaml to tokenfuse-control-plane:v1.2.0 or newer,
   apply it, and wait for the rollout before running this again."
echo "   tokenfuse-cloud is $TAG, at or above v1.2.0"

# ---- the hub's own address ---------------------------------------------------
HUB_HOST="$(kubectl -n "$NS" get configmap stack-hub-entry -o jsonpath='{.data.host}' 2>/dev/null || true)"
if [ -z "$HUB_HOST" ] || [ "$HUB_HOST" = "unset.invalid" ]; then
  die "the hub has no public address yet. Run ./hub/up.sh first."
fi

# ---- base64, either flavour --------------------------------------------------
# kubectl always stores Secret data as base64. GNU coreutils decodes with
# -d; the base64 that ships with macOS wants -D. Tried in that order because
# GNU is what most clusters' own tooling assumes, and a hard failure here is
# obvious rather than a silently empty decode.
b64dec() { base64 -d 2>/dev/null || base64 -D; }

# ---- read the existing key lists, and refuse if the site is already there --
CLOUD_KEYS_B64="$(kubectl -n "$NS" get secret stack-keys -o jsonpath='{.data.cloud_keys}' 2>/dev/null || true)"
WARDRYX_KEYS_B64="$(kubectl -n "$NS" get secret stack-keys -o jsonpath='{.data.wardryx_keys}' 2>/dev/null || true)"
[ -n "$CLOUD_KEYS_B64" ] && [ -n "$WARDRYX_KEYS_B64" ] \
  || die "stack-keys is missing cloud_keys or wardryx_keys. Is the stack fully installed?"

CLOUD_KEYS="$(printf '%s' "$CLOUD_KEYS_B64" | b64dec)"
WARDRYX_KEYS="$(printf '%s' "$WARDRYX_KEYS_B64" | b64dec)"

if printf '%s' "$CLOUD_KEYS" | tr ',' '\n' | grep -qE "^[^:]+:default:ingest:${SITE}\$"; then
  die "site '$SITE' already has a Cloud key in stack-keys. Refusing to mint a
   second one: this script never regenerates or drops an existing key. If the
   site lost its credentials, that is an operator decision (rotate by hand),
   not something this script does on its own initiative."
fi

# ---- mint the two keys --------------------------------------------------------
say "minting keys for site '$SITE'"
CLOUD_SECRET="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
WARDRYX_SECRET="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# key:org:role:site (tokenfuse's own spec, crates/cloud/src/keys.rs), the
# least-privilege `ingest` role: it may push telemetry and read what a
# viewer reads, and nothing else (invariant 65). "default" is the same org
# every other key in this stack-keys Secret already uses; there is one
# tokenfuse-cloud per hub, not one per org.
NEW_CLOUD_ENTRY="${CLOUD_SECRET}:default:ingest:${SITE}"
# key:tenant:role triples (wardryx's own spec, 10-planes.yaml), viewer: a
# site's gateway needs to ask /v1/decide, not to write policy.
NEW_WARDRYX_ENTRY="${WARDRYX_SECRET}:default:viewer"

APPENDED_CLOUD="${CLOUD_KEYS},${NEW_CLOUD_ENTRY}"
APPENDED_WARDRYX="${WARDRYX_KEYS},${NEW_WARDRYX_ENTRY}"

say "appending to stack-keys (existing keys untouched)"
# The patch travels on stdin, never as an argument: an argument is in `ps` for
# every user on this machine for as long as kubectl runs, and it would carry
# every key in the stack, not only the new one. The values go to python the
# same way, through the environment of that one process.
APPENDED_CLOUD="$APPENDED_CLOUD" APPENDED_WARDRYX="$APPENDED_WARDRYX" python3 -c "
import json, os
print(json.dumps({'stringData': {
    'cloud_keys': os.environ['APPENDED_CLOUD'],
    'wardryx_keys': os.environ['APPENDED_WARDRYX'],
}}))
" | kubectl -n "$NS" patch secret stack-keys --type merge --patch-file /dev/stdin >/dev/null
echo "   stack-keys: cloud_keys and wardryx_keys each gained one entry"

say "restarting tokenfuse-cloud and wardryx so the new keys take effect"
# Env vars sourced from a Secret are read once at container start; a Secret
# patch alone changes nothing running until the pod restarts.
kubectl -n "$NS" rollout restart deployment/tokenfuse-cloud deployment/wardryx >/dev/null
kubectl -n "$NS" rollout status deployment/tokenfuse-cloud --timeout=120s \
  || die "tokenfuse-cloud did not roll out after the key change. kubectl -n $NS describe pod -l app=tokenfuse-cloud"
kubectl -n "$NS" rollout status deployment/wardryx --timeout=120s \
  || die "wardryx did not roll out after the key change. kubectl -n $NS describe pod -l app=wardryx"

# ---- the site's own settings file -------------------------------------------
OUT="$HERE/site-${SITE}.env"
(
  umask 077
  cat > "$OUT" <<EOF
# $SITE's settings for reaching the hub at $HUB_HOST. Generated by
# hub/add-site.sh, $(date -u +%Y-%m-%dT%H:%M:%SZ). Keep this file: it is the
# only copy of these two secrets outside stack-keys on the hub's own cluster.
TOKENFUSE_CLOUD_URL=https://cloud.${HUB_HOST}
TOKENFUSE_CLOUD_KEY=${CLOUD_SECRET}
TOKENFUSE_WARDRYX_URL=https://wardryx.${HUB_HOST}
TOKENFUSE_WARDRYX_KEY=${WARDRYX_SECRET}
EOF
  chmod 0600 "$OUT"
)

say "done"
echo "   $OUT (mode 0600)"
echo "   Copy it to the site and set those four variables on its gateway."
echo "   Nothing above this line printed either secret."
