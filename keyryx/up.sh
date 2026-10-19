#!/usr/bin/env bash
# Turn on Keyryx on an installed cluster: key custody and its independent
# witness (keyryx/manifests/59-keyryx.yaml), and wardryx's approval signer
# through Keyryx (keyryx/wardryx-patch.yaml, wardryx v2.2.0).
#
#   KUBECONFIG=./kubeconfig.yaml ./keyryx/up.sh
#
# Off by default: `kubectl apply -k manifests/` never applies either file. This
# is the only path that turns Keyryx on, as closure/up.sh and delegation/up.sh are.
#
# Idempotent (CLAUDE.md invariant 4): the two root keys and the wardryx client
# key are minted once and REUSED on every later run, never regenerated. A root
# key that changed would orphan every key Keyryx had wrapped under it, which is
# why this script refuses to mint over an existing one. No key is printed: the
# values go from /dev/urandom through a pipe into kubectl, and nothing echoes them.
#
# Not wired here, and why (see the L2 report): vouchryx and tokenfuse, whose
# Keyryx releases were not yet published when this was written; trailryx, whose
# next release is later. Their pins stay where they are until those releases.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-agent-stack}"

command -v kubectl >/dev/null || { echo "keyryx/up.sh: kubectl is needed" >&2; exit 1; }
command -v openssl >/dev/null || { echo "keyryx/up.sh: openssl is needed" >&2; exit 1; }

# A 32-byte random value as 64 hex characters, no newline: the form Keyryx
# reads for a root key (internal/rootkey) and a bearer key alike. The read is
# bounded by head -c (CLAUDE.md invariant 41).
random_hex() {
  head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n'
}

# A root key Secret is minted once. Its value is never read back, so a second
# run cannot print or change it.
mint_root() {
  local name="$1"
  if kubectl -n "$NS" get secret "$name" >/dev/null 2>&1; then
    echo "kept   $name (already exists)"
    return 0
  fi
  random_hex | kubectl -n "$NS" create secret generic "$name" --from-file=root.key=/dev/stdin >/dev/null
  echo "minted $name"
}

mint_root keyryx-root
mint_root keyryx-witness-root

# wardryx's bearer key: minted once, read back on later runs so the policy's
# digest stays true of what wardryx presents.
if kubectl -n "$NS" get secret keyryx-wardryx-client >/dev/null 2>&1; then
  cred="$(kubectl -n "$NS" get secret keyryx-wardryx-client -o jsonpath='{.data.credential}' | base64 --decode)"
  echo "kept   keyryx-wardryx-client (already exists)"
else
  cred="$(random_hex)"
  printf '%s' "$cred" | kubectl -n "$NS" create secret generic keyryx-wardryx-client --from-file=credential=/dev/stdin >/dev/null
  echo "minted keyryx-wardryx-client"
fi
digest="$(printf '%s' "$cred" | openssl dgst -sha256 -r | cut -d' ' -f1)"
cred=""

# The policy names the digest, never the key. Rendered to a temp file and
# applied as a ConfigMap, so a re-run replaces the same object.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sed "s/@WARDRYX_DIGEST@/$digest/" "$HERE/policy.json.tmpl" >"$tmp/policy.json"
kubectl -n "$NS" create configmap keyryx-policy --from-file=policy.json="$tmp/policy.json" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
echo "applied keyryx-policy"

kubectl -n "$NS" apply -f "$HERE/manifests/59-keyryx.yaml"
kubectl -n "$NS" rollout status deployment/keyryx-custody --timeout=300s
kubectl -n "$NS" rollout status deployment/keyryx-witness --timeout=300s

# The deadline for v2 approval tokens minted before the switch (wardryx v2.2.x). An existing value is
# kept, so a re-run does not extend the window; a first run allows one hour from now.
v2until="$(kubectl -n "$NS" get deployment wardryx -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="WARDRYX_APPROVAL_V2_UNTIL")].value}' 2>/dev/null || true)"
if [ -z "$v2until" ]; then
  v2until="$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
fi
sed "s/@WARDRYX_APPROVAL_V2_UNTIL@/$v2until/" "$HERE/wardryx-patch.yaml" >"$tmp/wardryx-patch.yaml"
kubectl -n "$NS" patch deployment wardryx --type strategic --patch-file "$tmp/wardryx-patch.yaml"
kubectl -n "$NS" rollout status deployment/wardryx --timeout=300s

echo "Keyryx is on. Custody: keyryx-custody:4340, witness: keyryx-witness:4341."
echo "wardryx signs approval tokens through Keyryx. keyryx/down.sh reverses the wiring and keeps every key."
