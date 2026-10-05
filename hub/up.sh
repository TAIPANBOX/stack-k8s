#!/usr/bin/env bash
# Bring up the hub's public entry for remote sites (manifests/53-hub-entry.yaml).
#
#   ./hub/up.sh [--host box.example.com]
#
# With no --host, the address the LoadBalancer is given decides the name: an
# `<a-b-c-d>.sslip.io` built from its IPv4 address, which resolves with no DNS
# zone of your own (that is what N2/G2 was measured against, 2026-09-26). Pass
# --host for a domain you already control; Caddy asks Let's Encrypt for
# whichever name it is told, either way.
#
# KUBECONFIG comes from the environment, same as every other script here.
#
# Idempotent (CLAUDE.md invariant 4): re-running with the SAME host applies
# the manifest again (a no-op past the first time) and does not touch the
# running Deployment, so it never forces Caddy to re-request a certificate it
# already holds. Only a host that actually CHANGES restarts the pod, because
# the ACME state lives on an emptyDir (manifests/53-hub-entry.yaml's own
# header says why) and a restart with no reason would spend one of Let's
# Encrypt's rate-limited issuances for nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-agent-stack}"
HOST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl not found"
kubectl version -o json >/dev/null 2>&1 || die "no cluster: set KUBECONFIG"

say "applying manifests/53-hub-entry.yaml"
kubectl apply -f "$ROOT/manifests/53-hub-entry.yaml" 2>&1 | sed 's/^/   /'

# ---- the LoadBalancer address ----------------------------------------------
# type: LoadBalancer is METERED (see the manifest's own header): once this
# object exists it is billing, whatever happens next in this script.
say "waiting for the LoadBalancer address (this is billing from here)"
ADDR=""
for _ in $(seq 1 60); do
  ADDR="$(kubectl -n "$NS" get svc hub-ingress \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$ADDR" ] && break
  ADDR="$(kubectl -n "$NS" get svc hub-ingress \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$ADDR" ] && break
  sleep 5
done
[ -n "$ADDR" ] || die "no LoadBalancer address after 5 minutes.
   kubectl -n $NS get svc hub-ingress
   Check the cloud controller is running and the account has quota for one
   more forwarding rule / load balancer."
echo "   $ADDR"

# ---- the host --------------------------------------------------------------
if [ -n "$HOST" ]; then
  echo "   using --host $HOST; point its DNS at $ADDR yourself before"
  echo "   certificates can be issued for it"
else
  case "$ADDR" in
    *.*.*.*)
      HOST="$(printf '%s' "$ADDR" | tr '.' '-').sslip.io"
      echo "   derived $HOST from the address, no DNS zone needed"
      ;;
    *)
      die "the LoadBalancer gave a hostname ($ADDR), not an IPv4 address, so
   there is no address to build an sslip.io name from (this is the AWS NLB
   shape). Pass --host with a domain you control and point it at $ADDR."
      ;;
  esac
fi

# ---- write it into the ConfigMap, only if it actually changed --------------
CURRENT="$(kubectl -n "$NS" get configmap stack-hub-entry -o jsonpath='{.data.host}' 2>/dev/null || true)"
if [ "$CURRENT" = "$HOST" ]; then
  say "stack-hub-entry already carries $HOST, nothing to restart"
else
  say "writing $HOST into the stack-hub-entry ConfigMap"
  kubectl -n "$NS" patch configmap stack-hub-entry --type merge \
    -p "{\"data\":{\"host\":\"$HOST\"}}" >/dev/null
  say "restarting hub-ingress so Caddy picks up the new HUB_HOST"
  kubectl -n "$NS" rollout restart deployment/hub-ingress >/dev/null
fi

say "waiting for the rollout"
kubectl -n "$NS" rollout status deployment/hub-ingress --timeout=120s \
  || die "hub-ingress did not roll out. kubectl -n $NS describe pod -l app=hub-ingress"

# ---- both certificates ------------------------------------------------------
# Caddy's admin API is off (see the manifest), so the only way to know a
# certificate actually issued is its own log line. Polling accumulated log
# output rather than a stream: a certificate obtained on an EARLIER run of
# this script, before a restart that changed nothing about the cert itself,
# still counts, and re-checking here costs nothing extra.
say "waiting for both certificates (Let's Encrypt HTTP-01, cloud.$HOST and wardryx.$HOST)"
POD="$(kubectl -n "$NS" get pod -l app=hub-ingress -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$POD" ] || die "no hub-ingress pod found after a successful rollout, which should not happen.
   kubectl -n $NS get pods -l app=hub-ingress"

ok_cloud=0
ok_wardryx=0
for _ in $(seq 1 60); do
  LOG="$(kubectl -n "$NS" logs "$POD" -c caddy --since=10m 2>/dev/null || true)"
  # Per LINE, not per log blob: Caddy's config-loading output always mentions
  # "cloud.$HOST" (it is the site address), whether or not a certificate was
  # ever issued for it, so checking the two substrings independently anywhere
  # in the log would report success before Let's Encrypt was even asked.
  # Caddy's structured log puts both on the one line that reports the event.
  ISSUED="$(printf '%s\n' "$LOG" | grep -F 'certificate obtained successfully' || true)"
  if printf '%s' "$ISSUED" | grep -Fq "cloud.$HOST"; then ok_cloud=1; fi
  if printf '%s' "$ISSUED" | grep -Fq "wardryx.$HOST"; then ok_wardryx=1; fi
  [ "$ok_cloud" = 1 ] && [ "$ok_wardryx" = 1 ] && break
  sleep 5
done

if [ "$ok_cloud" != 1 ] || [ "$ok_wardryx" != 1 ]; then
  die "timed out after 5 minutes waiting for both certificates.
   cloud.$HOST:   $([ "$ok_cloud" = 1 ] && echo ok || echo not seen)
   wardryx.$HOST: $([ "$ok_wardryx" = 1 ] && echo ok || echo not seen)

   Caddy's own log, most recent first:
   kubectl -n $NS logs $POD -c caddy --tail=40

   Common causes: port 80 not actually reachable from the internet yet (a
   cloud firewall, or the forwarding rule still propagating), or Let's
   Encrypt's rate limit for this name already spent this week."
fi

say "up"
cat <<EOF
   https://cloud.$HOST/    -> tokenfuse-cloud (ingest, units, budgets, unit-budgets, kills, run-spend)
   https://wardryx.$HOST/  -> wardryx (decide, filter-tools)

   Next: ./hub/add-site.sh SITE_NAME
EOF
