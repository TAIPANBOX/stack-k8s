#!/usr/bin/env bash
# What this cluster is costing, right now, from what is actually running.
#
#   ./cost-live.sh
#
# Free. Every rate below came from Google's own Cloud Billing Catalog API
# (cloudbilling.googleapis.com/v1/services/6F81-5844-456A/skus, region
# europe-west3, OnDemand, USD), read on 2026-07-26 and recorded in ../COSTS.md
# with the SKU description each number came from. Every count comes from list
# calls, which are free.
#
# Unlike the AWS script there is no --actual mode. GCP's equivalent of Cost
# Explorer is a BigQuery billing export that has to be set up in advance and
# lags by hours; asking for it from here would create a dataset nobody asked
# for. The credits balance lives in the console under Billing > Credits.
set -euo pipefail

REGION="${REGION:-europe-west3}"
CLUSTER_NAME="${CLUSTER_NAME:-stack-k8s}"
PROJECT="${GCP_PROJECT:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$PROJECT" ]; then
  PROJECT="$(grep -E '^\s*project_id' terraform.tfvars 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/' || true)"
fi
[ -n "$PROJECT" ] || PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[ -n "$PROJECT" ] && [ "$PROJECT" != "(unset)" ] || { echo "no project: pass --project <project-id>" >&2; exit 1; }

g() { gcloud --project="$PROJECT" "$@"; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# Frankfurt, on demand. Machine types are priced per core-hour plus per GiB-hour
# rather than per instance, which is why these are two numbers and not one, and
# why a custom machine type would be priceable by the same formula.
rate_machine() {
  case "$1" in
    c3d-highcpu-8)  echo 0.35382064 ;;  # 8 x 0.03488434 + 16 x 0.00467162
    c3d-standard-8) echo 0.42027392 ;;  # 8 x 0.03488434 + 32 x 0.00467162
    c3-highcpu-8)   echo 0.40144544 ;;  # 8 x 0.040887   + 16 x 0.00464684
    c3-standard-8)  echo 0.47614688 ;;  # 8 x 0.040887   + 32 x 0.00464684
    *)              echo 0 ;;
  esac
}
RATE_PD_BALANCED_GB_MONTH=0.12
RATE_IPV4_HOUR=0.005          # External IP Charge on a Standard VM, in use
RATE_ADDRESS_IDLE_HOUR=0.012  # Static Ip Charge in Frankfurt, reserved and unused
RATE_FWD_RULE_HOUR=0.030      # Cloud Load Balancer Forwarding Rule Minimum, Frankfurt
RATE_FILESTORE_HDD_GB_MONTH=0.19

say "running now, in $PROJECT / $REGION"

TOTAL=0
add()  { TOTAL="$(awk -v a="$TOTAL" -v b="$1" 'BEGIN{printf "%.6f", a+b}')"; }
line() { printf '   %-44s %10s USD/hour\n' "$1" "$(printf '%.4f' "$2")"; }

# Instances
TYPES="$(g compute instances list --filter="labels.cluster=$CLUSTER_NAME AND status=RUNNING" \
  --format='value(machineType.basename())' 2>/dev/null || true)"
if [ -n "$TYPES" ]; then
  for t in $(printf '%s\n' "$TYPES" | sort -u); do
    n="$(printf '%s\n' "$TYPES" | grep -c "^$t$" || true)"
    r="$(rate_machine "$t")"
    if [ "$r" = "0" ]; then
      printf '   %-44s %10s (unknown type, add its rate above)\n' "$n x $t" "?"
    else
      c="$(awk -v n="$n" -v r="$r" 'BEGIN{printf "%.6f", n*r}')"
      line "$n x $t" "$c"; add "$c"
    fi
  done
else
  echo "   no running instances labelled cluster=$CLUSTER_NAME"
fi

# Public addresses in use. Same rate as AWS charges, to the cent.
IPS="$(g compute instances list --filter="labels.cluster=$CLUSTER_NAME AND status=RUNNING" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null | grep -c . || true)"
if [ "${IPS:-0}" -gt 0 ]; then
  c="$(awk -v n="$IPS" -v r="$RATE_IPV4_HOUR" 'BEGIN{printf "%.6f", n*r}')"
  line "$IPS x external IPv4, in use (upper bound)" "$c"; add "$c"
  printf '   %s\n' "   ^ the SKU's first tier is 744 IP-hours a month at zero, so a run"
  printf '   %s\n' "     shorter than about six days pays nothing for its addresses"
fi

# Reserved addresses attached to nothing, which is the expensive kind of idle:
# more than twice the rate of one that is doing work.
IDLE="$(g compute addresses list --regions="$REGION" --filter="status=RESERVED" --format='value(name)' 2>/dev/null | grep -c . || true)"
if [ "${IDLE:-0}" -gt 0 ]; then
  c="$(awk -v n="$IDLE" -v r="$RATE_ADDRESS_IDLE_HOUR" 'BEGIN{printf "%.6f", n*r}')"
  line "$IDLE x reserved address, attached to nothing" "$c"; add "$c"
fi

# Disks
GB="$(g compute disks list --format='value(sizeGb)' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
if [ "${GB:-0}" -gt 0 ]; then
  c="$(awk -v g="$GB" -v r="$RATE_PD_BALANCED_GB_MONTH" 'BEGIN{printf "%.6f", g*r/730}')"
  line "${GB} GB pd-balanced" "$c"; add "$c"
fi

# Load balancers, the piece Terraform never knew about
FWD="$(g compute forwarding-rules list --regions="$REGION" --format='value(name)' 2>/dev/null | grep -c . || true)"
if [ "${FWD:-0}" -gt 0 ]; then
  c="$(awk -v n="$FWD" -v r="$RATE_FWD_RULE_HOUR" 'BEGIN{printf "%.6f", n*r}')"
  line "$FWD x forwarding rule (load balancer)" "$c"; add "$c"
fi

# Filestore, billed on PROVISIONED capacity, not used
FSGB="$(g filestore instances list --format='value(fileShares[0].capacityGb)' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
if [ "${FSGB:-0}" -gt 0 ]; then
  c="$(awk -v g="$FSGB" -v r="$RATE_FILESTORE_HDD_GB_MONTH" 'BEGIN{printf "%.6f", g*r/730}')"
  line "filestore, ${FSGB} GB provisioned" "$c"; add "$c"
fi

echo "   -----------------------------------------------------------------------"
printf '   %-44s %10s USD/hour\n' "TOTAL" "$(printf '%.4f' "$TOTAL")"
printf '   %-44s %10s USD\n' "an 8 hour session" "$(awk -v t="$TOTAL" 'BEGIN{printf "%.2f", t*8}')"
printf '   %-44s %10s USD\n' "a 30 day month at this rate" "$(awk -v t="$TOTAL" 'BEGIN{printf "%.2f", t*730}')"
printf '\n   Hetzner baseline, measured:   EUR 144.49/month for the same shape\n'
printf '   AWS, same shape, published:   USD 1,862/month\n'
printf '\n   Egress is not counted above and has no free allowance here: GCP bills\n'
printf '   USD 0.12/GiB out of Frankfurt to western Europe from the first GiB,\n'
printf '   where AWS gives 100 GB/month free and Hetzner includes 20 TB per node.\n'
