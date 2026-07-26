#!/usr/bin/env bash
# Take the tunnel away and leave the stack as it was.
#
#   ./tunnel/down.sh && kubectl apply -k manifests/
#
# Order matters: this removes the tunnel namespace, and the apply afterwards
# returns the console Deployment to its unpatched form. Running the apply first
# would leave a console configured to reach a daemon that is being deleted.
set -euo pipefail
TUN_NS="${TUN_NS:-agent-tunnel}"
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "removing the tunnel from $TUN_NS"
kubectl delete namespace "$TUN_NS" --wait=true 2>&1 | sed 's/^/  /' || true

say "the console's own policies, which live in agent-stack"
kubectl -n agent-stack delete networkpolicy console-egress-tunnel console-ingress-tunnel \
  --ignore-not-found 2>&1 | sed 's/^/  /' || true

cat <<'TXT'

  Left behind on purpose: the DNS records and the Cloudflare token, which are
  yours and cost nothing.

  Gone with the namespace: every device issued through this tunnel. Deleting it
  deleted the claim holding peers.conf, so those configs stay valid-looking and
  will never complete a handshake again. That is the intended meaning of taking
  the road down.

  Now: kubectl apply -k manifests/
TXT
