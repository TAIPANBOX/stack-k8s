#!/usr/bin/env bash
# CLAUDE.md invariant 58, measured on a kind cluster: the admission policy admits the three TAIPANBOX
# images that stack-k8s v1.1.48 published, by digest, and refuses the v1.1.47 genaryx-console, which
# carries only a bundle-format signature the controller does not read.
#
# What it does: checks the signatures with the cosign v2.4.0 image (pinned by digest), installs the
# policy the way policy/up.sh does, and creates one test namespace labelled
# policy.sigstore.dev/include=true. It does not opt agent-stack in (no --enforce); the test namespace
# carries the same label, so the admission decision is the policy's. Everything it creates is deleted.
#
# Usage: KUBECONFIG=<kind kubeconfig> evidence/verified-images-kind/admission-v1148.sh
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$REPO" || exit 1
: "${KUBECONFIG:?point KUBECONFIG at a kind cluster}"

COSIGN='ghcr.io/sigstore/cosign/cosign:v2.4.0@sha256:9d50ceb15f023eda8f58032849eedc0216236d2e2f4cfe1cdf97c00ae7798cfe'
ID='^https://github\.com/TAIPANBOX/stack-k8s/\.github/workflows/(console-image|tunnel-images)\.yml@refs/tags/v[0-9].*$'
ISS='https://token.actions.githubusercontent.com'
NS=adm-v1148

ADMIT=(
  "stack-wg ghcr.io/taipanbox/stack-wg@sha256:b4a8d7716abc16d0be0dd4499e1e6d19ce9c558c67158a157d6b7829a52e3d2a"
  "stack-caddy ghcr.io/taipanbox/stack-caddy@sha256:9d34959511379ca45c37e93fe320d1e0fa2fe4412e7954e6e7b4a333e448d0b4"
  "genaryx-console ghcr.io/taipanbox/genaryx-console@sha256:311625121ba911746aa9a52b9fac7ae1a4730a89546636c86d6543214ea5dd07"
)
REFUSE="genaryx-console-v1147 ghcr.io/taipanbox/genaryx-console@sha256:0f688de13628990984b9b422a14b1e3c1b0803bf3d1e08310adfb8903478d739"

echo "== 1. the signatures, checked with cosign v2.4.0 (the pinned image)"
for entry in "${ADMIT[@]}" "$REFUSE"; do
  name=${entry%% *}; img=${entry#* }
  docker run --rm "$COSIGN" verify --certificate-identity-regexp "$ID" --certificate-oidc-issuer "$ISS" "$img" >/tmp/adm-cosign.$$ 2>&1
  echo "  $name ${img#*@}: cosign exit $? ($(grep -o 'no signatures found' /tmp/adm-cosign.$$ | head -1; grep -c 'Verification for' /tmp/adm-cosign.$$ | sed 's/^/verified claims: /' ))"
done
rm -f /tmp/adm-cosign.$$

echo "== 2. the controller that runs (policy/PIN) and the one the cluster reports"
grep -E '^(release|commit|image):' policy/PIN | sed 's/^/  pin: /'

kubectl create namespace agent-stack >/dev/null 2>&1   # policy/up.sh needs the namespace to exist
echo "== 3. policy/up.sh (no --enforce)"
policy/up.sh 2>&1 | sed 's/^/  /'
echo "  running: $(kubectl -n cosign-system get deployment webhook -o jsonpath='{.spec.template.spec.containers[0].image}')"

echo "== 4. test namespace $NS labelled policy.sigstore.dev/include=true"
kubectl create namespace "$NS" >/dev/null
kubectl label namespace "$NS" policy.sigstore.dev/include=true --overwrite >/dev/null

pod() { # name image
  cat <<YAML | kubectl -n "$NS" create -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: $1
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: $2
YAML
}

echo "== 5. one pod per image, by digest"
for entry in "${ADMIT[@]}"; do
  name=${entry%% *}; img=${entry#* }
  out=$(pod "admit-$name" "$img"); rc=$?
  if [ "$rc" = 0 ]; then echo "  ADMITTED $name ${img#*@}: $out"; else echo "  REFUSED  $name ${img#*@}: $out"; fi
done
name=${REFUSE%% *}; img=${REFUSE#* }
out=$(pod "refuse-$name" "$img"); rc=$?
if [ "$rc" = 0 ]; then echo "  ADMITTED $name ${img#*@} (UNEXPECTED): $out"; else echo "  REFUSED  $name ${img#*@}: $out"; fi

sleep 20
echo "== 6. the admitted pods after 20 s (admission is the claim; the container exit is not)"
kubectl -n "$NS" get pods 2>&1 | sed 's/^/  /'

echo "== 7. teardown"
kubectl -n "$NS" delete pods --all --wait=false >/dev/null 2>&1
policy/down.sh >/dev/null 2>&1; echo "  policy/down.sh exit $?"
kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1
kubectl delete namespace agent-stack --wait=false >/dev/null 2>&1
echo "  done"
