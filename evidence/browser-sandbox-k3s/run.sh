#!/usr/bin/env bash
# The browser keeps both sandboxes on a real node: Chromium's own and the container's filter.
#
#   ./evidence/browser-sandbox-k3s/run.sh [page]          on a one-node k3s on this host (sudo)
#   NODE_CONTAINER=k3d-x-server-0 CRICTL=crictl ./...     on a k3d or kind node instead
#   OLD48=<a copy of an older 48-scopyx-browser.yaml>     also runs that file, which must go red
#
# CLAUDE.md invariant 84. Run by `.github/workflows/browser-sandbox.yml` on a GitHub runner with
# k3s installed on the runner itself, so the node is an Ubuntu host with AppArmor on, the shape
# every installer here builds. Nothing is billed: a public repository's standard runners.
#
# What runs, cut out of the manifests as they stand: the namespace from 00-base (PodSecurity
# `restricted`, enforced), the journal claim from 47, and 48 itself, unchanged. One stand-in:
# wardryx, the image 10-planes pins, with a policy that allows every fetch, because the question
# here is the sandbox and not the policy. The profile reaches the node through the installers' own
# `lib/browser-seccomp.sh`. 47's NetworkPolicies are not applied: the door is reached with
# `kubectl port-forward`, and a policy that is not under test would only add a way to fail.
#
# What it measures, during a real render, from places that cannot stand in for each other:
#
#   the container's filter   the seccomp section of the OCI spec containerd built for the
#                            container (crictl inspect) is the node file, rule for rule, and
#                            PID 1 runs with Seccomp: 2;
#   Chromium's sandbox       a renderer in a PID namespace of its own (NSpid has two columns), in
#                            a user namespace of its own (a one-line uid_map), and under a second
#                            seccomp filter, Chromium's own, on top of the container's;
#   AppArmor                 the label the runtime gave PID 1 and the renderer, and the host's
#                            apparmor_restrict_unprivileged_userns, printed.
#
# Then each control, every one a variation of 48 applied for real: the older file (OLD48) must go
# red on those checks; the runtime's default filter must refuse the browser by name; a profile
# missing from the node must stop the container from being created, never start it without one;
# the Docker-format file must show what containerd does with it; and each of the three calls the
# profile adds must be needed. Prints PASS or FAIL per check, ends with RUN_EXIT, exits 1 on any
# FAIL, and prints no key.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd -P)"
PAGE="${1:-https://example.com/}"
NS=agent-stack
CRICTL="${CRICTL:-k3s crictl}"
FAILS=0
PASSES=0
pass() { echo "PASS  $*"; PASSES=$((PASSES + 1)); }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
say() { printf '      %s\n' "$*"; }
head_() { printf '\n== %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; echo "RUN_EXIT=2"; exit 2; }
work="$(mktemp -d)"
pf=""
cleanup() {
  [ -z "$pf" ] || kill "$pf" 2>/dev/null
  rm -rf "$work"
  if [ "${KEEP:-0}" != 1 ]; then kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
k() { kubectl -n "$NS" "$@"; }

# The node, as root. The installers' helper takes NODE and a command for the far shell, with the
# file on stdin; here_ is that shape for this one node.
node_sh() {
  if [ -n "${NODE_CONTAINER:-}" ]; then docker exec -i "$NODE_CONTAINER" sh -c "$1"; else sudo sh -c "$1"; fi
}
here_() { node_sh "$2"; }
. "$ROOT/lib/secret-doc.sh"
. "$ROOT/lib/gen.sh"
. "$ROOT/lib/browser-seccomp.sh"

# ---- the node and the namespace --------------------------------------------------------------
head_ "the node"
printf '      %s, kernel %s, %s\n' "$(node_sh '. /etc/os-release; printf %s "$PRETTY_NAME"')" \
  "$(node_sh 'uname -r')" "$(kubectl version 2>/dev/null | sed -n 's/^Server Version: /Kubernetes /p')"
printf '      tree %s, on %s\n' "$(git rev-parse --short HEAD)" "$(date -u +%Y-%m-%d)"
printf 'arch: %s\n' "$(node_sh 'uname -m')"
say "AppArmor enabled: $(node_sh 'cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo absent')"
say "kernel.apparmor_restrict_unprivileged_userns: $(node_sh 'sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo absent')"
say "runtime default AppArmor profile loaded: $(node_sh 'grep -c cri-containerd /sys/kernel/security/apparmor/profiles 2>/dev/null || echo 0')"

browser_seccomp_put here_ node || die "could not write the profile onto the node"
NODE_FILE="$BROWSER_SECCOMP_ROOT/$BROWSER_SECCOMP_NAME"
if node_sh "cat $NODE_FILE" | cmp -s - "$BROWSER_SECCOMP_FILE"; then
  pass "lib/browser-seccomp.sh put seccomp/chromium-v1.json at $NODE_FILE, byte for byte"
else
  fail "the node file is not seccomp/chromium-v1.json"
fi

python3 - "$ROOT" "$work" <<'PY'
import re, sys
root, work = sys.argv[1:3]
def doc(path, kind, name):
    for d in re.split(r"^---\s*$", open(root + "/manifests/" + path).read(), flags=re.M):
        if re.search(r"^kind: " + kind + r"\s*$", d, re.M) and re.search(r"^  name: " + name + r"\s*$", d, re.M):
            return d.strip() + "\n"
    sys.exit(f"{path} has no {kind} {name}")
open(work + "/ns.yaml", "w").write(doc("00-base.yaml", "Namespace", "agent-stack"))
open(work + "/pvc.yaml", "w").write(doc("47-scopyx.yaml", "PersistentVolumeClaim", "scopyx-events"))
m = re.search(r"^ +image: (ghcr\.io/taipanbox/wardryx:\S+@sha256:[0-9a-f]{64})$",
              open(root + "/manifests/10-planes.yaml").read(), re.M)
open(work + "/wardryx-image", "w").write(m.group(1))
PY
[ -s "$work/ns.yaml" ] || die "could not cut the namespace and the claim out of the manifests"
kubectl delete namespace "$NS" --wait=true >/dev/null 2>&1 || true
kubectl apply -f "$work/ns.yaml" >/dev/null || die "the namespace was not created"
say "namespace labels: $(kubectl get namespace "$NS" -o jsonpath='{.metadata.labels}')"
k apply -f "$work/pvc.yaml" >/dev/null || die "the journal claim was not created"

key="$(gen 32)" || die "no key"
pep="$(gen 32)" || die "no key"
secret_doc scopyx-keys SCOPYX_KEYS="$key=agent://lab.invalid/agent" SCOPYX_WARDRYX_KEY="$pep" \
  | k create -f - >/dev/null || die "scopyx-keys was not created"
secret_doc lab-wardryx WARDRYX_KEYS="$pep:default:pep" | k create -f - >/dev/null || die "the stand-in's key was not created"
cat >"$work/wardryx.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata: { name: lab-policy }
data:
  lab.yaml: |
    - name: lab-allow
      target: "*"
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: wardryx, labels: { app: wardryx } }
spec:
  replicas: 1
  selector: { matchLabels: { app: wardryx } }
  template:
    metadata: { labels: { app: wardryx } }
    spec:
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: wardryx
          image: $(cat "$work/wardryx-image")
          args: ["serve", "-addr", "0.0.0.0:8090", "-events", "/tmp/e.ndjson", "-policy", "/etc/wardryx/policy/lab.yaml"]
          envFrom: [{ secretRef: { name: lab-wardryx } }]
          ports: [{ containerPort: 8090 }]
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
          volumeMounts: [{ name: tmp, mountPath: /tmp }, { name: policy, mountPath: /etc/wardryx/policy }]
      volumes:
        - { name: tmp, emptyDir: { sizeLimit: 16Mi } }
        - { name: policy, configMap: { name: lab-policy } }
---
apiVersion: v1
kind: Service
metadata: { name: wardryx }
spec:
  selector: { app: wardryx }
  ports: [{ port: 8090, targetPort: 8090 }]
YAML
k apply -f "$work/wardryx.yaml" >/dev/null || die "the stand-in policy plane was not applied"
k rollout status deploy/wardryx --timeout=240s >/dev/null || { k logs deploy/wardryx --tail=20; die "the stand-in policy plane did not start"; }
# Ready once is not serving: the stand-in has to stay up and have an endpoint, or every fetch reads
# as the policy plane refusing and nothing about the sandbox is measured.
sleep 5
if [ -z "$(k get endpoints wardryx -o jsonpath='{.subsets[*].addresses[*].ip}')" ] ||
  [ "$(k get pod -l app=wardryx -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')" != 0 ]; then
  k get pod -l app=wardryx -o wide
  k logs deploy/wardryx --tail=30
  k logs deploy/wardryx --previous --tail=30 2>/dev/null
  die "the stand-in policy plane does not stay up"
fi
say "stand-in policy plane: $(k logs deploy/wardryx --tail=3 2>&1 | tr '\n' ' ' | cut -c1-240)"

# ---- helpers ---------------------------------------------------------------------------------
# A variation of 48: the file as it stands, with one text replaced. Every edit must apply.
variant() { # OUT FROM TO
  python3 - "$ROOT/manifests/48-scopyx-browser.yaml" "$1" "$2" "$3" <<'PY'
import sys
src, out, a, b = sys.argv[1:5]
s = open(src).read()
assert a in s, "the variation does not apply: " + a
open(out, "w").write(s.replace(a, b, 1))
PY
}
LOCALHOST="seccompProfile: { type: Localhost, localhostProfile: $BROWSER_SECCOMP_NAME }"

# The one Running pod of this rollout, never one still terminating from the last (GOTCHAS 159).
pod_now() {
  k get pod -l app=scopyx -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null \
    | awk '$2 == "Running" && $3 == "" { print $1 }'
}
pods_now() { # every pod of the browser, terminating or not
  k get pod -l app=scopyx -o name 2>/dev/null | wc -l | tr -d ' '
}
deploy() { # FILE: apply it, and wait for its one pod to run
  [ -z "$pf" ] || { kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null; pf=""; }
  k apply -f "$1" >/dev/null || return 1
  k rollout status deploy/scopyx --timeout=300s >/dev/null || return 1
  local i
  POD=""
  for i in $(seq 60); do
    POD="$(pod_now)"
    if [ -n "$POD" ] && [ "$(pods_now)" = 1 ]; then break; fi
    POD=""
    sleep 1
  done
  [ -n "$POD" ] || return 1
  k port-forward "pod/$POD" 14300:4300 >"$work/pf.log" 2>&1 &
  pf=$!
  for i in $(seq 30); do
    if curl -s -m 2 -o /dev/null http://127.0.0.1:14300/; then return 0; fi
    sleep 1
  done
  return 1
}
browse() { # one fetch, the answer in $work/browse.json; the key goes on curl's stdin
  printf 'header = "content-type: application/json"\nheader = "X-Scopyx-Key: %s"\n' "$key" \
    | curl -s -m 150 -K - -o "$work/browse.json" -w '%{http_code}' -X POST http://127.0.0.1:14300/ \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browse","arguments":{"url":"'"$PAGE"'"}}}'
}
browse_says() { # what one fetch answers, in a line
  browse >/dev/null
  python3 - "$work/browse.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    print("no answer"); sys.exit()
r = d.get("result") or {}
t = " ".join(c.get("text", "") for c in r.get("content", []))
print(("refused: " + t[:300]) if r.get("isError") or d.get("error") else f"rendered, {len(t)} characters")
PY
}

# Reads both sandboxes during one render. Returns non-zero when either is not there.
measure() {
  local bad=0 cid spec pid1 renderer
  cid="$(k get pod "$POD" -o jsonpath='{.status.containerStatuses[?(@.name=="scopyx")].containerID}')"
  cid="${cid#*://}"
  node_sh "$CRICTL inspect $cid" >"$work/inspect.json" 2>/dev/null
  if python3 - "$work/inspect.json" "$BROWSER_SECCOMP_FILE" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))["info"]["runtimeSpec"]["linux"].get("seccomp")
want = json.load(open(sys.argv[2]))
def norm(p):
    rules = []
    for r in p.get("syscalls") or []:
        args = [(a["index"], a["value"], a.get("valueTwo", 0), a["op"]) for a in r.get("args") or []]
        rules.append((tuple(r["names"]), r["action"], r.get("errnoRet"), tuple(args)))
    return (p["defaultAction"], p.get("defaultErrnoRet"), tuple(p.get("architectures") or []), tuple(rules))
if not spec:
    print("FAIL  the container's OCI spec carries no seccomp section"); sys.exit(1)
if norm(spec) != norm(want):
    print("FAIL  the filter containerd gave the container is not the node file"); sys.exit(1)
print(f"PASS  the filter containerd gave the container is the node file, {len(want['syscalls'])} rules, rule for rule")
PY
  then PASSES=$((PASSES + 1)); else FAILS=$((FAILS + 1)); bad=1; fi
  pid1="$(k exec "$POD" -c scopyx -- sh -c 'grep -E "^(Seccomp|NoNewPrivs):" /proc/1/status | tr -s "\t " " " | tr "\n" " "; cat /proc/1/attr/apparmor/current 2>/dev/null || cat /proc/1/attr/current 2>/dev/null' 2>/dev/null)"
  case "$pid1" in
    *"Seccomp: 2"*) pass "the container's filter is on: $pid1" ;;
    *) fail "the container's filter is not on: $pid1"; bad=1 ;;
  esac

  # The renderer lives for a second or two, so it is watched from before the page is asked for.
  # Its own filter comes up a moment after it starts, which is why this waits for the second one.
  k exec "$POD" -c scopyx -- sh -c '
    i=0; seen=""
    while [ "$i" -lt 900 ]; do
      for p in /proc/[0-9]*; do
        c="$(tr "\000" " " <"$p/cmdline" 2>/dev/null)"
        case "$c" in *--type=renderer*) ;; *) continue ;; esac
        s="$(grep -E "^(Seccomp|Seccomp_filters|NSpid):" "$p/status" 2>/dev/null | tr -s "\t " " " | tr "\n" ";")"
        m="$(tr -s " " <"$p/uid_map" 2>/dev/null | tr "\n" ";")"
        a="$(cat "$p/attr/apparmor/current" 2>/dev/null || cat "$p/attr/current" 2>/dev/null)"
        [ -n "$s" ] || continue
        seen="$s uid_map:$m apparmor:$a"
        case "$s" in *"Seccomp_filters: 1;"*) ;; *) echo "$seen"; exit 0 ;; esac
      done
      i=$((i + 1)); sleep 0.1
    done
    echo "$seen"' >"$work/renderer" 2>/dev/null &
  local watcher=$!
  sleep 0.5
  local code
  code="$(browse)"
  if python3 - "$work/browse.json" "$code" "$PAGE" <<'PY'
import json, sys
path, code, url = sys.argv[1:4]
try:
    d = json.load(open(path))
except ValueError:
    print(f"FAIL  browse answered HTTP {code}, and not JSON"); sys.exit(1)
r = d.get("result") or {}
text = " ".join(c.get("text", "") for c in r.get("content", []))
if d.get("error") or r.get("isError") or "<html" not in text.lower():
    print("FAIL  browse did not render " + url + ": " + (text or json.dumps(d))[:400]); sys.exit(1)
print(f"PASS  browse rendered {url}: {len(text)} characters of HTML")
PY
  then PASSES=$((PASSES + 1)); else FAILS=$((FAILS + 1)); bad=1; fi
  wait "$watcher" 2>/dev/null
  renderer="$(cat "$work/renderer")"
  say "renderer: ${renderer:-none seen}"
  [ -n "$renderer" ] || { fail "no renderer was seen, so Chromium's sandbox was not read"; bad=1; }
  if [[ "$renderer" =~ NSpid:\ [0-9]+\ [0-9]+ ]]; then
    pass "the renderer is in a PID namespace of its own"
  else
    fail "the renderer is in the container's PID namespace"; bad=1
  fi
  case "$renderer" in
    *"Seccomp: 2;"*"Seccomp_filters: 1;"*) fail "the renderer has one seccomp filter, the container's: Chromium's own is not on"; bad=1 ;;
    *"Seccomp: 2;"*) pass "the renderer runs under Chromium's own filter on top of the container's" ;;
    *) fail "the renderer has no seccomp filter"; bad=1 ;;
  esac
  case "$renderer" in
    *"uid_map: 0 0 4294967295"*) fail "the renderer is in the container's user namespace"; bad=1 ;;
    *"uid_map:"*" 1;"*) pass "the renderer is in a user namespace of its own" ;;
    *) fail "the renderer's uid_map was not read"; bad=1 ;;
  esac
  return "$bad"
}
unshare_row() { # what the container's filter lets unshare(1) do
  local flags out=""
  for flags in -Ur -Urm -Urn -Uri -Uru; do
    if k exec "$POD" -c scopyx -- unshare "$flags" true >/dev/null 2>&1; then out="$out $flags:allowed"; else out="$out $flags:refused"; fi
  done
  printf '%s' "${out# }"
}
waiting_reason() { # the browser container's waiting reason and message, once one shows
  local i r
  for i in $(seq 90); do
    r="$(k get pod -l app=scopyx -o jsonpath='{range .items[*]}{.status.containerStatuses[?(@.name=="scopyx")].state.waiting.reason}{" "}{.status.containerStatuses[?(@.name=="scopyx")].state.waiting.message}{"\n"}{end}' 2>/dev/null | awk 'NF' | tail -1)"
    case "$r" in ""|ContainerCreating*|PodInitializing*) ;; *) printf '%s' "$r"; return 0 ;; esac
    sleep 2
  done
  printf 'none in 180 s: %s' "$(k get pod -l app=scopyx -o wide 2>&1 | tail -1)"
}

# ---- 1. as shipped ---------------------------------------------------------------------------
head_ "as shipped: manifests/48-scopyx-browser.yaml, unchanged, under PodSecurity restricted"
if deploy "$ROOT/manifests/48-scopyx-browser.yaml"; then
  pass "admitted under restricted and running: $POD"
  if measure; then pass "both sandboxes were on while a real page rendered"; else fail "a sandbox was missing"; fi
  row="$(unshare_row)"
  say "unshare: $row"
  if [ "$row" = "-Ur:allowed -Urm:refused -Urn:refused -Uri:refused -Uru:refused" ]; then
    pass "the filter lets a process into a user namespace and refuses every other namespace"
  else
    fail "the filter's namespaces are not what the profile says: $row"
  fi
  n=0
  for _ in 1 2 3 4 5; do case "$(browse_says)" in rendered*) n=$((n + 1)) ;; esac; done
  if [ "$n" = 5 ]; then pass "5 of 5 more fetches rendered"; else fail "$n of 5 more fetches rendered"; fi
  gen1="$(k get deploy scopyx -o jsonpath='{.metadata.generation}')"
  uid1="$(k get pod "$POD" -o jsonpath='{.metadata.uid}')"
  k apply -f "$ROOT/manifests/48-scopyx-browser.yaml" >/dev/null
  sleep 3
  if [ "$gen1" = "$(k get deploy scopyx -o jsonpath='{.metadata.generation}')" ] && [ "$uid1" = "$(k get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null)" ]; then
    pass "a second apply changes nothing: generation $gen1, the same pod"
  else
    fail "a second apply rolled the browser"
  fi
else
  fail "48 as shipped did not run: $(waiting_reason)"
  k describe pod -l app=scopyx | tail -15
fi

# ---- 2. controls -----------------------------------------------------------------------------
if [ -n "${OLD48:-}" ]; then
  head_ "control: the older 48 ($OLD48) must go red on the same checks"
  if deploy "$OLD48"; then
    if measure >"$work/old.out" 2>&1; then
      sed 's/^/      | /' "$work/old.out"
      fail "the older file passed the sandbox checks"
    else
      sed 's/^/      | /' "$work/old.out"
      pass "the older file goes red: its browser renders with Chromium's sandbox off"
    fi
  else
    fail "the older file did not run, so it could not go red for the right reason"
  fi
fi

head_ "control: the runtime's default filter, and the browser's sandbox asked for"
variant "$work/rd.yaml" "$LOCALHOST" "seccompProfile: { type: RuntimeDefault }"
if deploy "$work/rd.yaml"; then
  said="$(browse_says)"
  say "$said"
  case "$said" in
    refused:*"sandbox"*) pass "under RuntimeDefault the browser refuses to render and names the sandbox" ;;
    *) fail "under RuntimeDefault the browser did not refuse by naming its sandbox" ;;
  esac
else
  fail "the RuntimeDefault variation did not run"
fi

head_ "control: a profile the node does not have"
variant "$work/absent.yaml" "localhostProfile: $BROWSER_SECCOMP_NAME" "localhostProfile: taipanbox/absent-v0.json"
[ -z "$pf" ] || { kill "$pf" 2>/dev/null; pf=""; }
k apply -f "$work/absent.yaml" >/dev/null
why="$(waiting_reason)"
say "$why"
case "$why" in
  CreateContainerError*"seccomp"*"absent-v0.json"*) pass "the container is not created, and the reason names the missing profile" ;;
  *) fail "a missing profile did not stop the container with a reason naming it" ;;
esac
if [ -n "$(pod_now)" ]; then fail "a browser pod is Running without its profile"; else pass "no browser pod runs without its profile"; fi

head_ "control: stack-single's file in Docker's format, as a node would read it"
# Twice: the file byte for byte, and the same file with the one rule that conflicts with another
# once the conditions are gone (clone3 refused for a container without CAP_SYS_ADMIN, beside clone3
# allowed for one with it), which is the edit a person makes to get it to load.
docker_name="taipanbox/chromium-v1-docker-format.json"
loaded_name="taipanbox/chromium-v1-docker-format-loaded.json"
node_sh "cat > $BROWSER_SECCOMP_ROOT/$docker_name" <"$ROOT/seccomp/chromium-v1.docker.json"
python3 - "$ROOT/seccomp/chromium-v1.docker.json" >"$work/loaded.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
before = len(p["syscalls"])
p["syscalls"] = [r for r in p["syscalls"] if not (r["names"] == ["clone3"] and r["action"] == "SCMP_ACT_ERRNO")]
assert len(p["syscalls"]) == before - 1
print(json.dumps(p))
PY
node_sh "cat > $BROWSER_SECCOMP_ROOT/$loaded_name" <"$work/loaded.json"
for name in "$docker_name" "$loaded_name"; do
  variant "$work/docker.yaml" "localhostProfile: $BROWSER_SECCOMP_NAME" "localhostProfile: $name"
  if deploy "$work/docker.yaml"; then
    row="$(unshare_row)"
    say "$name: runs, unshare: $row"
    case "$row" in
      *"-Urm:allowed"*) pass "$name: containerd dropped Docker's conditions, and a mount namespace is allowed" ;;
      "-Ur:allowed -Urm:refused -Urn:refused -Uri:refused -Uru:refused")
        fail "$name: gave the same filter as the resolved file, so GOTCHAS 161 is wrong" ;;
      *) pass "$name: not the filter Docker gives this container: $row" ;;
    esac
  else
    why="$(waiting_reason)"
    say "$name: does not run: $why"
    pass "$name: not the filter Docker gives this container: the container does not start"
  fi
done
head_ "control: each call the profile adds, taken out"
for gone in chroot clone unshare; do
  python3 - "$BROWSER_SECCOMP_FILE" "$ROOT/seccomp/chromium-v1.docker.json" "$gone" >"$work/without-$gone.json" <<'PY'
import json, sys
oci, docker, gone = sys.argv[1:4]
added = [r for r in json.load(open(docker))["syscalls"] if str(r.get("comment", "")).startswith("chromium-v1:") and gone in r["names"]]
assert len(added) == 1, "not one added rule for " + gone
a = {k: v for k, v in added[0].items() if k in ("names", "action", "errnoRet", "args")}
p = json.load(open(oci))
before = len(p["syscalls"])
p["syscalls"] = [r for r in p["syscalls"] if r != a]
assert len(p["syscalls"]) == before - 1, "the rule for " + gone + " is not in the node file"
print(json.dumps(p, indent=2))
PY
  node_sh "cat > $BROWSER_SECCOMP_ROOT/taipanbox/without-$gone.json" <"$work/without-$gone.json"
  variant "$work/without-$gone.yaml" "localhostProfile: $BROWSER_SECCOMP_NAME" "localhostProfile: taipanbox/without-$gone.json"
  if deploy "$work/without-$gone.yaml"; then
    said="$(browse_says)"
    say "without $gone: $said"
    case "$said" in
      refused:*) pass "without $gone the browser does not render" ;;
      *) fail "without $gone the browser still rendered, so the rule is not needed" ;;
    esac
  else
    fail "the variation without $gone did not run"
  fi
done
node_sh "rm -f $BROWSER_SECCOMP_ROOT/$docker_name $BROWSER_SECCOMP_ROOT/$loaded_name $BROWSER_SECCOMP_ROOT/taipanbox/without-chroot.json $BROWSER_SECCOMP_ROOT/taipanbox/without-clone.json $BROWSER_SECCOMP_ROOT/taipanbox/without-unshare.json"

head_ "the kernel's own word on namespaces refused under AppArmor, if any"
node_sh 'dmesg 2>/dev/null | grep -i "apparmor=\"DENIED\"" | grep -i userns | tail -3' | sed 's/^/      /'

printf '\n%s passed, %s failed\n' "$PASSES" "$FAILS"
if [ "$FAILS" = 0 ]; then echo "RUN_EXIT=0"; exit 0; fi
echo "RUN_EXIT=1"
exit 1
