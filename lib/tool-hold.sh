# The tool hold (CLAUDE.md invariant 83). Sourced by deploy.sh, cloud/gcp/deploy-gcp.sh,
# cloud/aws/deploy-aws.sh and tool-hold/agents.sh, not run.
#
# A tool call of an agent nothing grants is held for a person, on a cluster where nobody chose
# anything. Model calls pass, and only a grant lifts the hold: a restriction on the agent never
# does. That is wardryx 2.6.0's `when_no_grant: hold`, on one rule with target "*", so an agent
# id with no agent:// scheme cannot walk past it.
#
# WHERE IT LIVES
#
# In the ConfigMap wardryx-tool-hold, key tool-hold.yaml, which manifests/10-planes.yaml projects
# into wardryx's policy directory beside wardryx-policy. Not in wardryx-policy, because every
# launcher run applies that ConfigMap from this tree and would put the file back over any edit
# (the reason wardryx-typed-hold is a ConfigMap of its own). Not in the kustomization either: a
# floor a plain `apply -k` installs is a floor nobody was asked about. A launcher writes it, after
# it has asked the cluster's own history, and `kubectl apply -k` by hand leaves the hold off.
#
# The rule and the grants this stack needs for its own checks are one block, because a wardryx
# older than 2.6.0 refuses both keys at load, so leaving the hold out has to leave a directory
# that wardryx can read. wardryx reads its policy at start, so a run that changes the block
# restarts wardryx. A grant written with tool-hold/agents.sh goes through PUT /v1/policies
# instead: in force with no restart, and on the record.
#
# The block's body is stack-single's, rule for rule and name for name, and a gate in estate-gates
# compares the two. grant-install-check is there for that reason as well: nothing in this
# repository calls the broker as that identity today, and the grant names one tool and one id.
#
# THE SWITCH
#
# TOOL_HOLD (or --tool-hold) is empty, 0 or 1. Empty is on, unless this cluster said 0 before.
# 0 leaves the ConfigMap in place with no key in it. An empty ConfigMap projects no file, and it
# is how the next run knows the operator said 0, since a launcher here has no .env to keep it in.
# 1 is the operator's decision to turn it on over whatever the question below finds.
#
# A CLUSTER WITH A HISTORY IS ASKED FIRST
#
# Before anything is applied, wardryx's own replay puts the cluster's recorded decisions to the
# policy this run would serve: this tree's starter policy, the block, and what is in the store.
# If an agent outside the seeds would be held, the run stops with the list and applies nothing,
# so nothing that worked yesterday stops without a word. The same goes for a history that could
# not be asked. A new cluster has no history, and a cluster that carries the block was asked.
#
# The replay is a Job of the wardryx image these manifests pin, because the wardryx this cluster
# runs may be older than the question: `-format json` and the candidate report are 2.6.0's. It
# mounts the events claim read only, and it and the ConfigMap that carries its candidate are
# deleted before this returns.
#
# Needs in scope, from the caller: die(), k_ (its kubectl runner, given ONE string), and ROOT.
if ! declare -F die >/dev/null; then die() { printf '!! %s\n' "$*" >&2; exit 1; }; fi
if ! declare -F note >/dev/null; then note() { printf '   %s\n' "$*"; }; fi
if ! declare -F say >/dev/null; then say() { printf '\n>> %s\n' "$*"; }; fi

TOOL_HOLD_CM="wardryx-tool-hold"
TOOL_HOLD_ASK="wardryx-tool-hold-ask"
TOOL_HOLD_ON=1
TOOL_HOLD_SAID=""
TOOL_HOLD_STATE="absent"
TOOL_HOLD_WHY=""
TOOL_HOLD_SECONDS="${TOOL_HOLD_SECONDS:-3}"

tool_hold_check() { # WORD: refused before anything is installed
  case "${1:-}" in
    '' | 0 | 1) return 0 ;;
    *) printf '   --tool-hold takes 1 (on) or 0 (off), not "%s".\n' "$1" >&2; return 1 ;;
  esac
}
# The block, and what the cluster holds of it. A read that fails is not "absent": that would
# take a cluster nobody could reach for a new one.
tool_hold_current() { # prints the key tool-hold.yaml of the ConfigMap
  k_ "-n agent-stack get configmap $TOOL_HOLD_CM -o jsonpath='{.data.tool-hold\.yaml}'"
}
tool_hold_state() { # prints absent, on or off
  local name body
  name="$(k_ "-n agent-stack get configmap $TOOL_HOLD_CM --ignore-not-found -o name")" \
    || die "could not read ConfigMap $TOOL_HOLD_CM. Nothing was applied."
  [ -n "$name" ] || { printf absent; return 0; }
  body="$(tool_hold_current)" || die "could not read ConfigMap $TOOL_HOLD_CM. Nothing was applied."
  if [ -n "$body" ]; then printf on; else printf off; fi
}
tool_hold_resolve() { # reads TOOL_HOLD and the cluster; sets TOOL_HOLD_ON, _SAID and _STATE
  TOOL_HOLD_SAID="${TOOL_HOLD:-}"
  TOOL_HOLD_STATE="$(tool_hold_state)"
  case "$TOOL_HOLD_SAID" in
    1) TOOL_HOLD_ON=1 ;;
    0) TOOL_HOLD_ON=0 ;;
    *) if [ "$TOOL_HOLD_STATE" = off ]; then TOOL_HOLD_ON=0; else TOOL_HOLD_ON=1; fi ;;
  esac
}
tool_hold_domain() { # the trust domain, or nothing while it is the placeholder
  local td="${TRUST_DOMAIN:-}"
  [ -n "$td" ] || td="$(k_ "-n agent-stack get configmap stack-wiring --ignore-not-found -o jsonpath={.data.TRAILRYX_TRUST_DOMAIN}" 2>/dev/null || true)"
  case "$td" in '' | set-me.invalid) return 0 ;; esac
  printf '%s' "$td"
}
# Whether this cluster reads the web through the broker. manifests/47-scopyx.yaml is applied by
# hand, so two things say yes: a scopyx runs here, or the block already carries the grant. An
# operator who adds scopyx later gets the grant on the next run, or with agents.sh agent-allow.
tool_hold_web_wanted() {
  [ -n "$(tool_hold_domain)" ] || return 1
  if grep -q '^- name: grant-operator-web$' <<<"$(tool_hold_current 2>/dev/null || true)"; then return 0; fi
  [ -n "$(k_ "-n agent-stack get deployment scopyx --ignore-not-found -o name" 2>/dev/null || true)" ]
}
# How a grant may be reached. The broker says client-key for a static key, so leaving that out
# is what keeps a static key from borrowing a granted name. `none` stays in because scopyx asks
# wardryx about the same agent's fetch and sends no source at all, so a grant that took it out
# would deny the read the grant is for.
tool_hold_sources() { # [static]: the identity sources of a grant, comma and space
  case "${1:-}" in
    static) printf 'agent-token, client-key, none' ;;
    *) printf 'agent-token, none' ;;
  esac
}
# grant-install-check names client-key: that identity comes with the broker's own static key,
# and a grant that asked for an agent token there would deny it.
tool_hold_block() {
  printf '%s\n' \
    '# tool-hold: begin (managed by lib/tool-hold.sh; TOOL_HOLD, invariant 83)' \
    '- name: tool-hold' \
    '  target: "*"' \
    '  when_no_grant: hold' \
    '- name: grant-drills' \
    '  target: agent://mockryx.local/*' \
    '  grant_tool: ["*"]' \
    '- name: grant-install-check' \
    '  target: agent://local.invalid/install-check' \
    '  grant_tool: [ask]' \
    '  require_identity_source: [client-key]' \
    '  deny_if_chain_unproven: true'
  if tool_hold_web_wanted; then
    printf '%s\n' \
      '- name: grant-operator-web' \
      "  target: agent://$(tool_hold_domain)/agents/operator" \
      '  grant_tool: [fetch_url, browse]' \
      "  require_identity_source: [$(tool_hold_sources)]" \
      '  deny_if_chain_unproven: true'
  fi
  printf '%s\n' '# tool-hold: end'
}
tool_hold_document() { # stdin: the block. Prints the ConfigMap that carries it.
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: { name: %s, namespace: agent-stack, labels: { app: wardryx, plane: policy } }\ndata:\n  tool-hold.yaml: |\n' "$TOOL_HOLD_CM"
  sed 's/^/    /'
}
tool_hold_empty_document() { # the same ConfigMap with no key: what says the operator left it out
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: { name: %s, namespace: agent-stack, labels: { app: wardryx, plane: policy } }\ndata: {}\n' "$TOOL_HOLD_CM"
}
tool_hold_image() { # the wardryx these manifests pin: the one pin, read and never repeated
  sed -nE 's/^ +image: (ghcr\.io\/taipanbox\/wardryx:v[^ ]+@sha256:[0-9a-f]{64})$/\1/p' "$ROOT/manifests/10-planes.yaml" | sed -n 1p
}
tool_hold_starter() { # the starter policy this tree applies, at the depth a ConfigMap's block scalar wants
  awk '/^  name: wardryx-policy$/ { c = 1 }
       c && /^  policy\.yaml: \|$/ { on = 1; next }
       on && !/^    / && !/^$/ { exit }
       on { print }' "$ROOT/manifests/00-base.yaml"
}
# tool-hold/wardryx.py, in the console's pod. That pod holds the admin key already, as
# WARDRYX_ADMIN_KEY from the Secret stack-keys, and already reaches wardryx, so the key stays in
# the cluster and is on no command line: the program goes in on stdin and the request after it.
tool_hold_pod() { # VERB [BASE64]
  k_ "-n agent-stack exec -i deploy/genaryx-console -c console -- python3 - $*" <"$ROOT/tool-hold/wardryx.py"
}
tool_hold_b64() { base64 | tr -d '\n'; }
tool_hold_ask_document() { # STORED_JSON: the candidate, then the Job that reads it
  local image stored="${1:-}"
  image="$(tool_hold_image)"
  [ -n "$image" ] || die "manifests/10-planes.yaml pins no wardryx by tag and digest, so nothing can be asked. Nothing was applied."
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: { name: %s, namespace: agent-stack, labels: { app: %s, plane: policy } }\ndata:\n  policy.yaml: |\n' "$TOOL_HOLD_ASK" "$TOOL_HOLD_ASK"
  tool_hold_starter
  printf '  tool-hold.yaml: |\n'
  tool_hold_block | sed 's/^/    /'
  # What agent-allow wrote is in force too, and in no file. A wardryx that did not answer leaves
  # this key out, which errs toward listing more.
  if [ -n "$stored" ] && [ "$stored" != "[]" ]; then
    printf '  stored.json: |\n    %s\n' "$stored"
  fi
  cat <<YAML
---
apiVersion: batch/v1
kind: Job
metadata: { name: $TOOL_HOLD_ASK, namespace: agent-stack, labels: { app: $TOOL_HOLD_ASK, plane: policy } }
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 240
  ttlSecondsAfterFinished: 600
  template:
    metadata: { labels: { app: $TOOL_HOLD_ASK, plane: policy } }
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, supplementalGroups: [10001], seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: replay
          image: $image
          imagePullPolicy: IfNotPresent
          args: ["replay", "-events", "/var/lib/stack/events/wardryx.ndjson", "-archive", "/var/lib/stack/events/wardryx-policy-archive", "-policy", "/candidate", "-format", "json"]
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { memory: 512Mi }
          volumeMounts:
            - { name: events, mountPath: /var/lib/stack/events, readOnly: true }
            - { name: candidate, mountPath: /candidate, readOnly: true }
      volumes:
        - name: events
          persistentVolumeClaim: { claimName: stack-events, readOnly: true }
        - name: candidate
          configMap: { name: $TOOL_HOLD_ASK }
YAML
}
tool_hold_ask_clear() {
  k_ "-n agent-stack delete job $TOOL_HOLD_ASK --ignore-not-found" >/dev/null 2>&1 || true
  k_ "-n agent-stack delete configmap $TOOL_HOLD_ASK --ignore-not-found" >/dev/null 2>&1 || true
}
# Puts the cluster's own decisions to the policy this run would serve. Writes DIR/report.json when
# wardryx could be asked, and sets TOOL_HOLD_WHY when it could not.
tool_hold_ask() { # DIR
  local d="$1" stored="" i=0 done_="" why
  stored="$(tool_hold_pod store 2>/dev/null)" || stored=""
  tool_hold_ask_clear
  if ! tool_hold_ask_document "$stored" | k_ "-n agent-stack apply -f -" >/dev/null 2>"$d/apply.err"; then
    TOOL_HOLD_WHY="$(head -c 300 "$d/apply.err" | tr -d '\r' | sed -n 1p)"
    tool_hold_ask_clear
    return 1
  fi
  while [ "$i" -lt 80 ]; do
    done_="$(k_ "-n agent-stack get job $TOOL_HOLD_ASK -o jsonpath={.status.succeeded}/{.status.failed}" 2>/dev/null || true)"
    [ -z "$done_" ] || [ "$done_" = / ] || break
    i=$((i + 1))
    sleep "$TOOL_HOLD_SECONDS"
  done
  # A replay that finds a row its own version no longer reproduces exits 1 and still prints the
  # report, so the report is what is read, and the count of what it could not ask decides.
  k_ "-n agent-stack logs job/$TOOL_HOLD_ASK" >"$d/report.json" 2>"$d/report.err" || true
  tool_hold_ask_clear
  if [ -z "$(tool_hold_count total "$d/report.json")" ] || [ -z "$(tool_hold_count unexamined "$d/report.json")" ]; then
    why="$(cat "$d/report.json" "$d/report.err" | head -c 300 | tr -d '\r' | sed -n 1p)"
    TOOL_HOLD_WHY="${why:-the Job left no report (status ${done_:-none})}"
    return 1
  fi
}
tool_hold_count() { # NAME FILE: one figure of the report
  sed -nE 's/^  "'"$1"'": ([0-9]+),?$/\1/p' "$2"
}
tool_hold_rows() { # FILE: what the report would hold, one tab-separated line each: agent, tool, calls, last
  awk '
    function text(line) { sub(/^ *"[a-z_]+": "/, "", line); sub(/",?$/, "", line); return line }
    /^  "would_hold": \[$/ { on = 1; next }
    on && /^  \]/ { on = 0 }
    on && /^      "agent_id": / { agent = text($0) }
    on && /^      "tool": / { tool = text($0) }
    on && /^      "calls": / { calls = $2; sub(/,$/, "", calls) }
    on && /^      "last": / { printf "%s\t%s\t%s\t%s\n", agent, tool, calls, text($0) }
  ' "$1" | LC_ALL=C tr -c '[:print:]\t\n' '?'
}
tool_hold_table() { # FILE: at most forty rows, because an agent id is whatever a caller wrote
  local agent tool calls last shown=0 all
  all="$(tool_hold_rows "$1")"
  printf '   %-6s  %-20s  %-24s  %s\n' CALLS 'LAST SEEN' TOOL AGENT
  while IFS=$'\t' read -r agent tool calls last; do
    shown=$((shown + 1))
    [ "$shown" -le 40 ] || continue
    printf '   %-6s  %-20s  %-24s  %s\n' "$calls" "${last%%.*}" "$tool" "$agent"
  done <<<"$all"
  [ "$shown" -le 40 ] || printf '   ... and %s more\n' "$((shown - 40))"
}
# The commands to paste. An agent id and a tool name are whatever a caller wrote, so a command
# is printed only for text that means nothing to a shell, and the row is counted otherwise.
tool_hold_commands() { # FILE
  local agent tool calls last prev="" tools="" left=0 printed=0
  while IFS=$'\t' read -r agent tool calls last; do
    if ! [[ "$agent" =~ ^agent://[A-Za-z0-9._~-]+(:[0-9]+)?(/[A-Za-z0-9._~:/-]*)?$ ]] || ! [[ "$tool" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
      left=$((left + 1))
      continue
    fi
    if [ "$agent" != "$prev" ]; then
      if [ -n "$prev" ] && [ "$printed" -lt 40 ]; then printf "     ./tool-hold/agents.sh agent-allow '%s' '%s' --why 'what it is for'\n" "$prev" "$tools"; printed=$((printed + 1)); fi
      prev="$agent"
      tools="$tool"
    else
      tools="$tools,$tool"
    fi
  done < <(tool_hold_rows "$1" | sort)
  if [ -n "$prev" ] && [ "$printed" -lt 40 ]; then printf "     ./tool-hold/agents.sh agent-allow '%s' '%s' --why 'what it is for'\n" "$prev" "$tools"; fi
  [ "$left" -eq 0 ] || printf '   %s row(s) have no command: no grant can name an id without agent://, and text a shell reads is not printed to paste.\n' "$left"
}
# Before anything is applied. Stops the run with the list, or returns with nothing changed.
tool_hold_guard() {
  local d rows="" total unexamined stop
  tool_hold_resolve
  [ "$TOOL_HOLD_ON" = 1 ] || return 0
  [ "$TOOL_HOLD_STATE" != on ] || return 0
  [ -n "$(k_ "-n agent-stack get deployment wardryx --ignore-not-found -o name")" ] || return 0
  say "this cluster has a history: asking what the tool hold would stop, before anything is applied"
  d="$(mktemp -d)" || die "could not make a temporary directory to ask in. Nothing was applied."
  TOOL_HOLD_WHY=""
  if tool_hold_ask "$d"; then
    rows="$(tool_hold_rows "$d/report.json")"
    total="$(tool_hold_count total "$d/report.json")"
    unexamined="$(tool_hold_count unexamined "$d/report.json")"
    if [ -z "$rows" ] && [ "$unexamined" = 0 ]; then
      note "tool hold: $total decision(s) on this cluster asked, and no call outside the seeds would wait for a person"
      rm -rf "$d"
      return 0
    fi
    if [ -n "$rows" ]; then
      printf '\n   With the tool hold on, these calls would wait for a person (%s of %s decisions could not be asked):\n\n' "$unexamined" "$total"
      tool_hold_table "$d/report.json"
      stop="the tool hold would stop what the agents above do today."
    else
      printf '\n   %s of %s decisions on this cluster could not be asked, so no list here says what the tool hold would stop.\n' "$unexamined" "$total"
      stop="what the tool hold would stop on this cluster is not known."
    fi
  else
    printf '\n   wardryx could not be asked what the tool hold would stop: %s\n' "${TOOL_HOLD_WHY:-it answered nothing}"
    stop="what the tool hold would stop on this cluster is not known."
  fi
  if [ "$TOOL_HOLD_SAID" = 1 ]; then
    note "TOOL_HOLD=1 was said, so the hold goes on over that: an agent above waits for a person until something grants its tool"
    rm -rf "$d"
    return 0
  fi
  printf '\n   To give each agent what it needs, move the cluster first, with the hold off, then grant, then turn it on:\n\n'
  printf '     TOOL_HOLD=0 <this launcher, as you ran it>\n'
  if [ -n "$rows" ]; then
    tool_hold_commands "$d/report.json"
  else
    printf "     ./tool-hold/agents.sh agent-allow '<agent>' '<tool[,tool]>' --why 'what it is for'\n"
  fi
  printf '     TOOL_HOLD=1 <this launcher, as you ran it>\n\n'
  printf '   A wardryx older than 2.6.0 cannot store a grant, which is why the cluster moves first. An agent that\n'
  printf '   calls with a static key adds --static-key. ./tool-hold/agents.sh agent-list asks again at any time.\n'
  printf '   Or leave the hold off: TOOL_HOLD=0 <this launcher, as you ran it>, and nothing more.\n'
  rm -rf "$d"
  die "$stop Nothing was applied."
}
# After the kustomization, and only here: the namespace exists, and wardryx is on the pin the
# block needs. wardryx reads its policy at start, so a change restarts it, and only a change.
tool_hold_settle() {
  local want
  if [ "$TOOL_HOLD_ON" != 1 ]; then
    [ "$TOOL_HOLD_STATE" != off ] || return 0
    tool_hold_empty_document | k_ "apply -f -" >/dev/null || die "could not leave the tool hold out"
    if [ "$TOOL_HOLD_STATE" = on ]; then
      k_ "-n agent-stack rollout restart deployment/wardryx" >/dev/null \
        || die "could not restart wardryx after taking the tool hold out"
    fi
    note "tool hold: off, on your word. An agent's tool call passes unless a rule stops it, and the next run keeps this"
    return 0
  fi
  want="$(tool_hold_block)"
  if [ "$TOOL_HOLD_STATE" != absent ] && [ "$(tool_hold_current)" = "$want" ]; then return 0; fi
  tool_hold_document <<<"$want" | k_ "apply -f -" >/dev/null || die "could not apply the tool hold"
  k_ "-n agent-stack rollout restart deployment/wardryx" >/dev/null \
    || die "could not restart wardryx to load the tool hold"
  note "tool hold: on. A tool call nothing grants waits for a person, and model calls pass. Give an agent a tool: ./tool-hold/agents.sh agent-allow <agent> <tool[,tool]|all> --why 'text'"
}
