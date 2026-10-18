# The gateway's provider key (CLAUDE.md invariant 53). Sourced by deploy.sh,
# cloud/gcp/deploy-gcp.sh and cloud/aws/deploy-aws.sh, not run. It needs k_ and die
# from the caller, and note when the caller has none.
#
# The gateway holds the provider key and reads it from a file it mounts (10-planes.yaml,
# TOKENFUSE_UPSTREAM_KEY_FILE). This makes that Secret, gateway-upstream-key, from the
# operator's file. Three rules, each one a way a provider key used to reach an agent:
#
#   the key goes on stdin, never an argument: the document is printed by this shell
#   (a builtin, so no process list shows it) and piped to `kubectl create -f -`
#   the Secret is created once and never rewritten: a re-run keeps it, and says so
#   a key that is not a plain token is refused before anything is written, because it
#   goes into a JSON document unescaped
#
# Replacing the key is a deliberate act: delete the Secret, deploy with the new file, and
# restart the gateway, which reads its file once at start (TOKENFUSE_UPSTREAM_KEY_FILE).

if ! declare -F note >/dev/null; then note() { printf '   %s\n' "$*"; }; fi

# upstream_key_settle KEYFILE: makes gateway-upstream-key from KEYFILE when the cluster has
# none. Prints the outcome, never the key.
upstream_key_settle() {
  local keyfile="$1" have value
  have="$(k_ "-n agent-stack get secret gateway-upstream-key --ignore-not-found -o name")" \
    || die "could not ask the cluster whether gateway-upstream-key exists"
  case "$have" in
    *secret/gateway-upstream-key*)
      if [ -n "$keyfile" ]; then
        note "provider key: Secret gateway-upstream-key already exists and is kept; the file given was not read (to replace the key: delete the Secret, deploy with the new file, restart the gateway)"
      else
        note "provider key: Secret gateway-upstream-key exists and is kept"
      fi
      return 0 ;;
  esac
  [ -s "$keyfile" ] || die "--anthropic-key-file $keyfile is missing or empty"
  value="$(tr -d '\r\n' < "$keyfile")"
  case "$value" in
    ""|*[!A-Za-z0-9._-]*) die "the provider key in $keyfile is empty or holds a character a provider key does not have; refused before anything was written" ;;
  esac
  printf '{"apiVersion":"v1","kind":"Secret","type":"Opaque","metadata":{"name":"gateway-upstream-key","namespace":"agent-stack","labels":{"app.kubernetes.io/part-of":"agent-stack"}},"stringData":{"anthropic_key":"%s"}}\n' "$value" \
    | k_ "-n agent-stack create -f -" >/dev/null \
    || die "could not create Secret gateway-upstream-key"
  value=""
  note "provider key: Secret gateway-upstream-key made from $keyfile (never printed); the gateway reads it when it starts"
}
