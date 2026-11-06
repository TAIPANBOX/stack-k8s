#!/usr/bin/env bash
# Proves on a live cluster what the agent-pod network confines, and what it does not (CLAUDE.md invariant 77).
#
# WHAT IS PROVEN
#
# manifests/30-network-policy.yaml and manifests/58-agent-tokens-network.yaml apply to the pods of the `agent-stack`
# namespace and to nothing else. This script puts three probes where the answer differs and reports, per target,
# whether a TCP connection opened:
#
#   agent       the overlay's pod (agent-tokens/confined-agent): in agent-stack, labelled taipanbox.dev/agent-token=true.
#               Expected: opens vouchryx:4310, tokenfuse-gateway:4100 and tokenfuse-mcp-broker:4200, and nothing else.
#   unlabelled  a pod in agent-stack that carries no label. Expected: opens nothing (default-deny, DNS aside).
#   outside     a pod in a scratch namespace that has no policy at all. Expected: opens the scratch listener and the
#               external target, and none of the stack's services. It is the control: it shows the network is up, so a
#               refusal elsewhere is the policy and not a dead network, and it shows what an unconfined pod can do,
#               which is what an agent running outside agent-stack is.
#
# The scratch listener (a second namespace, no policy, accepts everything) is the destination that no ingress rule of
# the stack protects, so a refusal from the agent pod to it is EGRESS confinement and cannot be an ingress rule
# of the target. A cluster whose CNI does not enforce NetworkPolicy fails that row: the agent pod reaches it.
#
#   ./agent-tokens/confine-check.sh                              # in-cluster targets only
#   ./agent-tokens/confine-check.sh --external 1.1.1.1:443       # and one address outside the cluster
#   ./agent-tokens/confine-check.sh --keep                       # leave what it created (it prints the removal)
#
# Exit 0: every row was as expected. 1: a row was not, or a policy under test is missing. 2: it could not measure (no
# cluster, no vouchryx or gateway Service, a probe that did not run): this is never a pass. It refuses to start
# when the scratch namespace already exists, because it deletes that namespace afterwards and deletes nothing it
# did not create.
set -uo pipefail

cd "$(dirname "$0")/.."

NS="${NS:-agent-stack}"
KUBECTL="${KUBECTL:-kubectl}"
SCRATCH=agent-confine-scratch
EXTERNAL=""
KEEP=0

die() { printf '%s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --external) [ $# -ge 2 ] || die "--external needs HOST:PORT"; EXTERNAL="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
if [ -n "$EXTERNAL" ] && ! grep -Eq '^[A-Za-z0-9.-]+:[0-9]+$' <<<"$EXTERNAL"; then
  die "--external must be HOST:PORT, not '$EXTERNAL'"
fi

command -v "$KUBECTL" >/dev/null || die "$KUBECTL not found"
"$KUBECTL" version -o json >/dev/null 2>&1 || die "no cluster: set KUBECONFIG. Nothing was measured."

# ---- 1. the policies under test must be there, or there is nothing to measure -------------------
# A policy that is not there is an answer, not a failure to measure: pods of the namespace are not confined as
# manifests/30-network-policy.yaml and manifests/58-agent-tokens-network.yaml say, so this exits 1 and names it.
absent=""
for np in default-deny allow-dns agent-token-pods-egress; do
  "$KUBECTL" -n "$NS" get networkpolicy "$np" >/dev/null 2>&1 || absent="$absent $np"
done
if [ -n "$absent" ]; then
  printf 'FAIL: NetworkPolicy%s missing in %s (manifests/30-network-policy.yaml, manifests/58-agent-tokens-network.yaml), so an agent pod there is not confined.\n' "$absent" "$NS"
  exit 1
fi
for svc in vouchryx tokenfuse-gateway tokenfuse-mcp-broker; do
  "$KUBECTL" -n "$NS" get service "$svc" >/dev/null 2>&1 \
    || die "Service $svc is missing in $NS, so the three allowed paths have nothing to reach. Nothing was measured."
done
if "$KUBECTL" get namespace "$SCRATCH" >/dev/null 2>&1; then
  die "namespace $SCRATCH exists and this script deletes it afterwards; remove it yourself first. Nothing was measured."
fi

agent_existed=0
"$KUBECTL" -n "$NS" get deployment agent-confined >/dev/null 2>&1 && agent_existed=1

cleanup() {
  if [ "$KEEP" = 1 ]; then
    printf '\nkept. To remove: kubectl delete namespace %s; kubectl -n %s delete pod confine-unlabelled' "$SCRATCH" "$NS"
    [ "$agent_existed" = 0 ] && printf '; kubectl delete -k agent-tokens/confined-agent'
    printf '\n'
    return
  fi
  # Waited for, so a second run straight after the first does not meet a namespace that is still terminating.
  "$KUBECTL" -n "$NS" delete pod confine-unlabelled --wait=true --timeout=90s >/dev/null 2>&1
  if [ "$agent_existed" = 0 ]; then
    "$KUBECTL" delete -k agent-tokens/confined-agent --wait=true --timeout=90s >/dev/null 2>&1
    "$KUBECTL" -n "$NS" wait --for=delete pod -l app=agent-confined --timeout=120s >/dev/null 2>&1
  fi
  "$KUBECTL" delete namespace "$SCRATCH" --wait=true --timeout=120s >/dev/null 2>&1
}
trap cleanup EXIT

# ---- 2. the probes -------------------------------------------------------------------------------
pod_yaml() { # name namespace [extra label line]
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $2
  labels: { app: $1 }
spec:
  terminationGracePeriodSeconds: 1
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
      command: ["sleep", "3600"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
EOF
}

{
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $SCRATCH
  labels: { pod-security.kubernetes.io/enforce: restricted }
---
apiVersion: v1
kind: Pod
metadata:
  name: confine-listener
  namespace: $SCRATCH
  labels: { app: confine-listener }
spec:
  terminationGracePeriodSeconds: 1
  automountServiceAccountToken: false
  securityContext: { runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: listener
      image: busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
      command: ["httpd", "-f", "-p", "8080", "-h", "/"]
      ports: [{ containerPort: 8080 }]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
---
apiVersion: v1
kind: Service
metadata:
  name: confine-listener
  namespace: $SCRATCH
spec:
  selector: { app: confine-listener }
  ports: [{ port: 8080, targetPort: 8080 }]
---
EOF
  pod_yaml confine-outside "$SCRATCH"
  printf -- '---\n'
  pod_yaml confine-unlabelled "$NS"
} | "$KUBECTL" apply -f - >/dev/null || die "could not create the probes. Nothing was measured."

# A pod of an earlier run may still be terminating (deleting a Deployment returns before its pods are gone), and a probe
# run in it is killed halfway. Wait for it, and below pick only a pod that is not being deleted.
"$KUBECTL" -n "$NS" wait --for=delete pod -l app=agent-confined --timeout=120s >/dev/null 2>&1
"$KUBECTL" apply -k agent-tokens/confined-agent >/dev/null || die "could not apply agent-tokens/confined-agent. Nothing was measured."
"$KUBECTL" -n "$NS" rollout status deployment/agent-confined --timeout=180s >/dev/null || die "agent-confined did not become ready. Nothing was measured."
"$KUBECTL" -n "$SCRATCH" wait --for=condition=Ready pod/confine-listener pod/confine-outside --timeout=180s >/dev/null || die "the scratch pods did not become ready. Nothing was measured."
"$KUBECTL" -n "$NS" wait --for=condition=Ready pod/confine-unlabelled --timeout=180s >/dev/null || die "confine-unlabelled did not become ready. Nothing was measured."

AGENT_POD="$("$KUBECTL" -n "$NS" get pod -l app=agent-confined -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null | head -1)"
[ -n "$AGENT_POD" ] || die "no agent-confined pod found. Nothing was measured."
LABEL="$("$KUBECTL" -n "$NS" get pod "$AGENT_POD" -o jsonpath='{.metadata.labels.taipanbox\.dev/agent-token}' 2>/dev/null)"
[ "$LABEL" = true ] || die "the agent pod does not carry taipanbox.dev/agent-token=true (it carries '$LABEL'), so the policy under test does not select it. Nothing was measured."

# ---- 3. the matrix -------------------------------------------------------------------------------
measured=0
fails=0
errors=0

# connect <ns> <pod> <host> <port>  prints open | blocked | error: <what kubectl said>
connect() {
  local out err
  err="$(mktemp)"
  out="$("$KUBECTL" -n "$1" exec "$2" -- sh -c "nc -w 3 $3 $4 </dev/null >/dev/null 2>&1; echo \$?" 2>"$err" | tr -d '\r\n')"
  case "$out" in
    0) echo open ;;
    [1-9]*) echo blocked ;;
    *) echo "error: ${out:-no output} $(head -c 200 "$err" | tr '\r\n' '  ')" ;;
  esac
  rm -f "$err"
}

# expect <label> <ns> <pod> <host> <port> <open|blocked>
expect() {
  local label="$1" ns="$2" pod="$3" host="$4" port="$5" want="$6" got
  got="$(connect "$ns" "$pod" "$host" "$port")"
  measured=$((measured + 1))
  if [ "${got#error}" != "$got" ]; then
    errors=$((errors + 1))
    printf '  %-9s %-34s %-8s ERROR   the probe did not run (%s)\n' "$label" "$host:$port" "$want" "${got#error: }"
  elif [ "$got" = "$want" ]; then
    printf '  %-9s %-34s %-8s ok\n' "$label" "$host:$port" "$want"
  else
    fails=$((fails + 1))
    printf '  %-9s %-34s %-8s FAIL    got %s\n' "$label" "$host:$port" "$want" "$got"
  fi
}

PLANES="wardryx:8090 idryx:8081 tokenfuse-cloud:8080 policy-db:5432 genaryx-console:7420"
LISTENER="confine-listener.$SCRATCH.svc.cluster.local:8080"
EXT_HOST="${EXTERNAL%:*}"
EXT_PORT="${EXTERNAL##*:}"

printf 'agent pod %s/%s, labelled taipanbox.dev/agent-token=true\n' "$NS" "$AGENT_POD"
printf '  %-9s %-34s %-8s %s\n' probe target expected result
expect agent "$NS" "$AGENT_POD" vouchryx 4310 open
expect agent "$NS" "$AGENT_POD" tokenfuse-gateway 4100 open
expect agent "$NS" "$AGENT_POD" tokenfuse-mcp-broker 4200 open
for t in $PLANES; do expect agent "$NS" "$AGENT_POD" "${t%:*}" "${t#*:}" blocked; done
expect agent "$NS" "$AGENT_POD" "${LISTENER%:*}" "${LISTENER##*:}" blocked
expect agent "$NS" "$AGENT_POD" kubernetes.default.svc.cluster.local 443 blocked
[ -n "$EXTERNAL" ] && expect agent "$NS" "$AGENT_POD" "$EXT_HOST" "$EXT_PORT" blocked

printf '\npod with no label, in %s\n' "$NS"
expect unlabelled "$NS" confine-unlabelled vouchryx 4310 blocked
expect unlabelled "$NS" confine-unlabelled tokenfuse-gateway 4100 blocked
expect unlabelled "$NS" confine-unlabelled tokenfuse-mcp-broker 4200 blocked
for t in $PLANES; do expect unlabelled "$NS" confine-unlabelled "${t%:*}" "${t#*:}" blocked; done
expect unlabelled "$NS" confine-unlabelled "${LISTENER%:*}" "${LISTENER##*:}" blocked
[ -n "$EXTERNAL" ] && expect unlabelled "$NS" confine-unlabelled "$EXT_HOST" "$EXT_PORT" blocked

printf '\ncontrol: pod in %s, a namespace no policy applies to\n' "$SCRATCH"
expect outside "$SCRATCH" confine-outside "${LISTENER%:*}" "${LISTENER##*:}" open
[ -n "$EXTERNAL" ] && expect outside "$SCRATCH" confine-outside "$EXT_HOST" "$EXT_PORT" open
expect outside "$SCRATCH" confine-outside "vouchryx.$NS.svc.cluster.local" 4310 blocked
expect outside "$SCRATCH" confine-outside "tokenfuse-gateway.$NS.svc.cluster.local" 4100 blocked
expect outside "$SCRATCH" confine-outside "tokenfuse-mcp-broker.$NS.svc.cluster.local" 4200 blocked
for t in $PLANES; do expect outside "$SCRATCH" confine-outside "${t%:*}.$NS.svc.cluster.local" "${t#*:}" blocked; done

# DNS is open to every pod of the namespace (allow-dns in 30): reported, never asserted, because whether a name
# resolves depends on the cluster's upstream resolver and not on the policy under test.
printf '\nDNS (allow-dns opens port 53 to kube-system for every pod in %s; reported, not asserted)\n' "$NS"
for who in "agent:$AGENT_POD" "unlabelled:confine-unlabelled"; do
  for name in vouchryx.$NS.svc.cluster.local example.com; do
    if "$KUBECTL" -n "$NS" exec "${who#*:}" -- sh -c "nslookup $name 2>&1 | grep -q '^Address.*[0-9]'" >/dev/null 2>&1; then
      printf '  %-11s %-44s resolves\n' "${who%%:*}" "$name"
    else
      printf '  %-11s %-44s does not resolve\n' "${who%%:*}" "$name"
    fi
  done
done

printf '\n'
if [ "$errors" -gt 0 ]; then
  printf 'NOT MEASURED: %d of %d probes did not run. This is not a pass.\n' "$errors" "$measured"
  exit 2
fi
if [ "$fails" -gt 0 ]; then
  printf 'FAIL: %d of %d rows were not as expected.\n' "$fails" "$measured"
  exit 1
fi
printf 'OK: %d of %d rows as expected.\n' "$measured" "$measured"
