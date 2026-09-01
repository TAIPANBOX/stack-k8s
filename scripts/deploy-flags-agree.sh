#!/usr/bin/env bash
#
# Every deploy path can set the one key that must be set, and sets it in the
# only place where it sticks.
#
# WHY THIS EXISTS
#
# `00-base.yaml` ships `TRAILRYX_TRUST_DOMAIN: set-me.invalid` deliberately,
# because there is no defensible default. An operator sets it by hand, and
# `kubectl apply -k` puts the placeholder straight back: apply reverts the
# fields it MANAGES and leaves alone the ones it does not, so a key the operator
# added survives and a key the manifest declares is overwritten. Both behaviours
# are correct. Together they mean the one key that must be set is the one key
# that cannot stay set by hand. GOTCHAS 90.
#
# The two cloud wrappers grew a `--trust-domain` flag on 2026-09-01 and the
# ROOT script did not, which was found by a reader rather than by anything here:
# a Hetzner deploy had no way at all to set it, and this file is what stops that
# asymmetry coming back.
#
# WHAT IT COSTS WHEN IT IS WRONG, AND WHY THAT IS THE POINT
#
# The record plane accepts an event only if its agent id begins
# `agent://<domain>/`. With the placeholder standing, every event the cluster
# produces is refused as foreign, and a refusal that fires on EVERYTHING reads
# exactly like a quiet night. Nothing errors, nothing is missing, and the plane
# whose entire job is evidence has none.
#
# WHAT IT CHECKS, AND THE SECOND HALF IS THE LOAD-BEARING ONE
#
#   1. every deploy script parses `--trust-domain`
#   2. every one of them applies it AFTER its `apply -k`
#
# The second is the whole reason the flag works. Patching before the
# kustomization is indistinguishable from patching after it by reading the flag
# list, and it is silently useless: the apply that follows reverts it. A check
# that only counted the flag would pass a script that had moved the patch up.
#
# WHAT IT DOES NOT DO
#
# It reads text. It cannot tell that the patch names the right ConfigMap key, or
# that the value is a domain rather than a typo, and it does not run anything.
# What proves the flag actually sticks is a live cluster, which invariants 4 and
# 5 already say this repository cannot hold in a gate.
#
# SUBJECTS ARE FOUND BY WHAT MAKES THEM SUBJECTS, NEVER LISTED AND NEVER BY NAME
#
# A deploy path is a script that APPLIES THE MANIFESTS TO A CLUSTER IT IS
# TALKING TO, which in this repository means invoking `k_ "apply -k .../manifests"`.
# That helper is how a script drives the cluster it just built.
#
# Two narrower rules were tried first and both were wrong in an instructive way.
# Searching for files NAMED `deploy*` found this gate and
# `deploy-target-current.sh`, neither of which deploys anything, and reported a
# failure inside a gate. Searching for the STRING `apply -k` in code then found
# `build.sh`, `install.sh` and both tunnel scripts, where it sits inside a
# printed instruction telling the operator what to type next, plus `tunnel/up.sh`
# where it genuinely runs but against the tunnel overlay, which carries no trust
# domain. A mention is not an invocation and an invocation is not this subject.
#
# A fourth cloud arriving with its own deploy script is then checked the day it
# lands, whatever it is called. A hand-written list would pass it in silence,
# which is the exact defect this repository has found in other people's checks
# twice.
set -euo pipefail
cd "$(dirname "$0")/.."

# `|| true` is load-bearing, not tidiness. grep exits 1 when it matches nothing,
# and under `set -e` that killed this script BEFORE the empty check below, so the
# one case that matters most, every subject gone, exited non-zero and printed
# NOTHING. Found by planting it: an exit code with no sentence beside it is the
# silence this whole file exists to refuse.
scripts=$(grep -rlE '^[^#]*k_ "apply -k[^"]*manifests"' . --include='*.sh' --exclude-dir=.git | sort || true)

if [ -z "$scripts" ]; then
	printf 'FAIL: no deploy script found at all, so this measured NOTHING about\n'
	printf '      whether the deploy paths agree. That is not a clean run.\n'
	exit 1
fi

problems=0
checked=0

for f in $scripts; do
	checked=$((checked + 1))

	if ! grep -q -- '--trust-domain)' "$f"; then
		printf 'FAIL: %s does not parse --trust-domain, so this deploy path cannot set\n' "$f"
		printf '      the one key the manifest deliberately ships invalid.\n'
		problems=$((problems + 1))
		continue
	fi

	# The ordering, by line number, because that is the property. `apply -k` is
	# what reverts a hand-patch, so the flag has to act after the LAST one.
	apply_line=$(grep -nE '^[^#]*k_ "apply -k[^"]*manifests"' "$f" | tail -1 | cut -d: -f1 || true)
	patch_line=$(grep -n 'TRAILRYX_TRUST_DOMAIN' "$f" | grep -i 'patch' | tail -1 | cut -d: -f1 || true)

	if [ -z "$apply_line" ]; then
		printf 'FAIL: %s parses --trust-domain and runs no `apply -k`, so this check\n' "$f"
		printf '      cannot say whether the patch lands after the kustomization.\n'
		problems=$((problems + 1))
		continue
	fi
	if [ -z "$patch_line" ]; then
		printf 'FAIL: %s parses --trust-domain and never patches\n' "$f"
		printf '      TRAILRYX_TRUST_DOMAIN, so the flag is accepted and does nothing.\n'
		problems=$((problems + 1))
		continue
	fi
	if [ "$patch_line" -lt "$apply_line" ]; then
		printf 'FAIL: %s patches the trust domain at line %s, BEFORE its `apply -k` at\n' "$f" "$patch_line"
		printf '      line %s, so the apply reverts it and the flag is silently useless.\n' "$apply_line"
		problems=$((problems + 1))
	fi
done

if [ "$problems" -gt 0 ]; then
	printf '\n%d problem(s) across %d deploy script(s).\n' "$problems" "$checked"
	exit 1
fi

printf 'OK: %d deploy script(s), each parsing --trust-domain and patching it after\n' "$checked"
printf '    its own `apply -k`, which is the only position where it survives.\n'
