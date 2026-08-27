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

# One machine registered TWICE. A node name that is not pinned is re-derived at
# boot, and a machine that comes back under a different name leaves its old
# object behind: NotReady for the rest of the cluster's life, still holding the
# pod records it had when it left, and cleaned up by nothing
# (cloud/gcp/evidence/range-2026-08-27/FINDINGS.md, F3, where it held 17).
#
# The provider ID is what makes this exact rather than a guess: it names the
# INSTANCE, so two node objects carrying the same one are two names for one
# machine. Counting NotReady nodes cannot tell that apart from a node that is
# merely down, which is why it is a separate check.
dupe_provider="$($KUBECTL get nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' 2>/dev/null \
  | grep -v '^$' | sort | uniq -d | grep -c . || true)"
if [ "${dupe_provider:-0}" = 0 ]; then
  ok "no machine is registered under two node names"
else
  bad "$dupe_provider machine(s) hold two node objects each: a stale name was left behind, see FINDINGS F3"
fi

# Cluster DNS at one replica means one dead node costs the full not-ready
# toleration in lost name resolution, measured at 298 s on 2026-08-27
# (FINDINGS.md, F2). The installers scale this to two; k3s re-applies its own
# manifest on a version change, so this is here to catch the revert.
dns_replicas="$($KUBECTL -n kube-system get deployment coredns -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
if [ "${nodes_total_early:-$($KUBECTL get nodes --no-headers 2>/dev/null | grep -c .)}" -le 1 ]; then
  note "single-node cluster: cluster DNS cannot be spread, and one replica is all there is to have"
elif [ -z "$dns_replicas" ]; then
  bad "cannot read the coredns replica count: is cluster DNS deployed?"
elif [ "$dns_replicas" -ge 2 ]; then
  ok "cluster DNS has $dns_replicas ready replicas"
else
  bad "cluster DNS has $dns_replicas ready replica: one dead node costs the full 300 s toleration in lost resolution"
fi

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
# Each plane with ITS OWN credential. The money plane and the policy plane do
# not share one, and asking wardryx with the cloud's admin key gets a 401.
#
# This section used to do exactly that, and the way it failed is the reason it
# now reports a verdict. One raised exception ended the whole script before any
# print, `inpod` swallowed stderr, and the section rendered as a heading with
# nothing under it while the run still ended in "14 passed, 0 failed". Silence
# from a check reads as success to everyone including the person who wrote it.
# Measured on a live cluster 2026-08-02, where two of the five calls had been
# 401 for as long as the section has existed.
#
# So: every call is attempted, each failure is named, and the section fails the
# run instead of disappearing from it. That is invariant 5 of this repo, which
# says a verification check must be able to fail.
gov="$(inpod "
import os, urllib.request, json
def g(host, path, key=''):
    h = {'Authorization': 'Bearer ' + os.environ.get(key,'')} if key else {}
    return json.loads(urllib.request.urlopen(urllib.request.Request(host+path, headers=h), timeout=30).read())
CLOUD, POLICY = 'TOKENFUSE_CLOUD_ADMIN_KEY', 'WARDRYX_ADMIN_KEY'
got, bad = {}, []
for name, host, path, key in [
        ('runs',      'http://tokenfuse-cloud:8080', '/v1/runs',       CLOUD),
        ('alerts',    'http://tokenfuse-cloud:8080', '/v1/alerts',     CLOUD),
        ('policies',  'http://wardryx:8090',         '/v1/policies',   POLICY),
        ('approvals', 'http://wardryx:8090',         '/v1/approvals',  POLICY),
        ('identities','http://idryx:8081',           '/api/identities', '')]:
    try:
        got[name] = g(host, path, key) or []
    except Exception as e:
        bad.append('%s: %s' % (name, e))
if 'runs' in got and 'alerts' in got:
    print('  money    %d runs, \$%.2f settled, %d budget alerts' % (len(got['runs']), sum(r.get('spent_microusd',0) for r in got['runs'])/1e6, len(got['alerts'])))
if 'policies' in got:
    print('  policy   %d policies (%d console blocks), %d approvals' % (len(got['policies']), sum(1 for p in got['policies'] if p['id'].startswith('console-block')), len(got.get('approvals', []))))
if 'identities' in got:
    print('  identity %d identities' % len(got['identities']))
for b in bad:
    print('  UNREACHABLE ' + b)
")"
if [ -z "$gov" ]; then
  bad "the console could not be asked what it governs at all: no output from the probe"
else
  echo "$gov" | sed 's/^/  /' | sed 's/^  //'
  if echo "$gov" | grep -q UNREACHABLE; then
    bad "the console cannot read one of the planes it governs"
  else
    ok "the console can read all three planes it governs"
  fi
fi

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
  # Does this notifier have an INPUT at all. Asked as a configuration
  # question, not by looking at the log, because an empty log is ambiguous on
  # purpose: a fresh box that nothing has happened on yet looks exactly like a
  # box whose producers write nowhere. Measured on a live cluster 2026-08-02,
  # where the second was true and had been since the first deploy: the control
  # plane holds every detector worth mailing about and its exporter was never
  # given a path, so it wrote its incidents nowhere and heraldyx read an empty
  # directory for hours. Nothing here reported it.
  #
  # The state volume is the other half. It comes up root-owned, and without
  # fsGroup a process running as 65532 cannot write a file in it, which stays
  # invisible until the first event arrives and then costs the read offset and
  # the dedup counters on every restart.
  exporters=0
  for d in tokenfuse-cloud tokenfuse-gateway wardryx; do
    kc get deploy "$d" >/dev/null 2>&1 || continue
    # Three ways a plane can be told, and all three are read from the LIVE,
    # EFFECTIVE fields: a variable of its own, a serve flag (wardryx takes the
    # path as an argument), or `envFrom` the stack-wiring ConfigMap, which is
    # how the gateway gets it. Checking only a deployment's own env reports the
    # gateway as silent when it is not, and a check that cries wolf teaches an
    # operator to skip the section it lives in.
    #
    # Never `get -o yaml | grep`. That output carries
    # kubectl.kubernetes.io/last-applied-configuration, which is the full text
    # of a PREVIOUS manifest, so a variable that was applied once and removed
    # since still matches and the check passes on configuration that is no
    # longer there. Measured 2026-08-02: this check was written that way and
    # reported the exporter wired seconds after it had been deleted from the
    # deployment. See ../GOTCHAS.md, item 72.
    wired=0
    names="$(kc get deploy "$d" -o jsonpath='{range .spec.template.spec.containers[*].env[*]}{.name}{"\n"}{end}' 2>/dev/null)"
    args="$(kc get deploy "$d" -o jsonpath='{.spec.template.spec.containers[*].args}' 2>/dev/null)"
    froms="$(kc get deploy "$d" -o jsonpath='{range .spec.template.spec.containers[*].envFrom[*]}{.configMapRef.name}{"\n"}{end}' 2>/dev/null)"
    case "$names" in *EVENTS_PATH*) wired=1 ;; esac
    case "$args"  in *"/var/lib/stack/events/"*.ndjson*) wired=1 ;; esac
    if [ "$wired" = 0 ]; then
      case "$froms" in
        *stack-wiring*)
          kc get configmap stack-wiring -o jsonpath='{.data}' 2>/dev/null | grep -q 'EVENTS_PATH' && wired=1 ;;
      esac
    fi
    if [ "$wired" = 1 ]; then
      exporters=$((exporters + 1))
    elif [ "$d" = tokenfuse-cloud ]; then
      # Not a note. This is the plane every incident worth mailing about comes
      # from: budget_exhausted, sustained_loop, fanout_explosion, spend_spike,
      # budget_threshold. Unwired, the notifier is installed, healthy, mounted,
      # authenticated to a mail server, and structurally incapable of ever
      # sending an alert. That is the exact state this cluster shipped in.
      bad "$d writes no agent-events: every incident the notifier exists for is detected there, so it can never send an alert"
    else
      note "$d writes no agent-events: nothing it detects can reach the notifier"
    fi
  done
  if [ "$exporters" -ge 1 ]; then
    ok "$exporters plane(s) are configured to write the shared event log"
  else
    bad "no plane writes the event log: the notifier has no input and will never send anything"
  fi

  fsg="$(kc get deploy heraldyx -o jsonpath='{.spec.template.spec.securityContext.fsGroup}' 2>/dev/null)"
  if [ -n "$fsg" ]; then
    ok "the notifier's state volume is writable by it (fsGroup $fsg)"
  else
    bad "heraldyx has no fsGroup: its state volume comes up root-owned, so read offsets and dedup counters cannot survive a restart"
  fi

  hpod="$(kc get pod -l 'app=heraldyx,role!=security-probe' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"

  # Its own view of its input, against what is actually on the volume. Both
  # halves matter: a notifier watching nothing looks exactly like a quiet fleet
  # from every other angle, and this deployment has now produced that state
  # twice for two unrelated reasons (nothing writing the log, GOTCHAS earlier
  # today; and a shared volume failing stat on its own mount point while
  # listing its contents, GOTCHAS 74).
  if [ -n "$hpod" ] && [ "$CONSOLE_READY" = 1 ]; then
    watching="$(kc logs "$hpod" --tail=50 2>/dev/null | grep -o 'watching [0-9]* file(s)' | tail -1 | awk '{print $2}')"
    present="$(inpod "import glob; print(len(glob.glob('/var/lib/stack/events/*.ndjson')))")"
    # An ABSENT count and a count of zero are different answers, and this
    # check treated them as one. Measured on a live cluster 2026-08-03: a
    # notifier deliberately installed without mail printed no "watching" line
    # at all (fixed in heraldyx, which now reports what it reads whether or not
    # it can send), and this said it "sees none of the 3 event logs that
    # exist". It saw all three. A check must not report a state it did not
    # observe, which is GOTCHAS 73's rule pointed the other way.
    case "${watching:-}" in
      "") note "this notifier build does not report what it watches: nothing to compare against the ${present:-0} log(s) on the volume" ;;
      *)
        if [ "${watching:-0}" = 0 ] && [ "${present:-0}" -gt 0 ]; then
          bad "the notifier sees none of the ${present} event log(s) that exist: its mount answers but its directory does not (GOTCHAS 74)"
        elif [ "${watching:-0}" -lt "${present:-0}" ]; then
          note "the notifier watches ${watching} of ${present} event log(s): a file may have appeared since it last resolved"
        else
          ok "the notifier watches all ${present} event log(s) that exist"
        fi ;;
    esac
  fi
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
