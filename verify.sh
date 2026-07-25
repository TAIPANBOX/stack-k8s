#!/usr/bin/env bash
# Prove a cluster is actually running this stack, not merely green.
#
#   ./verify.sh                 # read-only checks
#   ./verify.sh --freeze        # also freeze an agent, restart the policy
#                               # plane, and prove the freeze survived
#
# Written to be cloud-agnostic on purpose: it speaks kubectl and nothing else,
# so the same run produces comparable output on Hetzner, on EKS and on GKE.
# See PORTABILITY.md for what the three runs are meant to be compared on.
#
# Exit status is the number of failed checks, so CI can use it directly.
set -uo pipefail

NS="${NS:-agent-stack}"
KUBECTL="${KUBECTL:-kubectl}"
DO_FREEZE=0
[ "${1:-}" = "--freeze" ] && DO_FREEZE=1

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
kc()   { $KUBECTL -n "$NS" "$@"; }

# Everything that talks to a plane runs INSIDE the console pod, because that is
# the only pod the NetworkPolicy admits to them. A check that had to weaken a
# policy to run would be checking a different cluster than the one you ship.
inpod() { kc exec deploy/genaryx-console -- python3 -c "$1" 2>/dev/null; }

head_ "nodes"
$KUBECTL get nodes -o custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].type,PROVIDER:.spec.providerID,IP:.status.addresses[0].address
notready="$($KUBECTL get nodes --no-headers 2>/dev/null | grep -cv ' Ready ')"
[ "${notready:-1}" = 0 ] && ok "every node Ready" || bad "$notready node(s) not Ready"

head_ "pods"
kc get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,STATUS:.status.phase
notrunning="$(kc get pods --no-headers 2>/dev/null | grep -cv ' Running ')"
[ "${notrunning:-1}" = 0 ] && ok "every pod Running" || bad "$notrunning pod(s) not Running"

# One node holding every pod is a five-node cluster with one node's worth of
# resilience (GOTCHAS 17), so this is a check, not a cosmetic note.
nodes_used="$(kc get pods -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -c .)"
[ "${nodes_used:-0}" -gt 1 ] && ok "workload spread over $nodes_used nodes" \
  || bad "every pod is on one node: check the podAntiAffinity patch"

head_ "storage"
kc get pvc -o custom-columns=CLAIM:.metadata.name,MODE:.spec.accessModes,CLASS:.spec.storageClassName,STATUS:.status.phase,SIZE:.status.capacity.storage
rwx_status="$(kc get pvc stack-events -o jsonpath='{.status.phase}' 2>/dev/null)"
[ "$rwx_status" = "Bound" ] && ok "the RWX event volume is Bound" \
  || bad "stack-events is '$rwx_status': without RWX the planes cannot share the event log"
defaults="$($KUBECTL get sc -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null | grep -c true)"
[ "${defaults:-0}" -le 1 ] && ok "$defaults default StorageClass" \
  || bad "$defaults default StorageClasses: a claim with no class name is a coin toss (GOTCHAS 3)"

head_ "network policy is actually enforced"
np="$(kc get networkpolicy --no-headers 2>/dev/null | grep -c .)"
[ "${np:-0}" -gt 0 ] && ok "$np NetworkPolicies present" || bad "no NetworkPolicies"
# Accepted-but-ignored policies are the failure this checks for (GOTCHAS 2):
# the API server takes every NetworkPolicy, `get networkpolicy` lists them, and
# a CNI without an implementation enforces none of them.
#
# The probe runs from the console, which is allowed to reach the three planes
# and NOT the policy store - only wardryx may open 5432, because anything that
# can reach Postgres can rewrite what the fleet is permitted to do without
# passing the PDP. So a console that CAN connect there means the policies are
# decoration. It runs from the console because that is the one pod in the
# namespace with an interpreter: the planes are distroless by design and have
# no shell to probe from.
denied="$(inpod "
import socket
s = socket.socket(); s.settimeout(5)
try:
    s.connect(('policy-db', 5432)); print('REACHED')
except Exception:
    print('blocked')
")"
[ "$denied" = "blocked" ] && ok "default-deny holds (the console cannot reach the policy store)" \
  || bad "the console reached policy-db:5432 ($denied): NetworkPolicy is not being enforced"

head_ "every plane answers"
out="$(inpod "
import os, urllib.request
for n,u in [('cloud',   'http://tokenfuse-cloud:8080/healthz'),
            ('gateway', 'http://tokenfuse-gateway:4100/healthz'),
            ('wardryx', 'http://wardryx:8090/healthz'),
            ('idryx',   'http://idryx:8081/healthz'),
            ('console', 'http://127.0.0.1:7420/healthz')]:
    try:
        print(n, urllib.request.urlopen(u, timeout=6).status)
    except Exception as e:
        print(n, 'FAIL', e)
")"
echo "$out" | sed 's/^/  /'
echo "$out" | grep -q FAIL && bad "a plane did not answer" || ok "all five planes answer 200"

head_ "the data the console governs"
inpod "
import os, urllib.request, json
def g(host, path, key=True):
    h = {'Authorization': 'Bearer ' + os.environ.get('TOKENFUSE_CLOUD_ADMIN_KEY','')} if key else {}
    return json.loads(urllib.request.urlopen(urllib.request.Request(host+path, headers=h), timeout=30).read())
runs = g('http://tokenfuse-cloud:8080', '/v1/runs')
al   = g('http://tokenfuse-cloud:8080', '/v1/alerts')
pol  = g('http://wardryx:8090', '/v1/policies')
apr  = g('http://wardryx:8090', '/v1/approvals') or []
ids  = g('http://idryx:8081', '/api/identities', False)
print('  money    %d runs, \$%.2f settled, %d budget alerts' % (len(runs), sum(r.get('spent_microusd',0) for r in runs)/1e6, len(al)))
print('  policy   %d policies (%d console blocks), %d approvals' % (len(pol), sum(1 for p in pol if p['id'].startswith('console-block')), len(apr)))
print('  identity %d identities' % len(ids))
"

head_ "the console is reading a real environment, not fixtures"
# GOTCHAS 16: with no descriptor the bus serves DEMO fixtures and the Graph
# draws agents that do not exist. `kind` is the only thing that says so.
bus="$(kc exec deploy/genaryx-console -- sh -c 'echo' >/dev/null 2>&1; kc get cm stack-environment -o jsonpath='{.data}' 2>/dev/null | head -c 1)"
[ -n "$bus" ] && ok "an environment descriptor is mounted" \
  || bad "no stack-environment ConfigMap: the bus will run on demo fixtures"

if [ "$DO_FREEZE" = 1 ]; then
  head_ "freeze, restart, and check the freeze survived"
  AGENT="${AGENT:-agent://meridian.example/treasury/reconciliation-batch}"
  inpod "
import os, urllib.request, json
H={'Authorization':'Bearer ' + os.environ.get('WARDRYX_ADMIN_KEY',''),'Content-Type':'application/json'}
def post(p,b):
    return json.loads(urllib.request.urlopen(urllib.request.Request('http://wardryx:8090'+p,data=json.dumps(b).encode(),headers=H),timeout=15).read())
probe={'agent_id':'$AGENT','run_id':'verify-probe','model':'gpt-4o','est_cost_usd':0.42,'tool_names':['ledger_read'],'steps':3}
print('  before restart, the PDP says:', post('/v1/decide',probe)['decision'])
"
  echo "  restarting the policy plane..."
  kc delete pod -l app=wardryx --wait=true >/dev/null 2>&1
  kc rollout status deploy/wardryx --timeout=180s >/dev/null 2>&1
  sleep 5
  after="$(inpod "
import os, urllib.request, json
H={'Authorization':'Bearer ' + os.environ.get('WARDRYX_ADMIN_KEY',''),'Content-Type':'application/json'}
probe={'agent_id':'$AGENT','run_id':'verify-probe-2','model':'gpt-4o','est_cost_usd':0.42,'tool_names':['ledger_read'],'steps':3}
r=json.loads(urllib.request.urlopen(urllib.request.Request('http://wardryx:8090/v1/decide',data=json.dumps(probe).encode(),headers=H),timeout=20).read())
print(r['decision'])
")"
  if [ "$after" = "deny" ]; then
    ok "the freeze survived a policy-plane restart"
  else
    bad "after the restart the PDP says '$after': the block did not survive (GOTCHAS 14)"
  fi
fi

head_ "result"
printf '  %d passed, %d failed\n\n' "$pass" "$fail"
exit "$fail"
