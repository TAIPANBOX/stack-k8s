#!/usr/bin/env bash
# The bus owner and a link a producer plants (GOTCHAS 164, the owner's second half). wardryx's group may
# write the policy archive and the chain verifier's group may write conform/, so either can plant a
# symbolic link where the owner writes a temp file while it copies the old layout in. Each run below:
#   1. a volume with an old-layout archive version and verifier state at its root;
#   2. the owner runs once;
#   3. as wardryx: remove the copied version, link `.copy.tmp` to typryx.ndjson;
#      as the verifier: remove its state, link `agent-conform.state.json.tmp` to vouchryx.ndjson;
#   4. the owner runs again; then typryx.ndjson and vouchryx.ndjson are read back.
# Expected of a sound owner: both streams keep 20000:<their producer> 0664 and stay empty.
#
#   KUBECONFIG=... SC=stack-rwx ./owner-symlink.sh <bus manifest> [label]
set -uo pipefail
: "${KUBECONFIG:?point KUBECONFIG at the stand}"
MAN="${1:?the bus manifest to take the owner from}"
LABEL="${2:-$MAN}"
SC="${SC:-stack-rwx}"
NS=g316-sym
B=busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
OWNER_GROUPS='[20001, 20002, 20005, 20010, 20012, 20013, 20020, 20030, 20040, 10002, 10003]'

pod() { # name uid gid supp subpath mountpath cmd
	kubectl -n $NS delete pod "$1" --ignore-not-found --wait=true >/dev/null 2>&1
	local sp=""; [ -n "$5" ] && sp=", subPath: $5"
	kubectl -n $NS apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: { name: $1 }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: $2, runAsGroup: $3, supplementalGroups: $4, seccompProfile: { type: RuntimeDefault } }
  containers:
  - name: c
    image: $B
    command: ["sh", "-c", $(printf '%s' "$7" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')]
    securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
    volumeMounts: [{ name: ev, mountPath: $6$sp }]
  volumes: [{ name: ev, persistentVolumeClaim: { claimName: stack-events } }]
YAML
	for _ in $(seq 1 150); do
		case "$(kubectl -n $NS get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null)" in Succeeded|Failed) break ;; esac
		sleep 2
	done
	kubectl -n $NS logs "$1" 2>&1 | sed "s/^/   [$1] /"
}

owner() { # job name
	kubectl -n $NS apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata: { name: $1 }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, runAsUser: 20000, runAsGroup: 10001, supplementalGroups: $OWNER_GROUPS, seccompProfile: { type: RuntimeDefault } }
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
	kubectl -n $NS wait --for=condition=complete "job/$1" --timeout=180s >/dev/null 2>&1 && echo "-- $1: Complete" || echo "-- $1: did not complete"
	kubectl -n $NS logs "job/$1" 2>&1 | grep -E 'copied|not copied|refused|bus ready' | sed "s/^/   [$1] /"
}

echo "== owner from: $LABEL ($SC)"
kubectl delete ns $NS --wait=true --timeout=300s >/dev/null 2>&1
kubectl create ns $NS >/dev/null
kubectl -n $NS apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: stack-events }
spec: { accessModes: [ReadWriteMany], storageClassName: $SC, resources: { requests: { storage: 1Gi } } }
YAML
python3 - "$MAN" <<'PY' | kubectl -n $NS apply -f - >/dev/null
import re, sys
for d in re.split(r"(?m)^---[ \t]*$", open(sys.argv[1]).read()):
    if re.search(r"(?m)^kind: ConfigMap$", d):
        print(re.sub(r"(?m)^  namespace: agent-stack\n", "", d).strip())
PY
pod old-layout 65532 10001 '[]' "" /bus 'umask 027; mkdir -p /bus/wardryx-policy-archive; echo "{\"old\":\"policy\"}" > /bus/wardryx-policy-archive/v1.json; echo "{\"seen\":[\"old\"]}" > /bus/agent-conform.state.json; chmod 0640 /bus/wardryx-policy-archive/v1.json /bus/agent-conform.state.json; echo planted old layout'
owner owner-1
pod as-wardryx 20001 10001 '[20001]' streams /ev 'cd /ev/wardryx-policy-archive && rm -f v1.json && ln -s ../typryx.ndjson .copy.tmp && ls -l .copy.tmp'
pod as-verifier 10002 10002 '[10001]' conform /c 'cd /c && rm -f agent-conform.state.json && ln -s ../streams/vouchryx.ndjson agent-conform.state.json.tmp && ls -l agent-conform.state.json.tmp'
owner owner-2
pod read-back 20000 10001 '[]' streams /ev 'for f in typryx vouchryx; do echo "$f.ndjson: $(stat -c "%u:%g %a" /ev/$f.ndjson), $(wc -c < /ev/$f.ndjson) bytes"; done'
pod as-verifier-2 10002 10002 '[10001]' streams /ev 'if (echo "{\"forged\":true}" >> /ev/vouchryx.ndjson) 2>/dev/null; then echo "the verifier WROTE vouchryx.ndjson"; else echo "the verifier is refused on vouchryx.ndjson"; fi'
kubectl delete ns $NS --wait=false >/dev/null 2>&1
