#!/usr/bin/env bash
# Measured run of the Keyryx L2 wiring on kind (no cloud, no spend). Creates a
# single-node kind cluster, applies keyryx/manifests/59-keyryx.yaml with the
# steps keyryx/up.sh runs (minting, the policy ConfigMap, the apply), then probes:
#   1. custody boots from the copied root key and serves its health and key set;
#   2. a consumer with the minted bearer key gets a signature, a stranger does not;
#   3. two producer uids on one events volume: one appends to its own stream,
#      the other is refused on that same stream;
#   4. a pod mounting the event streams read only (as the witness does) cannot write;
#   5. the witness reads the streams it was given (its log).
#
# Not run here: wardryx's patch (kind has no wardryx), the NetworkPolicy
# admission (kind's default CNI does not enforce NetworkPolicy), and any cloud.
#
#   ./evidence/keyryx-kind/run.sh 2>&1 | tee evidence/keyryx-kind/run.out
#
# Deletes the kind cluster it creates when run with --delete-after. Otherwise
# it leaves the cluster up for inspection (and for the operator to delete).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CLUSTER="${CLUSTER:-keyryx-l2}"
NS=agent-stack
BUSYBOX='busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e'

step() { printf '\n== %s\n' "$*"; }

step "cluster $CLUSTER"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --wait 120s || { echo "kind create failed"; exit 1; }
fi
# A private kubeconfig for this run: the operator's current context is not touched.
KUBE_TMP="$(mktemp -d)"
kind get kubeconfig --name "$CLUSTER" >"$KUBE_TMP/config"
chmod 0600 "$KUBE_TMP/config"
export KUBECONFIG="$KUBE_TMP/config"
kubectl get nodes

kubectl -n "$NS" delete pod probe producer-a producer-b ro-probe --ignore-not-found --wait=true >/dev/null 2>&1

step "namespace, the events volume (one node: ReadWriteOnce is shared by pods on it)"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: stack-events, namespace: agent-stack }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
YAML

step "keyryx/up.sh steps 1 to 3 (no wardryx patch: kind has no wardryx)"
for name in keyryx-root keyryx-witness-root; do
  if kubectl -n "$NS" get secret "$name" >/dev/null 2>&1; then
    echo "kept $name"
  else
    head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n' |
      kubectl -n "$NS" create secret generic "$name" --from-file=root.key=/dev/stdin >/dev/null
    echo "minted $name"
  fi
done
if kubectl -n "$NS" get secret keyryx-wardryx-client >/dev/null 2>&1; then
  cred="$(kubectl -n "$NS" get secret keyryx-wardryx-client -o jsonpath='{.data.credential}' | base64 --decode)"
  echo "kept keyryx-wardryx-client"
else
  cred="$(head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n')"
  printf '%s' "$cred" | kubectl -n "$NS" create secret generic keyryx-wardryx-client --from-file=credential=/dev/stdin >/dev/null
  echo "minted keyryx-wardryx-client"
fi
digest="$(printf '%s' "$cred" | openssl dgst -sha256 -r | cut -d' ' -f1)"
tmp="$(mktemp -d)"
sed "s/@WARDRYX_DIGEST@/$digest/" "$ROOT/keyryx/policy.json.tmpl" >"$tmp/policy.json"
kubectl -n "$NS" create configmap keyryx-policy --from-file=policy.json="$tmp/policy.json" \
  --dry-run=client -o yaml | kubectl -n "$NS" apply -f - >/dev/null
rm -rf "$tmp"
kubectl -n "$NS" apply -f "$ROOT/keyryx/manifests/59-keyryx.yaml"
kubectl -n "$NS" rollout status deployment/keyryx-custody --timeout=300s
kubectl -n "$NS" rollout status deployment/keyryx-witness --timeout=300s
kubectl -n "$NS" get pods -o wide

step "1. custody: health and the published key set"
kubectl -n "$NS" apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: probe, namespace: agent-stack, labels: { keyryx-consumer: "true" } }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 20200, runAsGroup: 20200, fsGroup: 20200, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: $BUSYBOX
      command: [sh, -c, "sleep 3600"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts:
        - { name: cred, mountPath: /cred, readOnly: true }
        - { name: tmp, mountPath: /tmp }
  volumes:
    - name: cred
      secret: { secretName: keyryx-wardryx-client, defaultMode: 0440 }
    - name: tmp
      emptyDir: {}
YAML
kubectl -n "$NS" wait pod/probe --for=condition=Ready --timeout=120s >/dev/null
CUSTODY=http://keyryx-custody.agent-stack.svc.cluster.local:4340
kubectl -n "$NS" exec probe -- wget -qO- "$CUSTODY/healthz"; echo " <- healthz"
kubectl -n "$NS" exec probe -- wget -qO- "$CUSTODY/v1/jwks/wardryx-approval" | head -c 300; echo " <- jwks (truncated)"

step "2. a consumer with the minted key signs; a stranger does not"
kubectl -n "$NS" exec probe -- sh -c "
  key=\$(cat /cred/credential)
  body='{\"statement_b64\":\"aGVsbG8=\",\"purpose\":\"approval\"}'
  echo 'good bearer:'; wget -S -qO- --header=\"Authorization: Bearer \$key\" --header='Content-Type: application/json' --post-data=\"\$body\" $CUSTODY/v1/keys/wardryx-approval/sign 2>&1 | head -c 400; echo
  echo 'wrong bearer:'; wget -S -qO- --header='Authorization: Bearer 0000000000000000000000000000000000000000000000000000000000000000' --header='Content-Type: application/json' --post-data=\"\$body\" $CUSTODY/v1/keys/wardryx-approval/sign 2>&1 | grep -E 'HTTP/' | head -2
  echo 'no bearer:'; wget -S -qO- --header='Content-Type: application/json' --post-data=\"\$body\" $CUSTODY/v1/keys/wardryx-approval/sign 2>&1 | grep -E 'HTTP/' | head -2
" 2>&1

step "3. two producer uids on one events volume"
for who in a b; do
  uid=$([ "$who" = a ] && echo 20001 || echo 20002)
  kubectl -n "$NS" apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: producer-$who, namespace: agent-stack }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: $uid, runAsGroup: $uid, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: producer
      image: $BUSYBOX
      command: [sh, -c]
      args:
        - |
          umask 007
          if [ "$who" = a ]; then echo '{"source":"wardryx","n":1}' >> /events/wardryx.ndjson; echo "producer-a append: exit \$?";
          else echo '{"source":"wardryx","n":2}' >> /events/wardryx.ndjson; echo "producer-b append to a stream it does not own: exit \$?"; fi
          ls -ln /events/wardryx.ndjson; sleep 3600
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts:
        - { name: events, mountPath: /events }
        - { name: tmp, mountPath: /tmp }
  volumes:
    - name: events
      persistentVolumeClaim: { claimName: stack-events }
    - name: tmp
      emptyDir: {}
YAML
done
sleep 15
kubectl -n "$NS" logs producer-a 2>&1 | head -5
kubectl -n "$NS" logs producer-b 2>&1 | head -5

step "4. a read-only mount of the event streams (the witness's mount) refuses a write"
kubectl -n "$NS" apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ro-probe, namespace: agent-stack }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 20100, runAsGroup: 20100, fsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: $BUSYBOX
      command: [sh, -c]
      args: ["echo x > /events/witness-was-here 2>&1; echo \"write exit=\$?\"; sleep 3600"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts:
        - { name: events, mountPath: /events, readOnly: true }
  volumes:
    - name: events
      persistentVolumeClaim: { claimName: stack-events, readOnly: true }
YAML
sleep 15
kubectl -n "$NS" logs ro-probe 2>&1 | head -3

step "5. the witness: its log, and its head after it has read the streams (one interval is 60 s)"
sleep 75
kubectl -n "$NS" exec probe -- wget -T 5 -qO- http://keyryx-witness.agent-stack.svc.cluster.local:4341/v1/witness/head; echo " <- witness head (probe carries keyryx-consumer, so step 6 decides whether it may reach the witness)"
kubectl -n "$NS" logs deploy/keyryx-witness --tail=20 2>&1

step "6. NetworkPolicy: which pod reaches which role (does this CNI enforce them?)"
kubectl -n kube-system get daemonset -o name | tr '\n' ' '; echo
for who in none consumer witness-client; do
  case "$who" in
    none) lbl='app: np-probe' ;;
    consumer) lbl='keyryx-consumer: "true"' ;;
    witness-client) lbl='keyryx-witness-client: "true"' ;;
  esac
  kubectl -n "$NS" apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: np-$who, namespace: agent-stack, labels: { $lbl } }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 20200, runAsGroup: 20200, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: $BUSYBOX
      command: [sh, -c, "sleep 3600"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
YAML
done
for who in none consumer witness-client; do kubectl -n "$NS" wait pod/np-$who --for=condition=Ready --timeout=120s >/dev/null; done
for who in none consumer witness-client; do
  c=$(kubectl -n "$NS" exec np-$who -- wget -T 5 -S -O /dev/null http://keyryx-custody.agent-stack.svc.cluster.local:4340/healthz 2>&1 | grep -m1 -oE 'HTTP/[0-9.]+ [0-9]+' || echo "no answer")
  w=$(kubectl -n "$NS" exec np-$who -- wget -T 5 -S -O /dev/null http://keyryx-witness.agent-stack.svc.cluster.local:4341/v1/witness/head 2>&1 | grep -m1 -oE 'HTTP/[0-9.]+ [0-9]+' || echo "no answer")
  echo "label $who: custody=$c witness=$w"
done
kubectl -n "$NS" delete pod np-none np-consumer np-witness-client --ignore-not-found >/dev/null

step "cleanup of probe pods"
kubectl -n "$NS" delete pod probe producer-a producer-b ro-probe --ignore-not-found >/dev/null

if [ "${1:-}" = "--delete-after" ]; then
  kind delete cluster --name "$CLUSTER"
fi
