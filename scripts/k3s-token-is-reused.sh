#!/usr/bin/env bash
#
# Every installer that brings up a k3s server reuses the token the cluster was
# created with, and reads it before it installs anything.
#
# WHY THIS EXISTS
#
# `install.sh` learned this in a0250b8 ("reuse the cluster's token, so the
# second run is possible at all") and `install-gcp.sh` was written with it.
# `install-aws.sh` was not, and no gate compared the three. Measured on AWS,
# 2026-09-13, the second `deploy-aws.sh` over a healthy five-node cluster: the
# installer minted a fresh K3S_TOKEN, the k3s install script rewrote
# `k3s.service.env` on the first server with it, and k3s refused to start:
#
#   failed to bootstrap cluster data: failed to reconcile with local datastore:
#   bootstrap data already found and encrypted with different token
#
# The other two servers kept etcd quorum, so the cluster looked alive from
# anywhere but the kubeconfig, which points at the dead one. The first server
# was restored by copying the token line from the second server's env file.
# GOTCHAS 102 (the trap itself is entry 59; 102 is the drift). Third time a
# block copied across the three clouds drifted: the deploy scripts once
# (entry 90, invariant 14), the installers twice (entry 101, invariant 17, and
# this). 1dfc242 carried three of that day's fixes into install-aws.sh eight
# hours after a0250b8 and not this one, so diligence was tried and missed it.
#
# WHAT IT CHECKS
#
#   1. every script that runs the k3s install script as a server assigns
#      K3S_TOKEN_VALUE from /var/lib/rancher/k3s/server/token on the first node,
#      over the same ssh helper the install uses (the file is root 0600)
#   2. it does so BEFORE the first server install, whether that install sits on
#      one line or wraps, because a read after it reads the file the install
#      just rewrote
#
# WHAT IT DOES NOT DO
#
# It reads text. That the reuse actually lets a second run through is a
# live-cluster property (invariants 4 and 5), measured on AWS the same day.
#
# SUBJECTS ARE FOUND BY WHAT MAKES THEM SUBJECTS
#
# A subject is a tracked shell script that installs a k3s SERVER: the k3s
# install script invoked as `INSTALL_K3S_VERSION=... sh -s - server`. Not a
# file named install-*, not a script that only mentions k3s in a comment or an
# instruction it prints, and not a gate whose grep pattern names the same words
# (the pattern below is spelled so that node-name-is-pinned.sh, which reads
# every .sh file for the install phrase, does not take this file for an
# installer; the first version of this gate tripped it, and matched itself).
set -euo pipefail
cd "$(dirname "$0")/.."

# `|| true` is load-bearing: grep exits 1 on no match and `set -e` would end
# this script before the sentence below. A subject has a non-comment line that
# runs the k3s installer as a server AND names INSTALL_K3S_VERSION somewhere
# outside a comment, so a gate's regex, a comment, or a printed instruction
# alone does not qualify; a script that has one without the other is named
# loudly below rather than skipped.
scripts=$(git grep -lE '^[^#]*sh -s - serv[e]r' -- '*.sh' 2>/dev/null | sort || true)

if [ -z "$scripts" ]; then
	printf 'FAIL: no script installs a k3s server, so this measured NOTHING about\n'
	printf '      whether the installers reuse the token. That is not a clean run.\n'
	exit 1
fi

problems=0
checked=0
for f in $scripts; do
	if ! grep -qE '^[^#]*INSTALL_K3S_VERSION=' "$f"; then
		printf 'FAIL: %s names the k3s server install and never sets INSTALL_K3S_VERSION, so this\n' "$f"
		printf '      cannot tell an installer from a script that prints one. Spell it as the others do.\n'
		problems=$((problems + 1))
		continue
	fi
	checked=$((checked + 1))
	# Two lines locate the install: the invocation (`su_ "$FIRST" "INSTALL_K3S_VERSION=...`),
	# whose first word is the ssh helper, and the `sh -s - server` that may sit on
	# the same line or on a continuation line below it. The earlier of the two is
	# the install; a read has to come before it. Anchoring on the `sh -s` line
	# alone let a wrapped first-server install slide the anchor down to the
	# joining-server line and pass a read placed between them.
	inv_line=$(grep -nE '^[^#]*(su_|sh_) "\$FIRST" "INSTALL_K3S_VERSION=' "$f" | head -1 | cut -d: -f1 || true)
	srv_line=$(grep -nE '^[^#]*sh -s - serv[e]r' "$f" | head -1 | cut -d: -f1 || true)
	if [ -z "$inv_line" ] || [ -z "$srv_line" ]; then
		printf 'FAIL: %s matched as an installer but its first-server install could not be located\n' "$f"
		printf '      (invocation line: %s, server line: %s). This gate reads one spelling; keep it.\n' "${inv_line:-none}" "${srv_line:-none}"
		problems=$((problems + 1))
		continue
	fi
	install_line=$inv_line
	[ "$srv_line" -lt "$install_line" ] && install_line=$srv_line
	inv_helper=$(sed -n "${inv_line}p" "$f" | sed -E 's/^[[:space:]]*([a-z_]+) .*/\1/')

	# The read is an ASSIGNMENT from the token file over the same helper, not a
	# mention of the path: `echo "recovery: cat .../token"` above the install is
	# text, and a read over a different helper (`sh_` where the login cannot read
	# a root-owned 0600 file) comes back empty and mints a fresh token anyway.
	read_line=$(grep -nE '^[^#]*K3S_TOKEN_VALUE=.*\$\((su_|sh_) .*cat /var/lib/rancher/k3s/server/token' "$f" | head -1 | cut -d: -f1 || true)
	if [ -z "$read_line" ]; then
		printf 'FAIL: %s installs a k3s server and never assigns K3S_TOKEN_VALUE from\n' "$f"
		printf '      /var/lib/rancher/k3s/server/token, so its second run mints a new token and the first server refuses to start.\n'
		problems=$((problems + 1))
		continue
	fi
	read_helper=$(sed -n "${read_line}p" "$f" | sed -E 's/.*\$\(([a-z_]+) .*/\1/')
	if [ "$read_helper" != "$inv_helper" ]; then
		printf 'FAIL: %s reads the token over %s and installs over %s: a read over the wrong helper\n' "$f" "$read_helper" "$inv_helper"
		printf '      comes back empty (the token file is root-owned, mode 0600) and a fresh token is minted.\n'
		problems=$((problems + 1))
		continue
	fi
	if [ "$read_line" -gt "$install_line" ]; then
		printf 'FAIL: %s reads the token at line %s, AFTER its first server install at line %s,\n' "$f" "$read_line" "$install_line"
		printf '      which is the file that install just rewrote with a fresh token.\n'
		problems=$((problems + 1))
	fi
done

if [ "$checked" -eq 0 ]; then
	printf 'FAIL: no installer could be judged, so this measured NOTHING. That is not a clean run.\n'
	exit 1
fi

if [ "$problems" -gt 0 ]; then
	printf '\n%d problem(s) across %d installer(s).\n' "$problems" "$checked"
	exit 1
fi

printf 'OK: %d installer(s), each reading the token this cluster was created with before\n' "$checked"
printf '    it installs a k3s server, so a second run joins the cluster instead of breaking it.\n'
