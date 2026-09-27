#!/usr/bin/env bash
# Take the hub's public entry down, LoadBalancer first.
#
#   ./hub/down.sh
#
# Order matters, the same fact manifests/53-hub-entry.yaml's own header states
# and cloud/{aws,gcp}/teardown.sh already act on for the console's balancer:
# Kubernetes creates this LoadBalancer, not Terraform, so a `terraform destroy`
# run before this Service is gone leaves a forwarding rule (and on GCP, its
# firewall rules) that Terraform has never heard of, still billing, and in the
# way of the destroy. This script deletes the Service and WAITS for it to be
# gone before touching anything else.
#
# KUBECONFIG comes from the environment, same as every other script here.
# Idempotent: running it again once everything is already gone reports so and
# exits 0, rather than failing on objects that no longer exist.
set -euo pipefail

NS="${NS:-agent-stack}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '   !! %s\n' "$*"; }

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

say "deleting the hub-ingress Service (the metered LoadBalancer)"
if kubectl -n "$NS" get svc hub-ingress >/dev/null 2>&1; then
  kubectl -n "$NS" delete svc hub-ingress --wait=true --timeout=120s
else
  echo "   already gone"
fi

say "waiting for the cloud controller to finish releasing the balancer"
# The Service object going away is not the same moment the forwarding rule
# does; cloud/*/teardown.sh's own sleep after this same delete is 30s, which
# is what this waits for here too.
sleep 30

say "removing the rest of manifests/53-hub-entry.yaml"
kubectl -n "$NS" delete -f "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/manifests/53-hub-entry.yaml" \
  --ignore-not-found=true --wait=true 2>&1 | sed 's/^/   /'

cat <<EOF

  Left as they are, on purpose: the stack-keys Secret's cloud_keys and
  wardryx_keys entries for every site this hub ever added, and the
  site-*.env files hub/add-site.sh wrote. Taking the entry down does not
  revoke a site's credentials; that is a separate, explicit decision
  (edit stack-keys by hand and restart tokenfuse-cloud and wardryx).

  This script does NOT touch Terraform or any other cloud resource. If this
  cluster is about to be torn down entirely:

    1. confirm the sweep above actually left nothing:
       kubectl -n $NS get svc hub-ingress   (should be NotFound)
    2. then run cloud/gcp/teardown.sh or cloud/aws/teardown.sh, which sweep
       every LoadBalancer Service in the cluster the same way, first, before
       terraform destroy
    3. check the provider console yourself for the forwarding rule (GCP) or
       the NLB (AWS): a script's own "clear" is not the same as the bill
       actually stopping until you have seen it
EOF
