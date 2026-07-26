#!/usr/bin/env bash
# Put the console back where the base manifests expect it.
#
#   ./tunnel/down.sh && kubectl apply -k manifests/
#
# Order matters and the reverse does not work: applying manifests/ first
# recreates the console in agent-stack while the one in agent-console is still
# running, and both claim the same RWO state volume, so the second stays
# Pending with a message about the volume rather than about the duplicate.
set -euo pipefail
DST_NS="${DST_NS:-agent-console}"
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "removing the console and its tunnel from $DST_NS"
kubectl delete namespace "$DST_NS" --wait=true 2>&1 | sed 's/^/  /' || true

say "left behind on purpose"
cat <<TXT
  The DNS records (gw. and box.) and the Cloudflare token Secret are yours and
  cost nothing. The issued WireGuard peers went with the namespace: deleting it
  deleted the claim holding peers.conf, so every device issued through this
  tunnel is revoked. That is the intended meaning of tearing the road down.

  Now: kubectl apply -k manifests/
TXT
