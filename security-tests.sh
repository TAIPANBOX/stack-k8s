#!/usr/bin/env bash
#
# The probe pods in here run the CONSOLE'S IMAGE, and that is a dependency worth
# knowing about rather than a detail. They need a shell and a python3, they must
# be admissible under the namespace's `restricted` Pod Security, and reusing an
# image the cluster already pulls avoids adding a second thing to trust.
#
# It was `stack/genaryx-console:dev` with `imagePullPolicy: IfNotPresent`, which
# worked only because every deploy built that image onto every node. The day the
# manifests started PULLING the console instead, 2026-09-01, the image stopped
# existing locally and two probe pods stopped starting. The run still said
# `0 failed`, because a probe that cannot start is reported as a note: the only
# visible difference was 24 passed / 5 noted where there had been 27 / 3.
#
# So the image here is the published, pinned one, the same tag the manifests
# name. If that tag moves, move it here too: a probe pod that cannot start
# disables a check without failing anything.
# The security posture of this deployment, asserted rather than described.
#
#   ./security-tests.sh                    # cluster-side checks
#   ./security-tests.sh --nodes ip1,ip2    # plus node-side checks over ssh
#
# `verify.sh` answers "is the stack running". This answers "is it contained":
# what a compromised pod can reach, what leaves the cluster, what an attacker
# with a copy of etcd gets, and whether the hardening the manifests claim is
# actually in force. Every check is a NEGATIVE test where a negative test is
# what proves the point: the interesting result is what fails to connect.
#
# Cloud-agnostic except the two node-side checks, so the same run is comparable
# on Hetzner, EKS and GKE (PORTABILITY.md).
set -uo pipefail

NS="${NS:-agent-stack}"
KUBECTL="${KUBECTL:-kubectl}"
SSH_KEY="${SSH_KEY:-}"
NODES=""
[ "${1:-}" = "--nodes" ] && { NODES="$2"; shift 2; }

pass=0; fail=0; warn=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  \033[33mnote\033[0m %s\n' "$*"; warn=$((warn+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
kc()   { $KUBECTL -n "$NS" "$@"; }

# Where the console actually is. It lives in $NS on a plain install, and in its
# own namespace once the operator tunnel is applied, because the tunnel needs
# capabilities that $NS refuses on purpose (GOTCHAS 46). Every probe below runs
# INSIDE the console pod, so a hardcoded namespace here does not make the
# checks fail honestly: it makes them report that the planes are unreachable
# when the truth is that the prober could not be found. Measured on 2026-07-26:
# six FAILs, all of them "expected open, got no answer", all of them wrong.
CONSOLE_NS="${CONSOLE_NS:-}"
if [ -z "$CONSOLE_NS" ]; then
  if $KUBECTL -n "$NS" get deploy genaryx-console >/dev/null 2>&1; then
    CONSOLE_NS="$NS"
  elif $KUBECTL -n agent-console get deploy genaryx-console >/dev/null 2>&1; then
    CONSOLE_NS="agent-console"
  else
    CONSOLE_NS="$NS"
  fi
fi
kcc()  { $KUBECTL -n "$CONSOLE_NS" "$@"; }
[ "$CONSOLE_NS" = "$NS" ] || printf '  (the console is in %s, probes run there)\n' "$CONSOLE_NS"

# Where the PRIVILEGED half is, which is a different question and the one test
# 5b actually cares about. The capabilities never went away; across three
# shapes they have merely moved. Finding them by looking for the pod that holds
# them, rather than by assuming which namespace that is, is what stops 5b from
# passing because the thing it audits is somewhere it was not told to look.
PRIV_NS="${PRIV_NS:-}"
if [ -z "$PRIV_NS" ]; then
  for cand in agent-tunnel agent-console "$NS"; do
    if $KUBECTL -n "$cand" get deploy -o json 2>/dev/null \
       | grep -q '"NET_ADMIN"'; then PRIV_NS="$cand"; break; fi
  done
fi

# Probes run from the console pod: it is the one pod in the namespace with an
# interpreter (every plane is distroless on purpose), and it is the pod with
# the MOST permissions, so anything it cannot reach, nothing can.
inpod() { kcc exec -i deploy/genaryx-console -- python3 - 2>/dev/null; }

connect_test() {  # host port expect(open|blocked) label
  local host="$1" port="$2" expect="$3" label="$4" got
  # A bare name is a Service in the PLANES namespace. Once the console lives
  # somewhere else, `wardryx` resolves to nothing there, and the probe reports
  # the plane unreachable when the truth is that the NAME was. Qualify it.
  # Anything already carrying a dot is external and left alone.
  case "$host" in
    *.*) ;;
    *) [ "$CONSOLE_NS" = "$NS" ] || host="$host.$NS" ;;
  esac
  got="$(printf 'import socket\ns=socket.socket()\ns.settimeout(6)\ntry:\n    s.connect(("%s",%s)); print("open")\nexcept Exception:\n    print("blocked")\n' "$host" "$port" | inpod)"
  if [ "$got" = "$expect" ]; then ok "$label ($got, as designed)"; else bad "$label: expected $expect, got ${got:-no answer}"; fi
}

head_ "0. the notifier's way out goes outward only"
# heraldyx is the one workload here allowed to open a connection beyond the
# cluster, and its policy narrows that to three mail ports on addresses OUTSIDE
# the private ranges. The claim worth testing is not that mail works, it is
# that the hole does not point INWARD.
#
# The probe wears `app: heraldyx`, because NetworkPolicy selects on labels and
# that is exactly what an attacker with pod-create in this namespace would try.
# If wearing the label were enough to reach a plane, the narrow rule would be
# decoration.
if kc get networkpolicy heraldyx-mail-egress >/dev/null 2>&1; then
  kc delete pod sec-probe-notify --ignore-not-found >/dev/null 2>&1
  cat <<'YAML' | kc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: { name: sec-probe-notify, labels: { app: heraldyx, role: security-probe } }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: ghcr.io/taipanbox/genaryx-console:v0.1.0
      imagePullPolicy: IfNotPresent
      command: ["sleep", "300"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
YAML
  if kc wait --for=condition=Ready pod/sec-probe-notify --timeout=90s >/dev/null 2>&1; then
    notify_out="$(kc exec -i sec-probe-notify -- python3 - <<'PY' 2>/dev/null
import socket
# Inward, on the ports the planes serve and on a mail port: both must fail.
# The second is the interesting one, since the policy allows 587 by PORT, and
# the except block is what stops it reaching a private address on that port.
# NOTE: no apostrophes in this heredoc, see GOTCHAS 71.
targets = [("tokenfuse-cloud",8080),("wardryx",8090),("idryx",8081),
           ("policy-db",5432),("genaryx-console",7420),("wardryx",587)]
for host, port in targets:
    s = socket.socket(); s.settimeout(5)
    try:
        s.connect((host, port)); print(f"REACHED {host}:{port}")
    except Exception:
        print(f"blocked {host}:{port}")
PY
)"
    echo "$notify_out" | sed 's/^/    /'
    if echo "$notify_out" | grep -q REACHED; then
      bad "a pod wearing the notifier's label reached inside the cluster: the egress rule points inward"
    else
      ok "the notifier's egress reaches nothing inside the cluster, on any port"
    fi
    kc delete pod sec-probe-notify --wait=false >/dev/null 2>&1
  else
    note "could not start the notifier probe pod; skipping"
  fi
else
  note "heraldyx is not deployed: no egress rule to test"
fi

head_ "1. a compromised pod in this namespace reaches nothing"
# The strongest containment claim there is: put an attacker INSIDE the trust
# boundary and show the boundary is not the namespace. This pod carries no
# `plane` label, so no policy names it, so default-deny is all that applies.
kc delete pod sec-probe --ignore-not-found >/dev/null 2>&1
cat <<'YAML' | kc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: { name: sec-probe, labels: { role: security-probe } }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: ghcr.io/taipanbox/genaryx-console:v0.1.0
      imagePullPolicy: IfNotPresent
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
YAML
if kc wait --for=condition=Ready pod/sec-probe --timeout=90s >/dev/null 2>&1; then
  probe_out="$(kc exec -i sec-probe -- python3 - <<'PY' 2>/dev/null
import socket
# NOTE: no apostrophes in this heredoc, see GOTCHAS 71.
targets = [("tokenfuse-cloud",8080),("tokenfuse-gateway",4100),("wardryx",8090),
           ("idryx",8081),("genaryx-console",7420),("policy-db",5432)]
for host, port in targets:
    s = socket.socket(); s.settimeout(5)
    try:
        s.connect((host, port)); print(f"REACHED {host}:{port}")
    except Exception:
        print(f"blocked {host}:{port}")
PY
)"
  echo "$probe_out" | sed 's/^/    /'
  if echo "$probe_out" | grep -q REACHED; then
    bad "an unlabelled pod reached a plane: the namespace is acting as a trust boundary"
  else
    ok "an unlabelled pod in the namespace reached none of the six services"
  fi
  kc delete pod sec-probe --wait=false >/dev/null 2>&1
else
  note "could not start the probe pod; skipping the in-namespace containment test"
fi

head_ "2. the console's own reach is exactly what it needs"
connect_test tokenfuse-cloud   8080 open    "console -> money plane"
connect_test wardryx           8090 open    "console -> policy plane"
connect_test idryx             8081 open    "console -> identity plane"
connect_test policy-db         5432 blocked "console -> the policy STORE (only wardryx may)"

head_ "3. nothing leaves the cluster except the metered path"
# The gateway is the only pod with an egress rule to the internet, and only on
# 443. That is what makes "no prompt leaves without being metered" a property
# of the deployment rather than a promise in a README.
connect_test api.anthropic.com 443 blocked "console -> the model provider (must go through the gateway)"
connect_test 1.1.1.1           443 blocked "console -> the open internet"
gw="$(kc exec -i deploy/tokenfuse-gateway -- bash -s <<'SH' 2>/dev/null
probe() { timeout 6 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null && echo "open $1:$2" || echo "blocked $1:$2"; }
probe api.anthropic.com 443
probe api.anthropic.com 80
probe 10.10.0.2 6443
SH
)"
echo "$gw" | sed 's/^/    /'
echo "$gw" | grep -q "^open api.anthropic.com:443" \
  && ok "gateway -> provider on 443 (the metered path is open)" \
  || bad "gateway cannot reach the provider on 443: the gateway is the only way out and it is shut"
echo "$gw" | grep -q "^blocked api.anthropic.com:80" \
  && ok "gateway -> provider on 80 is blocked (443 only)" \
  || bad "gateway reached port 80 outbound: the egress rule is wider than 443"
echo "$gw" | grep -q "^blocked 10.10.0.2:6443" \
  && ok "gateway cannot turn around and hit the cluster's own API" \
  || bad "gateway reached the Kubernetes API: the 0.0.0.0/0 egress rule is missing its private-range exceptions"

head_ "4. the namespace refuses a privileged pod"
# The manifests promise `pod-security.kubernetes.io/enforce: restricted`. This
# asks the API server to prove it, because a label that enforces nothing looks
# identical to one that does until the day it matters.
rejected="$(cat <<'YAML' | kc apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata: { name: sec-privileged }
spec:
  containers:
    - name: p
      image: ghcr.io/taipanbox/genaryx-console:v0.1.0
      securityContext: { privileged: true }
  hostNetwork: true
  hostPID: true
  volumes: [{ name: root, hostPath: { path: / } }]
YAML
)"
if echo "$rejected" | grep -qi "forbidden\|violat\|denied"; then
  ok "a privileged, hostNetwork, hostPath pod was REJECTED by admission"
  echo "$rejected" | tr ',' '\n' | grep -oiE "(privileged|hostNetwork|hostPID|hostPath|allowPrivilegeEscalation|runAsNonRoot|seccompProfile)[^,]*" | head -4 | sed 's/^/    /'
else
  bad "a privileged pod was ACCEPTED: Pod Security admission is not enforcing"
  kc delete pod sec-privileged --ignore-not-found >/dev/null 2>&1
fi

head_ "5. the workload runs as the manifests claim"
bad_specs=0
for kind in deployment statefulset; do
  for name in $(kc get "$kind" -o name 2>/dev/null); do
    spec="$(kc get "$name" -o json)"
    for probe in \
      '.spec.template.spec.securityContext.runAsNonRoot != true|runAsNonRoot' \
      '(.spec.template.spec.containers[]|.securityContext.allowPrivilegeEscalation) != false|allowPrivilegeEscalation' \
      '(.spec.template.spec.containers[]|.securityContext.capabilities.drop|index("ALL")) == null|capabilities drop ALL' \
      '.spec.template.spec.securityContext.seccompProfile.type != "RuntimeDefault"|seccompProfile' \
      '(.spec.template.spec.hostNetwork // false) != false|hostNetwork' \
      '(.spec.template.spec.volumes // [])|map(select(.hostPath))|length > 0|hostPath volume'
    do
      q="${probe%%|*}"; label="${probe##*|}"
      if echo "$spec" | python3 -c "
import json,sys
d=json.load(sys.stdin)
t=d['spec']['template']['spec']
label='$label'
bad=False
if label=='runAsNonRoot': bad = t.get('securityContext',{}).get('runAsNonRoot') is not True
elif label=='allowPrivilegeEscalation': bad = any(c.get('securityContext',{}).get('allowPrivilegeEscalation') is not False for c in t['containers'])
elif label=='capabilities drop ALL': bad = any('ALL' not in (c.get('securityContext',{}).get('capabilities',{}).get('drop') or []) for c in t['containers'])
elif label=='seccompProfile': bad = t.get('securityContext',{}).get('seccompProfile',{}).get('type')!='RuntimeDefault'
elif label=='hostNetwork': bad = bool(t.get('hostNetwork'))
elif label=='hostPath volume': bad = any('hostPath' in v for v in t.get('volumes',[]))
sys.exit(0 if bad else 1)
"; then
        bad "$(basename "$name"): $label"
        bad_specs=$((bad_specs+1))
      fi
    done
  done
done
[ "$bad_specs" = 0 ] && ok "every Deployment and StatefulSet: non-root, no privilege escalation, all capabilities dropped, RuntimeDefault seccomp, no host namespaces, no hostPath"

head_ "5b. the console namespace holds exactly the exceptions it is allowed"
# Tests 4 and 5 above scan ONE namespace, and once the operator tunnel exists
# the console no longer lives in it. Left alone, both would keep passing purely
# by not looking, which is worse than failing: a suite that cannot go red for a
# thing it used to cover has stopped being evidence for it (GOTCHAS 46).
#
# So the exception gets its own test. The console namespace is allowed to break
# `restricted`, because wireguard-go needs NET_ADMIN and /dev/net/tun and the
# console reaches it over a unix socket that cannot cross a pod boundary. It is
# allowed to break it in EXACTLY these ways and no others. Anything new fails
# here, which is the whole point.
# It audits PRIV_NS, not CONSOLE_NS, and those stopped being the same namespace
# the moment the console moved back under enforced `restricted`. Written the
# other way this test would have reported "no exception to audit" while the
# NET_ADMIN, the tun device and the root containers all still existed one
# namespace over: the precise failure the paragraph above was added to prevent,
# recurring inside the fix for it. What is audited is wherever the capabilities
# are, and if they are nowhere then there is genuinely nothing to audit.
if [ "$CONSOLE_NS" = "$NS" ]; then
  ok "the console itself runs inside $NS under enforced restricted"
fi
if [ -z "$PRIV_NS" ]; then
  ok "no namespace holds NET_ADMIN: there is no privileged half to audit"
else
  [ "$PRIV_NS" = "$CONSOLE_NS" ] \
    && echo "    the privileged half shares the console's namespace ($PRIV_NS)" \
    || echo "    the privileged half is in $PRIV_NS, apart from the console in $CONSOLE_NS"
  level="$($KUBECTL get ns "$PRIV_NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)"
  warnl="$($KUBECTL get ns "$PRIV_NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/warn}' 2>/dev/null)"
  echo "    $PRIV_NS: enforce=$level warn=${warnl:-none}"
  [ -n "$warnl" ] && [ "$warnl" != "$level" ] \
    && ok "the exception is announced: every apply prints what a stricter cluster would refuse" \
    || bad "$PRIV_NS has no stricter warn level, so the exception is silent"

  if $KUBECTL -n "$PRIV_NS" get deploy -o json 2>/dev/null | python3 -c "
import json, sys
# Exactly what the tunnel needs, named per container and per volume. Read this
# list as the promise: nothing outside it is permitted to appear.
ALLOWED_CAPS   = {'wg': {'NET_ADMIN'}, 'caddy': {'NET_BIND_SERVICE'}}
ALLOWED_ROOT   = {'wg', 'caddy'}
ALLOWED_VOLS   = {'tun': 'hostPath', 'events': 'nfs'}
bad = []
for d in json.load(sys.stdin)['items']:
    name = d['metadata']['name']
    t = d['spec']['template']['spec']
    for c in t['containers']:
        cn = c['name']
        sc = c.get('securityContext', {})
        caps = set((sc.get('capabilities', {}) or {}).get('add') or [])
        extra = caps - ALLOWED_CAPS.get(cn, set())
        if extra:
            bad.append(f'{name}/{cn} adds unexpected capabilities: {sorted(extra)}')
        if 'ALL' not in ((sc.get('capabilities', {}) or {}).get('drop') or []):
            bad.append(f'{name}/{cn} does not drop ALL')
        if sc.get('allowPrivilegeEscalation') is not False:
            bad.append(f'{name}/{cn} allows privilege escalation')
        root = sc.get('runAsUser') == 0 or sc.get('runAsNonRoot') is False
        if root and cn not in ALLOWED_ROOT:
            bad.append(f'{name}/{cn} runs as root and is not on the list')
    if t.get('hostNetwork') or t.get('hostPID') or t.get('hostIPC'):
        bad.append(f'{name} uses a host namespace, which nothing here needs')
    for v in t.get('volumes', []):
        for kind in ('hostPath', 'nfs'):
            if kind in v and ALLOWED_VOLS.get(v['name']) != kind:
                bad.append(f'{name} volume {v[\"name\"]} is an unexpected {kind}')
for b in bad:
    print('    ' + b)
sys.exit(1 if bad else 0)
"; then
    ok "$PRIV_NS breaks restricted in exactly the documented ways: NET_ADMIN on wg, NET_BIND_SERVICE on caddy, root on those two, the tun device and the shared event log"
  else
    bad "$PRIV_NS has grown a privilege beyond the documented exception"
  fi

  pub="$($KUBECTL -n "$PRIV_NS" get svc -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(' '.join(s['metadata']['name']+':'+s['spec']['type'] for s in d['items'] if s['spec']['type'] in ('LoadBalancer','NodePort')))")"
  [ "$pub" = "genaryx-tunnel:NodePort" ] \
    && ok "the only published Service is the tunnel itself, which answers nothing without a valid key" \
    || bad "unexpected published Services in $PRIV_NS: ${pub:-none}"
fi

head_ "6. nothing in this namespace is published"
published="$(kc get svc -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
out=[s['metadata']['name']+':'+s['spec']['type'] for s in d['items'] if s['spec']['type'] in ('LoadBalancer','NodePort')]
print(' '.join(out))
")"
[ -z "$published" ] && ok "every Service is ClusterIP (the operator reaches the console over their own tunnel)" \
  || note "published Services: $published (deliberate only if you meant to open a public entry point)"

head_ "7. secrets are not readable from a copy of etcd"
# The check that catches the most damaging default: with no encryption
# provider, every Secret sits in etcd as plaintext, so an etcd snapshot, a disk
# image or a backup IS the credential set.
canary="sec-canary-$$"
kc create secret generic "$canary" --from-literal=probe=CANARY-VALUE-CHECK >/dev/null 2>&1
sleep 2

# Reading etcd needs to happen ON a server. Prefer this host when the script is
# already running on one (the common case for k3s, where kubectl lives there),
# and fall back to ssh. An unreachable etcd is reported as UNVERIFIED, never as
# a pass and never as a failure: "I could not look" and "I looked and it was
# plaintext" are different findings, and conflating them is how a suite starts
# lying in whichever direction its author feared least.
ETCD_CERTS=/var/lib/rancher/k3s/server/tls/etcd
etcd_grep() {  # key pattern -> prints match count, or nothing if it could not look
  local key="$1" pat="$2"
  local cmd="D=$ETCD_CERTS; ETCDCTL_API=3 etcdctl --cacert=\$D/server-ca.crt --cert=\$D/client.crt --key=\$D/client.key --endpoints=https://127.0.0.1:2379 get $key 2>/dev/null | grep -ac $pat"
  if [ -d "$ETCD_CERTS" ] && command -v etcdctl >/dev/null 2>&1; then
    bash -c "$cmd" 2>/dev/null
  elif [ -n "$NODES" ]; then
    ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
      ${SSH_KEY:+-i "$SSH_KEY"} "root@${NODES%%,*}" "$cmd" 2>/dev/null
  fi
}
raw="$(etcd_grep "/registry/secrets/$NS/$canary" CANARY-VALUE-CHECK)"

# etcdctl is not on the node in any of the three cloud images this repo has
# run on, so the branch above answered "could not look" on every live cluster
# from 2026-07-25 to 2026-07-26 inclusive: four fresh clusters, four notes, no
# answer. A check that cannot run is a check that is not there.
#
# So when etcdctl is missing, ask the datastore directly. k3s keeps its embedded
# etcd under /var/lib/rancher/k3s/server/db, and a value that is encrypted at
# rest simply is not in those bytes. Two things make this evidence rather than a
# guess: `sync` first, so the write is on disk and not only in memory, and a
# CONTROL grep for the secret's NAME, which must be found. If the name is not
# there either, the search reached nothing and a clean result proves nothing.
if [ -z "$raw" ]; then
  db=/var/lib/rancher/k3s/server/db
  probe() {  # runs locally on a server, or over ssh to the first node
    if [ -d "$db" ]; then bash -c "$1" 2>/dev/null
    elif [ -n "$NODES" ]; then
      ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
        ${SSH_KEY:+-i "$SSH_KEY"} "root@${NODES%%,*}" "$1" 2>/dev/null
    fi
  }
  hits="$(probe "sync; sleep 1; grep -rc CANARY-VALUE-CHECK $db 2>/dev/null | awk -F: '{s+=\$2} END{print s+0}'")"
  ctrl="$(probe "grep -rc $canary $db 2>/dev/null | awk -F: '{s+=\$2} END{print s+0}'")"
  if [ -n "$hits" ] && [ "${ctrl:-0}" -gt 0 ] 2>/dev/null; then
    raw="$hits"
    [ "$raw" = 0 ] && note "read the datastore on disk directly (no etcdctl on this node); control: the Secret's NAME appears $ctrl times, its VALUE none"
  fi
fi

case "$raw" in
  0) ok "a freshly written Secret is NOT plaintext in etcd (an encryption provider is active)" ;;
  "") note "could not read etcd or the datastore on disk: encryption at rest UNVERIFIED" ;;
  *) bad "the Secret is plaintext in etcd, so an etcd snapshot IS the credential set: install the servers with --secrets-encryption (GOTCHAS 18)" ;;
esac
kc delete secret "$canary" --wait=false >/dev/null 2>&1

head_ "8. no credential is hiding in a ConfigMap"
leak="$(kc get cm -o json | python3 -c "
import json,sys,re
d=json.load(sys.stdin)
pat=re.compile(r'(?i)(password|secret|token|bearer|api[_-]?key)\s*[:=]\s*\S{8,}')
hits=[]
for cm in d['items']:
    for k,v in (cm.get('data') or {}).items():
        if isinstance(v,str) and pat.search(v) and 'REPLACE_ME' not in v:
            hits.append(cm['metadata']['name']+'/'+k)
print(' '.join(hits))
")"
[ -z "$leak" ] && ok "no ConfigMap key looks like a credential" || bad "possible credential in a ConfigMap: $leak"

head_ "9. the hosts themselves"
# Local first, ssh second, and silence about what could not be checked. The
# same reasoning as the etcd probe above.
host_check() {  # label runner...
  local label="$1"; shift
  local out; out="$("$@" 2>/dev/null)"
  case "$out" in
    *"passwordauthentication no"*)  ok "$label: sshd refuses passwords" ;;
    *"passwordauthentication yes"*) bad "$label: sshd accepts passwords (PasswordAuthentication no)" ;;
    *) note "$label: could not read sshd config" ;;
  esac
  case "$out" in
    *"etcd_public=0"*) ok "$label: etcd is not listening on a public address" ;;
    *"etcd_public="*)  bad "$label: etcd is listening on a public address" ;;
  esac
}
SSHD_PROBE='sshd -T 2>/dev/null | grep -E "^(permitrootlogin|passwordauthentication)" | tr "\n" " "; echo -n "etcd_public="; ss -ltn 2>/dev/null | grep ":2379" | grep -vcE "127\.0\.0\.1|10\.|\[::1\]" '
if command -v sshd >/dev/null 2>&1; then
  host_check "$(hostname) (local)" bash -c "$SSHD_PROBE"
fi
if [ -n "$NODES" ]; then
  IFS=',' read -r -a NODE_LIST <<< "$NODES"
  for n in "${NODE_LIST[@]}"; do
    host_check "$n" ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
      ${SSH_KEY:+-i "$SSH_KEY"} "root@$n" "$SSHD_PROBE"
  done
fi

head_ "10. a forged pod label buys nothing without a credential"
# GOTCHAS 20, kept as a standing check because it is the attack that worked.
# NetworkPolicy authorises by the label `plane: console`, which a pod assigns to
# ITSELF, so a label is reachability and never identity. What must stop an
# attacker is the bearer; this asserts that it does.
kc delete pod sec-forged --ignore-not-found >/dev/null 2>&1
cat <<'FORGEDYAML' | kc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: { name: sec-forged, labels: { plane: console } }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: forged
      image: ghcr.io/taipanbox/genaryx-console:v0.1.0
      imagePullPolicy: IfNotPresent
      command: ["sleep", "300"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
FORGEDYAML
if kc wait --for=condition=Ready pod/sec-forged --timeout=90s >/dev/null 2>&1; then
  forged="$(kc exec -i sec-forged -- python3 - <<'FORGEDPROBE' 2>/dev/null
import os, socket, urllib.request, urllib.error
s = socket.socket(); s.settimeout(5)
try:
    s.connect(("wardryx", 8090)); print("reach=yes")
except Exception:
    print("reach=no")
print("inherited_credential=" + ("yes" if (os.environ.get("WARDRYX_ADMIN_KEY") or os.environ.get("TOKENFUSE_CLOUD_ADMIN_KEY")) else "no"))
for label, url, method in [("read_policies","http://wardryx:8090/v1/policies","GET"),
                           ("delete_freeze","http://wardryx:8090/v1/policies/console-block-probe","DELETE"),
                           ("read_fleet","http://tokenfuse-cloud:8080/v1/runs","GET")]:
    try:
        req = urllib.request.Request(url, method=method, headers={"Authorization":"Bearer devkey"})
        r = urllib.request.urlopen(req, timeout=10); print(f"{label}={r.status}")
    except urllib.error.HTTPError as e:
        print(f"{label}={e.code}")
    except Exception:
        print(f"{label}=error")
FORGEDPROBE
)"
  echo "$forged" | sed 's/^/    /'
  echo "$forged" | grep -q "inherited_credential=no" \
    && ok "the forged pod inherits no credential from the cluster" \
    || bad "the forged pod inherited an admin credential from its environment"
  if echo "$forged" | grep -qE "read_policies=(200|201)|delete_freeze=(200|204)|read_fleet=200"; then
    bad "a self-labelled pod reached an admin API: a plane is accepting an unauthenticated or devkey bearer (GOTCHAS 20)"
  else
    ok "every admin verb from the forged pod was refused"
  fi
  kc delete pod sec-forged --wait=false >/dev/null 2>&1
else
  note "could not start the forged-label pod; that attack path is unverified here"
fi

head_ "11. the policy plane is on the data path, not only on the console"
# GOTCHAS 21: the enforcement hook is off by default and reads its OWN env var,
# so a cluster can look governed while its traffic is not.
gw_env="$(kc get deploy tokenfuse-gateway -o json | python3 -c "
import json,sys
c=json.load(sys.stdin)['spec']['template']['spec']['containers'][0]
env={e['name']: e.get('value','<ref>') for e in c.get('env',[])}
print(env.get('TOKENFUSE_WARDRYX_MODE','unset'), env.get('TOKENFUSE_WARDRYX_URL','unset'), env.get('TOKENFUSE_WARDRYX_FAILMODE','open'), env.get('TOKENFUSE_UPSTREAM','unset'))
")"
set -- $gw_env
[ "${1:-unset}" = "enforce" ] && ok "the gateway asks the PDP on every call (mode=$1)" \
  || bad "TOKENFUSE_WARDRYX_MODE=${1:-unset}: a frozen agent's live traffic is NOT checked (GOTCHAS 21)"
[ "${2:-unset}" != "unset" ] && ok "the gateway knows where the PDP is ($2)" \
  || bad "TOKENFUSE_WARDRYX_URL is unset: the hook stays off whatever the mode says"
[ "${3:-open}" = "closed" ] && ok "an unreachable PDP denies (failmode=closed)" \
  || note "failmode=${3:-open}: an unreachable PDP will PERMIT calls"
[ "${4:-unset}" != "unset" ] && ok "the gateway has a real upstream ($4)" \
  || bad "TOKENFUSE_UPSTREAM is unset: the gateway answers from a stub and meters invented tokens (GOTCHAS 22)"

head_ "11b. the policy plane has actually decided something"
# 11 reads four environment variables and passes when they are set correctly.
# That is worth checking and it is not the same question as whether a verdict
# was ever obtained. Measured on 2026-08-04: a deployment with all four
# variables right answered every managed call with 403 because the decision
# request was malformed, and 11 stayed green throughout. `failmode=closed`
# turns that into total denial; `failmode=open` would turn the identical fault
# into total bypass. Both look like "policy is working" from outside.
#
# So ask the gateway for one real ALLOW and one real DENY. Neither probe
# reaches the model provider, so neither costs anything:
#
#   ALLOW: a budget smaller than any call. The PDP has to say allow before
#          the ledger gets to say 402, so a 402 IS a positive verdict.
#   DENY:  a tool the shipped policy forbids for agent://mockryx.local/*.
#
# Run from inside the gateway pod against its own port, because this is a
# question about the gateway's decision path and not about who may reach it.
# No curl in that image, so the request is spoken over bash's /dev/tcp.
pdp_out="$(kc exec -i deploy/tokenfuse-gateway -- bash -s <<'PDPPROBE' 2>/dev/null
ask() {
  body="$1"; extra="$2"
  exec 3<>/dev/tcp/127.0.0.1/4100 || { echo "unreachable"; return; }
  printf 'POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nx-api-key: probe\r\nanthropic-version: 2023-06-01\r\ncontent-type: application/json\r\nx-fuse-run-id: sec-probe-pdp\r\nx-fuse-agent-id: agent://mockryx.local/sec-probe\r\n%sContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
    "$extra" "${#body}" "$body" >&3
  timeout 8 cat <&3 2>/dev/null | tr -d '\r'
  exec 3<&- 3>&-
}
tiny='{"model":"claude-haiku-4-5-20251001","max_tokens":8,"messages":[{"role":"user","content":"probe"}]}'
tooled='{"model":"claude-haiku-4-5-20251001","max_tokens":8,"tools":[{"name":"shell_exec","description":"p","input_schema":{"type":"object"}}],"messages":[{"role":"user","content":"probe"}]}'
echo "ALLOWPROBE $(ask "$tiny" 'x-fuse-budget-usd: 0.0000001
' | head -1)"
echo "DENYPROBE $(ask "$tooled" 'x-fuse-budget-usd: 5.0
' | grep -iE '^HTTP/|^x-fuse-wardryx' | tr '\n' ' ')"
PDPPROBE
)"

case "$pdp_out" in
  *"ALLOWPROBE HTTP/1.1 402"*)
    ok "the PDP returned a real ALLOW (a 402 means policy passed and the ledger stopped it)" ;;
  *"ALLOWPROBE HTTP/1.1 403"*)
    bad "every managed call is DENIED: the gateway is not getting verdicts, only failmode (check 11 cannot see this)" ;;
  *unreachable*|"")
    note "could not reach the gateway from its own pod: this check proved nothing" ;;
  *)
    note "unexpected allow-probe result, read it by hand: $(printf '%s' "$pdp_out" | head -1)" ;;
esac

case "$pdp_out" in
  *"DENYPROBE"*"403"*"deny"*)
    ok "the PDP returned a real DENY (forbidden tool refused with x-fuse-wardryx: deny)" ;;
  *"DENYPROBE"*"200"*)
    bad "a tool the policy forbids was ALLOWED: the PDP is answering but not enforcing" ;;
  *)
    note "deny-probe inconclusive, read it by hand: $(printf '%s' "$pdp_out" | grep DENYPROBE || echo none)" ;;
esac

head_ "12. the neighbouring namespaces"
# GOTCHAS 23: this namespace is hardened; a neighbour is the platform's job.
# Reported, not asserted: the suite cannot fix another namespace and must not
# imply the gap is closed.
for ns in $($KUBECTL get ns -o jsonpath='{.items[*].metadata.name}'); do
  case "$ns" in kube-*|calico-*|tigera-*|longhorn-system|"$NS") continue ;; esac
  pss="$($KUBECTL get ns "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)"
  nps="$($KUBECTL -n "$ns" get networkpolicy --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$pss" = "restricted" ] && [ "${nps:-0}" -gt 0 ]; then
    ok "namespace $ns: restricted Pod Security and $nps NetworkPolicies"
  else
    note "namespace $ns: Pod Security '${pss:-none}', $nps NetworkPolicies - a privileged pod can run there (fix: kubectl apply -f manifests/60-harden-neighbours.yaml, read its header first)"
  fi
done

head_ "result"
printf '  %d passed, %d failed, %d noted\n\n' "$pass" "$fail" "$warn"
exit "$fail"
