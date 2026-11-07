#!/usr/bin/env bash
# The tool hold on a real API server, from a cluster on the last release to a cluster with the floor.
# Local only: a kind cluster on this machine's Docker, nothing billed anywhere.
#
#   ./evidence/tool-hold-kind/run.sh           # creates kind cluster stack-k8s-tool-hold, deletes it after
#   KEEP=1 ./evidence/tool-hold-kind/run.sh    # leaves the cluster up
#
# What runs, cut out of the manifests as they stand: the namespace, the events claim, stack-wiring,
# wardryx-policy, the wardryx Deployment and Service, and the policy store, with Postgres, so the
# schema change at wardryx's first start is a real one. The events claim binds a hostPath volume,
# because kind's storage has no ReadWriteMany class, and wardryx's five WARDRYX_AGENT_TOKEN_ settings
# are cut out, because it reads vouchryx's key set at start and no vouchryx runs here: every call
# comes as a client key. A Deployment named genaryx-console runs the console's pinned image with `sleep`, so tool-hold/agents.sh
# reaches a real pod through a real exec. A launcher needs ssh and a node, so run_launcher() below is
# a launcher's order and nothing else: tool_hold_guard, the apply, tool_hold_settle, on the same
# lib/tool-hold.sh. Prints PASS or FAIL per check, exits 1 on any FAIL, and never prints a key.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd -P)"
CLUSTER="${CLUSTER:-stack-k8s-tool-hold}"
NS=agent-stack
OLD_WARDRYX="ghcr.io/taipanbox/wardryx:v2.5.1@sha256:2d3c0c9c0798156d3f05b82d0e63cf5b38ee4b9875d6bdbac1829f219c26abf7"
FAILS=0
PASSES=0
pass() { echo "PASS  $*"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
check() { # WHAT EXPECTED GOT
  if [ "$2" = "$3" ]; then pass "$1: $3"; else fail "$1: got '$3', want '$2'"; fi
}
head_() { printf '\n== %s\n' "$*"; }
work="$(mktemp -d)"
cleanup() {
  rm -rf "$work"
  if [ "${KEEP:-0}" != 1 ]; then kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
rnd() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
export KUBECONFIG="$work/kubeconfig"
export KUBECTL="kubectl --kubeconfig=$KUBECONFIG"
export TOOL_HOLD_SECONDS=2
k() { kubectl -n "$NS" "$@"; }
k_() { eval "$KUBECTL $*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
. "$ROOT/lib/secret-doc.sh"
. "$ROOT/lib/approver-mint.sh"

# ---- the cluster ---------------------------------------------------------------------------------
printf '%s, %s, on %s\n' "$(kind version)" "$(kubectl version --client 2>/dev/null | sed -n 1p)" "$(date -u +%Y-%m-%d)"
printf 'tree %s\n' "$(git rev-parse --short HEAD)"
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER" --wait 120s >/dev/null 2>&1 || { echo "FAIL  kind create cluster"; exit 1; }
kind get kubeconfig --name "$CLUSTER" >"$KUBECONFIG"
NODE="$CLUSTER-control-plane"
docker exec "$NODE" sh -c 'mkdir -p /var/local/stack-events && chown 0:10001 /var/local/stack-events && chmod 2775 /var/local/stack-events'

python3 - "$ROOT" "$work/new.yaml" "$work/old.yaml" "$OLD_WARDRYX" <<'PY'
import re, sys
root, new, old, old_image = sys.argv[1:5]
def docs(p):
    return [d for d in re.split(r"^---\s*$", open(root + "/manifests/" + p).read(), flags=re.M) if d.strip()]
keep = []
for d in docs("00-base.yaml"):
    if re.search(r"^kind: Namespace", d, re.M):
        keep.append(d)
    elif re.search(r"^kind: PersistentVolumeClaim", d, re.M) and re.search(r"^  name: stack-events$", d, re.M):
        keep.append(d)
    elif re.search(r"^kind: ConfigMap", d, re.M) and re.search(r"^  name: (stack-wiring|wardryx-policy)$", d, re.M):
        keep.append(d)
for d in docs("15-policy-store.yaml"):
    if re.search(r"^kind: (Service|StatefulSet)", d, re.M):
        keep.append(d)
for d in docs("10-planes.yaml"):
    if re.search(r"^kind: Deployment", d, re.M) and re.search(r"^  name: wardryx$", d, re.M):
        keep.append(d)
    if re.search(r"^kind: Service", d, re.M) and re.search(r"^metadata: \{ name: wardryx,", d, re.M):
        keep.append(d)
assert len(keep) == 8, len(keep)
text = "\n---\n".join(keep)
text, cut = re.subn(r"^ +- \{ name: WARDRYX_AGENT_TOKEN_[A-Z_]+, value: .*\n", "", text, flags=re.M)
assert cut == 5, cut
open(new, "w").write(text)
pin = re.search(r"ghcr\.io/taipanbox/wardryx:v[^ \n]+@sha256:[0-9a-f]{64}", text).group(0)
assert text.count(pin) == 1
# The last release: the image before this one. Its Deployment did not name the new ConfigMap.
text = text.replace(pin, old_image).replace("              - configMap: { name: wardryx-tool-hold, optional: true }\n", "")
open(old, "w").write(text)
PY
[ -s "$work/new.yaml" ] && [ -s "$work/old.yaml" ] || { echo "FAIL  could not cut the planes out of the manifests"; exit 1; }
CONSOLE_IMAGE="$(sed -nE 's/^ +image: (ghcr\.io\/taipanbox\/genaryx-console:v[^ ]+@sha256:[0-9a-f]{64})$/\1/p' "$ROOT/manifests/20-console.yaml" | sed -n 1p)"

kubectl apply -f - >/dev/null <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: stack-policy }
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: stack-rwx }
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: stack-events-kind }
spec:
  capacity: { storage: 5Gi }
  accessModes: ["ReadWriteMany"]
  storageClassName: stack-rwx
  hostPath: { path: /var/local/stack-events }
YAML

# ---- a new cluster: the question has nothing to ask --------------------------------------------------
head_ "a new cluster"
out="$( (. "$ROOT/lib/tool-hold.sh"; tool_hold_guard; printf 'guard returned, state=%s on=%s\n' "$TOOL_HOLD_STATE" "$TOOL_HOLD_ON") 2>&1 )"
printf '%s\n' "$out"
check "the guard on a cluster with no namespace" "guard returned, state=absent on=1" "$(tail -n 1 <<<"$out")"

# ---- the last release, with a history ---------------------------------------------------------------
head_ "a cluster on the last release, wardryx v2.5.1, with a history"
kubectl apply -f "$work/old.yaml" >/dev/null || { echo "FAIL  kubectl apply of the last release"; exit 1; }
ADMIN="kind-$(rnd)"; PEP="kind-$(rnd)"; PW="kind$(rnd)"
secret_doc stack-keys cloud_keys="$(rnd):org" cloud_admin="$(rnd)" gateway_admin="$(rnd)" declassify_key="$(rnd)" \
  wardryx_keys="$ADMIN:default:admin,$PEP:default:pep" wardryx_admin="$ADMIN" wardryx_gateway="$PEP" \
  | k create -f - >/dev/null || { echo "FAIL  stack-keys"; exit 1; }
secret_doc stack-policy-db password="$PW" dsn="postgres://wardryx:$PW@policy-db:5432/wardryx?sslmode=disable" approval_secret="$(rnd)$(rnd)" \
  | k create -f - >/dev/null || { echo "FAIL  stack-policy-db"; exit 1; }
approver_mint_settle >/dev/null
k apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: { name: genaryx-console, labels: { app: genaryx-console } }
spec:
  replicas: 1
  selector: { matchLabels: { app: genaryx-console } }
  template:
    metadata: { labels: { app: genaryx-console } }
    spec:
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: console
          image: $CONSOLE_IMAGE
          command: ["sleep", "infinity"]
          env:
            - name: WARDRYX_ADMIN_KEY
              valueFrom: { secretKeyRef: { name: stack-keys, key: wardryx_admin } }
            - name: PROBE_PEP_KEY
              valueFrom: { secretKeyRef: { name: stack-keys, key: wardryx_gateway } }
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
          volumeMounts:
            - { name: events, mountPath: /var/lib/stack/events }
      volumes:
        - name: events
          persistentVolumeClaim: { claimName: stack-events }
YAML
k rollout status statefulset/policy-db --timeout=240s >/dev/null || fail "the policy store did not start"
k rollout status deployment/wardryx --timeout=240s >/dev/null || { fail "wardryx v2.5.1 did not start"; k logs deploy/wardryx --tail=8; exit 1; }
k rollout status deployment/genaryx-console --timeout=420s >/dev/null || { fail "the console pod did not start"; exit 1; }

wardryx_image() { k get deployment wardryx -o 'jsonpath={.spec.template.spec.containers[0].image}'; }
wardryx_pod() { k get pod -l app=wardryx --field-selector=status.phase=Running -o 'jsonpath={.items[*].metadata.uid}'; }
schema() { k exec policy-db-0 -c postgres -- psql -U wardryx -d wardryx -At -c "$1" 2>/dev/null; }
decide() { # AGENT TOOL SOURCE: as the broker asks it, TOOL empty for a model call
  k exec -i deploy/genaryx-console -c console -- python3 - "$1" "$2" "$3" <<'PY'
import json, os, sys, urllib.error, urllib.request
agent, tool, source = sys.argv[1:4]
if tool:
    body = {"agent_id": agent, "run_id": "kind", "tool_names": [tool], "identity_source": source,
            "tool_call": {"name": tool, "target": "t", "arguments": {"a": 1}}}
else:
    body = {"agent_id": agent, "run_id": "kind", "model": "m", "identity_source": source}
request = urllib.request.Request("http://wardryx:8090/v1/decide", data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + os.environ["PROBE_PEP_KEY"], "Content-Type": "application/json"})
try:
    print(json.load(urllib.request.urlopen(request, timeout=10))["decision"])
except urllib.error.HTTPError as err:
    print("http %s %s" % (err.code, err.read()[:200]))
PY
}
BILLING=agent://acme.example/agents/billing
STRANGER=agent://acme.example/agents/stranger
for _ in 1 2 3; do check "2.5.1 allows a tool call" allow "$(decide "$BILLING" lookup_invoice client-key)"; done
check "2.5.1 allows the other tool" allow "$(decide "$BILLING" send_reminder client-key)"
check "2.5.1 allows the drill's tool" allow "$(decide agent://mockryx.local/scenario lookup_order_status client-key)"
check "the store has no pending_key yet" 0 "$(schema "select count(*) from information_schema.columns where table_name='approvals' and column_name='pending_key'")"
before="$(wardryx_pod)"

run_launcher() { # a launcher's order: the guard, the apply, the settle
  (
    . "$ROOT/lib/tool-hold.sh"
    tool_hold_guard
    kubectl apply -f "$work/new.yaml" >/dev/null
    tool_hold_settle
    kubectl -n "$NS" rollout status deployment/wardryx --timeout=240s >/dev/null
    printf 'launcher finished: state was %s, hold %s\n' "$TOOL_HOLD_STATE" "$TOOL_HOLD_ON"
  ) 2>&1
}

head_ "this release, nothing said: the run stops with the list and applies nothing"
out="$(run_launcher)"
printf '%s\n' "$out"
grep -q 'launcher finished' <<<"$out" && fail "the run went on over an ungranted caller"
grep -qE '3 +[0-9TZ:-]+ +lookup_invoice +agent://acme.example/agents/billing$' <<<"$out" && pass "the table names the agent, the tool and the count" || fail "the table does not name the agent"
grep -qF "./tool-hold/agents.sh agent-allow 'agent://acme.example/agents/billing' 'lookup_invoice,send_reminder' --why" <<<"$out" && pass "the stop prints the command to run" || fail "the stop prints no command"
grep -q mockryx <<<"$out" && fail "a seeded drill is on the list" || pass "the seeded drill is not on the list"
grep -q 'Nothing was applied' <<<"$out" && pass "the stop says nothing was applied" || fail "the stop does not say so"
check "wardryx's image after the stop" "$OLD_WARDRYX" "$(wardryx_image)"
check "wardryx's pod after the stop" "$before" "$(wardryx_pod)"
check "the floor's ConfigMap after the stop" "" "$(k get configmap wardryx-tool-hold --ignore-not-found -o name)"
check "the Job after the stop" "" "$(k get job wardryx-tool-hold-ask --ignore-not-found -o name)"
check "the candidate's ConfigMap after the stop" "" "$(k get configmap wardryx-tool-hold-ask --ignore-not-found -o name)"

head_ "TOOL_HOLD=0: the cluster moves, with the hold off"
out="$(TOOL_HOLD=0 run_launcher)"
printf '%s\n' "$out"
grep -q 'launcher finished: state was absent, hold 0' <<<"$out" && pass "the run went through" || fail "the run with TOOL_HOLD=0 stopped"
check "wardryx's image" "$(sed -nE 's/^ +image: (ghcr\.io\/taipanbox\/wardryx:v[^ ]+)$/\1/p' "$work/new.yaml")" "$(wardryx_image)"
check "the schema change at wardryx's first start: the column" 1 "$(schema "select count(*) from information_schema.columns where table_name='approvals' and column_name='pending_key'")"
check "the schema change at wardryx's first start: the two indexes" "approvals_pending approvals_pending_call" "$(schema "select string_agg(indexname, ' ' order by indexname) from pg_indexes where tablename='approvals' and indexname like 'approvals_pending%'")"
check "the ConfigMap keeps the word: no key in it" "" "$(k get configmap wardryx-tool-hold -o jsonpath='{.data}')"
check "with the hold off a stranger's tool call" allow "$(decide "$STRANGER" ask client-key)"

head_ "what the hold would stop, asked with it off, then a grant"
"$ROOT/tool-hold/agents.sh" agent-list
out="$("$ROOT/tool-hold/agents.sh" agent-allow "$BILLING" lookup_invoice,send_reminder --why 'the monthly reminders' --static-key 2>&1)"
printf '%s\n' "$out"
grep -qF 'the tool hold is off on this cluster' <<<"$out" && pass "agent-allow says the hold is off" || fail "agent-allow does not say the hold is off"

head_ "a run that says nothing keeps the word"
out="$(run_launcher)"
printf '%s\n' "$out"
grep -q 'state was off, hold 0' <<<"$out" && pass "the hold stays off, and nothing was asked" || fail "the word was not kept"

head_ "TOOL_HOLD=1: the operator's word over what is left on the list"
# The stranger's call above went through with the hold off, so it is in the history and on the list.
out="$(TOOL_HOLD=1 run_launcher)"
printf '%s\n' "$out"
grep -q 'TOOL_HOLD=1 was said' <<<"$out" && pass "TOOL_HOLD=1 is the operator's word over the stranger on the list" || fail "TOOL_HOLD=1 did not say what it went over"
grep -q 'launcher finished: state was off, hold 1' <<<"$out" && pass "the run went through" || fail "the run with TOOL_HOLD=1 stopped"
k get configmap wardryx-tool-hold -o jsonpath='{.data.tool-hold\.yaml}'
echo
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  got="$(k exec deploy/genaryx-console -c console -- grep -c 'policy_loaded' /var/lib/stack/events/wardryx.ndjson 2>/dev/null || true)"
  [ "${got:-0}" -ge 3 ] && break
  sleep 2
done
check "a tool call of an agent nothing grants" hold "$(decide "$STRANGER" ask client-key)"
check "a model call of that agent" allow "$(decide "$STRANGER" "" client-key)"
check "an id with no scheme" hold "$(decide stranger ask client-key)"
check "a granted tool" allow "$(decide "$BILLING" lookup_invoice client-key)"
check "the agent's tool nothing granted" hold "$(decide "$BILLING" write_ledger client-key)"
check "the drill's tool" allow "$(decide agent://mockryx.local/scenario lookup_order_status client-key)"
check "the drill's denied tool" deny "$(decide agent://mockryx.local/ci shell_exec client-key)"
check "the install check's tool" allow "$(decide agent://local.invalid/install-check ask client-key)"

head_ "one command ends a hold, with no restart"
before="$(wardryx_pod)"
"$ROOT/tool-hold/agents.sh" agent-allow "$STRANGER" ask --why 'the kind run grants this' --static-key
check "the stranger's tool, granted" allow "$(decide "$STRANGER" ask client-key)"
check "wardryx's pod after the grant" "$before" "$(wardryx_pod)"
"$ROOT/tool-hold/agents.sh" agent-list
"$ROOT/tool-hold/agents.sh" agent-deny "$STRANGER" ask --why 'the kind run takes it back'
check "the stranger's tool, taken back" hold "$(decide "$STRANGER" ask client-key)"
check "the record of both" 1 "$(k exec deploy/genaryx-console -c console -- sh -c 'grep -c policy_updated /var/lib/stack/events/wardryx.ndjson | awk "{print (\$1 >= 2)}"')"

head_ "a second run changes nothing"
before="$(wardryx_pod)"
generation="$(k get deployment wardryx -o jsonpath='{.metadata.generation}')"
out="$(run_launcher)"
printf '%s\n' "$out"
check "the deployment's generation" "$generation" "$(k get deployment wardryx -o jsonpath='{.metadata.generation}')"
check "wardryx's pod" "$before" "$(wardryx_pod)"

head_ "TOOL_HOLD=0 takes it out again"
out="$(TOOL_HOLD=0 run_launcher)"
printf '%s\n' "$out"
check "the ConfigMap holds no key" "" "$(k get configmap wardryx-tool-hold -o jsonpath='{.data}')"
sleep 3
check "with the hold out a stranger's tool call" allow "$(decide "$STRANGER" ask client-key)"

printf '\n%s passed, %s failed\n' "$PASSES" "$FAILS"
[ "$FAILS" = 0 ]
