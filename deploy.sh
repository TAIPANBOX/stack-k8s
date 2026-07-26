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
#
# `--console-ref <branch>` builds the console from a branch instead of main.
# The console is a separate repository, so a change proven on a branch there
# was, until this flag, undeployable by this script at any version.
set -euo pipefail

SERVERS=""; AGENTS=""; SSH_KEY="${SSH_KEY:-}"
HCLOUD_TOKEN="${HCLOUD_TOKEN:-}"
CONSOLE_TOKEN="${CONSOLE_TOKEN:-}"
# The console is its OWN repository with its own branches, and until this
# existed there was no way to deploy one: the clone below took whatever `main`
# happened to be. A console change could be written, reviewed and proven on a
# branch and still be undeployable, which is a strange thing for a deployment
# script to enforce.
CONSOLE_REF="${CONSOLE_REF:-main}"
# The operator tunnel, which is how anyone reaches the console afterwards. Empty
# means "ask, if there is a terminal to ask on"; 0 means the operator said no
# and will use `ssh -L` instead, which is a real way to run this.
WANT_TUNNEL="${WANT_TUNNEL:-}"
TUNNEL_DONE=0
CONSOLE_DOMAIN="${CONSOLE_DOMAIN:-}"
ENDPOINT_HOST="${ENDPOINT_HOST:-}"
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
    --console-ref)   CONSOLE_REF="$2"; shift 2 ;;
    --console-domain) CONSOLE_DOMAIN="$2"; WANT_TUNNEL=1; shift 2 ;;
    --endpoint-host)  ENDPOINT_HOST="$2";  WANT_TUNNEL=1; shift 2 ;;
    --no-tunnel)      WANT_TUNNEL=0; shift ;;
    --skip-install)  SKIP_INSTALL=1; shift ;;
    --skip-images)   SKIP_IMAGES=1; shift ;;
    -h|--help)       awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done
[ -n "$SERVERS" ] || { echo "--servers is required (comma-separated public IPs)" >&2; exit 1; }

say()  { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
die()  { EXPLAINED=1; printf '\n!! %s\n' "$*" >&2; exit 1; }
EXPLAINED=0

# Under `set -e` an unhandled failure ends this script wherever it happens, and
# a deploy that ends mid-sentence looks like a deploy that finished. Say which
# line died and with what, always. 141 is SIGPIPE, which `set -e` otherwise
# turns into an invisible exit.
trap 'rc=$?; { [ $rc -eq 0 ] || [ "${EXPLAINED:-0}" = 1 ]; } && exit $rc
      printf "\n!! deploy.sh stopped at line %s (exit %s)\n" "$LINENO" "$rc" >&2
      [ $rc -eq 141 ] && printf "   exit 141 is SIGPIPE: a pipeline ended early. This is a bug in the script, please report it.\n" >&2
      printf "   Re-running is safe: every step here is idempotent.\n" >&2
      exit $rc' EXIT

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

# ---- 0b. the tunnel's two names, asked BEFORE the long part -----------------
# Asked here rather than at the end, and the ordering is the whole point: the
# answers are checked against DNS, and an operator should learn that a record is
# missing in the first ten seconds rather than after fifteen minutes of building
# images. Everything else this script needs was already on the command line.
#
# Opening /dev/tty rather than testing it: `[ -r /dev/tty ]` succeeds whenever
# the device node exists, including in a detached process, and the failure then
# lands after the question has been printed. And a plain `read` would be worse
# still under the documented `curl ... | bash` form, where this script's own
# stdin IS the script: it would consume the remaining source as the answer.
if [ -z "$WANT_TUNNEL" ]; then
  if { exec 4<>/dev/tty; } 2>/dev/null; then
    cat >&4 <<'TXT'

   The console is published nowhere: every Service is ClusterIP and
   security-tests.sh asserts it. Two ways to reach it afterwards:

     a WireGuard tunnel, which needs two names you control and two DNS
     records, and which every device you later issue goes through
     ssh -L from your own machine, which needs nothing and suits one operator

TXT
    printf '   set up the tunnel now? [Y/n] ' >&4
    IFS= read -r ans <&4 || ans=""
    case "$(printf '%s' "$ans" | tr 'A-Z' 'a-z' | tr -d '[:space:]')" in
      n|no) WANT_TUNNEL=0 ;;
      *)    WANT_TUNNEL=1 ;;
    esac
    exec 4>&-
  else
    WANT_TUNNEL=0
    echo "   no terminal to ask on: SKIPPING the tunnel. Add it later with"
    echo "   ./tunnel/configure.sh then ./tunnel/up.sh, or pass --console-domain"
    echo "   and --endpoint-host here."
  fi
fi

if [ "$WANT_TUNNEL" = 1 ]; then
  cfg=("$ROOT/tunnel/configure.sh")
  [ -n "$CONSOLE_DOMAIN" ] && cfg+=(--console-domain "$CONSOLE_DOMAIN")
  [ -n "$ENDPOINT_HOST" ]  && cfg+=(--endpoint-host  "$ENDPOINT_HOST")
  [ -s "$ROOT/tunnel/site.yaml" ] && cfg+=(--force)
  "${cfg[@]}" || die "the tunnel was not configured, so nothing has been installed yet.
   Re-run, or add --no-tunnel to deploy without it."
fi

# ---- 1. the cluster ---------------------------------------------------------
if [ "$SKIP_INSTALL" = 1 ]; then
  say "skipping install.sh (--skip-install)"
else
  say "step 1/5: the cluster"
  # KUBECONFIG_OUT stated rather than left to default. install.sh writes
  # `./kubeconfig.yaml` relative to the CURRENT directory, and this script never
  # cd's into $ROOT, so run from anywhere else the file lands in one place and
  # step 6 below looks in another. Naming it makes the two agree.
  KUBECONFIG_OUT="$ROOT/kubeconfig.yaml" \
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
    # `--branch` on both paths, and a hard reset rather than a pull on the
    # second: `git pull --ff-only` on a checkout sitting on a DIFFERENT branch
    # fails, gets swallowed by `|| true`, and the build then quietly produces
    # the previous branch's console while reporting success.
    if sh_ "$BUILDER" "cd /root/src && \
       if [ -d genaryx-a360/.git ]; then \
         git -C genaryx-a360 remote set-url origin https://x-access-token:$CONSOLE_TOKEN@github.com/TAIPANBOX/genaryx.git && \
         git -C genaryx-a360 fetch -q --depth 1 origin '$CONSOLE_REF' && \
         git -C genaryx-a360 checkout -q -B '$CONSOLE_REF' FETCH_HEAD; \
       else \
         rm -rf genaryx-a360 && \
         git clone -q --depth 1 --branch '$CONSOLE_REF' https://x-access-token:$CONSOLE_TOKEN@github.com/TAIPANBOX/genaryx.git genaryx-a360; \
       fi && \
       git -C genaryx-a360 remote set-url origin https://github.com/TAIPANBOX/genaryx.git && \
       echo \"   genaryx (console) ok, at \$(git -C genaryx-a360 rev-parse --short HEAD) on $CONSOLE_REF\""; then
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
    # The operator tunnel needs these two, and nothing else builds them. Left
    # out, ./tunnel/up.sh reaches a running cluster and then sits in
    # ImagePullBackOff for images that were never built anywhere, which reads
    # like a registry problem rather than a missing build. Cheap: one Go binary
    # and one xcaddy build, both tiny beside the console.
    docker build -q -f stack-k8s/images/wg.Dockerfile -t stack/wg:dev stack-k8s >/dev/null
    echo '   built stack/wg:dev'
    docker build -q -f stack-k8s/images/caddy.Dockerfile -t stack/caddy:dev stack-k8s >/dev/null
    echo '   built stack/caddy:dev'
    if [ '$WITH_CONSOLE' = '1' ]; then
      docker build -q -f stack-k8s/images/console.Dockerfile -t stack/genaryx-console:dev . >/dev/null
      echo '   built stack/genaryx-console:dev'
    fi"

  say "importing images into every node's containerd"
  IMAGES="stack/wardryx:dev stack/idryx:dev stack/qryx:dev stack/mockryx:dev stack/tokenfuse:dev"
  IMAGES="$IMAGES stack/wg:dev stack/caddy:dev"
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

# ---- 6. the way in ---------------------------------------------------------
# Last, because it is the only step that hands the operator something to use
# rather than something to read: a config file, a QR, and an address. The two
# names it needs were asked for at the top, before any of the above, so a
# missing DNS record cannot waste the fifteen minutes in between.
if [ "$WANT_TUNNEL" = 1 ]; then
  say "step 6: your way in"
  ( cd "$ROOT" && KUBECONFIG="$ROOT/kubeconfig.yaml" ./tunnel/up.sh ) \
    || die "the stack is up and verified; only the tunnel failed.
   Fix what it printed and re-run just that part:
       cd $ROOT && KUBECONFIG=./kubeconfig.yaml ./tunnel/up.sh"
  TUNNEL_DONE=1
fi

CONSOLE_NODE="$(k_ "-n agent-stack get pod -l app=genaryx-console -o jsonpath='{.items[0].spec.nodeName}'" 2>/dev/null || true)"
CONSOLE_IP="$(k_ "-n agent-stack get svc genaryx-console -o jsonpath='{.spec.clusterIP}'" 2>/dev/null || true)"

# ---- the operator account --------------------------------------------------
# Until one exists the console refuses EVERY sign-in, and says so only in its
# own log, so an install that stops here looks broken rather than unfinished.
# Generate one, set it, and print it once. Deliberately not stored anywhere:
# not in a Secret (which every cluster-admin can read), not in a file, not in
# this script's own output beyond the line below.
CONSOLE_USER="${CONSOLE_USER:-ops}"
CONSOLE_PASSWORD=""
if [ -n "$CONSOLE_NODE" ]; then
  if k_ "-n agent-stack exec -i deploy/genaryx-console -- test -s /var/lib/stack/.taipan/genaryx-web/operator.json" >/dev/null 2>&1; then
    say "operator account already exists, left as is"
  else
    # 24 bytes of urandom, base64, punctuation stripped: long enough that the
    # Argon2id hash behind it is not the weak link, safe to paste anywhere.
    # The subshell disables pipefail deliberately. `tr </dev/urandom | head -c N`
    # is the idiom everyone writes, and under `set -o pipefail` it is a trap:
    # head closes the pipe once it has its N bytes, tr dies of SIGPIPE, the
    # pipeline reports 141 and `set -e` ends the deploy right here, silently,
    # with the cluster up and no operator account.
    CONSOLE_PASSWORD="$( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28 )"
    [ "${#CONSOLE_PASSWORD}" = 28 ] || die "could not generate an operator password; /dev/urandom is not readable."
    if printf '%s\n' "$CONSOLE_PASSWORD" | k_ "-n agent-stack exec -i deploy/genaryx-console -- /usr/local/bin/genaryx-web set-password --username $CONSOLE_USER" >/dev/null 2>&1; then
      say "operator '$CONSOLE_USER' created"
      # The console resolved "do I have an operator" at startup and does not
      # look again, so without this restart the account exists on disk and the
      # sign-in page still says the box has none (GOTCHAS.md item 50).
      k_ "-n agent-stack rollout restart deploy/genaryx-console" >/dev/null 2>&1 || true
      k_ "-n agent-stack rollout status deploy/genaryx-console --timeout=180s" >/dev/null 2>&1 || true
    else
      CONSOLE_PASSWORD=""
      say "could not set the operator password automatically; the command is printed below"
    fi
  fi
fi

# The tunnel has to land on the node running the console pod, so resolve that
# node's real address here rather than leaving the reader to map a Kubernetes
# node name onto an ssh target.
CONSOLE_ADDR=""
if [ -n "$CONSOLE_NODE" ]; then
  CONSOLE_ADDR="$(k_ "get node $CONSOLE_NODE -o jsonpath='{.status.addresses[?(@.type==\"ExternalIP\")].address}'" 2>/dev/null || true)"
  [ -n "$CONSOLE_ADDR" ] || CONSOLE_ADDR="$(k_ "get node $CONSOLE_NODE -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'" 2>/dev/null || true)"
fi

cat <<EOF

$(printf '\033[1m')Done.$(printf '\033[0m')

${CONSOLE_PASSWORD:+  Your console sign-in, shown once and stored nowhere:

      user      $CONSOLE_USER
      password  $CONSOLE_PASSWORD

  Change it whenever you like, and enrol a passkey once you are in:

      ssh root@$FIRST "/usr/local/bin/k3s kubectl -n agent-stack exec -i deploy/genaryx-console -- \\
        /usr/local/bin/genaryx-web set-password --username $CONSOLE_USER"

}${CONSOLE_PASSWORD:-  Set the operator's password (read from stdin, stored as an Argon2id hash).
  Until one exists the console refuses every sign-in:

      ssh root@$FIRST "/usr/local/bin/k3s kubectl -n agent-stack exec -i deploy/genaryx-console -- \\
        /usr/local/bin/genaryx-web set-password --username $CONSOLE_USER"

}  Reach the console over YOUR tunnel. There is no public entry point by
  design, and the tunnel has to land on the node running the console pod
  (GOTCHAS.md item 13)${CONSOLE_NODE:+, currently $CONSOLE_NODE}:

      ssh -L 17420:${CONSOLE_IP:-<console-clusterIP>}:7420 root@${CONSOLE_ADDR:-<that node's address>}
      open http://localhost:17420

  Re-check any time:

      ssh root@$FIRST 'KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/verify.sh --freeze'
      ssh root@$FIRST 'KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/security-tests.sh'

  A public entry point is a separate, metered decision:
  kubectl apply -f manifests/50-loadbalancer.yaml, and read its header first.
EOF
