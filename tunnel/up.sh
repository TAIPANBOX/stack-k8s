#!/usr/bin/env bash
# Bring up the operator's tunnel.
#
#   ./tunnel/up.sh
#
# Much shorter than it used to be, and the difference is the point. The earlier
# shape put the console in a privileged namespace beside the daemon, so this
# script had to copy the plane admin credentials across, discover the shared
# event log's NFS address, and diff a duplicated Deployment against its
# original to catch drift. The console now reaches the daemon over an
# authenticated network channel and stays where it was, so all of that is gone.
#
# What is left: one Secret the tunnel needs on its own side, an apply, and a
# check that the thing actually carries traffic rather than merely exists.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC_NS="${SRC_NS:-agent-stack}"
TUN_NS="${TUN_NS:-agent-tunnel}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"
kubectl version -o json >/dev/null 2>&1 || die "no cluster: set KUBECONFIG"

say "namespace"
kubectl apply -f "$HERE/namespace.yaml"

# ---- the proxy's own credentials -------------------------------------------
# install.sh generates these into agent-stack with every other per-cluster
# secret, and this repo never sees them. The tunnel needs the certificate, its
# key and the bearer; the console needs the CA and the bearer, and already has
# them where it is.
#
# The honest residual of the split: this one Secret exists in two namespaces.
# One secret, and the tunnel's own, rather than the plane admin keys the
# earlier shape had to duplicate.
say "the proxy's credentials"
kubectl -n "$SRC_NS" get secret stack-tunnel-proxy -o json 2>/dev/null \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
d['metadata']={'name':d['metadata']['name'],'namespace':'$TUN_NS'}
json.dump(d,sys.stdout)" \
  | kubectl apply -f - >/dev/null \
  || die "no stack-tunnel-proxy in $SRC_NS. install.sh generates it; re-run it, or
   check that openssl was available on the machine that ran it."
echo "   copied into $TUN_NS"

# The DNS-01 credential, from a file so it never reaches a command line or the
# shell history. Optional: without it Caddy falls back to its internal CA,
# which works only on a device told to trust it. Fine for iterating, useless
# for a demonstration, and the difference is silent, so it is reported.
CF_TOKEN_FILE="${CF_TOKEN_FILE:-$HOME/.config/stack-k8s/cloudflare-token}"
if [ -s "$CF_TOKEN_FILE" ]; then
  kubectl -n "$TUN_NS" create secret generic stack-tunnel-dns \
    --from-file=cloudflare_api_token="$CF_TOKEN_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "   stack-tunnel-dns (real certificate)"
else
  echo "   no $CF_TOKEN_FILE: Caddy will use its INTERNAL CA, so the passkey"
  echo "   ceremony will fail on any device that has not been told to trust it"
fi

say "applying"
kubectl apply -k "$HERE" 2>&1 | grep -vE 'unchanged$' || true

say "waiting for the tunnel"
kubectl -n "$TUN_NS" rollout status deploy/genaryx-tunnel --timeout=300s || {
  kubectl -n "$TUN_NS" describe rs -l app=genaryx-tunnel 2>/dev/null | grep -A4 'Events:' | tail -5
  die "the tunnel did not come up. If the message mentions PodSecurity the
   namespace labels did not apply; if it mentions a volume, check the
   stack-tunnel-proxy Secret has tls.crt, tls.key and token."
}
say "waiting for the console"
kubectl -n "$SRC_NS" rollout status deploy/genaryx-console --timeout=300s || \
  die "the console did not come back up after the patch"

# A rollout proves pods started. It proves nothing about whether the console
# can reach the daemon, which is the entire point of this change, so ask.
say "can the console actually reach the daemon?"
POD="$(kubectl -n "$SRC_NS" get pod -l app=genaryx-console -o jsonpath='{.items[0].metadata.name}')"
if kubectl -n "$SRC_NS" exec "$POD" -c console -- python3 -c "
import socket, ssl, sys
ctx = ssl.create_default_context(cafile='/etc/wg-uapi/ca.crt')
with socket.create_connection(('wg-uapi.agent-tunnel', 9090), timeout=8) as raw:
    with ctx.wrap_socket(raw, server_hostname='wg-uapi.agent-tunnel') as s:
        pass
" 2>/dev/null; then
  echo "   TLS to wg-uapi.agent-tunnel:9090 completes and the pinned CA verifies"
else
  # Say what is actually wrong before blaming the network. The first version of
  # this message sent the reader to the NetworkPolicies while the real cause was
  # a tunnel container that had already exited, and the policies were fine.
  RESTARTS="$(kubectl -n "$TUN_NS" get pod -l app=genaryx-tunnel \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="wg")].restartCount}' 2>/dev/null || true)"
  if [ "${RESTARTS:-0}" != "0" ]; then
    printf '\n   the tunnel container has restarted %s time(s). Its own last words:\n\n' "$RESTARTS"
    kubectl -n "$TUN_NS" logs deploy/genaryx-tunnel -c wg --previous --tail=15 2>/dev/null | sed 's/^/     /'
    die "the daemon is not staying up, so no client could reach it. Fix that first."
  fi
  die "the console cannot complete TLS to the daemon, and the daemon is up, so
   this is the path between them. Check, in this order: the
   console-egress-tunnel and tunnel-ingress NetworkPolicies, then that the
   Service is still called wg-uapi in $TUN_NS (install.sh puts that exact name
   in the certificate's SAN, so a rename fails as a TLS error)."
fi

cat <<EOF

$(printf '\033[1m')Up.$(printf '\033[0m') The tunnel is in $TUN_NS; the console stayed in $SRC_NS
under enforced PodSecurity restricted.

  Issue yourself a device from the console, dial
  $(kubectl -n "$TUN_NS" get configmap stack-tunnel -o jsonpath='{.data.endpoint_host}'):31820,
  then open https://$(kubectl -n "$TUN_NS" get configmap stack-tunnel -o jsonpath='{.data.console_domain}')/

  Going back: ./tunnel/down.sh, then kubectl apply -k manifests/
EOF
