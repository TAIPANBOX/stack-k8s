#!/usr/bin/env bash
# Bring up the cluster this repo's manifests target, from bare Hetzner servers
# to a platform ready for `./build.sh` and `kubectl apply -k manifests/`.
#
#   ./install.sh --servers 1.2.3.4,1.2.3.5,1.2.3.6 --agents 1.2.3.7,1.2.3.8
#
# Every decision below was paid for once already: each one is either a fix for
# something in GOTCHAS.md or the reason a gotcha never happens here. The point
# of this file existing is that a new operator runs a script instead of
# reconstructing those decisions from a chat log.
#
# What it does NOT do: create servers (they are yours, and hourly billed), open
# a public entry point (see manifests/50-loadbalancer.yaml, deliberately not in
# the kustomization), or install the stack's own images (that is ./build.sh).
#
# Requirements on the operator's machine: bash, ssh, curl. kubectl is optional
# (the script drives `k3s kubectl` over ssh) but useful afterwards.
#
# Requirements on the nodes: a fresh Ubuntu 24.04+ Hetzner CLOUD server (the
# metadata service at 169.254.169.254 is read for the private address and the
# server id, so this script is Hetzner-specific by design), root ssh, and every
# node attached to ONE Hetzner private network. A private network is free and
# not optional here: see GOTCHAS.md item 5.
set -euo pipefail

# ---- knobs -----------------------------------------------------------------
SERVERS=""                                  # comma-separated public IPs, etcd members
AGENTS=""                                   # comma-separated public IPs, workers
SSH_KEY="${SSH_KEY:-}"                      # ssh identity, if not the default
K3S_VERSION="${K3S_VERSION:-v1.36.2+k3s1}"  # pinned: an unpinned install is not reproducible
CALICO_VERSION="${CALICO_VERSION:-v3.29.1}"
LONGHORN_VERSION="${LONGHORN_VERSION:-v1.7.2}"
CCM_VERSION="${CCM_VERSION:-v1.21.0}"
POD_CIDR="${POD_CIDR:-10.42.0.0/16}"        # k3s's own default, kept so nothing has to be told twice
HCLOUD_TOKEN="${HCLOUD_TOKEN:-}"            # read-write project token, for the LB controller
KUBECONFIG_OUT="${KUBECONFIG_OUT:-./kubeconfig.yaml}"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --servers) SERVERS="$2"; shift 2 ;;
    --agents)  AGENTS="$2";  shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --token)   HCLOUD_TOKEN="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
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
sh_() { ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
k_()  { sh_ "$FIRST" "/usr/local/bin/k3s kubectl $*"; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

# Hetzner's metadata service is the single source of truth for both facts this
# install needs per node, so neither is typed by hand and neither can drift:
#   - the PRIVATE address, for --node-ip (GOTCHAS item 5)
#   - the SERVER ID, for the kubelet's provider-id (GOTCHAS item 10)
priv_ip_of() {
  sh_ "$1" "curl -sf --max-time 5 http://169.254.169.254/hetzner/v1/metadata/private-networks" \
    | awk '/^- ip:/ {print $3; exit}'
}
server_id_of() {
  sh_ "$1" "curl -sf --max-time 5 http://169.254.169.254/hetzner/v1/metadata/instance-id"
}

# ---- 0. preflight ----------------------------------------------------------
# Everything that can be wrong about the inputs is checked BEFORE anything is
# installed, because a half-installed cluster is harder to reason about than
# one that refused to start.
say "preflight on ${#ALL_NODES[@]} node(s)"
declare -A PRIV SID
for n in "${ALL_NODES[@]}"; do
  sh_ "$n" true 2>/dev/null || die "cannot ssh to root@$n"
  p="$(priv_ip_of "$n" || true)"
  [ -n "$p" ] || die "$n has no Hetzner private network attached (or no metadata service): attach every node to one private network first"
  s="$(server_id_of "$n" || true)"
  [ -n "$s" ] || die "$n did not return an instance-id from the metadata service"
  PRIV["$n"]="$p"; SID["$n"]="$s"
  printf '   %-16s private %-12s server-id %s\n' "$n" "$p" "$s"
  sh_ "$n" "test ! -x /usr/local/bin/k3s" || echo "     (k3s already present on $n: this script is idempotent, it will re-run the installer)"
done
FIRST_PRIV="${PRIV[$FIRST]}"

if [ -z "$HCLOUD_TOKEN" ]; then
  echo "   no --token given: the cloud-controller-manager will be SKIPPED."
  echo "   Everything else works; a type=LoadBalancer Service will stay <pending>."
fi

# ---- 1. node prep ----------------------------------------------------------
# Longhorn is not self-contained: its engine attaches volumes over iSCSI, and
# an RWX volume is served to other nodes over NFS. Both live on the HOST, not
# in a container, so a node without them produces volumes that never attach
# and RWX claims that never bind - with an error that talks about the CSI
# driver rather than about the missing package.
say "node prep: iscsi + nfs client on every node"
for n in "${ALL_NODES[@]}"; do
  sh_ "$n" 'set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq open-iscsi nfs-common cryptsetup >/dev/null
    systemctl enable --now iscsid >/dev/null 2>&1 || true
    modprobe iscsi_tcp || true
    # dm_crypt is only needed if you later turn on Longhorn volume encryption,
    # but loading it now costs nothing and saves a puzzling failure later.
    modprobe dm_crypt || true' &
done
wait
echo "   done"

# ---- 2. the first server ---------------------------------------------------
# The flag list is the interesting part of this file. Line by line:
#
#   --cluster-init            start an embedded-etcd cluster (not sqlite), so
#                             servers 2 and 3 can join it
#   --node-ip/--advertise-address on the PRIVATE address: without this every
#                             etcd peer, kubelet and overlay packet crosses the
#                             public internet (GOTCHAS 5)
#   --tls-san <public>        so an operator's kubectl still works from outside
#   --flannel-backend=none    k3s's default CNI does not implement
#   --disable-network-policy   NetworkPolicy; Calico replaces both (GOTCHAS 2)
#   --disable=servicelb       klipper would answer type=LoadBalancer itself and
#                             the hcloud controller would never see it
#   --disable=traefik         nothing here is exposed over an Ingress
#   --kubelet-arg=provider-id the kubelet registers as hcloud://<server-id>, so
#                             the cloud controller can map a Node to a Hetzner
#                             server. Set at INSTALL time on purpose: providerID
#                             is immutable, so retrofitting it means deleting
#                             the Node object, which on a server also removes
#                             its etcd member and detaches its volumes
#                             (GOTCHAS 10)
#   --write-kubeconfig-mode 0600  the default 0644 leaves cluster-admin
#                             credentials world-readable on the node
#
# The cluster token goes in through the installer's ENVIRONMENT, never as
# `--token` on the command line: the installer writes it to
# /etc/systemd/system/k3s.service.env (0600), whereas a flag would put it in
# the unit file and in every `ps` listing for the life of the node.
say "k3s server on $FIRST ($FIRST_PRIV)"
K3S_TOKEN_VALUE="${K3S_TOKEN_VALUE:-$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
sh_ "$FIRST" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - server \
    --cluster-init \
    --node-ip '$FIRST_PRIV' --advertise-address '$FIRST_PRIV' \
    --tls-san '$FIRST_PRIV' --tls-san '$FIRST' \
    --flannel-backend=none --disable-network-policy \
    --disable=servicelb --disable=traefik \
    --kubelet-arg=provider-id=hcloud://${SID[$FIRST]} \
    --write-kubeconfig-mode 0600" < <(curl -sfL https://get.k3s.io)

say "waiting for the API server"
for i in $(seq 1 60); do
  if k_ "get --raw /readyz" >/dev/null 2>&1; then echo "   ready"; break; fi
  [ "$i" = 60 ] && die "API server did not become ready"
  sleep 5
done

# ---- 3. the other servers, then the agents ---------------------------------
# Servers join one at a time: each new etcd member has to be learned by the
# existing quorum before the next one arrives, and a parallel join is how a
# three-member cluster ends up with two half-joined members.
for n in "${SERVER_LIST[@]:1}"; do
  say "k3s server joining: $n (${PRIV[$n]})"
  sh_ "$n" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - server \
      --server 'https://$FIRST_PRIV:6443' \
      --node-ip '${PRIV[$n]}' --advertise-address '${PRIV[$n]}' \
      --tls-san '${PRIV[$n]}' --tls-san '$n' \
      --flannel-backend=none --disable-network-policy \
      --disable=servicelb --disable=traefik \
      --kubelet-arg=provider-id=hcloud://${SID[$n]} \
      --write-kubeconfig-mode 0600" < <(curl -sfL https://get.k3s.io)
  for i in $(seq 1 40); do
    k_ "get node $(sh_ "$n" hostname) -o name" >/dev/null 2>&1 && break
    sleep 5
  done
done

for n in ${AGENT_LIST[@]+"${AGENT_LIST[@]}"}; do
  say "k3s agent: $n (${PRIV[$n]})"
  sh_ "$n" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_URL='https://$FIRST_PRIV:6443' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - agent \
      --node-ip '${PRIV[$n]}' \
      --kubelet-arg=provider-id=hcloud://${SID[$n]}" < <(curl -sfL https://get.k3s.io)
done

say "nodes"
k_ "get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,PROVIDER:.spec.providerID"

# ---- 4. Calico -------------------------------------------------------------
# The operator, then the Installation CR. The CR has to name this cluster's pod
# CIDR: the upstream example ships 192.168.0.0/16, and a Calico that hands out
# addresses from a range k3s did not plan for produces pods that are up and
# unreachable.
say "Calico $CALICO_VERSION"
k_ "create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/tigera-operator.yaml" 2>/dev/null \
  || k_ "replace -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/tigera-operator.yaml"
sh_ "$FIRST" "cat > /tmp/calico-installation.yaml" <<YAML
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
  sleep 5   # the operator's CRDs land a moment after the operator itself
done
say "waiting for Calico to make every node Ready"
for i in $(seq 1 60); do
  notready="$(k_ "get nodes --no-headers" | grep -cv ' Ready ' || true)"
  [ "$notready" = "0" ] && { echo "   all nodes Ready"; break; }
  [ "$i" = 60 ] && die "nodes did not become Ready: check 'kubectl -n calico-system get pods'"
  sleep 10
done

# ---- 5. Longhorn, and one honest default -----------------------------------
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

# k3s ships local-path as default and Longhorn installs itself as default too.
# Two defaults mean a PVC without a class name binds to whichever the API
# server picks that day (GOTCHAS 3).
say "one default StorageClass"
k_ "patch storageclass local-path -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}'" >/dev/null
k_ "get sc"

# The RWX class the shared event log claims BY NAME (README "Fact 1"), so a
# cluster without RWX fails at apply time instead of quietly co-locating every
# pod on one node. Retain, because the event log is the evidence trail: a
# deleted claim should leave the data behind for an operator to look at.
say "stack-rwx StorageClass"
sh_ "$FIRST" "cat > /tmp/stack-rwx.yaml" <<'YAML'
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

# ---- 6. the cloud controller, narrowed ------------------------------------
# Only if a token was given. The CCM here does ONE job: turn a
# type=LoadBalancer Service into a Hetzner load balancer. Node lifecycle stays
# with k3s and pod routing stays with Calico, so nothing overlaps and nothing
# fights over :10258 (GOTCHAS 4).
if [ -n "$HCLOUD_TOKEN" ]; then
  say "hcloud-cloud-controller-manager $CCM_VERSION (load balancers only)"
  NET_ID="$(sh_ "$FIRST" "curl -sf --max-time 5 http://169.254.169.254/hetzner/v1/metadata/private-networks" | awk '/network_id:/ {print $2; exit}')"
  k_ "-n kube-system create secret generic hcloud --from-literal=token='$HCLOUD_TOKEN' --from-literal=network='$NET_ID' --dry-run=client -o yaml" \
    | sh_ "$FIRST" "/usr/local/bin/k3s kubectl apply -f -"
  k_ "apply -f https://github.com/hetznercloud/hcloud-cloud-controller-manager/releases/download/$CCM_VERSION/ccm-networks.yaml"
  sh_ "$FIRST" "cat > /tmp/ccm-args.yaml" <<'YAML'
spec:
  template:
    spec:
      containers:
        - name: hcloud-cloud-controller-manager
          args:
            - "--cloud-provider=hcloud"
            - "--leader-elect=false"
            - "--allow-untagged-cloud"
            # k3s already serves :10258. Two processes, one port, and the
            # error is buried under a wall of usage text.
            - "--secure-port=10268"
            - "--webhook-secure-port=0"
            # No node or route controller: k3s owns node lifecycle, Calico owns
            # IPAM. Enabling them here is how you get a CCM that fights both.
            - "--controllers=service-lb-controller"
YAML
  k_ "-n kube-system patch deployment hcloud-cloud-controller-manager --patch-file /tmp/ccm-args.yaml"
  k_ "-n kube-system rollout status deployment/hcloud-cloud-controller-manager --timeout=120s"
fi

# ---- 7. the policy plane's credentials ------------------------------------
# Generated here, on the operator's machine, straight into a Secret on their
# cluster: nothing to type, nothing to commit, and no placeholder anyone could
# ship by accident. Idempotent - an existing Secret is left alone, because
# rotating the database password out from under a running Postgres would break
# the very thing this protects.
#
# WARDRYX_APPROVAL_SECRET is the second half: without it wardryx accepts a
# `require_human_above_usd` policy but cannot ever GRANT a hold, and says so in
# one startup line most people will not read.
if ! k_ "-n agent-stack get secret stack-policy-db" >/dev/null 2>&1; then
  say "policy-store credentials (generated, never committed)"
  PW="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  AS="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  k_ "create namespace agent-stack --dry-run=client -o yaml" | sh_ "$FIRST" "/usr/local/bin/k3s kubectl apply -f -" >/dev/null
  k_ "-n agent-stack create secret generic stack-policy-db \
      --from-literal=password='$PW' \
      --from-literal=dsn='postgres://wardryx:$PW@policy-db:5432/wardryx?sslmode=disable' \
      --from-literal=approval_secret='$AS'" >/dev/null
  echo "   created secret stack-policy-db"
else
  echo "   secret stack-policy-db already exists, left as is"
fi

# ---- 8. the operator's kubeconfig -----------------------------------------
# Fetched with the PUBLIC address substituted for 127.0.0.1, so kubectl works
# from the machine that ran this script. It carries cluster-admin credentials:
# 0600, and never committed (see .gitignore).
say "kubeconfig -> $KUBECONFIG_OUT"
sh_ "$FIRST" "cat /etc/rancher/k3s/k3s.yaml" | sed "s#127.0.0.1#$FIRST#" > "$KUBECONFIG_OUT"
chmod 600 "$KUBECONFIG_OUT"

# ---- 9. what the platform looks like now ----------------------------------
say "verify"
k_ "get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,PROVIDER:.spec.providerID,IP:.status.addresses[0].address"
echo
k_ "get sc"
echo
k_ "-n kube-system get deploy hcloud-cloud-controller-manager 2>/dev/null" || true

cat <<EOF

$(printf '\033[1m')Platform is up. Two commands left:$(printf '\033[0m')

  1. Build the stack's images and import them into every node:

       ./build.sh $(for n in "${ALL_NODES[@]}"; do printf 'root@%s ' "$n"; done)

  2. Apply the workload:

       KUBECONFIG=$KUBECONFIG_OUT kubectl apply -k manifests/

  Then reach the console over your own tunnel, which is the posture it is
  written for (manifests/20-console.yaml):

       ssh -L 17420:\$(KUBECONFIG=$KUBECONFIG_OUT kubectl -n agent-stack get svc genaryx-console -o jsonpath='{.spec.clusterIP}'):7420 root@<the node running the console pod>

  The tunnel has to land on the node running the console pod: cross-node
  traffic arrives with Calico's tunnel address as its source, which the
  default-deny policy does not admit (GOTCHAS.md item 13).

  A public entry point is a separate, metered decision:
  manifests/50-loadbalancer.yaml, and read its header first.
EOF
