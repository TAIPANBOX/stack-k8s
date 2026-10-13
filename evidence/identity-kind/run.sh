#!/usr/bin/env bash
# identity/up.sh against a real API server, from empty. Local only: a kind
# cluster on this machine's Docker, nothing billed anywhere.
#
#   ./evidence/identity-kind/run.sh            # creates kind cluster stack-k8s-identity, deletes it after
#   KEEP=1 ./evidence/identity-kind/run.sh     # leaves the cluster up
#
# What runs: the namespace, stack-wiring and the tokenfuse-gateway Deployment and
# Service exactly as manifests/00-base.yaml and manifests/10-planes.yaml declare
# them, except the gateway's `events` volume, which becomes an emptyDir because
# kind's storage has no ReadWriteMany class (the cluster installers bring
# Longhorn). stack-keys holds throwaway values. A stand-in named genaryx-console
# (python, sleeping) gives verify.sh the pod it asks the planes from; nothing else
# of the stack is installed, so only verify.sh's "client keys and the identity
# map" section is read here. Prints PASS/FAIL per check, exits 1 on any FAIL, and
# never prints a client key.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd -P)"
CLUSTER="${CLUSTER:-stack-k8s-identity}"
NS=agent-stack
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

# ---- the operator's files: throwaway secrets, made here, never printed -------------
rnd() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
K1="kind-$(rnd)"; K2="kind-$(rnd)"; K3="kind-$(rnd)"
printf '%s:treasury-bots\n%s:research-bots\n' "$K1" "$K2" >"$work/keys.txt"
printf '%s:treasury-bots\n%s:research-bots\n%s:treasury-bots\n' "$K1" "$K2" "$K3" >"$work/keys3.txt"
printf '%s:treasury-bots\n%s:research-bots\n%s:orphan\n' "$K1" "$K2" "$K3" >"$work/keys-orphan.txt"
cat >"$work/map.json" <<'JSON'
{
  "units": [
    {"id": "treasury", "budget_usd_month": 20},
    {"id": "research", "budget_usd_month": 5}
  ],
  "keys": [
    {"key_id": "treasury-bots", "unit": "treasury", "agents": ["agent://bank.example/treasury/*"]},
    {"key_id": "research-bots", "unit": "research", "agents": ["agent://bank.example/research/*"]}
  ]
}
JSON
sed 's/"budget_usd_month": 5}/"budget_usd_month": 7}/' "$work/map.json" >"$work/map2.json"
sed 's/"budget_usd_month": 5}/"budget_usd_month": 9}/' "$work/map.json" >"$work/map3.json"
sha() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
up() { (cd "$work" && KUBECONFIG="$work/kubeconfig" NS="$NS" "$ROOT/identity/up.sh" "$@") >"$work/up.out" 2>&1; }
leaked() { grep -qF -e "$K1" -e "$K2" -e "$K3" "$@"; }

# ---- from empty ----------------------------------------------------------------------
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER" --wait 120s >/dev/null 2>&1 || { echo "FAIL  kind create cluster"; exit 1; }
kind get kubeconfig --name "$CLUSTER" >"$work/kubeconfig"
export KUBECONFIG="$work/kubeconfig"

python3 - "$ROOT/manifests/00-base.yaml" "$ROOT/manifests/10-planes.yaml" "$work/stack.yaml" <<'PY'
import re, sys
base, planes, out = sys.argv[1], sys.argv[2], sys.argv[3]
def docs(p):
    return [d for d in re.split(r"^---\s*$", open(p).read(), flags=re.M) if d.strip()]
keep = []
for d in docs(base):
    if re.search(r"^kind: Namespace", d, re.M) or (re.search(r"^kind: ConfigMap", d, re.M) and re.search(r"^  name: stack-wiring", d, re.M)):
        keep.append(d)
for d in docs(planes):
    named = re.search(r"^  name: tokenfuse-gateway$", d, re.M) or re.search(r"^metadata: \{ name: tokenfuse-gateway,", d, re.M)
    if named and re.search(r"^kind: (Deployment|Service)", d, re.M):
        if "kind: Deployment" in d:
            n = d.count("persistentVolumeClaim: { claimName: stack-events }")
            assert n == 1, "the gateway's events claim moved"
            d = d.replace("persistentVolumeClaim: { claimName: stack-events }", "emptyDir: {}")
        keep.append(d)
assert len(keep) == 4, len(keep)
open(out, "w").write("\n---\n".join(keep))
PY
[ -s "$work/stack.yaml" ] || { echo "FAIL  could not cut the namespace, stack-wiring and the gateway out of the manifests"; exit 1; }
kubectl apply -f "$work/stack.yaml" >/dev/null || { echo "FAIL  kubectl apply of the gateway manifests"; exit 1; }
# Every key the manifests read from stack-keys (invariant 17 holds this script to
# that too), throwaway values; the gateway reads four of them.
kubectl -n "$NS" create secret generic stack-keys \
  --from-literal=cloud_keys="$(rnd):org" --from-literal=cloud_admin="$(rnd)" \
  --from-literal=wardryx_keys="$(rnd):org:admin" --from-literal=wardryx_admin="$(rnd)" \
  --from-literal=wardryx_gateway="$(rnd)" --from-literal=gateway_admin="$(rnd)" \
  --from-literal=declassify_key="$(rnd)" >/dev/null || { echo "FAIL  stack-keys"; exit 1; }
kubectl -n "$NS" apply -f - >/dev/null <<'YAML'
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
          image: python:3.12-slim
          command: ["sleep", "infinity"]
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
YAML
k rollout status deployment/tokenfuse-gateway --timeout=240s >/dev/null || { echo "FAIL  the gateway never started"; k describe pods -l app=tokenfuse-gateway | tail -20; exit 1; }
k rollout status deployment/genaryx-console --timeout=240s >/dev/null || { echo "FAIL  the stand-in console never started"; exit 1; }

gwpod() { # the newest Running gateway pod that is not terminating
  k get pods -l app=tokenfuse-gateway -o json | python3 -c '
import json, sys
items = [p for p in json.load(sys.stdin)["items"]
         if p.get("status", {}).get("phase") == "Running" and not p["metadata"].get("deletionTimestamp")]
items.sort(key=lambda p: p["metadata"]["creationTimestamp"])
print(items[-1]["metadata"]["name"] if items else "")'
}
settle() { k rollout status deployment/tokenfuse-gateway --timeout=180s >/dev/null; for _ in $(seq 1 60); do [ "$(k get pods -l app=tokenfuse-gateway --no-headers 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && return 0; sleep 1; done; }
gwlog() { # the gateway container's log, and a FAIL rather than silence when there is none
  local p l
  p="$(gwpod)"
  l="$(k logs "$p" -c gateway 2>/dev/null)"
  case "$l" in *"tokenfuse gateway listening"*) printf '%s\n' "$l" ;; *) echo "NO-GATEWAY-LOG pod='$p'" ;; esac
}
ann() { k get deploy tokenfuse-gateway -o jsonpath="{.spec.template.metadata.annotations.taipanbox\.dev/$1}"; }
rv() { k get "$1" "$2" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null; }
verify_section() { NS="$NS" KUBECTL="kubectl --context kind-$CLUSTER" "$ROOT/verify.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | sed -n '/^client keys and the identity map$/,/^the console is reading/p'; }
call() { # key agent: status and x-fuse of a metered call made from the stand-in console
  k exec deploy/genaryx-console -- python3 -c '
import sys, urllib.request, urllib.error
h = {"content-type": "application/json", "x-fuse-run-id": "kind-identity-run"}
if sys.argv[1]:
    h["x-fuse-key"] = sys.argv[1]
if sys.argv[2]:
    h["x-fuse-agent-id"] = sys.argv[2]
b = b"{\"model\":\"probe\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"probe\"}]}"
try:
    r = urllib.request.urlopen(urllib.request.Request("http://tokenfuse-gateway:4100/v1/messages", data=b, headers=h), timeout=15)
    print(r.status, r.headers.get("x-fuse", "-"), r.read()[:160].decode(errors="replace").replace("\n", " "))
except urllib.error.HTTPError as e:
    print(e.code, e.headers.get("x-fuse", "-"), e.read()[:160].decode(errors="replace").replace("\n", " "))
' "$1" "$2" 2>&1
}

echo "== 1. a cluster that names no file"
p0="$(gwpod)"
l0="$(gwlog)"
if grep -q NO-GATEWAY-LOG <<<"$l0"; then fail "no gateway log to read: $l0"
elif grep -q -e '^client auth: ON' -e '^identity map: ON' <<<"$l0"; then fail "the gateway started with keys or a map nobody gave it"
else pass "the gateway starts with both references optional and absent"; fi
# `ls`, not `ls -A`: the kubelet keeps its own ..data link and a timestamped
# directory in every ConfigMap volume, an empty one included.
[ -z "$(k exec "$p0" -c gateway -- sh -c 'ls /etc/tokenfuse/identity' 2>&1)" ] && pass "the map directory holds no file" || fail "the map directory holds a file: $(k exec "$p0" -c gateway -- sh -c 'ls -A /etc/tokenfuse/identity' 2>&1 | tr '\n' ' ')"
v="$(verify_section)"; echo "$v" | sed 's/^/      /'
grep -q 'FAIL' <<<"$v" && fail "verify.sh reports a failure on a cluster with no files" || pass "verify.sh notes both off"

echo "== 2. keys and a map, given"
if up --client-keys-file keys.txt --identity-map-file map.json; then pass "identity/up.sh ran"; else fail "identity/up.sh: $(tail -3 "$work/up.out")"; fi
settle
p1="$(gwpod)"
[ "$p1" != "$p0" ] && pass "the gateway rolled" || fail "the gateway did not roll"
k get secret gateway-client-keys >/dev/null 2>&1 && pass "Secret gateway-client-keys exists" || fail "no Secret"
[ "$(k get secret gateway-client-keys -o jsonpath='{.metadata.annotations}')" = "" ] && pass "the Secret carries no last-applied copy" || fail "the Secret carries annotations: a second copy of the keys"
[ "$(ann identity-map-sha256)" = "$(sha "$work/map.json")" ] && pass "the template carries the map's sha256" || fail "template map annotation '$(ann identity-map-sha256)'"
[ "$(ann client-keys-version)" = "$(rv secret gateway-client-keys)" ] && pass "the template carries the Secret's resourceVersion" || fail "template keys annotation"
gwlog | grep -q '^client auth: ON (2 key(s))' && pass "the new pod reports 2 client keys" || fail "the new pod does not report 2 keys"
gwlog | grep -q '^identity map: ON (2 unit(s), 2 key binding(s))' && pass "the new pod reports the map" || fail "the new pod does not report the map"
[ "$(k exec "$p1" -c gateway -- cat /etc/tokenfuse/identity/identity.json | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" = "$(sha "$work/map.json")" ] \
  && pass "the mounted map is the file given, byte for byte" || fail "the mounted map differs"
[ "$(k exec "$p1" -c gateway -- sh -c 'ls /etc/tokenfuse/identity')" = "identity.json" ] && pass "the directory holds the map alone" || fail "the directory holds more than the map"
k exec "$p1" -c gateway -- sh -c ': >/etc/tokenfuse/identity/x' >/dev/null 2>&1 && fail "the map directory is writable" || pass "the map directory is read only"
[ "$(k exec "$p1" -c gateway -- sh -c 'printf %s "$TOKENFUSE_IDENTITY_MAP"')" = /etc/tokenfuse/identity/identity.json ] && pass "TOKENFUSE_IDENTITY_MAP comes from the ConfigMap" || fail "TOKENFUSE_IDENTITY_MAP wrong"
leaked "$work/up.out" && fail "identity/up.sh printed a client key" || pass "identity/up.sh printed no client key"
v="$(verify_section)"; echo "$v" | sed 's/^/      /'
grep -q 'FAIL' <<<"$v" && fail "verify.sh reports a failure" || pass "verify.sh: the map and keys match, a call with no key and one with an unknown key are refused by the gateway"
r="$(call "$K1" agent://bank.example/research/r1)"; echo "      treasury key as a research agent: $r"
case "$r" in 403*identity_mismatch*|403*agent_id_not_allowed*) pass "a treasury key speaking as a research agent is refused 403" ;; *) fail "a treasury key as a research agent: $r" ;; esac
r="$(call "$K1" agent://bank.example/treasury/t1)"; echo "      treasury key as a treasury agent: $r"
case "$r" in 401*|403*identity*) fail "a treasury key as its own agent was refused at the identity door: $r" ;; *) pass "a treasury key as its own agent passes the identity door ($(cut -d' ' -f1-2 <<<"$r"))" ;; esac

echo "== 3. a re-run that names no file"
s1="$(rv secret gateway-client-keys)"; c1="$(rv configmap gateway-identity-map)"
up && pass "identity/up.sh ran" || fail "identity/up.sh: $(tail -3 "$work/up.out")"
settle
[ "$(gwpod)" = "$p1" ] && pass "nothing rolled" || fail "the gateway rolled"
[ "$(rv secret gateway-client-keys)" = "$s1" ] && [ "$(rv configmap gateway-identity-map)" = "$c1" ] && pass "neither object was written" || fail "an object was written"

echo "== 4. the same map again, then the deploy's apply again"
up --identity-map-file map.json && pass "identity/up.sh ran" || fail "identity/up.sh: $(tail -3 "$work/up.out")"
settle
[ "$(gwpod)" = "$p1" ] && [ "$(rv configmap gateway-identity-map)" = "$c1" ] && pass "the same map changed nothing" || fail "the same map changed something"
kubectl apply -f "$work/stack.yaml" >/dev/null
settle
[ "$(gwpod)" = "$p1" ] && [ "$(ann identity-map-sha256)" = "$(sha "$work/map.json")" ] && pass "applying the manifests again keeps the annotations and rolls nothing" || fail "applying the manifests again changed the gateway"
k get secret gateway-client-keys >/dev/null 2>&1 && k get configmap gateway-identity-map >/dev/null 2>&1 && pass "applying the manifests again keeps both objects" || fail "an object is gone"

echo "== 5. a new map"
up --identity-map-file map2.json && pass "identity/up.sh ran" || fail "identity/up.sh: $(tail -3 "$work/up.out")"
settle
p2="$(gwpod)"
[ "$p2" != "$p1" ] && pass "the gateway rolled" || fail "the gateway did not roll"
[ "$(k exec "$p2" -c gateway -- cat /etc/tokenfuse/identity/identity.json | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" = "$(sha "$work/map2.json")" ] \
  && pass "the new pod reads the new map" || fail "the new pod reads another map"

echo "== 6. a new keys file"
up --client-keys-file keys3.txt && pass "identity/up.sh ran" || fail "identity/up.sh: $(tail -3 "$work/up.out")"
settle
p3="$(gwpod)"
[ "$p3" != "$p2" ] && pass "the gateway rolled" || fail "the gateway did not roll"
gwlog | grep -q '^client auth: ON (3 key(s))' && pass "the new pod reports 3 client keys" || fail "the new pod does not report 3 keys"
r="$(call "$K3" agent://bank.example/treasury/t3)"
echo "      the new key as a treasury agent: $r"
case "$r" in 401*) fail "the new key was refused 401: $r" ;; *) pass "the new key passes the door ($(cut -d' ' -f1-2 <<<"$r"))" ;; esac

echo "== 7. a refused keys file changes nothing"
s3="$(rv secret gateway-client-keys)"
if up --client-keys-file keys-orphan.txt; then fail "a key with no binding was accepted"; else pass "a key with no binding is refused: $(grep '^!!' "$work/up.out" | head -1 | cut -c1-110)"; fi
settle
[ "$(gwpod)" = "$p3" ] && [ "$(rv secret gateway-client-keys)" = "$s3" ] && pass "nothing was written or rolled" || fail "something changed"
leaked "$work/up.out" && fail "the refusal printed a client key" || pass "the refusal printed no client key"

echo "== 8. a map edited by another hand"
p3="$(gwpod)"
python3 -c 'import json,sys;print(json.dumps({"data":{"identity.json":open(sys.argv[1]).read()}}))' "$work/map3.json" \
  | k patch configmap gateway-identity-map --type merge --patch-file /dev/stdin >/dev/null
# What a person inspecting the pod would see: the kubelet rewrites a mounted
# ConfigMap in place, so the file changes under a gateway that read the old map
# at start and keeps it. Measured, not assumed: how long until the file moves.
t0=$(date +%s); moved=""
for _ in $(seq 1 150); do
  if [ "$(k exec "$p3" -c gateway -- cat /etc/tokenfuse/identity/identity.json 2>/dev/null | python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" = "$(sha "$work/map3.json")" ]; then moved=$(( $(date +%s) - t0 )); break; fi
  sleep 1
done
if [ -n "$moved" ]; then
  echo "      the running pod's file became the edited map after ${moved}s, with no restart: $( [ "$(gwpod)" = "$p3" ] && echo 'same pod' || echo 'pod changed')"
  pass "measured: the mounted map changes in place under a running gateway (${moved}s)"
else
  echo "      the running pod's file did not change within 150s"
  pass "measured: the mounted map did not change in place within 150s"
fi
v="$(verify_section)"; echo "$v" | sed 's/^/      /'
grep -q 'FAIL.*another identity map' <<<"$v" && pass "verify.sh finds the gateway on another map than the ConfigMap holds" || fail "verify.sh missed the edited map"
up && pass "identity/up.sh ran" || fail "identity/up.sh: $(tail -3 "$work/up.out")"
settle
[ "$(gwpod)" != "$p3" ] && [ "$(ann identity-map-sha256)" = "$(sha "$work/map3.json")" ] && pass "a re-run checked the edited map and rolled the gateway onto it" || fail "the edited map was not rolled"
v="$(verify_section)"
grep -q 'FAIL' <<<"$v" && fail "verify.sh still fails after the re-run" || pass "verify.sh agrees again"

echo "== 9. turned off by deleting both objects"
p4="$(gwpod)"
k delete secret gateway-client-keys >/dev/null
k delete configmap gateway-identity-map >/dev/null
up && pass "identity/up.sh ran" || fail "identity/up.sh: $(tail -3 "$work/up.out")"
settle
[ "$(gwpod)" != "$p4" ] && pass "the gateway rolled" || fail "the gateway did not roll"
l9="$(gwlog)"
if grep -q NO-GATEWAY-LOG <<<"$l9"; then fail "no gateway log to read: $l9"
elif grep -q -e '^client auth: ON' -e '^identity map: ON' <<<"$l9"; then fail "the gateway still reads keys or a map"
else pass "the gateway reads neither"; fi
r="$(call "" "")"
echo "      a call with no key: $r"
case "$r" in 401*unauthorized*) fail "a call with no key is still refused 401" ;; *) pass "a call with no key passes the door again ($(cut -d' ' -f1-2 <<<"$r"))" ;; esac
v="$(verify_section)"
grep -q 'FAIL' <<<"$v" && fail "verify.sh fails on a cluster turned off" || pass "verify.sh notes both off"

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" = 0 ]
