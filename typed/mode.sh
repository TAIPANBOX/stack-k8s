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
# The door key (`typryx-keys`, TYPRYX_KEYS) is unchanged and still operator
# made, in every mode; 51-typryx.yaml's header shows the command.
#
# NOT DONE HERE: TYPRYX_TRAINING_DIR (an opt-in local training log) is planned
# in typryx and needs a release first. Nothing here sets it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="agent-stack"
M51="$ROOT/manifests/51-typryx.yaml"
M52="$ROOT/manifests/52-tokenfuse-mcp-broker.yaml"

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
while [ $# -gt 0 ]; do
  case "$1" in
    --with-typed) WITH_TYPED=1; shift ;;
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
  check|render|secrets|has-secrets|mode) ;;
  *) refuse "usage: typed/mode.sh check|render|secrets|has-secrets|mode [flags]" ;;
esac

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
  printf -- '---\n# typryx is default-deny on egress like every pod here. This is its one way out,\n# one peer and one port, added because the mode chosen at deploy time needs a backend.\n'
  printf 'apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata: { name: typryx-egress-model, namespace: %s }\nspec:\n  podSelector: { matchLabels: { app: typryx } }\n  policyTypes: ["Egress"]\n  egress:\n    - to:\n' "$NS"
  cat
  printf '      ports:\n        - { protocol: TCP, port: %s }\n' "$1"
}

public_peer() {
  printf '        - ipBlock:\n            cidr: 0.0.0.0/0\n            except: %s\n' "$PRIVATE_EXCEPT"
}

# Rewrite the three anchor lines of manifests/51 for a mode. An anchor that is
# not found exactly once is a refusal: a render that silently emitted the stub
# while claiming jev would be the worst answer this file could give.
render_typryx() { # env-fragment mount-fragment volume-fragment
  local out
  out="$(ENV_FRAG="$1" MOUNT_FRAG="$2" VOL_FRAG="$3" awk '
    BEGIN {
      a1 = "            - { name: TYPRYX_BACKEND, value: \"stub\" }"
      a2 = "            - { name: events, mountPath: /var/lib/stack/events }"
      a3 = "          persistentVolumeClaim: { claimName: stack-events }"
    }
    $0 == a1 { print ENVIRON["ENV_FRAG"]; n1++; next }
    $0 == a2 { print; if (ENVIRON["MOUNT_FRAG"] != "") print ENVIRON["MOUNT_FRAG"]; n2++; next }
    $0 == a3 { print; if (ENVIRON["VOL_FRAG"] != "") print ENVIRON["VOL_FRAG"]; n3++; next }
    { print }
    END { if (n1 != 1 || n2 != 1 || n3 != 1) exit 3 }
  ' "$M51")" || refuse "manifests/51-typryx.yaml no longer carries the three lines this mode rewrites (TYPRYX_BACKEND stub, the events mount, the stack-events volume), exactly once each. Fix typed/mode.sh with it."
  printf '%s\n' "$out"
}

render() {
  case "$EFFECTIVE" in
    off) return 0 ;;
    stub)
      cat "$M51"; printf -- '---\n'; cat "$M52" ;;
    jev)
      render_typryx \
        '            - { name: TYPRYX_BACKEND, value: "jev" }
            # The key is a FILE mounted from the typryx-jev-key Secret, never an environment value.
            - { name: TYPRYX_JEV_KEY_FILE, value: "/etc/typryx/jev/key" }' \
        '            - { name: jev-key, mountPath: /etc/typryx/jev, readOnly: true }' \
        '        - name: jev-key
          secret: { secretName: typryx-jev-key, defaultMode: 0440 }'
      printf -- '---\n'; cat "$M52"
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
      render_typryx "$env_frag" "$mount_frag" "$vol_frag"
      printf -- '---\n'; cat "$M52"
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

notice() {
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
esac
