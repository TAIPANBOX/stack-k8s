#!/usr/bin/env bash
#
# Enforces invariant 52 of CLAUDE.md: the gateway's key on the policy plane is a
# `pep`, never a `viewer`, on a fresh cluster and on an existing one that is
# installed again, in all three installers and the hub.
#
# WHY
#
# wardryx 2.0.0 refuses a viewer key on POST /v1/decide and POST /v1/filter-tools
# with a 403. The gateway, the MCP broker and scopyx present the one policy-plane
# key on every governed call, and the gateway and the broker fail closed, so a
# viewer entry in stack-keys refuses every governed call the moment the new wardryx
# is rolled out. An existing stack-keys Secret is never rewritten by a re-run, so
# the entry has to be rewritten in place, before `apply -k` rolls the new images.
#
# WHAT THIS CHECKS
#
#   A. THE FRESH SECRET. install.sh, cloud/aws/install-aws.sh and cloud/gcp/install-gcp.sh
#      give the gateway's entry in wardryx_keys the role pep, and none of them gives
#      it viewer. hub/add-site.sh gives a site's entry pep and migrates the viewer
#      entries a hub already holds.
#   B. THE TRANSFORM. The `# wardryx-role:` block is identical in the three
#      installers (a copy that drifts is a finding, not a style choice), and its
#      `wardryx_gateway_role_keys` rewrites the gateway's entry from viewer to pep
#      and nothing else: another entry, an agent list, an org and a key that only
#      begins with the gateway's secret stay as they were.
#   C. THE MIGRATION. Each installer runs that transform on the existing Secret's
#      wardryx_keys and writes the result back with a patch read from STDIN, before
#      its `apply -k`, and no argument of any kubectl or ssh command carries a key.
#   D. THE PINS. The manifests name the releases this change moves them to.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'FAIL: %s\n' "$*"; exit 1; }

INSTALLERS="install.sh cloud/aws/install-aws.sh cloud/gcp/install-gcp.sh"

# ---- A. the fresh Secret -----------------------------------------------------------
for f in $INSTALLERS; do
  grep -qF '$WARDRYX_ADMIN_SECRET:default:admin,$WARDRYX_GATEWAY_SECRET:default:pep' "$f" \
    || fail "$f does not mint the gateway's wardryx_keys entry as pep"
  if grep -q 'WARDRYX_GATEWAY_SECRET:default:viewer' "$f"; then
    fail "$f still mints the gateway's wardryx_keys entry as viewer, which wardryx 2.0.0 refuses on /v1/decide"
  fi
done
grep -qF 'NEW_WARDRYX_ENTRY="${WARDRYX_SECRET}:default:pep"' hub/add-site.sh \
  || fail "hub/add-site.sh does not give a site's gateway entry pep"
if grep -q ':default:viewer' hub/add-site.sh; then
  grep -q 'p\[3\] == "viewer"' hub/add-site.sh \
    || fail "hub/add-site.sh writes a viewer entry and does not migrate the viewer entries a hub already holds"
fi

# ---- B. the transform, identical across the installers and lifted for a run -------
block() { sed -n '/^# wardryx-role: begin$/,/^# wardryx-role: end$/p' "$1"; }
first="$(block install.sh)"
[ -n "$first" ] || fail "install.sh has no '# wardryx-role: begin' .. 'end' block, so the migration measured nothing"
for f in cloud/aws/install-aws.sh cloud/gcp/install-gcp.sh; do
  [ "$(block "$f")" = "$first" ] || fail "$f's wardryx-role block is not the one install.sh has, so the three installers would migrate differently"
done
grep -q '^wardryx_gateway_role_keys() {' <<<"$first" \
  || fail "the wardryx-role block defines no wardryx_gateway_role_keys, so the migration measured nothing"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/wardryx-role-k8s.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
printf '%s\n' "$first" >"$scratch/block.sh"

GW="gwsecret0123456789ABCDEFGHIJKLMNOPQRSTUV"
ADM="admsecret0123456789ABCDEFGHIJKLMNOPQRST"
OTH="othsecret0123456789ABCDEFGHIJKLMNOPQRS"

# run GW KEYS: the transform's output for a gateway secret and a wardryx_keys spec,
# both on stdin as the installers pass them
run() {
  printf '%s\n%s\n' "$1" "$2" | env -i PATH="$PATH" bash -c '
    set -euo pipefail
    . "$1"
    wardryx_gateway_role_keys' _ "$scratch/block.sh"
}

expect() { # LABEL GOT WANT
  [ "$2" = "$3" ] || fail "$1: got '$2', want '$3'"
}
expect "viewer becomes pep" "$(run "$GW" "$ADM:default:admin,$GW:default:viewer")" "$ADM:default:admin,$GW:default:pep"
expect "an agent list is kept" "$(run "$GW" "$GW:default:viewer:agent://acme.example/runner")" "$GW:default:pep:agent://acme.example/runner"
expect "another viewer is untouched" "$(run "$GW" "$GW:default:viewer,$OTH:acme:viewer")" "$GW:default:pep,$OTH:acme:viewer"
expect "a key that only begins with the secret is untouched" "$(run "$GW" "${GW}X:default:viewer,$GW:default:viewer")" "${GW}X:default:viewer,$GW:default:pep"
expect "no gateway entry changes nothing" "$(run "$GW" "$ADM:default:admin,$OTH:default:viewer")" "$ADM:default:admin,$OTH:default:viewer"
expect "a pep entry is left as it is" "$(run "$GW" "$ADM:default:admin,$GW:default:pep")" "$ADM:default:admin,$GW:default:pep"

# ---- C. the migration in each installer -------------------------------------------
for f in $INSTALLERS; do
  n_call="$(grep -n 'wardryx_gateway_role_keys)"$' "$f" | head -n 1 | cut -d: -f1 || true)"
  [ -n "$n_call" ] || fail "$f never runs the migration on an existing stack-keys Secret"
  n_apply="$(grep -n 'apply -k manifests/' "$f" | grep -v '^[0-9]*:[[:space:]]*#' | head -n 1 | cut -d: -f1 || true)"
  [ -n "$n_apply" ] && [ "$n_call" -lt "$n_apply" ] \
    || fail "$f runs the migration at line $n_call, after the planes are applied at line ${n_apply:-?}"
  grep -qF -- '--type merge --patch-file /dev/stdin' "$f" \
    || fail "$f does not write the migrated wardryx_keys with a patch read from stdin"
  if grep -nE 'k_ ".*(WARDRYX_KEYS_NEW|WARDRYX_GW_PLAIN|WARDRYX_KEYS_PLAIN)' "$f" >/dev/null; then
    fail "$f puts a key on a command line: $(grep -nE 'k_ ".*(WARDRYX_KEYS_NEW|WARDRYX_GW_PLAIN|WARDRYX_KEYS_PLAIN)' "$f" | head -n 1 | cut -c1-120)"
  fi
done
n_add="$(grep -n 'NEW_WARDRYX_ENTRY' hub/add-site.sh | head -n 1 | cut -d: -f1 || true)"
n_mig="$(grep -n 'MIGRATED_WARDRYX=' hub/add-site.sh | head -n 1 | cut -d: -f1 || true)"
[ -n "$n_mig" ] && [ "$n_mig" -lt "$(grep -n 'APPENDED_WARDRYX=' hub/add-site.sh | head -n 1 | cut -d: -f1)" ] \
  || fail "hub/add-site.sh appends to wardryx_keys without migrating the viewer entries first"
grep -q "printf '%s' \"\$WARDRYX_KEYS\" | awk" hub/add-site.sh \
  || fail "hub/add-site.sh migrates wardryx_keys with an awk that does not read stdin"

# ---- D. the pins the key moves with -------------------------------------------------
grep -q 'image: ghcr.io/taipanbox/wardryx:v2.4.1' manifests/10-planes.yaml \
  || fail "manifests/10-planes.yaml does not pin wardryx v2.4.1"
for old in 'wardryx:v1.5.0' 'wardryx:v2.0.0' 'tokenfuse:v1.14.0' 'tokenfuse:v1.15.0' 'costcrew:v0.6.0' 'vouchryx:v0.2.0' 'vouchryx:v0.3.0'; do
  if git grep -q -- "$old" -- manifests; then
    fail "manifests still name $old: $(git grep -n -- "$old" -- manifests | head -n 1 | cut -c1-120)"
  fi
done

echo "OK: the gateway's policy-plane key is a pep in all three installers and the hub; an existing stack-keys is migrated from viewer to pep on stdin before the planes are applied; the manifests pin wardryx v2.4.1."
