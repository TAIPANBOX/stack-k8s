#!/usr/bin/env bash
# GAPS G3.16, measured on a cluster: who can write, create, rename or remove a stream on the events
# bus, first in the shape the manifests had before this change (red), then in the layout this change
# builds (one uid and one group per producer, the streams in a subdirectory only an owner uid can
# write, every plane mounting that subdirectory and never the volume root).
#
#   KUBECONFIG=... SC=stack-rwx ./run.sh 2>&1 | tee output-stack-rwx.txt
#   KUBECONFIG=... SC=local-path ACCESS=ReadWriteOnce ./run.sh 2>&1 | tee output-local-path.txt
#
# The stand is described in README.md beside this file (k3s and Longhorn at the launcher's pins, in a
# guest on the build machine). The script creates
# and deletes its own namespaces (g316-*) and nothing else. Every probe prints what it expected and
# what it got; a line that starts with UNEXPECTED is a finding.
set -uo pipefail
: "${KUBECONFIG:?point KUBECONFIG at the stand}"
SC="${SC:-stack-rwx}"
ACCESS="${ACCESS:-ReadWriteMany}"
B=busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
WARDRYX=ghcr.io/taipanbox/wardryx:v2.6.1@sha256:2101d23bbe8ecb1b932a530611ffa02f1c7c9b82394c4fa8db238f7d0e7bd667
CLOUD=ghcr.io/taipanbox/tokenfuse-control-plane:v1.24.0@sha256:b05d3d12c61289006308cf94f3ab4edba958faf6575420eb50c93f973fc4a29a
HERE="$(cd "$(dirname "$0")" && pwd)"
# The owner's script is the one manifests/11-bus.yaml ships, cut out of its ConfigMap, never a copy.
BUS_MANIFEST="$HERE/../../manifests/11-bus.yaml"
owner_configmap() {
	python3 - "$BUS_MANIFEST" <<'PY2'
import re, sys
for d in re.split(r"(?m)^---[ \t]*$", open(sys.argv[1]).read()):
    if re.search(r"(?m)^kind: ConfigMap$", d):
        print(re.sub(r"(?m)^  namespace: agent-stack\n", "", d).strip())
PY2
}

say() { printf '\n== %s\n' "$*"; }

# pod NS NAME UID GID SUPP(json list) FSGROUP(or "") SUBPATH(or "") RO(true|false) CMD
pod() {
	local ns=$1 name=$2 uid=$3 gid=$4 supp=$5 fsg=$6 sub=$7 ro=$8 cmd=$9
	local fs="" sp=""
	[ -n "$fsg" ] && fs=", fsGroup: $fsg"
	[ -n "$sub" ] && sp=", subPath: $sub"
	kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=true >/dev/null 2>&1
	kubectl -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $name }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: $uid, runAsGroup: $gid, supplementalGroups: $supp$fs, seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: c
    image: $B
    command: ["sh", "-c", $(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
    securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
    volumeMounts: [{ name: ev, mountPath: /ev, readOnly: $ro$sp }]
  volumes: [{ name: ev, persistentVolumeClaim: { claimName: stack-events } }]
YAML
	local i=0 ph=""
	while [ $i -lt 300 ]; do
		ph="$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)"
		case "$ph" in Succeeded|Failed) break ;; esac
		sleep 2; i=$((i + 2))
	done
	echo "-- pod $name (uid $uid, gid $gid, supplementalGroups $supp${fsg:+, fsGroup $fsg}, mount ${sub:-<volume root>}${sub:+ subPath}, readOnly $ro): $ph"
	kubectl -n "$ns" logs "$name" 2>&1 | sed 's/^/   /'
}

# try LABEL EXPECT(ok|refused) SHELL: one probe inside a pod, reported as expected or UNEXPECTED
TRY='try() { label=$1; want=$2; shift 2; if out=$(sh -c "$*" 2>&1); then got=ok; else got=refused; fi; out=$(printf %s "$out" | tr "\n" " " | cut -c1-110); if [ "$got" = "$want" ]; then echo "expected $want, got $got: $label ${out:+($out)}"; else echo "UNEXPECTED $got (wanted $want): $label ${out:+($out)}"; fi; }'

pvc() {
	kubectl create ns "$1" >/dev/null
	kubectl -n "$1" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: stack-events }
spec: { accessModes: [$ACCESS], storageClassName: $SC, resources: { requests: { storage: 1Gi } } }
YAML
}

cleanup() { for ns in g316-red g316-layout; do kubectl delete ns "$ns" --wait=true --timeout=300s >/dev/null 2>&1; done; }

say "stand"
kubectl version 2>/dev/null | grep -i server
kubectl get csidriver driver.longhorn.io -o jsonpath='driver.longhorn.io fsGroupPolicy={.spec.fsGroupPolicy}{"\n"}' 2>/dev/null
echo "storage class: $SC ($(kubectl get sc "$SC" -o jsonpath='{.provisioner}')), access mode $ACCESS"
cleanup

###############################################################################
say "1. RED: the pods as the manifests had them before this change (stack-k8s 34f669e)"
pvc g316-red
pod g316-red root-probe 20000 10001 '[]' 10001 "" false \
	'ls -land /ev; mount | grep " /ev " | cut -d" " -f1-5; id'
# the gateway's precreate init: uid 10001, gid 10001, umask 027 (manifests/10-planes.yaml)
pod g316-red gateway-precreate 10001 10001 '[]' 10001 "" false \
	'f=/ev/tokenfuse.ndjson; umask 027; : > $f; echo "{\"source\":\"tokenfuse\",\"n\":1}" >> $f; ls -ln $f'
# wardryx's precreate init: uid 65532, container runAsGroup 10001, umask 027; then wardryx appends a line
pod g316-red wardryx-precreate 65532 10001 '[]' 10001 "" false \
	'f=/ev/wardryx.ndjson; umask 027; : > $f; echo "{\"source\":\"wardryx\",\"type\":\"policy_deny\",\"n\":1}" >> $f; ls -ln $f'
# costcrew's pod before this change: uid 65532, gid 65532, fsGroup 65532 (manifests/49-costcrew.yaml)
pod g316-red costcrew-as-before 65532 65532 '[]' 65532 "" false \
	"$TRY
	 try 'append a forged line to wardryx.ndjson, the decision journal' ok 'echo \"{\\\"source\\\":\\\"wardryx\\\",\\\"type\\\":\\\"policy_allow\\\",\\\"forged\\\":true}\" >> /ev/wardryx.ndjson'
	 echo '   wardryx.ndjson now:'; sed 's/^/     /' /ev/wardryx.ndjson"
# typryx's pod before this change: uid 65532, gid 65532, fsGroup 10001 (manifests/51-typryx.yaml)
pod g316-red typryx-as-before 65532 65532 '[]' 10001 "" false \
	"$TRY
	 id
	 try 'append to wardryx.ndjson (same uid 65532, group 10001)' ok 'echo \"{\\\"forged\\\":2}\" >> /ev/wardryx.ndjson'
	 try 'rename the gateway stream tokenfuse.ndjson (uid 10001) away' ok 'mv /ev/tokenfuse.ndjson /ev/.tokenfuse.gone'
	 try 'put a forged tokenfuse.ndjson in its place' ok 'echo \"{\\\"source\\\":\\\"tokenfuse\\\",\\\"forged\\\":true}\" > /ev/tokenfuse.ndjson'
	 try 'remove a stream of another uid' ok 'rm /ev/.tokenfuse.gone'
	 ls -lan /ev"
kubectl delete ns g316-red --wait=false >/dev/null 2>&1

###############################################################################
say "2. LAYOUT: one owner uid makes streams/ once, each producer its own uid and group, every plane mounts streams/ only"
pvc g316-layout
# A few root-level files as a cluster of the old layout leaves them, to see the owner copy them in.
pod g316-layout old-layout 65532 10001 '[]' 10001 "" false \
	'umask 027; echo "{\"source\":\"wardryx\",\"old\":1}" > /ev/wardryx.ndjson; mkdir -p /ev/wardryx-policy-archive; echo "{}" > /ev/wardryx-policy-archive/v1.json; chmod 0640 /ev/wardryx-policy-archive/v1.json; ls -lanR /ev | grep -v lost'
kubectl -n g316-layout delete job bus-owner --ignore-not-found >/dev/null 2>&1
owner_configmap | kubectl -n g316-layout apply -f - >/dev/null
kubectl -n g316-layout apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: bus-owner }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, runAsUser: 20000, runAsGroup: 10001, supplementalGroups: [20001, 20002, 20005, 20010, 20012, 20013, 20020, 20030, 20040, 10002, 10003], seccompProfile: { type: RuntimeDefault } }
      containers:
      - name: owner
        image: $B
        command: ["sh", "/script/bus-owner.sh"]
        securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
        volumeMounts: [{ name: ev, mountPath: /bus }, { name: script, mountPath: /script, readOnly: true }]
      volumes:
      - { name: ev, persistentVolumeClaim: { claimName: stack-events } }
      - { name: script, configMap: { name: bus-owner } }
YAML
kubectl -n g316-layout wait --for=condition=complete job/bus-owner --timeout=300s >/dev/null 2>&1 && echo "-- job bus-owner: Complete" || echo "UNEXPECTED job bus-owner did not complete"
kubectl -n g316-layout logs job/bus-owner 2>&1 | sed 's/^/   /'
pod g316-layout list-as-owner 20000 10001 '[]' "" "" true 'ls -land /ev /ev/streams /ev/conform; ls -lan /ev/streams /ev/streams/wardryx-policy-archive /ev/conform'

# The owner script refuses a second run over the same volume? It must be idempotent instead.
kubectl -n g316-layout delete job bus-owner --wait=true >/dev/null 2>&1
kubectl -n g316-layout get job -o name >/dev/null
kubectl -n g316-layout apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: bus-owner-again }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, runAsUser: 20000, runAsGroup: 10001, supplementalGroups: [20001, 20002, 20005, 20010, 20012, 20013, 20020, 20030, 20040, 10002, 10003], seccompProfile: { type: RuntimeDefault } }
      containers:
      - name: owner
        image: $B
        command: ["sh", "/script/bus-owner.sh"]
        securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
        volumeMounts: [{ name: ev, mountPath: /bus }, { name: script, mountPath: /script, readOnly: true }]
      volumes:
      - { name: ev, persistentVolumeClaim: { claimName: stack-events } }
      - { name: script, configMap: { name: bus-owner } }
YAML
kubectl -n g316-layout wait --for=condition=complete job/bus-owner-again --timeout=300s >/dev/null 2>&1 && echo "-- job bus-owner-again (second run on the same volume): Complete" || echo "UNEXPECTED second run did not complete"
kubectl -n g316-layout logs job/bus-owner-again 2>&1 | tail -3 | sed 's/^/   /'

say "2a. a producer appends to its own stream through its group"
pod g316-layout wardryx-producer 20001 10001 '[20001]' "" streams false \
	"$TRY
	 id
	 try 'wardryx (20001) appends to wardryx.ndjson' ok 'echo \"{\\\"source\\\":\\\"wardryx\\\",\\\"n\\\":2}\" >> /ev/wardryx.ndjson'
	 try 'wardryx adds a version to its policy archive' ok 'echo \"{}\" > /ev/wardryx-policy-archive/.v2.tmp && chmod 0640 /ev/wardryx-policy-archive/.v2.tmp && mv /ev/wardryx-policy-archive/.v2.tmp /ev/wardryx-policy-archive/v2.json'
	 ls -ln /ev/wardryx.ndjson /ev/wardryx-policy-archive"

say "2b. another producer can neither write another plane's stream nor change a name in the bus directory"
pod g316-layout costcrew-producer 10003 10001 '[10003]' "" streams false \
	"$TRY
	 id
	 try 'costcrew (10003) appends to its own costcrew.ndjson' ok 'echo \"{\\\"source\\\":\\\"costcrew\\\"}\" >> /ev/costcrew.ndjson'
	 try 'append a forged line to wardryx.ndjson' refused 'echo forged >> /ev/wardryx.ndjson'
	 try 'truncate wardryx.ndjson' refused ': > /ev/wardryx.ndjson'
	 try 'create a new stream file' refused 'echo x > /ev/costcrew2.ndjson'
	 try 'rename wardryx.ndjson away' refused 'mv /ev/wardryx.ndjson /ev/w.gone'
	 try 'remove wardryx.ndjson' refused 'rm -f /ev/wardryx.ndjson; [ ! -e /ev/wardryx.ndjson ]'
	 try 'make a directory' refused 'mkdir /ev/x'
	 try 'chmod wardryx.ndjson' refused 'chmod 0666 /ev/wardryx.ndjson'
	 try 'link a stream under a new name' refused 'ln /ev/wardryx.ndjson /ev/w2.ndjson'
	 try 'add a version to wardryx policy archive' refused 'echo x > /ev/wardryx-policy-archive/v9.json'
	 try 'rename an archived version' refused 'mv /ev/wardryx-policy-archive/v1.json /ev/wardryx-policy-archive/v0.json'
	 try 'read wardryx.ndjson (the bus is readable to the bus group)' ok 'cat /ev/wardryx.ndjson >/dev/null'"

say "2c. two containers of one pod, each with its own group (the gateway and its verdryx-slo sidecar)"
pod g316-layout gateway-shape 20010 20010 '[10001]' "" streams false \
	"$TRY
	 id
	 try 'gateway (20010:20010) appends to tokenfuse.ndjson' ok 'echo \"{\\\"source\\\":\\\"tokenfuse\\\"}\" >> /ev/tokenfuse.ndjson'
	 try 'gateway appends to verdryx.ndjson, the sidecar s stream' refused 'echo forged >> /ev/verdryx.ndjson'"

say "2d. readers read every stream and write none"
pod g316-layout reader 65532 65532 '[10001]' "" streams true \
	"$TRY
	 id
	 try 'read every stream' ok 'cat /ev/*.ndjson >/dev/null'
	 try 'read the policy archive' ok 'cat /ev/wardryx-policy-archive/*.json >/dev/null'
	 try 'append to wardryx.ndjson' refused 'echo x >> /ev/wardryx.ndjson'"
pod g316-layout reader-rw-mount 65532 65532 '[10001]' "" streams false \
	"$TRY
	 try 'append to wardryx.ndjson, with the mount read-write: the mode alone refuses' refused 'echo x >> /ev/wardryx.ndjson'
	 try 'create a file, mount read-write' refused 'echo x > /ev/r.ndjson'"
pod g316-layout outsider 30000 30000 '[]' "" streams true \
	"$TRY
	 try 'a pod outside the bus group lists the bus' refused 'ls /ev'"

say "2e. the wait init mounts the volume root read only and cannot change it"
pod g316-layout root-readonly 20003 10001 '[]' "" "" true \
	"$TRY
	 try 'rename streams/ at the volume root' refused 'mv /ev/streams /ev/streams.gone'
	 try 'make a new streams.new at the volume root' refused 'mkdir /ev/streams.new'
	 try 'see the owner marker' ok 'test -f /ev/streams/.layout && cat /ev/streams/.layout'"

say "2f. the agent-stack-go v2 writer (wardryx v2.6.1) and tokenfuse (control plane v1.24.0) open a stream they do not own"
kubectl -n g316-layout apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: wardryx }
spec:
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 20001, runAsGroup: 10001, supplementalGroups: [20001], seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: wardryx
    image: $WARDRYX
    args: ["serve", "-addr", "0.0.0.0:8090", "-events", "/var/lib/stack/events/wardryx.ndjson"]
    env:
    - { name: WARDRYX_KEYS, value: "k0123456789abcdef0123456789abcdef:acme:admin" }
    - { name: WARDRYX_POLICY_ARCHIVE, value: "/var/lib/stack/events/wardryx-policy-archive" }
    securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
    volumeMounts: [{ name: ev, mountPath: /var/lib/stack/events, subPath: streams }]
  volumes: [{ name: ev, persistentVolumeClaim: { claimName: stack-events } }]
---
apiVersion: v1
kind: Pod
metadata: { name: cloud }
spec:
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 20013, runAsGroup: 20013, supplementalGroups: [10001], seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: cloud
    image: $CLOUD
    command: ["/usr/local/bin/tokenfuse-cloud"]
    env:
    - { name: PORT, value: "8080" }
    - { name: TOKENFUSE_CLOUD_KEYS, value: "c0123456789abcdef0123456789abcdef:default:admin" }
    - { name: TOKENFUSE_EVENTS_PATH, value: "/var/lib/stack/events/tokenfuse-cloud.ndjson" }
    securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
    volumeMounts: [{ name: ev, mountPath: /var/lib/stack/events, subPath: streams }]
  volumes: [{ name: ev, persistentVolumeClaim: { claimName: stack-events } }]
YAML
kubectl -n g316-layout wait --for=condition=Ready pod/wardryx pod/cloud --timeout=300s 2>&1 | sed 's/^/   /'
sleep 5
echo "-- wardryx log (events and archive lines):"
kubectl -n g316-layout logs wardryx 2>&1 | grep -i -E 'event|archive|listen|error|refus' | head -8 | sed 's/^/   /'
echo "-- tokenfuse-cloud log (the exporter's startup line):"
kubectl -n g316-layout logs cloud 2>&1 | grep -i -E 'agent-event|ndjson|error' | head -5 | sed 's/^/   /'
# a policy decision through wardryx's own API, so the writer appends a line to the file it does not own
kubectl -n g316-layout run curl --rm -i --restart=Never --image="$B" --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":30000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"curl","image":"'"$B"'","command":["sh","-c","wget -q -O- --header \"Authorization: Bearer k0123456789abcdef0123456789abcdef\" --header \"Content-Type: application/json\" --post-data \"{\\\"agent_id\\\":\\\"agent://acme.example/a\\\",\\\"run_id\\\":\\\"run-g316\\\",\\\"tool_names\\\":[\\\"x\\\"]}\" http://'"$(kubectl -n g316-layout get pod wardryx -o jsonpath='{.status.podIP}')"':8090/v1/decide 2>&1 | head -c 300; echo"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' 2>&1 | grep -v '^pod ' | sed 's/^/   decide: /'
pod g316-layout after-writers 65532 65532 '[10001]' "" streams true \
	'ls -ln /ev/wardryx.ndjson /ev/tokenfuse-cloud.ndjson; echo "   wardryx.ndjson lines: $(wc -l < /ev/wardryx.ndjson)"; tail -n 1 /ev/wardryx.ndjson | cut -c1-200'

say "2g. kubelet and a subPath that does not exist yet (why every pod waits for the owner's marker)"
pod g316-layout missing-subpath 20003 10001 '[]' "" not-made-yet true 'ls -land /ev'
pod g316-layout root-after 20000 10001 '[]' "" "" true 'ls -lan /ev | grep -v lost'

say "2h. the AUTH_SYS limit: how many groups of a process the server honours"
pod g316-layout groups-limit 20000 10001 '[30001,30002,30003,30004,30005,30006,30007,30008,30009,30010,30011,30012,30013,30014,30015,30016,30017,30018,30019,30020]' "" "" false \
	'mkdir -p /ev/gtest; cd /ev/gtest; id; ok=""; no=""; for g in $(seq 30001 30020); do : > f$g; if chgrp $g f$g 2>/dev/null; then ok="$ok $g"; else no="$no $g"; fi; done; echo "chgrp honoured for:$ok"; echo "chgrp refused for:${no:- none}"'

say "done"
cleanup
