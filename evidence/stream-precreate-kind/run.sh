#!/usr/bin/env bash
# CLAUDE.md invariant 59, measured. Two v2 writers, wardryx and agent-conform, each run twice on
# an empty stack-events volume that holds one stream with a broken prev_hash:
#   unfixed  the pods as manifests/ stood before the initContainers (red)
#   fixed    the pods with each writer's initContainers copied out of manifests/ (green)
# Needs KUBECONFIG pointing at a cluster you may create namespaces in (kind is enough). It deletes
# the two namespaces it creates and nothing else. Prints one block per run; tee it into output.txt.
set -uo pipefail
cd "$(dirname "$0")"
: "${KUBECONFIG:?point KUBECONFIG at a kind cluster}"
B=busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e

wait_phase() { # ns pod phase timeout
	local i=0
	while [ "$i" -lt "$4" ]; do
		[ "$(kubectl -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)" = "$3" ] && return 0
		sleep 2; i=$((i + 2))
	done
	return 1
}

for mode in unfixed fixed; do
	ns="ev-$mode"
	echo "===== $mode ($ns) ====="
	kubectl wait --for=delete "namespace/$ns" --timeout=300s >/dev/null 2>&1
	kubectl create ns "$ns" >/dev/null
	cat <<YAML | kubectl -n "$ns" apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: stack-events
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata:
  name: seed-break
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, fsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: seed
      image: $B
      command:
        - sh
        - -c
        - |
          cat > /var/lib/stack/events/tokenfuse.ndjson <<'EOF'
          {"schema":"taipanbox.dev/agent-event/v0.2","ts":"2026-07-24T12:00:00Z","source":"tokenfuse","type":"budget_exhausted","agent_id":"agent://acme.example/support/tier1-bot","severity":"critical","run_id":"run-0001","data":{"n":1}}
          {"schema":"taipanbox.dev/agent-event/v0.2","ts":"2026-07-24T12:00:01Z","source":"tokenfuse","type":"budget_exhausted","agent_id":"agent://acme.example/support/tier1-bot","severity":"critical","run_id":"run-0001","prev_hash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","data":{"n":2}}
          EOF
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
      volumeMounts: [{ name: events, mountPath: /var/lib/stack/events }]
  volumes: [{ name: events, persistentVolumeClaim: { claimName: stack-events } }]
YAML
	wait_phase "$ns" seed-break Succeeded 180 && echo "seeded: one stream, second line's prev_hash is all zeros"

	python3 pods.py "$mode" | sed "s/namespace: ev-test/namespace: $ns/" | kubectl -n "$ns" apply -f - >/dev/null

	if [ "$mode" = fixed ]; then
		kubectl -n "$ns" wait --for=condition=Ready pod/wardryx --timeout=180s >/dev/null 2>&1 \
			&& echo "wardryx: Ready" || echo "wardryx: NOT ready"
		echo "wardryx init (precreate-streams) log:"
		kubectl -n "$ns" logs wardryx -c precreate-streams 2>&1 | grep 'wardryx.ndjson' | sed 's/^/  /'
	else
		wait_phase "$ns" wardryx Failed 180 && echo "wardryx: Failed (exit $(kubectl -n "$ns" get pod wardryx -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}'))" \
			|| echo "wardryx: did not fail within 180 s"
		kubectl -n "$ns" logs wardryx 2>&1 | grep "open events writer" | sed 's/^/  /'
	fi

	wait_phase "$ns" agent-conform Failed 180 || wait_phase "$ns" agent-conform Succeeded 1
	echo "agent-conform: phase $(kubectl -n "$ns" get pod agent-conform -o jsonpath='{.status.phase}') exit $(kubectl -n "$ns" get pod agent-conform -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
	kubectl -n "$ns" logs agent-conform -c agent-conform 2>&1 | grep -v '^NOTE' | sed 's/^/  /' | tail -4

	echo "stack-events after both runs:"
	kubectl -n "$ns" run lsvol --rm -i --restart=Never --image="$B" --overrides='{"spec":{"securityContext":{"runAsUser":65532,"runAsGroup":65532,"fsGroup":10001},"containers":[{"name":"lsvol","image":"'"$B"'","command":["sh","-c","ls -ln /var/lib/stack/events"],"volumeMounts":[{"name":"events","mountPath":"/var/lib/stack/events"}]}],"volumes":[{"name":"events","persistentVolumeClaim":{"claimName":"stack-events"}}]}}' 2>/dev/null \
		| grep -E '^[-d]' | awk '!seen[$0]++' | sed 's/^/  /'
	kubectl delete ns "$ns" --wait=false >/dev/null 2>&1
done
