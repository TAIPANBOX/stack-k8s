#!/usr/bin/env bash
# What this cluster is costing, right now, from what is actually running.
#
#   ./cost-live.sh              # free: counts resources, applies published rates
#   ./cost-live.sh --actual     # also asks Cost Explorer what was really billed
#
# The default path costs NOTHING: every rate below came from AWS's own public
# price list (no account needed) and every count comes from describe calls,
# which are free.
#
# --actual calls Cost Explorer, and Cost Explorer is metered: **USD 0.01 per
# request**. Two requests here, so USD 0.02. That is not a rounding error worth
# hiding, so it is behind a flag and printed before it runs.
set -euo pipefail

REGION="${REGION:-eu-central-1}"
CLUSTER_NAME="${CLUSTER_NAME:-stack-k8s}"
ACTUAL=0
[ "${1:-}" = "--actual" ] && ACTUAL=1

aws_() { aws --region "$REGION" "$@"; }
say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# eu-central-1, on demand, Linux, shared tenancy.
# Source: pricing.us-east-1.amazonaws.com price list published 2026-07-20.
rate_instance() {
  case "$1" in
    c7i.2xlarge) echo 0.4074 ;;
    c7a.2xlarge) echo 0.46852 ;;
    m7i.2xlarge) echo 0.4830 ;;
    *)           echo 0 ;;
  esac
}
RATE_GP3_GB_MONTH=0.0952
RATE_IPV4_HOUR=0.005
RATE_NLB_HOUR=0.027
RATE_EFS_GB_MONTH=0.36

say "running now, in $REGION"

TOTAL=0
add() { TOTAL="$(awk -v a="$TOTAL" -v b="$1" 'BEGIN{printf "%.6f", a+b}')"; }
line() { printf '   %-42s %10s USD/hour\n' "$1" "$(printf '%.4f' "$2")"; }

# Instances
INST="$(aws_ ec2 describe-instances \
  --filters "Name=tag:Cluster,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceType' --output text 2>/dev/null || true)"
if [ -n "$INST" ]; then
  for t in $INST; do
    r="$(rate_instance "$t")"
    [ "$r" = "0" ] && printf '   %-42s %10s (unknown type, add its rate above)\n' "$t" "?"
    add "$r"
  done
  n="$(echo "$INST" | wc -w | tr -d ' ')"
  first="$(echo "$INST" | awk '{print $1}')"
  line "$n x $first" "$(awk -v n="$n" -v r="$(rate_instance "$first")" 'BEGIN{printf "%.6f", n*r}')"
else
  echo "   no running instances tagged Cluster=$CLUSTER_NAME"
fi

# Public IPv4. Every running instance with a public address pays for it, which
# is the line item Hetzner has no equivalent of at all.
IPS="$(aws_ ec2 describe-instances \
  --filters "Name=tag:Cluster,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text 2>/dev/null | tr '\t' '\n' | grep -c . || true)"
if [ "${IPS:-0}" -gt 0 ]; then
  c="$(awk -v n="$IPS" -v r="$RATE_IPV4_HOUR" 'BEGIN{printf "%.6f", n*r}')"
  line "$IPS x public IPv4" "$c"; add "$c"
fi

# EBS
GB="$(aws_ ec2 describe-volumes \
  --filters "Name=tag:Cluster,Values=$CLUSTER_NAME" \
  --query 'Volumes[].Size' --output text 2>/dev/null | tr '\t' '\n' | awk '{s+=$1} END{print s+0}')"
if [ "${GB:-0}" -gt 0 ]; then
  c="$(awk -v g="$GB" -v r="$RATE_GP3_GB_MONTH" 'BEGIN{printf "%.6f", g*r/730}')"
  line "${GB} GB gp3" "$c"; add "$c"
fi

# Load balancers, which is the piece Terraform never knew about
ARNS="$(aws_ elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true)"
LBN=0
if [ -n "$ARNS" ]; then
  # By tag: the in-tree controller names an NLB after the Service UID, so a
  # name-prefix match silently counts zero and understates the bill.
  # shellcheck disable=SC2086
  LBN="$(aws_ elbv2 describe-tags --resource-arns $ARNS \
    --query "TagDescriptions[?Tags[?Key=='kubernetes.io/cluster/$CLUSTER_NAME']].ResourceArn" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -c . || true)"
fi
if [ "${LBN:-0}" -gt 0 ]; then
  c="$(awk -v n="$LBN" -v r="$RATE_NLB_HOUR" 'BEGIN{printf "%.6f", n*r}')"
  line "$LBN x network load balancer" "$c"; add "$c"
fi

# EFS
EFSB="$(aws_ efs describe-file-systems \
  --query "FileSystems[?Name=='$CLUSTER_NAME-events'].SizeInBytes.Value" --output text 2>/dev/null | awk '{s+=$1} END{print s+0}')"
if [ "${EFSB:-0}" -gt 0 ]; then
  c="$(awk -v b="$EFSB" -v r="$RATE_EFS_GB_MONTH" 'BEGIN{printf "%.6f", (b/1073741824)*r/730}')"
  line "efs, $(awk -v b="$EFSB" 'BEGIN{printf "%.2f", b/1073741824}') GiB" "$c"; add "$c"
fi

echo "   ---------------------------------------------------------------------"
printf '   %-42s %10s USD/hour\n' "TOTAL" "$(printf '%.4f' "$TOTAL")"
printf '   %-42s %10s USD\n' "an 8 hour session" "$(awk -v t="$TOTAL" 'BEGIN{printf "%.2f", t*8}')"
printf '   %-42s %10s USD\n' "a 30 day month at this rate" "$(awk -v t="$TOTAL" 'BEGIN{printf "%.2f", t*730}')"
printf '\n   Hetzner baseline, measured: EUR 144.49/month for the same shape\n'
printf '   (5 x CPX42 at EUR 137, plus the lb11 load balancer at EUR 7.49)\n'

if [ "$ACTUAL" = 1 ]; then
  say "actual billed, month to date (this query costs USD 0.02)"
  START="$(date -u +%Y-%m-01)"
  END="$(date -u +%Y-%m-%d)"
  [ "$START" = "$END" ] && START="$(date -u -v-1m +%Y-%m-01 2>/dev/null || date -u -d 'last month' +%Y-%m-01)"
  aws ce get-cost-and-usage \
    --time-period "Start=$START,End=$END" \
    --granularity DAILY --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE \
    --query 'ResultsByTime[].{day:TimePeriod.Start,items:Groups[].{svc:Keys[0],usd:Metrics.UnblendedCost.Amount}}' \
    --output json 2>/dev/null || echo "   Cost Explorer is not enabled on this account, or the user lacks ce:GetCostAndUsage."
  echo
  echo "   Note: Cost Explorer lags real usage by up to 24 hours. During a run,"
  echo "   trust the resource count above; use this the morning after."
fi
