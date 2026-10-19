#!/usr/bin/env bash
# Measures invariant 58 on a throwaway kind cluster (kind v0.33.0), against the real images.
# Creates the cluster, measures, and deletes it. KUBECONFIG is a private copy; no other cluster is touched.
#
# Usage: evidence/verified-images-kind/run.sh            (REPO defaults to the directory above evidence/)
set -uo pipefail

cd "${REPO:-$(dirname "$0")/../..}"
NAME="${KIND_NAME:-f016-verify}"
WORK="$(mktemp -d)"
export KUBECONFIG="$WORK/kubeconfig"
trap 'kind delete cluster --name "$NAME" >/dev/null 2>&1; rm -rf "$WORK"' EXIT

WARDRYX='ghcr.io/taipanbox/wardryx@sha256:9e6a9a9e38f12089499d64c09e23fb5022ac2f1858aefa81187b1df260a87869'
TOKENFUSE='ghcr.io/taipanbox/tokenfuse@sha256:a119ce03a6bc0b3c9eacb755707397bf6b20c75c8d1838f0eeeb0bf4f0c8354c'
CONSOLE='ghcr.io/taipanbox/genaryx-console@sha256:54218cfb989f7499da3a92d52d917ef8bc67b938d1b54070ba63e88fdf164bdd'
MOCKRYX='ghcr.io/taipanbox/mockryx@sha256:758d31650f43b283762da81c8543e3c5dea000d7360a9fb4df8f408f1503c5c7'
COSIGN='ghcr.io/sigstore/cosign/cosign:v2.4.0@sha256:9d50ceb15f023eda8f58032849eedc0216236d2e2f4cfe1cdf97c00ae7798cfe'

echo "# verified images, measured $(date -u +%Y-%m-%dT%H:%M:%SZ) on kind $(kind version | awk '{print $2}')"
kind create cluster --name "$NAME" --wait 180s >/dev/null 2>&1 || { echo "kind create failed"; exit 1; }
kind get kubeconfig --name "$NAME" > "$KUBECONFIG"
echo "kubernetes $(kubectl version -o json 2>/dev/null | sed -n 's/.*"gitVersion": "\(v[^"]*\)".*/\1/p' | tail -1)"

probe() { # probe <label> <namespace> <image>
  local label="$1" ns="$2" img="$3" out rc verdict
  out=$(kubectl -n "$ns" run "probe-$RANDOM" --image="$img" --restart=Never --command -- /bin/true 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then verdict=ADMITTED; else verdict=REFUSED; fi
  printf '%-46s %-9s %s\n' "$label" "$verdict" "$img"
  printf '%s\n' "$out" | sed -n 's/.*denied the request: /      reason: /p' | cut -c1-260
}

kubectl create namespace agent-stack >/dev/null
kubectl create namespace unopted-test >/dev/null
kubectl create namespace before-test >/dev/null

echo
echo "## 0. no policy yet"
probe "unsigned genaryx-console" before-test "$CONSOLE"

echo
echo "## 1. policy/up.sh without --enforce"
bash policy/up.sh > "$WORK/up0.log" 2>&1; echo "    up.sh exit=$?; $(tail -2 "$WORK/up0.log" | head -1)"
kubectl get namespace agent-stack -L policy.sigstore.dev/include --no-headers | sed 's/^/    /'
probe "unsigned genaryx-console, installed not enforced" agent-stack "$CONSOLE"

echo
echo "## 2. policy/up.sh --enforce"
bash policy/up.sh --enforce > "$WORK/up1.log" 2>&1; echo "    up.sh --enforce exit=$?"
kubectl get clusterimagepolicy --no-headers | sed 's/^/    /'
kubectl get namespace agent-stack -L policy.sigstore.dev/include --no-headers | sed 's/^/    /'
probe "unsigned genaryx-console" agent-stack "$CONSOLE"
probe "unsigned mockryx" agent-stack "$MOCKRYX"
probe "signed wardryx v2.1.0 (release workflow)" agent-stack "$WARDRYX"
probe "signed tokenfuse v1.16.0 (release workflow)" agent-stack "$TOKENFUSE"
probe "listed upstream postgres, digest" agent-stack "postgres:16-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea"
probe "listed upstream busybox, digest" agent-stack "busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
probe "listed upstream caddy, digest" agent-stack "caddy@sha256:6aeddd44c3078b0f9a35206472a11420648a79c184603ef95957d0a20044cb2b"
probe "unlisted upstream alpine, tag" agent-stack "alpine:3.20"

echo
echo "## 3. the verifier, on a keyless signature it can read (cosign v2.4.0, legacy .sig)"
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: measure-cosign-identity
spec:
  images:
    - glob: "ghcr.io/sigstore/cosign/**"
  authorities:
    - keyless:
        url: https://fulcio.sigstore.dev
        identities:
          - issuer: https://token.actions.githubusercontent.com
            subjectRegExp: '.*'
YAML
sleep 3
probe "cosign v2.4.0, identity GitHub (wrong issuer)" agent-stack "$COSIGN"
kubectl patch clusterimagepolicy measure-cosign-identity --type merge \
  -p '{"spec":{"authorities":[{"keyless":{"url":"https://fulcio.sigstore.dev","identities":[{"issuer":"https://accounts.google.com","subjectRegExp":".*"}]}}]}}' >/dev/null
sleep 3
probe "cosign v2.4.0, identity its own signer" agent-stack "$COSIGN"
kubectl delete clusterimagepolicy measure-cosign-identity >/dev/null

echo
echo "## 4. a namespace that is not opted in"
probe "unsigned genaryx-console, not opted in" unopted-test "$CONSOLE"

echo
echo "## 5. policy/down.sh"
bash policy/down.sh > "$WORK/down.log" 2>&1; echo "    down.sh exit=$?"
sed 's/^/    /' "$WORK/down.log" | head -4
probe "unsigned genaryx-console, after down.sh" agent-stack "$CONSOLE"

echo
echo "finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
