#!/usr/bin/env bash
# Bring up the cluster this repo's manifests target, on GCE instances that
# `terraform apply` has already created.
#
#   ./install-gcp.sh --servers 1.2.3.4,1.2.3.5,1.2.3.6 --agents 1.2.3.7,1.2.3.8
#
# This is ../../install.sh with the Hetzner-specific parts replaced, and the
# replacements are the point of the file: each one is a line in the comparison
# ../PORTABILITY.md asks for. There are exactly five of them, marked [GCP]:
#
#   1. the metadata service answers a GET with a HEADER, not a token dance
#   2. provider-id is gce://<project>/<zone>/<instance-NAME>, and the name is
#      the identifier rather than an opaque id
#   3. the firewall is a tag-scoped rule created by Terraform before any
#      instance exists
#   4. the cloud controller reads credentials from the instance's service
#      account, and has to be TOLD project, network, subnetwork, node tag and
#      zone in a gce.conf, because on a self-managed cluster nothing supplies
#      them
#   5. Calico has to encapsulate UNCONDITIONALLY here. This is the only
#      Kubernetes-level difference across the three clouds, and it is a real
#      finding rather than a preference: see the comment at section 4.
#
# Everything else, and that is most of it, is identical to both other runs: k3s
# with the same flags, Longhorn with the same RWX class, the same generated
# Secrets. That similarity is also a finding.
set -euo pipefail

# ---- knobs -----------------------------------------------------------------
SERVERS=""
AGENTS=""
SSH_KEY="${SSH_KEY:-$HOME/.ssh/stack-k8s-gcp}"
SSH_USER="${SSH_USER:-ubuntu}"
K3S_VERSION="${K3S_VERSION:-v1.36.2+k3s1}"          # same pin as the other two runs
CALICO_VERSION="${CALICO_VERSION:-v3.29.1}"
LONGHORN_VERSION="${LONGHORN_VERSION:-v1.7.2}"
# [GCP] cloud-provider-gcp, pinned to a tag that is actually PUBLISHED as an
# image rather than to the newest GitHub release (GOTCHAS.md item 42: a release
# is not an image, and the cluster answers ImagePullBackOff rather than anything
# that names the real problem). Verified 2026-07-26 by asking the registry:
#
#   curl -sLo /dev/null -w '%{http_code}\n' \
#     https://registry.k8s.io/v2/cloud-provider-gcp/cloud-controller-manager/manifests/<tag>
#
# Published: v36.0.3, v36.0.4, v36.2.4, v35.0.0, v35.0.2, v34.x, v33.1.1, v32.x.
# v36.2.4 is the newest, and it matches the k8s 1.36 line k3s is pinned to,
# which the AWS run could not manage (cloud-provider-aws had nothing newer than
# v1.35.2 in the registry).
CCM_VERSION="${CCM_VERSION:-v36.2.4}"
POD_CIDR="${POD_CIDR:-10.42.0.0/16}"
CLUSTER_NAME="${CLUSTER_NAME:-stack-k8s}"
NODE_TAG="${NODE_TAG:-$CLUSTER_NAME-node}"
SUBNETWORK="${SUBNETWORK:-}"                        # [GCP] not readable from metadata, see section 4
SKIP_CCM=0
KUBECONFIG_OUT="${KUBECONFIG_OUT:-./kubeconfig.yaml}"

usage() { sed -n '2,30p' "$0" | sed -E 's/^# ?//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --servers)      SERVERS="$2"; shift 2 ;;
    --agents)       AGENTS="$2";  shift 2 ;;
    --ssh-key)      SSH_KEY="$2"; shift 2 ;;
    --cluster-name) CLUSTER_NAME="$2"; NODE_TAG="$CLUSTER_NAME-node"; shift 2 ;;
    --subnetwork)   SUBNETWORK="$2"; shift 2 ;;
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
      printf "\n!! install-gcp.sh stopped at line %s (exit %s)\n" "$LINENO" "$rc" >&2
      [ $rc -eq 141 ] && printf "   exit 141 is SIGPIPE: a pipeline ended early. This is a bug in the script, please report it.\n" >&2
      printf "   Re-running is safe: every step here is idempotent.\n" >&2
      printf "   The cluster is still billing while you debug: see ../COSTS.md section 5.\n" >&2
      exit $rc' EXIT

# ---- [GCP] 1: the metadata service ----------------------------------------
# Three clouds, three protocols for the same question. Hetzner answers a plain
# GET on 169.254.169.254. AWS wants a PUT for a session token first, and every
# read carries it. GCE answers a GET, but only with the header below, and the
# header is the whole authentication: it exists to stop a browser or a confused
# proxy inside the VM from fetching metadata by accident, because a plain
# cross-origin GET cannot set custom headers.
#
# metadata.google.internal resolves to 169.254.169.254 on every GCE instance;
# the name is used because that is what Google's own documentation and every
# error message refer to.
imds() {
  su_ "$1" "curl -sf -H 'Metadata-Flavor: Google' --max-time 5 http://metadata.google.internal/computeMetadata/v1/$2"
}

# ---- 0. preflight ----------------------------------------------------------
say "preflight on ${#ALL_NODES[@]} node(s)"

# A cloud recycles addresses. The SECOND run of this script on the same project
# is very likely to be handed the exact addresses the previous cluster had, on
# machines that are not the previous cluster, and ssh then refuses to connect at
# all:
#
#   WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
#   Offending ECDSA key in ~/.ssh/known_hosts:53
#
# `StrictHostKeyChecking=accept-new` does NOT cover this: it accepts a host it
# has never seen, and rejects one whose key changed, which is the correct
# behaviour and exactly the wrong outcome here. Measured on 2026-07-26: the
# first run of this script was clean, the second died in the preflight with
# every node refusing, on a cluster that was already billing.
#
# What this does is NOT "turn off host key checking". It forgets the key of a
# machine that no longer exists, for an address Terraform has just been handed
# back, and then checks normally from there.
say "forgetting host keys for addresses this cloud may have recycled"
for n in "${ALL_NODES[@]}"; do
  ssh-keygen -R "$n" >/dev/null 2>&1 || true
done
echo "   done (this is not the same as disabling the check: see the comment)"

# Facts per node in parallel INDEXED arrays rather than one associative array.
# `declare -A` needs bash 4, and macOS still ships bash 3.2.57 as /bin/bash, so
# an operator driving this from a stock Mac gets "declare: -A: invalid option"
# on line one of the preflight and a cluster that is already billing
# (GOTCHAS.md item 41).
NODE_PRIV=(); NODE_NAME=(); NODE_ZONE=()
node_index() {
  local i=0 x
  for x in "${ALL_NODES[@]}"; do
    [ "$x" = "$1" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}
priv_of() { printf '%s' "${NODE_PRIV[$(node_index "$1")]}"; }
name_of() { printf '%s' "${NODE_NAME[$(node_index "$1")]}"; }
zone_of() { printf '%s' "${NODE_ZONE[$(node_index "$1")]}"; }

PROJECT_ID=""
for n in "${ALL_NODES[@]}"; do
  # A GCE instance answers the API as RUNNING well before it accepts an ssh
  # key. The key arrives from instance metadata via the guest agent, which
  # starts after sshd, so `terraform apply` can finish and hand over addresses
  # that refuse connections for another half minute. Measured here on
  # 2026-07-26: a node created 40 seconds earlier failed the preflight while its
  # two siblings, four minutes old, passed.
  #
  # So this waits rather than dying, and only says the discouraging thing about
  # OS Login once waiting has genuinely failed.
  ssh_ok=0
  for attempt in $(seq 1 24); do
    sh_ "$n" true 2>/dev/null && { ssh_ok=1; break; }
    [ "$attempt" = 1 ] && printf '   %s not answering ssh yet, waiting' "$n"
    printf '.'
    sleep 5
  done
  [ "$ssh_ok" = 1 ] && [ "${attempt:-1}" -gt 1 ] && printf ' ok\n'
  [ "$ssh_ok" = 1 ] || die "cannot ssh to $SSH_USER@$n after two minutes (key: $SSH_KEY).
   If the instance is up, the usual cause is OS Login: with it enabled GCE
   ignores the ssh-keys metadata entirely and derives a different username.
   main.tf pins enable-oslogin=FALSE for exactly this reason."
  su_ "$n" true 2>/dev/null || die "$SSH_USER@$n cannot sudo"
  p="$(imds "$n" "instance/network-interfaces/0/ip" || true)"
  [ -n "$p" ] || die "$n did not answer the metadata service. On GCE the read needs the header 'Metadata-Flavor: Google'."
  nm="$(imds "$n" "instance/name" || true)"
  # The zone arrives as projects/<number>/zones/<zone>, which is not what
  # provider-id wants.
  z="$(imds "$n" "instance/zone" | awk -F/ '{print $NF}' || true)"
  [ -n "$nm" ] && [ -n "$z" ] || die "$n did not return an instance name and zone"
  [ -n "$PROJECT_ID" ] || PROJECT_ID="$(imds "$n" "project/project-id" || true)"
  ni="$(node_index "$n")"
  NODE_PRIV[$ni]="$p"; NODE_NAME[$ni]="$nm"; NODE_ZONE[$ni]="$z"
  printf '   %-16s private %-12s %-22s %s\n' "$n" "$p" "$nm" "$z"
  su_ "$n" "test ! -x /usr/local/bin/k3s" || echo "     (k3s already present on $n: this script is idempotent, it will re-run the installer)"
done
[ -n "$PROJECT_ID" ] || die "could not read the project id from the metadata service"
FIRST_PRIV="$(priv_of "$FIRST")"
echo "   project $PROJECT_ID"

# [GCP] 2: provider-id. Hetzner used hcloud://<server-id>, a single opaque
# number. AWS wanted aws:///<az>/<instance-id>, because an instance id is only
# unique within a region. GCE wants gce://<project>/<zone>/<NAME>: the name the
# operator chose IS the identifier, so unlike the other two it is readable and
# it is the same string the kubelet registers the Node under.
#
# Set at INSTALL time for the same reason as on both other clouds: providerID is
# immutable, and retrofitting it means deleting the Node object, which on a
# server also removes its etcd member (GOTCHAS.md item 10).
provider_id_of() { printf 'gce://%s/%s/%s' "$PROJECT_ID" "$(zone_of "$1")" "$(name_of "$1")"; }

# ---- [GCP] 3: the firewall is already there --------------------------------
# On Hetzner install.sh calls the provider API to build a cloud firewall,
# because a Hetzner server is reachable from the whole internet the moment it
# boots. On GCP the rules are created by Terraform BEFORE any instance exists
# and are scoped by NETWORK TAG, so the window GOTCHAS.md item 19 describes
# never opens, and item 58 cannot happen either: a tag-scoped rule reaches the
# nodes carrying the tag and nothing else in the project.
say "firewall"
echo "   the tag-scoped rules Terraform created are already enforcing ssh, 6443 and"
echo "   icmp from your address only, plus the NodePort range from Google's two"
echo "   health check ranges. Nothing to do here, which is the GCP difference."

# sshd hardening is still worth doing: the image ships with password auth off,
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
# Identical to Hetzner, including the multipathd blacklist that the AWS script
# predates. Longhorn attaches volumes over iSCSI and serves RWX over NFS, both
# from the HOST, and open-iscsi drags in multipath-tools, which then claims
# every Longhorn device and makes it unformattable (GOTCHAS.md item 60). The
# failure blames the CSI driver and never says the word multipath.
say "node prep: iscsi + nfs client on every node"
for n in "${ALL_NODES[@]}"; do
  su_ "$n" 'sh -c "set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq open-iscsi nfs-common cryptsetup >/dev/null
    systemctl enable --now iscsid >/dev/null 2>&1 || true
    modprobe iscsi_tcp || true
    modprobe dm_crypt || true
    if systemctl is-enabled multipathd >/dev/null 2>&1 || [ -e /etc/multipath.conf ]; then
      if ! grep -q VIRTUAL-DISK /etc/multipath.conf 2>/dev/null; then
        printf \"\n# Longhorn volumes: see stack-k8s install.sh and GOTCHAS.md item 60.\nblacklist {\n    device {\n        vendor \\\"IET\\\"\n        product \\\"VIRTUAL-DISK\\\"\n    }\n}\n\" >> /etc/multipath.conf
        systemctl restart multipathd 2>/dev/null || true
        sleep 2; multipath -F 2>/dev/null || true
      fi
    fi"' &
done
wait
echo "   done"

# ---- 2. the first server ---------------------------------------------------
# The flag list is unchanged from the other two runs except provider-id. Every
# flag is explained in ../../install.sh section 2; the reasons are not
# cloud-specific, which is itself worth recording.
say "k3s server on $FIRST ($FIRST_PRIV)"
# The token is REUSED when this cluster already has one, and that is what makes
# a second run of this script possible at all: k3s encrypts its bootstrap data
# with the token the cluster was created with, and a fresh random one is fatal
# with an error that names neither the token nor this script (GOTCHAS.md item
# 59).
# The name a node registers under is decided ONCE, here, and never re-decided by
# whatever `hostname` happens to return on some later boot. k3s defaults the node
# name to the host name, and that value is not reliably stable across a stop and
# start: on 2026-08-27 a node that had registered as
# stack-k8s-server-1.europe-west3-a.c.PROJECT.internal came back from a
# stop/start as plain stack-k8s-server-1, and the original object sat NotReady
# for the rest of the cluster's life still holding 17 pod records that nothing
# ever cleans up (evidence/range-2026-08-27/FINDINGS.md, F3).
#
# The value read here is the one k3s would have picked by itself, so pinning it
# changes nothing about an existing cluster's identity. It only stops that choice
# from being made a second time, by a boot that races the guest agent.
node_name_of() { sh_ "$1" hostname 2>/dev/null || printf '%s' "$(name_of "$1")"; }
FIRST_NODE_NAME="$(node_name_of "$FIRST")"
[ -n "$FIRST_NODE_NAME" ] || die "could not read a host name from $FIRST to pin --node-name to"

K3S_TOKEN_VALUE="${K3S_TOKEN_VALUE:-}"
if [ -z "$K3S_TOKEN_VALUE" ]; then
  K3S_TOKEN_VALUE="$(su_ "$FIRST" 'cat /var/lib/rancher/k3s/server/token 2>/dev/null' || true)"
  if [ -n "$K3S_TOKEN_VALUE" ]; then
    echo "   reusing the token this cluster was created with"
  else
    K3S_TOKEN_VALUE="$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
fi
su_ "$FIRST" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - server \
    --cluster-init \
    --node-name '$FIRST_NODE_NAME' \
    --node-ip '$FIRST_PRIV' --advertise-address '$FIRST_PRIV' \
    --tls-san '$FIRST_PRIV' --tls-san '$FIRST' \
    --flannel-backend=none --disable-network-policy \
    --disable=servicelb --disable=traefik \
    --disable=local-storage \
    --secrets-encryption \
    --kubelet-arg=provider-id=$(provider_id_of "$FIRST") \
    --node-label 'topology.kubernetes.io/zone=$(zone_of "$FIRST")' \
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
  # Read the name BEFORE installing, so the node registers under a name we chose.
  JOINED_NAME="$(node_name_of "$n")"
  [ -n "$JOINED_NAME" ] || die "could not read a host name from $n to pin --node-name to"
  su_ "$n" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - server \
      --server 'https://$FIRST_PRIV:6443' \
      --node-name '$JOINED_NAME' \
      --node-ip '$(priv_of "$n")' --advertise-address '$(priv_of "$n")' \
      --tls-san '$(priv_of "$n")' --tls-san '$n' \
      --flannel-backend=none --disable-network-policy \
      --disable=servicelb --disable=traefik \
      --disable=local-storage \
      --secrets-encryption \
      --kubelet-arg=provider-id=$(provider_id_of "$n") \
      --node-label 'topology.kubernetes.io/zone=$(zone_of "$n")' \
      --write-kubeconfig-mode 0600" < <(curl -sfL https://get.k3s.io)
  # This lookup used to be a guess. GCE sets the host name to the FULLY QUALIFIED
  # internal name, so k3s registered stack-k8s-server-2.europe-west3-a.c.PROJECT
  # .internal while the metadata service answered stack-k8s-server-2; looking up
  # the short form never matched, the loop ran its full 40 attempts, and each
  # join stalled a silent 200 seconds on a cluster that is billing (GOTCHAS.md
  # item 67). Now the name is pinned above and passed to k3s, so this waits for
  # a name we know rather than one we hope for.
  for i in $(seq 1 40); do
    k_ "get node $JOINED_NAME -o name" >/dev/null 2>&1 && break
    sleep 5
  done
done

for n in ${AGENT_LIST[@]+"${AGENT_LIST[@]}"}; do
  say "k3s agent: $n ($(priv_of "$n"))"
  su_ "$n" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_URL='https://$FIRST_PRIV:6443' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - agent \
      --node-name '$(node_name_of "$n")' \
      --node-ip '$(priv_of "$n")' \
      --kubelet-arg=provider-id=$(provider_id_of "$n") \
      --node-label 'topology.kubernetes.io/zone=$(zone_of "$n")'" < <(curl -sfL https://get.k3s.io)
done

say "nodes"
k_ "get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,PROVIDER:.spec.providerID"

# ---- 4. Calico, and the one Kubernetes-level difference --------------------
# [GCP] 5. The other two clouds run `encapsulation: VXLANCrossSubnet`, which
# wraps pod traffic ONLY between different subnets and sends raw pod addresses
# between nodes that share one. All five nodes share one subnet here, exactly as
# they did on AWS, so CrossSubnet means unencapsulated.
#
# On AWS that produced GOTCHAS.md item 44, and the fix was one Terraform line:
# source_dest_check = false, because an EC2 subnet still delivers a frame to the
# instance whose MAC it carries, and the only thing stopping it was an
# anti-spoofing check on the interface.
#
# On GCP that fix has no counterpart, and this is the difference worth writing
# up. A GCE VPC has no layer 2 at all: every packet is routed by DESTINATION
# address against the VPC's route table. A packet for 10.42.x.x matches no
# route, so it is dropped before the anti-spoofing question is even asked.
# canIpForward would let a node EMIT such a packet; nothing would deliver it.
# Native routing here needs one VPC route per node for a /26 that Calico's IPAM
# allocates dynamically, which is a route table that has to be kept in step with
# a running cluster.
#
# So the encapsulation moves up a layer: unconditional VXLAN. The outer packet
# carries node addresses, which the VPC routes happily, and the cluster stops
# depending on cloud routing entirely.
#
# The honest cost of that choice, and it belongs in the article: the Kubernetes
# configuration is no longer byte-identical across the three clouds. AWS kept
# the difference in Terraform. GCP does not let you.
say "Calico $CALICO_VERSION (VXLAN, unconditional: see the comment above this line in the source)"
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
        encapsulation: VXLAN
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

# Cluster DNS ships at ONE replica, and on 2026-08-27 that cost 298 seconds of
# name resolution for the whole cluster when a single node was stopped: the sole
# coredns pod went down with it and the replacement waited out the full 300 s
# not-ready toleration before it was rescheduled somewhere else
# (cloud/gcp/evidence/range-2026-08-27/FINDINGS.md, F2). Nothing was broken. The
# configuration says one dead node costs five minutes of DNS, and it charged
# exactly that.
#
# The deployment already carries a topology spread constraint over host names,
# so a second replica lands on a different node with no further configuration.
# There was simply never a second replica for it to place.
#
# k3s owns this manifest and re-applies it when its own version changes, not on
# every restart, so the scale survives reboots but not a k3s upgrade. verify.sh
# checks the replica count for that reason: a revert should surface as a failed
# check rather than as the next outage.
say "cluster DNS: more than one replica"
DNS_WANT=2
[ "${#ALL_NODES[@]}" -lt 2 ] && DNS_WANT=1
k_ "-n kube-system scale deployment coredns --replicas=$DNS_WANT" >/dev/null \
  || echo "   could not scale coredns; verify.sh will report this"
echo "   coredns replicas=$DNS_WANT"

# A cheap, direct check that the choice above actually took, run BEFORE
# Longhorn: on AWS the same failure appeared four minutes later as a Longhorn
# webhook timeout that named nothing useful.
say "cross-node pod traffic (the check the AWS run wished it had)"
if k_ "get ippool default-ipv4-ippool -o jsonpath='{.spec.vxlanMode}'" 2>/dev/null | grep -q Always; then
  echo "   vxlanMode=Always, so pod packets never leave a node unencapsulated"
else
  echo "   WARNING: the IP pool is not in unconditional VXLAN mode. On GCE that means"
  echo "   cross-node pod traffic will be dropped by the VPC, and the first symptom"
  echo "   will be Longhorn timing out on its own webhook (GOTCHAS.md item 44)."
fi

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

# ---- [GCP] 4: the cloud controller ----------------------------------------
# The same shape of difference as AWS, with different contents. It authenticates
# AS THE INSTANCE, through the service account Terraform attached, so there is
# no token in a Secret. And it discovers almost nothing: project, network,
# subnetwork, the node tag and the zone all have to be written into a gce.conf,
# because on a self-managed cluster nothing supplies them. GKE's managed control
# plane supplies all five, which is precisely what its fee buys.
#
# token-url = nil is the line that makes it use the instance's own credentials.
# Without it the provider looks for a token server that does not exist here,
# which is a kube-up-era default nobody would guess (verified against
# providers/gce/gce.go: the literal string "nil" means "fall back to
# DefaultTokenSource").
#
# Narrowed exactly like the other two: --controllers=service only. k3s keeps
# node lifecycle and Calico keeps routing, so nothing overlaps and nothing
# fights over a port (GOTCHAS.md item 4). Port 10268 for the same reason as
# there: k3s already serves 10258.
if [ "$SKIP_CCM" = 0 ]; then
  say "cloud-provider-gcp $CCM_VERSION (load balancers only)"
  # The network name comes from the metadata service. The SUBNETWORK name does
  # not, and that is a genuine gap worth recording: GCE publishes the network,
  # the mac, the netmask and the gateway of an interface, but not the name of
  # the subnetwork it sits in, while the AWS metadata service publishes both
  # vpc-id and subnet-id. So this one value is derived from the cluster name
  # (which is how Terraform names it) and can be overridden.
  NETWORK="$(imds "$FIRST" "instance/network-interfaces/0/network" | awk -F/ '{print $NF}' || true)"
  [ -n "$NETWORK" ] || NETWORK="$CLUSTER_NAME"
  SUBNET="${SUBNETWORK:-$CLUSTER_NAME-nodes}"
  echo "   project $PROJECT_ID  network $NETWORK  subnetwork $SUBNET  zone $(zone_of "$FIRST")  tag $NODE_TAG"

  su_ "$FIRST" "tee /tmp/gcp-ccm.yaml >/dev/null" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: gce-cloud-config
  namespace: kube-system
data:
  gce.conf: |
    [global]
    project-id = $PROJECT_ID
    network-name = $NETWORK
    subnetwork-name = $SUBNET
    node-tags = $NODE_TAG
    node-instance-prefix = $CLUSTER_NAME-
    local-zone = $(zone_of "$FIRST")
    multizone = false
    regional = false
    token-url = nil
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloud-controller-manager
  namespace: kube-system
---
# Upstream's own example binds cluster-admin here. It is not needed: the service
# controller touches Services, their status, Nodes and Events, and nothing else.
# A controller that can rewrite anything in the cluster in order to create a
# load balancer is the same mistake as a gateway that can rewrite the policy it
# enforces (GOTCHAS.md item 20).
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: stack-gcp-cloud-controller-manager
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
  name: stack-gcp-cloud-controller-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: stack-gcp-cloud-controller-manager
subjects:
  - kind: ServiceAccount
    name: cloud-controller-manager
    namespace: kube-system
---
# GCP-only, and not obvious: the GCE provider derives a cluster id from a
# ConfigMap in kube-system (ingress-uid), creating it if it is missing, and uses
# it to name the objects it creates. Without this Role it cannot read or create
# that ConfigMap and the controller stops before it ever looks at a Service.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: stack-gcp-ccm-cluster-id
  namespace: kube-system
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch", "create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: stack-gcp-ccm-cluster-id
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: stack-gcp-ccm-cluster-id
subjects:
  - kind: ServiceAccount
    name: cloud-controller-manager
    namespace: kube-system
---
# Narrowing the ClusterRole above costs exactly one extra binding, and leaving
# it out is a crash, not a degradation. Any controller-manager that serves an
# authenticated endpoint loads the request-header CA from the
# extension-apiserver-authentication ConfigMap at startup and exits non-zero if
# it cannot read it (GOTCHAS.md item 43).
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: stack-gcp-ccm-authentication-reader
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
  - kind: ServiceAccount
    name: cloud-controller-manager
    namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gcp-cloud-controller-manager
  namespace: kube-system
  labels:
    k8s-app: gcp-cloud-controller-manager
spec:
  selector:
    matchLabels:
      k8s-app: gcp-cloud-controller-manager
  template:
    metadata:
      labels:
        k8s-app: gcp-cloud-controller-manager
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
        - name: gcp-cloud-controller-manager
          image: registry.k8s.io/cloud-provider-gcp/cloud-controller-manager:$CCM_VERSION
          args:
            - --v=2
            - --cloud-provider=gce
            - --cloud-config=/etc/gce/gce.conf
            - --controllers=service
            - --configure-cloud-routes=false
            - --allocate-node-cidrs=false
            - --leader-elect=false
            - --secure-port=10268
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
          volumeMounts:
            - name: cloud-config
              mountPath: /etc/gce
              readOnly: true
      volumes:
        - name: cloud-config
          configMap:
            name: gce-cloud-config
YAML
  k_ "apply -f /tmp/gcp-ccm.yaml"
  k_ "-n kube-system rollout status daemonset/gcp-cloud-controller-manager --timeout=180s" || true

  # `rollout status` alone is a lie here. This DaemonSet has no readiness probe,
  # so a pod counts as AVAILABLE the moment its container starts, and a
  # controller that starts, fails to read something it needs and exits two
  # seconds later is "available" on the way past. Measured on the first live AWS
  # cluster: rollout status returned success while the controller was in
  # CrashLoopBackOff the whole time, and nothing noticed until a
  # type=LoadBalancer Service sat <pending> (GOTCHAS.md item 43).
  ccm_pods() {
    k_ "-n kube-system get pods -l k8s-app=gcp-cloud-controller-manager -o jsonpath='{range .items[*]}{.status.phase}{\":\"}{.status.containerStatuses[0].restartCount}{\" \"}{end}'" 2>/dev/null
  }
  say "confirming the cloud controller is actually running, not merely started"
  before="$(ccm_pods)"
  sleep 20
  after="$(ccm_pods)"
  running="$(printf '%s' "$after" | tr ' ' '\n' | grep -c '^Running:' || true)"
  want="${#SERVER_LIST[@]}"
  if [ "${running:-0}" -lt "$want" ] || [ "$before" != "$after" ]; then
    echo "   state before: $before"
    echo "   state after:  $after"
    k_ "-n kube-system logs -l k8s-app=gcp-cloud-controller-manager --tail=15" 2>/dev/null || true
    die "the cloud controller is not staying up ($running/$want running, restart counts still moving).
   The last lines of its log are above; the real error is usually the LAST line,
   under a wall of usage text that makes it look like a flag problem.
   Everything else works without it; a type=LoadBalancer Service will stay <pending>.
   Re-run with --skip-ccm to continue deliberately without one."
  fi
  echo "   $running/$want running, restart counts stable"
else
  echo "   --skip-ccm: no cloud controller. A type=LoadBalancer Service will stay <pending>."
fi

# ---- 6. the planes' credentials -------------------------------------------
# Byte for byte the same as the other two installs: generated here, straight
# into Secrets on the cluster, never committed and never seen by this repo.
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
k_ "-n kube-system get ds gcp-cloud-controller-manager 2>/dev/null" || true

cat <<EOF

$(printf '\033[1m')Platform is up, and billing. Two commands left:$(printf '\033[0m')

  1. Build the stack's images and import them into every node:

       cd ../.. && ./build.sh $(for n in "${ALL_NODES[@]}"; do printf '%s@%s ' "$SSH_USER" "$n"; done)

  2. Apply the workload:

       KUBECONFIG=cloud/gcp/$KUBECONFIG_OUT kubectl apply -k manifests/

  Then the tunnel, unchanged from the other two clouds (GOTCHAS.md item 13: it
  has to land on the node running the console pod):

       ssh -i $SSH_KEY -L 17420:\$(kubectl -n agent-stack get svc genaryx-console -o jsonpath='{.spec.clusterIP}'):7420 $SSH_USER@<node running the console>

  A public entry point is a separate, metered decision: loadbalancer-gcp.yaml,
  and on GCP it is a forwarding rule at USD 0.030/hour plus USD 0.010/GiB.

  $(printf '\033[1m')When done: ./teardown.sh$(printf '\033[0m')  (about USD 1.88/hour says so)
EOF
