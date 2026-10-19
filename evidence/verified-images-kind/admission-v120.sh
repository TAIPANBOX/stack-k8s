#!/usr/bin/env bash
# CLAUDE.md invariant 58 and 59's admission half, measured on a throwaway kind cluster for stack-k8s
# v1.2.0: the default install's admission (policy/up.sh --enforce, the same call deploy.sh makes) admits
# every digest the manifests pin, refuses an unsigned image, refuses a bundle-format-only signature, and
# refuses a TAIPANBOX image when the only identity that signed it is another repository's.
#
# Creates its own kind cluster and deletes it. Pods are created to be judged by the admission webhook and
# deleted at once: the verdict is the create call's, not the container's.
#
# Usage: evidence/verified-images-kind/admission-v120.sh   (REPO defaults to the directory above evidence/)
set -uo pipefail

cd "${REPO:-$(dirname "$0")/../..}" || exit 1
NAME="${KIND_NAME:-admission-v120}"
WORK="$(mktemp -d)"
export KUBECONFIG="$WORK/kubeconfig"
trap 'kind delete cluster --name "$NAME" >/dev/null 2>&1; rm -rf "$WORK"' EXIT

# Unsigned: no signature of any kind (F-016 measured no referrer and no .sig tag for v1.1.46).
UNSIGNED='ghcr.io/taipanbox/genaryx-console@sha256:54218cfb989f7499da3a92d52d917ef8bc67b938d1b54070ba63e88fdf164bdd'
# Bundle-format signature only: the controller reads the legacy .sig tag, not the bundle (policy/README.md).
BUNDLE_ONLY='ghcr.io/taipanbox/genaryx-console@sha256:0f688de13628990984b9b422a14b1e3c1b0803bf3d1e08310adfb8903478d739'
# The mockryx digest the manifests pin (drills CronJob), used for the other-repository identity test.
MOCKRYX_PIN='ghcr.io/taipanbox/mockryx@sha256:2c07b4d9723466611a083b9d64ba6b642faac8e669a29066e00103a5de96363c'

echo "# admission v1.2.0 on kind, measured $(date -u +%Y-%m-%dT%H:%M:%SZ), kind $(kind version | awk '{print $2}')"
kind create cluster --name "$NAME" --wait 180s >/dev/null 2>&1 || { echo "kind create failed"; exit 1; }
kind get kubeconfig --name "$NAME" > "$KUBECONFIG"
echo "kubernetes $(kubectl version -o json 2>/dev/null | sed -n 's/.*"gitVersion": "\(v[^"]*\)".*/\1/p' | tail -1)"
echo "repo $(git rev-parse --short HEAD 2>/dev/null) $(git diff --quiet 2>/dev/null && echo clean || echo 'with local changes')"
echo "controller $(grep -E '^(release|image):' policy/PIN | tr '\n' ' ')"

kubectl create namespace agent-stack >/dev/null

# probe <label> <image>: one pod in agent-stack, judged by the webhook at create time.
n=0
probe() {
  local label="$1" img="$2" out rc verdict reason
  n=$((n + 1))
  out=$(kubectl -n agent-stack create -f - 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: probe-$n
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: $img
YAML
)
  rc=$?
  if [ "$rc" -eq 0 ]; then verdict=ADMITTED; else verdict=REFUSED; fi
  kubectl -n agent-stack delete pod "probe-$n" --wait=false >/dev/null 2>&1
  printf '%-10s %-44s %s\n' "$verdict" "$label" "${img#ghcr.io/taipanbox/}"
  reason=$(printf '%s\n' "$out" | tr '\n' ' ' | sed -n 's/.*denied the request: //p' | cut -c1-260)
  [ -n "$reason" ] && echo "           reason: $reason"
  return "$rc"
}

echo
echo "## 1. policy/up.sh --enforce (the default install's call; deploy.sh runs it after the apply)"
bash policy/up.sh --enforce > "$WORK/up.log" 2>&1
echo "    up.sh --enforce exit=$?"
sed 's/^/    /' "$WORK/up.log"
kubectl get clusterimagepolicy --no-headers | awk '{print "    " $1}'
kubectl get namespace agent-stack -L policy.sigstore.dev/include --no-headers | sed 's/^/    /'

echo
echo "## 2. every digest manifests/ and keyryx/manifests/ pin: admitted"
# Digests from the tracked manifests, one line per distinct reference, in the order they first appear.
REFS=$(grep -rhoE '[a-z0-9./:_-]+@sha256:[0-9a-f]{64}' manifests keyryx/manifests | awk '!seen[$0]++')
total=0; admitted=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  total=$((total + 1))
  if probe "pinned in manifests" "$ref"; then admitted=$((admitted + 1)); fi
done <<< "$REFS"
echo "    admitted $admitted of $total distinct pinned digests"

echo
echo "## 3. refused: an unsigned image, a bundle-only signature, and an unlisted upstream image"
probe "unsigned genaryx-console v1.1.46" "$UNSIGNED" && echo "    UNEXPECTED: admitted"
probe "genaryx-console v1.1.47, bundle format only" "$BUNDLE_ONLY" && echo "    UNEXPECTED: admitted"
probe "unlisted upstream alpine, tag" "alpine:3.20" && echo "    UNEXPECTED: admitted"

echo
echo "## 4. a TAIPANBOX image signed only by another repository's identity is refused"
# Same image, same signature: the policy that names mockryx's own release is replaced for the test by
# one that names tokenfuse's release (another repository's identity, on a version tag). The mockryx
# signature was made by mockryx's release.yml, so only the identity differs.
kubectl delete clusterimagepolicy taipanbox-mockryx >/dev/null
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: measure-foreign-identity
spec:
  mode: enforce
  images:
    - glob: "ghcr.io/taipanbox/mockryx@sha256:*"
  authorities:
    - keyless:
        url: https://fulcio.sigstore.dev
        identities:
          - issuer: https://token.actions.githubusercontent.com
            subjectRegExp: '^https://github\.com/TAIPANBOX/tokenfuse/\.github/workflows/release\.yml@refs/tags/v[0-9][A-Za-z0-9._+-]*$'
YAML
sleep 5
probe "mockryx, identity of tokenfuse's release" "$MOCKRYX_PIN" && echo "    UNEXPECTED: admitted"
kubectl delete clusterimagepolicy measure-foreign-identity >/dev/null
kubectl apply -f policy/image-policy.yaml >/dev/null
sleep 5
probe "mockryx, identity of mockryx's release" "$MOCKRYX_PIN"

echo
echo "## 5. policy/down.sh removes the admission; the same unsigned image is then admitted"
bash policy/down.sh > "$WORK/down.log" 2>&1; echo "    down.sh exit=$?"
sleep 5
probe "unsigned genaryx-console v1.1.46, after down" "$UNSIGNED"

echo
echo "finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
