# Keyryx, installed by default: custody and its witness, wardryx's approval signer, and the record signer
# (trailryx-node seals through custody). Sourced by deploy.sh, cloud/gcp/deploy-gcp.sh, cloud/aws/deploy-aws.sh
# and keyryx/up.sh, not run. CLAUDE.md invariant 69.
#
# `@decided 2026-10-19` (paraphrased): Keyryx is part of every install. Its wiring is off only when the
# operator names --without-keyryx, which is the weaker setting: approvals are then signed without custody and
# the record is sealed without a signature from it.
#
# Needs in scope, from the caller: k_ (its kubectl runner, given ONE argument string), die(), and ROOT (the
# repository root). Everything reaches the cluster on stdin: the policy, the manifests and the patches are
# read here and piped, so no file is copied onto a node. The keys never reach a command line: they are made
# from /dev/urandom into a pipe, or read back from their Secret into a shell variable.
#
# WHAT keyryx_install_settle DOES, in order:
#   the two root keys (keyryx-root, keyryx-witness-root): minted once, kept on every later run
#   the two bearers (keyryx-wardryx-client, keyryx-trailryx-client): minted once; the policy names their digests
#   the policy (ConfigMap keyryx-policy): the keys trailryx-root and wardryx-approval, and the two consumers
#   keyryx/manifests/59 (custody and witness) and 60 (the consumer egress), applied, custody and witness rolled out
#   wardryx: keyryx/wardryx-patch.yaml, strategic, after apply, rolled out (its image is the same pin)
#   record-seal: keyryx/record-seal-patch.yaml, strategic, after apply
#
# WHAT keyryx_remove_settle DOES: the same two patches in reverse (wardryx-unpatch.yaml, record-seal-unpatch.yaml).
# It keeps custody, the witness, every key and the policy, because apply prunes nothing and no key is deleted on
# this repository's own initiative.

KEYRYX_NS="${KEYRYX_NS:-agent-stack}"

keyryx_random_hex() {
  head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n'
}

# keyryx_mint_root NAME: a root key Secret, minted once; its value is never read back.
keyryx_mint_root() {
  local name="$1"
  if [ -n "$(k_ "-n $KEYRYX_NS get secret $name --ignore-not-found -o name")" ]; then
    printf '   %s: kept (already exists)\n' "$name"
    return 0
  fi
  keyryx_random_hex | k_ "-n $KEYRYX_NS create secret generic $name --from-file=root.key=/dev/stdin" >/dev/null \
    || die "could not mint the Keyryx root key $name"
  printf '   %s: minted\n' "$name"
}

# keyryx_bearer_digest NAME: prints the sha256 digest of a consumer bearer on stdout (the policy names the
# digest, never the bearer). The bearer is minted once and read back on later runs.
keyryx_bearer_digest() {
  local name="$1" cred
  if [ -n "$(k_ "-n $KEYRYX_NS get secret $name --ignore-not-found -o name")" ]; then
    cred="$(k_ "-n $KEYRYX_NS get secret $name -o jsonpath='{.data.credential}'" | base64 --decode)" \
      || die "could not read the consumer credential $name"
    printf '   %s: kept (already exists)\n' "$name" >&2
  else
    cred="$(keyryx_random_hex)"
    printf '%s' "$cred" | k_ "-n $KEYRYX_NS create secret generic $name --from-file=credential=/dev/stdin" >/dev/null \
      || die "could not mint the consumer credential $name"
    printf '   %s: minted\n' "$name" >&2
  fi
  printf '%s' "$cred" | openssl dgst -sha256 -r | cut -d' ' -f1
}

# keyryx_apply_policy WARDRYX_DIGEST TRAILRYX_DIGEST: the custody policy as a ConfigMap, applied from stdin.
keyryx_apply_policy() {
  local wd="$1" td="$2" rendered
  rendered="$(sed -e "s/@WARDRYX_DIGEST@/$wd/" -e "s/@TRAILRYX_DIGEST@/$td/" "$ROOT/keyryx/policy.json.tmpl")"
  {
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: keyryx-policy\n  namespace: %s\ndata:\n  policy.json: |\n' "$KEYRYX_NS"
    printf '%s\n' "$rendered" | sed 's/^/    /'
  } | k_ "-n $KEYRYX_NS apply -f -" >/dev/null || die "could not apply the Keyryx policy"
  printf '   keyryx-policy: applied (trailryx-root and wardryx-approval; two consumers)\n'
}

# keyryx_apply_objects: custody, the witness and the consumer egress, then both rolled out.
keyryx_apply_objects() {
  cat "$ROOT/keyryx/manifests/59-keyryx.yaml" | k_ "-n $KEYRYX_NS apply -f -" >/dev/null \
    || die "could not apply keyryx/manifests/59-keyryx.yaml"
  cat "$ROOT/keyryx/manifests/60-keyryx-consumers.yaml" | k_ "-n $KEYRYX_NS apply -f -" >/dev/null \
    || die "could not apply keyryx/manifests/60-keyryx-consumers.yaml"
  k_ "-n $KEYRYX_NS rollout status deployment/keyryx-custody --timeout=300s" >/dev/null \
    || die "keyryx-custody did not roll out"
  k_ "-n $KEYRYX_NS rollout status deployment/keyryx-witness --timeout=300s" >/dev/null \
    || die "keyryx-witness did not roll out"
  printf '   keyryx-custody and keyryx-witness: rolled out\n'
}

# keyryx_patch_wardryx: wardryx signs its approval tokens through custody. The patch's image is the same pin as
# manifests/10-planes.yaml (checked by scripts/keyryx-is-default.sh), so this step never rolls wardryx back.
keyryx_patch_wardryx() {
  local v2until
  v2until="$(k_ "-n $KEYRYX_NS get deployment wardryx -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"WARDRYX_APPROVAL_V2_UNTIL\")].value}'" 2>/dev/null || true)"
  if [ -z "$v2until" ]; then
    # The end of the window in which a v2 HMAC token minted before this switch still verifies: one hour from
    # the first run, then kept (wardryx-patch.yaml says why).
    v2until="$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
  fi
  sed "s/@WARDRYX_APPROVAL_V2_UNTIL@/$v2until/" "$ROOT/keyryx/wardryx-patch.yaml" \
    | k_ "-n $KEYRYX_NS patch deployment wardryx --type strategic --patch-file /dev/stdin" >/dev/null \
    || die "could not patch wardryx to sign approvals through Keyryx"
  k_ "-n $KEYRYX_NS rollout status deployment/wardryx --timeout=300s" >/dev/null \
    || die "wardryx did not roll out with its Keyryx signer"
  printf '   wardryx: approval signer is keyryx (rolled out)\n'
}

# keyryx_patch_record_seal: the record-seal signs each sealed root through custody.
keyryx_patch_record_seal() {
  cat "$ROOT/keyryx/record-seal-patch.yaml" \
    | k_ "-n $KEYRYX_NS patch cronjob record-seal --type strategic --patch-file /dev/stdin" >/dev/null \
    || die "could not patch the record-seal to sign through Keyryx"
  printf '   record-seal: signs through keyryx (TRAILRYX_SIGNER=keyryx)\n'
}

keyryx_install_settle() {
  printf '\n>> Keyryx, on by default (--without-keyryx turns it off, the weaker setting)\n'
  keyryx_mint_root keyryx-root
  keyryx_mint_root keyryx-witness-root
  local wd td
  wd="$(keyryx_bearer_digest keyryx-wardryx-client)" || die "could not settle the wardryx bearer"
  td="$(keyryx_bearer_digest keyryx-trailryx-client)" || die "could not settle the trailryx bearer"
  keyryx_apply_policy "$wd" "$td"
  keyryx_apply_objects
  keyryx_patch_wardryx
  keyryx_patch_record_seal
  printf '   Keyryx is on. Custody keyryx-custody:4340, witness keyryx-witness:4341.\n'
}

# TODO(trailryx-kid): the trailryx pin, TRAILRYX_KEYRYX_KID (trailryx#112), is not released. Until it is,
# record-seal takes Keyryx's key from the JWKS it fetches on each refresh, unpinned: the residual that the
# wave-3 trailryx item names. Waiting on the trailryx release tag and digest. When it lands, add the variable
# to keyryx/record-seal-patch.yaml and to this note's removal.

# keyryx_remove_settle: the opt-out. The signers come off; custody, the witness and every key stay.
keyryx_remove_settle() {
  printf '\n>> Keyryx off (--without-keyryx): the approval signer and the record signer are removed, and the record is not signed by custody.\n'
  k_ "-n $KEYRYX_NS get deployment wardryx" >/dev/null 2>&1 \
    && k_ "-n $KEYRYX_NS patch deployment wardryx --type strategic --patch-file /dev/stdin" < "$ROOT/keyryx/wardryx-unpatch.yaml" >/dev/null \
    || true
  k_ "-n $KEYRYX_NS get cronjob record-seal" >/dev/null 2>&1 \
    && k_ "-n $KEYRYX_NS patch cronjob record-seal --type strategic --patch-file /dev/stdin" < "$ROOT/keyryx/record-seal-unpatch.yaml" >/dev/null \
    || true
  printf '   wardryx and record-seal: Keyryx wiring removed. Custody and the witness stay until removed by hand.\n'
}
