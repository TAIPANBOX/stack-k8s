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
  sed -n '2,20p' "$0" | sed -E 's/^# ?//'
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
die() { EXPLAINED=1; printf '\n!! %s\n' "$*" >&2; exit 1; }
EXPLAINED=0

# A cluster install that ends mid-sentence looks like one that finished. Under
# `set -e` that is the default behaviour, so name the line and the code every
# time. 141 is SIGPIPE, the failure mode `set -e` hides best.
trap 'rc=$?; { [ $rc -eq 0 ] || [ "${EXPLAINED:-0}" = 1 ]; } && exit $rc
      printf "\n!! install.sh stopped at line %s (exit %s)\n" "$LINENO" "$rc" >&2
      [ $rc -eq 141 ] && printf "   exit 141 is SIGPIPE: a pipeline ended early. This is a bug in the script, please report it.\n" >&2
      printf "   Re-running is safe: every step here is idempotent.\n" >&2
      exit $rc' EXIT

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

# Two facts per node, kept in parallel INDEXED arrays rather than one
# associative array. `declare -A` needs bash 4, and macOS still ships bash
# 3.2.57 as /bin/bash, so an operator driving this from a stock Mac gets
# "declare: -A: invalid option" on the first line of the preflight, with
# servers already created and already billing (GOTCHAS.md item 41).
NODE_PRIV=(); NODE_SID=()
node_index() {
  local i=0 x
  for x in "${ALL_NODES[@]}"; do
    [ "$x" = "$1" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}
priv_of() { printf '%s' "${NODE_PRIV[$(node_index "$1")]}"; }
sid_of() { printf '%s' "${NODE_SID[$(node_index "$1")]}"; }
for n in "${ALL_NODES[@]}"; do
  sh_ "$n" true 2>/dev/null || die "cannot ssh to root@$n"
  p="$(priv_ip_of "$n" || true)"
  [ -n "$p" ] || die "$n has no Hetzner private network attached (or no metadata service): attach every node to one private network first"
  s="$(server_id_of "$n" || true)"
  [ -n "$s" ] || die "$n did not return an instance-id from the metadata service"
  ni="$(node_index "$n")"
  NODE_PRIV[$ni]="$p"; NODE_SID[$ni]="$s"
  printf '   %-16s private %-12s server-id %s\n' "$n" "$p" "$s"
  sh_ "$n" "test ! -x /usr/local/bin/k3s" || echo "     (k3s already present on $n: this script is idempotent, it will re-run the installer)"
done
FIRST_PRIV="$(priv_of "$FIRST")"

if [ -z "$HCLOUD_TOKEN" ]; then
  echo "   no --token given: the cloud-controller-manager will be SKIPPED."
  echo "   Everything else works; a type=LoadBalancer Service will stay <pending>."
fi

# ---- 0b. close the doors before opening any ---------------------------------
# Done FIRST, before k3s exists, because the window between "kubelet is
# listening" and "firewall is up" is a window.
#
# What this closes, measured on the first live cluster: the kubelet API (:10250)
# was reachable from the whole internet on every node, and the Kubernetes API
# (:6443) on every server. Both answer 401 to an anonymous request, so neither
# is an open door - but a kubelet reachable from anywhere is one authorization
# bug away from remote code execution on every node, and neither belongs on the
# public internet. See GOTCHAS.md item 19.
#
# A Hetzner cloud firewall costs nothing, is enforced OUTSIDE the host (so a
# compromised node cannot switch it off), and is attached to the servers rather
# than baked into them.
if [ -n "$HCLOUD_TOKEN" ]; then
  say "cloud firewall: ssh and the API from your address only"
  OPERATOR_IP="${OPERATOR_IP:-$(sh_ "$FIRST" 'echo $SSH_CLIENT' | awk '{print $1}')}"
  if [ -z "$OPERATOR_IP" ]; then
    echo "   could not detect your public address; set OPERATOR_IP=x.x.x.x and re-run"
  else
    echo "   your address, as the node sees it: $OPERATOR_IP"
    sh_ "$FIRST" "cat > /tmp/fw.py" <<'PY'
import json, os, sys, urllib.request
T = os.environ["HCLOUD_TOKEN"]; MY = sys.argv[1] + "/32"
def api(path, payload=None, method="GET"):
    data = json.dumps(payload).encode() if payload is not None else None
    r = urllib.request.Request("https://api.hetzner.cloud/v1/"+path, data=data, method=method,
        headers={"Authorization": "Bearer "+T, "Content-Type": "application/json"})
    body = urllib.request.urlopen(r, timeout=30).read()
    return json.loads(body) if body else {}
rules = [
    {"direction": "in", "protocol": "tcp", "port": "22",   "source_ips": [MY], "description": "ssh, operator only"},
    {"direction": "in", "protocol": "tcp", "port": "6443", "source_ips": [MY], "description": "kube api, operator only"},
    {"direction": "in", "protocol": "icmp",                "source_ips": [MY], "description": "ping, operator only"},
]
name = "agent-stack-operator-only"
found = [f for f in api("firewalls")["firewalls"] if f["name"] == name]
if found:
    fw = found[0]; api(f"firewalls/{fw['id']}/actions/set_rules", {"rules": rules}, "POST")
else:
    fw = api("firewalls", {"name": name, "rules": rules}, "POST")["firewall"]
# THIS cluster's nodes, matched by public address, and not one server more.
# This used to take every server the token could see and apply the firewall to
# all of them. A Hetzner token is project-wide, so a project holding anything
# else got that machine locked to one operator's address by a script it was
# never named in. The nodes are an argument to this installer; there is no
# reason to ask the API which servers exist.
wanted = set(sys.argv[2:])
servers = [s for s in api("servers?per_page=50")["servers"]
           if (s["public_net"]["ipv4"] or {}).get("ip") in wanted]
missing = wanted - {(s["public_net"]["ipv4"] or {}).get("ip") for s in servers}
if missing:
    sys.exit(f"   these --servers/--agents are not in this Hetzner project: {sorted(missing)}\n"
             f"   (a firewall applied to the wrong project is worse than none)")

# Already applied is not an error. `apply_to_resources` answers 422 for a
# resource the firewall already covers, so a plain re-run of an installer that
# advertises itself as idempotent died on its own previous success.
already = {a.get("server", {}).get("id") for a in fw.get("applied_to", [])
           if a.get("type") == "server"}
todo = [s["id"] for s in servers if s["id"] not in already]
if todo:
    api(f"firewalls/{fw['id']}/actions/apply_to_resources",
        {"apply_to": [{"type": "server", "server": {"id": i}} for i in todo]}, "POST")
    print(f"   firewall {fw['id']} applied to {len(todo)} node(s)")
else:
    print(f"   firewall {fw['id']} already covers all {len(servers)} node(s)")
print(f"   everything inbound dropped except 22, 6443 and icmp from {MY}")
PY
    sh_ "$FIRST" "HCLOUD_TOKEN='$HCLOUD_TOKEN' python3 /tmp/fw.py '$OPERATOR_IP' ${ALL_NODES[*]} && rm -f /tmp/fw.py"
    echo "   NOTE: if your address changes, re-run this script or widen the rule, or you will be locked out."
  fi
else
  echo "   no --token: SKIPPING the cloud firewall. The kubelet API will be reachable"
  echo "   from the internet on every node. Fix that before this cluster holds anything."
fi

# sshd: key-only, and no root password path at all. Free, and it removes the
# one service that is deliberately public from every password-guessing list.
say "sshd: keys only"
for n in "${ALL_NODES[@]}"; do
  sh_ "$n" 'F=/etc/ssh/sshd_config.d/99-stack-hardening.conf
    printf "PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\nX11Forwarding no\nMaxAuthTries 3\n" > $F
    chmod 644 $F
    sshd -t && (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null)' \
    && echo "   $n hardened" || echo "   $n: sshd config rejected, left as it was"
done

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
    modprobe dm_crypt || true

    # multipathd arrives WITH open-iscsi and breaks Longhorn on contact.
    # Longhorn presents every volume over iSCSI as IET/VIRTUAL-DISK, multipathd
    # claims each one as an mpath map, and mke2fs then refuses to format it:
    #
    #   /dev/longhorn/pvc-... is apparently in use by the system;
    #   will not make a filesystem here!
    #
    # Every PVC stays Pending and every pod waits on it. Nothing in the pod
    # event mentions multipath, and the package was never asked for: it came in
    # as a dependency of the line above.
    #
    # Blacklisted by VENDOR, not by devnode. The blacklist most often quoted for
    # this is a devnode match on ^sd[a-z0-9]+, which switches multipath off for
    # every SCSI disk on the host. This excludes only the Longhorn devices and
    # leaves a real multipath configuration, if there is one, working.
    if systemctl is-enabled multipathd >/dev/null 2>&1 || [ -e /etc/multipath.conf ]; then
      if ! grep -q "VIRTUAL-DISK" /etc/multipath.conf 2>/dev/null; then
        cat >> /etc/multipath.conf <<MP

# Longhorn volumes: see stack-k8s install.sh and GOTCHAS.md item 60.
blacklist {
    device {
        vendor "IET"
        product "VIRTUAL-DISK"
    }
}
MP
        systemctl restart multipathd 2>/dev/null || true
        # Drop maps already claimed, or volumes created before this stay
        # unformattable until the node reboots.
        sleep 2; multipath -F 2>/dev/null || true
      fi
    fi' &
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
#   --disable=local-storage   k3s's own local-path provisioner, and with it the
#                             SECOND default StorageClass. Patching that class
#                             to non-default is not durable: k3s rewrites its
#                             bundled manifests on every server restart and the
#                             annotation comes back. Measured here on 2026-07-25:
#                             a restart for --secrets-encryption silently
#                             restored it, and `verify.sh` caught two defaults
#                             again hours later (GOTCHAS 3)
#   --kubelet-arg=provider-id the kubelet registers as hcloud://<server-id>, so
#                             the cloud controller can map a Node to a Hetzner
#                             server. Set at INSTALL time on purpose: providerID
#                             is immutable, so retrofitting it means deleting
#                             the Node object, which on a server also removes
#                             its etcd member and detaches its volumes
#                             (GOTCHAS 10)
#   --secrets-encryption      Secrets are encrypted at rest. Without it every
#                             Secret sits in etcd as PLAINTEXT, so an etcd
#                             snapshot, a disk image or a backup IS the
#                             credential set - verified by reading a database
#                             password straight out of etcd on the first live
#                             cluster (GOTCHAS 18). Retrofitting this needs a
#                             hand-written encryption config, a rolling
#                             restart and a rewrite of every existing Secret;
#                             at install time it is one flag
#   --write-kubeconfig-mode 0600  the default 0644 leaves cluster-admin
#                             credentials world-readable on the node
#
# The cluster token goes in through the installer's ENVIRONMENT, never as
# `--token` on the command line: the installer writes it to
# /etc/systemd/system/k3s.service.env (0600), whereas a flag would put it in
# the unit file and in every `ps` listing for the life of the node.
# The name a node registers under is decided ONCE, here, and never re-decided by
# whatever `hostname` happens to return on some later boot. k3s defaults the node
# name to the host name, and that value is not reliably stable across a stop and
# start: on the 2026-08-27 GCP range a node that had registered under its fully
# qualified name came back from a stop/start under its short one, and the
# original object sat NotReady for the rest of the cluster's life still holding
# 17 pod records that nothing ever cleans up
# (cloud/gcp/evidence/range-2026-08-27/FINDINGS.md, F3). The measurement was on
# GCP; the exposure is the same wherever a host name can be re-derived at boot,
# so all three installers pin it.
#
# The value read here is the one k3s would have picked by itself, so pinning it
# changes nothing about an existing cluster's identity. It only stops that choice
# from being made a second time.
node_name_of() { sh_ "$1" hostname 2>/dev/null || printf '%s' "$1"; }
FIRST_NODE_NAME="$(node_name_of "$FIRST")"
[ -n "$FIRST_NODE_NAME" ] || die "could not read a host name from $FIRST to pin --node-name to"

say "k3s server on $FIRST ($FIRST_PRIV)"
# The token is REUSED when this cluster already has one, and that is what makes
# a second run of this script possible at all. k3s encrypts its bootstrap data
# with the token the cluster was created with, so handing it a fresh random one
# is fatal and says so in a way that names neither the token nor this script:
#
#   failed to reconcile with local datastore:
#   bootstrap data already found and encrypted with different token
#
# Read from the DATASTORE's own copy, not from
# /etc/systemd/system/k3s.service.env: the k3s installer rewrites that env file
# with whatever it was just given, so by the time a failed run is examined it
# holds the wrong token and the right one survives only here.
K3S_TOKEN_VALUE="${K3S_TOKEN_VALUE:-}"
if [ -z "$K3S_TOKEN_VALUE" ]; then
  K3S_TOKEN_VALUE="$(sh_ "$FIRST" 'cat /var/lib/rancher/k3s/server/token 2>/dev/null' || true)"
  if [ -n "$K3S_TOKEN_VALUE" ]; then
    echo "   reusing the token this cluster was created with"
  else
    K3S_TOKEN_VALUE="$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
fi
sh_ "$FIRST" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - server \
    --cluster-init \
    --node-name '$FIRST_NODE_NAME' \
    --node-ip '$FIRST_PRIV' --advertise-address '$FIRST_PRIV' \
    --tls-san '$FIRST_PRIV' --tls-san '$FIRST' \
    --flannel-backend=none --disable-network-policy \
    --disable=servicelb --disable=traefik \
    --disable=local-storage \
    --secrets-encryption \
    --kubelet-arg=provider-id=hcloud://$(sid_of "$FIRST") \
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
  say "k3s server joining: $n ($(priv_of "$n"))"
  JOINED_NAME="$(node_name_of "$n")"
  [ -n "$JOINED_NAME" ] || die "could not read a host name from $n to pin --node-name to"
  sh_ "$n" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - server \
      --server 'https://$FIRST_PRIV:6443' \
      --node-name '$JOINED_NAME' \
      --node-ip '$(priv_of "$n")' --advertise-address '$(priv_of "$n")' \
      --tls-san '$(priv_of "$n")' --tls-san '$n' \
      --flannel-backend=none --disable-network-policy \
      --disable=servicelb --disable=traefik \
      --disable=local-storage \
      --secrets-encryption \
      --kubelet-arg=provider-id=hcloud://$(sid_of "$n") \
      --write-kubeconfig-mode 0600" < <(curl -sfL https://get.k3s.io)
  for i in $(seq 1 40); do
    k_ "get node $JOINED_NAME -o name" >/dev/null 2>&1 && break
    sleep 5
  done
done

for n in ${AGENT_LIST[@]+"${AGENT_LIST[@]}"}; do
  say "k3s agent: $n ($(priv_of "$n"))"
  sh_ "$n" "INSTALL_K3S_VERSION='$K3S_VERSION' K3S_URL='https://$FIRST_PRIV:6443' K3S_TOKEN='$K3S_TOKEN_VALUE' sh -s - agent \
      --node-name '$(node_name_of "$n")' \
      --node-ip '$(priv_of "$n")' \
      --kubelet-arg=provider-id=hcloud://$(sid_of "$n")" < <(curl -sfL https://get.k3s.io)
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

# The servers are installed with --disable=local-storage, so there should be
# exactly one default class already. This patch is the fallback for a cluster
# that was installed before that flag existed: it fixes the symptom, and it is
# NOT durable on its own, because k3s re-applies its bundled manifests on every
# server restart and the annotation returns (GOTCHAS 3).
say "one default StorageClass"
if k_ "get sc local-path" >/dev/null 2>&1; then
  echo "   local-path still exists (pre-existing cluster): patching it non-default"
  k_ "patch storageclass local-path -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}'" >/dev/null
  echo "   NOTE: re-run this after any k3s server restart, or reinstall with --disable=local-storage"
fi
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
  # Recreate, and this is the whole reason the patch below can ever take
  # effect. The upstream manifest is applied first, so its pod starts with the
  # DEFAULT :10258, which k3s itself is already listening on, and crash-loops.
  # That pod is hostNetwork, so while it exists it holds the node's port budget
  # and the corrected pod cannot be scheduled at all: "0/1 nodes are available:
  # 1 node(s) didn't have free ports". Under RollingUpdate the two then wait
  # for each other forever, because the old pod is not removed until the new
  # one is Ready and the new one cannot start until the old is gone. The
  # rollout times out with "1 old replicas are pending termination" and nothing
  # in that message mentions a port.
  #
  # Recreate breaks it by stopping the old pod BEFORE starting the new one,
  # which is correct for a single-replica hostNetwork controller anyway: two of
  # these can never run side by side on one node whatever the strategy says.
  strategy:
    type: Recreate
    # Required: leaving the old block would be Recreate with RollingUpdate
    # settings, which the API server rejects.
    rollingUpdate: null
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

# ---- 7b. the planes' bearer keys -------------------------------------------
# `stack-keys` is referenced by five secretKeyRefs across 10-planes.yaml and
# 20-console.yaml, and until this block existed nothing created it: a fresh
# cluster applied the manifests and every plane sat in
# CreateContainerConfigError with no hint about what the missing values should
# even look like.
#
# Both planes take `key:org[:role]` on the SERVER side and the bare key on the
# CLIENT side, and conflating the two is worse than an outage: a value with no
# `:org` half parses to zero valid keys, so the plane starts cleanly,
# authenticates nobody, answers 401 to its own console, and says so in one log
# line. Three secrets, five values:
#
#   cloud_keys      the spec tokenfuse-cloud accepts
#   cloud_admin     the bare key the gateway and console present to it
#   wardryx_keys    the spec wardryx accepts, TWO principals
#   wardryx_admin   the console's key: it administers policy
#   wardryx_gateway the gateway's key, deliberately VIEWER. /v1/decide needs
#                   any authenticated principal, and an enforcement point that
#                   can rewrite the policy it enforces is not one.
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

# ---- 7c. the tunnel's network door ----------------------------------------
# Only needed when the console reaches the WireGuard daemon over a network
# rather than a shared volume, which is the Kubernetes shape (see
# tunnel/DESIGN-uapi-transport.md). Generated here anyway, because it costs
# nothing to have and the alternative is an operator minting a certificate by
# hand at the moment they least want to.
#
# A tiny CA that signs exactly one leaf, and whose key is DESTROYED the moment
# it has signed. That last part is what keeps this from being a certificate
# authority in the sense that costs: there is no key left to protect, nothing
# can mint a second identity, and rotating means running this block again.
#
# Why not one self-signed certificate handed to both ends, which is simpler and
# was the first attempt: rustls refuses it outright with
# `invalid peer certificate: CaUsedAsEndEntity`, because `openssl req -x509`
# marks a self-signed certificate CA:TRUE and webpki will not accept a CA as an
# end-entity certificate. Verified by a test rather than discovered on a
# cluster (crates/connectors/tests/uapi_tls_pinning.rs in genaryx).
#
# The SAN carries both the short and the fully qualified Service name, because
# which one a client uses depends on its namespace's search path and a mismatch
# fails as a certificate error rather than a naming one.
PROXY_DNS_SHORT="${WG_PROXY_DNS_SHORT:-wg-uapi.agent-tunnel}"
PROXY_DNS_FQDN="${WG_PROXY_DNS_FQDN:-wg-uapi.agent-tunnel.svc.cluster.local}"
if ! k_ "-n agent-stack get secret stack-tunnel-proxy" >/dev/null 2>&1; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "   no openssl on this machine: SKIPPING the tunnel proxy credentials."
    echo "   The unix relay is unaffected; only a console in another pod needs these."
  else
    say "tunnel proxy credentials (generated, never committed)"
    PROXY_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    PROXY_TMP="$(mktemp -d)"
    # P-256 throughout: boring, and accepted by every TLS 1.3 stack without a
    # feature flag.
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$PROXY_TMP/ca.key" -out "$PROXY_TMP/ca.crt" -days 3650 \
      -subj "/CN=stack-k8s tunnel proxy CA" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign" >/dev/null 2>&1 \
      || die "openssl could not generate the tunnel proxy CA"
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$PROXY_TMP/tls.key" -out "$PROXY_TMP/tls.csr" \
      -subj "/CN=$PROXY_DNS_SHORT" >/dev/null 2>&1 \
      || die "openssl could not generate the tunnel proxy key"
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s,DNS:%s\n' \
      "$PROXY_DNS_SHORT" "$PROXY_DNS_FQDN" > "$PROXY_TMP/leaf.ext"
    openssl x509 -req -in "$PROXY_TMP/tls.csr" -CA "$PROXY_TMP/ca.crt" -CAkey "$PROXY_TMP/ca.key" \
      -days 3650 -extfile "$PROXY_TMP/leaf.ext" -out "$PROXY_TMP/tls.crt" >/dev/null 2>&1 \
      || die "openssl could not sign the tunnel proxy certificate"
    # The authority stops existing here, before anything is stored. Nothing
    # after this point can issue a second certificate for this name.
    rm -f "$PROXY_TMP/ca.key"
    k_ "-n agent-stack create secret generic stack-tunnel-proxy \
        --from-literal=token='$PROXY_TOKEN' \
        --from-literal=ca.crt='$(cat "$PROXY_TMP/ca.crt")' \
        --from-literal=tls.crt='$(cat "$PROXY_TMP/tls.crt")' \
        --from-literal=tls.key='$(cat "$PROXY_TMP/tls.key")'" >/dev/null
    rm -rf "$PROXY_TMP"
    echo "   created secret stack-tunnel-proxy for $PROXY_DNS_SHORT"
  fi
else
  echo "   secret stack-tunnel-proxy already exists, left as is"
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
