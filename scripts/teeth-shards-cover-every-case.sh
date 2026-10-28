#!/usr/bin/env bash
#
# The teeth run is split into CI shards (invariant 49). Each shard is one job in
# .github/workflows/gates.yml that runs scripts/gates-have-teeth.sh with
# TEETH_SHARD=i/N. A case that falls in no shard never runs, and a case in two
# shards runs twice; neither changes an exit code, so nothing else would notice.
#
# This gate lists the whole run and each shard with TEETH_LIST=1, which runs no
# case and mutates nothing, and compares them: the shards must cover the whole
# list, each case once, and no shard may be empty.
#
# N is read from the workflow, not written here, so the number checked is the
# number CI runs. The teeth job's TEETH_SHARD line names N, and the matrix must
# run exactly the shards 1 to N.
#
# Its own faults are planted by three cases in scripts/gates-have-teeth.sh whose
# names start with "teeth-shards-cover-every-case:".

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

wf=".github/workflows/gates.yml"

fail() {
	printf 'FAIL  %s\n' "$*"
	exit 1
}

[ -f "$wf" ] || fail "$wf is missing: measured nothing"

# The teeth job's line, e.g. "TEETH_SHARD: ${{ matrix.shard }}/6".
n_lines="$(grep -E 'TEETH_SHARD: \$\{\{ matrix\.shard \}\}/[0-9]+' "$wf" | sed -E 's/.*\/([0-9]+).*/\1/')"
count="$(printf '%s\n' "$n_lines" | grep -c .)"
[ "$count" -ne 0 ] || fail "$wf has no sharded teeth job (TEETH_SHARD: \${{ matrix.shard }}/N): measured nothing"
[ "$count" -eq 1 ] || fail "$wf names more than one shard count: $(printf '%s ' $n_lines)"
n="$n_lines"
[ "$n" -ge 1 ] || fail "$wf names zero shards"

expect=""
i=1
while [ "$i" -le "$n" ]; do
	if [ -z "$expect" ]; then expect="$i"; else expect="$expect, $i"; fi
	i=$((i + 1))
done
grep -qF "shard: [$expect]" "$wf" ||
	fail "the CI matrix does not run every shard: $wf must name shard: [$expect], so each of the $n shards runs once"

tmp="$(mktemp -d)" || fail "could not make a scratch directory"
trap 'rm -rf "$tmp"' EXIT INT TERM

# The whole list is taken with TEETH_SHARD unset. This gate also runs as a case
# inside a shard, where TEETH_SHARD is set in the environment, and a whole list
# that inherited it would be one shard, and every other shard would look extra.
if ! env -u TEETH_SHARD TEETH_LIST=1 ./scripts/gates-have-teeth.sh >"$tmp/whole" 2>"$tmp/whole.err"; then
	fail "the whole case list could not be read: $(head -3 "$tmp/whole.err")"
fi
[ -s "$tmp/whole" ] || fail "the whole case list is empty: measured nothing"

: >"$tmp/union"
i=1
while [ "$i" -le "$n" ]; do
	if ! TEETH_LIST=1 TEETH_SHARD="$i/$n" ./scripts/gates-have-teeth.sh >"$tmp/shard$i" 2>"$tmp/shard$i.err"; then
		fail "shard $i/$n could not be listed: $(head -3 "$tmp/shard$i.err")"
	fi
	cat "$tmp/shard$i" >>"$tmp/union"
	i=$((i + 1))
done

LC_ALL=C sort "$tmp/whole" >"$tmp/whole.sorted"
LC_ALL=C sort "$tmp/union" >"$tmp/union.sorted"
total="$(wc -l <"$tmp/whole.sorted" | tr -d ' ')"

# A case is identified by its name, so the whole list must not repeat one.
twice_whole="$(LC_ALL=C uniq -d "$tmp/whole.sorted")"
[ -z "$twice_whole" ] ||
	fail "the whole list names a case twice, so no split can be checked by name: $(printf '%s\n' "$twice_whole" | head -2 | tr '\n' ';')"

missing="$(LC_ALL=C comm -23 "$tmp/whole.sorted" "$tmp/union.sorted")"
[ -z "$missing" ] ||
	fail "the shards do not cover the whole list: $(printf '%s\n' "$missing" | grep -c .) case(s) run in no shard, e.g. $(printf '%s\n' "$missing" | head -2 | tr '\n' ';')"

twice="$(LC_ALL=C uniq -d "$tmp/union.sorted")"
[ -z "$twice" ] ||
	fail "a case runs in more than one shard, so it runs twice: e.g. $(printf '%s\n' "$twice" | head -2 | tr '\n' ';')"

extra="$(LC_ALL=C comm -13 "$tmp/whole.sorted" "$tmp/union.sorted")"
[ -z "$extra" ] ||
	fail "a shard lists a case the whole list does not have: $(printf '%s\n' "$extra" | head -2 | tr '\n' ';')"

i=1
while [ "$i" -le "$n" ]; do
	[ -s "$tmp/shard$i" ] || fail "shard $i/$n owns no case: measured nothing"
	i=$((i + 1))
done

printf 'OK: the %d shards of the teeth run cover all %d cases, each once\n' "$n" "$total"
