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
#
# `--trust-domain <domain>` sets the record plane's trust domain after the
# manifests are applied, which is the only place it survives.
#
# `--with-finops` additionally builds and applies CostCrew, the finops plane:
# the bill, worked by a crew of agents. It is off by default because it is a
# whole plane somebody may not want, not because it is dangerous. The half of
# it that CAN spend on a model account ships suspended, so this flag applies a
# console and starts no meter; see manifests/49-costcrew.yaml for how to run
# the crew deliberately afterwards.
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
# Where the operator opens their own console. The link in the mail goes here
# and nowhere else, and the default is what this script's own closing screen
# tells them to run.
ALERT_CONSOLE_DEFAULT="http://localhost:17420"
ALERT_CONSOLE_URL="${ALERT_CONSOLE_URL:-}"
# The finops plane, off by default. It is a whole plane somebody may simply not
# want, and the half of it that can spend money ships suspended, so the flag
# carries the plane and never the spending. See manifests/49-costcrew.yaml.
WITH_FINOPS="${WITH_FINOPS:-0}"
# The record plane's trust domain. Empty leaves 00-base.yaml's `set-me.invalid`
# in place, which is the loud state and the right default; see where it is used.
TRUST_DOMAIN="${TRUST_DOMAIN:-}"
# Build tokenfuse, trailryx and costcrew on a node instead of pulling them.
#
# Off, since 2026-09-01, because all three are published and pinned in the
# manifests. It exists for the two cases a registry does not serve, which are
# the same two BUILD_PLANES names in ../../build.sh: testing a change that is
# not released yet, and a cluster whose nodes cannot reach ghcr.io. It builds
# them at :dev, which the manifests no longer reference, so using it also
# means editing an image line or patching the deployment.
BUILD_FROM_SOURCE="${BUILD_FROM_SOURCE:-0}"
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
    --console-url)   ALERT_CONSOLE_URL="$2"; shift 2 ;;
    --with-finops)   WITH_FINOPS=1; shift ;;
    --trust-domain)  TRUST_DOMAIN="$2"; shift 2 ;;
    --skip-install)  SKIP_INSTALL=1; shift ;;
    --skip-images)   SKIP_IMAGES=1; shift ;;
    # The header block, found rather than counted.
    #
    # It was a hardcoded line range twice, and drifted twice: first past
    # --copilot-key-file, then past --trust-domain, each time leaving a
    # real flag documented in a comment nobody prints. A range that has to
    # be updated whenever the header grows is a range that will not be.
    -h|--help)
      end=$(grep -n '^set -euo pipefail' "$0" | head -1 | cut -d: -f1)
      sed -n "2,$((end - 1))p" "$0" | sed -E 's/^# ?//'; exit 0 ;;
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
  printf '   address for alerts, several separated by commas (blank = none): ' >&4
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
    cat >&4 <<'TXT'

   Last one. Where do YOU open this console? The mail carries a link there
   and nowhere else, so the answer has to be the entry point you actually
   use: this cluster has none that is public, by design.

   That privacy is the point rather than a limitation. A link that only
   resolves once you are on your own tunnel is worth nothing to anyone else
   who reads, forwards or intercepts the message.

   This install hands you an SSH tunnel that lands the console on
   http://localhost:17420. If you reach the cluster over WireGuard or your
   own VPN instead, give that address.

TXT
    printf '   console address [%s]: ' "${ALERT_CONSOLE_URL:-$ALERT_CONSOLE_DEFAULT}" >&4
    IFS= read -r ans <&4 || ans=""
    ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
    ALERT_CONSOLE_URL="${ans:-${ALERT_CONSOLE_URL:-$ALERT_CONSOLE_DEFAULT}}"
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
    # The operator's own entry point, asked for rather than guessed. This used
    # to be omitted on the cloud paths, on the reasoning that a cluster with no
    # tunnel plane has no name a browser could resolve. It was wrong twice: the
    # install hands out an SSH tunnel two screens further down, and an operator
    # on WireGuard or a corporate VPN has a name we could never have derived.
    # An alert with no coordinate is the feature missing its point.
    if [ -n "$ALERT_CONSOLE_URL" ]; then printf '  HERALDYX_CONSOLE_URL: %s\n' "$(b64_ "$ALERT_CONSOLE_URL")"; fi
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
# Cloned because something on the node still BUILDS from them: tokenfuse for
# its own image, and qryx, mockryx, verdryx and engram because the console
# image bundles those four tools inside itself (see images/console.Dockerfile).
#
# wardryx, idryx and heraldyx are gone from this list on purpose: their images
# are pulled from ghcr.io now, so cloning their source on the node would be
# fetching something nothing reads. Their policy and config come from the
# manifests, not from their repositories.
# trailryx is on this list from 2026-09-01. 40-routines-and-secrets.yaml applies
# the record-seal CronJob on every cloud and that CronJob runs
# `stack/trailryx:dev`, which nothing here ever built, so the record plane could
# never seal anything here. See the fuller account in ../gcp/deploy-gcp.sh, where
# it was measured on a live cluster.
#
# costcrew joins the list only with --with-finops, for the same reason its
# manifest is not in the kustomization: a deployment that clones and builds a
# plane nobody applied is paying for it in build minutes and node disk to leave
# it sitting there.
# What is left here is what the CONSOLE image bundles inside itself, and
# nothing else: qryx, mockryx, verdryx and engram are four tools the console
# spawns rather than four pods, so they have to be in its image and its image
# is built here.
#
# tokenfuse, trailryx and costcrew left this list on 2026-09-01, when the
# manifests started pulling them from ghcr.io by pinned tag. Cloning source
# nothing builds is fetching something nothing reads.
OPEN_REPOS="qryx mockryx verdryx engram"
[ "$BUILD_FROM_SOURCE" = 1 ] && OPEN_REPOS="$OPEN_REPOS tokenfuse trailryx"
[ "$BUILD_FROM_SOURCE" = 1 ] && [ "$WITH_FINOPS" = 1 ] && OPEN_REPOS="$OPEN_REPOS costcrew"
# Nothing is built here any more, and this whole step is the one that took the
# time. Every image the manifests name is published and pinned, so the kubelet
# pulls them and this machine does not clone, build, save, stream or import
# anything at all.
#
# Measured on a live GCP cluster 2026-09-01: with only the console still built
# here, a deploy took 17m16s and almost all of it was that build. What is left
# once it is pulled too is k3s, the manifests and the two test suites.
#
# BUILD_FROM_SOURCE=1 brings the whole step back, for the two cases a registry
# does not serve: a change that is not released yet, and a cluster whose nodes
# cannot reach ghcr.io. It builds at :dev, which the manifests no longer name,
# so using it also means editing an image line or patching the deployment.
if [ "$SKIP_IMAGES" = 1 ] || [ "$BUILD_FROM_SOURCE" != 1 ]; then
  if [ "$SKIP_IMAGES" = 1 ]; then
    say "skipping the image build (--skip-images)"
  else
    say "step 2/5: nothing to build, every image is published and pinned"
    echo "   set BUILD_FROM_SOURCE=1 to build on a node instead"
  fi
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
  # The console has been public and Apache-2.0 since 2026-07-27, and the root
  # deploy.sh was taught that the same day. The cloud scripts were not, so every
  # deployment since built the stack WITHOUT a console while still applying
  # 20-console.yaml, leaving a pod in ImagePullBackOff and verify.sh reporting a
  # failure nobody could explain. Measured on live clusters 2026-08-02, on both
  # clouds: AWS was fixed first and GCP kept the fault for another hour, which
  # is the same "one path learned, the other did not" that put this whole
  # section here in the first place.
  #
  # So the clone is unconditional now. CONSOLE_TOKEN survives for the one case
  # it is still good for: building from a private fork of your own.
  if [ -n "$CONSOLE_TOKEN" ]; then
    CONSOLE_AUTH="x-access-token:$CONSOLE_TOKEN@"
  else
    CONSOLE_AUTH=""
  fi
  say "fetching the console source here, so any token stays on this machine"
  TMP="$(mktemp -d)"
  if git -c credential.helper= clone -q --depth 1 \
       "https://${CONSOLE_AUTH}github.com/TAIPANBOX/genaryx.git" \
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
    echo "   could not clone the console: continuing WITHOUT it, and 20-console.yaml"
    echo "   will not be applied, so nothing waits on an image that is not coming"
  fi

  # The five Go planes are NOT built here any more: they are published, pinned
  # by version in the manifests, and pulled by the kubelet from
  # ghcr.io/taipanbox/{wardryx,idryx,qryx,mockryx,heraldyx}. That removes the
  # slowest and most fragile part of a first install, and two of the defects a
  # live run found on 2026-08-02 lived in that build path rather than in any
  # service. What nobody builds, nobody breaks.
  #
  # Still built here because it is not published: tokenfuse (Rust) and the
  # console (built from source per install).
  #
  # The trade is that every node needs to reach ghcr.io. These nodes already
  # reach the internet for k3s, Longhorn and Calico, so this adds a host to
  # that list rather than a requirement.
  say "building what is not published (the console build is four languages and takes the longest)"
  su_ "$BUILDER" "sh -c \"set -e
    cd /root/src
    if [ '$BUILD_FROM_SOURCE' = '1' ]; then
      docker build -q -f stack-k8s/images/tokenfuse.Dockerfile -t stack/tokenfuse:dev ./tokenfuse >/dev/null
      echo '   built stack/tokenfuse:dev'
      docker build -q -f stack-k8s/images/trailryx.Dockerfile -t stack/trailryx:dev ./trailryx >/dev/null
      echo '   built stack/trailryx:dev'
    fi
    if [ '$WITH_CONSOLE' = '1' ]; then
      docker build -q -f stack-k8s/images/console.Dockerfile -t stack/genaryx-console:dev . >/dev/null
      echo '   built stack/genaryx-console:dev'
    fi
    if [ '$WITH_FINOPS' = '1' ] && [ '$BUILD_FROM_SOURCE' = '1' ]; then
      docker build -q -f costcrew/Dockerfile -t stack/costcrew:dev ./costcrew >/dev/null
      echo '   built stack/costcrew:dev'
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

  # Only what was actually built here goes over the private network. The
  # pulled ones are the kubelet's business and never touch this path, which
  # is the whole saving: this used to distribute every image on every
  # install, and the console is now the only one left.
  IMAGES=""
  [ "$BUILD_FROM_SOURCE" = 1 ] && IMAGES="stack/tokenfuse:dev stack/trailryx:dev"
  [ "$WITH_CONSOLE" = 1 ] && IMAGES="$IMAGES stack/genaryx-console:dev"
  [ "$BUILD_FROM_SOURCE" = 1 ] && [ "$WITH_FINOPS" = 1 ] && IMAGES="$IMAGES stack/costcrew:dev"
  su_ "$BUILDER" "sh -c \"for img in $IMAGES; do
      docker save \\\$img | k3s ctr images import - >/dev/null 2>&1 && echo '   '\\\$img' -> builder' || echo '   '\\\$img' -> builder FAILED'
      for p in $PRIVS; do
        docker save \\\$img | ssh -i /root/.ssh/stack-distribute -o BatchMode=yes -o StrictHostKeyChecking=no $SSH_USER@\\\$p 'sudo k3s ctr images import -' >/dev/null 2>&1 \
          && echo '   '\\\$img' -> '\\\$p || echo '   '\\\$img' -> '\\\$p' FAILED'
      done
    done\""

  # Rewritten THROUGH the file rather than over it, and never with nothing.
  #
  # `> new && mv new authorized_keys` replaces the inode, so the operator's key
  # file comes back with whatever mode and owner the shell's umask handed the
  # temporary. sshd is strict about that file by design and answers a bad mode
  # with `Permission denied (publickey)`: a completed handshake, a rejected key,
  # and no hint that the file it just refused is one this script wrote.
  #
  # On 2026-08-27 the operator lost ssh to exactly the nodes this loop touches,
  # and kept it on the builder, which the loop skips. The cluster stayed green
  # throughout, so nothing alerted; the deploy failed four steps later on a
  # connection it had broken itself. A reboot restored access, which fits: the
  # GCE guest agent rebuilds this file from instance metadata at boot.
  # See cloud/gcp/evidence/range-2026-08-27/FINDINGS.md, F1.
  #
  # `cat tmp > ak` keeps the original file, its mode and its owner. The `-s`
  # test is the other half and matters more: if the filter ever produced an
  # empty result, writing it would remove the operator's own key and lock
  # everyone out of a running cluster permanently. Doing nothing is always the
  # better failure here.
  say "removing the distribution key"
  for n in "${ALL_NODES[@]}"; do
    [ "$n" = "$BUILDER" ] && continue
    sh_ "$n" "grep -vF '$DIST_PUB' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new 2>/dev/null; if [ -s ~/.ssh/authorized_keys.new ]; then cat ~/.ssh/authorized_keys.new > ~/.ssh/authorized_keys; fi; rm -f ~/.ssh/authorized_keys.new" || true
  done

  # And then prove it, because the failure above was silent for four steps.
  # This is the cheapest possible check and it is the one that was missing.
  for n in "${ALL_NODES[@]}"; do
    sh_ "$n" true >/dev/null 2>&1 || die "the operator can no longer ssh to $n, and this step is what touched its keys.
   A reboot of that node restores access (the guest agent rebuilds
   authorized_keys from instance metadata), and the deploy can be re-run:
   every step here is idempotent. See FINDINGS.md F1 for the measured case."
  done
  su_ "$BUILDER" "rm -f /root/.ssh/stack-distribute /root/.ssh/stack-distribute.pub"
  echo "   done, the nodes are back to the operator's key only"
fi

# ---- 3. the workload --------------------------------------------------------
say "step 3/5: the workload"
tar -cz -C "$ROOT" manifests | su_ "$FIRST" 'sh -c "mkdir -p /root/stack-k8s && tar -xz -C /root/stack-k8s"'
k_ "apply -k /root/stack-k8s/manifests"

# The trust domain, set AFTER the kustomization and not before, which is the
# whole point of it being here. 00-base.yaml ships `set-me.invalid` because
# there is no defensible default, an operator patches it, and the next run of
# this script puts the placeholder back: `apply` reverts the keys the manifest
# DECLARES and leaves the ones an operator ADDED. See ../gcp/deploy-gcp.sh,
# where it was measured three times in one session.
if [ -n "$TRUST_DOMAIN" ]; then
  say "trust domain: $TRUST_DOMAIN (set after apply, which is what makes it stick)"
  k_ "-n agent-stack patch cm stack-wiring --type merge -p '{\"data\":{\"TRAILRYX_TRUST_DOMAIN\":\"$TRUST_DOMAIN\"}}'" >/dev/null \
    || die "could not set the trust domain on stack-wiring"
fi

# The finops plane, applied from its own file for the same reason heraldyx and
# scopyx are: it is not in the kustomization, so it arrives only when somebody
# asked for it. Its crew CronJob ships suspended, so this applies a plane and
# starts no spending.
if [ "$WITH_FINOPS" = 1 ]; then
  say "finops: applying the CostCrew plane (its crew stays suspended)"
  k_ "apply -f /root/stack-k8s/manifests/49-costcrew.yaml"
fi

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
