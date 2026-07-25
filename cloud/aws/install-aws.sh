#!/usr/bin/env bash
# Bring up the cluster this repo's manifests target, on AWS EC2 instances that
# `terraform apply` has already created.
#
#   ./install-aws.sh --servers 1.2.3.4,1.2.3.5,1.2.3.6 --agents 1.2.3.7,1.2.3.8
#
# This is ../../install.sh with the Hetzner-specific parts replaced, and the
# replacements are the point of the file: each one is a line in the comparison
# PORTABILITY.md asks for. There are exactly five of them, and they are marked
# [AWS] below:
#
#   1. the metadata service needs a token before it answers anything
#   2. provider-id is aws:///<az>/<instance-id>, not hcloud://<id>
#   3. the firewall is a security group, created by Terraform, not by this
#      script against a provider API
#   4. the cloud controller reads credentials from the instance profile, and
#      has to be TOLD its VPC, subnet, zone and cluster id, because on a
#      self-managed cluster nothing discovers them
#   5. ssh lands as `ubuntu`, not `root`
#
# Everything else, and that is most of it, is identical: k3s with the same
# flags, Calico for the same reason, Longhorn with the same RWX class, the same
# generated Secrets. That similarity is also a finding.
set -euo pipefail

# ---- knobs -----------------------------------------------------------------
SERVERS=""
AGENTS=""
SSH_KEY="${SSH_KEY:-$HOME/.ssh/stack-k8s-aws}"
SSH_USER="${SSH_USER:-ubuntu}"                      # [AWS] 5: Ubuntu AMIs have no root login
K3S_VERSION="${K3S_VERSION:-v1.36.2+k3s1}"          # same pin as the Hetzner run
CALICO_VERSION="${CALICO_VERSION:-v3.29.1}"
LONGHORN_VERSION="${LONGHORN_VERSION:-v1.7.2}"
CCM_VERSION="${CCM_VERSION:-v1.36.1}"               # [AWS] cloud-provider-aws, matched to k8s 1.36
POD_CIDR="${POD_CIDR:-10.42.0.0/16}"
CLUSTER_NAME="${CLUSTER_NAME:-stack-k8s}"           # [AWS] must equal the kubernetes.io/cluster/<name> tag
SKIP_CCM=0
KUBECONFIG_OUT="${KUBECONFIG_OUT:-./kubeconfig.yaml}"

usage() { sed -n '2,30p' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --servers)      SERVERS="$2"; shift 2 ;;
    --agents)       AGENTS="$2";  shift 2 ;;
    --ssh-key)      SSH_KEY="$2"; shift 2 ;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --skip-ccm)     SKIP_CCM=1; shift ;;
    -h|--help)      usage 0 ;;
    *) echo "unknown flag: $1" >&2; usage 1 ;;
  esac
done
[ -n "$SERVERS" ] || { echo "--servers is required" >&2; usage 1; }

IFS=',' read -r -a SERVER_LIST <<< "$SERVERS"
AGENT_LIST=()
[ -n "$AGENTS" ] && IFS=',' read -r -a AGENT_LIST <<< "$AGENTS"
ALL_NODES=("${SERVER_LIST[@]}" ${AGENT_LIST[@]+"${AGENT_LIST[@]}"})
FIRST="${SERVER_LIST[0]}"

case "${#SERVER_LIST[@]}" in
  1) echo "note: one server means one etcd member. Fine for a demo, not HA." ;;
  3|5) ;;
  *) echo "warning: ${#SERVER_LIST[@]} servers. etcd wants an ODD number (1, 3 or 5) or it cannot hold quorum." ;;
esac

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o BatchMode=yes)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")
sh_() { ssh "${SSH_OPTS[@]}" "$SSH_USER@$1" "${@:2}"; }
su_() { ssh "${SSH_OPTS[@]}" "$SSH_USER@$1" "sudo ${*:2}"; }
k_()  { su_ "$FIRST" "/usr/local/bin/k3s kubectl $*"; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { EXPLAINED=1; printf '\n!! %s\n' "$*" >&2; exit 1; }
EXPLAINED=0

# GOTCHAS.md item 26: a `set -e` script that dies mid-run looks like one that
# finished. Name the line and the code every time.
trap 'rc=$?; { [ $rc -eq 0 ] || [ "${EXPLAINED:-0}" = 1 ]; } && exit $rc
      printf "\n!! install-aws.sh stopped at line %s (exit %s)\n" "$LINENO" "$rc" >&2
      [ $rc -eq 141 ] && printf "   exit 141 is SIGPIPE: a pipeline ended early. This is a bug in the script, please report it.\n" >&2
      printf "   Re-running is safe: every step here is idempotent.\n" >&2
      printf "   The cluster is still billing while you debug: see ../COSTS.md section 5.\n" >&2
      exit $rc' EXIT

# ---- [AWS] 1: the metadata service ----------------------------------------
# Hetzner answers a plain GET on 169.254.169.254. AWS wants a session token
# first, obtained with a PUT, and the token is what every subsequent read
# presents. The instances are deliberately created with http_tokens=required so
# this is not optional and cannot be silently skipped, which is the honest way
# to record the difference.
#
# The token TTL is 60 seconds and it is fetched per call rather than cached:
# these are three reads on a fresh node, not a hot path.
imds() {
  su_ "$1" "sh -c 'T=\$(curl -sf -X PUT \"http://169.254.169.254/latest/api/token\" \
      -H \"X-aws-ec2-metadata-token-ttl-seconds: 60\" --max-time 5) || exit 1
    curl -sf -H \"X-aws-ec2-metadata-token: \$T\" --max-time 5 \
      \"http://169.254.169.254/latest/meta-data/$2\"'"
}

# ---- 0. preflight ----------------------------------------------------------
say "preflight on ${#ALL_NODES[@]} node(s)"

# Three facts per node, kept in parallel INDEXED arrays rather than one
# associative array. `declare -A` needs bash 4, and macOS still ships bash
# 3.2.57 as /bin/bash with no newer one in PATH by default, so an operator
# driving this from a stock Mac gets "declare: -A: invalid option" on line one
# of the preflight and a cluster that is already billing. Measured here on
# 2026-07-25 (GOTCHAS.md item 41).
NODE_PRIV=(); NODE_IID=(); NODE_AZ=()
node_index() {
  local i=0 x
  for x in "${ALL_NODES[@]}"; do
    [ "$x" = "$1" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}
priv_of() { printf '%s' "${NODE_PRIV[$(node_index "$1")]}"; }
iid_of() { printf '%s' "${NODE_IID[$(node_index "$1")]}"; }
az_of() { printf '%s' "${NODE_AZ[$(node_index "$1")]}"; }

for n in "${ALL_NODES[@]}"; do
  sh_ "$n" true 2>/dev/null || die "cannot ssh to $SSH_USER@$n (key: $SSH_KEY)"
  su_ "$n" true 2>/dev/null || die "$SSH_USER@$n cannot sudo"
  p="$(imds "$n" "local-ipv4" || true)"
  [ -n "$p" ] || die "$n did not answer IMDSv2. If http_tokens is not 'required' this reads differently; check the instance's metadata_options."
  i="$(imds "$n" "instance-id" || true)"
  z="$(imds "$n" "placement/availability-zone" || true)"
  [ -n "$i" ] && [ -n "$z" ] || die "$n did not return an instance-id and availability zone"
  ni="$(node_index "$n")"
  NODE_PRIV[$ni]="$p"; NODE_IID[$ni]="$i"; NODE_AZ[$ni]="$z"
  printf '   %-16s private %-12s %s  %s\n' "$n" "$p" "$i" "$z"
  su_ "$n" "test ! -x /usr/local/bin/k3s" || echo "     (k3s already present on $n: this script is idempotent, it will re-run the installer)"
done
FIRST_PRIV="$(priv_of "$FIRST")"

# [AWS] 2: provider-id. Hetzner used hcloud://<server-id>, a single opaque
# number. AWS wants the zone as well, because an instance id is only unique
# within a region. Set at INSTALL time for the same reason as on Hetzner:
# providerID is immutable, and retrofitting it means deleting the Node object,
# which on a server also removes its etcd member (GOTCHAS.md item 10).
provider_id_of() { printf 'aws:///%s/%s' "$(az_of "$1")" "$(iid_of "$1")"; }

# ---- [AWS] 3: the firewall is already there --------------------------------
# On Hetzner install.sh calls the provider API to build a cloud firewall,
# because a Hetzner server is reachable from the whole internet the moment it
# boots. On AWS the security group is created by Terraform BEFORE any instance
# exists, so the window GOTCHAS.md item 19 describes never opens here. The
# posture is identical and the mechanism is better; it is only the ordering
# that changed.
say "firewall"
echo "   the security group Terraform created is already enforcing ssh, 6443 and icmp"
echo "   from your address only. Nothing to do here, which is the AWS difference."

# sshd hardening is still worth doing: the AMI ships with password auth off,
# but not with MaxAuthTries or X11Forwarding closed.
say "sshd: keys only"
for n in "${ALL_NODES[@]}"; do
  su_ "$n" 'sh -c "F=/etc/ssh/sshd_config.d/99-stack-hardening.conf
    printf \"PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\nX11Forwarding no\nMaxAuthTries 3\n\" > \$F
    chmod 644 \$F
    sshd -t && (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null)"' \
    && echo "   $n hardened" || echo "   $n: sshd config rejected, left as it was"
done

# ---- 1. node prep ----------------------------------------------------------
# Identical to Hetzner: Longhorn attaches volumes over iSCSI and serves RWX over
# NFS, both from the HOST. A node without these produces volumes that never
# attach, with an error that talks about the CSI driver instead.
say "node prep: iscsi + nfs client on every node"
for n in "${ALL_NODES[@]}"; do
  su_ "$n" 'sh -c "set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq open-iscsi nfs-common cryptsetup >/dev/null
    systemctl enable --now iscsid >/dev/null 2>&1 || true
    modprobe iscsi_tcp || true
    modprobe dm_crypt || true"' &
done
wait
echo "   done"

# ---- 2. the first server ---------------------------------------------------
# The flag list is unchanged from the Hetzner run except for provider-id. Every
# flag is explained in ../../install.sh section 2; the reasons are not
# cloud-specific, which is itself worth recording.
say "k3s server on $FIRST ($FIRST_PRIV)"
K3S_TOKEN_VALUE="${K3S_TOKEN_VALUE:-$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
su_ "$FIRST" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - server \
    --cluster-init \
    --node-ip '$FIRST_PRIV' --advertise-address '$FIRST_PRIV' \
    --tls-san '$FIRST_PRIV' --tls-san '$FIRST' \
    --flannel-backend=none --disable-network-policy \
    --disable=servicelb --disable=traefik \
    --disable=local-storage \
    --secrets-encryption \
    --kubelet-arg=provider-id=$(provider_id_of "$FIRST") \
    --node-label 'topology.kubernetes.io/zone=$(az_of "$FIRST")' \
    --write-kubeconfig-mode 0600" < <(curl -sfL https://get.k3s.io)

say "waiting for the API server"
for i in $(seq 1 60); do
  if k_ "get --raw /readyz" >/dev/null 2>&1; then echo "   ready"; break; fi
  [ "$i" = 60 ] && die "API server did not become ready"
  sleep 5
done

# ---- 3. the other servers, then the agents ---------------------------------
for n in "${SERVER_LIST[@]:1}"; do
  say "k3s server joining: $n ($(priv_of "$n"))"
  su_ "$n" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - server \
      --server 'https://$FIRST_PRIV:6443' \
      --node-ip '$(priv_of "$n")' --advertise-address '$(priv_of "$n")' \
      --tls-san '$(priv_of "$n")' --tls-san '$n' \
      --flannel-backend=none --disable-network-policy \
      --disable=servicelb --disable=traefik \
      --disable=local-storage \
      --secrets-encryption \
      --kubelet-arg=provider-id=$(provider_id_of "$n") \
      --node-label 'topology.kubernetes.io/zone=$(az_of "$n")' \
      --write-kubeconfig-mode 0600" < <(curl -sfL https://get.k3s.io)
  for i in $(seq 1 40); do
    k_ "get node $(sh_ "$n" hostname) -o name" >/dev/null 2>&1 && break
    sleep 5
  done
done

for n in ${AGENT_LIST[@]+"${AGENT_LIST[@]}"}; do
  say "k3s agent: $n ($(priv_of "$n"))"
  su_ "$n" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_URL='https://$FIRST_PRIV:6443' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - agent \
      --node-ip '$(priv_of "$n")' \
      --kubelet-arg=provider-id=$(provider_id_of "$n") \
      --node-label 'topology.kubernetes.io/zone=$(az_of "$n")'" < <(curl -sfL https://get.k3s.io)
done

say "nodes"
k_ "get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,PROVIDER:.spec.providerID"

# ---- 4. Calico -------------------------------------------------------------
# Same reason as Hetzner, and the AWS parallel is worth stating: EKS's VPC CNI
# does not enforce NetworkPolicy on its own either. The trap is the same class,
# the switch is different.
say "Calico $CALICO_VERSION"
k_ "create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/tigera-operator.yaml" 2>/dev/null \
  || k_ "replace -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/tigera-operator.yaml"
su_ "$FIRST" "tee /tmp/calico-installation.yaml >/dev/null" <<YAML
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        cidr: $POD_CIDR
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
YAML
for i in $(seq 1 30); do
  k_ "apply -f /tmp/calico-installation.yaml" >/dev/null 2>&1 && break
  sleep 5
done
say "waiting for Calico to make every node Ready"
for i in $(seq 1 60); do
  notready="$(k_ "get nodes --no-headers" | grep -cv ' Ready ' || true)"
  [ "$notready" = "0" ] && { echo "   all nodes Ready"; break; }
  [ "$i" = 60 ] && die "nodes did not become Ready: check 'kubectl -n calico-system get pods'"
  sleep 10
done

# ---- 5. Longhorn -----------------------------------------------------------
say "Longhorn $LONGHORN_VERSION"
k_ "apply -f https://raw.githubusercontent.com/longhorn/longhorn/$LONGHORN_VERSION/deploy/longhorn.yaml"
say "waiting for Longhorn (this takes a few minutes on a fresh node)"
for i in $(seq 1 90); do
  ready="$(k_ "-n longhorn-system get ds longhorn-manager -o jsonpath='{.status.numberReady}'" 2>/dev/null || echo 0)"
  want="${#ALL_NODES[@]}"
  if [ "${ready:-0}" -ge "$want" ]; then echo "   longhorn-manager ready on $ready/$want nodes"; break; fi
  [ "$i" = 90 ] && die "Longhorn did not come up: check 'kubectl -n longhorn-system get pods'"
  sleep 10
done

say "one default StorageClass"
if k_ "get sc local-path" >/dev/null 2>&1; then
  echo "   local-path still exists: patching it non-default"
  k_ "patch storageclass local-path -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}'" >/dev/null
fi
k_ "get sc"

say "stack-rwx StorageClass"
su_ "$FIRST" "tee /tmp/stack-rwx.yaml >/dev/null" <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: stack-rwx
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "3"
  staleReplicaTimeout: "30"
  fsType: "ext4"
YAML
k_ "apply -f /tmp/stack-rwx.yaml"

# ---- [AWS] 4: the cloud controller ----------------------------------------
# The largest genuine difference, and the one most likely to cost time.
#
# On Hetzner the CCM gets a project token in a Secret and discovers everything
# else from the API. Here it authenticates as the INSTANCE (the IAM role
# Terraform attached), which is better, but it discovers almost nothing: on a
# self-managed cluster nothing tells it which VPC, subnet, zone or cluster it
# belongs to. EKS's managed control plane supplies all four, which is precisely
# why this step has no EKS counterpart and why a self-managed cluster on AWS is
# not "EKS minus the fee".
#
# Narrowed exactly like the Hetzner one: --controllers=service only. k3s keeps
# node lifecycle and Calico keeps routing, so nothing overlaps and nothing
# fights over a port (GOTCHAS.md item 4). Port 10268 for the same reason as
# there: k3s already serves 10258.
if [ "$SKIP_CCM" = 0 ]; then
  say "aws-cloud-controller-manager $CCM_VERSION (load balancers only)"

  VPC_ID="$(imds "$FIRST" "network/interfaces/macs/$(imds "$FIRST" "mac")/vpc-id" || true)"
  SUBNET_ID="$(imds "$FIRST" "network/interfaces/macs/$(imds "$FIRST" "mac")/subnet-id" || true)"
  [ -n "$VPC_ID" ] && [ -n "$SUBNET_ID" ] || die "could not read the VPC and subnet from the metadata service"
  echo "   vpc $VPC_ID  subnet $SUBNET_ID  zone $(az_of "$FIRST")  cluster $CLUSTER_NAME"

  su_ "$FIRST" "tee /tmp/aws-ccm.yaml >/dev/null" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-cloud-config
  namespace: kube-system
data:
  cloud.conf: |
    [Global]
    Zone=$(az_of "$FIRST")
    VPC=$VPC_ID
    SubnetID=$SUBNET_ID
    KubernetesClusterID=$CLUSTER_NAME
    DisableSecurityGroupIngress=false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloud-controller-manager
  namespace: kube-system
---
# Upstream's own example binds cluster-admin here. It is not needed: the
# service controller touches Services, their status, Nodes and Events, and
# nothing else. A controller that can rewrite anything in the cluster in order
# to create a load balancer is the same mistake as a gateway that can rewrite
# the policy it enforces (GOTCHAS.md item 20).
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: stack-aws-cloud-controller-manager
rules:
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: [""]
    resources: ["services/status"]
    verbs: ["get", "patch", "update"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch", "update"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: stack-aws-cloud-controller-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: stack-aws-cloud-controller-manager
subjects:
  - kind: ServiceAccount
    name: cloud-controller-manager
    namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: aws-cloud-controller-manager
  namespace: kube-system
  labels:
    k8s-app: aws-cloud-controller-manager
spec:
  selector:
    matchLabels:
      k8s-app: aws-cloud-controller-manager
  template:
    metadata:
      labels:
        k8s-app: aws-cloud-controller-manager
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: "true"
      tolerations:
        - key: node.cloudprovider.kubernetes.io/uninitialized
          value: "true"
          effect: NoSchedule
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      serviceAccountName: cloud-controller-manager
      hostNetwork: true
      priorityClassName: system-cluster-critical
      containers:
        - name: aws-cloud-controller-manager
          image: registry.k8s.io/provider-aws/cloud-controller-manager:$CCM_VERSION
          args:
            - --v=2
            - --cloud-provider=aws
            - --cloud-config=/etc/aws/cloud.conf
            - --controllers=service
            - --configure-cloud-routes=false
            - --leader-elect=false
            - --secure-port=10268
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
          volumeMounts:
            - name: cloud-config
              mountPath: /etc/aws
              readOnly: true
      volumes:
        - name: cloud-config
          configMap:
            name: aws-cloud-config
YAML
  k_ "apply -f /tmp/aws-ccm.yaml"
  k_ "-n kube-system rollout status daemonset/aws-cloud-controller-manager --timeout=180s" \
    || die "the cloud controller did not come up. Check 'kubectl -n kube-system logs -l k8s-app=aws-cloud-controller-manager'.
   Everything else works without it; a type=LoadBalancer Service will stay <pending>.
   Re-run with --skip-ccm to continue deliberately without one."
else
  echo "   --skip-ccm: no cloud controller. A type=LoadBalancer Service will stay <pending>."
fi

# ---- 6. the planes' credentials -------------------------------------------
# Byte for byte the same as the Hetzner install: generated here, straight into
# Secrets on the cluster, never committed and never seen by this repo. Repeated
# rather than shared because a cluster bootstrap that sources a second file is
# a cluster bootstrap that fails halfway on a bad path.
if ! k_ "-n agent-stack get secret stack-policy-db" >/dev/null 2>&1; then
  say "policy-store credentials (generated, never committed)"
  PW="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  AS="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  k_ "create namespace agent-stack --dry-run=client -o yaml" | su_ "$FIRST" "/usr/local/bin/k3s kubectl apply -f -" >/dev/null
  k_ "-n agent-stack create secret generic stack-policy-db \
      --from-literal=password='$PW' \
      --from-literal=dsn='postgres://wardryx:$PW@policy-db:5432/wardryx?sslmode=disable' \
      --from-literal=approval_secret='$AS'" >/dev/null
  echo "   created secret stack-policy-db"
else
  echo "   secret stack-policy-db already exists, left as is"
fi

if ! k_ "-n agent-stack get secret stack-keys" >/dev/null 2>&1; then
  say "plane credentials (generated, never committed)"
  CLOUD_SECRET="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  WARDRYX_ADMIN_SECRET="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  WARDRYX_GATEWAY_SECRET="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  k_ "-n agent-stack create secret generic stack-keys \
      --from-literal=cloud_keys='$CLOUD_SECRET:default:admin' \
      --from-literal=cloud_admin='$CLOUD_SECRET' \
      --from-literal=wardryx_keys='$WARDRYX_ADMIN_SECRET:default:admin,$WARDRYX_GATEWAY_SECRET:default:viewer' \
      --from-literal=wardryx_admin='$WARDRYX_ADMIN_SECRET' \
      --from-literal=wardryx_gateway='$WARDRYX_GATEWAY_SECRET'" >/dev/null
  echo "   created secret stack-keys"
else
  echo "   secret stack-keys already exists, left as is"
fi

# ---- 7. the operator's kubeconfig -----------------------------------------
say "kubeconfig -> $KUBECONFIG_OUT"
su_ "$FIRST" "cat /etc/rancher/k3s/k3s.yaml" | sed "s#127.0.0.1#$FIRST#" > "$KUBECONFIG_OUT"
chmod 600 "$KUBECONFIG_OUT"

# ---- 8. what the platform looks like now ----------------------------------
say "verify"
k_ "get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,PROVIDER:.spec.providerID,IP:.status.addresses[0].address"
echo
k_ "get sc"
echo
k_ "-n kube-system get ds aws-cloud-controller-manager 2>/dev/null" || true

cat <<EOF

$(printf '\033[1m')Platform is up, and billing. Two commands left:$(printf '\033[0m')

  1. Build the stack's images and import them into every node:

       cd ../.. && ./build.sh $(for n in "${ALL_NODES[@]}"; do printf '%s@%s ' "$SSH_USER" "$n"; done)

  2. Apply the workload:

       KUBECONFIG=cloud/aws/$KUBECONFIG_OUT kubectl apply -k manifests/

  Then the tunnel, unchanged from Hetzner (GOTCHAS.md item 13: it has to land
  on the node running the console pod):

       ssh -i $SSH_KEY -L 17420:\$(kubectl -n agent-stack get svc genaryx-console -o jsonpath='{.spec.clusterIP}'):7420 $SSH_USER@<node running the console>

  A public entry point is a separate, metered decision: manifests/50-loadbalancer.yaml,
  and on AWS it is an NLB at USD 0.027/hour plus capacity units.

  $(printf '\033[1m')When done: ./teardown.sh$(printf '\033[0m')  (about USD 2.13/hour says so)
EOF
