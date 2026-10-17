#!/usr/bin/env bash
# identity/mint.sh against a real API server, from empty. Local only: a kind
# cluster on this machine's Docker, nothing billed anywhere. CLAUDE.md invariant 50.
#
#   ./evidence/identity-kind/mint.sh            # creates kind cluster stack-k8s-mint, deletes it after
#   KEEP=1 ./evidence/identity-kind/mint.sh     # leaves the cluster up
#
# What runs: the namespace, stack-wiring and the tokenfuse-gateway Deployment and
# Service exactly as manifests/00-base.yaml and manifests/10-planes.yaml declare
# them (the gateway's `events` volume an emptyDir: kind has no ReadWriteMany class),
# stack-keys with throwaway values, and a stand-in genaryx-console (python,
# sleeping) carrying the console's Felyx lines from manifests/20-console.yaml, so
# the key the deploy mints for Felyx reaches a pod the way it reaches the console.
# No wardryx runs, so a call that gets past identity is refused by the policy hook
# (fail closed) or the budget, and either is "past identity" here. Prints PASS/FAIL
# per check, exits 1 on any FAIL, and never prints a client key.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd -P)"
CLUSTER="${CLUSTER:-stack-k8s-mint}"
NS=agent-stack
DOMAIN=kind.example
FAILS=0
PASSES=0
pass() { echo "PASS  $*"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
k() { kubectl --context "kind-$CLUSTER" -n "$NS" "$@"; }
work="$(mktemp -d)"
cleanup() {
  rm -rf "$work"
  if [ "${KEEP:-0}" != 1 ]; then kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
rnd() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER" --wait 120s >/dev/null 2>&1 || { echo "FAIL  kind create cluster"; exit 1; }
kind get kubeconfig --name "$CLUSTER" >"$work/kubeconfig"
export KUBECONFIG="$work/kubeconfig"

python3 - "$ROOT/manifests/00-base.yaml" "$ROOT/manifests/10-planes.yaml" "$ROOT/manifests/20-console.yaml" "$work/stack.yaml" "$DOMAIN" <<'PY'
import re, sys
base, planes, console, out, domain = sys.argv[1:6]
def docs(p):
    return [d for d in re.split(r"^---\s*$", open(p).read(), flags=re.M) if d.strip()]
keep = []
for d in docs(base):
    if re.search(r"^kind: Namespace", d, re.M):
        keep.append(d)
    elif re.search(r"^kind: ConfigMap", d, re.M) and re.search(r"^  name: stack-wiring", d, re.M):
        d, n = re.subn(r"TRAILRYX_TRUST_DOMAIN: \S+", "TRAILRYX_TRUST_DOMAIN: " + domain, d)
        assert n == 1, "stack-wiring's trust domain moved"
        # No control plane runs here, and tokenfuse v1.14.0 refuses a keyed call 503
        # seed_pending until it has read the month from one it was told about. Told about
        # none, it counts units in its own process, which is what this run needs.
        d, n = re.subn(r"TOKENFUSE_CLOUD_URL: \S+", 'TOKENFUSE_CLOUD_URL: ""', d)
        assert n == 1, "stack-wiring's cloud URL moved"
        keep.append(d)
for d in docs(planes):
    named = re.search(r"^  name: tokenfuse-gateway$", d, re.M) or re.search(r"^metadata: \{ name: tokenfuse-gateway,", d, re.M)
    if named and re.search(r"^kind: (Deployment|Service)", d, re.M):
        if "kind: Deployment" in d:
            assert d.count("persistentVolumeClaim: { claimName: stack-events }") == 1, "the gateway's events claim moved"
            d = d.replace("persistentVolumeClaim: { claimName: stack-events }", "emptyDir: {}")
        keep.append(d)
assert len(keep) == 4, len(keep)
# The console's Felyx lines, as 20-console.yaml writes them, on a stand-in.
c = open(console).read()
felyx = re.findall(r"(?m)^( *- \{ name: GENARYX_COPILOT_FUSE_KEY_REF,.*\}\n *- name: GENARYX_COPILOT_FUSE_KEY\n *valueFrom: .*\n)", c)
assert len(felyx) == 1, "the console's Felyx key lines moved"
lines = [l.strip() for l in felyx[0].strip("\n").split("\n")]
env = "\n".join("            " + ("  " + l if l.startswith("valueFrom") else l) for l in lines)
keep.append("""apiVersion: apps/v1
kind: Deployment
metadata: { name: genaryx-console, namespace: agent-stack, labels: { app: genaryx-console } }
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
          image: python:3.12-slim
          command: ["sleep", "infinity"]
          envFrom:
            - configMapRef: { name: stack-wiring }
          env:
            - { name: GENARYX_COPILOT_AGENT_ID, value: "agent://$(TRAILRYX_TRUST_DOMAIN)/genaryx/felyx" }
""" + env + """
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
""")
open(out, "w").write("\n---\n".join(keep))
PY
[ -s "$work/stack.yaml" ] || { echo "FAIL  could not cut the namespace, stack-wiring, the gateway and the console's Felyx lines out of the manifests"; exit 1; }
kubectl apply -f "$work/stack.yaml" >/dev/null || { echo "FAIL  kubectl apply"; exit 1; }
kubectl -n "$NS" create secret generic stack-keys \
  --from-literal=cloud_keys="$(rnd):org" --from-literal=cloud_admin="$(rnd)" \
  --from-literal=wardryx_keys="$(rnd):org:admin" --from-literal=wardryx_admin="$(rnd)" \
  --from-literal=wardryx_gateway="$(rnd)" --from-literal=gateway_admin="$(rnd)" \
  --from-literal=declassify_key="$(rnd)" >/dev/null || { echo "FAIL  stack-keys"; exit 1; }

# ---- 1. before the mint: the gateway does not start without its keys ---------------------
reason=""
for _ in $(seq 1 90); do
  reason="$(k get pods -l app=tokenfuse-gateway -o json 2>/dev/null | python3 -c '
import json, sys
rs = []
for p in json.load(sys.stdin).get("items", []):
    for c in (p.get("status", {}).get("containerStatuses") or []) + (p.get("status", {}).get("initContainerStatuses") or []):
        if c.get("name") == "gateway":
            rs.append(((c.get("state") or {}).get("waiting") or {}).get("reason", "") or next(iter(c.get("state") or {}), ""))
print(" ".join(rs))')"
  case "$reason" in *CreateContainerConfigError*) break ;; esac
  sleep 2
done
case "$reason" in *CreateContainerConfigError*) reason=CreateContainerConfigError ;; esac
[ "$reason" = CreateContainerConfigError ] \
  && pass "with no gateway-client-keys the gateway waits in CreateContainerConfigError, it does not start open" \
  || fail "with no gateway-client-keys the gateway's container is '$reason', not CreateContainerConfigError"

# ---- 2. the mint ---------------------------------------------------------------------------
KF="$work/agent-key"
"$ROOT/identity/mint.sh" --agent-key-file "$KF" >"$work/mint1.out" 2>&1
rc=$?
[ "$rc" = 0 ] && pass "identity/mint.sh minted on an empty cluster" || { fail "identity/mint.sh exited $rc: $(tail -3 "$work/mint1.out" | tr '\n' ' ')"; }
AK="$(cat "$KF" 2>/dev/null)"
SPEC="$(k get secret gateway-client-keys -o jsonpath='{.data.client_keys}' | base64 --decode)"
FK="$(k get secret felyx-client-key -o jsonpath='{.data.client_key}' | base64 --decode)"
leaked() { [ -n "$AK" ] && grep -qF -e "$AK" -e "$FK" "$@"; }
[ "$(stat -f %Lp "$KF" 2>/dev/null || stat -c %a "$KF")" = 600 ] && pass "the agents' key file is 0600" || fail "the agents' key file is not 0600"
[ "$SPEC" = "$FK:felyx,$AK:agents" ] && pass "the Secret holds <felyx>:felyx,<agents>:agents, the file the agents' key, felyx-client-key Felyx's" \
  || fail "the Secret, the file and felyx-client-key do not agree"
[ "$(k get secret gateway-client-keys -o jsonpath='{.metadata.labels.taipanbox\.dev/identity}')" = minted ] && pass "the Secret is labelled minted" || fail "the Secret is not labelled minted"
if leaked "$work/mint1.out"; then fail "a minted key appears in what identity/mint.sh printed"; else pass "identity/mint.sh printed no key"; fi
grep -qF "$KF" "$work/mint1.out" && grep -qF "agent://$DOMAIN/agents/" "$work/mint1.out" \
  && pass "identity/mint.sh named the key file and the agents' ids" || fail "identity/mint.sh did not name the key file or the ids"

k rollout status deployment/tokenfuse-gateway --timeout=240s >/dev/null && pass "the gateway rolled out on the minted keys" || fail "the gateway did not roll out after the mint"
k rollout status deployment/genaryx-console --timeout=240s >/dev/null || fail "the stand-in console did not roll out"
for _ in $(seq 1 60); do [ "$(k get pods -l app=tokenfuse-gateway --no-headers 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && break; sleep 1; done
GWP="$(k get pods -l app=tokenfuse-gateway -o jsonpath='{.items[0].metadata.name}')"
LOG="$(k logs "$GWP" -c gateway 2>/dev/null)"
grep -qF 'client auth: ON (2 key(s))' <<<"$LOG" && pass "the gateway reports client auth ON with 2 keys" || fail "the gateway does not report 2 client keys"
grep -qF 'identity map: ON (2 unit(s), 2 key binding(s)); strict=Enforce' <<<"$LOG" && pass "the gateway reads the minted map, 2 units, 2 bindings, strict=Enforce" || fail "the gateway does not report the minted map strict"
if grep -qE 'has no keys\[\] binding|has no matching TOKENFUSE_CLIENT_KEYS entry' <<<"$LOG"; then fail "the gateway warns about an unbound key or an orphan binding"; else pass "no unbound key and no orphan binding"; fi
[ "$(k exec deploy/genaryx-console -- printenv GENARYX_COPILOT_FUSE_KEY 2>/dev/null)" = "$FK" ] \
  && pass "the console stand-in holds Felyx's minted key, from felyx-client-key" || fail "the console stand-in does not hold Felyx's minted key"

# ---- 3. the calls ----------------------------------------------------------------------------
call() { # key agent: status and error type of a metered call made from the stand-in console
  k exec deploy/genaryx-console -- python3 -c '
import json, sys, urllib.request, urllib.error
h = {"content-type": "application/json", "x-fuse-run-id": "kind-mint-run", "x-fuse-budget-usd": "0.000001"}
if sys.argv[1]:
    h["x-fuse-key"] = sys.argv[1]
if sys.argv[2]:
    h["x-fuse-agent-id"] = sys.argv[2]
b = b"{\"model\":\"claude-haiku-4-5\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"probe\"}]}"
try:
    r = urllib.request.urlopen(urllib.request.Request("http://tokenfuse-gateway:4100/v1/messages", data=b, headers=h), timeout=10)
    print(r.status, "-")
except urllib.error.HTTPError as e:
    t = "-"
    try:
        t = json.loads(e.read()).get("error", {}).get("type", "-")
    except Exception:
        pass
    print(e.code, t)' "$1" "$2" 2>&1
}
a="$(call '' "agent://$DOMAIN/agents/kind")"
b="$(call "$AK" "agent://$DOMAIN/agents/kind")"
c="$(call "$AK" "agent://$DOMAIN/genaryx/felyx")"
d="$(call "$FK" "agent://$DOMAIN/genaryx/felyx")"
e="$(call "$FK" "agent://$DOMAIN/agents/kind")"
echo "      no key: $a | agents' key as an agent: $b | agents' key as Felyx: $c | Felyx's key as Felyx: $d | Felyx's key as an agent: $e"
[ "$a" = "401 unauthorized" ] && pass "a call with no key is refused 401" || fail "a call with no key: $a"
case "$b" in 401*|"403 identity_mismatch") fail "the agents' key speaking as an agent did not get past identity: $b" ;; *) pass "the agents' key speaking as an agent gets past identity ($b)" ;; esac
[ "$c" = "403 identity_mismatch" ] && pass "the agents' key speaking as Felyx is refused 403 identity_mismatch" || fail "the agents' key speaking as Felyx: $c"
case "$d" in 401*|"403 identity_mismatch") fail "Felyx's key speaking as Felyx did not get past identity: $d" ;; *) pass "Felyx's key speaking as Felyx gets past identity ($d)" ;; esac
[ "$e" = "403 identity_mismatch" ] && pass "Felyx's key speaking as an agent is refused 403 identity_mismatch" || fail "Felyx's key speaking as an agent: $e"

# ---- 4. a re-run writes nothing and rolls nothing ---------------------------------------------
before="$(k get secret gateway-client-keys felyx-client-key -o jsonpath='{.items[*].metadata.resourceVersion}') $(k get configmap gateway-identity-map -o jsonpath='{.metadata.resourceVersion}') $(k get deploy tokenfuse-gateway genaryx-console -o jsonpath='{.items[*].metadata.generation}')"
cp "$KF" "$work/key.before"
"$ROOT/identity/mint.sh" --agent-key-file "$KF" >"$work/mint2.out" 2>&1 || fail "the re-run of identity/mint.sh failed: $(tail -2 "$work/mint2.out" | tr '\n' ' ')"
after="$(k get secret gateway-client-keys felyx-client-key -o jsonpath='{.items[*].metadata.resourceVersion}') $(k get configmap gateway-identity-map -o jsonpath='{.metadata.resourceVersion}') $(k get deploy tokenfuse-gateway genaryx-console -o jsonpath='{.items[*].metadata.generation}')"
[ "$before" = "$after" ] && pass "a re-run changed no object and rolled neither Deployment" || fail "a re-run changed something: '$before' then '$after'"
cmp -s "$KF" "$work/key.before" && pass "a re-run kept the agents' key file byte for byte" || fail "a re-run changed the agents' key file"
if leaked "$work/mint2.out"; then fail "a minted key appears in the re-run's output"; fi

# ---- 5. verify.sh's own section ------------------------------------------------------------------
vs="$(NS="$NS" KUBECTL="kubectl --context kind-$CLUSTER" "$ROOT/verify.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | sed -n '/^client keys and the identity map$/,/^the console is reading/p')"
echo "$vs" | sed 's/^/      /'
if grep -qE '^ *FAIL ' <<<"$vs" || ! grep -qE '^ *ok +the gateway refuses a call with no client key' <<<"$vs"; then fail "verify.sh's client keys section reports a failure"; else pass "verify.sh's client keys section passes"; fi
if leaked <(printf '%s' "$vs"); then fail "a minted key appears in verify.sh's output"; fi

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
