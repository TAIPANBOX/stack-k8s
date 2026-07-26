#!/usr/bin/env bash
# Stop paying for this cluster, and prove that you stopped.
#
#   ./teardown.sh            # asks first, shows what it found
#   ./teardown.sh --yes      # no prompt
#   ./teardown.sh --check    # find leftovers, delete nothing
#
# `terraform destroy` alone is NOT enough, and the reason is the same on all
# three clouds with different nouns. The cloud controller creates the load
# balancer, so Terraform has never heard of it. On GCP that is not one object
# but four: a forwarding rule, a target pool, a health check and a FIREWALL
# RULE, and the firewall rule alone is enough to make the VPC undeletable.
#
# So the order here is: unmake what Kubernetes made, THEN destroy, THEN look
# again for anything either step left behind.
#
# ../PORTABILITY.md asks "one command, or a hunt for orphaned resources?". This
# file is the answer for GCP, and the answer is: one command, but only because
# someone already did the hunt.
set -euo pipefail

REGION="${REGION:-europe-west3}"
ZONE="${ZONE:-${REGION}-a}"
CLUSTER_NAME="${CLUSTER_NAME:-stack-k8s}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-./kubeconfig.yaml}"
PROJECT="${GCP_PROJECT:-}"
ASSUME_YES=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=1; shift ;;
    --check)    CHECK_ONLY=1; shift ;;
    --project)  PROJECT="$2"; shift 2 ;;
    --region)   REGION="$2"; ZONE="${REGION}-a"; shift 2 ;;
    -h|--help)  sed -n '2,22p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '   !! %s\n' "$*"; }

# A teardown must never sit waiting for an answer nobody is there to give.
# gcloud offers to enable a disabled API and blocks on the reply, which in this
# script would mean a cluster still billing behind a blinking cursor. The one
# question worth asking here is asked below, by this script, in its own words.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

command -v gcloud >/dev/null || { echo "gcloud not found" >&2; exit 1; }

if [ -z "$PROJECT" ]; then
  PROJECT="$(grep -E '^\s*project_id' terraform.tfvars 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/' || true)"
fi
[ -n "$PROJECT" ] || PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
[ -n "$PROJECT" ] && [ "$PROJECT" != "(unset)" ] || { echo "no project: pass --project <project-id>" >&2; exit 1; }

g() { gcloud --project="$PROJECT" "$@"; }
NET="$CLUSTER_NAME"

# Which project is this? A teardown pointed at the wrong project is the one
# mistake this script could make that costs more than leaving the cluster up.
say "project"
echo "   $PROJECT   region $REGION   cluster $CLUSTER_NAME"
echo "   account: $(gcloud config get-value account 2>/dev/null)"

# ---- 1. what is currently costing money ------------------------------------
say "what exists right now"

INSTANCES="$(g compute instances list --filter="labels.cluster=$CLUSTER_NAME" --format='value(name,machineType.basename(),status)' 2>/dev/null || true)"
echo "   instances:"
[ -n "$INSTANCES" ] && echo "$INSTANCES" | sed 's/^/     /' || echo "     none"

FWD="$(g compute forwarding-rules list --regions="$REGION" --format='value(name,IPAddress,target.basename())' 2>/dev/null || true)"
echo "   forwarding rules (each one is a load balancer, USD 0.030/hour):"
[ -n "$FWD" ] && echo "$FWD" | sed 's/^/     /' || echo "     none"

POOLS="$(g compute target-pools list --regions="$REGION" --format='value(name)' 2>/dev/null || true)"
echo "   target pools:"
[ -n "$POOLS" ] && echo "$POOLS" | sed 's/^/     /' || echo "     none"

ADDR="$(g compute addresses list --regions="$REGION" --filter="status=RESERVED" --format='value(name,address,status)' 2>/dev/null || true)"
echo "   reserved addresses (bill at USD 0.012/hour doing nothing):"
[ -n "$ADDR" ] && echo "$ADDR" | sed 's/^/     /' || echo "     none"

DISKS="$(g compute disks list --filter="-users:*" --format='value(name,sizeGb,zone.basename())' 2>/dev/null || true)"
echo "   unattached disks:"
[ -n "$DISKS" ] && echo "$DISKS" | sed 's/^/     /' || echo "     none"

FS="$(g filestore instances list --format='value(name,tier,fileShares[0].capacityGb)' 2>/dev/null || true)"
echo "   filestore (1 TiB minimum, USD 194/month):"
[ -n "$FS" ] && echo "$FS" | sed 's/^/     /' || echo "     none"

if [ "$CHECK_ONLY" = 1 ]; then
  say "--check: nothing deleted"
  exit 0
fi

if [ "$ASSUME_YES" = 0 ]; then
  printf '\n\033[1mDelete all of the above from project %s? [type yes] \033[0m' "$PROJECT"
  read -r reply
  [ "$reply" = "yes" ] || { echo "stopped, nothing deleted"; exit 0; }
fi

# ---- 2. unmake what Kubernetes made ----------------------------------------
# Before Terraform, because Terraform cannot delete a network that a firewall
# rule it does not own is attached to.
if [ -f "$KUBECONFIG_FILE" ] && command -v kubectl >/dev/null; then
  say "removing type=LoadBalancer Services, so the controller deletes its balancer"
  svcs="$(KUBECONFIG="$KUBECONFIG_FILE" kubectl get svc -A \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [ -n "$svcs" ]; then
    echo "$svcs" | while read -r ns name; do
      [ -z "$ns" ] && continue
      echo "   deleting svc $ns/$name"
      KUBECONFIG="$KUBECONFIG_FILE" kubectl -n "$ns" delete svc "$name" --wait=true --timeout=120s || true
    done
    echo "   waiting 30s for the controller to finish deleting the balancer"
    sleep 30
  else
    echo "   none"
  fi
else
  echo "   (no kubeconfig or no kubectl: skipping, the sweep below still catches it)"
fi

# Whatever the controller did not clean up. Re-queried rather than reusing the
# list from the top: the controller has just been asked to delete these, and
# acting on a stale list makes every line report a failure that is a success.
#
# Order matters and is not guessable: a forwarding rule pins its target pool,
# a target pool pins its health check, and all three outlive the Service if the
# controller was already gone when it was deleted.
say "sweeping the load balancer objects the controller owns"
for f in $(g compute forwarding-rules list --regions="$REGION" --format='value(name)' 2>/dev/null || true); do
  echo "   forwarding rule $f"
  g compute forwarding-rules delete "$f" --region="$REGION" --quiet || warn "could not delete $f"
done
for p in $(g compute target-pools list --regions="$REGION" --format='value(name)' 2>/dev/null || true); do
  echo "   target pool $p"
  g compute target-pools delete "$p" --region="$REGION" --quiet || warn "could not delete $p"
done
for h in $(g compute http-health-checks list --format='value(name)' 2>/dev/null || true); do
  echo "   http health check $h"
  g compute http-health-checks delete "$h" --quiet || warn "could not delete $h"
done

# The controller's own firewall rules, named k8s-*. Terraform does not own them
# and the network will not delete while they exist.
say "sweeping firewall rules the controller created"
for fw in $(g compute firewall-rules list --filter="network:$NET AND name~^k8s-" --format='value(name)' 2>/dev/null || true); do
  echo "   $fw"
  g compute firewall-rules delete "$fw" --quiet || warn "could not delete $fw"
done

# ---- 3. Terraform --------------------------------------------------------
say "terraform destroy"
if [ -f terraform.tfstate ] || [ -d .terraform ]; then
  terraform destroy -auto-approve
else
  warn "no terraform state here. Falling back to the sweep only."
fi

# ---- 4. look again -------------------------------------------------------
# A teardown that reports success without re-checking is a teardown that has not
# been verified, which is the same standard the rest of this repo holds itself
# to.
say "sweep: what is left in $PROJECT"
LEFT=0
check() {
  local label="$1"; shift
  local out; out="$("$@" 2>/dev/null || true)"
  if [ -n "$out" ]; then
    warn "$label still present:"; echo "$out" | sed 's/^/       /'; LEFT=1
  else
    printf '   clear: %s\n' "$label"
  fi
}

check "instances" g compute instances list --format='value(name)'
check "disks" g compute disks list --format='value(name)'
check "forwarding rules" g compute forwarding-rules list --regions="$REGION" --format='value(name)'
check "target pools" g compute target-pools list --regions="$REGION" --format='value(name)'
check "reserved addresses" g compute addresses list --regions="$REGION" --format='value(name)'
check "firewall rules on $NET" g compute firewall-rules list --filter="network:$NET" --format='value(name)'
check "networks" g compute networks list --filter="name=$NET" --format='value(name)'
check "filestore" g filestore instances list --format='value(name)'
check "snapshots" g compute snapshots list --format='value(name)'

echo
if [ "$LEFT" = 0 ]; then
  printf '\033[1m   Nothing left. The meter is at zero for this project.\033[0m\n'
else
  printf '\033[1m   Something is still there. It is still billing. Delete it before closing the laptop.\033[0m\n'
  exit 1
fi

cat <<EOF

  Two things this script deliberately does NOT delete:

    - your SSH keypair (~/.ssh/stack-k8s-gcp), which costs nothing and is yours
    - the PROJECT itself, which costs nothing empty and is reused for the next
      run. GCP has a kill switch the other two clouds do not:

        gcloud projects delete $PROJECT

      That removes everything in it at once, billable or not, with a 30 day
      undo. It is the only teardown that cannot miss anything, and it is the
      project owner's call, not this script's.

  Check the bill tomorrow, not just this output. Billing data lags real usage
  by several hours on every cloud.
EOF
