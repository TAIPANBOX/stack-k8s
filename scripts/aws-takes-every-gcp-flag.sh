#!/usr/bin/env bash
#
# The AWS deploy script takes every flag the GCP deploy script takes.
#
# WHY THIS EXISTS
#
# cloud/gcp/deploy-gcp.sh and cloud/aws/deploy-aws.sh are the same launcher for
# two clouds, and each header says so. A flag that lands in one and not the
# other is invisible from the side that lacks it: an operator on AWS types the
# flag, gets "unknown flag", and reads documentation that says the two launchers
# take the same flags. --copilot-key-file (Felyx on a cloud model, CLAUDE.md
# invariant 25) was added to the GCP launcher alone, so the AWS launcher could
# not point Felyx at a cloud model at all.
#
# WHAT IT CHECKS
#
# Every flag in the option parser of deploy-gcp.sh, meaning the case arms
# between its `while [ $# -gt 0 ]` line and the `done` that closes that loop,
# must also be an arm of the same parser in deploy-aws.sh. The reverse is not
# checked: a flag only the AWS launcher takes is allowed, since nothing forbids
# a cloud from having its own knob.
#
# THE ALLOW-LIST
#
# A GCP flag may be left out of the AWS launcher only by an entry in ALLOW below,
# with the reason it is cloud-specific. There are none today. The gate also fails
# an entry that names no GCP flag, or a flag the AWS launcher now takes, so the
# list cannot go stale into a silence.
#
# WHAT IT DOES NOT DO
#
# It compares flag names, not what each arm does with its value. Two arms that
# take the same name but assign different variables, or consume the wrong number
# of arguments, pass here. Review reads those arms by hand.
#
# NO PARSER, NO VERDICT
#
# If either launcher is missing or has no option parser, the gate says it
# measured nothing and fails. A parser the gate cannot read is not an empty one.

set -euo pipefail
cd "$(dirname "$0")/.."

GCP=cloud/gcp/deploy-gcp.sh
AWS=cloud/aws/deploy-aws.sh

# One entry per line, `flag|why it is cloud-specific`. Empty today: every flag the
# GCP launcher takes, the AWS launcher takes too.
ALLOW=""

for f in "$GCP" "$AWS"; do
	if [ ! -f "$f" ]; then
		printf 'FAIL: %s is missing, so this measured NOTHING about the flags.\n' "$f"
		exit 1
	fi
done

# The flags one launcher's option parser accepts, one per line. The parser is the
# block from `while [ $# -gt 0 ]; do` to the first `done` after it. The `|| true`
# is load-bearing: grep exits 1 on no match, and under pipefail that must read as
# an empty result for the check below to say so, not as a crash with no sentence.
parser_flags() {
	awk '/^while \[ \$# -gt 0 \]; do/ { on = 1; next } on && /^done/ { exit } on { print }' "$1" |
		grep -oE '^[[:space:]]*--[a-z][a-z0-9-]*\)' |
		sed -E 's/^[[:space:]]*//; s/\)$//' || true
}

allowed_names() {
	while IFS='|' read -r name _; do
		if [ -n "$name" ]; then printf '%s\n' "$name"; fi
	done <<<"$ALLOW"
	return 0
}

gcp_flags="$(parser_flags "$GCP")"
aws_flags="$(parser_flags "$AWS")"

if [ -z "$gcp_flags" ]; then
	printf 'FAIL: no option parser found in %s, so this measured NOTHING about the flags.\n' "$GCP"
	exit 1
fi
if [ -z "$aws_flags" ]; then
	printf 'FAIL: no option parser found in %s, so this measured NOTHING about the flags.\n' "$AWS"
	exit 1
fi

problems=0
checked=0

# Here-strings, not `printf | grep -q`: grep -q exits on its first match, which
# under pipefail can turn the producer's SIGPIPE into a false "missing".
for flag in $gcp_flags; do
	checked=$((checked + 1))
	if grep -qx -- "$flag" <<<"$(allowed_names)"; then
		continue
	fi
	if ! grep -qx -- "$flag" <<<"$aws_flags"; then
		printf 'FAIL: %s does not take %s, which %s takes.\n' "$AWS" "$flag" "$GCP"
		problems=$((problems + 1))
	fi
done

while IFS='|' read -r name _; do
	[ -n "$name" ] || continue
	if ! grep -qx -- "$name" <<<"$gcp_flags"; then
		printf 'FAIL: the allow-list names %s, which %s does not take. Remove the entry.\n' "$name" "$GCP"
		problems=$((problems + 1))
	elif grep -qx -- "$name" <<<"$aws_flags"; then
		printf 'FAIL: the allow-list names %s, which %s takes now. Remove the entry.\n' "$name" "$AWS"
		problems=$((problems + 1))
	fi
done <<<"$ALLOW"

if [ "$problems" -gt 0 ]; then
	printf '%d problem(s) in the flags of the two launchers. Give %s the flag, or allow-list\n' "$problems" "$AWS"
	printf 'it in this script with the reason it is cloud-specific.\n'
	exit 1
fi

printf 'OK: %s takes all %d flags that %s takes.\n' "$AWS" "$checked" "$GCP"
