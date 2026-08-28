#!/usr/bin/env bash
# Checks that the gates in `scripts/` still FAIL on the faults they exist to
# catch, still PASS on what they must not catch, and REFUSE to report success
# when they measured nothing at all.
#
# WHY
#
# Every gate here parses text, and a text parser does not break loudly: it
# stops matching and reports success. The mutants that proved each one existed
# as prose, in commit messages and in the `*(gate: ...)*` markers in CLAUDE.md,
# which is a record of what was true once. Nothing ran them again.
#
# A gate that has quietly stopped catching anything looks exactly like a gate
# with nothing to catch, and stays that way until the fault it guards ships.
#
# WHY THE THIRD PROPERTY IS SEPARATE FROM THE FIRST
#
# Because in this repository it found a real hole, the first one the harness
# has found anywhere in the estate.
#
# `pinned-images.sh` printed "OK: 0 image references, all pinned, built here,
# or allowed by name" and exited 0 on a tree where `manifests/*.yaml` matched
# no file. Renaming the manifests to .yml, or moving them into a subdirectory,
# is ordinary housekeeping, and either one silently turned a check on eleven
# images into a check on none, while printing a sentence that asserts the
# opposite. Fixed in the commit before this one; the case below is what keeps
# it fixed.
#
# Two of the other three already refuse on an absent subject and say so. Those
# sentences were true, established by hand once, and nothing re-ran them.
#
# HOW IT MUTATES WITHOUT LEAVING A MESS
#
# It edits tracked files in place, so it refuses to start unless the tree is
# clean, restores with `git checkout` after every case, restores again from a
# trap on any exit path including a kill, and asserts the tree is clean before
# reporting success.
#
#
# A GATE THAT IS ALREADY FAILING CANNOT BE JUDGED
#
# No case proves anything if the gate was already failing before the mutation.
# So every case runs the gate on the UNMUTATED tree first and reports
# UNJUDGEABLE. Found on 2026-08-09 in it-rat, where one gate was legitimately
# red and a case against it would have been indistinguishable from a working
# one.
#
# It covered only the fail-cases at first, which left the mirror of the same
# bug: on a red gate a pass-case reports OVEREAGER, "the gate failed on
# something it must not catch", and sends the reader to look at a harmless
# mutation. The verdict was being given without the predicate it depends on.
#
# A MUTATION THAT DID NOT APPLY PROVES NOTHING
#
# Every edit asserts it changed the file. A case whose edit applied nothing is
# a failure here, not a pass. That is not hypothetical: five such mutations
# were caught across idryx and tokenfuse on 2026-08-09, and three of the five
# had been verified BY HAND against the same gate minutes earlier. The hand
# version and the harness version differ only in how many layers of quoting sit
# between the text and python, which is exactly the difference nobody sees.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

if [ -n "$(git status --porcelain)" ]; then
	printf 'this script mutates tracked files, so it needs a clean tree.\n'
	printf 'commit or stash first; it restores with `git checkout` and cannot\n'
	printf 'tell your edits from its own.\n'
	exit 1
fi

# Untracked files too: a mutation may RENAME a tracked file, and `git checkout`
# restores the original while leaving the new name behind. And the INDEX, since
# a gate may read `git ls-files` rather than the disk, so a mutation has to move
# the file in both. Safe because this
# script refuses to start unless the tree is clean, so anything untracked
# during a run was created by the run. `-x` is deliberately absent: ignored
# build output is not ours to delete.
restore() {
	git reset -q --hard HEAD 2>/dev/null
	git clean -fdq 2>/dev/null
}
baseline_dir="$(mktemp -d)"

# One trap for both, because a second `trap ... EXIT` REPLACES the first
# rather than adding to it. Writing them separately disarmed `restore` on
# every interrupt path, which would leave a mutated tree behind on Ctrl-C.
cleanup() {
	restore
	rm -rf "$baseline_dir"
}
trap cleanup EXIT INT TERM


failures=0
cases=0

# run_case <name> <expect: fail|pass> <gate> <python edit> [required output]
#
# The needle separates "it failed" from "it failed for the reason this case is
# about". Without it, a case expecting failure is satisfied by any failure,
# including one this harness caused itself.
run_case() {
	local name="$1" expect="$2" gate="$3" edit="$4" needle="${5:-}"
	cases=$((cases + 1))

	# The baseline applies to EVERY case, not only the ones expecting a failure.
	# It was `fail`-only until 2026-08-09, which left the mirror of the bug it was
	# written for: on a gate that is already red, a `pass` case reports OVEREAGER,
	# "the gate failed on something it must not catch", and sends the reader to
	# look at a harmless mutation while the gate was failing without it. Neither
	# verdict means anything on a red gate, so neither is given.
	skip_baseline=0
	if [ "$expect" = fail_env ]; then
		# `fail` with the baseline skipped, for cases whose fault IS the command
		# rather than a mutation: red before and after is the point there.
		expect=fail
		skip_baseline=1
	fi

	if [ "$skip_baseline" = 0 ]; then
		local key base_out
		key="$baseline_dir/$(printf '%s' "$gate" | cksum | tr -d ' ')"
		if [ ! -f "$key" ]; then
			if eval "$gate" >/dev/null 2>&1; then printf 'green' >"$key"; else printf 'red' >"$key"; fi
		fi
		base_out="$(cat "$key")"
		if [ "$base_out" = red ]; then
			printf 'UNJUDGEABLE  %s\n             the gate is already failing on a clean tree, so neither a\n             failure nor a pass after the mutation would prove anything\n' "$name"
			failures=$((failures + 1))
			return
		fi
	fi

	if ! python3 -c "$edit"; then
		printf 'BROKEN  %s\n        its mutation did not apply, so this case proved nothing\n' "$name"
		failures=$((failures + 1))
		restore
		return
	fi

	local out rc
	out=$(eval "$gate" 2>&1)
	rc=$?
	restore

	# Exit code first, then wording. Checking the needle before the expectation
	# turns "it did not fail at all" into "it failed for the wrong reason",
	# which sends the reader to look at prose when the gate is toothless.
	if [ "$expect" = fail ] && [ "$rc" -ne 0 ] && [ -n "$needle" ] &&
		! printf '%s' "$out" | grep -qF -- "$needle"; then
		printf 'WRONG REASON  %s\n              it failed, but not saying: %s\n' "$name" "$needle"
		failures=$((failures + 1))
		return
	fi
	if [ "$expect" = fail ] && [ "$rc" -eq 0 ]; then
		printf 'TOOTHLESS  %s\n           the gate passed on a fault it exists to catch\n' "$name"
		failures=$((failures + 1))
	elif [ "$expect" = pass ] && [ "$rc" -ne 0 ]; then
		printf 'OVEREAGER  %s\n           the gate failed on something it must not catch\n' "$name"
		failures=$((failures + 1))
		printf '%s\n' "$out" | head -4 | sed 's/^/           /'
	else
		printf 'ok  %-58s (%s)\n' "$name" "$expect"
	fi
}

py() { printf 'def edit(p, a, b):\n    s = open(p).read()\n    assert a in s, "pattern not found in " + p\n    open(p, "w").write(s.replace(a, b, 1))\n%s\n' "$1"; }

echo "=== faults each gate must catch ==="

# An image tag that moves means a pod can come back different with no rollout,
# on a cluster nobody touched.
# invariant: components.json says what this launcher actually installs.
#
# The Kubernetes half of what stack-up and stack-single carry. Three cases: the
# ordinary drift, the map that makes this deployment's names comparable at all,
# and the reader losing its subject.
run_case "manifest-is-true: a workload is installed and not declared" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'import json
p = "components.json"
d = json.load(open(p))
c = d["components"][0]["checked"]
before = len(c["installs_services"])
c["installs_services"] = [s for s in c["installs_services"] if s != "policy-db"]
assert len(c["installs_services"]) == before - 1, "policy-db was not declared"
json.dump(d, open(p, "w"), indent=2)')" \
	"and components.json does not say so"

# This is the only deployment whose routines are called something else, so the
# map is what makes them comparable. A CronJob mapped to a name the estate does
# not use is a private nickname for a private nickname.
run_case "manifest-is-true: a CronJob is mapped to a routine the estate does not have" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'import json
p = "components.json"
d = json.load(open(p))
c = d["components"][0]["checked"]
assert "drills" in c["schedules_routines"], "the drills CronJob is not mapped"
c["schedules_routines"]["drills"] = "drill-runner"
json.dump(d, open(p, "w"), indent=2)')" \
	"not one of the estate's routines"

# The subject taken away. An empty manifests/ must say it measured nothing
# rather than agree that this deployment installs nothing.
run_case "manifest-is-true: the manifests stop declaring a kind" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'import pathlib
n = 0
for path in sorted(pathlib.Path("manifests").glob("*.yaml")):
    body = path.read_text()
    if "kind:" not in body:
        continue
    path.write_text(body.replace("kind:", "sort:"))
    n += 1
assert n, "no manifest declared a kind to remove"')" \
	"measured NOTHING"

run_case "pinned-images: a tag that moves under the operator" fail \
	'./scripts/pinned-images.sh' \
	"$(py 'import re, glob
for f in sorted(glob.glob("manifests/*.yaml")):
    s = open(f).read()
    m = re.search(r"image: (ghcr\.io/\S+):v[0-9]\S*", s)
    if m:
        open(f, "w").write(s.replace(m.group(0), "image: %s:latest" % m.group(1), 1))
        break
else:
    raise AssertionError("no pinned ghcr image to unpin")')" \
	"moves: a pod can come back different"

# The default apply set must not publish anything to the world, and must not
# apply placeholder secrets.
run_case "closed-by-default: placeholders join the default apply set" fail \
	'./scripts/closed-by-default.sh' \
	"$(py 'edit("manifests/kustomization.yaml", "resources:\n  - 00-base.yaml", "resources:\n  - secrets.example.yaml\n  - 00-base.yaml")')" \
	"placeholder secrets"

run_case "gotchas-classified: an entry with no classification" fail \
	'./scripts/gotchas-classified.sh' \
	"$(py 'edit("GOTCHAS.md", "> **Platform.**", "> Platform, unlabelled.")')" \
	"has no classification"

# A k3s install that does not name the node leaves its identity to whatever
# `hostname` returns at boot, and a machine that comes back under a different
# name registers a SECOND node object while the first sits NotReady forever
# holding its old pod records (FINDINGS.md F3, 2026-08-27).
run_case "node-name-is-pinned: an install that lets the boot choose the name" fail \
	'./scripts/node-name-is-pinned.sh' \
	"$(py 'import re
s = open("cloud/gcp/install-gcp.sh").read()
out = re.sub(r"^ +--node-name .*\n", "", s, count=1, flags=re.M)
assert out != s, "no --node-name line to remove"
open("cloud/gcp/install-gcp.sh", "w").write(out)')" \
	"without --node-name"

echo
echo "=== and what they must NOT catch ==="

# postgres:16-alpine is an upstream tag allowed BY NAME, recorded in the
# script header with its reason. A gate that flagged it would be flagging a
# decision, and would be edited out by whoever hit it.
run_case "pinned-images: the recorded upstream tag stays allowed" pass \
	'./scripts/pinned-images.sh' \
	"$(py 'import glob
for f in sorted(glob.glob("manifests/*.yaml")):
    s = open(f).read()
    if "postgres:16-alpine" in s:
        open(f, "w").write(s.replace("postgres:16-alpine", "postgres:16-alpine", 1) + "\n# a harmless trailing comment\n")
        break
else:
    raise AssertionError("no postgres image reference to leave alone")')"


# Prose describing an unpinned install is not an unpinned install. This gate
# reads code, and the marker below is assembled from pieces so that this very
# file does not become a subject of the gate it is testing.
run_case "node-name-is-pinned: a comment describing an unpinned install" pass \
	'./scripts/node-name-is-pinned.sh' \
	"$(py 'marker = "sh -s " + "- server"
s = open("install.sh").read()
open("install.sh", "w").write(s + "\n# For reference, an unpinned install used to read:\n#   " + marker + " --cluster-init --node-ip 1.2.3.4\n")')"

echo
echo "=== and the one this estate learned the hard way ==="
echo "    a gate whose subject is gone must SAY so, not report OK on nothing"

# THE HOLE. Renaming manifests to .yml made pinned-images.sh report a clean
# run over zero images. This is the case that keeps the fix in place.
run_case "pinned-images: no manifests left to read images from" fail \
	'./scripts/pinned-images.sh' \
	"$(py 'import subprocess, glob
n = 0
for f in sorted(glob.glob("manifests/*.yaml")):
    subprocess.run(["git", "mv", f, f[:-5] + ".yml"], check=True)
    n += 1
assert n, "no manifests in this repo"')" \
	"measured nothing"

run_case "gotchas-classified: no numbered entries left to classify" fail \
	'./scripts/gotchas-classified.sh' \
	"$(py 'import re
s = open("GOTCHAS.md").read()
out = re.sub(r"^## (\d+)\. ", r"### \\1) ", s, flags=re.M)
assert out != s, "no numbered gotcha headings to disable"
open("GOTCHAS.md", "w").write(out)')" \
	"no numbered gotcha sections found"

run_case "node-name-is-pinned: no k3s install left to check" fail \
	'./scripts/node-name-is-pinned.sh' \
	"$(py 'import glob, subprocess
marker = "sh -s " + "- server"
n = 0
for f in sorted(glob.glob("*.sh")) + sorted(glob.glob("cloud/*/*.sh")):
    if marker in open(f).read():
        subprocess.run(["git", "mv", f, f[:-3] + ".bash"], check=True)
        n += 1
assert n, "no installer to move out of the way"')" \
	"measured nothing"

run_case "portability-claims: the comparison sheet loses its section" fail \
	'./scripts/portability-claims.sh' \
	"$(py 'edit("PORTABILITY.md", "## 3. The comparison sheet", "## 3bis. The comparison sheet")')" \
	"has no section 3"

# manifests-valid: the fault it exists for is a MISSPELLED FIELD, not an
# invalid document. Kubernetes ignores an unknown key rather than rejecting it,
# so `readOnlyRootFileSystem` with a capital S leaves a container an operator
# believes is read-only writable, and the manifest reads correctly to a human.
# That is why the gate passes --strict and why this case uses that exact typo
# rather than a malformed document any parser would catch.
run_case "manifests-valid: a misspelled field Kubernetes would silently ignore" fail \
	'./scripts/manifests-valid.sh' \
	"$(py 'edit("manifests/47-scopyx.yaml", "readOnlyRootFilesystem: true", "readOnlyRootFileSystem: true")')" \
	"additional properties"

# The other half: the exclusion list must not become a place to hide a
# manifest. A patch that stops being listed as a patch is either dead or a
# manifest, and both must stop being skipped.
run_case "manifests-valid: a skipped patch is no longer listed as one" fail \
	'./scripts/manifests-valid.sh' \
	"$(py 'edit("tunnel/kustomization.yaml", "path: console-patch.yaml", "path: somewhere-else.yaml")')" \
	"no longer lists it"

echo
if [ -n "$(git status --porcelain)" ]; then
	printf 'FAIL: this script left the tree dirty, so it cannot be trusted about anything above\n'
	git status --porcelain | head -5
	exit 1
fi

if [ "$failures" -gt 0 ]; then
	printf '%d of %d cases failed.\n' "$failures" "$cases"
	printf 'A gate that has quietly stopped catching anything looks exactly like a gate\n'
	printf 'with nothing to catch, and stays that way until the fault it guards ships.\n'
	exit 1
fi

printf 'OK: %d cases. Every gate fails on its own fault, passes on a non-fault,\n' "$cases"
printf '    and refuses to report success when it measured nothing.\n'
