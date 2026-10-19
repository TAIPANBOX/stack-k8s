# The console's approver key, and wardryx's copy of its public half, minted once when the cluster holds
# neither. Sourced by deploy.sh, cloud/gcp/deploy-gcp.sh and cloud/aws/deploy-aws.sh, not run. CLAUDE.md
# invariant 67.
#
# `@decided 2026-10-19` (paraphrased): an approval names the person who gave it, and a grant or a denial
# with no statement from the console is refused. The console signs that statement with a P-256 key only it
# holds, and wardryx verifies it against the public half. This file makes that pair; it never rewrites it.
#
# Needs in scope, from the caller: die(), k_ (its kubectl runner, given ONE argument string) and
# secret_doc from lib/secret-doc.sh. Writes nothing but the two objects below, and a private temporary
# directory (mode 0700) that holds the key for the length of one call and is removed on every path.
#
# WHAT A RUN DOES, by what the cluster holds:
#   neither object     makes an EC P-256 key (PKCS#8 PEM) and its JWK set, creates the Secret
#                      console-approver-key (key approver.pem) and the ConfigMap wardryx-approver-jwks
#                      (key approver-jwks.json) on stdin, and removes the directory.
#   both objects       nothing. The key is never rewritten, so the console and wardryx keep one pair.
#   one of the two     refuses. A Secret and a JWK set that do not match would refuse every statement,
#                      so a half pair is an operator's decision, not something a deploy repairs.
#
# The private key never reaches a command line: secret_doc reads its file's bytes, and the documents go to
# `kubectl create -f -` on stdin. The public JWK set is written to the ConfigMap as one JSON line.

APPROVER_NS="${APPROVER_NS:-agent-stack}"
APPROVER_SECRET="console-approver-key"
APPROVER_CM="wardryx-approver-jwks"

# approver_mint_fail DIR MESSAGE: remove the private directory, then refuse. die() exits, so the cleanup
# has to come first.
approver_mint_fail() {
  rm -rf "$1"
  die "$2"
}

approver_mint_settle() {
  local have secret_there=no cm_there=no dir jwks_json
  have="$(k_ "-n $APPROVER_NS get secret/$APPROVER_SECRET configmap/$APPROVER_CM --ignore-not-found -o name" \
    | tr '\n' ' ')" || die "could not ask the cluster whether the approver key exists"
  case " $have " in *" secret/$APPROVER_SECRET "*) secret_there=yes ;; esac
  case " $have " in *" configmap/$APPROVER_CM "*) cm_there=yes ;; esac

  if [ "$secret_there" = yes ] && [ "$cm_there" = yes ]; then
    printf '   approver key: kept (%s and %s are both in %s)\n' "$APPROVER_SECRET" "$APPROVER_CM" "$APPROVER_NS"
    return 0
  fi
  if [ "$secret_there" = yes ] || [ "$cm_there" = yes ]; then
    die "the approver key and its public JWK set are not both in $APPROVER_NS (have: ${have:-none}). A half pair would refuse every approval statement, so nothing was changed. Restore the missing one by hand, or delete the other, then run the deploy again."
  fi

  dir="$(mktemp -d)" || die "could not create a private directory for the approver key"
  chmod 700 "$dir"
  (
    umask 077
    openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out "$dir/approver.pem"
  ) || approver_mint_fail "$dir" "could not generate the approver key (openssl ecparam and pkcs8)"
  openssl pkey -in "$dir/approver.pem" -pubout -outform DER -out "$dir/pub.der" \
    || approver_mint_fail "$dir" "could not derive the approver's public key"
  jwks_json="$(python3 - "$dir/pub.der" <<'PY'
import base64
import json
import sys

der = open(sys.argv[1], "rb").read()
point = der[-65:]
if len(point) != 65 or point[0] != 4:
    sys.exit("the public key is not an uncompressed P-256 point")


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


jwks = {"keys": [{"kty": "EC", "crv": "P-256", "use": "sig", "alg": "ES256",
                  "x": b64url(point[1:33]), "y": b64url(point[33:65])}]}
print(json.dumps(jwks, separators=(",", ":")))
PY
)" || approver_mint_fail "$dir" "could not write the approver's JWK set"

  {
    secret_doc "$APPROVER_SECRET" "approver.pem=@$dir/approver.pem"
    printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\ndata:\n  approver-jwks.json: '"'"'%s'"'"'\n' \
      "$APPROVER_CM" "$jwks_json"
  } | k_ "-n $APPROVER_NS create -f -" >/dev/null \
    || approver_mint_fail "$dir" "could not create the approver key and its public JWK set in $APPROVER_NS"
  rm -rf "$dir"
  printf '   approver key: minted (%s, and %s with the public half). The private key was never printed.\n' \
    "$APPROVER_SECRET" "$APPROVER_CM"
}
