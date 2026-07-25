#!/usr/bin/env bash
# One command, bare servers to a governed agent stack.
#
#   curl -fsSL https://raw.githubusercontent.com/TAIPANBOX/stack-k8s/main/deploy.sh | bash -s -- \
#     --servers 1.2.3.4,1.2.3.5,1.2.3.6 --agents 1.2.3.7,1.2.3.8 --hcloud-token <token>
#
# or, from a clone:
#
#   ./deploy.sh --servers 1.2.3.4,1.2.3.5,1.2.3.6 --agents 1.2.3.7,1.2.3.8 --hcloud-token <token>
#
# What it does, in order, each step already documented in its own file:
#
#   1. install.sh        the cluster: a cloud firewall first, sshd keys-only,
#                        k3s with secrets encrypted at rest, Calico so
#                        NetworkPolicy is real, Longhorn with an RWX class, the
#                        cloud controller narrowed to load balancers
#   2. sources + images  clones the stack's repos onto ONE node and builds the
#                        images there, then imports them into every node's
#                        containerd. No registry, no pull secrets, no second
#                        bill
#   3. manifests         kubectl apply -k, then waits for every rollout
#   4. verify.sh         proves the stack is running: ten checks
#   5. security-tests.sh proves it is contained: seventeen checks
#
# The open stack needs NO credentials: wardryx, idryx, qryx, mockryx, tokenfuse,
# verdryx and engram are public. The Genaryx console is the one paid, closed
# piece, so `--console-token <github-token-with-access>` is what adds it. Leave
# it out and you get the governed stack without the control room, which is a
# real deployment and not a crippled one: the planes enforce with or without a
# UI in front of them.
set -euo pipefail

SERVERS=""; AGENTS=""; SSH_KEY="${SSH_KEY:-}"
HCLOUD_TOKEN="${HCLOUD_TOKEN:-}"
CONSOLE_TOKEN="${CONSOLE_TOKEN:-}"
REF="${REF:-main}"
SKIP_INSTALL=0; SKIP_IMAGES=0
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/TAIPANBOX/stack-k8s}"
REPO_TARBALL="${REPO_TARBALL:-https://api.github.com/repos/TAIPANBOX/stack-k8s/tarball}"

while [ $# -gt 0 ]; do
  case "$1" in
    --servers)       SERVERS="$2"; shift 2 ;;
    --agents)        AGENTS="$2"; shift 2 ;;
    --ssh-key)       SSH_KEY="$2"; shift 2 ;;
    --hcloud-token)  HCLOUD_TOKEN="$2"; shift 2 ;;
    --console-token) CONSOLE_TOKEN="$2"; shift 2 ;;
    --skip-install)  SKIP_INSTALL=1; shift ;;
    --skip-images)   SKIP_IMAGES=1; shift ;;
    -h|--help)       sed -n '2,30p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done
[ -n "$SERVERS" ] || { echo "--servers is required (comma-separated public IPs)" >&2; exit 1; }

say()  { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

IFS=',' read -r -a SERVER_LIST <<< "$SERVERS"
AGENT_LIST=(); [ -n "$AGENTS" ] && IFS=',' read -r -a AGENT_LIST <<< "$AGENTS"
ALL_NODES=("${SERVER_LIST[@]}" ${AGENT_LIST[@]+"${AGENT_LIST[@]}"})
FIRST="${SERVER_LIST[0]}"
# The last node builds. On a cluster this size the builder is also a worker, and
# building where the images are needed saves shipping them over the internet.
BUILDER="${ALL_NODES[${#ALL_NODES[@]}-1]}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o BatchMode=yes)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")
sh_() { ssh "${SSH_OPTS[@]}" "root@$1" "${@:2}"; }
k_()  { sh_ "$FIRST" "/usr/local/bin/k3s kubectl $*"; }

# ---- 0. find this repo, whether cloned or piped from curl -------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -d "$HERE/manifests" ]; then
  ROOT="$HERE"
  say "using this checkout: $ROOT"
else
  ROOT="$(mktemp -d)"
  say "fetching stack-k8s@$REF into $ROOT"
  auth=(); [ -n "$CONSOLE_TOKEN" ] && auth=(-H "Authorization: Bearer $CONSOLE_TOKEN")
  curl -fsSL "${auth[@]}" "$REPO_TARBALL/$REF" | tar -xz -C "$ROOT" --strip-components=1 \
    || die "could not fetch the repo. It is private today: pass --console-token, or clone it and run ./deploy.sh"
fi
[ -d "$ROOT/manifests" ] || die "no manifests/ in $ROOT"

# ---- 1. the cluster ---------------------------------------------------------
if [ "$SKIP_INSTALL" = 1 ]; then
  say "skipping install.sh (--skip-install)"
else
  say "step 1/5: the cluster"
  bash "$ROOT/install.sh" --servers "$SERVERS" ${AGENTS:+--agents "$AGENTS"} \
    ${SSH_KEY:+--ssh-key "$SSH_KEY"} ${HCLOUD_TOKEN:+--token "$HCLOUD_TOKEN"}
fi

# ---- 2. sources and images --------------------------------------------------
# The Dockerfiles build from a directory holding the repos side by side, because
# one image (the console) legitimately spans five of them. So the layout is
# reproduced on the builder rather than invented here.
#
# Note the directory name `genaryx-a360` for the `genaryx` repo: the console's
# Dockerfile refers to it by that path, which is the name it has in the
# development tree these images were first built from. Renaming it is a change
# to every Dockerfile and every build script, so the clone is named to match.
OPEN_REPOS="wardryx idryx qryx mockryx tokenfuse verdryx engram"
if [ "$SKIP_IMAGES" = 1 ]; then
  say "skipping the image build (--skip-images)"
else
  say "step 2/5: sources and images on $BUILDER"
  sh_ "$BUILDER" 'set -e
    export DEBIAN_FRONTEND=noninteractive
    command -v docker >/dev/null || { apt-get update -qq && apt-get install -y -qq docker.io git >/dev/null; }
    command -v git >/dev/null || apt-get install -y -qq git >/dev/null
    systemctl enable --now docker >/dev/null 2>&1 || true
    mkdir -p /root/src'
  # this repo's own Dockerfiles have to be on the builder too
  tar -cz -C "$ROOT" images manifests | sh_ "$BUILDER" 'mkdir -p /root/src/stack-k8s && tar -xz -C /root/src/stack-k8s'

  for r in $OPEN_REPOS; do
    sh_ "$BUILDER" "cd /root/src && if [ -d $r ]; then git -C $r pull -q --ff-only || true; else git clone -q --depth 1 https://github.com/TAIPANBOX/$r.git; fi && echo '   $r ok'"
  done

  WITH_CONSOLE=0
  if [ -n "$CONSOLE_TOKEN" ]; then
    if sh_ "$BUILDER" "cd /root/src && if [ -d genaryx-a360 ]; then git -C genaryx-a360 pull -q --ff-only || true; else git clone -q --depth 1 https://x-access-token:$CONSOLE_TOKEN@github.com/TAIPANBOX/genaryx.git genaryx-a360; fi && git -C genaryx-a360 remote set-url origin https://github.com/TAIPANBOX/genaryx.git && echo '   genaryx (console) ok'"; then
      WITH_CONSOLE=1
    else
      echo "   could not clone the console with that token: continuing WITHOUT it"
    fi
  else
    echo "   no --console-token: deploying the open stack without the Genaryx console"
  fi

  say "building images (the console build is four languages and takes the longest)"
  sh_ "$BUILDER" "set -e
    cd /root/src
    for pair in wardryx:wardryx idryx:idryx qryx:qryx mockryx:mockryx; do
      name=\${pair%%:*}; repo=\${pair##*:}
      docker build -q -f stack-k8s/images/go-service.Dockerfile \
        --build-arg SERVICE=\$name --build-arg SRC=./\$repo -t stack/\$name:dev . >/dev/null
      echo \"   built stack/\$name:dev\"
    done
    docker build -q -f stack-k8s/images/tokenfuse.Dockerfile -t stack/tokenfuse:dev ./tokenfuse >/dev/null
    echo '   built stack/tokenfuse:dev'
    if [ '$WITH_CONSOLE' = '1' ]; then
      docker build -q -f stack-k8s/images/console.Dockerfile -t stack/genaryx-console:dev . >/dev/null
      echo '   built stack/genaryx-console:dev'
    fi"

  say "importing images into every node's containerd"
  IMAGES="stack/wardryx:dev stack/idryx:dev stack/qryx:dev stack/mockryx:dev stack/tokenfuse:dev"
  [ "$WITH_CONSOLE" = 1 ] && IMAGES="$IMAGES stack/genaryx-console:dev"
  PRIVS=""
  for n in "${ALL_NODES[@]}"; do
    PRIVS="$PRIVS $(sh_ "$n" "curl -sf --max-time 5 http://169.254.169.254/hetzner/v1/metadata/private-networks | awk '/^- ip:/ {print \$3; exit}'")"
  done
  sh_ "$BUILDER" "for img in $IMAGES; do
      docker save \$img | k3s ctr images import - >/dev/null 2>&1 && echo \"   \$img -> this node\" || echo \"   \$img -> this node FAILED\"
      for p in $PRIVS; do
        docker save \$img | ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@\$p 'k3s ctr images import -' >/dev/null 2>&1 \
          && echo \"   \$img -> \$p\" || true
      done
    done" || echo "   (import over the private network needs node-to-node ssh; see the note at the end)"
fi

# ---- 3. the workload --------------------------------------------------------
say "step 3/5: the workload"
tar -cz -C "$ROOT" manifests | sh_ "$FIRST" 'mkdir -p /root/stack-k8s && tar -xz -C /root/stack-k8s'
k_ "apply -k /root/stack-k8s/manifests"
say "waiting for rollouts"
for d in $(k_ "-n agent-stack get deploy -o name"); do
  k_ "-n agent-stack rollout status $d --timeout=300s" || true
done
k_ "-n agent-stack rollout status statefulset/policy-db --timeout=300s" || true

# ---- 4 and 5. proof, not vibes ---------------------------------------------
tar -cz -C "$ROOT" verify.sh security-tests.sh | sh_ "$FIRST" 'tar -xz -C /root/stack-k8s'
say "step 4/5: is it running"
sh_ "$FIRST" 'KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/verify.sh' || true
say "step 5/5: is it contained"
sh_ "$FIRST" 'KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/security-tests.sh' || true

CONSOLE_NODE="$(k_ "-n agent-stack get pod -l app=genaryx-console -o jsonpath='{.items[0].spec.nodeName}'" 2>/dev/null || true)"
CONSOLE_IP="$(k_ "-n agent-stack get svc genaryx-console -o jsonpath='{.spec.clusterIP}'" 2>/dev/null || true)"

cat <<EOF

$(printf '\033[1m')Done.$(printf '\033[0m')

  Set the operator's password (read from stdin, stored as an Argon2id hash):

      ssh root@$FIRST "/usr/local/bin/k3s kubectl -n agent-stack exec -i deploy/genaryx-console -- \\
        /usr/local/bin/genaryx-web set-password --username you"

  Then reach the console over YOUR tunnel. There is no public entry point by
  design, and the tunnel has to land on the node running the console pod
  (GOTCHAS.md item 13)${CONSOLE_NODE:+, which is currently $CONSOLE_NODE}:

      ssh -L 17420:${CONSOLE_IP:-<console-clusterIP>}:7420 root@<that node's address>
      open http://localhost:17420

  Re-check any time:

      ssh root@$FIRST 'KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/verify.sh --freeze'
      ssh root@$FIRST 'KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/security-tests.sh'

  A public entry point is a separate, metered decision:
  kubectl apply -f manifests/50-loadbalancer.yaml, and read its header first.
EOF
