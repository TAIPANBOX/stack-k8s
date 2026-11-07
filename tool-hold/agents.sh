#!/usr/bin/env bash
# What an operator has for the tool hold (CLAUDE.md invariant 83), the same three commands as
# stack-single's `./install.sh agent-allow | agent-deny | agent-list`:
#
#   ./tool-hold/agents.sh agent-allow <agent> <tool[,tool]|all> --why 'what it is for' [--static-key]
#   ./tool-hold/agents.sh agent-deny  <agent> <tool[,tool]|all> --why 'what it is for'
#   ./tool-hold/agents.sh agent-list
#
# A grant goes through PUT /v1/policies: in force at once with no restart, on the record as
# policy_updated, and it survives a restart. What it changes is in wardryx's store, so this writes
# nothing in the cluster's manifests. The request runs in the console's pod, which holds the admin
# key from the Secret stack-keys, so the key is on no command line and does not leave the cluster.
#
# KUBECTL names the kubectl to use, as in policy/up.sh: on a node, KUBECTL="k3s kubectl".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
KUBECTL="${KUBECTL:-kubectl}"
EXPLAINED=0
die() { EXPLAINED=1; printf '\n!! %s\n' "$*" >&2; exit 1; }
note() { printf '   %s\n' "$*"; }
say() { printf '\n>> %s\n' "$*"; }
k_() { eval "$KUBECTL $*"; }
# shellcheck source=../lib/tool-hold.sh
. "$ROOT/lib/tool-hold.sh" || die "no lib/tool-hold.sh in $ROOT"

usage() {
  awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0" | sed -E 's/^# ?//'
}

# The hold's state, what wardryx loaded at its last start, and the count of grants: one line.
list_status() {
  local state loaded infile instore="not read" stored
  state="$(tool_hold_state)"
  loaded="$(tool_hold_pod loaded 2>/dev/null || true)"
  infile="$(grep -cE '^ *grant_tool:' <<<"$(tool_hold_current 2>/dev/null || true)" || true)"
  if stored="$(tool_hold_pod grants 2>/dev/null)"; then instore="$(grep -c . <<<"$stored" || true)"; fi
  [ "$state" = on ] || state=off
  if [ -n "$loaded" ] && [ "$loaded" != "$state" ]; then
    printf '   tool hold: %s in the ConfigMap and %s in the wardryx running, which reads it at start; grants: %s in the ConfigMap, %s through agent-allow\n' "$state" "$loaded" "$infile" "$instore"
  else
    printf '   tool hold: %s, grants: %s in the ConfigMap, %s through agent-allow\n' "$state" "$infile" "$instore"
  fi
}
list_file_grants() { # the ConfigMap's grants, one tab-separated line each: agent, tools, name
  awk '
    function clean(v) { gsub(/^[ "\047\[]+|[ "\047\]]+$/, "", v); gsub(/[ "\047]/, "", v); return v }
    function flush() { if (tools != "") printf "%s\t%s\t%s\n", target, tools, name; name = target = tools = "" }
    /^- / { flush() }
    /^(- |  )name:/ { v = $0; sub(/^[- ]+name: */, "", v); name = v }
    /^(- |  )target:/ { v = $0; sub(/^[- ]+target: */, "", v); target = clean(v) }
    /^(- |  )grant_tool:/ { v = $0; sub(/^[- ]+grant_tool: */, "", v); tools = clean(v) }
    END { flush() }
  '
}
list_grants() {
  local target tools name stored
  printf '\n   %-44s  %-26s  %s\n' AGENT TOOLS WHERE
  while IFS=$'\t' read -r target tools name; do
    [ -n "$target" ] || continue
    printf '   %-44s  %-26s  ConfigMap: %s\n' "$target" "$tools" "$name"
  done <<<"$(tool_hold_current 2>/dev/null | list_file_grants || true)"
  if stored="$(tool_hold_pod grants 2>/dev/null)"; then
    while IFS=$'\t' read -r target tools name; do
      [ -n "$target" ] || continue
      printf '   %-44s  %-26s  agent-allow: %s\n' "$target" "$tools" "$name"
    done <<<"$stored"
  else
    printf '   wardryx did not answer, so what agent-allow wrote is not listed here\n'
  fi
}
list_preview() { # with the hold off: what it would stop
  local d
  d="$(mktemp -d)" || return 0
  if tool_hold_ask "$d"; then
    if [ -n "$(tool_hold_rows "$d/report.json")" ]; then
      printf '\n   With the hold on, these calls would wait for a person:\n\n'
      tool_hold_table "$d/report.json"
    else
      printf '\n   With the hold on, no call on this cluster would wait for a person (%s of %s decisions could not be asked).\n' \
        "$(tool_hold_count unexamined "$d/report.json")" "$(tool_hold_count total "$d/report.json")"
    fi
  else
    printf '\n   wardryx could not be asked what the hold would stop: %s\n' "${TOOL_HOLD_WHY:-it answered nothing}"
  fi
  rm -rf "$d"
}

why_ok() { # one line of at most 300 characters with no quote or backslash, which goes in the policy's name
  [ -n "$1" ] && [ "${#1}" -le 300 ] && [[ "$1" != *[\"\'\\]* ]] && [ "$1" = "$(printf '%s' "$1" | tr -d '\n\r\t')" ]
}
tools_json() { # A,B: the same as a JSON list
  local out="" one
  while IFS= read -r one; do
    [ -n "$one" ] || continue
    out="$out${out:+,}\"$one\""
  done <<<"$(tr ',' '\n' <<<"$1")"
  printf '[%s]' "$out"
}
sources_json() { # agent-token, none: the same as a JSON list
  tools_json "$(tr -d ' ' <<<"$1")"
}

main() {
  local cmd="${1:-}" agent="${2:-}" tools="${3:-}" why="" static="" granted req
  case "$cmd" in
    agent-list)
      list_status
      list_grants
      [ "$(tool_hold_state)" = on ] || list_preview
      return 0
      ;;
    agent-allow | agent-deny) ;;
    -h | --help | '') usage; return 0 ;;
    *) die "agents.sh does not read $cmd. Nothing was changed." ;;
  esac
  [ "$#" -ge 3 ] || die "usage: ./tool-hold/agents.sh $cmd <agent> <tool[,tool]|all> --why 'what it is for'"
  shift 3
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --why) [ "$#" -ge 2 ] || die "--why needs the reason after it. Nothing was changed."; why="$2"; shift 2 ;;
      --static-key) static=static; shift ;;
      *) die "$cmd does not read $1. Nothing was changed." ;;
    esac
  done
  [[ "$agent" =~ ^agent://[A-Za-z0-9._~-]+(:[0-9]+)?(/[A-Za-z0-9._~:/*-]*)?$ ]] \
    || die "$cmd takes an agent as agent://<domain>/<path>, and a * only after the domain: a grant must name the trust domain it is for. Nothing was changed."
  [[ "$tools" =~ ^[A-Za-z0-9._:/-]+(,[A-Za-z0-9._:/-]+)*$ ]] \
    || die "$cmd takes tools as one name, a,b or all. Nothing was changed."
  why_ok "$why" \
    || die "$cmd needs --why: a written reason, one line of at most 300 characters with no quote or backslash, which goes in the policy's name. Nothing was changed."
  if [ "$cmd" = agent-allow ]; then
    req="{\"agent\":\"$agent\",\"tools\":$(tools_json "$tools"),\"why\":\"$why\",\"sources\":$(sources_json "$(tool_hold_sources "$static")")}"
    granted="$(tool_hold_pod allow "$(printf '%s' "$req" | tool_hold_b64)")" || die "the grant was not written. Nothing was changed."
    if [ "$granted" = '*' ]; then
      printf '\n   WARNING: %s may now call every tool the broker reaches, with no person in the way.\n' "$agent"
      printf '   A tool with root on a node gives the agent root. Name the tools it needs instead when you can.\n\n'
    fi
    note "granted $granted to $agent, in force now with no restart, and on the record as policy_updated"
    [ "$(tool_hold_state)" = on ] || note "the tool hold is off on this cluster, so this grant lifts nothing yet"
    [ -n "$static" ] || note "this grant asks for an agent token: an agent that calls with a static key is refused until you repeat this with --static-key"
  else
    req="{\"agent\":\"$agent\",\"tools\":$(tools_json "$tools"),\"why\":\"$why\"}"
    tool_hold_pod deny "$(printf '%s' "$req" | tool_hold_b64)" || die "the grant was not taken away. Nothing was changed."
    note "taken from $agent: $tools. Its next call waits for a person, in force now with no restart, and on the record as policy_updated"
  fi
}

main "$@"
