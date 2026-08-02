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

pass=0; fail=0; warn=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
# For a thing that is neither passing nor broken, usually because the cluster
# is smaller than the property being asked about. Counted separately so it
# cannot quietly inflate the pass count either.
note() { printf '  \033[33mnote\033[0m %s\n' "$*"; warn=$((warn+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
kc()   { $KUBECTL -n "$NS" "$@"; }

# Everything that talks to a plane runs INSIDE the console pod, because that is
# the only pod the NetworkPolicy admits to them. A check that had to weaken a
# policy to run would be checking a different cluster than the one you ship.
inpod() { kc exec deploy/genaryx-console -- python3 -c "$1" 2>/dev/null; }

# Whether there is a console pod to probe FROM at all.
#
# Every check below that reaches a plane runs inside the console, because that
# is the only pod the NetworkPolicy admits to them. When there is no console
# pod, `inpod` fails and prints NOTHING, and a check comparing that empty
# string against an expected answer concludes the worst.
#
# It did exactly that on a live AWS cluster on 2026-08-02: with the console in
# ImagePullBackOff, verify.sh reported "the console reached policy-db:5432 ():
# NetworkPolicy is not being enforced". Nothing had reached anything. The probe
# had not run. That is a check reporting a security failure it did not observe,
# on the single most important claim this deployment makes, which is worse than
# a check that stays silent: somebody would have gone looking for a hole that
# was never there, and somebody else would have stopped believing the suite.
#
# So the console's absence is established ONCE, up front, and the checks that
# need it say "could not run" instead of guessing.
CONSOLE_READY=0
if [ "$(kc get deploy genaryx-console -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" -ge 1 ] 2>/dev/null; then
  CONSOLE_READY=1
fi

head_ "nodes"
$KUBECTL get nodes -o custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].type,PROVIDER:.spec.providerID,IP:.status.addresses[0].address
notready="$($KUBECTL get nodes --no-headers 2>/dev/null | grep -cv ' Ready ')"
[ "${notready:-1}" = 0 ] && ok "every node Ready" || bad "$notready node(s) not Ready"

head_ "pods"
kc get pods -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,STATUS:.status.phase
# `Completed` is not a failure: the CronJobs leave finished pods behind, and so
# does any probe pod a test left. Only count pods that are neither Running nor
# Succeeded.
notrunning="$(kc get pods --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" { n++ } END { print n+0 }')"
[ "${notrunning:-1}" = 0 ] && ok "every pod Running (finished Job pods ignored)" \
  || bad "$notrunning pod(s) neither Running nor Completed"

# One node holding every pod is a five-node cluster with one node's worth of
# resilience (GOTCHAS 17), so this is a check, not a cosmetic note.
#
# Unless the cluster HAS one node, which install.sh supports and says so:
# "one server means one etcd member. Fine for a demo, not HA." Reported as a
# failure there, this was a red line no arrangement of pods could turn green,
# on a topology the installer offers. A check that cannot pass is as useless as
# one that cannot fail; it is just louder.
nodes_total="$($KUBECTL get nodes --no-headers 2>/dev/null | grep -c .)"
nodes_used="$(kc get pods -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -c .)"
if [ "${nodes_total:-0}" -le 1 ]; then
  note "single-node cluster: nothing to spread over, and no resilience to claim"
elif [ "${nodes_used:-0}" -gt 1 ]; then
  ok "workload spread over $nodes_used nodes"
else
  bad "every pod is on one node of $nodes_total: check the podAntiAffinity patch"
fi

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
if [ "$CONSOLE_READY" = 0 ]; then
  note "no console pod: cannot probe the policy store from inside the namespace"
else
  denied="$(inpod "
import socket
s = socket.socket(); s.settimeout(5)
try:
    s.connect(('policy-db', 5432)); print('REACHED')
except Exception:
    print('blocked')
")"
  case "$denied" in
    blocked) ok "default-deny holds (the console cannot reach the policy store)" ;;
    REACHED) bad "the console reached policy-db:5432: NetworkPolicy is not being enforced" ;;
    *)       note "the probe produced no answer ('$denied'), so this says nothing either way" ;;
  esac
fi

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
  # This check has a PRECONDITION it never used to state: the agent has to be
  # frozen already, by somebody clicking Freeze in the console or by a policy
  # put through the admin API. It does not create the block itself, on purpose,
  # because what it is proving is that a block SOMEONE ELSE made survives.
  #
  # Without that precondition the probe answers "allow" both times and the old
  # code reported `the block did not survive`, which names a persistence bug
  # (GOTCHAS 14) that has not happened. Measured on the first GCP cluster,
  # 2026-07-26, on a cluster where nothing had ever been frozen: a clean stack
  # reported a failure, which is the most expensive kind of wrong.
  before="$(inpod "
import os, urllib.request, json
H={'Authorization':'Bearer ' + os.environ.get('WARDRYX_ADMIN_KEY',''),'Content-Type':'application/json'}
probe={'agent_id':'$AGENT','run_id':'verify-probe','model':'gpt-4o','est_cost_usd':0.42,'tool_names':['ledger_read'],'steps':3}
print(json.loads(urllib.request.urlopen(urllib.request.Request('http://wardryx:8090/v1/decide',data=json.dumps(probe).encode(),headers=H),timeout=15).read())['decision'])
")"
  echo "  before restart, the PDP says: $before"
fi

if [ "$DO_FREEZE" = 1 ] && [ "${before:-}" != "deny" ]; then
  note "nothing is frozen, so there is nothing for a restart to lose"
  echo "     Freeze $AGENT in the console (or PUT a policy that denies it) and"
  echo "     run this again. Reporting a pass here would prove nothing, and"
  echo "     reporting a failure would name a bug that has not happened."
  DO_FREEZE=0
fi

if [ "$DO_FREEZE" = 1 ]; then
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

head_ "the notifier"
# Opt-in, so "not deployed" is a correct deployment and not a failure: the
# operator was asked at install time and blank is a real answer.
if ! kc get deploy heraldyx >/dev/null 2>&1; then
  note "heraldyx is not deployed: this box was not asked to write to anyone"
else
  hready="$(kc get deploy heraldyx -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  if [ "${hready:-0}" -ge 1 ]; then ok "the notifier is running"; else bad "heraldyx has no ready replica"; fi

  # The invariant made physical. heraldyx limits MESSAGES and never evidence,
  # and what holds that is not a promise in a README, it is this mount option.
  # Read off the LIVE spec rather than the file in git, because the cluster is
  # what an operator actually has.
  ro="$(kc get deploy heraldyx -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[?(@.name=="events")].readOnly}' 2>/dev/null)"
  if [ "$ro" = "true" ]; then
    ok "the notifier mounts the event log read-only"
  else
    bad "heraldyx's events mount is not readOnly (got '${ro:-unset}'): it could write to the trail it reads"
  fi

  # Its own record, read by the process that owns it. The image has no shell,
  # so this is the only way to see the file without copying a volume out, and
  # the binary exits non-zero on a broken chain. An empty journal exits 0, so
  # reaching the failure branch means a real break rather than a quiet box.
  # The pod by selector, EXCLUDING anything wearing `role=security-probe`.
  #
  # `kc exec deploy/heraldyx` picks any pod matching the deployment's selector,
  # and the notifier's egress probe in security-tests.sh deliberately wears
  # `app: heraldyx`, because that label is how a NetworkPolicy selects it. So
  # while that probe exists, `deploy/heraldyx` can resolve to a pod running the
  # console image, and this check fails with
  # `exec: "/usr/local/bin/service": no such file or directory`, which reads
  # like the notifier is broken. Measured on a live cluster 2026-08-02.
  hpod="$(kc get pod -l 'app=heraldyx,role!=security-probe' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [ -z "$hpod" ]; then
    bad "heraldyx has no pod outside the security probe"
  elif jout="$(kc exec "$hpod" -- /usr/local/bin/service --journal 2>&1)"; then
    echo "$jout" | sed 's/^/    /'
    ok "the dispatch record is intact"
  else
    echo "$jout" | sed 's/^/    /'
    bad "heraldyx reports its own record is not intact"
  fi
fi

head_ "result"
if [ "${warn:-0}" -gt 0 ]; then
  printf '  %d passed, %d failed, %d noted\n\n' "$pass" "$fail" "$warn"
else
  printf '  %d passed, %d failed\n\n' "$pass" "$fail"
fi
exit "$fail"
