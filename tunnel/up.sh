#!/usr/bin/env bash
# Bring up the operator's tunnel, and move the console to the namespace that
# can honestly hold it.
#
#   ./tunnel/up.sh
#
# Three things here cannot be static YAML, which is the whole reason this file
# exists rather than a line in a README:
#
#   1. the shared event log's address, which Longhorn chooses and changes when
#      the volume is recreated
#   2. the two generated Secrets the console needs, which live in agent-stack
#      and must not be written into this repository
#   3. a check that tunnel/console.yaml has not drifted from the base it was
#      copied out of
#
# Read tunnel/namespace.yaml first if you have not: this moves the console out
# of a namespace that enforces PodSecurity `restricted`, and the reasoning for
# that matters more than the mechanics below.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC_NS="${SRC_NS:-agent-stack}"
DST_NS="${DST_NS:-agent-console}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"
kubectl version -o json >/dev/null 2>&1 || die "no cluster: set KUBECONFIG"

# ---- 1. has the copy drifted? ----------------------------------------------
# tunnel/console.yaml is a COPY of manifests/20-console.yaml with a different
# namespace and two extra containers. A copy nobody checks is a copy that is
# already wrong, so compare what the base console container declares against
# what the copy declares, and refuse if the base has grown something the copy
# lacks. Names only: values legitimately differ (the plane URLs are qualified
# here, and the tunnel adds env of its own).
say "checking tunnel/console.yaml against manifests/20-console.yaml"
python3 - "$ROOT/manifests/20-console.yaml" "$HERE/console.yaml" <<'PY'
import re, sys

def console_block(path):
    text = open(path).read()
    # the console container starts at `- name: console` and ends at the next
    # container or the volumes key at the same indentation
    m = re.search(r'\n(\s*)- name: console\n(.*?)(?=\n\1- name: |\n\s*volumes:)', text, re.S)
    return m.group(0) if m else ""

def names(block, key):
    if key == "env":
        return set(re.findall(r'(?:^|\{|\s)name: ([A-Z][A-Z0-9_]+)', block))
    return set(re.findall(r'name: ([a-z][a-z-]*), mountPath', block))

base, copy = console_block(sys.argv[1]), console_block(sys.argv[2])
if not base or not copy:
    print("   could not locate a console container in one of the files"); sys.exit(1)

bad = 0
for key, label in (("env", "environment variables"), ("mounts", "volume mounts")):
    missing = names(base, key) - names(copy, key)
    if missing:
        print(f"   MISSING {label} in tunnel/console.yaml: {', '.join(sorted(missing))}")
        bad = 1
print("   in step" if not bad else "   DRIFTED")
sys.exit(bad)
PY
[ $? -eq 0 ] || die "tunnel/console.yaml has drifted from the base. Copy the missing
   entries across before applying, or the console will come up missing whatever
   the base grew since."

# ---- 2. where is the shared event log? --------------------------------------
# A PVC cannot cross a namespace, but Longhorn already exports this RWX volume
# over NFS on a ClusterIP, so the console mounts that export directly. Resolved
# here because the address is Longhorn's to choose.
say "finding the shared event log"
PV="$(kubectl -n "$SRC_NS" get pvc stack-events -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
[ -n "$PV" ] || die "no bound stack-events claim in $SRC_NS: apply manifests/ first"
ENDPOINT="$(kubectl -n longhorn-system get volumes.longhorn.io "$PV" -o jsonpath='{.status.shareEndpoint}' 2>/dev/null || true)"
[ -n "$ENDPOINT" ] || die "Longhorn reports no share endpoint for $PV.
   An RWX volume gets one only once it is ATTACHED, so start the workload that
   uses it first, or check 'kubectl -n longhorn-system get volumes.longhorn.io'."
NFS_SERVER="${ENDPOINT#nfs://}"; NFS_SERVER="${NFS_SERVER%%/*}"
NFS_PATH="/${ENDPOINT#nfs://*/}"
echo "   $ENDPOINT"

# ---- 3. the namespace, before anything is copied into it --------------------
say "namespace"
kubectl apply -f "$HERE/namespace.yaml"

# ---- 4. the two generated Secrets ------------------------------------------
# install.sh generates these into agent-stack and this repo never sees them.
# Copied rather than regenerated, because regenerating would hand the console a
# different key from the one the planes accept.
#
# This is the honest cost of the two-namespace shape: the credential now exists
# in two places, and rotating it means rotating both. Named here rather than
# left for someone to discover.
say "copying the generated credentials into $DST_NS"
kubectl -n "$SRC_NS" get secret stack-keys -o json 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['metadata']={'name':d['metadata']['name'],'namespace':'$DST_NS'}
json.dump(d,sys.stdout)" \
  | kubectl apply -f - >/dev/null && echo "   stack-keys" || die "could not copy stack-keys from $SRC_NS"
# The DNS-01 credential, from a file so it never reaches a command line or the
# shell history. Optional: without it Caddy falls back to its internal CA,
# which works only on a device told to trust it. Fine for iterating, useless
# for a demonstration, and the difference is silent, so it is reported.
CF_TOKEN_FILE="${CF_TOKEN_FILE:-$HOME/.config/stack-k8s/cloudflare-token}"
if [ -s "$CF_TOKEN_FILE" ]; then
  kubectl -n "$DST_NS" create secret generic stack-tunnel-dns \
    --from-file=cloudflare_api_token="$CF_TOKEN_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null && echo "   stack-tunnel-dns (real certificate)"
else
  echo "   no $CF_TOKEN_FILE: Caddy will use its INTERNAL CA, so the passkey"
  echo "   ceremony will fail on any device that has not been told to trust it"
fi

kubectl -n "$SRC_NS" get configmap stack-environment -o json 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['metadata']={'name':d['metadata']['name'],'namespace':'$DST_NS'}
json.dump(d,sys.stdout)" \
  | kubectl apply -f - >/dev/null && echo "   stack-environment" || true

# ---- 5. apply ---------------------------------------------------------------
say "applying"
kubectl kustomize "$HERE" \
  | sed -e "s|EVENTS_NFS_SERVER|$NFS_SERVER|" -e "s|EVENTS_NFS_PATH|$NFS_PATH|" \
  | kubectl apply -f - 2>&1 | grep -vE 'unchanged$' || true

# ---- 6. did it actually come up? -------------------------------------------
# A rollout that reports success proves the pods started, not that the tunnel
# exists. Both are checked, in that order, because the second failure mode is
# the quiet one.
say "waiting for the console"
kubectl -n "$DST_NS" rollout status deploy/genaryx-console --timeout=300s || {
  kubectl -n "$DST_NS" describe rs -l app=genaryx-console 2>/dev/null | grep -A4 'Events:' | tail -5
  die "the console did not come up. If the message above mentions PodSecurity,
   the namespace labels did not apply; if it mentions a volume, the NFS mount
   for the event log is the first thing to check."
}

say "the tunnel interface"
POD="$(kubectl -n "$DST_NS" get pod -l app=genaryx-console -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$DST_NS" exec "$POD" -c wg -- wg show 2>/dev/null | head -6 \
  || echo "   the daemon is up but 'wg show' said nothing: check 'kubectl -n $DST_NS logs $POD -c wg'"

cat <<EOF

$(printf '\033[1m')Up.$(printf '\033[0m') The console now lives in $DST_NS, and the planes stay in $SRC_NS
under PodSecurity restricted.

  Issue yourself a device from the console, then dial:

      $(kubectl -n "$DST_NS" get configmap stack-tunnel -o jsonpath='{.data.endpoint_host}'):31820

  and open https://$(kubectl -n "$DST_NS" get configmap stack-tunnel -o jsonpath='{.data.console_domain}')/ once the tunnel is up.

  Going back to the plain layout: ./tunnel/down.sh, THEN kubectl apply -k manifests/
EOF
