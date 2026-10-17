# The gateway's client keys when the operator brought none: minted here, once, and
# never rewritten. Sourced by deploy.sh, cloud/gcp/deploy-gcp.sh,
# cloud/aws/deploy-aws.sh and identity/mint.sh, not run. CLAUDE.md invariant 50.
#
# @decided 2026-10-17 (paraphrased): close the agent-security findings of the
# 2026-10-17 review, starting with the defaults. The gateway never answers an
# unnamed caller: manifests/10-planes.yaml reads TOKENFUSE_CLIENT_KEYS from the
# Secret gateway-client-keys and that reference is not optional, so a gateway with
# no keys does not start. A cluster given no files by identity/up.sh gets two keys
# from here, the same two stack-single's installer mints (its invariant 35):
#
#   felyx   the console's copilot, bound to exactly agent://<td>/genaryx/felyx, in
#           unit `console`; its secret is also in the Secret felyx-client-key, the
#           one object the console reads it from (20-console.yaml)
#   agents  the operator's own agents, bound to agent://<td>/agents/*, in unit
#           `agents`; its secret is written to a file on this machine, 0600, whose
#           PATH the deploy prints and never the value
#
# <td> is TRAILRYX_TRUST_DOMAIN as stack-wiring holds it after the deploy's
# --trust-domain patch, the domain the console already names Felyx in. The agents'
# pattern stops short of Felyx's id, so an agent cannot speak as the copilot. The
# map carries a unit each and no budget: it binds and attributes, and a budget is
# the operator's decision.
#
# WHAT A RUN DOES, by what the cluster holds:
#   nothing                     mints both secrets, creates the Secret (labelled
#                               taipanbox.dev/identity=minted), felyx-client-key
#                               and the map's ConfigMap
#   the minted Secret           keeps every secret byte for byte; puts back
#                               felyx-client-key or the map if one was deleted;
#                               rewrites the map only when the trust domain moved
#   the operator's Secret       nothing at all: identity/up.sh owns it
#   a map and no Secret         refuses: a map's bindings name keys the cluster
#                               does not have, and the gateway needs keys
# Then it writes onto the gateway's pod template the map's sha256 and the Secret's
# resourceVersion, the two annotations identity/up.sh and verify.sh already use,
# and onto the console's the felyx-client-key resourceVersion, so each rolls
# exactly when what it reads changed (a Secret change restarts no pod).
#
# Every document goes to `kubectl create -f -` or `patch --patch-file /dev/stdin`
# on stdin: no secret is on a command line, and never `apply`, whose
# last-applied annotation would keep a second copy of every value.
#
#   . "$ROOT/lib/gen.sh" || die "no lib/gen.sh in $ROOT"
#   . "$ROOT/lib/identity-mint.sh" || die "no lib/identity-mint.sh in $ROOT"
#   identity_mint_settle "$ROOT/agent-key"   # after `apply -k` and the trust-domain patch
#
# Needs in scope, from the caller: die() and k_ (its kubectl runner, given ONE
# string, as the deploy scripts' runner over ssh is). It sources the one generator
# itself (CLAUDE.md invariant 41), so a caller cannot reach the mint without it.
IDM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$IDM_ROOT/lib/gen.sh" || return 1
# identity-mint: begin
# The deploy scripts print with say(); a note is one indented line, as identity/up.sh prints it.
if ! declare -F note >/dev/null; then note() { printf '   %s\n' "$*"; }; fi
IDM_NS=agent-stack
IDM_SECRET=gateway-client-keys
IDM_SECRET_KEY=client_keys
IDM_FELYX_SECRET=felyx-client-key
IDM_FELYX_KEY=client_key
IDM_CM=gateway-identity-map
IDM_MAP_KEY=identity.json
IDM_PATH_KEY=map_path
IDM_MAP_DIR=/etc/tokenfuse/identity
IDM_LABEL=taipanbox.dev/identity
IDM_ANN_MAP=taipanbox.dev/identity-map-sha256
IDM_ANN_KEYS=taipanbox.dev/client-keys-version
IDM_ANN_FELYX=taipanbox.dev/felyx-key-version
IDM_MINTED=0       # 1 when the gateway runs keys this settle minted or kept as minted
IDM_DOMAIN=""      # the trust domain the minted map names

# DOMAIN: the map, one line, on stdout. No secret in it.
identity_mint_map() {
  printf '{"units":[{"id":"console","name":"Felyx, the console copilot"},{"id":"agents","name":"The operator agents"}],"keys":[{"key_id":"felyx","unit":"console","agents":["agent://%s/genaryx/felyx"]},{"key_id":"agents","unit":"agents","agents":["agent://%s/agents/*"]}]}' "$1" "$1"
}

identity_mint_sha() { # the sha256 of stdin, hex
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

# KEYFILE: settle the gateway's client keys, then roll what reads them. Prints notes
# and never a secret.
identity_mint_settle() {
  local keyfile="$1" have domain label spec felyx="" agents="" entry id rest want cur esc rv sha t frv
  have="$(k_ "-n $IDM_NS get secret/$IDM_SECRET configmap/$IDM_CM secret/$IDM_FELYX_SECRET --ignore-not-found -o name")" \
    || die "could not ask the cluster whether the gateway's client keys exist, so the identity step did not run"
  domain="$(k_ "-n $IDM_NS get configmap stack-wiring -o jsonpath='{.data.TRAILRYX_TRUST_DOMAIN}'")" \
    || die "could not read TRAILRYX_TRUST_DOMAIN from stack-wiring, which the minted keys are bound to"
  case "$domain" in
    ""|*[!A-Za-z0-9.-]*) die "TRAILRYX_TRUST_DOMAIN in stack-wiring is '$domain', not a name of A-Z a-z 0-9 . and -: the keys this deploy mints are bound to agent ids in it" ;;
  esac
  IDM_DOMAIN="$domain"
  IDM_MINTED=0

  case "$have" in
    *"secret/$IDM_SECRET"*)
      label="$(k_ "-n $IDM_NS get secret $IDM_SECRET -o jsonpath='{.metadata.labels.taipanbox\.dev/identity}'")" \
        || die "could not read the labels of Secret $IDM_SECRET"
      if [ "$label" != minted ]; then
        note "client keys: Secret $IDM_SECRET is the operator's (identity/up.sh), left as it is"
        return 0
      fi
      spec="$(k_ "-n $IDM_NS get secret $IDM_SECRET -o jsonpath='{.data.$IDM_SECRET_KEY}'" | base64 --decode)" \
        || die "could not read Secret $IDM_SECRET"
      rest="$spec,"
      while [ -n "$rest" ]; do
        entry="${rest%%,*}"
        rest="${rest#*,}"
        id="${entry##*:}"
        case "$id" in
          felyx) [ -z "$felyx" ] || felyx=bad; [ "$felyx" = bad ] || felyx="${entry%:*}" ;;
          agents) [ -z "$agents" ] || agents=bad; [ "$agents" = bad ] || agents="${entry%:*}" ;;
          *) felyx=bad ;;
        esac
      done
      if [ -z "$felyx" ] || [ -z "$agents" ] || [ "$felyx" = bad ] || [ "$agents" = bad ]; then
        die "Secret $IDM_SECRET is labelled $IDM_LABEL=minted and does not hold exactly the two keys this deploy mints (felyx and agents), so it was edited by hand. Remove the label to make it yours, or delete it and deploy again to mint new keys. Nothing was changed."
      fi
      ;;
    *)
      case "$have" in
        *"configmap/$IDM_CM"*)
          die "ConfigMap $IDM_CM holds an identity map and the cluster has no client keys, which the gateway requires. Give both files to identity/up.sh, or delete the ConfigMap and deploy again to mint keys and a map. Nothing was changed." ;;
      esac
      case "$have" in
        *"secret/$IDM_FELYX_SECRET"*)
          felyx="$(k_ "-n $IDM_NS get secret $IDM_FELYX_SECRET -o jsonpath='{.data.$IDM_FELYX_KEY}'" | base64 --decode)" \
            || die "could not read Secret $IDM_FELYX_SECRET" ;;
        *) felyx="$(gen 40)" || die "could not mint Felyx's client key" ;;
      esac
      agents="$(gen 40)" || die "could not mint the agents' client key"
      [ "$felyx" != "$agents" ] || die "the two minted keys came out the same; deploy again"
      printf '{"apiVersion":"v1","kind":"Secret","type":"Opaque","metadata":{"name":"%s","namespace":"%s","labels":{"app.kubernetes.io/part-of":"agent-stack","%s":"minted"}},"stringData":{"%s":"%s:felyx,%s:agents"}}\n' \
        "$IDM_SECRET" "$IDM_NS" "$IDM_LABEL" "$IDM_SECRET_KEY" "$felyx" "$agents" \
        | k_ "-n $IDM_NS create -f -" >/dev/null \
        || die "could not create Secret $IDM_SECRET"
      note "client keys: minted for Felyx and for your agents, in Secret $IDM_SECRET (never printed)"
      ;;
  esac
  IDM_MINTED=1

  # Felyx's own Secret, the one object the console reads its key from.
  case "$have" in
    *"secret/$IDM_FELYX_SECRET"*)
      [ "$(k_ "-n $IDM_NS get secret $IDM_FELYX_SECRET -o jsonpath='{.data.$IDM_FELYX_KEY}'" | base64 --decode)" = "$felyx" ] \
        || die "Secret $IDM_FELYX_SECRET does not hold the key Secret $IDM_SECRET binds to Felyx, so the console's copilot would be refused 401. Delete $IDM_FELYX_SECRET and deploy again. Nothing was changed." ;;
    *)
      printf '{"apiVersion":"v1","kind":"Secret","type":"Opaque","metadata":{"name":"%s","namespace":"%s","labels":{"app.kubernetes.io/part-of":"agent-stack","%s":"minted"}},"stringData":{"%s":"%s"}}\n' \
        "$IDM_FELYX_SECRET" "$IDM_NS" "$IDM_LABEL" "$IDM_FELYX_KEY" "$felyx" \
        | k_ "-n $IDM_NS create -f -" >/dev/null \
        || die "could not create Secret $IDM_FELYX_SECRET" ;;
  esac

  # The map, rebuilt from the trust domain on every run: the same bytes, unless the
  # domain moved. It holds no secret.
  want="$(identity_mint_map "$domain")"
  esc="$(printf '%s' "$want" | sed 's/"/\\"/g')"
  case "$have" in
    *"configmap/$IDM_CM"*)
      cur="$(k_ "-n $IDM_NS get configmap $IDM_CM -o jsonpath='{.data.identity\.json}'")" \
        || die "could not read ConfigMap $IDM_CM"
      if [ "$cur" != "$want" ]; then
        printf '{"data":{"%s":"%s","%s":"%s/%s"}}\n' "$IDM_MAP_KEY" "$esc" "$IDM_PATH_KEY" "$IDM_MAP_DIR" "$IDM_MAP_KEY" \
          | k_ "-n $IDM_NS patch configmap $IDM_CM --type merge --patch-file /dev/stdin" >/dev/null \
          || die "could not update the identity map in ConfigMap $IDM_CM"
        note "identity map: rebound to the trust domain $domain"
      fi
      ;;
    *)
      printf '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"%s","namespace":"%s","labels":{"app.kubernetes.io/part-of":"agent-stack","%s":"minted"}},"data":{"%s":"%s","%s":"%s/%s"}}\n' \
        "$IDM_CM" "$IDM_NS" "$IDM_LABEL" "$IDM_MAP_KEY" "$esc" "$IDM_PATH_KEY" "$IDM_MAP_DIR" "$IDM_MAP_KEY" \
        | k_ "-n $IDM_NS create -f -" >/dev/null \
        || die "could not create ConfigMap $IDM_CM"
      note "identity map: felyx bound to agent://$domain/genaryx/felyx, agents to agent://$domain/agents/*"
      ;;
  esac

  # The agents' key, in a file on this machine for the operator to hand out.
  if [ ! -f "$keyfile" ] || [ "$(cat "$keyfile")" != "$agents" ]; then
    ( umask 077; printf '%s\n' "$agents" >"$keyfile.tmp" ) || die "could not write the agents' key to $keyfile"
    mv -f "$keyfile.tmp" "$keyfile" || die "could not put the agents' key in place at $keyfile"
  fi
  chmod 0600 "$keyfile" || die "could not set the mode of $keyfile"
  agents=""
  felyx=""

  # What the gateway and the console read, onto their pod templates, so each rolls
  # exactly when it changed. The values are a digest and two versions, no secret.
  sha="$(printf '%s' "$want" | identity_mint_sha)"
  rv="$(k_ "-n $IDM_NS get secret $IDM_SECRET -o jsonpath='{.metadata.resourceVersion}'")" \
    || die "could not read the version of Secret $IDM_SECRET"
  t="$(k_ "-n $IDM_NS get deployment tokenfuse-gateway -o jsonpath='{.spec.template.metadata.annotations.taipanbox\.dev/identity-map-sha256} {.spec.template.metadata.annotations.taipanbox\.dev/client-keys-version}'")" \
    || die "could not read the gateway's pod template"
  if [ "$t" != "$sha $rv" ]; then
    k_ "-n $IDM_NS patch deployment tokenfuse-gateway --type merge -p '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"$IDM_ANN_MAP\":\"$sha\",\"$IDM_ANN_KEYS\":\"$rv\"}}}}}'" >/dev/null \
      || die "could not roll the gateway onto its client keys"
  fi
  if [ -n "$(k_ "-n $IDM_NS get deployment genaryx-console --ignore-not-found -o name")" ]; then
    frv="$(k_ "-n $IDM_NS get secret $IDM_FELYX_SECRET -o jsonpath='{.metadata.resourceVersion}'")" \
      || die "could not read the version of Secret $IDM_FELYX_SECRET"
    t="$(k_ "-n $IDM_NS get deployment genaryx-console -o jsonpath='{.spec.template.metadata.annotations.taipanbox\.dev/felyx-key-version}'")" \
      || die "could not read the console's pod template"
    if [ "$t" != "$frv" ]; then
      k_ "-n $IDM_NS patch deployment genaryx-console --type merge -p '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"$IDM_ANN_FELYX\":\"$frv\"}}}}}'" >/dev/null \
        || die "could not roll the console onto Felyx's client key"
    fi
  fi
}

# What the end of a deploy says about the minted keys: the file and the ids, never a
# secret. Says nothing on a cluster running the operator's own keys.
identity_mint_note() { # KEYFILE
  [ "$IDM_MINTED" = 1 ] || return 0
  printf '\nClient keys are ON, minted by this deploy because identity/up.sh was given no files.\n'
  printf 'Your agents now need a key: every call to the gateway carries\n\n'
  printf '    x-fuse-key       the secret in %s (it is not printed here)\n' "$1"
  printf '    x-fuse-agent-id  an id under agent://%s/agents/, such as agent://%s/agents/support-bot\n' "$IDM_DOMAIN" "$IDM_DOMAIN"
  printf '    x-fuse-run-id    its run, as before\n\n'
  printf 'A call with no key, or one the gateway does not hold, is refused 401, and the key\n'
  printf 'speaking as an id outside agents/ is refused 403 identity_mismatch. To read it\n'
  printf 'again on another machine: kubectl -n %s get secret %s -o jsonpath=%s | base64 --decode\n' "$IDM_NS" "$IDM_SECRET" "'{.data.client_keys}'"
  printf '(the entry ending :agents). To give each agent its own key and unit, run\n'
  printf 'identity/up.sh with a keys file and an identity map, both together.\n'
}
# identity-mint: end
