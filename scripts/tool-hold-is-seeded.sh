#!/usr/bin/env bash
#
# Enforces invariant 83 of CLAUDE.md: a tool call of an agent nothing grants is held for a person
# on a cluster where nobody chose anything, model calls pass, only an explicit grant lifts the
# hold, and a cluster with a history stops the launcher with the list before anything is applied.
#
# WHAT THIS IS ABOUT
#
# This is the first default in the stack that can stop something that worked yesterday, and a
# wrong answer here is silent in both directions: a seed that is too wide switches the control off
# and every check stays green, and a seed that is too narrow stops an agent with no word. So this
# gate does not stop at text. It holds five things:
#
#   A. the wiring: the pin, the projection, and in each of the three launchers the switch, the
#      question before the first apply, and the write after the kustomization;
#   B. the block, rendered by lib/tool-hold.sh: the floor on "*", the seeds line for line, the
#      web grant only with a scopyx and a trust domain, and the ConfigMap that carries it;
#   C. the stop, on a stub kubectl fed replay reports: who is asked, what is printed, what is
#      never printed to paste, that a stopped run applies nothing and leaves no Job, and that a
#      second run neither writes nor restarts;
#   D. the binding: every scenario names a case here, and every case is named by a scenario;
#   E. the real thing: the image the manifests pin, serving the block, on a network of its own.
#      Each seed is asked what it was written for, tool-hold/agents.sh goes through a real PUT with
#      a shim logging every argument, and the stop reads a real replay of the Job's own arguments.
#
# WHAT THIS DOES NOT SEE
#
# A real API server and a real broker: evidence/tool-hold-kind/ runs the first, with a real Job, a
# real exec and a real Postgres, on kind.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No lib, no block, no launcher or no Docker: each fails, and says it measured nothing.
#
# (teeth cases: scripts/gates-have-teeth.sh, "tool-hold-is-seeded: ...";
#  scenarios: features/a-tool-call-nothing-grants-waits-for-a-person.feature)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd -P)"

status=0
fail() {
	printf 'FAIL: %s\n' "$*"
	status=1
}

for f in lib/tool-hold.sh tool-hold/agents.sh tool-hold/wardryx.py manifests/10-planes.yaml deploy.sh cloud/gcp/deploy-gcp.sh cloud/aws/deploy-aws.sh; do
	[ -f "$f" ] || {
		printf 'FAIL: %s is not there, so the hold was NOT measured and this measured NOTHING.\n' "$f"
		exit 1
	}
done
if ! grep -q '^tool_hold_block() {$' lib/tool-hold.sh || ! grep -q '^tool_hold_guard() {$' lib/tool-hold.sh || ! grep -q '^tool_hold_settle() {$' lib/tool-hold.sh; then
	printf 'FAIL: lib/tool-hold.sh has no tool_hold_block, tool_hold_guard and tool_hold_settle, so the hold was NOT measured and this measured NOTHING.\n'
	exit 1
fi

# ---- A. the wiring ---------------------------------------------------------------------
PIN="$(sed -nE 's/^ +image: (ghcr\.io\/taipanbox\/wardryx:v[^ ]+@sha256:[0-9a-f]{64})$/\1/p' manifests/10-planes.yaml | sed -n 1p)"
[ -n "$PIN" ] || fail "A: manifests/10-planes.yaml pins no wardryx by tag and digest, so the pin was not measured"
VER="$(sed -nE 's/.*wardryx:v([0-9]+\.[0-9]+)\.[0-9]+@sha256:.*/\1/p' <<<"$PIN")"
case "$VER" in
	2.[6-9] | 2.[1-9][0-9] | [3-9].*) ;;
	*) fail "A: manifests/10-planes.yaml pins wardryx ${VER:-?}, older than 2.6.0, which refuses when_no_grant at load" ;;
esac
grep -qE 'wardryx:v[0-9]' lib/tool-hold.sh tool-hold/agents.sh && fail "A: the image the question runs in is written down a second time: it is read from the manifest, and a second pin drifts"

grep -q '^              - configMap: { name: wardryx-tool-hold, optional: true }$' manifests/10-planes.yaml \
	|| fail "A: manifests/10-planes.yaml does not project the ConfigMap wardryx-tool-hold, optional, into wardryx's policy directory"
others="$(grep -l 'wardryx-tool-hold' manifests/*.yaml | grep -v '^manifests/10-planes\.yaml$' || true)"
[ -z "$others" ] || fail "A: a manifest carries the floor ($others), so a plain apply -k would install it with nobody asked"

python3 - <<'PY' || status=1
import re, sys
bad = []
launchers = ["deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh"]
for path in launchers:
    lines = open(path).read().split("\n")
    def first(pattern):
        for n, line in enumerate(lines, 1):
            if not line.lstrip().startswith("#") and re.search(pattern, line):
                return n
        return None
    source = first(r'^\. "\$ROOT/lib/tool-hold\.sh"')
    check = first(r"^tool_hold_check ")
    guard = first(r"^tool_hold_guard\b")
    settle = first(r"^tool_hold_settle\b")
    store = first(r"^policy_store_guard\b")
    apply_ = first(r'k_ "apply -k ')
    clear = first(r"delete configmap wardryx-typed-hold")
    if source is None:
        bad.append(f"{path} does not source lib/tool-hold.sh")
    if first(r'--tool-hold\) TOOL_HOLD="\$2"') is None:
        bad.append(f"{path} does not parse --tool-hold")
    if first(r'^TOOL_HOLD="\$\{TOOL_HOLD:-\}"$') is None:
        bad.append(f"{path} does not read TOOL_HOLD from the environment")
    if check is None:
        bad.append(f"{path} never calls tool_hold_check, so a misspelt switch is found on the cluster")
    if guard is None:
        bad.append(f"{path} never calls tool_hold_guard, so a cluster with a history is not asked")
    if settle is None:
        bad.append(f"{path} never calls tool_hold_settle, so the block is never written")
    if None in (source, check, guard, settle, store, apply_, clear):
        continue
    if not source < check:
        bad.append(f"{path} checks the switch before it sources the lib")
    if not (store < guard < apply_):
        bad.append(f"{path} asks the question after the first apply, so a stop no longer means nothing was applied")
    if not (apply_ < settle and clear < settle):
        bad.append(f"{path} writes the block before the kustomization and the typed hold")
    installed = first(r"step 1/5|install-(gcp|aws)\.sh\"") or check + 1
    if not check < installed:
        bad.append(f"{path} checks the switch after the cluster is installed")
console = open("manifests/20-console.yaml").read()
if not re.search(r"- name: WARDRYX_ADMIN_KEY\n\s+valueFrom: \{ secretKeyRef: \{ name: stack-keys, key: wardryx_admin \} \}", console):
    bad.append("manifests/20-console.yaml: the console pod does not hold WARDRYX_ADMIN_KEY from the Secret stack-keys, so tool-hold/agents.sh has no key to send")
agents = open("tool-hold/agents.sh").read()
for verb in ("agent-allow", "agent-deny", "agent-list"):
    if verb not in agents:
        bad.append(f"tool-hold/agents.sh does not read {verb}")
for line in bad:
    print("FAIL: A: " + line)
sys.exit(1 if bad else 0)
PY

# ---- the harness -----------------------------------------------------------------------
scratch="$(mktemp -d)"
live=""
cleanup() {
	if [ -n "$live" ]; then
		docker rm -f "$live-wardryx" >/dev/null 2>&1 || true
		docker volume rm "${live}_events" >/dev/null 2>&1 || true
	fi
	rm -rf "$scratch"
}
trap cleanup EXIT

cat >"$scratch/harness.sh" <<'SH'
set -euo pipefail
die() { printf 'DIED: %s\n' "$*"; exit 1; }
note() { printf 'NOTE: %s\n' "$*"; }
say() { printf 'SAY: %s\n' "$*"; }
fact() { if [ -f "$C/$1" ]; then cat "$C/$1"; fi; }
k_() {
  local n
  printf '%s\n' "$*" >>"$C/k.log"
  case "$*" in
    *"get configmap wardryx-tool-hold --ignore-not-found -o name") if [ -f "$C/held" ]; then printf 'configmap/wardryx-tool-hold\n'; fi ;;
    *"get configmap wardryx-tool-hold -o jsonpath="*) fact held ;;
    *"get configmap stack-wiring"*) fact domain ;;
    *"get deployment wardryx"*) if [ -f "$C/wardryx" ]; then printf 'deployment.apps/wardryx\n'; fi ;;
    *"get deployment scopyx"*) if [ -f "$C/scopyx" ]; then printf 'deployment.apps/scopyx\n'; fi ;;
    *"exec -i deploy/genaryx-console"*) cat >/dev/null; if [ -f "$C/store" ]; then cat "$C/store"; else return 1; fi ;;
    *"delete job"* | *"delete configmap"*) printf 'x\n' >>"$C/cleared" ;;
    *"apply -f -")
      n="$(find "$C" -name 'applied.*' | wc -l | tr -d ' ')"
      cat >"$C/applied.$n"
      if [ -f "$C/refused" ]; then printf 'admission webhook refused it\n' >&2; return 1; fi ;;
    *"get job"*) if [ -f "$C/job" ]; then cat "$C/job"; else printf '1/'; fi ;;
    *"logs job/"*) fact report ;;
    *"rollout restart"*) printf 'x\n' >>"$C/restarted" ;;
    *) printf 'UNKNOWN k_: %s\n' "$*" >&2; return 1 ;;
  esac
}
SH
run() { # DIR SCRIPT [ENV=VALUE...]: lib/tool-hold.sh on the stub kubectl; prints what it said, then rc=
	local c="$1" script="$2"
	shift 2
	(
		env -i PATH="$PATH" HOME="$c" C="$c" ROOT="$ROOT" TOOL_HOLD_SECONDS=0 "$@" \
			bash -c ". '$scratch/harness.sh'; . '$ROOT/lib/tool-hold.sh'; $script"
		printf 'rc=%s\n' "$?"
	) 2>&1
}
rc_of() { sed -n 's/^rc=//p' <<<"$1" | tail -n 1; }
box() { # NAME [FACT...]: a directory the stub reads
	local c="$scratch/$1"
	shift
	mkdir -p "$c"
	: >"$c/k.log"
	local one
	for one in "$@"; do : >"$c/$one"; done
	printf '%s' "$c"
}
report() { # DIR TOTAL UNEXAMINED [AGENT TOOL]...: a replay report, as wardryx prints it
	local c="$1" total="$2" unexamined="$3" first=1
	shift 3
	{
		printf '{\n  "total": %s,\n  "unexamined": %s,\n' "$total" "$unexamined"
		if [ "$#" -eq 0 ]; then
			printf '  "would_hold": null\n}\n'
		else
			printf '  "would_hold": [\n'
			while [ "$#" -gt 0 ]; do
				[ "$first" = 1 ] || printf ',\n'
				first=0
				printf '    {\n      "agent_id": "%s",\n      "tool": "%s",\n      "calls": 3,\n      "last": "2026-11-07T10:00:00.123Z"\n    }' "$1" "$2"
				shift 2
			done
			printf '\n  ]\n}\n'
		fi
	} >"$c/report"
}
applied_block() { # DIR: every ConfigMap the run applied that is the floor's own
	grep -l 'name: wardryx-tool-hold, namespace' "$1"/applied.* 2>/dev/null || true
}

# ---- B. the block ----------------------------------------------------------------------
c="$(box b)"
block="$(run "$c" tool_hold_block)"
[ "$(rc_of "$block")" = 0 ] || fail "B: tool_hold_block did not run: $block"
block="$(sed '/^rc=/d' <<<"$block")"
line_of() { grep -nxF -- "$1" <<<"$block" | cut -d: -f1 | head -n 1; }
rule() { # NAME: that rule's lines, from its name to the next rule
	awk -v n="- name: $1" '$0 == n { on = 1; print; next } /^(- |#)/ { on = 0 } on' <<<"$block"
}
[ "$(sed -n 1p <<<"$block")" = "# tool-hold: begin (managed by lib/tool-hold.sh; TOOL_HOLD, invariant 83)" ] || fail "B: the block does not open with its begin marker"
[ "$(tail -n 1 <<<"$block")" = "# tool-hold: end" ] || fail "B: the block does not close with its end marker"
floor="$(rule tool-hold)"
grep -qxF '  target: "*"' <<<"$floor" || fail 'B: the floor is not on target "*", so an agent id with no scheme walks past it'
grep -qxF '  when_no_grant: hold' <<<"$floor" || fail "B: the floor does not say when_no_grant: hold"
[ "$(grep -c '^- name: ' <<<"$block")" = 3 ] || fail "B: the block has rules other than the floor and two seeds: $(grep '^- name: ' <<<"$block" | tr '\n' ' ')"
[ "$(rule grant-drills)" = '- name: grant-drills
  target: agent://mockryx.local/*
  grant_tool: ["*"]' ] || fail "B: grant-drills is not every tool for agent://mockryx.local/* and nothing else: $(rule grant-drills)"
[ "$(rule grant-install-check)" = '- name: grant-install-check
  target: agent://local.invalid/install-check
  grant_tool: [ask]
  require_identity_source: [client-key]
  deny_if_chain_unproven: true' ] || fail "B: grant-install-check is not ask for that one id under the broker's static key: $(rule grant-install-check)"
grep -qE 'felyx|costcrew' <<<"$block" && fail "B: the block grants Felyx or CostCrew something, and both make model calls only"

c="$(box b-web scopyx)"
printf 'acme.example' >"$c/domain"
block="$(run "$c" tool_hold_block)"
block="$(sed '/^rc=/d' <<<"$block")"
[ "$(rule grant-operator-web)" = '- name: grant-operator-web
  target: agent://acme.example/agents/operator
  grant_tool: [fetch_url, browse]
  require_identity_source: [agent-token, none]
  deny_if_chain_unproven: true' ] || fail "B: grant-operator-web is not fetch_url and browse for the operator under an agent token and scopyx's question: $(rule grant-operator-web)"
c="$(box b-noweb)"
printf 'acme.example' >"$c/domain"
grep -q 'grant-operator-web' <<<"$(run "$c" tool_hold_block)" && fail "B: the web grant is on a cluster with no scopyx"
c="$(box b-nodomain scopyx)"
printf 'set-me.invalid' >"$c/domain"
grep -q 'grant-operator-web' <<<"$(run "$c" tool_hold_block)" && fail "B: the web grant names the placeholder trust domain"
c="$(box b-kept)"
printf 'acme.example' >"$c/domain"
printf -- '- name: grant-operator-web\n' >"$c/held"
grep -q 'grant-operator-web' <<<"$(run "$c" tool_hold_block)" || fail "B: a block that carries the web grant loses it when scopyx is down for a moment"

c="$(box b-doc)"
doc="$(run "$c" 'tool_hold_block | tool_hold_document')"
grep -qF 'metadata: { name: wardryx-tool-hold, namespace: agent-stack,' <<<"$doc" || fail "B: the document is not the ConfigMap wardryx-tool-hold"
grep -qxF '  tool-hold.yaml: |' <<<"$doc" || fail "B: the document has no key tool-hold.yaml, and wardryx reads a directory by extension"
grep -qxF '    - name: tool-hold' <<<"$doc" || fail "B: the document does not carry the block at the depth of its key"

starter="$(run "$c" tool_hold_starter | sed '/^rc=/d')"
grep -qxF '    - name: stack-up-demo-deny-shell-exec' <<<"$starter" || fail "B: tool_hold_starter does not read the starter policy out of manifests/00-base.yaml"
[ "$(grep -c '^    - name: ' <<<"$starter")" = "$(awk '/^  name: wardryx-policy$/ { c = 1 } c && /^---$/ { exit } c && /^    - name: / { n++ } END { print n + 0 }' manifests/00-base.yaml)" ] \
	|| fail "B: tool_hold_starter stops short of the starter policy, so the question leaves out a rule the cluster serves"

# ---- C. the stop -----------------------------------------------------------------------
guard='tool_hold_guard; printf "passed\n"; tool_hold_settle; printf "settled\n"'

c="$(box c-new)"
out="$(run "$c" "$guard")"
grep -q '^settled$' <<<"$out" || fail "C: a new cluster did not go through: $out"
grep -q 'apply -f -' <<<"$(head -n 8 "$c/k.log")" && grep -q 'wardryx-tool-hold-ask' "$c"/applied.* 2>/dev/null && fail "C: a new cluster was asked, and it has no history"
[ -n "$(applied_block "$c")" ] || fail "C: a new cluster got no floor: nothing wrote the block"
grep -q 'when_no_grant: hold' "$(applied_block "$c" | head -n 1)" || fail "C: the ConfigMap written does not carry the floor"
[ -s "$c/restarted" ] || fail "C: the floor was written and wardryx not restarted, and it reads its policy at start"

c="$(box c-clean wardryx)"
report "$c" 12 0
printf '[]' >"$c/store"
out="$(run "$c" "$guard")"
grep -q '^settled$' <<<"$out" || fail "C: a cluster with nothing to hold did not go through: $out"
grep -q '12 decision(s) on this cluster asked' <<<"$out" || fail "C: a clean question does not say how much it asked: $out"
ask="$(grep -l 'kind: Job' "$c"/applied.* 2>/dev/null | head -n 1)"
if [ -z "$ask" ]; then
	fail "C: a cluster with a history was not asked: no Job was applied, so the replay check is gone"
else
	grep -qF "image: $PIN" "$ask" || fail "C: the question runs another image than the one the manifests pin"
	grep -qF -- '"-format", "json"' "$ask" || fail "C: the Job does not ask for the report a program reads"
	grep -qF -- '"-policy", "/candidate"' "$ask" || fail "C: the Job puts no candidate to the history"
	grep -qF '{ name: events, mountPath: /var/lib/stack/events, readOnly: true, subPath: streams }' "$ask" || fail "C: the Job can write the events it reads, or reads another directory than the bus (invariant 89)"
	grep -qF 'persistentVolumeClaim: { claimName: stack-events, readOnly: true }' "$ask" || fail "C: the Job can write the events it reads"
	grep -qF 'automountServiceAccountToken: false' "$ask" || fail "C: the Job carries a service-account token (invariant 15)"
	grep -qF 'readOnlyRootFilesystem: true' "$ask" || fail "C: the Job's root is writable"
	grep -qxF '    - name: tool-hold' "$ask" || fail "C: the question leaves the floor out, so it asks nothing"
	grep -qxF '    - name: grant-drills' "$ask" || fail "C: the question leaves the seeds out, so every drill reads as stopped"
	grep -qxF '    - name: stack-up-demo-deny-shell-exec' "$ask" || fail "C: the question leaves the starter policy out"
	grep -q 'stored.json' "$ask" && fail "C: an empty store went in as a file, and a list of nothing is no policy"
fi
[ "$(wc -l <"$c/cleared" | tr -d ' ')" -ge 4 ] || fail "C: the question leaves its Job or its ConfigMap behind"

c="$(box c-store wardryx)"
report "$c" 12 0
printf '[{"name":"grant","target":"agent://a.example/x","grant_tool":["ask"]}]' >"$c/store"
run "$c" "$guard" >/dev/null
grep -qF '  stored.json: |' "$c"/applied.* 2>/dev/null || fail "C: what agent-allow wrote is not in the question, so a granted agent is listed"

c="$(box c-stop wardryx)"
report "$c" 40 0 agent://acme.example/agents/billing lookup_invoice agent://acme.example/agents/billing send_reminder 'agent://a/$(id)' ask stranger ask
printf '[]' >"$c/store"
out="$(run "$c" "$guard")"
[ "$(rc_of "$out")" = 1 ] || fail "C: a cluster with an ungranted caller did not stop"
grep -q '^passed$' <<<"$out" && fail "C: a cluster with an ungranted caller went on"
grep -qE '3 +2026-11-07T10:00:00 +lookup_invoice +agent://acme.example/agents/billing$' <<<"$out" || fail "C: the table does not give the calls, when last, the tool and the agent: $out"
grep -qF "./tool-hold/agents.sh agent-allow 'agent://acme.example/agents/billing' 'lookup_invoice,send_reminder' --why" <<<"$out" || fail "C: the stop prints no command that grants the agent its tools: $out"
grep -qF 'TOOL_HOLD=0 <this launcher' <<<"$out" || fail "C: the stop does not say how to leave the hold off"
grep -qF 'Nothing was applied.' <<<"$out" || fail "C: the stop does not say that nothing was applied"
grep -qF '$(id)' <<<"$(grep -F 'agent-allow' <<<"$out" || true)" && fail "C: a hostile id is printed to paste"
grep -qF '2 row(s) have no command' <<<"$out" || fail "C: rows with no command are not counted: $out"
[ -z "$(applied_block "$c")" ] || fail "C: a stopped run wrote the floor"
[ ! -s "$c/restarted" ] || fail "C: a stopped run restarted wardryx"
[ "$(wc -l <"$c/cleared" | tr -d ' ')" -ge 4 ] || fail "C: a stopped run leaves its Job or its ConfigMap behind"

c="$(box c-over wardryx)"
report "$c" 40 0 agent://acme.example/agents/billing lookup_invoice
out="$(run "$c" "$guard" TOOL_HOLD=1)"
grep -q '^settled$' <<<"$out" || fail "C: TOOL_HOLD=1 does not turn the hold on over the list: $out"
[ -n "$(applied_block "$c")" ] || fail "C: TOOL_HOLD=1 wrote no floor"

c="$(box c-blind wardryx)"
report "$c" 40 7
out="$(run "$c" "$guard")"
[ "$(rc_of "$out")" = 1 ] || fail "C: unexamined decisions read as nothing to hold, so a history that could not be asked passed"
grep -qF '7 of 40 decisions on this cluster could not be asked' <<<"$out" || fail "C: the stop does not say how much could not be asked: $out"

c="$(box c-noask wardryx)"
out="$(run "$c" "$guard")"
[ "$(rc_of "$out")" = 1 ] || fail "C: a Job that left no report passed the question"
grep -qF 'wardryx could not be asked' <<<"$out" || fail "C: the stop does not say that wardryx could not be asked: $out"
c="$(box c-refused wardryx refused)"
out="$(run "$c" "$guard")"
[ "$(rc_of "$out")" = 1 ] || fail "C: a Job the cluster refused passed the question"
grep -qF 'admission webhook refused it' <<<"$out" || fail "C: the stop does not say why the Job was refused: $out"

c="$(box c-off wardryx)"
out="$(run "$c" "$guard" TOOL_HOLD=0)"
grep -q '^settled$' <<<"$out" || fail "C: TOOL_HOLD=0 did not go through: $out"
grep -q 'kind: Job' "$c"/applied.* 2>/dev/null && fail "C: TOOL_HOLD=0 was asked, and it has said what it wants"
grep -q 'when_no_grant' "$c"/applied.* 2>/dev/null && fail "C: TOOL_HOLD=0 leaves the block"
[ -n "$(applied_block "$c")" ] || fail "C: TOOL_HOLD=0 left nothing to say so, and the next run would ask again"

c="$(box c-kept wardryx held)"
out="$(run "$c" "$guard")"
grep -q '^settled$' <<<"$out" || fail "C: a cluster that said 0 did not go through: $out"
grep -q 'kind: Job' "$c"/applied.* 2>/dev/null && fail "C: a cluster that said 0 is asked again, so TOOL_HOLD=0 does not last"
[ -z "$(applied_block "$c")" ] || fail "C: a cluster that said 0 got the floor on a run that said nothing"

c="$(box c-back wardryx)"
printf '%s\n' '- name: tool-hold' >"$c/held"
out="$(run "$c" "$guard" TOOL_HOLD=0)"
grep -q 'when_no_grant' "$c"/applied.* 2>/dev/null && fail "C: TOOL_HOLD=0 leaves the block on a cluster that had it"
[ -n "$(applied_block "$c")" ] || fail "C: TOOL_HOLD=0 leaves the block on a cluster that had it: nothing was written"
[ -s "$c/restarted" ] || fail "C: TOOL_HOLD=0 took the block out and wardryx kept serving it: it was not restarted"

c="$(box c-again wardryx)"
run "$c" 'tool_hold_block' | sed '/^rc=/d' >"$c/held"
out="$(run "$c" "$guard")"
grep -q '^settled$' <<<"$out" || fail "C: a cluster that carries the block did not go through: $out"
[ -z "$(find "$c" -name 'applied.*')" ] || fail "C: a second run wrote something"
[ ! -s "$c/restarted" ] || fail "C: a second run restarted wardryx with nothing changed"

c="$(box c-change wardryx scopyx)"
printf 'acme.example' >"$c/domain"
printf '%s\n' '# tool-hold: begin' '- name: tool-hold' '# tool-hold: end' >"$c/held"
out="$(run "$c" "$guard")"
grep -q 'grant-operator-web' "$c"/applied.* 2>/dev/null || fail "C: a cluster that gained a scopyx did not get the web grant on the next run"
[ -s "$c/restarted" ] || fail "C: a changed block does not restart wardryx"

for word in 2 yes on; do
	c="$(box "c-word-$word")"
	[ "$(rc_of "$(run "$c" "tool_hold_check '$word'")")" != 0 ] || fail "C: --tool-hold took the word $word"
done

# ---- D. the binding --------------------------------------------------------------------
python3 - <<'PY' || status=1
import re, sys
try:
    feature = open("features/a-tool-call-nothing-grants-waits-for-a-person.feature").read()
except OSError:
    print("FAIL: D: features/a-tool-call-nothing-grants-waits-for-a-person.feature is not there, so the behaviour is written nowhere")
    sys.exit(1)
teeth = open("scripts/gates-have-teeth.sh").read()
bound = set(re.findall(r'# -> gates-have-teeth\.sh "([^"]+)"', feature))
cases = set(re.findall(r'^run_case "(tool-hold-is-seeded: [^"]+)"', teeth, re.M))
bad = []
if not bound:
    bad.append("no scenario is bound to a case")
for name in sorted(bound - cases):
    bad.append(f'a scenario names a case that does not exist: "{name}"')
for name in sorted(cases - bound):
    bad.append(f'a case no scenario names: "{name}"')
chunks = re.split(r"^  Scenario: ", feature, flags=re.M)[1:]
for chunk in chunks:
    if "# -> gates-have-teeth.sh" not in chunk:
        bad.append(f"a scenario is bound to nothing: {chunk.splitlines()[0]}")
for line in bad:
    print("FAIL: D: " + line)
sys.exit(1 if bad else 0)
PY

# The static parts decide most faults, and a run of the image says nothing about them.
if [ "$status" != 0 ]; then
	printf 'the block or its wiring is wrong, so asking the image about it would mean nothing\n'
	exit 1
fi

# ---- E. the real thing -----------------------------------------------------------------
if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
	printf 'FAIL: no Docker, so the seeds were not put to the image and this measured NOTHING.\n'
	exit 1
fi
BUSYBOX="$(sed -nE 's/^ +image: (busybox@sha256:[0-9a-f]{64})$/\1/p' manifests/10-planes.yaml | sed -n 1p)"
[ -n "$BUSYBOX" ] || {
	printf 'FAIL: manifests/10-planes.yaml pins no busybox, so the volume could not be made and this measured NOTHING.\n'
	exit 1
}
for image in "$PIN" "$BUSYBOX"; do
	if ! docker image inspect "$image" >/dev/null 2>&1; then
		docker pull -q "$image" >/dev/null || {
			printf 'FAIL: could not pull %s, so the seeds were not put to the image and this measured NOTHING.\n' "$image"
			exit 1
		}
	fi
done
live="holdgate$$"
ADMIN="holdgate-admin-$(printf '%040d' 7)"
PEP="holdgate-pep-$(printf '%040d' 9)"
docker volume create "${live}_events" >/dev/null
docker run --rm -v "${live}_events:/v" "$BUSYBOX" chown 65532:10001 /v >/dev/null

e="$scratch/e"
mkdir -p "$e/policy" "$e/shim" "$e/box"
c="$(box e-box wardryx)"
printf 'acme.example' >"$c/domain"
: >"$c/scopyx"
run "$c" tool_hold_block | sed '/^rc=/d' >"$e/policy/tool-hold.yaml"
run "$c" tool_hold_starter | sed '/^rc=/d' | sed 's/^    //' >"$e/policy/policy.yaml"
chmod -R a+rX "$e"
docker run -d --name "$live-wardryx" --user 65532:10001 -p 127.0.0.1::8090 \
	-e WARDRYX_KEYS="$ADMIN:default:admin,$PEP:default:pep" -e WARDRYX_APPROVAL_SECRET=holdgate-approval-secret-0000000000000000 \
	-e WARDRYX_POLICY_ARCHIVE=/var/lib/stack/events/wardryx-policy-archive \
	-v "${live}_events:/var/lib/stack/events" -v "$e/policy:/etc/wardryx/policy:ro" "$PIN" \
	serve -addr 0.0.0.0:8090 -events /var/lib/stack/events/wardryx.ndjson -policy /etc/wardryx/policy >/dev/null \
	|| { printf 'FAIL: the pinned wardryx did not start on the block, so this measured NOTHING.\n'; exit 1; }
PORT=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	PORT="$(docker port "$live-wardryx" 8090/tcp 2>/dev/null | sed -n 's/.*:\([0-9]*\)$/\1/p' | head -n 1)"
	if [ -n "$PORT" ] && [ "$(python3 - "$PORT" <<'PY' 2>/dev/null
import sys, urllib.request
print(urllib.request.urlopen("http://127.0.0.1:%s/healthz" % sys.argv[1], timeout=2).status)
PY
)" = 200 ]; then ready=1; break; fi
	sleep 1
done
if [ "${ready:-0}" != 1 ]; then
	docker logs "$live-wardryx" 2>&1 | tail -5
	printf 'FAIL: the pinned wardryx did not answer on the block, so this measured NOTHING.\n'
	exit 1
fi
decide() { # AGENT TOOL SOURCE: a tools/call as the broker asks it, TOOL empty for a model call, `web` for scopyx's question
	python3 - "$PORT" "$PEP" "$1" "$2" "$3" <<'PY'
import json, sys, urllib.error, urllib.request
port, key, agent, tool, source = sys.argv[1:6]
if tool == "":
    body = {"agent_id": agent, "run_id": "r", "model": "m", "identity_source": source}
elif tool == "web":
    body = {"agent_id": agent, "run_id": "r", "tool_names": ["fetch_url"], "domains": ["example.com"]}
else:
    body = {"agent_id": agent, "run_id": "r", "tool_names": [tool], "identity_source": source,
            "tool_call": {"name": tool, "target": "t", "arguments": {"a": 1}}}
request = urllib.request.Request("http://127.0.0.1:%s/v1/decide" % port, data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
try:
    print(json.load(urllib.request.urlopen(request, timeout=5))["decision"])
except urllib.error.HTTPError as err:
    print("http %s" % err.code)
PY
}
want() { # NAME DECISION AGENT TOOL SOURCE
	local got
	got="$(decide "$3" "$4" "$5")"
	[ "$got" = "$2" ] || fail "E: $1: wardryx answered ${got:-nothing}, want $2"
}
OP=agent://acme.example/agents/operator
want "a tool call of an agent nothing grants" hold agent://acme.example/stranger ask agent-token
want "a model call of that agent" allow agent://acme.example/stranger "" agent-token
want "an egress question of that agent" allow agent://acme.example/stranger web ""
want "an id with no scheme" hold stranger ask client-key
want "the fire drill's tool" allow agent://mockryx.local/scenario lookup_order_status client-key
want "the drill's denied tool" deny agent://mockryx.local/ci shell_exec client-key
want "the install check through the broker's static key" allow agent://local.invalid/install-check ask client-key
want "another tool of the install check's id" hold agent://local.invalid/install-check fetch_url client-key
want "the operator's fetch" allow "$OP" fetch_url agent-token
want "scopyx's question about the operator's fetch" allow "$OP" web ""
want "the operator's name under a static key" deny "$OP" fetch_url client-key
want "the operator's other tool" hold "$OP" ask agent-token
want "the operator's model call" allow "$OP" "" agent-token
[ "$status" = 0 ] || exit 1

# kubectl, for tool-hold/agents.sh and the question: a console pod that is this machine, a Job that
# is a real replay with the Job's own arguments, and every argument logged.
cat >"$e/kubectl" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$e/argv.log"
case "\$*" in
  *"get configmap wardryx-tool-hold --ignore-not-found -o name") printf 'configmap/wardryx-tool-hold\n' ;;
  *"get configmap wardryx-tool-hold -o jsonpath="*) cat "$e/policy/tool-hold.yaml" ;;
  *"get configmap stack-wiring"*) printf 'acme.example' ;;
  *"get deployment scopyx"*) printf 'deployment.apps/scopyx\n' ;;
  *"get secret stack-keys"*) printf '%s' "$ADMIN" ;;
  *"exec -i deploy/genaryx-console"*)
    while [ "\$#" -gt 0 ] && [ "\$1" != python3 ]; do shift; done
    WARDRYX_ADMIN_KEY="$ADMIN" TOOL_HOLD_WARDRYX_URL="http://127.0.0.1:$PORT" exec "\$@" ;;
  *"apply -f -") cat >"$e/asked.yaml" ;;
  *"get job"*) printf '1/' ;;
  *"logs job/"*)
    rm -rf "$e/candidate"; mkdir -p "$e/candidate"
    python3 - "$e/asked.yaml" "$e/candidate" >"$e/job-args" <<'PY'
import json, re, sys
text = open(sys.argv[1]).read()
cm, job = text.split("\n---\n", 1)
name = None
files = {}
for line in cm.split("\n"):
    m = re.match(r"^  ([a-z.-]+): \|$", line)
    if m:
        name = m.group(1)
        files[name] = ""
    elif name and line.startswith("    "):
        files[name] += line[4:] + "\n"
    elif name and line == "":
        files[name] += "\n"
for key, body in files.items():
    open(sys.argv[2] + "/" + key, "w").write(body)
print("\n".join(json.loads(re.search(r"^ +args: (\[.*\])$", job, re.M).group(1))))
PY
    chmod -R a+rX "$e/candidate"
    IFS=\$'\n' read -d '' -r -a args <"$e/job-args" || true
    docker run --rm --network none --read-only --cap-drop ALL --user 65532:65532 --group-add 10001 \
      -v "${live}_events:/var/lib/stack/events:ro" -v "$e/candidate:/candidate:ro" "$PIN" "\${args[@]}" 2>&1 ;;
  *"delete job"* | *"delete configmap"*) ;;
  *"logs deploy/wardryx -c wardryx") docker logs "$live-wardryx" 2>&1 ;;
  *) printf 'UNKNOWN kubectl: %s\n' "\$*" >&2; exit 1 ;;
esac
SHIM
chmod +x "$e/kubectl"
agents() { env -i PATH="$PATH" HOME="$e" KUBECTL="$e/kubectl" TOOL_HOLD_SECONDS=0 "$ROOT/tool-hold/agents.sh" "$@" 2>&1; }

floorput="$(python3 - "$PORT" "$ADMIN" <<'PY'
import json, sys, urllib.error, urllib.request
request = urllib.request.Request("http://127.0.0.1:%s/v1/policies/x" % sys.argv[1], method="PUT",
    data=json.dumps({"target": "*", "when_no_grant": "hold"}).encode(),
    headers={"Authorization": "Bearer " + sys.argv[2], "Content-Type": "application/json"})
try:
    print(urllib.request.urlopen(request, timeout=5).status)
except urllib.error.HTTPError as err:
    print(err.code)
PY
)"
[ "$floorput" = 400 ] || fail "E: the floor was written through the policy API: HTTP $floorput"

started="$(docker inspect --format '{{.State.StartedAt}}' "$live-wardryx")"
AG=agent://acme.example/lab/one
out="$(agents agent-allow "$AG" ask,browse --why 'the gate grants this')" || fail "E: agent-allow was refused: $out"
want "a granted tool" allow "$AG" ask agent-token
want "the agent's tool nothing granted" hold "$AG" fetch_url agent-token
want "a granted name under a static key" deny "$AG" ask client-key
out="$(agents agent-allow "$AG" fetch_url --why 'one more')" || fail "E: a second agent-allow was refused: $out"
want "a second grant keeps the first" allow "$AG" browse agent-token
want "a second grant adds its tool" allow "$AG" fetch_url agent-token
[ "$started" = "$(docker inspect --format '{{.State.StartedAt}}' "$live-wardryx")" ] || fail "E: the grant needed a restart"
events="$(docker run --rm -v "${live}_events:/e:ro" "$BUSYBOX" cat /e/wardryx.ndjson)"
grep -q '"policy_updated"' <<<"$events" || fail "E: agent-allow left no policy_updated on the record"
listed="$(agents agent-list)"
grep -qE '^ +tool hold: on, grants: 3 in the ConfigMap, 1 through agent-allow$' <<<"$listed" || fail "E: agent-list does not say the floor is on and how many grants: $listed"
grep -qF 'one more' <<<"$listed" || fail "E: agent-list does not show the reason in the grant's name"
grep -q "$AG" <<<"$listed" || fail "E: agent-list does not show the grant"
grep -q 'grant-drills' <<<"$listed" || fail "E: agent-list does not show the grants in the ConfigMap"
# What wardryx loaded is its own start line (2.6.1 and later), read from its log: on here.
loaded_now="$(env -i PATH="$PATH" ROOT="$ROOT" KUBECTL="$e/kubectl" bash -c 'k_() { eval "$KUBECTL $*"; }; . "$ROOT/lib/tool-hold.sh"; tool_hold_loaded' 2>&1)"
[ "$loaded_now" = on ] || fail "E: what the running wardryx loaded does not read on from its own start line: '$loaded_now'"
# A start record 2.6.0 left on the bus names an older start, so it must not decide: one with no floor,
# planted after the real start, changes nothing in what agent-list says.
docker run --rm -v "${live}_events:/e" "$BUSYBOX" sh -c 'printf "%s\n" "{\"type\":\"policy_loaded\",\"source\":\"wardryx\",\"data\":{\"no_grant_floors\":[]}}" >>/e/wardryx.ndjson'
listed="$(agents agent-list)"
grep -qE '^ +tool hold: on, grants: 3 in the ConfigMap, 1 through agent-allow$' <<<"$listed" || fail "E: a start record left on the bus by an older wardryx decides what the running one loaded: $listed"

# The stop against the real replay: the agent with a stored grant is off the list, the stranger is on it.
out="$(env -i PATH="$PATH" HOME="$e" TRUST_DOMAIN=acme.example ROOT="$ROOT" TOOL_HOLD_SECONDS=0 KUBECTL="$e/kubectl" bash -c "
	set -euo pipefail
	die() { printf 'DIED: %s\n' \"\$*\"; exit 1; }
	k_() { eval \"\$KUBECTL \$*\"; }
	. '$ROOT/lib/tool-hold.sh'
	d=\"\$(mktemp -d)\"
	tool_hold_ask \"\$d\" || { printf 'NOT ASKED: %s\n' \"\$TOOL_HOLD_WHY\"; exit 1; }
	printf 'total=%s unexamined=%s\n' \"\$(tool_hold_count total \"\$d/report.json\")\" \"\$(tool_hold_count unexamined \"\$d/report.json\")\"
	tool_hold_table \"\$d/report.json\"
	tool_hold_commands \"\$d/report.json\"
" 2>&1)"
grep -qE '^total=[1-9][0-9]* unexamined=0$' <<<"$out" || fail "E: the real replay read nothing, or could not read what it read: $out"
grep -qE ' +ask +agent://acme.example/stranger$' <<<"$out" || fail "E: the real replay does not list the stranger: $out"
grep -qF "agent-allow 'agent://acme.example/stranger' 'ask'" <<<"$out" || fail "E: the real report gives no command for the stranger: $out"
grep -q 'agent://acme.example/lab/one' <<<"$out" && fail "E: a grant written through agent-allow is not in the question, so a granted agent is listed"
grep -q 'agent://mockryx.local' <<<"$out" && fail "E: the question leaves the seeds out"

out="$(agents agent-deny "$AG" ask --why 'the gate takes it back')" || fail "E: agent-deny was refused: $out"
want "a tool taken back" hold "$AG" ask agent-token
want "the tool left" allow "$AG" browse agent-token
agents agent-deny "$AG" all --why 'gone' >/dev/null || fail "E: agent-deny all was refused"
want "every tool taken back" hold "$AG" browse agent-token
agents agent-allow "$AG" ask --why 'a static caller' --static-key >/dev/null || fail "E: agent-allow --static-key was refused"
want "a grant for a static key" allow "$AG" ask client-key
out="$(agents agent-allow "$AG" all --why 'all of it')"
grep -q 'WARNING' <<<"$out" || fail "E: agent-allow all prints no warning"
want "every tool" allow "$AG" whatever client-key
out="$(agents agent-deny "$AG" ask --why 'one of all' || true)"
grep -q 'holds every tool' <<<"$out" || fail "E: one tool came out of a grant of every tool"

for hostile in 'agent://*/x' 'agent://a*/x' '*' 'stranger' 'agent://a/x"y' 'agent://a/$(id)'; do
	out="$(agents agent-allow "$hostile" ask --why 'a reason' || true)"
	grep -q 'trust domain' <<<"$out" || fail "E: agent-allow took $hostile"
done
for bad in 'a b' 'a;b' '"' ''; do
	out="$(agents agent-allow agent://a/b "$bad" --why 'a reason' || true)"
	grep -q 'takes tools as' <<<"$out" || fail "E: agent-allow took the tool '$bad'"
done
out="$(agents agent-allow agent://a/b ask || true)"
grep -q 'needs --why' <<<"$out" || fail "E: agent-allow went on with no --why"
out="$(agents agent-allow agent://a/b ask --why 'a "quote' || true)"
grep -q 'needs --why' <<<"$out" || fail "E: a quote in --why reached the JSON"

if grep -qF "$ADMIN" "$e/argv.log"; then
	fail "E: the admin key reached a kubectl argument list"
fi
[ -s "$e/argv.log" ] || fail "E: the shim logged nothing, so no argument list was read"
if grep -q 'exec -i deploy/genaryx-console' "$e/argv.log"; then :; else
	fail "E: nothing ran in the console's pod, so the key's path was not measured"
fi

if [ "$status" = 0 ]; then
	printf 'OK: the floor is on "*", the seeds keep the checks working and hold nothing else, a real replay stops a cluster with an ungranted caller before anything is applied, and one command ends a hold with no restart.\n'
fi
exit "$status"
