#!/usr/bin/env bash
# Stop paying for this cluster, and prove that you stopped.
#
#   ./teardown.sh            # asks first, shows what it found
#   ./teardown.sh --yes      # no prompt
#   ./teardown.sh --check    # find leftovers, delete nothing
#
# `terraform destroy` alone is NOT enough, and the reason is the interesting
# part of this file. The cloud controller creates the load balancer, so
# Terraform has never heard of it. That NLB lives in the VPC Terraform is
# trying to delete, which means:
#
#   - destroy FAILS with a DependencyViolation on the subnet, and
#   - if you then delete the VPC by hand and miss the balancer, it keeps
#     billing USD 0.027/hour attached to nothing
#
# So the order here is: unmake what Kubernetes made, THEN destroy, THEN look
# again for anything either step left behind.
#
# PORTABILITY.md asks "one command, or a hunt for orphaned resources?". This
# file is the answer for AWS, and the answer is: one command, but only because
# someone already did the hunt.
set -euo pipefail

REGION="${REGION:-eu-central-1}"
CLUSTER_NAME="${CLUSTER_NAME:-stack-k8s}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-./kubeconfig.yaml}"
ASSUME_YES=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)   ASSUME_YES=1; shift ;;
    --check)    CHECK_ONLY=1; shift ;;
    --region)   REGION="$2"; shift 2 ;;
    -h|--help)  sed -n '2,26p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '   !! %s\n' "$*"; }
aws_() { aws --region "$REGION" "$@"; }

# Load balancers are found by TAG, not by name. The in-tree service controller
# names an NLB after the Service UID (a18d10d98be3c4e39b41b27fe205c1a9), not
# k8s-<ns>-<svc> as the separate AWS Load Balancer Controller does. A sweep
# keyed on a name prefix therefore finds nothing and reports "clear" over an
# orphan that is still billing, which is the exact failure this script exists
# to prevent. Both controllers tag with kubernetes.io/cluster/<name>.
cluster_lbs() {
  local arns
  arns="$(aws_ elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true)"
  [ -z "$arns" ] && return 0
  # shellcheck disable=SC2086
  aws_ elbv2 describe-tags --resource-arns $arns \
    --query "TagDescriptions[?Tags[?Key=='kubernetes.io/cluster/$CLUSTER_NAME']].ResourceArn" \
    --output text 2>/dev/null || true
}


command -v aws >/dev/null || { echo "aws cli not found" >&2; exit 1; }

# Which account is this? A teardown pointed at the wrong account is the one
# mistake this script could make that costs more than leaving the cluster up.
say "account"
ACCOUNT="$(aws_ sts get-caller-identity --query Account --output text)"
ARN="$(aws_ sts get-caller-identity --query Arn --output text)"
echo "   $ACCOUNT  $ARN"
echo "   region $REGION, cluster $CLUSTER_NAME"

# ---- 1. what is currently costing money ------------------------------------
say "what exists right now"

VPC_ID="$(terraform output -json ccm_config 2>/dev/null | sed -n 's/.*"vpc_id":"\([^"]*\)".*/\1/p' || true)"
if [ -z "$VPC_ID" ]; then
  VPC_ID="$(aws_ ec2 describe-vpcs \
    --filters "Name=tag:Cluster,Values=$CLUSTER_NAME" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
fi
[ "$VPC_ID" = "None" ] && VPC_ID=""
echo "   vpc: ${VPC_ID:-<none found>}"

INSTANCES="$(aws_ ec2 describe-instances \
  --filters "Name=tag:Cluster,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output text 2>/dev/null || true)"
echo "   instances:"
[ -n "$INSTANCES" ] && echo "$INSTANCES" | sed 's/^/     /' || echo "     none"

if [ -n "$VPC_ID" ]; then
  LBS="$(aws_ elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].[LoadBalancerArn,LoadBalancerName,Type]" --output text 2>/dev/null || true)"
else
  LBS=""
fi
echo "   load balancers in the vpc:"
[ -n "$LBS" ] && echo "$LBS" | sed 's/^/     /' || echo "     none"

EFS="$(aws_ efs describe-file-systems \
  --query "FileSystems[?Name=='$CLUSTER_NAME-events'].[FileSystemId,SizeInBytes.Value]" --output text 2>/dev/null || true)"
echo "   efs:"
[ -n "$EFS" ] && echo "$EFS" | sed 's/^/     /' || echo "     none"

ORPHAN_VOLS="$(aws_ ec2 describe-volumes \
  --filters "Name=status,Values=available" "Name=tag:Cluster,Values=$CLUSTER_NAME" \
  --query 'Volumes[].[VolumeId,Size]' --output text 2>/dev/null || true)"
echo "   unattached volumes:"
[ -n "$ORPHAN_VOLS" ] && echo "$ORPHAN_VOLS" | sed 's/^/     /' || echo "     none"

UNUSED_EIPS="$(aws_ ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' --output text 2>/dev/null || true)"
echo "   unassociated elastic IPs (bill at USD 0.005/hour doing nothing):"
[ -n "$UNUSED_EIPS" ] && echo "$UNUSED_EIPS" | sed 's/^/     /' || echo "     none"

if [ "$CHECK_ONLY" = 1 ]; then
  say "--check: nothing deleted"
  exit 0
fi

if [ "$ASSUME_YES" = 0 ]; then
  printf '\n\033[1mDelete all of the above from account %s? [type yes] \033[0m' "$ACCOUNT"
  read -r reply
  [ "$reply" = "yes" ] || { echo "stopped, nothing deleted"; exit 0; }
fi

# ---- 2. unmake what Kubernetes made ----------------------------------------
# Before Terraform, because Terraform cannot delete a subnet that a load
# balancer it does not own is sitting in.
if [ -f "$KUBECONFIG_FILE" ] && command -v kubectl >/dev/null; then
  say "removing type=LoadBalancer Services, so the controller deletes its NLB"
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
  echo "   (no kubeconfig or no kubectl: skipping, the sweep below still catches the balancer)"
fi

# Whatever the controller did not clean up, by VPC. This is the step that
# turns "destroy failed with DependencyViolation" into "destroy succeeded".
#
# Re-queried rather than reusing the list from the top of the script: the
# controller has just been asked to delete these, and acting on a stale list
# means every line reports a failure that is actually a success.
if [ -n "$VPC_ID" ]; then
  LBS="$(aws_ elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].[LoadBalancerArn,LoadBalancerName,Type]" --output text 2>/dev/null || true)"
fi
if [ -n "$VPC_ID" ] && [ -n "$LBS" ]; then
  say "deleting load balancers left in the vpc"
  echo "$LBS" | while read -r arn name type; do
    [ -z "$arn" ] && continue
    echo "   $name ($type)"
    aws_ elbv2 delete-load-balancer --load-balancer-arn "$arn" || warn "could not delete $name"
  done
  sleep 20
  say "deleting orphaned target groups"
  aws_ elbv2 describe-target-groups --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null \
    | tr '\t' '\n' | while read -r tg; do
        [ -z "$tg" ] && continue
        echo "   $tg"
        aws_ elbv2 delete-target-group --target-group-arn "$tg" || warn "could not delete $tg"
      done
fi

# The controller creates its own security group for the balancer and tags it
# with the cluster. Terraform does not own it, and the VPC will not delete
# while it exists.
if [ -n "$VPC_ID" ]; then
  say "deleting security groups the controller created"
  aws_ ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null \
    | tr '\t' '\n' | while read -r sg; do
        [ -z "$sg" ] && continue
        # The node group is Terraform's; leave it for destroy.
        nm="$(aws_ ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].GroupName' --output text)"
        [ "$nm" = "$CLUSTER_NAME-nodes" ] && continue
        echo "   $sg ($nm)"
        aws_ ec2 delete-security-group --group-id "$sg" || warn "could not delete $sg, it may still be in use"
      done
fi

# ---- 3. Terraform --------------------------------------------------------
say "terraform destroy"
if [ -f terraform.tfstate ] || [ -d .terraform ]; then
  terraform destroy -auto-approve
else
  warn "no terraform state here. Falling back to the sweep only."
fi

# ---- 4. look again -------------------------------------------------------
# A teardown that reports success without re-checking is a teardown that has
# not been verified, which is the same standard the rest of this repo holds
# itself to.
say "sweep: what is left in $REGION tagged Cluster=$CLUSTER_NAME"
LEFT=0
check() {
  local label="$1"; shift
  local out; out="$("$@" 2>/dev/null || true)"
  if [ -n "$out" ] && [ "$out" != "None" ]; then
    warn "$label still present:"; echo "$out" | sed 's/^/       /'; LEFT=1
  else
    printf '   clear: %s\n' "$label"
  fi
}

check "instances" aws_ ec2 describe-instances \
  --filters "Name=tag:Cluster,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text
check "volumes" aws_ ec2 describe-volumes \
  --filters "Name=tag:Cluster,Values=$CLUSTER_NAME" --query 'Volumes[].VolumeId' --output text
check "snapshots" aws_ ec2 describe-snapshots --owner-ids "$ACCOUNT" \
  --filters "Name=tag:Cluster,Values=$CLUSTER_NAME" --query 'Snapshots[].SnapshotId' --output text
check "vpcs" aws_ ec2 describe-vpcs \
  --filters "Name=tag:Cluster,Values=$CLUSTER_NAME" --query 'Vpcs[].VpcId' --output text
check "efs" aws_ efs describe-file-systems \
  --query "FileSystems[?Name=='$CLUSTER_NAME-events'].FileSystemId" --output text
check "unassociated elastic IPs" aws_ ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].AllocationId' --output text

# Load balancers carry no Cluster tag once Terraform's VPC is gone, so this one
# is checked by name prefix: the controller names them k8s-<namespace>-<service>.
check "load balancers tagged for this cluster" cluster_lbs

echo
if [ "$LEFT" = 0 ]; then
  printf '\033[1m   Nothing left. The meter is at zero for this cluster.\033[0m\n'
else
  printf '\033[1m   Something is still there. It is still billing. Delete it before closing the laptop.\033[0m\n'
  exit 1
fi

cat <<EOF

  Two things this script deliberately does NOT delete:

    - your SSH keypair (~/.ssh/stack-k8s-aws), which costs nothing and is
      yours
    - the IAM user and its access key, which cost nothing and are reused for
      the next run. Delete the ACCESS KEY yourself when the comparison is
      finished, in the console under IAM > Users > stack-k8s-deploy.

  Check the bill tomorrow, not just this output:

    ./cost-live.sh
EOF
