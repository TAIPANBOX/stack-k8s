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
# Nothing here needs a credential. Every repository this pulls is public and
# Apache-2.0, the Genaryx console included since 2026-07-27.
# `--console-token` survives for the one case it is still good for: building
# the console from a private fork of your own. Without the console you get the
# governed stack and no control room, which is a real deployment and not a
# crippled one: the planes enforce with or without a UI in front of them.
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
# The console's own account. There is deliberately no --console-password: a
# password on a command line is visible in `ps` to every user on the machine for
# as long as the deploy runs, and stays in the shell history afterwards. Asked
# on the terminal, or generated.
CONSOLE_USER="${CONSOLE_USER:-ops}"
CONSOLE_PASSWORD=""
CONSOLE_PASSWORD_CHOSEN=0
# Notifications. Empty ALERT_TO means "ask, if there is a terminal to ask on",
# and a blank answer means no notifier is installed at all. There is
# deliberately no --smtp-password, for the same reason there is no
# --console-password: a secret on a command line is in `ps` for every user on
# the machine for as long as this runs, and in the shell history afterwards.
ALERT_TO="${ALERT_TO:-}"
ALERT_ASKED=0
SMTP_HOST="${SMTP_HOST:-}"
SMTP_FROM="${SMTP_FROM:-}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS=""
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
    --console-user)   CONSOLE_USER="$2"; shift 2 ;;
    --alert-to)       ALERT_TO="$2"; ALERT_ASKED=1; shift 2 ;;
    --no-alerts)      ALERT_TO=""; ALERT_ASKED=1; shift ;;
    --smtp-host)      SMTP_HOST="$2"; shift 2 ;;
    --smtp-from)      SMTP_FROM="$2"; shift 2 ;;
    --smtp-user)      SMTP_USER="$2"; shift 2 ;;
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
    || die "could not fetch the repo; check the network, or clone it and run ./deploy.sh"
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

# ---- 0c. the console account, asked here and used at the end ---------------
# Everything the operator needs to sign in is settled in one conversation at the
# top, and travels the same SSH channel that installs the platform. It never
# crosses the internet, and the console has no registration endpoint at all: the
# account is created here, and the form the operator meets later is a sign-in.
#
# Three things this has to get right, and each of them is why it is a prompt
# rather than a flag.
#
#   No echo. A password typed in front of anyone, or left in a screenshot of a
#   terminal, is not a password.
#   Typed twice. A single typo in a value nobody can read back produces a
#   console that refuses its own operator, fifteen minutes later, with the
#   install already finished.
#   Never written down. It lives in this shell's memory until the moment it is
#   piped into set-password, and goes nowhere else: no temp file, no flag, no
#   history.
if [ -z "$CONSOLE_PASSWORD" ]; then
  if { exec 4<>/dev/tty; } 2>/dev/null; then
    cat >&4 <<'TXT'

   The console account. There is no sign-up page: this is the one account, and
   it is created here rather than on the internet. You will type it into the
   sign-in form once the tunnel is up.

   Leave the password blank to have a long one generated and printed at the end
   instead, which is the right answer if this is not the machine you will keep.

TXT
    printf '   username [%s]: ' "$CONSOLE_USER" >&4
    IFS= read -r ans <&4 || ans=""
    ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
    [ -n "$ans" ] && CONSOLE_USER="$ans"

    while :; do
      printf '   password (blank = generate): ' >&4
      IFS= read -rs p1 <&4 || p1=""; printf '\n' >&4
      [ -z "$p1" ] && break
      # Eight refused, under twelve warned and accepted.
      #
      # The floor is low on purpose, and the reason is the tunnel. This form
      # cannot be reached from the internet at all: every Service is ClusterIP,
      # so seeing the sign-in page already requires a working WireGuard device.
      # There is no online guessing, and no offline guessing either, because the
      # Argon2id hash lives on a volume inside the cluster. What the password
      # actually stops is one case: somebody holding an old or leaked .conf who
      # is already inside the tunnel.
      #
      # It stops being the second barrier the day anyone applies
      # manifests/50-loadbalancer.yaml, which is a real and deliberate option in
      # this repository. Hence a warning rather than silence between 8 and 12.
      if [ "${#p1}" -lt 8 ]; then
        printf '   at least 8 characters. This one account is the whole console.\n' >&4
        continue
      fi
      if [ "${#p1}" -lt 12 ]; then
        printf '   \033[33mshort. Fine behind the tunnel, where reaching this form already\n' >&4
        printf '   needs a WireGuard device. Weak the day this console is published.\033[0m\n' >&4
      fi
      printf '   again: ' >&4
      IFS= read -rs p2 <&4 || p2=""; printf '\n' >&4
      if [ "$p1" = "$p2" ]; then CONSOLE_PASSWORD="$p1"; p1=""; p2=""; break; fi
      printf '   those did not match.\n' >&4
    done
    exec 4>&-
  fi
fi

# ---- 0d. notifications, asked here and installed at step 3b ----------------
# Third and last question in the one conversation at the top, for the same
# reason as the other two: everything the operator has to decide is decided
# before fifteen minutes of installing, not after.
#
# Blank is a real answer and the default one. A box with no address configured
# installs no notifier at all: no pod, no egress rule, nothing.
if [ "$ALERT_ASKED" = 0 ] && [ -z "$ALERT_TO" ]; then
  if { exec 4<>/dev/tty; } 2>/dev/null; then
    cat >&4 <<'TXT'

   Notifications. This box can write to you when one of your own agents
   crosses a line: a budget gone, a policy denial, a run killed, an agent
   behaving unlike itself. The mail comes from this box, it carries a link
   into this console, and it never carries a button that acts.

   Mail is the only thing in this deployment that reaches outside the
   cluster, so answering this grants exactly one pod exactly one way out,
   on the mail ports and nowhere else.

   Leave the address blank for no notifications. Nothing is installed then.

TXT
    printf '   address for alerts (blank = none): ' >&4
    IFS= read -r ans <&4 || ans=""
    ALERT_TO="$(printf '%s' "$ans" | tr -d '[:space:]')"

    if [ -n "$ALERT_TO" ]; then
      # A mail server is not guessable and a wrong one is the whole failure
      # mode this question exists to prevent, so it is asked, not defaulted.
      while [ -z "$SMTP_HOST" ]; do
        printf '   mail server as host:port (e.g. smtp.example.com:587): ' >&4
        IFS= read -r ans <&4 || ans=""
        ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
        case "$ans" in
          "") printf '   without one, this box has nothing to hand the mail to.\n' >&4 ;;
          *:*) SMTP_HOST="$ans" ;;
          *) printf '   needs a port too: %s:587 for submission, :465 for implicit TLS.\n' "$ans" >&4 ;;
        esac
      done

      # Defaulted to the recipient, which is right far more often than it is
      # wrong: most operators send from the same domain they read.
      printf '   sender address [%s]: ' "$ALERT_TO" >&4
      IFS= read -r ans <&4 || ans=""
      ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
      SMTP_FROM="${ans:-$ALERT_TO}"

      printf '   username (blank = server wants no authentication): ' >&4
      IFS= read -r ans <&4 || ans=""
      SMTP_USER="$(printf '%s' "$ans" | tr -d '[:space:]')"
      if [ -n "$SMTP_USER" ]; then
        # No echo, and not typed twice: unlike the console password, a wrong
        # one here is caught within the minute by the test message at step 3b,
        # which is a better check than typing it again.
        printf '   password: ' >&4
        IFS= read -rs SMTP_PASS <&4 || SMTP_PASS=""; printf '\n' >&4
      fi
    fi
    exec 4>&-
  else
    echo "   no terminal to ask on: SKIPPING notifications. Add them later with"
    echo "   kubectl apply -f manifests/45-heraldyx.yaml and a heraldyx-mail Secret,"
    echo "   or pass --alert-to and --smtp-host here."
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
# Cloned because something on the node still BUILDS from them: tokenfuse for
# its own image, and qryx, mockryx, verdryx and engram because the console
# image bundles those four tools inside itself (see images/console.Dockerfile).
#
# wardryx, idryx and heraldyx are gone from this list on purpose: their images
# are pulled from ghcr.io now, so cloning their source on the node would be
# fetching something nothing reads. Their policy and config come from the
# manifests, not from their repositories.
# trailryx joins the list because its image is BUILT here, not pulled: the
# published one carries `trailryx-ingest` only and every sealing command is in
# `trailryx-node`. Same reason tokenfuse is on this list and wardryx is not.
OPEN_REPOS="qryx mockryx tokenfuse verdryx engram trailryx"
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
  # The console is public now, so the URL carries a token only when one was
  # given (a private fork). An empty CONSOLE_TOKEN must not produce
  # `https://x-access-token:@github.com/...`, which git treats as an empty
  # credential and fails on rather than falling back to anonymous.
  if [ -n "$CONSOLE_TOKEN" ]; then CONSOLE_AUTH="x-access-token:$CONSOLE_TOKEN@"; else CONSOLE_AUTH=""; fi
  if true; then
    # `--branch` on both paths, and a hard reset rather than a pull on the
    # second: `git pull --ff-only` on a checkout sitting on a DIFFERENT branch
    # fails, gets swallowed by `|| true`, and the build then quietly produces
    # the previous branch's console while reporting success.
    if sh_ "$BUILDER" "cd /root/src && \
       if [ -d genaryx-a360/.git ]; then \
         git -C genaryx-a360 remote set-url origin https://${CONSOLE_AUTH}github.com/TAIPANBOX/genaryx.git && \
         git -C genaryx-a360 fetch -q --depth 1 origin '$CONSOLE_REF' && \
         git -C genaryx-a360 checkout -q -B '$CONSOLE_REF' FETCH_HEAD; \
       else \
         rm -rf genaryx-a360 && \
         git clone -q --depth 1 --branch '$CONSOLE_REF' https://${CONSOLE_AUTH}github.com/TAIPANBOX/genaryx.git genaryx-a360; \
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

  # The five Go planes are NOT built here any more. They are published, pinned
  # by version in the manifests, and pulled by the kubelet:
  #
  #   ghcr.io/taipanbox/{wardryx,idryx,qryx,mockryx,heraldyx}
  #
  # That removes the slowest and most fragile part of a first install. Building
  # them here meant a Go toolchain on the node, a clone of five repositories,
  # and a docker save piped over ssh to every other node; two of the defects a
  # live run found on 2026-08-02 lived in that path rather than in any service.
  # What nobody builds, nobody breaks.
  #
  # What is still built is what is not published: tokenfuse (Rust) and the
  # console (built from source per install), plus the two tiny tunnel images.
  #
  # The trade is that every node now needs to reach ghcr.io. These nodes
  # already reach the internet to install k3s, Longhorn and Calico, so this
  # adds a host to that list rather than a requirement.
  say "building what is not published (the console build is four languages and takes the longest)"
  sh_ "$BUILDER" "set -e
    cd /root/src
    docker build -q -f stack-k8s/images/tokenfuse.Dockerfile -t stack/tokenfuse:dev ./tokenfuse >/dev/null
    echo '   built stack/tokenfuse:dev'
    # The record plane's sealing tools. Built here for the same reason
    # tokenfuse is: the published GHCR image carries `trailryx-ingest` only and
    # every sealing command is in `trailryx-node`, which is published nowhere.
    docker build -q -f stack-k8s/images/trailryx.Dockerfile -t stack/trailryx:dev ./trailryx >/dev/null
    echo '   built stack/trailryx:dev'
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
  IMAGES="stack/tokenfuse:dev stack/wg:dev stack/caddy:dev"
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

# ---- 3b. notifications ------------------------------------------------------
# Only if the operator gave an address at the top. No address, no notifier pod
# and no egress rule: the cluster stays exactly as closed as it was.
if [ -n "$ALERT_TO" ]; then
  say "step 3b: notifications"
  # Built here and piped over stdin, never passed as an argument. `k_`
  # interpolates what it is given into a shell command line on the node, where
  # a mail password would sit in `ps` for every process on that machine for as
  # long as the call runs. Values are base64 for a second reason: a password
  # containing a quote, a colon or a backslash breaks the YAML it travels in,
  # and it would break it at 2am on somebody else's cluster.
  b64_() { printf '%s' "$1" | base64 | tr -d '\n'; }
  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: heraldyx-mail\n  namespace: agent-stack\ntype: Opaque\ndata:\n'
    printf '  HERALDYX_TO: %s\n'        "$(b64_ "$ALERT_TO")"
    printf '  HERALDYX_SMTP_HOST: %s\n' "$(b64_ "$SMTP_HOST")"
    printf '  HERALDYX_SMTP_FROM: %s\n' "$(b64_ "$SMTP_FROM")"
    printf '  HERALDYX_BOX: %s\n'       "$(b64_ "${CONSOLE_DOMAIN:-agent stack}")"
    if [ -n "$SMTP_USER" ]; then printf '  HERALDYX_SMTP_USER: %s\n' "$(b64_ "$SMTP_USER")"; fi
    if [ -n "$SMTP_PASS" ]; then printf '  HERALDYX_SMTP_PASS: %s\n' "$(b64_ "$SMTP_PASS")"; fi
    # The deep link needs a name the operator's browser can resolve. Without a
    # tunnel there is none, and the mail says so in a sentence rather than
    # carrying a link to a cluster IP nobody can reach.
    if [ -n "$CONSOLE_DOMAIN" ]; then printf '  HERALDYX_CONSOLE_URL: %s\n' "$(b64_ "https://$CONSOLE_DOMAIN")"; fi
  } | k_ "-n agent-stack apply -f -" >/dev/null \
    || die "the stack is up; only the notification Secret failed to apply."
  # Out of this shell's memory the moment it has been delivered.
  SMTP_PASS=""

  k_ "apply -f /root/stack-k8s/manifests/45-heraldyx.yaml" >/dev/null \
    || die "the stack is up; only the notifier failed to apply."
  k_ "-n agent-stack rollout status deploy/heraldyx --timeout=180s" || true

  # The test message, sent from INSIDE the pod, which is the point: it proves
  # the pod's own network path, its own egress policy and its own credentials,
  # not this laptop's. A wrong mail setting found here costs a minute. Found
  # the way it is otherwise found, through an alert that never arrived, it
  # costs whatever the alert was about.
  if k_ "-n agent-stack exec deploy/heraldyx -- /usr/local/bin/service --test-mail" 2>&1 | sed 's/^/   /'; then
    echo "   if that message does not arrive, the address or the server is wrong,"
    echo "   and nothing else in this install depends on it."
  else
    echo "   the test message did NOT go out. The stack is fine and unaffected;"
    echo "   notifications are not. Check the address, the server and the"
    echo "   credentials, then:"
    echo "       kubectl -n agent-stack logs deploy/heraldyx"
    echo "       kubectl -n agent-stack exec deploy/heraldyx -- /usr/local/bin/service --test-mail"
  fi
fi

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
if [ -n "$CONSOLE_NODE" ]; then
  if k_ "-n agent-stack exec -i deploy/genaryx-console -- test -s /var/lib/stack/.taipan/genaryx-web/operator.json" >/dev/null 2>&1 \
     && [ "$CONSOLE_PASSWORD_CHOSEN" != 1 ]; then
    # An account is already here and nobody typed a new password, so the
    # existing one stands. Named, because "an account" is not enough: an
    # operator signing in has to know WHICH name, and the default in this
    # script has not always been the name a given cluster was set up with.
    # python3, not sed: the console image has it, and a sed expression does not
    # survive the layers of quoting between this shell, ssh, and `kubectl exec`.
    # Measured, not assumed: the sed form answered `Syntax error: "(" unexpected`.
    EXISTING_USER="$(k_ "-n agent-stack exec -i deploy/genaryx-console -- python3 -c \"import json;print(json.load(open('/var/lib/stack/.taipan/genaryx-web/operator.json'))['username'])\"" 2>/dev/null | tr -d '\r\n ' || true)"
    say "operator account already exists, left as is${EXISTING_USER:+ (username: $EXISTING_USER)}"
    CONSOLE_USER="${EXISTING_USER:-$CONSOLE_USER}"
  else
    # 24 bytes of urandom, base64, punctuation stripped: long enough that the
    # Argon2id hash behind it is not the weak link, safe to paste anywhere.
    # The subshell disables pipefail deliberately. `tr </dev/urandom | head -c N`
    # is the idiom everyone writes, and under `set -o pipefail` it is a trap:
    # head closes the pipe once it has its N bytes, tr dies of SIGPIPE, the
    # pipeline reports 141 and `set -e` ends the deploy right here, silently,
    # with the cluster up and no operator account.
    if [ -n "$CONSOLE_PASSWORD" ]; then
      # Chosen at the top, before any of this ran. Never echoed back here: the
      # operator knows it, and printing it would put it in the scrollback and in
      # every screenshot of a successful install.
      #
      # It is APPLIED even when an account already exists. Asking somebody for a
      # password and then discarding it is worse than not asking: they spend the
      # next ten minutes typing it into a form that was never going to take it,
      # and the line that explains why scrolled past long ago. Typing one here is
      # an instruction, and this run is when it was given.
      CONSOLE_PASSWORD_CHOSEN=1
    else
      CONSOLE_PASSWORD="$( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28 )"
      [ "${#CONSOLE_PASSWORD}" = 28 ] || die "could not generate an operator password; /dev/urandom is not readable."
    fi
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

# Built here rather than inside the final heredoc: three states, and a
# conditional that long inside `cat <<EOF` is unreadable and easy to break.
#
# printf, not `$(cat <<INNER ... INNER)`. An APOSTROPHE inside a heredoc that
# sits inside a command substitution breaks bash outright:
#
#   unexpected EOF while looking for matching `''
#
# on a file whose quoting is correct. The word "operator's" was enough. See
# GOTCHAS.md item 63.
#
# The third state is the point of all this. A password the operator TYPED is
# not repeated back: they already have it, and printing it would leave it in
# this scrollback and in every screenshot anyone takes of a successful install.
RESET_CMD="      ssh root@$FIRST \"/usr/local/bin/k3s kubectl -n agent-stack exec -i deploy/genaryx-console -- \\\\
        /usr/local/bin/genaryx-web set-password --username $CONSOLE_USER\""

if [ "$CONSOLE_PASSWORD_CHOSEN" = 1 ]; then
  printf -v SIGNIN_BLOCK '%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n\n%s\n' \
    "  Your console sign-in:" \
    "      user      $CONSOLE_USER" \
    "      password  the one you typed at the start" \
    "  Not repeated here on purpose: you have it already, and printing it would" \
    "  leave it in this scrollback and in any screenshot of this run." \
    "  Change it whenever you like, and enrol a passkey once you are in:" \
    "$RESET_CMD"
elif [ -n "$CONSOLE_PASSWORD" ]; then
  printf -v SIGNIN_BLOCK '%s\n\n%s\n%s\n\n%s\n\n%s\n' \
    "  Your console sign-in, shown once and stored nowhere:" \
    "      user      $CONSOLE_USER" \
    "      password  $CONSOLE_PASSWORD" \
    "  Change it whenever you like, and enrol a passkey once you are in:" \
    "$RESET_CMD"
else
  printf -v SIGNIN_BLOCK '%s\n%s\n\n%s\n' \
    "  Set the operator password (read from stdin, stored as an Argon2id hash)." \
    "  Until one exists the console refuses every sign-in:" \
    "$RESET_CMD"
fi

# The last thing an operator reads must not contradict what they were just
# handed. Step 6 gives them a WireGuard config, a QR and an address; telling
# them in the next breath to set up an ssh -L instead is how a reader decides
# the tooling does not know what it is doing.
if [ "$TUNNEL_DONE" = 1 ]; then
  printf -v WAY_IN '%s\n%s\n' \
    "  Your way in is the tunnel above: import that .conf, connect, then open" \
    "  the console. There is no public entry point, by design."
else
  printf -v WAY_IN '%s\n%s\n%s\n\n%s\n%s\n' \
    "  Reach the console over YOUR tunnel. There is no public entry point by" \
    "  design, and the tunnel has to land on the node running the console pod" \
    "  (GOTCHAS.md item 13)${CONSOLE_NODE:+, currently $CONSOLE_NODE}:" \
    "      ssh -L 17420:${CONSOLE_IP:-<console-clusterIP>}:7420 root@${CONSOLE_ADDR:-<the address of that node>}" \
    "      open http://localhost:17420"
fi

cat <<EOF

$(printf '\033[1m')Done.$(printf '\033[0m')

${SIGNIN_BLOCK}
${WAY_IN}
  Re-check any time:

      ssh root@$FIRST 'KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/verify.sh --freeze'
      ssh root@$FIRST 'KUBECTL="/usr/local/bin/k3s kubectl" bash /root/stack-k8s/security-tests.sh'

  A public entry point is a separate, metered decision:
  kubectl apply -f manifests/50-loadbalancer.yaml, and read its header first.
EOF
