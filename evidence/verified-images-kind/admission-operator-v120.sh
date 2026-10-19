#!/usr/bin/env bash
# CLAUDE.md invariant 58, the operator's own agent images, measured on a throwaway kind cluster for stack-k8s v1.2.0:
# with admission on (policy/up.sh --enforce, the same call deploy.sh makes), an agent pod whose image no policy covers
# is refused; the same image, listed as a static entry in the operator's copy of the template, is admitted; and a
# different digest of the same image name stays refused. Policy/README.md, "Your own agent images".
#
# The agent image is alpine, not a TAIPANBOX image: it stands in for an operator's agent. The digests are the
# registry's (docker buildx imagetools inspect, 2026-10-19). Pods are created to be judged by the webhook and deleted
# at once: the verdict is the create call's.
#
# The operator's copy is written to policy/operator-image-policy.yaml, which is gitignored, and removed at exit. If a
# copy already exists there, this script refuses to run rather than overwrite or delete it.
#
# Usage: evidence/verified-images-kind/admission-operator-v120.sh   (REPO defaults to the directory above evidence/)
set -uo pipefail

cd "${REPO:-$(dirname "$0")/../..}" || exit 1
NAME="${KIND_NAME:-admission-operator-v120}"
OPCOPY="policy/operator-image-policy.yaml"
if [ -e "$OPCOPY" ]; then
  echo "refusing to run: $OPCOPY already exists; move it aside first (this script writes and removes it)"
  exit 2
fi
WORK="$(mktemp -d)"
export KUBECONFIG="$WORK/kubeconfig"
trap 'rm -f "$OPCOPY"; kind delete cluster --name "$NAME" >/dev/null 2>&1; rm -rf "$WORK"' EXIT

LISTED_DIGEST='sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'   # alpine:3.20
OTHER_DIGEST='sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1'    # alpine:3.19

echo "# operator agent images on kind, measured $(date -u +%Y-%m-%dT%H:%M:%SZ), kind $(kind version | awk '{print $2}')"
kind create cluster --name "$NAME" --wait 180s >/dev/null 2>&1 || { echo "kind create failed"; exit 1; }
kind get kubeconfig --name "$NAME" > "$KUBECONFIG"
echo "kubernetes $(kubectl version -o json 2>/dev/null | sed -n 's/.*"gitVersion": "\(v[^"]*\)".*/\1/p' | tail -1)"
echo "repo $(git rev-parse --short HEAD 2>/dev/null) $(git diff --quiet 2>/dev/null && echo clean || echo 'with local changes')"
echo "controller $(grep -E '^(release|image):' policy/PIN | tr '\n' ' ')"

kubectl create namespace agent-stack >/dev/null

# agent <label> <image>: one agent pod in agent-stack, carrying the label the agent-token network selects.
n=0
agent() {
  local label="$1" img="$2" out rc verdict reason
  n=$((n + 1))
  out=$(kubectl -n agent-stack create -f - 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: agent-probe-$n
  labels:
    app: agent-example
    taipanbox.dev/agent-token: "true"
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
    - name: agent
      image: $img
      command: ["/bin/sleep", "60"]
YAML
)
  rc=$?
  if [ "$rc" -eq 0 ]; then verdict=ADMITTED; else verdict=REFUSED; fi
  kubectl -n agent-stack delete pod "agent-probe-$n" --wait=false >/dev/null 2>&1
  printf '%-10s %-52s %s\n' "$verdict" "$label" "${img#index.docker.io/}"
  reason=$(printf '%s\n' "$out" | tr '\n' ' ' | sed -n 's/.*denied the request: //p' | cut -c1-260)
  [ -n "$reason" ] && echo "           reason: $reason"
  return "$rc"
}

echo
echo "## 1. the default install's call, no operator copy"
bash policy/up.sh --enforce > "$WORK/up1.log" 2>&1
echo "    up.sh --enforce exit=$?"
kubectl get clusterimagepolicy --no-headers | awk '{print "    " $1}' | grep -c . | sed 's/^/    policies: /'
kubectl get namespace agent-stack -L policy.sigstore.dev/include --no-headers | sed 's/^/    /'
agent "agent image, not listed (alpine:3.20)" "alpine@$LISTED_DIGEST" && echo "    UNEXPECTED: admitted"

echo
echo "## 2. the operator lists the agent image by digest in the copy, and runs the deploy's call again"
cat > "$OPCOPY" <<YAML
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: operator-agent-static
spec:
  mode: enforce
  images:
    - glob: "index.docker.io/library/alpine@$LISTED_DIGEST"
  authorities:
    - static:
        action: pass
YAML
echo "    copy written: $OPCOPY (one static entry, alpine:3.20 by digest)"
bash policy/up.sh --enforce > "$WORK/up2.log" 2>&1
echo "    up.sh --enforce exit=$?"
grep -c "operator-agent-static" "$WORK/up2.log" | sed 's/^/    operator entries applied (lines naming it): /'
sleep 5
agent "agent image, listed (alpine:3.20)" "alpine@$LISTED_DIGEST"
agent "other digest of the same name, not listed (alpine:3.19)" "alpine@$OTHER_DIGEST" && echo "    UNEXPECTED: admitted"

echo
echo "## 3. policy/down.sh removes the admission and the operator's entry"
bash policy/down.sh > "$WORK/down.log" 2>&1
echo "    down.sh exit=$?"
echo "    operator entry left: $(kubectl get clusterimagepolicy operator-agent-static --ignore-not-found --no-headers | wc -l | tr -d ' ') (0 is right)"

echo
echo "finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
