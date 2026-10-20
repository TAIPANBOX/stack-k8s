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
#   trailryx pin: custody's one ES384 key, by its kid, into the stack-wiring ConfigMap (keyryx_pin_trailryx_kid, invariant 73)
#   record-seal: keyryx/record-seal-patch.yaml, strategic, after apply
#   readers: keyryx/console-findings-patch.yaml and keyryx/heraldyx-findings-patch.yaml, strategic, each applied
#     when its Deployment is there (heraldyx is opt-in), so the witness's findings reach them (invariant 75)
#
# WHAT keyryx_remove_settle DOES: the same patches in reverse (wardryx-unpatch.yaml, record-seal-unpatch.yaml,
# console-findings-unpatch.yaml, heraldyx-findings-unpatch.yaml).
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

# keyryx_patch_reader DEPLOYMENT FILE: one reader of the witness's findings (CLAUDE.md invariant 75), patched only
# when its Deployment is there. heraldyx is opt-in and deploy.sh applies it after this settle, so deploy.sh calls
# this again for heraldyx once it is applied. The reader mounts the witness's own claim through subPath alerts, read
# only, and is pod-affined to the witness, so it rolls onto the witness's node.
keyryx_patch_reader() {
  local dep="$1" file="$2"
  if ! k_ "-n $KEYRYX_NS get deployment $dep" >/dev/null 2>&1; then
    printf '   %s: not installed, its findings patch waits until it is\n' "$dep"
    return 0
  fi
  cat "$ROOT/keyryx/$file" \
    | k_ "-n $KEYRYX_NS patch deployment $dep --type strategic --patch-file /dev/stdin" >/dev/null \
    || die "could not patch $dep to read the Keyryx witness's findings"
  k_ "-n $KEYRYX_NS rollout status deployment/$dep --timeout=300s" >/dev/null \
    || die "$dep did not roll out beside the Keyryx witness"
  printf '   %s: reads the witness findings, read only, beside the witness (rolled out)\n' "$dep"
}

# keyryx_unpatch KIND NAME FILE: one Keyryx patch reversed, when its object is there. An object that is not
# there is skipped; an unpatch the API server refuses stops the run with the reason, so the opt-out never
# reports wiring removed that it did not remove. scripts/keyryx-patches-round-trip.sh runs every pair.
keyryx_unpatch() {
  local kind="$1" name="$2" file="$3"
  local found
  # --ignore-not-found prints nothing for an object that is not there and fails on any other error, so a
  # cluster that cannot be read stops the run instead of reading as "not installed".
  found="$(k_ "-n $KEYRYX_NS get $kind $name --ignore-not-found -o name")" \
    || die "could not read $kind $name to remove its Keyryx wiring"
  if [ -z "$found" ]; then
    printf '   %s %s: not installed, nothing to remove\n' "$kind" "$name"
    return 0
  fi
  k_ "-n $KEYRYX_NS patch $kind $name --type strategic --patch-file /dev/stdin" < "$ROOT/keyryx/$file" >/dev/null \
    || die "could not remove the Keyryx wiring from $kind $name (keyryx/$file was refused); it is still wired to Keyryx"
}

# keyryx_unpatch_reader DEPLOYMENT FILE: the reverse of keyryx_patch_reader, through keyryx_unpatch, which dies
# on a refused unpatch.
keyryx_unpatch_reader() {
  keyryx_unpatch deployment "$1" "$2" || die "could not remove the Keyryx findings wiring from $1"
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
  keyryx_pin_trailryx_kid
  keyryx_patch_record_seal
  keyryx_patch_reader genaryx-console console-findings-patch.yaml
  keyryx_patch_reader heraldyx heraldyx-findings-patch.yaml
  printf '   Keyryx is on. Custody keyryx-custody:4340, witness keyryx-witness:4341.\n'
}

# keyryx_probe_jwks NAME: prints custody's public key set for NAME (GET /v1/jwks/NAME, a public route). It runs a
# one-shot probe pod with the consumer label, the only label custody admits (CLAUDE.md invariant 57), busybox pinned
# by digest, restricted like every pod here, and removes the pod after it has answered. Its output is the key set,
# which is public; nothing here prints it.
keyryx_probe_jwks() {
  local name="$1" pod="keyryx-jwks-probe" phase out i
  k_ "-n $KEYRYX_NS delete pod $pod --ignore-not-found --wait=true" >/dev/null 2>&1 || true
  cat <<EOF | k_ "-n $KEYRYX_NS create -f -" >/dev/null || return 1
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $KEYRYX_NS
  labels: { keyryx-consumer: "true", app.kubernetes.io/part-of: agent-stack }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65534, runAsGroup: 65534, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
      command: [wget, -qO-, "http://keyryx-custody.$KEYRYX_NS.svc.cluster.local:4340/v1/jwks/$name"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 64Mi } }
EOF
  phase=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    phase="$(k_ "-n $KEYRYX_NS get pod $pod -o jsonpath='{.status.phase}'" 2>/dev/null || true)"
    case "$phase" in
      Succeeded|Failed) break ;;
    esac
    sleep 2
  done
  out=""
  if [ "$phase" = Succeeded ]; then
    out="$(k_ "-n $KEYRYX_NS logs $pod" 2>/dev/null || true)"
  fi
  k_ "-n $KEYRYX_NS delete pod $pod --ignore-not-found --wait=false" >/dev/null 2>&1 || true
  [ "$phase" = Succeeded ] || return 1
  printf '%s' "$out"
}

# keyryx_pin_trailryx_kid: pins the record seal to the one ES384 (P-384) key custody publishes for trailryx-root,
# by its RFC 7638 thumbprint, which is the kid custody publishes (CLAUDE.md invariant 73). trailryx-node v1.5.0
# refuses to start with no pin, and reads only the key the pin names. The kid is the only thing printed about the key.
#   no ES384 key in the set                          refused, with the reason
#   a first install, and more than one ES384 key     refused, and the operator names the one to pin
#   a re-run, and the pin is still in the set        kept, nothing written
#   a re-run, and the pin is no longer in the set    refused: rotation is named, not implied
#   KEYRYX_ROTATE_KID=<kid> set                      pinned to that kid, which the set must hold as ES384
keyryx_pin_trailryx_kid() {
  local current jwks es384 n kid
  current="$(k_ "-n $KEYRYX_NS get configmap stack-wiring -o jsonpath='{.data.TRAILRYX_KEYRYX_KID}'" 2>/dev/null || true)"
  jwks="$(keyryx_probe_jwks trailryx-root)" \
    || die "could not read custody's trailryx-root key set: the probe pod did not answer"
  es384="$(printf '%s' "$jwks" | python3 -c '
import json, re, sys
try:
    doc = json.load(sys.stdin)
except ValueError:
    sys.exit("custody answered a trailryx-root key set that is not JSON")
keys = doc.get("keys") if isinstance(doc, dict) else None
if not isinstance(keys, list):
    sys.exit("custody answered a trailryx-root key set with no keys array")
for k in keys:
    if isinstance(k, dict) and k.get("kty") == "EC" and k.get("crv") == "P-384":
        kid = k.get("kid") or ""
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}", kid):
            sys.exit("custody publishes a P-384 key whose kid is not a 43-character thumbprint: refusing to pin it")
        print(kid)
')" || die "custody's trailryx-root key set cannot be pinned (see the line above)"
  n="$(printf '%s\n' "$es384" | grep -c . || true)"
  if [ "${n:-0}" -eq 0 ]; then
    die "custody's trailryx-root key set has no ES384 key: trailryx-node pins a P-384 key, and keyryx/policy.json.tmpl makes trailryx-root ES384"
  fi
  if [ -n "${KEYRYX_ROTATE_KID:-}" ]; then
    printf '%s\n' "$es384" | grep -Fqx "$KEYRYX_ROTATE_KID" \
      || die "KEYRYX_ROTATE_KID names no ES384 key in custody's trailryx-root set"
    kid="$KEYRYX_ROTATE_KID"
  elif [ -n "$current" ]; then
    if printf '%s\n' "$es384" | grep -Fqx "$current"; then
      printf '   trailryx-kid: kept (the record seal stays pinned to %s)\n' "$current"
      return 0
    fi
    die "the pinned TRAILRYX_KEYRYX_KID is not in custody's trailryx-root set; to rotate on purpose, re-run with KEYRYX_ROTATE_KID=<kid of the successor>"
  else
    [ "$n" -eq 1 ] || die "custody's trailryx-root set holds more than one ES384 key, and no pin exists yet: name the one to pin with KEYRYX_ROTATE_KID=<kid>"
    kid="$(printf '%s\n' "$es384" | head -n 1)"
  fi
  printf '{"data":{"TRAILRYX_KEYRYX_KID":"%s"}}' "$kid" \
    | k_ "-n $KEYRYX_NS patch configmap stack-wiring --type merge --patch-file /dev/stdin" >/dev/null \
    || die "could not write the trailryx pin to stack-wiring"
  printf '   trailryx-kid: pinned to custody'"'"'s ES384 key %s (the record seal signs under it)\n' "$kid"
}

# keyryx_remove_settle: the opt-out. The signers come off; custody, the witness and every key stay.
keyryx_remove_settle() {
  printf '\n>> Keyryx off (--without-keyryx): the approval signer and the record signer are removed, and the record is not signed by custody.\n'
  keyryx_unpatch deployment wardryx wardryx-unpatch.yaml
  keyryx_unpatch cronjob record-seal record-seal-unpatch.yaml
  keyryx_unpatch_reader genaryx-console console-findings-unpatch.yaml
  keyryx_unpatch_reader heraldyx heraldyx-findings-unpatch.yaml
  printf '   wardryx, record-seal, the console and heraldyx: Keyryx wiring removed. Custody and the witness stay until removed by hand.\n'
}
