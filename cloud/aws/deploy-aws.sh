#!/usr/bin/env bash
# One command, bare EC2 instances to a governed agent stack.
#
#   ./deploy-aws.sh --servers 1.2.3.4,1.2.3.5,1.2.3.6 --agents 1.2.3.7,1.2.3.8
#
# The AWS counterpart of ../../deploy.sh. Same five steps, same proofs:
#
#   1. install-aws.sh    the cluster: k3s with secrets encrypted at rest,
#                        Calico so NetworkPolicy is real, Longhorn with an RWX
#                        class, the cloud controller narrowed to load balancers
#   2. sources + images  clones the stack's repos onto ONE node and builds them
#                        THERE, then distributes over the private network
#   3. manifests         kubectl apply -k, then waits for every rollout
#   4. verify.sh         proves the stack is running
#   5. security-tests.sh proves it is contained
#
# Step 2 is why the machine running this script stays light: no Docker here, no
# source tree here, no large checkout. It needs ssh, curl and the terraform and
# aws CLIs, which is what preflight.sh checks.
#
# The open stack needs NO credentials: wardryx, idryx, qryx, mockryx, tokenfuse,
# verdryx and engram are public. The Genaryx console is the one closed piece, so
# `--console-token <github-token>` is what adds it. Leave it out and you get the
# governed stack without the control room, which is a real deployment and not a
# crippled one: the planes enforce with or without a UI in front of them.
set -euo pipefail

SERVERS=""; AGENTS=""
SSH_KEY="${SSH_KEY:-$HOME/.ssh/stack-k8s-aws}"
SSH_USER="${SSH_USER:-ubuntu}"
CONSOLE_TOKEN="${CONSOLE_TOKEN:-}"
# Notifications, exactly as ../../deploy.sh asks for them. There is deliberately
# no --smtp-password: a secret on a command line is in `ps` for every user on
# the machine for as long as this runs, and in the shell history afterwards.
ALERT_TO="${ALERT_TO:-}"
ALERT_ASKED=0
SMTP_HOST="${SMTP_HOST:-}"
SMTP_FROM="${SMTP_FROM:-}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS=""
SKIP_INSTALL=0; SKIP_IMAGES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --servers)       SERVERS="$2"; shift 2 ;;
    --agents)        AGENTS="$2"; shift 2 ;;
    --ssh-key)       SSH_KEY="$2"; shift 2 ;;
    --console-token) CONSOLE_TOKEN="$2"; shift 2 ;;
    --alert-to)      ALERT_TO="$2"; ALERT_ASKED=1; shift 2 ;;
    --no-alerts)     ALERT_TO=""; ALERT_ASKED=1; shift ;;
    --smtp-host)     SMTP_HOST="$2"; shift 2 ;;
    --smtp-from)     SMTP_FROM="$2"; shift 2 ;;
    --smtp-user)     SMTP_USER="$2"; shift 2 ;;
    --skip-install)  SKIP_INSTALL=1; shift ;;
    --skip-images)   SKIP_IMAGES=1; shift ;;
    -h|--help)       sed -n '2,26p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done
[ -n "$SERVERS" ] || { echo "--servers is required (comma-separated public IPs)" >&2; exit 1; }

ask_alerts() {
  # Asked before anything is built, for the reason the Hetzner script gives:
  # everything an operator must decide is decided before fifteen minutes of
  # installing, not after. Blank is a real answer and the default one.
  [ "$ALERT_ASKED" = 0 ] && [ -z "$ALERT_TO" ] || return 0
  { exec 4<>/dev/tty; } 2>/dev/null || {
    echo "   no terminal to ask on: SKIPPING notifications. Pass --alert-to and"
    echo "   --smtp-host, or apply manifests/45-heraldyx.yaml yourself later."
    return 0
  }
  cat >&4 <<'TXT'

   Notifications. This box can write to you when one of your own agents
   crosses a line: a budget gone, a policy denial, a run killed, an agent
   behaving unlike itself. The mail comes from this box, and it carries a
   link into this console, never a button that acts.

   Mail is the only thing in this deployment that reaches outside the
   cluster, so answering this grants exactly one pod exactly one way out,
   on the mail ports and nowhere else.

   Leave the address blank for no notifications. Nothing is installed then.

TXT
  printf '   address for alerts (blank = none): ' >&4
  IFS= read -r ans <&4 || ans=""
  ALERT_TO="$(printf '%s' "$ans" | tr -d '[:space:]')"
  if [ -n "$ALERT_TO" ]; then
    while [ -z "$SMTP_HOST" ]; do
      printf '   mail server as host:port (e.g. smtp.example.com:587): ' >&4
      IFS= read -r ans <&4 || ans=""
      ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
      case "$ans" in
        "")  printf '   without one, this box has nothing to hand the mail to.\n' >&4 ;;
        *:*) SMTP_HOST="$ans" ;;
        *)   printf '   needs a port too: %s:587 for submission, :465 for implicit TLS.\n' "$ans" >&4 ;;
      esac
    done
    printf '   sender address [%s]: ' "$ALERT_TO" >&4
    IFS= read -r ans <&4 || ans=""
    ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
    SMTP_FROM="${ans:-$ALERT_TO}"
    printf '   username (blank = server wants no authentication): ' >&4
    IFS= read -r ans <&4 || ans=""
    SMTP_USER="$(printf '%s' "$ans" | tr -d '[:space:]')"
    if [ -n "$SMTP_USER" ]; then
      printf '   password: ' >&4
      IFS= read -rs SMTP_PASS <&4 || SMTP_PASS=""; printf '\n' >&4
    fi
  fi
  exec 4>&-
}

install_alerts() {
  [ -n "$ALERT_TO" ] || return 0
  say "notifications"
  # Piped over stdin, never passed as an argument: `k_` interpolates what it is
  # given into a shell command line on the node, where a mail password would sit
  # in `ps`. Base64 for a second reason: a password with a quote or a colon in it
  # breaks the YAML it travels in.
  b64_() { printf '%s' "$1" | base64 | tr -d '\n'; }
  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: heraldyx-mail\n  namespace: agent-stack\ntype: Opaque\ndata:\n'
    printf '  HERALDYX_TO: %s\n'        "$(b64_ "$ALERT_TO")"
    printf '  HERALDYX_SMTP_HOST: %s\n' "$(b64_ "$SMTP_HOST")"
    printf '  HERALDYX_SMTP_FROM: %s\n' "$(b64_ "$SMTP_FROM")"
    printf '  HERALDYX_BOX: %s\n'       "$(b64_ "aws")"
    if [ -n "$SMTP_USER" ]; then printf '  HERALDYX_SMTP_USER: %s\n' "$(b64_ "$SMTP_USER")"; fi
    if [ -n "$SMTP_PASS" ]; then printf '  HERALDYX_SMTP_PASS: %s\n' "$(b64_ "$SMTP_PASS")"; fi
    # No tunnel on this path, so no console name a browser could resolve. The
    # mail says it carries no link rather than carrying a dead one.
  } | k_ "-n agent-stack apply -f -" >/dev/null \
    || die "the stack is up; only the notification Secret failed to apply."
  SMTP_PASS=""

  k_ "apply -f /root/stack-k8s/manifests/45-heraldyx.yaml" >/dev/null \
    || die "the stack is up; only the notifier failed to apply."
  k_ "-n agent-stack rollout status deploy/heraldyx --timeout=180s" || true

  if k_ "-n agent-stack exec deploy/heraldyx -- /usr/local/bin/service --test-mail" 2>&1 | sed 's/^/   /'; then
    echo "   if that message does not arrive, the address or the server is wrong,"
    echo "   and nothing else in this install depends on it."
  else
    echo "   the test message did NOT go out. The stack is fine and unaffected."
    echo "       kubectl -n agent-stack logs deploy/heraldyx"
  fi
}

say() { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
die() { EXPLAINED=1; printf '\n!! %s\n' "$*" >&2; exit 1; }
EXPLAINED=0

trap 'rc=$?; { [ $rc -eq 0 ] || [ "${EXPLAINED:-0}" = 1 ]; } && exit $rc
      printf "\n!! deploy-aws.sh stopped at line %s (exit %s)\n" "$LINENO" "$rc" >&2
      [ $rc -eq 141 ] && printf "   exit 141 is SIGPIPE: a pipeline ended early. This is a bug in the script, please report it.\n" >&2
      printf "   Re-running is safe: every step here is idempotent.\n" >&2
      printf "   The cluster bills while you debug: ./cost-live.sh, and ./teardown.sh stops it.\n" >&2
      exit $rc' EXIT

IFS=',' read -r -a SERVER_LIST <<< "$SERVERS"
AGENT_LIST=(); [ -n "$AGENTS" ] && IFS=',' read -r -a AGENT_LIST <<< "$AGENTS"
ALL_NODES=("${SERVER_LIST[@]}" ${AGENT_LIST[@]+"${AGENT_LIST[@]}"})
FIRST="${SERVER_LIST[0]}"
BUILDER="${ALL_NODES[${#ALL_NODES[@]}-1]}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o BatchMode=yes)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY")
sh_() { ssh "${SSH_OPTS[@]}" "$SSH_USER@$1" "${@:2}"; }
su_() { ssh "${SSH_OPTS[@]}" "$SSH_USER@$1" "sudo ${*:2}"; }
k_()  { su_ "$FIRST" "/usr/local/bin/k3s kubectl $*"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
[ -d "$ROOT/manifests" ] || die "no manifests/ above this script. Run it from a checkout of stack-k8s."
say "using this checkout: $ROOT"

# A rebuilt cluster is likely to be handed the previous one's public addresses,
# and ssh refuses an address whose host key changed (GOTCHAS item 68).
for n in "${ALL_NODES[@]}"; do
  ssh-keygen -R "$n" >/dev/null 2>&1 || true
done

# Asked before anything is created or built, so a missing answer costs ten
# seconds rather than the fifteen minutes of installing that follow.
ask_alerts

# ---- 1. the cluster ---------------------------------------------------------
if [ "$SKIP_INSTALL" = 1 ]; then
  say "skipping install-aws.sh (--skip-install)"
else
  say "step 1/5: the cluster"
  bash "$(dirname "${BASH_SOURCE[0]:-$0}")/install-aws.sh" \
    --servers "$SERVERS" ${AGENTS:+--agents "$AGENTS"} --ssh-key "$SSH_KEY"
fi

# ---- 2. sources and images --------------------------------------------------
# Same layout as the Hetzner run: the repos side by side under /root/src,
# because one image (the console) legitimately spans five of them. The clone of
# `genaryx` is named `genaryx-a360` because the console's Dockerfile refers to
# it by that path.
OPEN_REPOS="wardryx idryx qryx mockryx heraldyx tokenfuse verdryx engram"
if [ "$SKIP_IMAGES" = 1 ]; then
  say "skipping the image build (--skip-images)"
else
  say "step 2/5: sources and images on $BUILDER"
  su_ "$BUILDER" 'sh -c "set -e
    export DEBIAN_FRONTEND=noninteractive
    command -v docker >/dev/null || { apt-get update -qq && apt-get install -y -qq docker.io git >/dev/null; }
    command -v git >/dev/null || apt-get install -y -qq git >/dev/null
    systemctl enable --now docker >/dev/null 2>&1 || true
    mkdir -p /root/src"'

  tar -cz -C "$ROOT" images manifests | su_ "$BUILDER" 'sh -c "mkdir -p /root/src/stack-k8s && tar -xz -C /root/src/stack-k8s"'

  for r in $OPEN_REPOS; do
    su_ "$BUILDER" "sh -c \"cd /root/src && if [ -d $r ]; then git -C $r pull -q --ff-only || true; else git clone -q --depth 1 https://github.com/TAIPANBOX/$r.git; fi\"" \
      && echo "   $r ok"
  done

  # The console is the one closed repo, so it is the one clone that needs a
  # credential. It is fetched HERE, on the operator's machine, and shipped to
  # the builder as source. The token never reaches the cluster.
  #
  # The obvious alternative, handing the token to the node and letting it clone,
  # is what ../../deploy.sh does and it is worse in a way that is easy to miss:
  # the token ends up in the node's process list, in its shell history, and in
  # .git/config, on a machine that is often in someone else's cloud account. A
  # token with access to every private repository an account owns should not be
  # somewhere its owner is not.
  #
  # --depth 1, and the remote is rewritten before the tarball is made, so the
  # credential is in no file that leaves this machine.
  WITH_CONSOLE=0
  if [ -n "$CONSOLE_TOKEN" ]; then
    say "fetching the console source here, so the token stays on this machine"
    TMP="$(mktemp -d)"
    if git -c credential.helper= clone -q --depth 1 \
         "https://x-access-token:$CONSOLE_TOKEN@github.com/TAIPANBOX/genaryx.git" \
         "$TMP/genaryx-a360" 2>/dev/null; then
      git -C "$TMP/genaryx-a360" remote set-url origin https://github.com/TAIPANBOX/genaryx.git
      BUILT_FROM="$(git -C "$TMP/genaryx-a360" rev-parse --short HEAD)"
      grep -rl 'x-access-token' "$TMP/genaryx-a360/.git" >/dev/null 2>&1 \
        && { rm -rf "$TMP"; die "the token is still in .git after rewriting the remote; refusing to ship it"; }
      echo "   console source at $BUILT_FROM, uploading to the builder"
      tar -cz -C "$TMP" genaryx-a360 | su_ "$BUILDER" 'tar -xz -C /root/src'
      rm -rf "$TMP"
      WITH_CONSOLE=1
      echo "   genaryx (console) staged, no credential on any node"
    else
      rm -rf "$TMP"
      echo "   could not clone the console with that token: continuing WITHOUT it"
    fi
  else
    echo "   no --console-token: deploying the open stack without the Genaryx console"
  fi

  say "building images (the console build is four languages and takes the longest)"
  su_ "$BUILDER" "sh -c \"set -e
    cd /root/src
    for pair in wardryx:wardryx idryx:idryx qryx:qryx mockryx:mockryx heraldyx:heraldyx; do
      name=\\\${pair%%:*}; repo=\\\${pair##*:}
      docker build -q -f stack-k8s/images/go-service.Dockerfile --build-arg SERVICE=\\\$name --build-arg SRC=./\\\$repo -t stack/\\\$name:dev . >/dev/null
      echo '   built stack/'\\\$name':dev'
    done
    docker build -q -f stack-k8s/images/tokenfuse.Dockerfile -t stack/tokenfuse:dev ./tokenfuse >/dev/null
    echo '   built stack/tokenfuse:dev'
    if [ '$WITH_CONSOLE' = '1' ]; then
      docker build -q -f stack-k8s/images/console.Dockerfile -t stack/genaryx-console:dev . >/dev/null
      echo '   built stack/genaryx-console:dev'
    fi\""

  # ---- distributing the images -------------------------------------------
  # The Hetzner script assumed node-to-node ssh already worked and printed a
  # caveat when it did not. Here it is arranged explicitly, because the
  # alternative is worse in a way that is easy to miss: pulling 1.5 GB of
  # images down to the operator's laptop and pushing them back up would leave
  # AWS and re-enter it, and egress from AWS is billed at about USD 0.09/GB.
  #
  # A throwaway keypair is generated ON the builder, its public half is added
  # to the other nodes by this script (which already has ssh to all of them),
  # the images move over the PRIVATE network, and the key is removed at the
  # end. It never touches the operator's own key, which stays on the operator's
  # machine where it belongs.
  say "distributing images over the private network"
  DIST_PUB="$(su_ "$BUILDER" 'sh -c "test -f /root/.ssh/stack-distribute || ssh-keygen -t ed25519 -N \"\" -q -f /root/.ssh/stack-distribute; cat /root/.ssh/stack-distribute.pub"')"
  [ -n "$DIST_PUB" ] || die "could not prepare the distribution key on the builder"

  PRIVS=""
  for n in "${ALL_NODES[@]}"; do
    [ "$n" = "$BUILDER" ] && continue
    p="$(su_ "$n" 'sh -c "T=\$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H \"X-aws-ec2-metadata-token-ttl-seconds: 60\" --max-time 5); curl -sf -H \"X-aws-ec2-metadata-token: \$T\" --max-time 5 http://169.254.169.254/latest/meta-data/local-ipv4"')"
    [ -n "$p" ] || die "could not read the private address of $n"
    PRIVS="$PRIVS $p"
    sh_ "$n" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qF '$DIST_PUB' ~/.ssh/authorized_keys 2>/dev/null || printf '%s\n' '$DIST_PUB' >> ~/.ssh/authorized_keys"
  done

  IMAGES="stack/wardryx:dev stack/idryx:dev stack/qryx:dev stack/mockryx:dev stack/heraldyx:dev stack/tokenfuse:dev"
  [ "$WITH_CONSOLE" = 1 ] && IMAGES="$IMAGES stack/genaryx-console:dev"
  su_ "$BUILDER" "sh -c \"for img in $IMAGES; do
      docker save \\\$img | k3s ctr images import - >/dev/null 2>&1 && echo '   '\\\$img' -> builder' || echo '   '\\\$img' -> builder FAILED'
      for p in $PRIVS; do
        docker save \\\$img | ssh -i /root/.ssh/stack-distribute -o BatchMode=yes -o StrictHostKeyChecking=no $SSH_USER@\\\$p 'sudo k3s ctr images import -' >/dev/null 2>&1 \
          && echo '   '\\\$img' -> '\\\$p || echo '   '\\\$img' -> '\\\$p' FAILED'
      done
    done\""

  say "removing the distribution key"
  for n in "${ALL_NODES[@]}"; do
    [ "$n" = "$BUILDER" ] && continue
    sh_ "$n" "grep -vF '$DIST_PUB' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new 2>/dev/null && mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys" || true
  done
  su_ "$BUILDER" "rm -f /root/.ssh/stack-distribute /root/.ssh/stack-distribute.pub"
  echo "   done, the nodes are back to the operator's key only"
fi

# ---- 3. the workload --------------------------------------------------------
say "step 3/5: the workload"
tar -cz -C "$ROOT" manifests | su_ "$FIRST" 'sh -c "mkdir -p /root/stack-k8s && tar -xz -C /root/stack-k8s"'
k_ "apply -k /root/stack-k8s/manifests"
say "waiting for rollouts"
for d in $(k_ "-n agent-stack get deploy -o name"); do
  k_ "-n agent-stack rollout status $d --timeout=300s" || true
done
k_ "-n agent-stack rollout status statefulset/policy-db --timeout=300s" || true

install_alerts

# ---- 4 and 5. proof, not vibes ---------------------------------------------
tar -cz -C "$ROOT" verify.sh security-tests.sh | su_ "$FIRST" 'tar -xz -C /root/stack-k8s'
say "step 4/5: is it running"
su_ "$FIRST" 'KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/verify.sh' || true
say "step 5/5: is it contained"
su_ "$FIRST" 'KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/security-tests.sh' || true

CONSOLE_NODE="$(k_ "-n agent-stack get pod -l app=genaryx-console -o jsonpath='{.items[0].spec.nodeName}'" 2>/dev/null || true)"
CONSOLE_IP="$(k_ "-n agent-stack get svc genaryx-console -o jsonpath='{.spec.clusterIP}'" 2>/dev/null || true)"

# ---- the operator account --------------------------------------------------
CONSOLE_USER="${CONSOLE_USER:-ops}"
CONSOLE_PASSWORD=""
if [ -n "$CONSOLE_NODE" ]; then
  if k_ "-n agent-stack exec -i deploy/genaryx-console -- test -s /var/lib/stack/.taipan/genaryx-web/operator.json" >/dev/null 2>&1; then
    say "operator account already exists, left as is"
  else
    # GOTCHAS.md item 25: the subshell disables pipefail deliberately. `tr
    # </dev/urandom | head -c N` under `set -o pipefail` kills the script here,
    # silently, with the cluster up and no operator account.
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

# k3s is told --node-ip <private> on purpose, so the Node object carries an
# InternalIP and often NO ExternalIP, and a tunnel command built from it points
# at an address the operator cannot reach. Map the console's node to the PUBLIC
# address this script was called with, through the metadata service.
CONSOLE_ADDR=""
if [ -n "$CONSOLE_NODE" ]; then
  CONSOLE_PRIV="$(k_ "get node $CONSOLE_NODE -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'" 2>/dev/null || true)"
  for n in "${ALL_NODES[@]}"; do
    p="$(su_ "$n" 'sh -c "T=\$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H \"X-aws-ec2-metadata-token-ttl-seconds: 60\" --max-time 5); curl -sf -H \"X-aws-ec2-metadata-token: \$T\" --max-time 5 http://169.254.169.254/latest/meta-data/local-ipv4"' 2>/dev/null || true)"
    [ -n "$p" ] && [ "$p" = "$CONSOLE_PRIV" ] && { CONSOLE_ADDR="$n"; break; }
  done
  [ -n "$CONSOLE_ADDR" ] || CONSOLE_ADDR="$CONSOLE_PRIV"
fi

cat <<EOF

$(printf '\033[1m')Done.$(printf '\033[0m')

${CONSOLE_PASSWORD:+  Your console sign-in, shown once and stored nowhere:

      user      $CONSOLE_USER
      password  $CONSOLE_PASSWORD

}  Reach the console over YOUR tunnel. There is no public entry point by
  design, and the tunnel has to land on the node running the console pod
  (GOTCHAS.md item 13)${CONSOLE_NODE:+, currently $CONSOLE_NODE}:

      ssh -i $SSH_KEY -L 17420:${CONSOLE_IP:-<console-clusterIP>}:7420 $SSH_USER@${CONSOLE_ADDR:-<the address of that node>}
      open http://localhost:17420

  Re-check any time:

      ssh -i $SSH_KEY $SSH_USER@$FIRST 'sudo KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/verify.sh --freeze'
      ssh -i $SSH_KEY $SSH_USER@$FIRST 'sudo KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/security-tests.sh'

  What it is costing right now:

      ./cost-live.sh

  $(printf '\033[1m')When finished: ./teardown.sh$(printf '\033[0m')
EOF
