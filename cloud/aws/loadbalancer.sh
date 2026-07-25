#!/usr/bin/env bash
# Publish the console through an AWS Network Load Balancer, and make it
# actually carry traffic.
#
#   ./loadbalancer.sh          # create, fix, verify
#   ./loadbalancer.sh --down   # delete it and stop the meter
#
# METERED: about USD 0.027/hour plus capacity units, so roughly USD 19.71 a
# month, against EUR 7.49 for the Hetzner lb11 this replaces.
#
# ---------------------------------------------------------------------------
# Why this is a script and not just `kubectl apply -f loadbalancer-aws.yaml`.
#
# An AWS NLB with instance targets preserves the CLIENT address by default.
# That single default breaks the deployment in a way that reports success:
#
#   - traffic reaches the pod from a public address, so the NetworkPolicy
#     (ipBlock 10.10.0.0/16, correct on Hetzner) drops every request
#   - it also reaches the NODE from a public address, so the security group
#     (NodePort range from the subnet only) drops it one layer earlier
#   - and the health check goes to a SEPARATE healthCheckNodePort that
#     kube-proxy answers on the host without ever touching the pod, so AWS
#     reports the target healthy the whole time
#
# Healthy balancer, zero traffic, nothing in any log. GOTCHAS.md item 45.
#
# There are two ways out and this script takes the tighter one. Opening both
# layers to 0.0.0.0/0 works and costs the cluster its default-deny posture on
# the one port that faces the internet. Turning OFF client-IP preservation
# instead makes traffic arrive from inside the subnet, exactly as the Hetzner
# balancer does with use-private-ip, so the security group and the
# NetworkPolicy both stay as they are and both clouds keep the same posture.
#
# It cannot be expressed in the Service. The obvious annotation,
# service.beta.kubernetes.io/aws-load-balancer-preserve-client-ip, belongs to
# the separate AWS Load Balancer Controller; the in-tree service controller
# used here ignores it. Verified on 2026-07-25 by creating the Service with
# the annotation present from the start: preserve_client_ip.enabled came up
# true anyway. So the attribute is set on the target group afterwards, here,
# where it is visible rather than buried in a runbook.
#
# The cost of this approach, stated plainly: the console sees the balancer's
# address instead of the real client address. That is also what happens on
# Hetzner, so the two runs stay comparable, but it is a real limitation for
# anything that wants per-client rate limiting or audit by source address.
set -euo pipefail

REGION="${REGION:-eu-central-1}"
NS="${NS:-agent-stack}"
SVC="${SVC:-genaryx-console-lb}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-./kubeconfig.yaml}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
kc() { KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
aws_() { aws --region "$REGION" "$@"; }

if [ "${1:-}" = "--down" ]; then
  say "deleting $SVC (this deletes the balancer and stops the meter)"
  kc -n "$NS" delete svc "$SVC" --ignore-not-found
  echo "   gone. ./teardown.sh --check will confirm nothing is left billing."
  exit 0
fi

command -v kubectl >/dev/null || die "kubectl not found"
[ -f "$KUBECONFIG_FILE" ] || die "no $KUBECONFIG_FILE: run install-aws.sh first"

say "creating the Service"
kc apply -f "$HERE/loadbalancer-aws.yaml"

say "waiting for the balancer to get an address"
HOST=""
for _ in $(seq 1 40); do
  HOST="$(kc -n "$NS" get svc "$SVC" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$HOST" ] && break
  sleep 5
done
[ -n "$HOST" ] || die "the Service never got an address. Is the cloud controller running?
   kubectl -n kube-system get pods -l k8s-app=aws-cloud-controller-manager"
echo "   $HOST"

# The target groups exist only once the controller has created them, and each
# Service port gets its own. Both need the attribute.
say "turning off client-IP preservation on every target group"
NODEPORTS="$(kc -n "$NS" get svc "$SVC" -o jsonpath='{range .spec.ports[*]}{.nodePort}{"\n"}{end}')"
[ -n "$NODEPORTS" ] || die "the Service has no nodePorts, which should be impossible"

FIXED=0
for _ in $(seq 1 24); do
  FIXED=0
  for np in $NODEPORTS; do
    tg="$(aws_ elbv2 describe-target-groups \
      --query "TargetGroups[?Port==\`$np\`].TargetGroupArn|[0]" --output text 2>/dev/null || true)"
    [ -z "$tg" ] || [ "$tg" = "None" ] && continue
    aws_ elbv2 modify-target-group-attributes --target-group-arn "$tg" \
      --attributes Key=preserve_client_ip.enabled,Value=false >/dev/null 2>&1 || true
    v="$(aws_ elbv2 describe-target-group-attributes --target-group-arn "$tg" \
      --query "Attributes[?Key=='preserve_client_ip.enabled'].Value|[0]" --output text 2>/dev/null || true)"
    [ "$v" = "false" ] && { echo "   nodePort $np: preserve_client_ip=false"; FIXED=$((FIXED + 1)); }
  done
  want="$(printf '%s\n' "$NODEPORTS" | grep -c . || true)"
  [ "$FIXED" -ge "$want" ] && break
  sleep 5
done
[ "$FIXED" -gt 0 ] || die "no target group ever appeared for nodePorts: $NODEPORTS"

# The whole point of the file. A balancer that reports healthy proves nothing;
# a request that returns proves it carries traffic.
say "proving it actually carries traffic"
# NOTE the shape of this assignment. `CODE="$(curl ... || echo 000)"` looks
# equivalent and is not: on failure curl's own -w prints 000 AND the echo adds
# another, so CODE becomes "000000", which is not equal to "000", so the loop
# exits on the first attempt and the script reports success against a balancer
# that is still provisioning. Written wrong here once already.
CODE=000
for _ in $(seq 1 30); do
  CODE="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://$HOST/" 2>/dev/null)" || CODE=000
  case "$CODE" in
    ''|000) : ;;
    *) break ;;
  esac
  sleep 10
done

if [ "$CODE" = "000" ]; then
  aws_ elbv2 describe-target-health --target-group-arn \
    "$(aws_ elbv2 describe-target-groups --query "TargetGroups[?Port==\`$(printf '%s\n' "$NODEPORTS" | head -1)\`].TargetGroupArn|[0]" --output text)" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text 2>/dev/null || true
  die "the balancer is up and answers nothing. Target health is above.
   If targets are HEALTHY and this still fails, it is a source-address problem,
   not a health problem: check the security group NodePort rule and the
   console-ingress-lb NetworkPolicy. See GOTCHAS.md item 45."
fi

cat <<EOF

$(printf '\033[1m')The console is published and answering: HTTP $CODE$(printf '\033[0m')

    http://$HOST/

  Over plain HTTP, which means a sign-in page on the public internet. Put TLS
  in front of it before it holds anything real.

  Stop the meter:  ./loadbalancer.sh --down
EOF
