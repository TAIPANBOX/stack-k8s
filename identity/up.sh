#!/usr/bin/env bash
# Give the gateway its client keys and its identity map, from files.
#
#   ./identity/up.sh --client-keys-file keys.txt --identity-map-file identity.json
#   ./identity/up.sh --identity-map-file identity.json    # a new map, the keys kept
#   ./identity/up.sh                                      # check what the cluster holds again
#   ./identity/up.sh --check-only --client-keys-file keys.txt --identity-map-file identity.json
#
# Who may call the gateway, which agent ids each caller may speak as, and which
# business unit its spend lands in (tokenfuse docs/20). CLAUDE.md invariant 39.
# The keys are required (invariant 50): the gateway does not start without the
# Secret this writes, and a deploy given no files mints two keys of its own
# (lib/identity-mint.sh). This script is how an operator brings their own. On a
# cluster whose keys were minted, give both files together: the minted map binds
# the minted key ids and nothing else. Writing them makes the keys the operator's,
# and the deploy leaves them alone from then on.
#
#   --client-keys-file F   (or CLIENT_KEYS_FILE) one secret:key_id per line, the
#                          line the console's Onboard tab prints; blank lines and
#                          # comments are ignored
#   --identity-map-file F  (or IDENTITY_MAP_FILE) tokenfuse's identity map, JSON:
#                          units[], keys[] and prefixes[] (docs/20)
#   --check-only           check the files and touch no cluster: the grammar, then
#                          the gateway image reads the pair it is given
#   --image IMG            (or IDENTITY_IMAGE) the gateway image to check with; by
#                          default the one the running gateway Deployment names,
#                          and with --check-only the one manifests/10-planes.yaml pins
#
# WHERE THEY GO. The keys become the Secret gateway-client-keys (key client_keys),
# written from stdin: never on a command line, and never through `kubectl apply`,
# whose last-applied annotation would keep a second copy on the object. The map
# becomes the ConfigMap gateway-identity-map: the file under identity.json, and
# under map_path the path the gateway reads it from, so the variable and the file
# come from one object and cannot disagree (the gateway refuses to start on a path
# that names no file). manifests/10-planes.yaml reads the keys as required and the
# map as optional, and mounts the map read only at /etc/tokenfuse/identity.
# Neither object is in any manifest, so `kubectl apply -k` leaves them alone.
#
# CHECKED TWICE, AND NEITHER CHECK CHANGES THE CLUSTER.
#   First, before any tool runs: each file is a readable regular file with
#     something in it and no NUL byte; each key line is secret:key_id, split on
#     the LAST colon as tokenfuse splits it, with a secret of 24 to 256 of
#     A-Z a-z 0-9 . _ ~ + / = @ : - and a key id of 1 to 128 of A-Z a-z 0-9 . _ -
#     (no comma, quote, dollar or space can reach the Secret), and no secret given
#     twice; the map is UTF-8, starts with {, and fits in a ConfigMap. What the
#     cluster already holds is held to the same grammar.
#   Then, with docker on this machine: the gateway image the cluster runs reads
#     the pair this run will leave (the new file where one was given, what the
#     cluster holds where not), in a throwaway container with no network, as the
#     pod runs it (its command, its uid, a read-only root), so tokenfuse's own
#     parser is the judge and not a copy of it here. Anything it refuses to start
#     on is refused, and so are three things it only warns about: a map that
#     configures nothing (an empty file and {} read as no map at all), a map key_id
#     no client key carries, and a client key the map does not bind (under
#     strict=enforce, the gateway's default, every call with it is refused 403).
# Only then is anything written.
#
# THE GATEWAY ROLLS WHEN WHAT IT READS CHANGED, AND ONLY THEN. A Secret or
# ConfigMap change restarts no pod, and the gateway reads both only at start. So
# the gateway's pod template carries the map's sha256 and the Secret's
# resourceVersion as annotations (taipanbox.dev/identity-map-sha256,
# taipanbox.dev/client-keys-version, `off` when absent), set with `kubectl patch`,
# which `kubectl apply -k` leaves alone (GOTCHAS 113). A run that changes neither
# object patches nothing and rolls nothing; a run cut short after a write is
# repaired by the next one, which finds the template behind the objects. After
# the roll, the start-up lines of the gateway pod carrying those annotations are
# read: it must report the keys and the map this run checked.
#
# A RE-RUN that names no file keeps both and checks them again, with the image
# the cluster runs now, so an upgrade that would refuse the map is found here.
#
# TO TURN THE MAP OFF, delete its ConfigMap, then run this script with no file,
# which rolls the gateway without it. The keys cannot be turned off: the gateway
# requires them. This script deletes nothing itself:
#   kubectl -n agent-stack delete configmap gateway-identity-map
#   ./identity/up.sh
#
# Every metered call must carry `x-fuse-key`. Felyx (the console's copilot) sends
# the key in the Secret felyx-client-key, which a deploy mints with its own keys;
# with your files, give Felyx a line in the keys file and put the same secret in
# that Secret. The drills (mockryx) send no key and are refused 401.
#
# Needs kubectl (KUBECONFIG from the environment), docker and python3 here. The
# check bind-mounts a staging directory of this machine, so the Docker daemon has
# to run here: a remote one (DOCKER_HOST) sees no map, and the check refuses.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-agent-stack}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

KEYS_FILE="${CLIENT_KEYS_FILE:-}"
MAP_FILE="${IDENTITY_MAP_FILE:-}"
IMAGE="${IDENTITY_IMAGE:-}"
CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --client-keys-file)  [ -n "${2:-}" ] || die "--client-keys-file needs a file"; KEYS_FILE="$2"; shift 2 ;;
    --identity-map-file) [ -n "${2:-}" ] || die "--identity-map-file needs a file"; MAP_FILE="$2"; shift 2 ;;
    --image)             [ -n "${2:-}" ] || die "--image needs an image"; IMAGE="$2"; shift 2 ;;
    --check-only)        CHECK_ONLY=1; shift ;;
    -h|--help)           awk 'NR > 1 && /^set -euo pipefail/ { exit } NR > 1' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *)                   die "unknown flag: $1" ;;
  esac
done

NOTHING="Nothing was changed in the cluster."

# identity-files: begin
# The names the manifest, verify.sh and scripts/identity-files-are-checked.sh are
# held to. One copy, here.
SECRET_NAME=gateway-client-keys
SECRET_KEY=client_keys
MAP_CONFIGMAP=gateway-identity-map
MAP_KEY=identity.json
MAP_PATH_KEY=map_path
MAP_DIR=/etc/tokenfuse/identity
MINT_LABEL=taipanbox.dev/identity
GATEWAY_CMD=/usr/local/bin/tokenfuse
GATEWAY_USER=10001:10001
ANN_MAP=taipanbox.dev/identity-map-sha256
ANN_KEYS=taipanbox.dev/client-keys-version
KEYS_MAX=262144
# A ConfigMap holds at most 1 MiB in all; this leaves room for its path key.
MAP_MAX=1044480

KEYS_GIVEN=0   # 1 when this run named a keys file
KEYS_NEW=""    # the spec that file gives, comma-joined; never printed
MAP_GIVEN=0    # 1 when this run named a map
CHECK_KEYS=0   # client keys the gateway image read
CHECK_MAP=0    # 1 when the gateway image read a map
CHECK_CONTAINER=""
SCRATCH=""

cleanup() {
  if [ -n "$CHECK_CONTAINER" ]; then docker rm -f "$CHECK_CONTAINER" >/dev/null 2>&1 || true; fi
  if [ -n "$SCRATCH" ]; then rm -rf -- "$SCRATCH"; fi
}
trap cleanup EXIT

# FILE MAXBYTES: prints why FILE cannot be read as an input, nothing when it can.
identity_file_why() {
  local f="$1" size
  if [ ! -e "$f" ]; then printf 'names nothing that exists'; return 0; fi
  if [ ! -f "$f" ]; then printf 'does not name a regular file'; return 0; fi
  if [ ! -r "$f" ]; then printf 'names a file this script cannot read'; return 0; fi
  size=$(( $(wc -c <"$f") ))
  if [ "$size" -gt "$2" ]; then printf 'names a file larger than %s bytes' "$2"; return 0; fi
  if [ "$(( $(tr -d '\000' <"$f" | wc -c) ))" != "$size" ]; then printf 'names a file holding a NUL byte'; return 0; fi
  if ! LC_ALL=C grep -q '[^[:space:]]' "$f"; then printf 'names an empty file'; return 0; fi
}

# ENTRY: prints why ENTRY is not a usable secret:key_id, nothing when it is. Never
# prints the entry: the secret is the one thing this script does not show.
identity_entry_why() {
  local LC_ALL=C secret key_id re_id='^[A-Za-z0-9._-]{1,128}$' re_chars='^[A-Za-z0-9._~+/=@:-]+$'
  case "$1" in
    *:*) ;;
    *) printf 'is not secret:key_id (it has no colon)'; return 0 ;;
  esac
  secret="${1%:*}"
  key_id="${1##*:}"
  if [[ ! "$key_id" =~ $re_id ]]; then
    printf 'has a key id (after its last colon) that is not 1 to 128 of A-Z a-z 0-9 . _ -'
  elif [ "${#secret}" -lt 24 ] || [ "${#secret}" -gt 256 ]; then
    printf 'has a secret that is not 24 to 256 characters long'
  elif [[ ! "$secret" =~ $re_chars ]]; then
    printf 'has a secret with a character outside A-Z a-z 0-9 . _ ~ + / = @ : -'
  fi
}

# SPEC: prints why a comma-joined spec the cluster holds is not usable, nothing
# when it is. The same grammar as a file's lines, entry by entry.
identity_spec_why() {
  local rest="$1," entry why n=0 seen=$'\n'
  while [ -n "$rest" ]; do
    entry="${rest%%,*}"
    rest="${rest#*,}"
    n=$((n + 1))
    why="$(identity_entry_why "$entry")"
    if [ -n "$why" ]; then printf 'entry %s %s' "$n" "$why"; return 0; fi
    case "$seen" in
      *$'\n'"${entry%:*}"$'\n'*) printf 'entry %s gives a secret an earlier entry already gave' "$n"; return 0 ;;
    esac
    seen="$seen${entry%:*}"$'\n'
  done
}

# Decide what this run was given, and refuse, naming what is wrong and never what
# a secret is, before any tool has run.
identity_resolve() {
  local f why line secret n=0 count=0 spec="" seen=$'\n' first
  if [ -n "$KEYS_FILE" ]; then
    f="$KEYS_FILE"
    why="$(identity_file_why "$f" "$KEYS_MAX")"
    [ -z "$why" ] || die "--client-keys-file $why. It must name a file of secret:key_id lines (README, \"Client keys and the identity map\"). $NOTHING"
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      line="${line%$'\r'}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      case "$line" in ""|"#"*) continue ;; esac
      why="$(identity_entry_why "$line")"
      [ -z "$why" ] || die "--client-keys-file: line $n $why. Each line is secret:key_id. $NOTHING"
      secret="${line%:*}"
      case "$seen" in
        *$'\n'"$secret"$'\n'*) die "--client-keys-file: line $n gives a secret an earlier line already gave, and the gateway would keep only one of the two. $NOTHING" ;;
      esac
      seen="$seen$secret"$'\n'
      spec="${spec:+$spec,}$line"
      count=$((count + 1))
    done <"$f"
    [ "$count" -gt 0 ] || die "--client-keys-file names no key: every line in it is blank or a comment. $NOTHING"
    [ "${#spec}" -le 65536 ] || die "--client-keys-file gives more keys than fit in one environment value (65536 bytes). $NOTHING"
    KEYS_NEW="$spec"
    KEYS_GIVEN=1
  fi
  if [ -n "$MAP_FILE" ]; then
    f="$MAP_FILE"
    why="$(identity_file_why "$f" "$MAP_MAX")"
    [ -z "$why" ] || die "--identity-map-file $why. It must name tokenfuse's identity map, a JSON file that fits in a ConfigMap (README, \"Client keys and the identity map\"). $NOTHING"
    python3 -c 'import sys; open(sys.argv[1], "rb").read().decode("utf-8")' "$f" 2>/dev/null \
      || die "--identity-map-file is not UTF-8, which JSON and a ConfigMap both require. $NOTHING"
    first="$(sed -n '/[^[:space:]]/{s/^[[:space:]]*//;s/^\(.\).*/\1/p;q;}' "$f")"
    [ "$first" = "{" ] || die "--identity-map-file is not a JSON object: an identity map starts with {. $NOTHING"
    MAP_GIVEN=1
  fi
}

# Removes every secret of SPEC from stdin, so the gateway's own words can be shown.
identity_redact() {
  REDACT_SPEC="$1" python3 -c '
import os, sys
t = sys.stdin.read()
for e in os.environ["REDACT_SPEC"].split(","):
    if ":" in e:
        t = t.replace(e.rsplit(":", 1)[0], "<a secret>")
sys.stdout.write(t)'
}

# IMAGE SPEC MAPFILE: the gateway image reads the pair, and the answer is read from
# what it prints. Writes nothing outside a staging directory this run made.
identity_check() {
  local img="$1" spec="$2" map="$3" stage logs="" status="" left=40 orphans unbound
  CHECK_KEYS=0
  CHECK_MAP=0
  [ -n "$spec$map" ] || return 0
  [ -n "$img" ] || die "could not tell which gateway image to check the files with. $NOTHING"
  command -v docker >/dev/null 2>&1 \
    || die "docker is not on PATH. The gateway image reads the files in a throwaway container before anything changes, and this machine cannot start one. $NOTHING"
  docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null 2>&1 \
    || die "could not pull $img to check the files with. $NOTHING"
  stage="$(mktemp -d "$SCRATCH/check.XXXXXX")" || die "could not make a staging directory"
  chmod 0755 "$stage"
  if [ -n "$map" ]; then
    cat "$map" >"$stage/$MAP_KEY" || die "could not stage the identity map"
    chmod 0444 "$stage/$MAP_KEY"
  fi
  CHECK_CONTAINER="identity-check-$$-$(date +%s)"
  # The keys travel in this command's environment and `-e NAME` with no value,
  # never on a command line. The command, the user and the read-only root are the
  # pod's own (manifests/10-planes.yaml): an image BUILD_FROM_SOURCE builds has no
  # ENTRYPOINT, and the published one names its binary by PATH, so the command is
  # given rather than left to the image.
  TOKENFUSE_CLIENT_KEYS="$spec" docker run -d --name "$CHECK_CONTAINER" --network none \
      --user "$GATEWAY_USER" --read-only --cap-drop ALL --security-opt no-new-privileges \
      --entrypoint "$GATEWAY_CMD" \
      -e TOKENFUSE_UPSTREAM=https://api.anthropic.com/v1/messages \
      -e TOKENFUSE_CLIENT_KEYS \
      -e "TOKENFUSE_IDENTITY_MAP=${map:+$MAP_DIR/$MAP_KEY}" \
      -v "$stage:$MAP_DIR:ro" \
      "$img" >/dev/null \
    || die "could not start $img to check the files. $NOTHING"
  while [ "$left" -gt 0 ]; do
    logs="$(docker logs "$CHECK_CONTAINER" 2>&1)"
    case "$logs" in *"tokenfuse gateway listening"*) break ;; esac
    status="$(docker inspect -f '{{.State.Status}}' "$CHECK_CONTAINER" 2>/dev/null || true)"
    [ "$status" = running ] || [ "$status" = created ] || break
    sleep 0.5
    left=$((left - 1))
  done
  logs="$(docker logs "$CHECK_CONTAINER" 2>&1)"
  docker rm -f "$CHECK_CONTAINER" >/dev/null 2>&1 || true
  CHECK_CONTAINER=""
  rm -rf -- "$stage"

  case "$logs" in
    *"tokenfuse gateway listening"*) ;;
    *)
      printf '%s\n' "$logs" | grep '^tokenfuse: ' | identity_redact "$spec" | sed 's/^/   /' >&2 || true
      die "the gateway image ($img) would not start with these files (its own words are above). $NOTHING"
      ;;
  esac
  if [ -n "$spec" ]; then
    CHECK_KEYS=$(( $(printf '%s' "$spec" | tr -cd ',' | wc -c) + 1 ))
    grep -qF "client auth: ON ($CHECK_KEYS key(s))" <<<"$logs" \
      || die "the gateway did not take all $CHECK_KEYS client key(s) it was given. $NOTHING"
  fi
  if [ -n "$map" ]; then
    grep -qF 'identity map: ON (' <<<"$logs" \
      || die "the identity map configures nothing: no unit, no key binding, no prefix. An empty file and {} read as no map at all, and the gateway would run with it off. $NOTHING"
    CHECK_MAP=1
  fi
  # The backticks are the gateway's own quoting around a key id, matched as text.
  # shellcheck disable=SC2016
  orphans="$(sed -n 's/^tokenfuse: identity map key_id `\([^`]*\)` has no matching TOKENFUSE_CLIENT_KEYS entry.*/\1/p' <<<"$logs" | sort -u | tr '\n' ' ')"
  if [ -n "$orphans" ]; then
    die "the identity map binds key id(s) ${orphans}that no client key carries, so its bindings could never match a call. Give a secret:key_id line for each, or drop the binding. $NOTHING"
  fi
  # shellcheck disable=SC2016  # the gateway's backticks again, matched as text
  unbound="$(sed -n 's/^tokenfuse: client key `\([^`]*\)` has no keys\[\] binding.*/\1/p' <<<"$logs" | sort -u | tr '\n' ' ')"
  if [ -n "$unbound" ]; then
    die "client key id(s) ${unbound}have no keys[] binding in the identity map, and under strict=enforce, the gateway's default, every call with them is refused 403. Bind each in the map, or drop it from the keys file. $NOTHING"
  fi
}
# identity-files: end

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/identity-up.XXXXXX")" || die "could not make a scratch directory"
chmod 0700 "$SCRATCH"

identity_resolve

if [ "$CHECK_ONLY" = 1 ]; then
  [ "$KEYS_GIVEN$MAP_GIVEN" != 00 ] || die "--check-only needs --client-keys-file, --identity-map-file or both: there is nothing to check."
  [ -n "$IMAGE" ] || IMAGE="$(sed -n 's/^ *image: \(ghcr\.io\/taipanbox\/tokenfuse:[^ ]*\)$/\1/p' "$ROOT/manifests/10-planes.yaml" | head -n 1)"
  identity_check "$IMAGE" "$KEYS_NEW" "${MAP_FILE:+$MAP_FILE}"
  if [ "$CHECK_MAP" = 1 ]; then m="an identity map"; else m="no identity map"; fi
  say "the gateway image read the files"
  note "OK: $IMAGE read $CHECK_KEYS client key(s) and $m, and refused nothing."
  note "Only the pair given here was checked: a run against the cluster checks it with what the cluster keeps."
  exit 0
fi

# ---- the cluster, read only until the check has passed ----------------------------
command -v kubectl >/dev/null || die "kubectl not found"
command -v python3 >/dev/null || die "python3 not found"
kubectl version -o json >/dev/null 2>&1 || die "no cluster: set KUBECONFIG"
k() { kubectl -n "$NS" "$@"; }
# The namespace must already exist: this configures an installed stack, and it
# never applies a Namespace object (GOTCHAS 114).
kubectl get namespace "$NS" -o name >/dev/null 2>&1 \
  || die "namespace $NS does not exist: install the stack first. $NOTHING"
dep="$(k get deployment tokenfuse-gateway -o json 2>/dev/null)" \
  || die "no tokenfuse-gateway Deployment in $NS: install the stack first. $NOTHING"

# What the gateway's pod template says it read: the image, and the two annotations
# (an absent annotation reads as off, so a cluster never given a file is not rolled).
live="$(printf '%s' "$dep" | python3 -c '
import json, sys
d = json.load(sys.stdin)
t = d["spec"]["template"]
img = next((c.get("image", "") for c in t["spec"]["containers"] if c.get("name") == "gateway"), "")
ann = t.get("metadata", {}).get("annotations") or {}
print(img)
print(ann.get(sys.argv[1]) or "off")
print(ann.get(sys.argv[2]) or "off")' "$ANN_MAP" "$ANN_KEYS")"
LIVE_IMAGE="$(sed -n 1p <<<"$live")"
LIVE_ANN_MAP="$(sed -n 2p <<<"$live")"
LIVE_ANN_KEYS="$(sed -n 3p <<<"$live")"
[ -n "$IMAGE" ] || IMAGE="$LIVE_IMAGE"

# What the Secret holds: "<resourceVersion>:<spec>", the spec decoded here and kept
# in this shell only. A resourceVersion has no colon.
secret_read() {
  local o out
  SECRET_PRESENT=0
  SECRET_MINTED=0
  SECRET_RV=""
  KEPT_SPEC=""
  o="$(k get secret "$SECRET_NAME" -o json --ignore-not-found)" || die "could not read Secret $SECRET_NAME. $NOTHING"
  [ -n "$o" ] || return 0
  out="$(printf '%s' "$o" | python3 -c '
import base64, json, sys
o = json.load(sys.stdin)
v = (o.get("data") or {}).get(sys.argv[1], "")
m = "1" if (o["metadata"].get("labels") or {}).get(sys.argv[2]) == "minted" else "0"
sys.stdout.write(m + o["metadata"].get("resourceVersion", "") + ":" + base64.b64decode(v).decode("utf-8"))' "$SECRET_KEY" "$MINT_LABEL")" \
    || die "could not read Secret $SECRET_NAME. $NOTHING"
  SECRET_PRESENT=1
  SECRET_MINTED="${out:0:1}"
  out="${out:1}"
  SECRET_RV="${out%%:*}"
  KEPT_SPEC="${out#*:}"
}

# What the ConfigMap holds: the map copied to KEPT_MAP byte for byte, its sha256 in
# MAP_SHA, and the path it hands the gateway.
cm_read() {
  local o out path
  MAP_SHA=""
  KEPT_MAP=""
  o="$(k get configmap "$MAP_CONFIGMAP" -o json --ignore-not-found)" || die "could not read ConfigMap $MAP_CONFIGMAP. $NOTHING"
  [ -n "$o" ] || return 0
  out="$(printf '%s' "$o" | python3 -c '
import hashlib, json, sys
d = json.load(sys.stdin).get("data") or {}
m = d.get(sys.argv[1])
if m is not None:
    open(sys.argv[3], "wb").write(m.encode("utf-8"))
print(hashlib.sha256(m.encode("utf-8")).hexdigest() if m is not None else "")
print(d.get(sys.argv[2], ""))' "$MAP_KEY" "$MAP_PATH_KEY" "$SCRATCH/kept.json")" \
    || die "could not read ConfigMap $MAP_CONFIGMAP. $NOTHING"
  MAP_SHA="$(sed -n 1p <<<"$out")"
  path="$(sed -n 2p <<<"$out")"
  if [ -n "$MAP_SHA" ]; then
    KEPT_MAP="$SCRATCH/kept.json"
    [ "$path" = "$MAP_DIR/$MAP_KEY" ] \
      || die "ConfigMap $MAP_CONFIGMAP hands the gateway the path '$path', not $MAP_DIR/$MAP_KEY, the one place the map is mounted. Give --identity-map-file again, or delete the ConfigMap. $NOTHING"
  elif [ -n "$path" ]; then
    die "ConfigMap $MAP_CONFIGMAP names a map path and holds no $MAP_KEY, so the gateway would refuse to start. Give --identity-map-file again, or delete the ConfigMap. $NOTHING"
  fi
}

secret_read
cm_read
if [ "$KEYS_GIVEN" = 0 ] && [ -n "$KEPT_SPEC" ]; then
  why="$(identity_spec_why "$KEPT_SPEC")"
  [ -z "$why" ] || die "Secret $SECRET_NAME holds a spec whose $why. Give --client-keys-file again, or delete the Secret. $NOTHING"
fi

# The pair this run will leave: the new file where one was given, what the cluster
# keeps where not.
SPEC="$KEPT_SPEC"
[ "$KEYS_GIVEN" = 0 ] || SPEC="$KEYS_NEW"
MAPF="$KEPT_MAP"
[ "$MAP_GIVEN" = 0 ] || MAPF="$MAP_FILE"
# The gateway requires keys (invariant 50): a run that would leave none is refused.
[ -n "$SPEC" ] \
  || die "the gateway requires client keys and this run would leave none. Give --client-keys-file, or deploy (or run identity/mint.sh) to mint them. $NOTHING"
# Keys the deploy minted are bound by the map it minted, and by nothing else.
if [ "$SECRET_MINTED" = 1 ] && [ "$KEYS_GIVEN$MAP_GIVEN" != 00 ] && [ "$KEYS_GIVEN$MAP_GIVEN" != 11 ]; then
  die "the client keys on this cluster were minted by a deploy, and the map it wrote binds those keys only. Give --client-keys-file and --identity-map-file together. $NOTHING"
fi

say "the gateway image reads the files first"
identity_check "$IMAGE" "$SPEC" "$MAPF"
note "$IMAGE read $CHECK_KEYS client key(s) and $( [ "$CHECK_MAP" = 1 ] && echo 'an identity map' || echo 'no identity map'), with no network, and refused nothing"

# ---- only now is anything written ----------------------------------------------------
# The keys, on stdin: a JSON body built here and handed to kubectl, never an argument.
if [ "$KEYS_GIVEN" = 1 ] && [ "$SPEC" != "$KEPT_SPEC" ]; then
  if [ "$SECRET_PRESENT" = 1 ]; then
    printf '%s' "$SPEC" | python3 -c '
import base64, json, sys
print(json.dumps({"data": {sys.argv[1]: base64.b64encode(sys.stdin.buffer.read()).decode()}}))' "$SECRET_KEY" \
      | k patch secret "$SECRET_NAME" --type merge --patch-file /dev/stdin >/dev/null \
      || die "could not replace the client keys in Secret $SECRET_NAME"
  else
    printf '%s' "$SPEC" | python3 -c '
import base64, json, sys
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                  "metadata": {"name": sys.argv[1], "namespace": sys.argv[2],
                               "labels": {"app.kubernetes.io/part-of": "agent-stack"}},
                  "data": {sys.argv[3]: base64.b64encode(sys.stdin.buffer.read()).decode()}}))' \
      "$SECRET_NAME" "$NS" "$SECRET_KEY" \
      | k create -f - >/dev/null \
      || die "could not create Secret $SECRET_NAME"
  fi
  note "client keys: $CHECK_KEYS key(s) in Secret $SECRET_NAME (never printed)"
  # Yours now: a deploy leaves a Secret without the minted label alone.
  if [ "$SECRET_MINTED" = 1 ]; then
    printf '{"metadata":{"labels":{"%s":null}}}' "$MINT_LABEL" \
      | k patch secret "$SECRET_NAME" --type merge --patch-file /dev/stdin >/dev/null \
      || die "could not take the minted label off Secret $SECRET_NAME"
    note "client keys: yours now; a deploy will not mint over them (felyx-client-key is left as it is)"
  fi
  secret_read
fi

if [ "$MAP_GIVEN" = 1 ]; then
  NEW_SHA="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$MAP_FILE")"
  if [ "$NEW_SHA" = "$MAP_SHA" ]; then
    note "identity map: the same as the one the cluster holds, left as is"
  else
    body="$(python3 -c '
import json, sys
m = open(sys.argv[1], "rb").read().decode("utf-8")
d = {sys.argv[2]: m, sys.argv[3]: sys.argv[4]}
if sys.argv[5] == "patch":
    print(json.dumps({"data": d}))
else:
    print(json.dumps({"apiVersion": "v1", "kind": "ConfigMap",
                      "metadata": {"name": sys.argv[6], "namespace": sys.argv[7],
                                   "labels": {"app.kubernetes.io/part-of": "agent-stack"}},
                      "data": d}))' "$MAP_FILE" "$MAP_KEY" "$MAP_PATH_KEY" "$MAP_DIR/$MAP_KEY" \
      "$( [ -n "$MAP_SHA" ] && echo patch || echo create )" "$MAP_CONFIGMAP" "$NS")"
    if [ -n "$MAP_SHA" ]; then
      printf '%s' "$body" | k patch configmap "$MAP_CONFIGMAP" --type merge --patch-file /dev/stdin >/dev/null \
        || die "could not replace the identity map in ConfigMap $MAP_CONFIGMAP"
    else
      printf '%s' "$body" | k create -f - >/dev/null || die "could not create ConfigMap $MAP_CONFIGMAP"
    fi
    note "identity map: in ConfigMap $MAP_CONFIGMAP, read only for the gateway at $MAP_DIR/$MAP_KEY"
    cm_read
  fi
fi

# ---- the gateway rolls exactly when what it reads changed ------------------------------
ANN_MAP_WANT=off
[ -z "$MAP_SHA" ] || ANN_MAP_WANT="$MAP_SHA"
ANN_KEYS_WANT=off
[ "$SECRET_PRESENT" = 0 ] || ANN_KEYS_WANT="$SECRET_RV"
ROLLED=0
if [ "$ANN_MAP_WANT" != "$LIVE_ANN_MAP" ] || [ "$ANN_KEYS_WANT" != "$LIVE_ANN_KEYS" ]; then
  say "rolling the gateway onto what it now reads"
  k patch deployment tokenfuse-gateway --type merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"$ANN_MAP\":\"$ANN_MAP_WANT\",\"$ANN_KEYS\":\"$ANN_KEYS_WANT\"}}}}}" >/dev/null \
    || die "could not patch tokenfuse-gateway's pod template"
  ROLLED=1
fi
k rollout status deployment/tokenfuse-gateway --timeout=180s >/dev/null \
  || die "tokenfuse-gateway did not roll out. kubectl -n $NS describe deployment tokenfuse-gateway"

# The pod that carries what this run set, and what it says it read at start.
pod="$(k get pods -l app=tokenfuse-gateway -o json | python3 -c '
import json, sys
want = {sys.argv[1]: sys.argv[2], sys.argv[3]: sys.argv[4]}
best = None
for p in json.load(sys.stdin)["items"]:
    m = p["metadata"]
    ann = m.get("annotations") or {}
    if m.get("deletionTimestamp") or p.get("status", {}).get("phase") != "Running":
        continue
    if any((ann.get(k) or "off") != v for k, v in want.items()):
        continue
    if best is None or m.get("creationTimestamp", "") > best[0]:
        best = (m.get("creationTimestamp", ""), m["name"])
print(best[1] if best else "")' "$ANN_MAP" "$ANN_MAP_WANT" "$ANN_KEYS" "$ANN_KEYS_WANT")"
[ -n "$pod" ] || die "no running tokenfuse-gateway pod carries what this run set. kubectl -n $NS get pods -l app=tokenfuse-gateway"
start="$(k logs "$pod" -c gateway --limit-bytes=262144 2>/dev/null || true)"
seen_keys="$(sed -n 's/^client auth: ON (\([0-9]*\) key(s)).*/\1/p' <<<"$start" | head -n 1)"
seen_map="$(grep -c '^identity map: ON (' <<<"$start" || true)"
if [ -n "$seen_keys" ] && [ "$seen_keys" != "$CHECK_KEYS" ]; then
  die "pod $pod reports $seen_keys client key(s) and this run left $CHECK_KEYS. Something other than this script sets TOKENFUSE_CLIENT_KEYS: kubectl -n $NS get deployment tokenfuse-gateway -o yaml"
elif [ -z "$seen_keys" ] && [ "$CHECK_KEYS" -gt 0 ]; then
  if [ "$ROLLED" = 1 ]; then die "pod $pod started without client auth, and this run left $CHECK_KEYS key(s). kubectl -n $NS logs $pod -c gateway"; fi
  note "pod $pod: its start-up lines are no longer in its log, so the keys it reports could not be read again"
fi
if [ "$seen_map" -gt 0 ] && [ "$CHECK_MAP" = 0 ]; then
  die "pod $pod reads an identity map and this run left none. kubectl -n $NS get deployment tokenfuse-gateway -o yaml"
elif [ "$seen_map" = 0 ] && [ "$CHECK_MAP" = 1 ]; then
  if [ "$ROLLED" = 1 ]; then die "pod $pod started without the identity map this run left. kubectl -n $NS logs $pod -c gateway"; fi
  note "pod $pod: its start-up lines are no longer in its log, so the map it reads could not be read again"
fi

say "the gateway's identity"
if [ "$ROLLED" = 1 ]; then note "rolled: pod $pod started on what this run left"; else note "unchanged: pod $pod already runs on it, nothing was rolled"; fi
if [ "$CHECK_KEYS" -gt 0 ]; then
  note "client keys: $CHECK_KEYS, from Secret $SECRET_NAME. Every metered call must send"
  note "  x-fuse-key: <its secret>     and, where the map binds its key, an agent id it may speak as:"
  note "  x-fuse-agent-id: agent://<domain>/<name>"
  note "Felyx sends the key in Secret felyx-client-key; the drills send none and are refused 401."
fi
if [ "$CHECK_MAP" = 1 ]; then
  note "identity map: on, sha256 $MAP_SHA, from ConfigMap $MAP_CONFIGMAP"
else
  note "identity map: off"
fi
