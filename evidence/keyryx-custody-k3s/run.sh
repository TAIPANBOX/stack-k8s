#!/usr/bin/env bash
# Measured run of keyryx v0.2.0 custody's own stream on k3s (no cloud, no spend), and of the console image
# genaryx v0.1.0 under this stack's security context. CLAUDE.md invariant 97, stack-k8s 1.19.0.
#
# Runs as root inside a throwaway VM (an ephemeral Incus clone of an Ubuntu 24.04 image on the build machine,
# 2 vCPU, 8 GiB): installs the k3s release and the Longhorn release this repository pins, each checked against
# the sha256 lib/verified-fetch.sh pins, and the events claim on `stack-rwx` (Longhorn RWX, as install.sh writes
# it, one replica on one node): the bus's separation rests on Longhorn RWX applying no fsGroup, which k3s's own
# local-path does (evidence/bus-per-producer-longhorn). Then it applies, unchanged, manifests/11-bus.yaml and keyryx/manifests/59-keyryx.yaml into a namespace that enforces
# Pod Security `restricted`, with the minting keyryx/up.sh does, and probes:
#    1. the bus owner makes custody/ 20000:20101 0771 beside streams/, twice (the second run is the real test);
#    2. custody's init makes keyryx-custody.ndjson as 20101 in group 10001, 0640, and custody starts on v0.2.0
#       and says where it announces;
#    3. `kubectl exec ... keyryx admin rotate` and `... revoke` on the admin socket, as custody's own uid,
#       write key_rotated and key_revoked into that file;
#    4. a reader shaped as heraldyx's patch mounts it (subPath custody, read only, group 10001) and reads both
#       lines, and cannot write the file or add a name beside it;
#    5. another plane's identity (wardryx, 20001 in its groups) mounting custody/ read-write cannot append to
#       the file nor create a name in custody/;
#    6. heraldyx v0.10.0 itself, reading the file as the patch names it, writes the mail for key_revoked;
#    7. custody restarted keeps its file and starts again;
#    8. the console image genaryx v0.1.0 runs as verdryx-slo does (uid 20020, read-only root, no capability):
#       its shell, verdryx, both engines and genaryx-web answer, and genaryx-web makes a preview key.
#
#   ./evidence/keyryx-custody-k3s/run.sh 2>&1 | tee evidence/keyryx-custody-k3s/output.txt
#
# Each failed probe prints FAIL and the run ends with RUN_EXIT=1; RUN_EXIT=0 means every probe held.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
NS=agent-stack
BUSYBOX='busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e'
K3S_VERSION="${K3S_VERSION:-v1.36.2+k3s1}"
FAILS=0

step() { printf '\n== %s\n' "$*"; }
ok() { printf 'OK    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
k() { kubectl -n "$NS" "$@"; }
wait_done() { # pod [seconds]: until the pod has Succeeded or Failed
  local i
  for i in $(seq "${2:-180}"); do
    case "$(k get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null)" in Succeeded|Failed) return 0 ;; esac
    sleep 1
  done
  return 1
}
img() { sed -nE "s#^ +image: (ghcr\.io/taipanbox/$1:v[^ ]+@sha256:[0-9a-f]{64})\$#\1#p" "$2" | sed -n 1p; }

step "k3s $K3S_VERSION, from its tag, checked against the pinned sha256"
if ! command -v k3s >/dev/null 2>&1; then
  . "$ROOT/lib/verified-fetch.sh"
  vf_init || exit 1
  url="https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION/+/%2B}/install.sh"
  f="$(vf_file K3S_INSTALL_SHA256 "the k3s install script" "$K3S_VERSION" "$url")" || { echo "the k3s install script did not verify"; exit 1; }
  INSTALL_K3S_VERSION="$K3S_VERSION" sh "$f" --write-kubeconfig-mode 0600 >/dev/null || { echo "k3s install failed"; exit 1; }
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for _ in $(seq 60); do kubectl get nodes 2>/dev/null | grep -q ' Ready' && break; sleep 2; done
kubectl get nodes -o wide

step "Longhorn v1.7.2, checked against the pinned sha256, and stack-rwx as install.sh writes it (one replica)"
if ! kubectl get csidriver driver.longhorn.io >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -qq open-iscsi nfs-common >/dev/null 2>&1; systemctl enable --now iscsid >/dev/null 2>&1
  . "$ROOT/lib/verified-fetch.sh"; vf_init || exit 1
  lh="$(vf_file LONGHORN_SHA256 "Longhorn" v1.7.2 https://raw.githubusercontent.com/longhorn/longhorn/v1.7.2/deploy/longhorn.yaml)" \
    || { echo "longhorn.yaml did not verify"; exit 1; }
  kubectl apply -f "$lh" >/dev/null
fi
for _ in $(seq 120); do
  [ "$(kubectl -n longhorn-system get ds longhorn-csi-plugin -o jsonpath='{.status.numberReady}' 2>/dev/null)" = 1 ] && break; sleep 5
done
kubectl -n longhorn-system get ds longhorn-csi-plugin
kubectl apply -f - <<'YAML' >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: stack-rwx
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"
  staleReplicaTimeout: "30"
  fsType: "ext4"
YAML
kubectl get csidriver driver.longhorn.io -o jsonpath='driver.longhorn.io fsGroupPolicy={.spec.fsGroupPolicy}{"\n"}'
# the Keyryx state claims stay on k3s's default class, local-path, which is ReadWriteOnce like Longhorn's
kubectl annotate sc longhorn storageclass.kubernetes.io/is-default-class=false --overwrite >/dev/null 2>&1

step "namespace $NS enforcing Pod Security restricted, and the claims 59-keyryx.yaml does not make"
kubectl apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
YAML
k apply -f - <<YAML >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: stack-events, namespace: $NS }
spec:
  accessModes: [ReadWriteMany]
  storageClassName: stack-rwx
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: trailryx-records, namespace: $NS }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
YAML
for _ in $(seq 60); do [ "$(k get pvc stack-events -o jsonpath='{.status.phase}')" = Bound ] && break; sleep 3; done
k get pvc
kubectl get ns "$NS" --show-labels

# A pod that binds the local-path claims now, so the owner Job and every later pod share one node directory.
probe_root() { # name script: a pod in the bus group mounting the claim root READ ONLY, prints its output
  k delete pod "$1" --ignore-not-found --wait=true >/dev/null 2>&1
  k apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: $1, namespace: $NS }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 20099, runAsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: c
      image: $BUSYBOX
      command: ["sh", "-c", $(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      volumeMounts: [{ name: events, mountPath: /bus, readOnly: true }]
  volumes:
    - name: events
      persistentVolumeClaim: { claimName: stack-events, readOnly: true }
YAML
  wait_done "$1"
  k logs "$1"
  k delete pod "$1" --wait=false >/dev/null 2>&1
}

run_owner() {
  k delete job bus-owner --ignore-not-found --wait=true >/dev/null 2>&1
  k apply -f "$ROOT/manifests/11-bus.yaml" >/dev/null
  if k wait --for=condition=complete job/bus-owner --timeout=240s >/dev/null; then
    ok "the bus-owner Job completed ($1)"
  else
    fail "the bus-owner Job did not complete ($1)"; k logs job/bus-owner --tail=20
  fi
}

step "1. the bus owner, twice"
run_owner "first run"
run_owner "second run"
out="$(probe_root probe-owner 'stat -c "%n %u:%g:%a" /bus/streams /bus/custody /bus/focus/gateway; ls /bus/custody >/dev/null 2>&1 && echo "custody/ lists for others" || echo "custody/ does not list for others"')"
printf '%s\n' "$out"
grep -q '^/bus/custody 20000:20101:771$' <<<"$out" && ok "custody/ is 20000:20101 0771" || fail "custody/ is not 20000:20101 0771"
grep -q '^/bus/streams 20000:10001:2750$' <<<"$out" && ok "streams/ is still 20000:10001 2750" || fail "streams/ changed"
grep -q 'custody/ does not list for others' <<<"$out" && ok "custody/ does not list for a uid outside its group" || fail "custody/ lists for others"

step "2. keyryx/up.sh's minting, then 59-keyryx.yaml as it is"
for name in keyryx-root keyryx-witness-root; do
  k get secret "$name" >/dev/null 2>&1 \
    || head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n' | k create secret generic "$name" --from-file=root.key=/dev/stdin >/dev/null
done
for name in keyryx-wardryx-client keyryx-trailryx-client; do
  k get secret "$name" >/dev/null 2>&1 \
    || head -c 32 /dev/urandom | od -An -vtx1 | tr -d ' \n' | k create secret generic "$name" --from-file=credential=/dev/stdin >/dev/null
done
wd="$(k get secret keyryx-wardryx-client -o jsonpath='{.data.credential}' | base64 -d | sha256sum | cut -d' ' -f1)"
td="$(k get secret keyryx-trailryx-client -o jsonpath='{.data.credential}' | base64 -d | sha256sum | cut -d' ' -f1)"
sed -e "s/@WARDRYX_DIGEST@/$wd/" -e "s/@TRAILRYX_DIGEST@/$td/" "$ROOT/keyryx/policy.json.tmpl" >/tmp/policy.json
k create configmap keyryx-policy --from-file=policy.json=/tmp/policy.json --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -f "$ROOT/keyryx/manifests/59-keyryx.yaml" 2>&1 | grep -iv 'unchanged' | grep -i 'warning\|forbidden\|error' && fail "the apply printed a warning or a refusal" || ok "59-keyryx.yaml applied under restricted with no warning"
if k rollout status deployment/keyryx-custody --timeout=300s >/dev/null; then ok "custody v0.2.0 is Ready"; else fail "custody is not Ready"; k describe pod -l app=keyryx-custody | tail -20; k logs deploy/keyryx-custody --all-containers --tail=30; fi
k rollout status deployment/keyryx-witness --timeout=300s >/dev/null && ok "the witness is Ready" || fail "the witness is not Ready"
k get pods -o wide
k logs deploy/keyryx-custody -c precreate-streams
k logs deploy/keyryx-custody -c keyryx | grep -i 'announcing to' | tail -1
k logs deploy/keyryx-custody -c keyryx | grep -q 'announcing to /var/lib/stack/events/keyryx-custody.ndjson' \
  && ok "custody announces to /var/lib/stack/events/keyryx-custody.ndjson" || fail "custody does not say it announces there"
out="$(probe_root probe-file 'stat -c "%n %u:%g:%a %h" /bus/custody/keyryx-custody.ndjson')"
printf '%s\n' "$out"
grep -q 'keyryx-custody.ndjson 20101:10001:640 1$' <<<"$out" && ok "the stream is 20101:10001 0640 with one link" || fail "the stream is not 20101:10001 0640 with one link"

step "3. rotate and revoke on the admin socket, as custody's uid"
k exec deploy/keyryx-custody -c keyryx -- id 2>/dev/null || echo "(no id in the distroless image)"
before="$(k exec deploy/keyryx-custody -c keyryx -- keyryx admin rotate wardryx-approval 2>&1)"; rc=$?
printf 'rotate: %s (exit %s)\n' "$before" "$rc"
[ $rc -eq 0 ] && ok "keyryx admin rotate wardryx-approval answered" || fail "keyryx admin rotate failed"
kid="$(grep -oE '"(old|previous|retired)_?kid"[^"]*"[^"]+"' <<<"$before" | sed -E 's/.*"([^"]+)"$/\1/' | sed -n 1p)"
[ -n "$kid" ] || kid="$(grep -oE '"kid"[^"]*"[^"]+"' <<<"$before" | sed -E 's/.*"([^"]+)"$/\1/' | sed -n 1p)"
echo "revoking kid $kid"
rv="$(k exec deploy/keyryx-custody -c keyryx -- keyryx admin revoke "$kid" 2>&1)"; rc=$?
printf 'revoke: %s (exit %s)\n' "$rv" "$rc"
[ $rc -eq 0 ] && ok "keyryx admin revoke answered" || fail "keyryx admin revoke failed"
sleep 3

step "4. a reader shaped as heraldyx's patch"
k delete pod reader --ignore-not-found --wait=true >/dev/null 2>&1
k apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: reader, namespace: $NS }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, supplementalGroups: [10001], seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: c
      image: $BUSYBOX
      command: ["sh", "-c", "cat /var/lib/stack/keyryx-custody/keyryx-custody.ndjson; echo; if echo x >> /var/lib/stack/keyryx-custody/keyryx-custody.ndjson 2>/dev/null; then echo APPENDED; else echo append-refused; fi; if : > /var/lib/stack/keyryx-custody/planted 2>/dev/null; then echo CREATED; else echo create-refused; fi"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      volumeMounts: [{ name: events, mountPath: /var/lib/stack/keyryx-custody, subPath: custody, readOnly: true }]
  volumes:
    - name: events
      persistentVolumeClaim: { claimName: stack-events }
YAML
wait_done reader 120
out="$(k logs reader)"; printf '%s\n' "$out"
grep -q '"type":"key_rotated"' <<<"$out" && ok "the reader reads key_rotated" || fail "no key_rotated line"
grep -q '"type":"key_revoked"' <<<"$out" && ok "the reader reads key_revoked" || fail "no key_revoked line"
grep -q 'append-refused' <<<"$out" && grep -q 'create-refused' <<<"$out" && ok "the reader can neither append nor add a name" || fail "the reader wrote"

step "5. another plane's identity, custody/ mounted read-write"
k delete pod other --ignore-not-found --wait=true >/dev/null 2>&1
k apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: other, namespace: $NS }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 20001, runAsGroup: 20001, supplementalGroups: [10001], seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: c
      image: $BUSYBOX
      command: ["sh", "-c", "if echo x >> /c/keyryx-custody.ndjson 2>/dev/null; then echo APPENDED; else echo append-refused; fi; if : > /c/keyryx-custody.ndjson.new 2>/dev/null; then echo CREATED; else echo create-refused; fi; if mv /c/keyryx-custody.ndjson /c/moved 2>/dev/null; then echo RENAMED; else echo rename-refused; fi"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      volumeMounts: [{ name: events, mountPath: /c, subPath: custody }]
  volumes:
    - name: events
      persistentVolumeClaim: { claimName: stack-events }
YAML
wait_done other 120
out="$(k logs other)"; printf '%s\n' "$out"
[ "$(tr '\n' ' ' <<<"$out")" = "append-refused create-refused rename-refused " ] && ok "another plane cannot append, add or rename in custody/" || fail "another plane changed custody/"

step "6. heraldyx v0.10.0 reads custody's stream as the patch names it"
HIMG="$(img heraldyx "$ROOT/manifests/45-heraldyx.yaml")"
echo "image $HIMG"
k delete pod heraldyx-once --ignore-not-found --wait=true >/dev/null 2>&1
k apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: heraldyx-once, namespace: $NS }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, supplementalGroups: [10001], seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: heraldyx
      image: $HIMG
      args: ["--once", "--from-now=false"]
      env:
        - { name: HERALDYX_EVENTS, value: "/var/lib/stack/keyryx-custody/keyryx-custody.ndjson" }
        - { name: HERALDYX_STATE, value: "/work/state.json" }
        - { name: HERALDYX_MIN_SEVERITY, value: "high" }
        - { name: HERALDYX_TO, value: "ops@example.invalid" }
        - { name: HERALDYX_MAIL_FILE, value: "/work/mail.txt" }
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      volumeMounts:
        - { name: events, mountPath: /var/lib/stack/keyryx-custody, subPath: custody, readOnly: true }
        - { name: work, mountPath: /work }
    - name: show
      image: $BUSYBOX
      command: ["sh", "-c", "for i in \$(seq 60); do [ -s /work/mail.txt ] && break; sleep 2; done; cat /work/mail.txt"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      volumeMounts: [{ name: work, mountPath: /work }]
  volumes:
    - name: events
      persistentVolumeClaim: { claimName: stack-events }
    - name: work
      emptyDir: { sizeLimit: 8Mi }
YAML
wait_done heraldyx-once 180
k logs heraldyx-once -c heraldyx | tail -8
mail="$(k logs heraldyx-once -c show)"; printf '%s\n' "$mail" | sed -n 1,40p
grep -qi 'revok' <<<"$mail" && ok "heraldyx wrote the mail for key_revoked" || fail "heraldyx wrote no mail for key_revoked"

step "7. custody restarted keeps its stream"
k rollout restart deployment/keyryx-custody >/dev/null
k rollout status deployment/keyryx-custody --timeout=300s >/dev/null && ok "custody started again" || fail "custody did not start again"
out="$(probe_root probe-again 'stat -c "%n %u:%g:%a %h" /bus/custody/keyryx-custody.ndjson; grep -c "" /bus/custody/keyryx-custody.ndjson')"
printf '%s\n' "$out"
grep -q 'keyryx-custody.ndjson 20101:10001:640 1$' <<<"$out" && ok "the stream is kept, 20101:10001 0640" || fail "the stream changed across a restart"
run_owner "third run, over a custody/ that holds a stream"

step "8. the console image genaryx v0.1.0, as verdryx-slo runs it"
CIMG="$(img genaryx "$ROOT/manifests/20-console.yaml")"
echo "image $CIMG"
k delete pod console-image --ignore-not-found --wait=true >/dev/null 2>&1
k apply -f - <<YAML >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: console-image, namespace: $NS }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 20020, runAsGroup: 20020, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: c
      image: $CIMG
      command: ["/bin/sh", "-c"]
      args:
        - |
          set -u
          genaryx-web --version
          verdryx --help >/dev/null 2>&1 && echo "verdryx answers"
          wardryx --version 2>&1 | head -1
          tokenfuse constants 2>&1 | head -1
          trailryx-verify --version 2>&1 | head -1
          umask 077; genaryx-web preview-key --out /work/preview.key >/work/recipient; echo "preview-key exit \$?"; wc -c </work/recipient
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      volumeMounts: [{ name: work, mountPath: /work }]
  volumes:
    - name: work
      emptyDir: { medium: Memory, sizeLimit: 4Mi }
YAML
wait_done console-image 300
out="$(k logs console-image)"; printf '%s\n' "$out"
grep -q '^genaryx-web 0\.1\.0' <<<"$out" && ok "genaryx-web 0.1.0 answers" || fail "genaryx-web did not answer 0.1.0"
grep -q 'verdryx answers' <<<"$out" && ok "verdryx answers (the quality-drift CronJob and verdryx-slo run it)" || fail "verdryx did not answer"
grep -q 'preview-key exit 0' <<<"$out" && ok "genaryx-web preview-key made a key (the mint lib/preview-mint.sh runs)" || fail "preview-key failed"

step "result"
k get pods -o wide
echo "RUN_EXIT=$([ "$FAILS" -eq 0 ] && echo 0 || echo 1) ($FAILS failed)"
