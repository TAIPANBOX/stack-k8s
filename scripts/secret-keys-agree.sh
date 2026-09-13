#!/usr/bin/env bash
#
# Every installer that generates a Secret generates every key the manifests
# read from it.
#
# WHY THIS EXISTS
#
# `10-planes.yaml` and `20-console.yaml` started reading `gateway_admin` from
# the `stack-keys` Secret on 2026-09-07 (GOTCHAS 97). The root `install.sh`
# grew the key the same day. The two cloud installers did not, and nothing here
# noticed, because no gate compared what a manifest READS with what an installer
# WRITES. The first fresh cluster after that change, GCP on 2026-09-13, came up
# with the gateway and the console both in `CreateContainerConfigError`,
# `couldn't find key gateway_admin in Secret agent-stack/stack-keys`, and
# `deploy-gcp.sh` waited five minutes per rollout before its own verify went red.
#
# The same asymmetry, in the same three files, had already happened once with
# `--trust-domain` (invariant 14). Three copies of one block drift; a gate over
# the block is what keeps them one.
#
# WHAT IT CHECKS
#
#   For every script that runs `create secret generic <name>` with a literal
#   name, and every `secretKeyRef` in the manifests that names that Secret:
#   the create block carries `--from-literal=<key>=` or `--from-file=<key>=`.
#
# WHAT IT DOES NOT DO
#
# It reads text. It cannot say the value is right, that the key is not later
# deleted, or that a cluster installed BEFORE a key existed gets it added: that
# migration branch ("secret already exists, add what is missing") is proved on
# a live cluster, not here. A reference marked `optional: true` is not counted:
# a pod starts without it, so an installer owes it nothing. A Secret nobody here generates (an operator-supplied
# model key, the tunnel's token) is out of scope on purpose: the manifests that
# read it say so beside the reference, and its absence is the operator's choice.
#
# SUBJECTS ARE FOUND BY WHAT MAKES THEM SUBJECTS
#
# A subject is a script that CREATES a Secret the manifests read. The set is
# derived from the `create secret generic` invocations in tracked shell scripts,
# never listed by name, so a fourth cloud is checked the day it lands. A script
# creating a Secret under a variable name (security-tests.sh plants a canary
# called "$canary") is not a subject: the manifests cannot read it by name.
set -euo pipefail
cd "$(dirname "$0")/.."

# Every (secret, key) the manifests read, in both YAML spellings:
#   secretKeyRef: { name: stack-keys, key: gateway_admin }
# and
#   secretKeyRef:
#     name: stack-copilot
#     key: api_key
# Fields may come in any order and may be quoted. A reference marked
# `optional: true` is dropped: a pod never enters CreateContainerConfigError on
# an optional key, so an installer owes it nothing. A reference this cannot
# parse is printed as UNPARSED and fails the gate below, never dropped in
# silence: the first version pattern-matched one field order and passed a
# `{ key: k, name: s }` reference clean.
manifest_refs() {
	grep -rhE 'secretKeyRef: *\{' manifests --include='*.yaml' 2>/dev/null |
		grep -v '^[[:space:]]*#' |
		grep -oE 'secretKeyRef: *\{[^}]*\}' |
		awk -F'[{},]' '{
			n = ""; k = ""; opt = 0
			for (i = 1; i <= NF; i++) {
				f = $i; gsub(/["\x27]/, "", f); sub(/^[ \t]+/, "", f); sub(/[ \t]+$/, "", f)
				if (f ~ /^name:/)          { sub(/^name:[ \t]*/, "", f); n = f }
				else if (f ~ /^key:/)      { sub(/^key:[ \t]*/, "", f); k = f }
				else if (f ~ /^optional:/) { if (f ~ /true/) opt = 1 }
			}
			if (opt) next
			if (n == "" || k == "") print "UNPARSED inline secretKeyRef: " $0
			else print n, k
		}' || true
	# The multi-line form: the block runs from `secretKeyRef:` to the first
	# line indented no deeper than it, comments skipped, whatever its length.
	for f in $(git ls-files 'manifests/*.yaml'); do
		awk -v file="$f" '
			function flush() {
				if (!opt) {
					if (n == "" || k == "") print "UNPARSED multi-line secretKeyRef in " file
					else print n, k
				}
			}
			/^[[:space:]]*#/ { next }
			inblk {
				match($0, /^[ \t]*/); ind = RLENGTH
				if ($0 ~ /^[[:space:]]*$/ || ind <= bind) { flush(); inblk = 0 }
				else {
					line = $0; sub(/[ \t]*#.*$/, "", line); gsub(/["\x27]/, "", line)
					if (line ~ /^[ \t-]*name:/)          { sub(/^[ \t-]*name:[ \t]*/, "", line); n = line }
					else if (line ~ /^[ \t-]*key:/)      { sub(/^[ \t-]*key:[ \t]*/, "", line); k = line }
					else if (line ~ /^[ \t-]*optional:/) { if (line ~ /true/) opt = 1 }
					next
				}
			}
			/secretKeyRef:[ \t]*$/ { match($0, /^[ \t]*/); bind = RLENGTH; inblk = 1; n = ""; k = ""; opt = 0 }
			END { if (inblk) flush() }
		' "$f"
	done
}

# Every (script, secret, key) an installer writes. The create block runs from
# the `create secret generic` line to the first line that does not end in a
# backslash, which is how every installer here spells a multi-line kubectl.
# Recognised: `--from-literal=key=...` and `--from-file=key=...`, with or
# without quotes around the pair. NOT recognised, and a create block written
# that way fails the gate loudly rather than passing it: `--from-literal key=v`
# (space instead of `=`), `--from-file=/path` (key from the basename) and
# `--from-env-file=`. The gate constrains the spelling on purpose.
created_keys() {
	local f="$1"
	awk '
		/create secret generic [A-Za-z0-9_.-]+/ {
			match($0, /create secret generic [A-Za-z0-9_.-]+/)
			name = substr($0, RSTART + 22, RLENGTH - 22)
			inblock = 1
		}
		inblock {
			line = $0; gsub(/["\x27]/, "", line)
			while (match(line, /--from-(literal|file)=[A-Za-z0-9_.-]+=/)) {
				kv = substr(line, RSTART, RLENGTH)
				sub(/^--from-(literal|file)=/, "", kv)
				sub(/=$/, "", kv)
				print name, kv
				line = substr(line, RSTART + RLENGTH)
			}
			if ($0 !~ /\\[ \t]*$/) inblock = 0
		}
	' "$f"
}

refs=$(manifest_refs | sort -u)
if printf '%s\n' "$refs" | grep -q '^UNPARSED'; then
	printf 'FAIL: a secretKeyRef this gate could not parse, so it cannot say what that pod reads:\n'
	printf '%s\n' "$refs" | grep '^UNPARSED' | sed 's/^/      /'
	exit 1
fi
if [ -z "$refs" ]; then
	printf 'FAIL: no manifest reads any Secret key, so this measured NOTHING about\n'
	printf '      whether the installers agree with the manifests. That is not a clean run.\n'
	exit 1
fi

# `|| true` is load-bearing: grep exits 1 on no match and `set -e` would end
# this script before the sentence below.
scripts=$(git grep -lE 'create secret generic [A-Za-z0-9_.-]+' -- '*.sh' 2>/dev/null | sort || true)

problems=0
checked=0
for f in $scripts; do
	made=$(created_keys "$f" | sort -u)
	[ -n "$made" ] || continue
	for secret in $(printf '%s\n' "$made" | cut -d' ' -f1 | sort -u); do
		wanted=$(printf '%s\n' "$refs" | awk -v s="$secret" '$1 == s {print $2}')
		[ -n "$wanted" ] || continue
		checked=$((checked + 1))
		for key in $wanted; do
			if ! printf '%s\n' "$made" | grep -qxF "$secret $key"; then
				printf 'FAIL: %s creates Secret %s and does not create key %s, which a\n' "$f" "$secret" "$key"
				printf '      manifest reads. A pod that reads it stays in CreateContainerConfigError.\n'
				problems=$((problems + 1))
			fi
		done
	done
done

if [ "$checked" -eq 0 ]; then
	printf 'FAIL: no script creates a Secret the manifests read, so this measured NOTHING\n'
	printf '      about whether the installers agree with the manifests. That is not a clean run.\n'
	exit 1
fi

if [ "$problems" -gt 0 ]; then
	printf '\n%d problem(s) across %d (installer, Secret) pair(s).\n' "$problems" "$checked"
	exit 1
fi

printf 'OK: %d (installer, Secret) pair(s), each creating every key a manifest reads.\n' "$checked"
