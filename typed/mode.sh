#!/usr/bin/env bash
# The typed-answer data mode: validate the operator's choice and render what it
# deploys. The ONE copy of this logic: deploy.sh, cloud/gcp/deploy-gcp.sh and
# cloud/aws/deploy-aws.sh only parse flags and hand them here, because a block
# copied into three launchers drifts (GOTCHAS 90, 101, 102; CLAUDE.md
# invariants 14, 17, 18). Invariant 26 holds it, scripts/typed-mode-is-honest.sh.
#
#   typed/mode.sh <verb> [flags]
#
#   verbs    check        validate the flags; print nothing on stdout; say on
#                         stderr what leaves the cluster in the chosen mode.
#                         The launchers run this BEFORE they install anything,
#                         so a missing key file costs seconds, not a build.
#            render       the manifests to apply, on stdout
#            secrets      the Secret(s) to apply, on stdout, for piping into
#                         `kubectl apply -f -` ONLY. Refuses a terminal.
#            has-secrets  yes or no
#            mode         the effective mode: off, stub, jev or own-model
#            door-secrets the door's two Secrets that do not exist yet, on stdout,
#                         for piping into `kubectl create -f -` ONLY. Refuses a
#                         terminal. Needs --have; reads typryx-keys' TYPRYX_KEYS,
#                         base64 as `kubectl get -o jsonpath` prints it, on stdin
#                         when --have names it. See THE DOOR below.
#
#   flags    --with-typed                 alone: the stub backend, exactly as
#                                         before this file existed
#            --typed-mode jev|own-model|off   default off
#            --typed-jev-key-file PATH    jev only; required
#            --typed-model-url URL        own-model only; required; ends in /v1
#            --typed-model-name NAME      own-model only; required
#            --typed-model-key-file PATH  own-model only; optional
#            --typed-model-cidr CIDR      own-model only; optional; the network
#                                         the egress rule admits, for a model
#                                         named by a host name on your own LAN
#            --typed-training             opt in to typryx's local training log
#                                         (TYPRYX_TRAINING_DIR); off by default;
#                                         needs typryx deployed (any mode but off)
#            --typed-risk-signal          opt in to the typed risk signal: typryx's
#                                         `wardryx-proxy` between the MCP broker and
#                                         wardryx; off by default; needs typryx
#                                         deployed (any mode but off)
#            --have "NAMES"               door-secrets only: which of the two door
#                                         Secrets exist, as `kubectl get secret
#                                         typryx-keys tokenfuse-mcp-broker-keys
#                                         --ignore-not-found -o name` prints them;
#                                         empty when neither does
#            --trust-domain DOMAIN        door-secrets only; the domain of the
#                                         identity a minted typryx key carries
#                                         (default set-me.invalid, the manifests'
#                                         own placeholder)
#
# `@decided 2026-09-30`: a customer chooses where the data of a typed answer
# goes, from three modes, and the launchers ask.
#
#   off        nothing is deployed for typryx. It does not remove a typryx an
#              earlier run installed; delete that yourself.
#   stub       (--with-typed alone) the free deterministic backend, no outbound
#              call. manifests/51 and 52 are emitted byte for byte.
#   jev        TYPRYX_BACKEND=jev. The named fields of every question leave the
#              cluster for TypeSafe's hosted API. The key is a Kubernetes
#              Secret made from the file, mounted as a file; TYPRYX_JEV_KEY_FILE
#              points at it. Never an environment value, never a ConfigMap,
#              never printed, never in a rendered manifest.
#   own-model  TYPRYX_BACKEND=openai-logprobs against an OpenAI-compatible
#              server the customer runs (Ollama, vLLM, ...). Nothing leaves the
#              cluster or the customer's network, unless the URL names a hosted
#              service, which is then the customer's own choice.
#
# WHY THE MODES ARE RENDERED, NOT PATCHED. `kubectl patch` never touches the
# last-applied annotation `apply` reads, so a later `apply -f 51-typryx.yaml`
# (stub) would see no difference and leave the patched backend in place, the
# trap delegation/up.sh documents (invariant 24). Every run applies the WHOLE
# document, so moving between modes is an ordinary apply.
#
# WHY THERE IS AN EGRESS POLICY. 30-network-policy.yaml is default-deny, and
# the gateway is the only pod with a way out. typryx on jev or own-model must
# reach its backend, so those modes add `typryx-egress-model`: one peer, one
# port. Switching back to the stub leaves that policy behind, harmlessly, since
# the stub makes no outbound call; delete it if you want the door shut again:
#   kubectl -n agent-stack delete networkpolicy typryx-egress-model
#
# THE DOOR. Two Secrets, read in every mode and neither optional: `typryx-keys`
# (TYPRYX_KEYS, `bearer=agent://identity`, manifests/51) and
# `tokenfuse-mcp-broker-keys` (manifests/52): TOKENFUSE_MCP_KEYS, the broker's own
# door (`secret:broker-caller`, the key id bare, invariant 33), and
# TOKENFUSE_MCP_SECRETS, `typryx_key=<typryx's bearer>`, the vault the broker fills
# a `{{secret:typryx_key}}` handle from. `@decided 2026-10-14`: the deploy scripts
# mint both when absent and never overwrite one, as stack-single's installer
# already does. `door-secrets` is the one copy of the decision, and the launchers
# call it in their typed branch before the render (CLAUDE.md invariant 42,
# scripts/typed-door-is-minted.sh):
#
#   both exist       both kept, nothing printed: a Secret made first, by hand or by
#                    an earlier run, wins
#   neither exists   both minted, two fresh 40-character bearers from lib/gen.sh,
#                    the broker's vault carrying typryx's
#   only typryx's    the broker's minted, its vault carrying the bearer read from
#                    the existing typryx-keys (on stdin, never printed)
#   only the broker's  a stop: a fresh typryx key would not be the one the broker's
#                    vault already holds, and every call through it would be refused
#
# The documents go to `kubectl create -f -` on stdin: `create` refuses an existing
# Secret where `apply` would replace it, and `apply` would also keep a second copy
# of every value in its last-applied annotation. On stderr this says what it kept
# and minted and how to read a value back, never a value.
#
# THE TRAINING LOG. `@decided 2026-09-30`: typryx keeps an opt-in local log of
# the questions it answered, so a customer can fine-tune and calibrate a model of
# their own on their own data; we do not train or ship models. --typed-training
# sets TYPRYX_TRAINING_DIR (typryx v0.3.0 or later) and changes nothing else: one
# environment variable and its comment, in any mode. Without the flag no mode
# renders it, and the render is byte for byte what it was before the flag existed.
#
# WHERE IT LIVES, AND WHY THERE IS NO NEW DISK. A PersistentVolumeClaim
# provisions a real disk that is billed from creation (00-base.yaml, GOTCHAS 81),
# so a flag must not add one: that is the operator's spending decision. The
# directory is a subdirectory of the claim typryx ALREADY has, `typryx-state`,
# which holds its ledger at /var/lib/typryx/ledger. That is also the only place
# it is useful: a log is paired with the human truths recorded on the ledger
# (`typryx export --training`), so a log on storage that dies with the pod, next
# to a ledger that survives it, would be a log with nothing to pair with. It is
# NOT put on stack-events, the shared bus other planes read: it holds question
# text. It lives as long as that claim does. scripts/typed-mode-is-honest.sh
# holds all of this.
#
# THE RISK SIGNAL. `@decided 2026-10-04` (estate audit, wave 1, J2): a typed risk
# signal may turn a call into a hold for a person and never into a deny, and its
# first consumer is wardryx (v1.2.0, rule `hold_if_signal`). --typed-risk-signal
# renders three things and changes the LLM path in none of them:
#
#   1. manifests/56-typryx-wardryx-proxy.yaml, typryx's `wardryx-proxy` (typryx
#      v0.4.0) as its own Deployment, given the SAME backend the mode chose for
#      typryx (the same three lines rewritten, the same key Secret mounted) and
#      no state of its own, with the NetworkPolicy edges broker -> proxy -> wardryx;
#   2. the broker (manifests/52), which asks wardryx itself on every cluster since
#      2026-10-17 (invariant 51), with its `TOKENFUSE_WARDRYX_URL` pointing at the
#      proxy instead and a longer tool-call wait. ONLY the broker: the
#      gateway keeps asking wardryx directly, so a slow typed answer never sits on
#      the model path (J2-DESIGN: the model's median would miss the gateway's 250 ms
#      and, fail-closed, refuse calls);
#   3. `typryx-egress-model`, when the mode has one, widened to select the proxy
#      pod as well, so the proxy reaches exactly what typryx reaches.
#
# It seeds NO policy: nothing is held until an operator writes a `hold_if_signal`
# rule (README, "A typed risk signal"). It is refused when typryx is not deployed:
# there is nothing to ask. Without the flag every render is byte for byte what it
# was before the flag existed, which scripts/typed-mode-is-honest.sh holds.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# The one secret generator, a bounded read (CLAUDE.md invariant 41), for the door's bearers.
. "$ROOT/lib/gen.sh"
NS="agent-stack"
M51="$ROOT/manifests/51-typryx.yaml"
M52="$ROOT/manifests/52-tokenfuse-mcp-broker.yaml"
M56="$ROOT/manifests/56-typryx-wardryx-proxy.yaml"

# Private ranges a public egress rule must never reach back into (the same list
# 30-network-policy.yaml's gateway-egress-internet carries).
PRIVATE_EXCEPT='[10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16]'

refuse() { printf 'typed: %s\n' "$*" >&2; exit 1; }

verb="${1:-}"
[ $# -gt 0 ] && shift

WITH_TYPED=0
MODE=""
JEV_KEY_FILE=""
MODEL_URL=""
MODEL_NAME=""
MODEL_KEY_FILE=""
MODEL_CIDR=""
TRAINING=0
TRAINING_DIR="/var/lib/typryx/training"
RISK=0
HAVE=""
HAVE_GIVEN=0
DOOR_DOMAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-typed) WITH_TYPED=1; shift ;;
    # Empty is a real answer here (neither Secret exists), so it is not the value rule below.
    --have)
      [ $# -ge 2 ] || refuse "--have needs a value (empty when neither door Secret exists)"
      HAVE="$2"; HAVE_GIVEN=1; shift 2 ;;
    --trust-domain)
      [ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
      DOOR_DOMAIN="$2"; shift 2 ;;
    --typed-training) TRAINING=1; shift ;;
    --typed-risk-signal) RISK=1; shift ;;
    --typed-mode|--typed-jev-key-file|--typed-model-url|--typed-model-name|--typed-model-key-file|--typed-model-cidr)
      [ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
      case "$1" in
        --typed-mode)           MODE="$2" ;;
        --typed-jev-key-file)   JEV_KEY_FILE="$2" ;;
        --typed-model-url)      MODEL_URL="$2" ;;
        --typed-model-name)     MODEL_NAME="$2" ;;
        --typed-model-key-file) MODEL_KEY_FILE="$2" ;;
        --typed-model-cidr)     MODEL_CIDR="$2" ;;
      esac
      shift 2 ;;
    *) refuse "unknown flag: $1" ;;
  esac
done

case "$verb" in
  check|render|secrets|has-secrets|mode|door-secrets) ;;
  *) refuse "usage: typed/mode.sh check|render|secrets|has-secrets|mode|door-secrets [flags]" ;;
esac
if [ "$verb" != door-secrets ] && { [ "$HAVE_GIVEN" = 1 ] || [ -n "$DOOR_DOMAIN" ]; }; then
  refuse "--have and --trust-domain only go with door-secrets"
fi

# ---- which mode, and which flags belong to it ------------------------------
EFFECTIVE=""
case "$MODE" in
  "")
    if [ "$WITH_TYPED" = 1 ]; then EFFECTIVE=stub; else EFFECTIVE=off; fi ;;
  off)
    if [ "$WITH_TYPED" = 1 ]; then
      refuse "--with-typed and --typed-mode off contradict each other: drop one of them"
    fi
    EFFECTIVE=off ;;
  jev|own-model) EFFECTIVE="$MODE" ;;
  *) refuse "unknown --typed-mode '$MODE': it is jev, own-model or off" ;;
esac

if [ "$TRAINING" = 1 ] && [ "$EFFECTIVE" = off ]; then
  refuse "--typed-training needs typryx deployed to write a log: add --with-typed, or choose --typed-mode jev or own-model"
fi

if [ "$RISK" = 1 ] && [ "$EFFECTIVE" = off ]; then
  refuse "--typed-risk-signal needs typryx deployed to produce a signal: add --with-typed, or choose --typed-mode jev or own-model"
fi

if [ "$EFFECTIVE" != jev ] && [ -n "$JEV_KEY_FILE" ]; then
  refuse "--typed-jev-key-file only goes with --typed-mode jev (this run is: $EFFECTIVE)"
fi
if [ "$EFFECTIVE" != own-model ]; then
  for v in "$MODEL_URL" "$MODEL_NAME" "$MODEL_KEY_FILE" "$MODEL_CIDR"; do
    if [ -n "$v" ]; then
      refuse "--typed-model-* flags only go with --typed-mode own-model (this run is: $EFFECTIVE)"
    fi
  done
fi

# A key is a file, read here on the operator's machine. Missing, not a file,
# unreadable or blank is refused by name, before anything is applied.
key_file_ok() { # path flag
  [ -e "$1" ] || refuse "$2 $1 does not exist"
  [ -f "$1" ] || refuse "$2 $1 is not a regular file"
  [ -r "$1" ] || refuse "$2 $1 is not readable"
  grep -q '[^[:space:]]' "$1" || refuse "$2 $1 is empty (or only whitespace): there is no key in it"
}

octets_ok() { # a.b.c.d
  local IFS=. o
  for o in $1; do [ "$o" -le 255 ] || return 1; done
}

# ---- validate --------------------------------------------------------------
HOST=""; PORT=""; HOSTKIND=""; SVC_NS=""
case "$EFFECTIVE" in
  jev)
    [ -n "$JEV_KEY_FILE" ] || refuse "--typed-mode jev needs --typed-jev-key-file PATH. The Jev key is read from a file and stored in a Secret, never passed as a value on a command line."
    key_file_ok "$JEV_KEY_FILE" --typed-jev-key-file ;;
  own-model)
    [ -n "$MODEL_URL" ]  || refuse "--typed-mode own-model needs --typed-model-url URL (ending in /v1)"
    [ -n "$MODEL_NAME" ] || refuse "--typed-mode own-model needs --typed-model-name NAME"
    case "$MODEL_URL" in
      *@*) refuse "--typed-model-url must not carry credentials (user:password@): a key goes in --typed-model-key-file" ;;
    esac
    url_re='^(https?)://([A-Za-z0-9.-]+)(:([0-9]+))?(/[A-Za-z0-9._~%+/-]*)?$'
    [[ "$MODEL_URL" =~ $url_re ]] \
      || refuse "--typed-model-url '$MODEL_URL' is not http(s)://host[:port]/.../v1 (no query, no fragment, no IPv6 literal)"
    scheme="${BASH_REMATCH[1]}"; HOST="${BASH_REMATCH[2]}"; PORT="${BASH_REMATCH[4]}"; path="${BASH_REMATCH[5]}"
    case "$path" in
      */v1|*/v1/) ;;
      *) refuse "--typed-model-url '$MODEL_URL' must end in /v1 (typryx appends /chat/completions itself)" ;;
    esac
    MODEL_URL="${MODEL_URL%/}"
    if [ -z "$PORT" ]; then
      if [ "$scheme" = https ]; then PORT=443; else PORT=80; fi
    fi
    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then refuse "--typed-model-url port $PORT is not 1 to 65535"; fi
    name_re='^[A-Za-z0-9._:/+@-]+$'
    [[ "$MODEL_NAME" =~ $name_re ]] || refuse "--typed-model-name '$MODEL_NAME' has characters a model name does not"
    [ -z "$MODEL_KEY_FILE" ] || key_file_ok "$MODEL_KEY_FILE" --typed-model-key-file
    if [ -n "$MODEL_CIDR" ]; then
      cidr_re='^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$'
      if ! { [[ "$MODEL_CIDR" =~ $cidr_re ]] && octets_ok "${MODEL_CIDR%/*}"; }; then
        refuse "--typed-model-cidr '$MODEL_CIDR' is not an IPv4 CIDR such as 192.168.7.0/24"
      fi
    fi
    ip_re='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
    svc_re='^[a-z0-9-]+\.([a-z0-9-]+)\.svc(\.cluster\.local)?$'
    one_re='^[A-Za-z0-9-]+$'
    if [[ "$HOST" =~ $ip_re ]] && octets_ok "$HOST"; then
      HOSTKIND=ip
    elif [[ "$HOST" =~ $svc_re ]]; then
      HOSTKIND=svc; SVC_NS="${BASH_REMATCH[1]}"
    elif [[ "$HOST" =~ $one_re ]]; then
      HOSTKIND=local
    else
      HOSTKIND=name
    fi ;;
esac

# ---- the pieces -------------------------------------------------------------
# `apply` never prunes, so every object a mode can render is named here once.
emit_secret() { # secret-name file
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n  labels: { app: typryx, plane: typed }\ntype: Opaque\ndata:\n  key: %s\n' \
    "$1" "$NS" "$(base64 < "$2" | tr -d '\n')"
}

egress_policy() { # port, then the peer lines on stdin
  local selector='{ matchLabels: { app: typryx } }'
  if [ "$RISK" = 1 ]; then
    # The proxy answers from the same backend, so it needs the same way out, no wider:
    # the one policy selects both pods rather than a second policy carrying a copy.
    selector='{ matchExpressions: [{ key: app, operator: In, values: [typryx, typryx-wardryx-proxy] }] }'
  fi
  printf -- '---\n# typryx is default-deny on egress like every pod here. This is its one way out,\n# one peer and one port, added because the mode chosen at deploy time needs a backend.\n'
  printf 'apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata: { name: typryx-egress-model, namespace: %s }\nspec:\n  podSelector: %s\n  policyTypes: ["Egress"]\n  egress:\n    - to:\n' "$NS" "$selector"
  cat
  printf '      ports:\n        - { protocol: TCP, port: %s }\n' "$1"
}

public_peer() {
  printf '        - ipBlock:\n            cidr: 0.0.0.0/0\n            except: %s\n' "$PRIVATE_EXCEPT"
}

# Rewrite the three anchor lines of manifests/51 for a mode. An anchor that is
# not found exactly once is a refusal: a render that silently emitted the stub
# while claiming jev would be the worst answer this file could give.
render_typryx() { # env-fragment mount-fragment volume-fragment [file mount-anchor volume-anchor]
  local out file="${4:-$M51}" a2 a3
  # The anchors default to manifests/51's; a caller rendering another file names its own.
  if [ $# -ge 6 ]; then
    a2="$5"; a3="$6"
  else
    a2='            - { name: events, mountPath: /var/lib/stack/events }'
    a3='          persistentVolumeClaim: { claimName: stack-events }'
  fi
  out="$(ENV_FRAG="$1" MOUNT_FRAG="$2" VOL_FRAG="$3" A2="$a2" A3="$a3" awk '
    BEGIN {
      a1 = "            - { name: TYPRYX_BACKEND, value: \"stub\" }"
      a2 = ENVIRON["A2"]
      a3 = ENVIRON["A3"]
    }
    $0 == a1 { print ENVIRON["ENV_FRAG"]; n1++; next }
    $0 == a2 { print; if (ENVIRON["MOUNT_FRAG"] != "") print ENVIRON["MOUNT_FRAG"]; n2++; next }
    $0 == a3 { print; if (ENVIRON["VOL_FRAG"] != "") print ENVIRON["VOL_FRAG"]; n3++; next }
    { print }
    END { if (n1 != 1 || n2 != 1 || n3 != 1) exit 3 }
  ' "$file")" || refuse "${file#"$ROOT"/} no longer carries the three lines this mode rewrites (TYPRYX_BACKEND stub, its mount, its volume), exactly once each. Fix typed/mode.sh with it."
  printf '%s\n' "$out"
}

# The training log is ONE environment variable on the container. It adds no volume:
# TRAINING_DIR is under /var/lib/typryx, the mount of the typryx-state claim the
# ledger already uses (see the header). Given an environment fragment, print it
# with the training variable after it when --typed-training was given, unchanged
# otherwise, so that a run without the flag renders what it always did.
with_training() { # env-fragment
  printf '%s' "$1"
  if [ "$TRAINING" = 1 ]; then
    printf '\n            # Opt-in local training log (--typed-training), typryx v0.3.0 or later: the egressed state of\n'
    printf '            # each answered question, never the backend answer. A directory on the typryx-state claim the\n'
    printf '            # ledger already uses: no new disk, and it lives as long as that claim.\n'
    printf '            - { name: TYPRYX_TRAINING_DIR, value: "%s" }' "$TRAINING_DIR"
  fi
  printf '\n'
}

# The broker's wardryx settings. manifests/52 asks wardryx itself about every tool call
# (CLAUDE.md invariant 51): mode enforce, fail closed, the gateway's VIEWER key (`wardryx_gateway`
# in stack-keys, minted by every installer: /v1/decide needs any authenticated principal, and an
# admin key here would let the enforcement point rewrite the policy it enforces). Without the risk
# signal the broker is manifests/52 byte for byte. With it, ONLY two lines move: the URL, to
# typryx's wardryx-proxy, and the tool path's wait, because the proxy's own ask may take up to
# TYPRYX_PROXY_ASK_TIMEOUT_MS (3000, at most 5000) before it forwards without a signal. The LLM
# gateway in 10-planes.yaml keeps asking wardryx directly. Each of the two lines must be there
# exactly once.
render_broker() {
  if [ "$RISK" = 0 ]; then
    cat "$M52"
    return
  fi
  local out
  out="$(awk '
    BEGIN {
      u = "            - { name: TOKENFUSE_WARDRYX_URL, value: \"http://wardryx:8090\" }"
      t = "            - { name: TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS, value: \"1000\" }"
    }
    $0 == u {
      print "            # The typed risk signal (--typed-risk-signal, CLAUDE.md invariant 29): the broker asks"
      print "            # wardryx THROUGH typryx'"'"'s wardryx-proxy, which adds the risk class of the pending call as"
      print "            # a signal. Only this container: the LLM gateway keeps asking wardryx directly."
      print "            - { name: TOKENFUSE_WARDRYX_URL, value: \"http://typryx-wardryx-proxy:4330\" }"
      nu++; next
    }
    $0 == t {
      print "            # A tool call may wait longer than a model call: the proxy'"'"'s own ask may take up to"
      print "            # TYPRYX_PROXY_ASK_TIMEOUT_MS (3000, at most 5000) before it forwards without a signal."
      print "            - { name: TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS, value: \"7000\" }"
      nt++; next
    }
    { print }
    END { if (nu != 1 || nt != 1) exit 3 }
  ' "$M52")" || refuse "manifests/52-tokenfuse-mcp-broker.yaml no longer carries its TOKENFUSE_WARDRYX_URL and TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS lines exactly once each, which the risk signal moves to the proxy. Fix typed/mode.sh with it."
  printf '%s\n' "$out"
}

# One typed mode, whole: typryx (manifests/51, rewritten for the mode), the broker in front
# of it, and, only with the risk signal, the proxy given the SAME backend (the same three
# lines rewritten in manifests/56, the same key Secret mounted). The training log belongs to
# typryx alone: the proxy opens no journal, no ledger and no training log, and asks about
# tool-call arguments it must not write down.
emit_mode() { # env-fragment mount-fragment volume-fragment   (the backend, WITHOUT the training log)
  if [ "$EFFECTIVE" = stub ] && [ "$TRAINING" = 0 ]; then
    cat "$M51"
  else
    render_typryx "$(with_training "$1")" "$2" "$3"
  fi
  printf -- '---\n'
  render_broker
  if [ "$RISK" = 1 ]; then
    printf -- '---\n'
    render_typryx "$1" "$2" "$3" "$M56" \
      '            - { name: tmp, mountPath: /tmp }' \
      '          emptyDir: {}'
  fi
}

render() {
  case "$EFFECTIVE" in
    off) return 0 ;;
    stub)
      emit_mode '            - { name: TYPRYX_BACKEND, value: "stub" }' "" "" ;;
    jev)
      emit_mode \
        '            - { name: TYPRYX_BACKEND, value: "jev" }
            # The key is a FILE mounted from the typryx-jev-key Secret, never an environment value.
            - { name: TYPRYX_JEV_KEY_FILE, value: "/etc/typryx/jev/key" }' \
        '            - { name: jev-key, mountPath: /etc/typryx/jev, readOnly: true }' \
        '        - name: jev-key
          secret: { secretName: typryx-jev-key, defaultMode: 0440 }'
      public_peer | egress_policy 443 ;;
    own-model)
      local env_frag mount_frag vol_frag
      env_frag="$(printf '            - { name: TYPRYX_BACKEND, value: "openai-logprobs" }\n            - { name: TYPRYX_OPENAI_URL, value: "%s" }\n            - { name: TYPRYX_OPENAI_MODEL, value: "%s" }' "$MODEL_URL" "$MODEL_NAME")"
      mount_frag=""; vol_frag=""
      if [ -n "$MODEL_KEY_FILE" ]; then
        env_frag="$env_frag
            # The key is a FILE mounted from the typryx-model-key Secret, never an environment value.
            - { name: TYPRYX_OPENAI_KEY_FILE, value: \"/etc/typryx/model/key\" }"
        mount_frag='            - { name: model-key, mountPath: /etc/typryx/model, readOnly: true }'
        vol_frag='        - name: model-key
          secret: { secretName: typryx-model-key, defaultMode: 0440 }'
      fi
      emit_mode "$env_frag" "$mount_frag" "$vol_frag"
      case "$HOSTKIND" in
        ip)    cidr="$HOST/32"; if [ -n "$MODEL_CIDR" ]; then cidr="$MODEL_CIDR"; fi
               printf '        - ipBlock:\n            cidr: %s\n' "$cidr" | egress_policy "$PORT" ;;
        svc)   if [ -n "$MODEL_CIDR" ]; then
                 printf '        - ipBlock:\n            cidr: %s\n' "$MODEL_CIDR" | egress_policy "$PORT"
               else
                 printf '        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: %s } }\n' "$SVC_NS" | egress_policy "$PORT"
               fi ;;
        local) if [ -n "$MODEL_CIDR" ]; then
                 printf '        - ipBlock:\n            cidr: %s\n' "$MODEL_CIDR" | egress_policy "$PORT"
               else
                 printf '        - podSelector: {}\n' | egress_policy "$PORT"
               fi ;;
        name)  if [ -n "$MODEL_CIDR" ]; then
                 printf '        - ipBlock:\n            cidr: %s\n' "$MODEL_CIDR" | egress_policy "$PORT"
               else
                 public_peer | egress_policy "$PORT"
               fi ;;
      esac ;;
  esac
  # The proxy's edges (broker -> proxy -> wardryx) are objects of their own, rendered with it
  # by emit_mode through manifests/56; nothing to add here for the stub, which has no egress.
}

secrets() {
  case "$EFFECTIVE" in
    jev) emit_secret typryx-jev-key "$JEV_KEY_FILE" ;;
    own-model)
      if [ -n "$MODEL_KEY_FILE" ]; then emit_secret typryx-model-key "$MODEL_KEY_FILE"; fi ;;
  esac
  return 0
}

has_secrets() {
  case "$EFFECTIVE" in
    jev) echo yes ;;
    own-model) if [ -n "$MODEL_KEY_FILE" ]; then echo yes; else echo no; fi ;;
    *) echo no ;;
  esac
}

# ---- the door: typryx-keys and tokenfuse-mcp-broker-keys (see THE DOOR above) ---------------
DOOR_TYPRYX="typryx-keys"
DOOR_BROKER="tokenfuse-mcp-broker-keys"
DOOR_KEY_ID="broker-caller"
DOOR_SUBJECT="typed-broker"

b64_() { printf '%s' "$1" | base64 | tr -d '\n'; }

door_secret() { # name app then key=value pairs, each value base64 in the document
  local name="$1" app="$2" kv
  shift 2
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n  labels: { app: %s, plane: typed }\ntype: Opaque\ndata:\n' \
    "$name" "$NS" "$app"
  for kv in "$@"; do
    printf '  %s: %s\n' "${kv%%=*}" "$(b64_ "${kv#*=}")"
  done
}

door_secrets() {
  [ "$EFFECTIVE" != off ] || refuse "door-secrets is for a typryx that is deployed: add --with-typed, or choose --typed-mode jev or own-model"
  [ "$HAVE_GIVEN" = 1 ] || refuse "door-secrets needs --have: which of $DOOR_TYPRYX and $DOOR_BROKER exist (empty for neither)"
  local have_t=0 have_b=0 tok domain="${DOOR_DOMAIN:-set-me.invalid}" given="" spec bearer broker_key made=""
  local domain_re bearer_re='^[^[:space:],]+$'
  for tok in $HAVE; do
    case "${tok#secret/}" in
      "$DOOR_TYPRYX") have_t=1 ;;
      "$DOOR_BROKER") have_b=1 ;;
      *) refuse "--have names '$tok', which is not $DOOR_TYPRYX or $DOOR_BROKER" ;;
    esac
  done
  domain_re='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
  [[ "$domain" =~ $domain_re ]] || refuse "--trust-domain '$domain' is not a domain name"
  # Read stdin whole in every case, so the `kubectl get` feeding it never meets a closed pipe.
  if [ ! -t 0 ]; then given="$(cat)"; fi

  if [ "$have_t" = 1 ] && [ "$have_b" = 1 ]; then
    printf 'typed: the door: %s and %s already exist and are kept as they are.\n' "$DOOR_TYPRYX" "$DOOR_BROKER" >&2
  elif [ "$have_b" = 1 ]; then
    refuse "$DOOR_BROKER exists and $DOOR_TYPRYX does not. A new typryx key would not be the typryx_key the broker's vault already holds, so every call through the broker would be refused, and the door never overwrites a Secret that exists. Create $DOOR_TYPRYX with the bearer that vault holds (manifests/51-typryx.yaml's header shows the command), or delete $DOOR_BROKER so both are minted, then run this again."
  elif [ "$have_t" = 1 ]; then
    spec="$(printf '%s' "$given" | tr -d ' \n\r\t' | base64 -d 2>/dev/null)" || spec=""
    bearer="${spec%%,*}"
    bearer="${bearer%%=*}"
    if [ -z "$bearer" ] || [ "$bearer" = "$spec" ] || ! [[ "$bearer" =~ $bearer_re ]]; then
      refuse "$DOOR_TYPRYX exists but no TYPRYX_KEYS bearer (\`bearer=agent://...\`) could be read from it, so the broker's vault cannot be given typryx's key. Create $DOOR_BROKER by hand (manifests/52-tokenfuse-mcp-broker.yaml's header shows the command), then run this again."
    fi
    broker_key="$(gen 40)" || refuse "could not mint the broker's key"
    door_secret "$DOOR_BROKER" tokenfuse-mcp-broker \
      "TOKENFUSE_MCP_KEYS=$broker_key:$DOOR_KEY_ID" "TOKENFUSE_MCP_SECRETS=typryx_key=$bearer"
    made="$DOOR_BROKER, its vault carrying the bearer of the $DOOR_TYPRYX that was already there, which is kept"
  else
    bearer="$(gen 40)" || refuse "could not mint typryx's key"
    broker_key="$(gen 40)" || refuse "could not mint the broker's key"
    [ "$bearer" != "$broker_key" ] || refuse "the two door keys came out equal, which a random source does not do"
    door_secret "$DOOR_TYPRYX" typryx "TYPRYX_KEYS=$bearer=agent://$domain/$DOOR_SUBJECT"
    printf -- '---\n'
    door_secret "$DOOR_BROKER" tokenfuse-mcp-broker \
      "TOKENFUSE_MCP_KEYS=$broker_key:$DOOR_KEY_ID" "TOKENFUSE_MCP_SECRETS=typryx_key=$bearer"
    made="$DOOR_TYPRYX (identity agent://$domain/$DOOR_SUBJECT) and $DOOR_BROKER, the broker's vault carrying typryx's bearer"
  fi
  bearer=""; broker_key=""; spec=""; given=""
  if [ -n "$made" ]; then
    printf 'typed: the door: creating %s. A Secret that already exists is never overwritten, so on every later run both are kept.\n' "$made" >&2
  fi
  printf '       Read a value back, never printed here: the broker'"'"'s caller key (`secret:%s`; an agent sends the secret as x-fuse-key), then typryx'"'"'s own (`bearer=agent://...`):\n' "$DOOR_KEY_ID" >&2
  printf "         kubectl -n %s get secret %s -o jsonpath='{.data.TOKENFUSE_MCP_KEYS}' | base64 -d\n" "$NS" "$DOOR_BROKER" >&2
  printf "         kubectl -n %s get secret %s -o jsonpath='{.data.TYPRYX_KEYS}' | base64 -d\n" "$NS" "$DOOR_TYPRYX" >&2
}

notice() {
  if [ "$TRAINING" = 1 ]; then
    printf 'typed: training log ON (--typed-training). typryx appends the egressed state of each answered question to training.ndjson in %s, on the typryx-state claim it already has: no new disk, and the log lives as long as that claim.\n       It never holds the backend'"'"'s answer. Read how to export it, and why it adds no disk, in README "Typed answers: choose where your data goes".\n' "$TRAINING_DIR" >&2
  fi
  if [ "$RISK" = 1 ]; then
    printf 'typed: risk signal ON (--typed-risk-signal). typryx'"'"'s wardryx-proxy now sits between tokenfuse'"'"'s MCP broker and wardryx (manifests/56), answering from the same backend as typryx. The LLM gateway keeps asking wardryx directly.\n' >&2
    printf '       The broker asks wardryx about EVERY tool call on every cluster (invariant 51), now through the proxy, and fails closed: while wardryx or the proxy is down, tool calls through the broker are refused.\n' >&2
    printf '       No policy is seeded. Nothing is held until you write a hold_if_signal rule (README "A typed risk signal"); a rule that would deny on a signal is refused by wardryx.\n' >&2
    case "$EFFECTIVE" in
      stub) printf '       The stub backend answers every call the same way and its probabilities mean nothing: a hold_if_signal rule on them would hold on noise.\n' >&2 ;;
      jev)  printf '       Each tool call that carries a name and whole arguments is one Jev ask, a paid call, and the tool name, arguments and target leave the cluster; the proxy has its own hourly cap (TYPRYX_MAX_CALLS_PER_HOUR, default 1000).\n' >&2 ;;
      own-model) printf '       Each tool call that carries a name and whole arguments is one ask of your model; the tool name, arguments and target go to it.\n' >&2 ;;
    esac
  fi
  case "$EFFECTIVE" in
    jev)
      printf 'typed: mode jev. The named fields of every typed question leave the cluster for TypeSafe'"'"'s hosted API, a paid service billed to your key.\n       typryx caps calls at TYPRYX_MAX_CALLS_PER_HOUR (default 1000). The key is a Secret mounted as a file and is never printed.\n' >&2 ;;
    own-model)
      printf 'typed: mode own-model. typryx asks %s (model %s). Nothing leaves your cluster or network unless that URL is a hosted service.\n' "$MODEL_URL" "$MODEL_NAME" >&2 ;;
    stub)
      printf 'typed: mode stub (--with-typed alone). Free, deterministic, no outbound call; it answers nobody'"'"'s real question.\n' >&2 ;;
  esac
}

case "$verb" in
  check)       notice ;;
  render)      render ;;
  secrets)
    [ ! -t 1 ] || refuse "refusing to print a Secret to a terminal: pipe it into 'kubectl apply -f -' and nowhere else"
    secrets ;;
  has-secrets) has_secrets ;;
  mode)        echo "$EFFECTIVE" ;;
  door-secrets)
    [ ! -t 1 ] || refuse "refusing to print a Secret to a terminal: pipe it into 'kubectl create -f -' and nowhere else"
    door_secrets ;;
esac
