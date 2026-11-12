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
#
# TWO BRACE PAIRS IN ONE py BLOCK, AGAIN
#
# The hazard below came back on 2026-10-04: 18 of 57 new cases failed their first
# run, the mutation silently rewritten to a no-op or the needle to the edit
# script's own text, because each carried a manifest line like `{ name: X, value:
# "5.00" }` twice in one `py '...'` block. A literal brace in a py block is not
# safe on bash 3.2 whatever the count looks like, so the cases added that day
# spell every brace \x7b and \x7d and nothing else in them can be expanded.
#
# A CASE CAN PASS IN CI AND MISBEHAVE LOCALLY
#
# On bash 3.2, which is the bash on this machine, an unquoted brace pair
# inside "$(...)" splits the argument into two words, and CI's bash 5 does
# not: commit 939f686 (a two-brace-pair case, since fixed in 73a2e63) ran
# green in CI while reporting WRONG REASON here, so a case that only ever
# runs in CI is not proven at all.

# A running bash reads its script file as it goes. The cases below edit this file
# and then `git reset` it, which replaces the file under the shell; a shell still
# reading the old inode would parse the edited bytes (found on 2026-10-14, when a
# planted filter made shard 1 stop with a syntax error). So the run continues
# from a copy of itself that no case touches. The copy is removed on exit.
if [ "${TEETH_RUN_COPY:-}" != "$0" ]; then
	run_copy="$(mktemp)" || exit 1
	cp "$0" "$run_copy" || exit 1
	TEETH_RUN_COPY="$run_copy" exec "$BASH" "$run_copy" "$@"
fi
discard_copy() {
	if [ "${TEETH_RUN_COPY:-}" = "$0" ]; then
		rm -f "$0"
	fi
}
trap discard_copy EXIT

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

# Two switches, read before anything else. Unset, a run is exactly what it was.
#
# TEETH_SHARD=i/N runs only the cases whose position k (1-based, in the order
# they are written) has (k - 1) % N == i - 1. CI runs the shards as parallel
# jobs, one each; scripts/teeth-shards-cover-every-case.sh proves that together they run
# every case once.
#
# TEETH_LIST=1 prints each case name, one per line, and runs none of them. It
# mutates nothing, so it must not reset a tree that holds someone's work: the
# listing writes to fd 3, everything else goes to /dev/null, and restore() is a
# no-op while listing.
shard_i=""
shard_n=""
ran=0
if [ -n "${TEETH_SHARD:-}" ]; then
	shard_i="${TEETH_SHARD%/*}"
	shard_n="${TEETH_SHARD#*/}"
	if ! grep -Eq '^[0-9]+/[0-9]+$' <<<"$TEETH_SHARD" ||
		[ "$shard_i" -lt 1 ] || [ "$shard_i" -gt "$shard_n" ]; then
		printf 'TEETH_SHARD must be i/N with 1 <= i <= N, not "%s"\n' "$TEETH_SHARD"
		exit 1
	fi
fi
if [ "${TEETH_LIST:-}" = 1 ]; then
	exec 3>&1 1>/dev/null
fi

if [ "${TEETH_LIST:-}" != 1 ] && [ -n "$(git status --porcelain)" ]; then
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
	if [ "${TEETH_LIST:-}" = 1 ]; then
		return 0
	fi
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
	discard_copy
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

	# Position k of this case decides its shard (see the head). A case outside
	# this shard is neither run nor judged here; the shard that owns it runs it.
	if [ -n "$shard_i" ] && [ $(( (cases - 1) % shard_n )) -ne $((shard_i - 1)) ]; then
		return
	fi
	if [ "${TEETH_LIST:-}" = 1 ]; then
		printf '%s\n' "$name" >&3
		return
	fi
	ran=$((ran + 1))

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
		! grep -qF -- "$needle" <<<"$out"; then
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

py() { printf 'def edit(p, a, b):\n    s = open(p).read()\n    assert a in s, "pattern not found in " + p\n    assert a != b, "edit replaces a string with itself in " + p\n    open(p, "w").write(s.replace(a, b, 1))\n    assert open(p).read() != s, "edit changed nothing in " + p\n%s\n' "$1"; }

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

# `manual_jobs` is a claim ABOUT an object, so the two cases below plant the
# fault on each side of that claim: the manifest stops matching it, and the
# reason behind it goes away.
#
# Neither case has a real subject any more. costcrew-crew was the one CronJob
# here that spent on an account outside the cluster while it shipped as a
# manual_jobs template, and it graduated out of that bucket on 2026-09-03:
# v0.2.0's `-due` gates spending at the console's own cadence switch instead
# of at Kubernetes suspend, so the manifest now correctly sets
# `suspend: false` and components.json correctly declares no manual job at
# all. A check with nothing to mutate proves nothing, so both cases below
# plant a SYNTHETIC manual_jobs entry onto `drills`, a real CronJob that
# really does carry `suspend: true` today, edited only inside this one
# mutation and never written back.
run_case "manifest-is-true: a manual job is not actually suspended" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'import json, pathlib
p = "components.json"
d = json.load(open(p))
c = d["components"][0]["checked"]
c["manual_jobs"] = {"drills": "planted by gates-have-teeth.sh: a real suspended CronJob, borrowed for this one case"}
json.dump(d, open(p, "w"), indent=2)
n = 0
for path in sorted(pathlib.Path("manifests").glob("*.yaml")):
    body = path.read_text()
    if "suspend: true" not in body:
        continue
    path.write_text(body.replace("suspend: true", "suspend: false"))
    n += 1
assert n, "no manifest set suspend: true, so the claim was already unbacked"')" \
	"does not set"

run_case "manifest-is-true: a manual job carries no reason" fail \
	'./scripts/manifest-is-true.sh' \
	"$(py 'import json
p = "components.json"
d = json.load(open(p))
c = d["components"][0]["checked"]
c["manual_jobs"] = {"drills": "   "}
json.dump(d, open(p, "w"), indent=2)')" \
	"gives no"

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

# security-tests.sh runs probe pods on a live cluster too, and pinned-images.sh
# started reading it on 2026-09-07 after four of those pods sat on a stale tag
# with nothing noticing. Same fault, same gate, the other file it now reads.
run_case "pinned-images: a tag that moves, planted in security-tests.sh" fail \
	'./scripts/pinned-images.sh' \
	"$(py 'edit("security-tests.sh", "image: ghcr.io/taipanbox/genaryx-console:v1.8.8@sha256:55765e22aeb5a157099b30a9ecbda53b83121c17b3b98b6896af5733ba16f9a5", "image: ghcr.io/taipanbox/genaryx-console:latest")')" \
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

# A pod that automounts the default ServiceAccount token holds a valid API
# credential nothing in this stack needs, and the day an operator binds a Role
# to `default` for an unrelated reason it stops being pointed at nothing.
run_case "no-sa-token-by-default: a pod template loses the field" fail \
	'./scripts/no-sa-token-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "      automountServiceAccountToken: false\n", "")')" \
	"does not set"

# The class of mistake this gate exists for: an operator-only file joining
# the tracked set with nothing else in this repo positioned to notice, since
# every other gate here reads content or manifests rather than names. See
# GOTCHAS.md entry 99, where cloud/gcp/terraform.tfvars.bak did exactly this
# for 76 commits.
#
# Three cases, not one, because root and nested are different blind spots
# and closing one silently opened the other. The first round planted only
# at the repository root (planted-secret.pem). A second review found that
# left two mutants alive against a NESTED path, one that skips any path
# containing a slash and one that matches the whole path instead of the
# basename, and neither would have caught the file this gate actually
# exists for, so the root-level case was replanted nested. That traded one
# gap for its mirror: a third review found `if "/" not in path: return
# None` inside `shape_of` survives every nested case untouched, because it
# only exempts a path with no directory component, and the harness reported
# a clean run even though the gate had silently stopped seeing anything at
# the repository root, the placement GOTCHAS 99 and that review both call
# the most common real one for a stray `.env` or `id_rsa`. So all three
# stay: root, and the nested glob and nested exact shapes below.
run_case "no-operator-files-tracked: an operator file gets tracked at the repository root" fail \
	'./scripts/no-operator-files-tracked.sh' \
	"$(py 'import subprocess
p = "gates-have-teeth-plant.env"
open(p, "w").write("planted by gates-have-teeth.sh: a fake operator file\n")
subprocess.run(["git", "add", p], check=True)')" \
	"matches the operator-file shape"

# Nested, not at the repository root: this is the shape GOTCHAS 99 actually
# was. Under a synthetic gates-have-teeth-plant/ directory rather than
# literally at cloud/gcp/terraform.tfvars.bak: a real GCP or AWS run leaves
# real, gitignored terraform state at that exact path (confirmed present on
# the machine this case was written on), and `git reset --hard` only ever
# reverts a TRACKED path back to HEAD, so staging over a real untracked
# file here would leave it silently replaced by this case's fake content
# forever, not restored by restore() below. `git add -f` because
# .gitignore now excludes this shape on purpose.
run_case "no-operator-files-tracked: an operator file gets tracked" fail \
	'./scripts/no-operator-files-tracked.sh' \
	"$(py 'import subprocess
p = "cloud/gcp/gates-have-teeth-plant/terraform.tfvars.bak"
subprocess.run(["mkdir", "-p", "cloud/gcp/gates-have-teeth-plant"], check=True)
open(p, "w").write("planted by gates-have-teeth.sh: a fake operator file\n")
subprocess.run(["git", "add", "-f", p], check=True)')" \
	"matches the operator-file shape"

# A second, nested EXACT name, not a glob suffix: this is what actually
# distinguishes the two nested-path mutants named above. fnmatch's "*"
# spans "/" (verified: fnmatch.fnmatch("cloud/gcp/x.tfvars.bak",
# "*.tfvars.*") is True), so a whole-path-instead-of-basename mutant still
# happens to catch the glob case above by accident. It cannot accidentally
# catch an EXACT shape like "terraform.tfstate": the whole path is never
# equal to the bare name.
run_case "no-operator-files-tracked: a nested exact shape gets tracked" fail \
	'./scripts/no-operator-files-tracked.sh' \
	"$(py 'import subprocess
p = "cloud/gcp/gates-have-teeth-plant/terraform.tfstate"
subprocess.run(["mkdir", "-p", "cloud/gcp/gates-have-teeth-plant"], check=True)
open(p, "w").write("planted by gates-have-teeth.sh: a fake operator file\n")
subprocess.run(["git", "add", "-f", p], check=True)')" \
	"matches the operator-file shape"

# The allow list itself must not be able to rot: an entry naming a path git
# no longer tracks is a hole with a reason attached to it, and nothing would
# notice it sitting there unused. Mutates the gate's own ALLOWED dict, the
# same way other cases here mutate the file a gate reads.
TEETH_EDIT_1="$(py 'edit("scripts/no-operator-files-tracked.sh", "ALLOWED = {\n", "ALLOWED = {\n    \"cloud/gcp/nonexistent.tfvars.bak\": \"planted by gates-have-teeth.sh: this path is not tracked\",\n")')"
run_case "no-operator-files-tracked: a stale allow-list entry" fail \
	'./scripts/no-operator-files-tracked.sh' \
	"$TEETH_EDIT_1" \
	"is allow-listed in this script but"

# The allow list rots the other way too: a path that IS tracked but whose
# basename never matched a shape in the first place has been suppressing
# nothing since the day it was written, and nobody would notice that
# either. CLAUDE.md is always tracked and matches none of the SHAPES above.
TEETH_EDIT_2="$(py 'edit("scripts/no-operator-files-tracked.sh", "ALLOWED = {\n", "ALLOWED = {\n    \"CLAUDE.md\": \"planted by gates-have-teeth.sh: this path matches no shape at all\",\n")')"
run_case "no-operator-files-tracked: an allow-list entry that matches no shape" fail \
	'./scripts/no-operator-files-tracked.sh' \
	"$TEETH_EDIT_2" \
	"matches no operator-file shape"

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

# A Service is not a pod template, and this gate must not ask it for a field
# that only means something on one. The comment planted here would trip a
# gate that found "kind:" or "restartPolicy:" anywhere in the text rather than
# reading structure; genaryx-console-lb has none of its own.
run_case "no-sa-token-by-default: a non-pod object carries no such field" pass \
	'./scripts/no-sa-token-by-default.sh' \
	"$(py 'edit("manifests/50-loadbalancer.yaml", "spec:\n  type: LoadBalancer", "spec:\n  # not a pod template: kind: Deployment / template: / restartPolicy: OnFailure\n  type: LoadBalancer")')"

# The same shape, sitting on disk and never staged, must stay silent: this
# gate exists to keep an operator file OUT of git, not to complain that one
# exists on a machine. `git add` is deliberately never called here.
run_case "no-operator-files-tracked: the same shape, left untracked, is not a fault" pass \
	'./scripts/no-operator-files-tracked.sh' \
	"$(py 'p = "local-only.key"
open(p, "w").write("never staged, just sitting on disk\n")')"

echo
echo "=== and the one this estate learned the hard way ==="
echo "    a gate whose subject is gone must SAY so, not report OK on nothing"

# THE HOLE. Renaming manifests to .yml made pinned-images.sh report a clean
# run over zero images. This is the case that keeps the fix in place.
# Both of the gate's sources have to be taken away for "measured nothing" to
# be the honest answer: since 2026-09-07 it also reads security-tests.sh, so
# renaming the manifests alone would leave that file's images still counted,
# and the gate would report a clean pass over a real subject rather than
# admitting it has nothing left to read.
run_case "pinned-images: no manifests or security-tests.sh left to read images from" fail \
	'./scripts/pinned-images.sh' \
	"$(py 'import subprocess, glob
n = 0
for f in sorted(glob.glob("manifests/*.yaml")):
    subprocess.run(["git", "mv", f, f[:-5] + ".yml"], check=True)
    n += 1
subprocess.run(["git", "mv", "security-tests.sh", "security-tests.sh.bak"], check=True)
n += 1
assert n, "no manifests and no security-tests.sh in this repo"')" \
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

# Invariant 14, three cases, and the middle one is the reason the gate compares
# line numbers instead of counting a flag. A `--trust-domain` parsed and applied
# BEFORE the kustomization reads identically in a flag list and is silently
# useless, because the apply that follows reverts it.
TEETH_EDIT_3="$(py 'edit("deploy.sh", "    --trust-domain)  TRUST_DOMAIN=\"$2\"; shift 2 ;;\n", "")')"
run_case "deploy-flags-agree: a deploy path stops taking --trust-domain" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$TEETH_EDIT_3" \
	"does not parse --trust-domain"

TEETH_EDIT_4="$(py 'edit("deploy.sh", "TRAILRYX_TRUST_DOMAIN\\\":\\\"$TRUST_DOMAIN", "TRAILRYX_TRUST_DOMAI_N\\\":\\\"$TRUST_DOMAIN")')"
run_case "deploy-flags-agree: the flag is accepted and patches nothing" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$TEETH_EDIT_4" \
	"never applies"

run_case "deploy-flags-agree: no deploy path left to judge" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'import os
for f in ("deploy.sh", "cloud/aws/deploy-aws.sh", "cloud/gcp/deploy-gcp.sh"):
    os.remove(f)')" \
	"measured NOTHING"

# Three installers each carry a copy of the block that generates `stack-keys`,
# and two of the three shipped without the key the manifests had started to
# read. The fault is one missing `--from-literal`, so that is what is planted;
# the mirror fault is a manifest reading a key nobody writes; and a key an
# installer writes that no manifest reads is NOT this gate's business, which the
# pass case holds.
# The manifest edit names no brace pair on purpose: `{ name: ..., key: ... }`
# inside "$(...)" is exactly the bash 3.2 expansion the header above describes,
# and the first version of this case applied a different edit, missed the fault
# and reported TOOTHLESS here while the gate itself was fine.
TEETH_EDIT_5="$(py 'edit("install.sh", "      gateway_admin=\"$GATEWAY_ADMIN_SECRET\" \\\n", "")')"
run_case "secret-keys-agree: an installer stops creating a key the manifests read" fail \
	'./scripts/secret-keys-agree.sh' \
	"$TEETH_EDIT_5" \
	"does not create key gateway_admin"

run_case "secret-keys-agree: a manifest starts reading a key no installer writes" fail \
	'./scripts/secret-keys-agree.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "stack-keys, key: gateway_admin", "stack-keys, key: gateway_admin_v2")')" \
	"does not create key gateway_admin_v2"

run_case "secret-keys-agree: a manifest reads a key no installer writes, multi-line spelling" fail \
	'./scripts/secret-keys-agree.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "valueFrom: { secretKeyRef: { name: stack-keys, key: gateway_admin } }", "valueFrom:\n                secretKeyRef:\n                  name: stack-keys\n                  key: gateway_admin_v2")')" \
	"does not create key gateway_admin_v2"

run_case "secret-keys-agree: no manifest left that reads a Secret" fail \
	'./scripts/secret-keys-agree.sh' \
	"$(py 'import glob
for f in glob.glob("manifests/*.yaml"):
    s = open(f).read()
    open(f, "w").write(s.replace("secretKeyRef", "secretKeyRe_f"))')" \
	"measured NOTHING"

run_case "secret-keys-agree: an installer writes a key nothing reads" pass \
	'./scripts/secret-keys-agree.sh' \
	"$(py 'edit("install.sh", "      cloud_admin=\"$CLOUD_SECRET\" \\\n", "      cloud_admin=\"$CLOUD_SECRET\" \\\n      spare=\"$CLOUD_SECRET\" \\\n")')"

# evidence/identity-kind/run.sh creates stack-keys with every key the manifests read, so
# it is an (installer, Secret) subject too: the gate judges it and passes it, which is
# correct. Taking the installers away therefore takes it away too, or the case would
# measure a Secret creator instead of none. evidence/agent-tokens-kind/run-v1.18.0.sh creates the
# stand-in Secrets of its scratch cluster the same way, so it goes with them, and so does the v1.19.0 run.
# lib/vouchryx-mint.sh creates vouchryx-keys with a literal name, so it is a Secret creator too, and goes with them.
run_case "secret-keys-agree: no installer left to judge" fail \
	'./scripts/secret-keys-agree.sh' \
	"$(py 'import os
for f in ("install.sh", "cloud/aws/install-aws.sh", "cloud/gcp/install-gcp.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh", "delegation/up.sh", "closure/up.sh", "evidence/identity-kind/run.sh", "evidence/tool-hold-kind/run.sh", "evidence/require-agent-tokens-kind/run-v1.19.0.sh", "lib/vouchryx-mint.sh", "evidence/agent-tokens-kind/run-v1.18.0.sh", "evidence/identity-kind/mint.sh"):
    os.remove(f)')" \
	"measured NOTHING"

# Three installers each bring up a k3s server, and the second run of one of
# them killed the first server on AWS because it alone minted a fresh token.
# The fault planted is the read of the existing token taken away; the mirror
# is the read moved BELOW the install, where it reads a file the install just
# rewrote. No brace pair in any edit string (bash 3.2, see the header).
run_case "k3s-token-is-reused: an installer stops reading the cluster's token" fail \
	'./scripts/k3s-token-is-reused.sh' \
	"$(py 'edit("install.sh", "cat /var/lib/rancher/k3s/server/token || echo __ABSENT__", "echo __ABSENT__")')" \
	"never assigns K3S_TOKEN_VALUE from"

run_case "k3s-token-is-reused: the token is read after the install rewrote it" fail \
	'./scripts/k3s-token-is-reused.sh' \
	"$(py 'edit("install.sh", "  K3S_TOKEN_VALUE=\"$(sh_ \"$FIRST\" \"sh -c", "  K3S_TOKEN_VALUE_HELD=\"$(sh_ \"$FIRST\" \"sh -c")
s = open("install.sh").read()
j = s.index("# ---- 3. the other servers")
open("install.sh", "w").write(s[:j] + "K3S_TOKEN_VALUE=\"$(sh_ \"$FIRST\" \x27cat /var/lib/rancher/k3s/server/token\x27)\"\n" + s[j:])')" \
	"AFTER its first server install"

run_case "k3s-token-is-reused: a comment mentioning the install is not an installer" pass \
	'./scripts/k3s-token-is-reused.sh' \
	"$(py 'edit("install.sh", "#!/usr/bin/env bash\n", "#!/usr/bin/env bash\n# this comment names the k3s install phrase and installs nothing: INSTALL_K3S_VERSION=x sh -s - serv" + "er\n")')"

# The first-server install wrapped over two lines, with the read moved between
# the first-server and the joining-server installs: the first version of the
# gate anchored its ordering check on the `sh -s` line alone, so the wrap slid
# the anchor down to the joining-server line and the misplaced read passed.
run_case "k3s-token-is-reused: a wrapped first-server install hides a read placed after it" fail \
	'./scripts/k3s-token-is-reused.sh' \
	"$(py 'p = "cloud/aws/install-aws.sh"
s = open(p).read()
start = s.index("  K3S_TOKEN_VALUE=\"$(su_ \"$FIRST\" \"sh -c ")
end = s.index("\n", s.index("|| die \"could not read the cluster token", start)) + 1
stmt = s[start:end]
s = s[:start] + s[end:] + "\n" + stmt
open(p, "w").write(s)')" \
	"AFTER its first server install"

# The silent mutant: the read over the login helper instead of the sudo one.
# On the box the token file is root-owned 0600, so `sh_` reads nothing and the
# installer mints a fresh token with every line of the reuse block in place.
TEETH_EDIT_6="$(py 'edit("cloud/aws/install-aws.sh", "K3S_TOKEN_VALUE=\"$(su_ \"$FIRST\" \"sh -c", "K3S_TOKEN_VALUE=\"$(sh_ \"$FIRST\" \"sh -c")')"
run_case "k3s-token-is-reused: the token is read over a helper that cannot read it" fail \
	'./scripts/k3s-token-is-reused.sh' \
	"$TEETH_EDIT_6" \
	"reads the token over sh_ and installs over su_"

run_case "k3s-token-is-reused: no installer left to judge" fail \
	'./scripts/k3s-token-is-reused.sh' \
	"$(py 'import os
for f in ("install.sh", "cloud/aws/install-aws.sh", "cloud/gcp/install-gcp.sh"):
    os.remove(f)')" \
	"measured NOTHING"

# The subject taken away entirely: with nothing left in the index, this gate
# has no tracked file list to check an operator-file shape against, and
# agreeing that a repository with nothing in it also has no operator files
# in it would be the same silent hole invariant 9 is about. `git rm --cached`
# leaves the working tree untouched, so restore() (reset --hard) puts every
# path straight back in the index.
run_case "no-operator-files-tracked: nothing left in the index to check" fail \
	'./scripts/no-operator-files-tracked.sh' \
	"$(py 'import subprocess
subprocess.run(["git", "rm", "-r", "--cached", "-q", "."], check=True)')" \
	"measured NOTHING"

# The GCP preflight rewrote the operator's machine type with its own default
# (GOTCHAS 103, invariant 19). The gate runs the real script under stubs over a
# seeded tfvars; the fault is the read-back of the file's value taken away, so
# the default wins again exactly as it did on 2026-09-13.
TEETH_EDIT_7="$(py 'edit("cloud/gcp/preflight.sh", "MACHINE_TYPE=\"${MACHINE_TYPE:-$(tfvar_ machine_type || true)}\"", "MACHINE_TYPE=\"${MACHINE_TYPE:-}\"")')"
run_case "preflight-keeps-tfvars: the file's machine type is no longer read back" fail \
	'./scripts/preflight-keeps-tfvars.sh' \
	"$TEETH_EDIT_7" \
	"machine_type: the file said c2d-highcpu-8"

# The default itself changing is not the fault: the gate judges what the file
# said against what was written back, so a new default must not fire it.
run_case "preflight-keeps-tfvars: a changed default is not a rewrite" pass \
	'./scripts/preflight-keeps-tfvars.sh' \
	"$(py 'edit("cloud/gcp/preflight.sh", "MACHINE_TYPE=\"${MACHINE_TYPE:-c3d-highcpu-8}\"", "MACHINE_TYPE=\"${MACHINE_TYPE:-c4-highcpu-8}\"")')"

run_case "preflight-keeps-tfvars: no preflight left to run" fail \
	'./scripts/preflight-keeps-tfvars.sh' \
	"$(py 'import os
os.remove("cloud/gcp/preflight.sh")')" \
	"measured nothing"

# The gateway's semantic cache defaults to shadow mode, one global mutex per
# call, whenever TOKENFUSE_CACHE is unset (tokenfuse#319). A container losing
# the line is the ordinary drift this gate exists for.
TEETH_EDIT_8="$(py 'edit("manifests/10-planes.yaml", "            - { name: TOKENFUSE_CACHE, value: \"off\" }\n", "")')"
run_case "gateway-cache-is-off: a gateway container loses TOKENFUSE_CACHE" fail \
	'./scripts/gateway-cache-is-off.sh' \
	"$TEETH_EDIT_8" \
	"no TOKENFUSE_CACHE env var"

# The variable present but wrong is a different failure than absent, and the
# gate has to say which value it actually found.
TEETH_EDIT_9="$(py 'edit("manifests/10-planes.yaml", "- { name: TOKENFUSE_CACHE, value: \"off\" }", "- { name: TOKENFUSE_CACHE, value: \"on\" }")')"
run_case "gateway-cache-is-off: a gateway container sets TOKENFUSE_CACHE to something other than off" fail \
	'./scripts/gateway-cache-is-off.sh' \
	"$TEETH_EDIT_9" \
	"TOKENFUSE_CACHE='on'"

# A sidecar that runs the same published image but with a subcommand (here,
# focus-export) never reaches the semantic cache, and must not be judged as
# if it were the gateway itself. Swapping its command onto the bare binary,
# with its args: block left standing, checks that the args: key is what
# excludes it, not the binary name.
run_case "gateway-cache-is-off: a subcommand sidecar is not a gateway container" pass \
	'./scripts/gateway-cache-is-off.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "command: [\"/bin/sh\", \"-c\"]", "command: [\"/usr/local/bin/tokenfuse\"]")')"

# The subject taken away: the gateway container's image line is the only
# thing that makes it a subject at all, so changing it removes the one
# matching container from every manifest kustomization.yaml includes.
run_case "gateway-cache-is-off: no gateway container left to judge" fail \
	'./scripts/gateway-cache-is-off.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "          image: ghcr.io/taipanbox/tokenfuse:v1.25.0@sha256:3a81dbcd116557eff54aae29e7d68104af8fc788265d58e71adf3f96fea03317\n", "          image: ghcr.io/taipanbox/tokenfuse-other:v1.0.4\n")')" \
	"measured nothing about the"

# The gateway's declassify key (invariant 27). POST /v1/fuse/declassify lifts a
# run's taint label and its credential is optional in the gateway, so a
# container that does not carry the key leaves the endpoint open to anything
# that reaches port 4100. Four ways the manifest half goes wrong, and the
# mirror faults in the installers, where the key must come in on stdin.
run_case "declassify-is-keyed: the gateway container loses TOKENFUSE_DECLASSIFY_KEY" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - name: TOKENFUSE_DECLASSIFY_KEY\n              valueFrom: { secretKeyRef: { name: stack-keys, key: declassify_key } }\n", "")')" \
	"no TOKENFUSE_DECLASSIFY_KEY env var"

TEETH_EDIT_10="$(py 'edit("manifests/10-planes.yaml", "              valueFrom: { secretKeyRef: { name: stack-keys, key: declassify_key } }\n", "              value: \"change-me\"\n")')"
run_case "declassify-is-keyed: the key becomes a literal in the manifest" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$TEETH_EDIT_10" \
	"set from a literal value"

run_case "declassify-is-keyed: the key is marked optional" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "key: declassify_key } }", "key: declassify_key, optional: true } }")')" \
	"marked optional"

run_case "declassify-is-keyed: the gateway reads some other key of the Secret" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "key: declassify_key } }", "key: gateway_admin } }")')" \
	"not stack-keys/declassify_key"

# The key travels on stdin. An argument is readable in the process table of
# both ends of the ssh, and the audit found --from-literal values on ssh argv.
TEETH_EDIT_11="$(py 'edit("install.sh", "      declassify_key=\"$DECLASSIFY_SECRET\" \\\n", "      declassify_key=\"$DECLASSIFY_SECRET\" \\\n      --from-literal=declassify_key=\x27$DECLASSIFY_SECRET\x27 \\\n")')"
run_case "declassify-is-keyed: an installer passes the key with --from-literal" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$TEETH_EDIT_11" \
	"puts declassify_key on a command line with --from-literal"

TEETH_EDIT_12="$(py 'edit("cloud/gcp/install-gcp.sh", "    printf \x27%s\x27 \"{\\\"stringData\\\":{\\\"declassify_key\\\":\\\"$DECLASSIFY_SECRET\\\"}}\" | k_ \"-n agent-stack patch secret stack-keys --type merge --patch-file /dev/stdin\" >/dev/null\n", "    k_ \"-n agent-stack patch secret stack-keys --type merge -p \x27{\\\"stringData\\\":{\\\"declassify_key\\\":\\\"$DECLASSIFY_SECRET\\\"}}\x27\" >/dev/null\n")')"
run_case "declassify-is-keyed: an installer migrates the key with patch -p" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$TEETH_EDIT_12" \
	"patches declassify_key on a command line"

TEETH_EDIT_13="$(py 'edit("install.sh", "      declassify_key=\"$DECLASSIFY_SECRET\" \\\n    | k_ \"-n agent-stack create -f -\" >/dev/null", "      declassify_key=\"$DECLASSIFY_SECRET\" \\\n    k_ \"-n agent-stack create -f -\" >/dev/null")')"
run_case "declassify-is-keyed: an installer creates the Secret without piping the key in" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$TEETH_EDIT_13" \
	"never creates declassify_key from stdin"

TEETH_EDIT_14="$(py 'edit("install.sh", "--patch-file /dev/stdin\" >/dev/null\n    echo \"   added declassify_key", "--patch-file /tmp/p\" >/dev/null\n    echo \"   added declassify_key")')"
run_case "declassify-is-keyed: an installer never gives an existing Secret the key" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$TEETH_EDIT_14" \
	"has no stdin patch for declassify_key"

# The subjects taken away: the gateway container's image line is what makes it
# a subject, and with no installer left there is nothing to read the mint from.
# Each must say it measured nothing, never OK.
run_case "declassify-is-keyed: no gateway container left to judge" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "          image: ghcr.io/taipanbox/tokenfuse:v1.25.0@sha256:3a81dbcd116557eff54aae29e7d68104af8fc788265d58e71adf3f96fea03317\n", "          image: ghcr.io/taipanbox/tokenfuse-other:v1.0.4\n")')" \
	"measured nothing about the declassify key"

run_case "declassify-is-keyed: no installer left to read" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'import os
for f in ("install.sh", "cloud/aws/install-aws.sh", "cloud/gcp/install-gcp.sh"):
    os.remove(f)')" \
	"NOTHING about how the declassify key travels"

# What it must not catch. A sidecar running the same image on a subcommand
# never serves the route; a reworded comment is not a change to the key; and
# the other keys of the Secret still ride --from-literal, which this gate does
# not police (that is an older finding, named in the gate's header).
run_case "declassify-is-keyed: a subcommand sidecar is not a gateway container" pass \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "command: [\"/bin/sh\", \"-c\"]", "command: [\"/usr/local/bin/tokenfuse\"]")')"

run_case "declassify-is-keyed: a comment beside the key is reworded" pass \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "Nothing in this stack calls the endpoint.", "Nothing in this stack calls that endpoint.")')"

run_case "declassify-is-keyed: another key of the Secret still rides --from-literal" pass \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("install.sh", "      cloud_admin=\"$CLOUD_SECRET\" \\\n", "      cloud_admin=\"$CLOUD_SECRET\" \\\n      --from-literal=spare=\x27$CLOUD_SECRET\x27 \\\n")')"

# A one-replica plane that keeps the default 300 s toleration sits on a dead
# node for five minutes after it is marked NotReady: 360 s of a refused gateway
# on 2026-09-26 (invariant 21). The first occurrence of each line below is the
# gateway's.
run_case "planes-leave-a-dead-node: a rolling plane drops the unreachable toleration" fail \
	'./scripts/planes-leave-a-dead-node.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "        - { key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute, tolerationSeconds: 30 }\n", "")')" \
	"no toleration for node.kubernetes.io/unreachable"

run_case "planes-leave-a-dead-node: a not-ready toleration above 60 seconds" fail \
	'./scripts/planes-leave-a-dead-node.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "node.kubernetes.io/not-ready, operator: Exists, effect: NoExecute, tolerationSeconds: 30", "node.kubernetes.io/not-ready, operator: Exists, effect: NoExecute, tolerationSeconds: 300")')" \
	"tolerationSeconds 300 for node.kubernetes.io/not-ready"

run_case "planes-leave-a-dead-node: a serving container loses its preStop sleep" fail \
	'./scripts/planes-leave-a-dead-node.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "          lifecycle: { preStop: { sleep: { seconds: 5 } } }\n", "")')" \
	"has no preStop sleep"

# A StatefulSet is a subject too since invariant 22: policy-db holds a
# ReadWriteOnce claim, and on Longhorn it fails over only when it leaves the
# dead node early (GOTCHAS 109).
run_case "planes-leave-a-dead-node: a StatefulSet drops its unreachable toleration" fail \
	'./scripts/planes-leave-a-dead-node.sh' \
	"$(py 'edit("manifests/15-policy-store.yaml", "        - { key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute, tolerationSeconds: 30 }\n", "")')" \
	"StatefulSet policy-db: no toleration for node.kubernetes.io/unreachable"

# A Recreate Deployment never runs two pods at once, so there is no endpoint
# hand-over for a preStop sleep to cover: idryx turned Recreate and stripped of
# its sleep must pass, its tolerations still judged.
run_case "planes-leave-a-dead-node: a Recreate Deployment needs no preStop sleep" pass \
	'./scripts/planes-leave-a-dead-node.sh' \
	"$(py 'p = "manifests/10-planes.yaml"
edit(p, "  selector: { matchLabels: { app: idryx } }\n", "  strategy: { type: Recreate }\n  selector: { matchLabels: { app: idryx } }\n")
s = open(p).read()
i = s.index("        - name: idryx\n")
j = s.index("          lifecycle: { preStop: { sleep: { seconds: 5 } } }\n", i)
open(p, "w").write(s[:j] + s[j + len("          lifecycle: { preStop: { sleep: { seconds: 5 } } }\n"):])')"

# The subject list is every manifests/*.yaml since 2026-10-05, not the
# kustomization's: an opt-in manifest that a script applies on its own is a
# workload on the cluster all the same. Measured that day on GCP: hub-ingress
# (53, applied by hub/up.sh) kept the default 300 s and this gate said OK.
run_case "planes-leave-a-dead-node: an opt-in manifest outside the kustomization drops its toleration" fail \
	'./scripts/planes-leave-a-dead-node.sh' \
	"$(py 'edit("manifests/53-hub-entry.yaml", "        - { key: node.kubernetes.io/unreachable, operator: Exists, effect: NoExecute, tolerationSeconds: 30 }\n", "")')" \
	"Deployment hub-ingress: no toleration for node.kubernetes.io/unreachable"

run_case "planes-leave-a-dead-node: an opt-in rolling Deployment loses its preStop sleep" fail \
	'./scripts/planes-leave-a-dead-node.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "          lifecycle: { preStop: { sleep: { seconds: 5 } } }\n", "")')" \
	"Deployment tokenfuse-mcp-broker, container broker: serves a port and has no preStop sleep"

run_case "planes-leave-a-dead-node: no Deployment or StatefulSet left to judge" fail \
	'./scripts/planes-leave-a-dead-node.sh' \
	"$(py 'import glob, re
for f in glob.glob("manifests/*.yaml"):
    s = open(f).read()
    t = re.sub(r"(?m)^kind: (Deployment|StatefulSet)$", r"kind: \1Gone", s)
    if t != s:
        open(f, "w").write(t)')" \
	"measured nothing about leaving a dead node"

# Longhorn holds a dead node's volumes unless told otherwise; the setting is a
# block copied into three installers, the shape that drifted three times
# before (GOTCHAS 90, 101, 102).
TEETH_EDIT_15="$(py 'edit("cloud/aws/install-aws.sh", "  if k_ \"-n longhorn-system patch settings.longhorn.io node-down-pod-deletion-policy", "  if k_ \"-n longhorn-system get settings.longhorn.io node-down-pod-deletion-policy-was-here")')"
run_case "longhorn-releases-a-dead-node: an installer never sets the policy" fail \
	'./scripts/longhorn-releases-a-dead-node.sh' \
	"$TEETH_EDIT_15" \
	"never sets node-down-pod-deletion-policy"

run_case "longhorn-releases-a-dead-node: an installer sets the policy to the wrong value" fail \
	'./scripts/longhorn-releases-a-dead-node.sh' \
	"$(py 'import re
p = "cloud/gcp/install-gcp.sh"
s = open(p).read()
t = re.sub(r"(node-down-pod-deletion-policy --type merge -p .*?)delete-both-statefulset-and-deployment-pod", r"\1do-nothing", s, count=1)
assert t != s, "the patch line was not found"
open(p, "w").write(t)')" \
	"but not to delete-both-statefulset-and-deployment-pod"

run_case "longhorn-releases-a-dead-node: the confirmation line reworded is not a fault" pass \
	'./scripts/longhorn-releases-a-dead-node.sh' \
	"$(py 'edit("install.sh", "    echo \"   node-down-pod-deletion-policy=delete-both-statefulset-and-deployment-pod\"", "    echo \"   a dead node now releases its volumes\"")')"

run_case "longhorn-releases-a-dead-node: no Longhorn installer left" fail \
	'./scripts/longhorn-releases-a-dead-node.sh' \
	"$(py 'import os
for f in ["install.sh", "cloud/gcp/install-gcp.sh", "cloud/aws/install-aws.sh"]:
    os.remove(f)')" \
	"This measured nothing"

# Invariant 43 (GOTCHAS 129): the policy store's volume is on stack-policy, and
# every Longhorn installer creates that class with the settings the store needs.
run_case "policy-store-survives-a-partition: the policy-db claim names no class" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'edit("manifests/15-policy-store.yaml", "        storageClassName: stack-policy\n", "")')" \
	"names no storageClassName"

run_case "policy-store-survives-a-partition: the policy-db claim names the RWX class" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'edit("manifests/15-policy-store.yaml", "storageClassName: stack-policy", "storageClassName: stack-rwx")')" \
	"not \`stack-policy\`"

TEETH_EDIT_16="$(py 'edit("install.sh", "  dataLocality: \"best-effort\"", "  dataLocality: \"disabled\"")')"
run_case "policy-store-survives-a-partition: an installer leaves data locality disabled" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$TEETH_EDIT_16" \
	"parameter dataLocality"

TEETH_EDIT_17="$(py 'edit("cloud/aws/install-aws.sh", "  disableRevisionCounter: \"false\"", "  disableRevisionCounter: \"true\"")')"
run_case "policy-store-survives-a-partition: an installer turns the revision counter off" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$TEETH_EDIT_17" \
	"parameter disableRevisionCounter"

TEETH_EDIT_18="$(py 'edit("cloud/gcp/install-gcp.sh", "  staleReplicaTimeout: \"2880\"", "  staleReplicaTimeout: \"30\"")')"
run_case "policy-store-survives-a-partition: an installer keeps a failed replica 30 minutes" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$TEETH_EDIT_18" \
	"parameter staleReplicaTimeout"

run_case "policy-store-survives-a-partition: an installer lets the class delete its data" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'edit("install.sh", "  name: stack-policy\nprovisioner: driver.longhorn.io\nallowVolumeExpansion: true\nreclaimPolicy: Retain", "  name: stack-policy\nprovisioner: driver.longhorn.io\nallowVolumeExpansion: true\nreclaimPolicy: Delete")')" \
	"reclaimPolicy"

TEETH_EDIT_19="$(py 'edit("cloud/gcp/install-gcp.sh", "  name: stack-policy\n", "  name: stack-policy\n  annotations: { storageclass.kubernetes.io/is-default-class: \"true\" }\n")')"
run_case "policy-store-survives-a-partition: an installer marks the class as the default" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$TEETH_EDIT_19" \
	"marked as the default class"

TEETH_EDIT_20="$(py 'edit("install.sh", "k_ \"apply -f /tmp/stack-policy.yaml\"", "k_ \"apply -f /tmp/stack-policy.yaml\"\nk_ \"-n longhorn-system patch settings.longhorn.io auto-salvage --type merge -p {value:false}\"")')"
run_case "policy-store-survives-a-partition: an installer turns auto-salvage off" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$TEETH_EDIT_20" \
	"auto-salvage off"

run_case "policy-store-survives-a-partition: an installer never writes the class" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'import re
p = "cloud/aws/install-aws.sh"
s = open(p).read()
t = re.sub(r"say .stack-policy StorageClass.*?apply -f /tmp/stack-policy.yaml.\n", "", s, count=1, flags=re.S)
assert t != s, "the stack-policy block was not found"
open(p, "w").write(t)')" \
	"never creates the stack-policy StorageClass"

run_case "policy-store-survives-a-partition: no Longhorn installer left" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'import os
for f in ["install.sh", "cloud/gcp/install-gcp.sh", "cloud/aws/install-aws.sh"]:
    os.remove(f)')" \
	"This measured nothing"

run_case "policy-store-survives-a-partition: the class reworded in spacing is not a fault" pass \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'edit("install.sh", "  dataLocality: \"best-effort\"", "  dataLocality:   \"best-effort\"")')"

# Invariant 43, the refusal half (GOTCHAS 129): a deploy stops, with one sentence
# that names the migration, BEFORE its first apply, when policy-db is on another class.
TEETH_EDIT_21="$(py 'edit("lib/policy-store.sh", "  [ \"$cls\" = \"stack-policy\" ] && return 0", "  return 0")')"
run_case "policy-store-refuses-an-old-claim: the guard lets an old claim through" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$TEETH_EDIT_21" \
	"scenario old: expected a refusal"

run_case "policy-store-refuses-an-old-claim: the refusal loses its pointer to GOTCHAS 129" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$(py 'edit("lib/policy-store.sh", "migrate the policy store first as GOTCHAS 129 describes", "migrate the policy store first as the notes describe")')" \
	"lacks 'GOTCHAS 129'"

TEETH_EDIT_22="$(py 'edit("lib/policy-store.sh", "|| die \"could not ask the cluster whether policy-db exists, so the manifests were not applied\"", "|| return 0")')"
run_case "policy-store-refuses-an-old-claim: an unreachable cluster lets the apply through" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$TEETH_EDIT_22" \
	"scenario unreachable-name: expected a refusal"

TEETH_EDIT_23="$(py 'edit("lib/policy-store.sh", "  [ -n \"$existing\" ] || return 0", "  [ -n \"$existing\" ] || die \"fresh cluster refused\"")')"
run_case "policy-store-refuses-an-old-claim: a fresh cluster is refused" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$TEETH_EDIT_23" \
	"scenario fresh"

run_case "policy-store-refuses-an-old-claim: the AWS deploy drops its guard call" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "policy_store_guard   # CLAUDE.md invariant 43, GOTCHAS 129: refuse before anything is applied\n", "")')" \
	"does not call policy_store_guard before it"

run_case "policy-store-refuses-an-old-claim: the GCP deploy calls the guard after its apply" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$(py 'p = "cloud/gcp/deploy-gcp.sh"
s = open(p).read()
g = "policy_store_guard   # CLAUDE.md invariant 43, GOTCHAS 129: refuse before anything is applied\n"
a = "k_ \"apply -k /root/stack-k8s/manifests\"\n"
assert g in s and a in s, "the guard or the apply line was not found"
s = s.replace(g, "", 1).replace(a, a + "policy_store_guard\n", 1)
open(p, "w").write(s)')" \
	"after its first apply"

TEETH_EDIT_24="$(py 'edit("deploy.sh", ". \"$ROOT/lib/policy-store.sh\" || die \"no lib/policy-store.sh in $ROOT\"\n", "")')"
run_case "policy-store-refuses-an-old-claim: the top-level deploy does not source the helper" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$TEETH_EDIT_24" \
	"does not source lib/policy-store.sh"

run_case "policy-store-refuses-an-old-claim: no deploy script left to judge" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$(py 'import os
for f in ["deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh"]:
    os.remove(f)')" \
	"This measured nothing"

run_case "policy-store-refuses-an-old-claim: the helper's comment reworded is not a fault" pass \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$(py 'edit("lib/policy-store.sh", "There is no opt-out flag on purpose.", "There is no opt-out flag, on purpose.")')"

# The hub entry's whole job is to publish something on purpose, so nothing
# above stops a route from widening: it would still be valid YAML, still pass
# kubeconform, still keep automountServiceAccountToken false. Only reading the
# Caddyfile's own route list catches a route that grew.
run_case "hub-entry-is-narrow: a route is added" fail \
	'./scripts/hub-entry-is-narrow.sh' \
	"$(py 'edit("manifests/53-hub-entry.yaml",
    "path /v1/units /v1/budgets /v1/unit-budgets /v1/kills /v1/run-spend",
    "path /v1/units /v1/budgets /v1/unit-budgets /v1/kills /v1/run-spend /v1/runs")')" \
	"beyond the allowed eight"

# The site-scoped run seed (tokenfuse invariant 75) is a route a remote
# gateway needs; dropping it silently brings back the 2026-10-05 defect (a
# site that restarts counts its runs' spend from zero), so its absence fails
# the gate rather than reading as "narrower is fine".
run_case "hub-entry-is-narrow: the site run-spend route is dropped" fail \
	'./scripts/hub-entry-is-narrow.sh' \
	"$(py 'edit("manifests/53-hub-entry.yaml",
    "path /v1/units /v1/budgets /v1/unit-budgets /v1/kills /v1/run-spend",
    "path /v1/units /v1/budgets /v1/unit-budgets /v1/kills")')" \
	"missing route(s): [('GET', '/v1/run-spend')]"

run_case "hub-entry-is-narrow: a route's method widens" fail \
	'./scripts/hub-entry-is-narrow.sh' \
	"$(py 'edit("manifests/53-hub-entry.yaml",
    "        method POST\n        path /v1/ingest\n",
    "        method GET\n        path /v1/ingest\n")')" \
	"missing route(s)"

run_case "hub-entry-is-narrow: the catch-all is removed" fail \
	'./scripts/hub-entry-is-narrow.sh' \
	"$(py 'edit("manifests/53-hub-entry.yaml",
    "      handle {\n        respond 404\n      }\n",
    "")')" \
	"no catch-all"

run_case "hub-entry-is-narrow: a capability is added" fail \
	'./scripts/hub-entry-is-narrow.sh' \
	"$(py 'edit("manifests/53-hub-entry.yaml",
    "capabilities: { drop: [\"ALL\"], add: [\"NET_BIND_SERVICE\"] }",
    "capabilities: { drop: [\"ALL\"], add: [\"NET_BIND_SERVICE\", \"NET_ADMIN\"] }")')" \
	"only NET_BIND_SERVICE is allowed"

run_case "hub-entry-is-narrow: the file joins the default apply" fail \
	'./scripts/hub-entry-is-narrow.sh' \
	"$(py 'edit("manifests/kustomization.yaml",
    "  - 40-routines-and-secrets.yaml\n",
    "  - 40-routines-and-secrets.yaml\n  - 53-hub-entry.yaml\n")')" \
	"is listed in manifests/kustomization.yaml"

run_case "hub-entry-is-narrow: a comment line in the Caddyfile is not a fault" pass \
	'./scripts/hub-entry-is-narrow.sh' \
	"$(py 'edit("manifests/53-hub-entry.yaml",
    "    cloud.{$HUB_HOST} {",
    "    # a harmless comment about the cloud site\n    cloud.{$HUB_HOST} {")')"

run_case "hub-entry-is-narrow: the file is removed" fail \
	'./scripts/hub-entry-is-narrow.sh' \
	"$(py 'import os
os.remove("manifests/53-hub-entry.yaml")')" \
	"This measured nothing"

# vouchryx runs agents-only in the default install (CLAUDE.md invariant 24, as amended on 2026-10-19).
# The default install carries vouchryx, its IdP inputs stay optional, its keys are minted by the deploy,
# and the console's revoke wiring stays opt-in. Seven cases: the four faults the gate names, the console
# leak, a missing subject, and one comment that must not be a fault.
run_case "vouchryx-runs-agents-only: the manifest leaves the default apply set" fail \
	'./scripts/vouchryx-runs-agents-only.sh' \
	"$(py 'edit("manifests/kustomization.yaml",
    "  - 54-delegation.yaml\n",
    "")')" \
	"is not in manifests/kustomization.yaml's resources"

run_case "vouchryx-runs-agents-only: the IdP ConfigMap is required again" fail \
	'./scripts/vouchryx-runs-agents-only.sh' \
	"$(py 'edit("manifests/54-delegation.yaml",
    "key: trusted_issuers, optional: true } }",
    "key: trusted_issuers } }")')" \
	"without optional: true, so vouchryx needs an IdP to start"

run_case "vouchryx-runs-agents-only: the console's revoke wiring goes into the default console" fail \
	'./scripts/vouchryx-runs-agents-only.sh' \
	"$(py 'edit("manifests/20-console.yaml",
    "            - { name: GENARYX_COPILOT_API_KEY_REF, value: \"env:GENARYX_COPILOT_FUSE_KEY\" }\n",
    "            - { name: GENARYX_COPILOT_API_KEY_REF, value: \"env:GENARYX_COPILOT_FUSE_KEY\" }\n            - { name: GENARYX_VOUCHRYX_URL, value: \"http://vouchryx:4310\" }\n")')" \
	"sets a GENARYX_VOUCHRYX_* variable"

run_case "vouchryx-runs-agents-only: the deploy stops minting vouchryx's keys" fail \
	'./scripts/vouchryx-runs-agents-only.sh' \
	"$(py 'edit("deploy.sh",
    "vouchryx_mint_settle\n",
    "")')" \
	"never calls vouchryx_mint_settle"

run_case "vouchryx-runs-agents-only: the mint library is taken away" fail \
	'./scripts/vouchryx-runs-agents-only.sh' \
	"$(py 'import os; os.remove("lib/vouchryx-mint.sh")')" \
	"does not exist"

run_case "vouchryx-runs-agents-only: the subject taken away entirely" fail \
	'./scripts/vouchryx-runs-agents-only.sh' \
	"$(py 'import os; os.remove("manifests/54-delegation.yaml")')" \
	"measured nothing"

run_case "vouchryx-runs-agents-only: a comment naming the IdP input is not a fault" pass \
	'./scripts/vouchryx-runs-agents-only.sh' \
	"$(py 'edit("manifests/54-delegation.yaml",
    "# Reachable only from the doors",
    "# Note: trusted_issuers is optional, so vouchryx-trusted-issuers may be absent.\n# Reachable only from the doors")')"

# The door (CLAUDE.md invariant 54, as amended): agent tokens are required at the gateway and the broker, with
# one audience, a closed revocation list at most 60 s old, the same issuer and JWKS, and an agent-pod network
# that opens nothing else. Each fault below is one the gate names.
AGT=./scripts/agent-tokens-are-required.sh

TEETH_EDIT_25="$(py 'edit("manifests/10-planes.yaml", "{ name: TOKENFUSE_AGENT_TOKENS, value: \"require\" }", "{ name: TOKENFUSE_AGENT_TOKENS, value: \"accept\" }")')"
run_case "agent-tokens-are-required: the gateway accepts static keys beside tokens (accept, not require)" fail \
	"$AGT" \
	"$TEETH_EDIT_25" \
	"TOKENFUSE_AGENT_TOKENS must be exactly 'require'"

TEETH_EDIT_26="$(py 'edit("manifests/10-planes.yaml", "{ name: TOKENFUSE_PROFILE, value: \"governed\" }", "{ name: TOKENFUSE_PROFILE, value: \"observe\" }")')"
run_case "agent-tokens-are-required: the gateway drops the governed profile" fail \
	"$AGT" \
	"$TEETH_EDIT_26" \
	"TOKENFUSE_PROFILE must be exactly 'governed'"

run_case "agent-tokens-are-required: the gateway runs a tokenfuse that predates the governed profile" fail \
	"$AGT" \
	"$(py 'import re; p = "manifests/10-planes.yaml"; s = open(p).read(); s, n = re.subn(r"tokenfuse:v1\.25\.0@sha256", "tokenfuse:v1.18.0@sha256", s); assert n >= 1, n; open(p, "w").write(s)')" \
	"predates the governed profile and the static-key list"

TEETH_EDIT_27="$(py 'edit("manifests/10-planes.yaml", "{ name: TOKENFUSE_DELEGATION_AUDIENCE, value: \"https://vouchryx.agent-stack.invalid\" }", "{ name: TOKENFUSE_DELEGATION_AUDIENCE, value: \"\" }")')"
run_case "agent-tokens-are-required: the gateway's audience is empty, so any audience passes" fail \
	"$AGT" \
	"$TEETH_EDIT_27" \
	"TOKENFUSE_DELEGATION_AUDIENCE must be exactly"

TEETH_EDIT_28="$(py 'edit("manifests/10-planes.yaml", "{ name: TOKENFUSE_DELEGATION_AUDIENCE, value: \"https://vouchryx.agent-stack.invalid\" }", "{ name: TOKENFUSE_DELEGATION_AUDIENCE, value: \"https://vouchryx.other.invalid\" }")')"
run_case "agent-tokens-are-required: the gateway's audience is a second, unchecked one" fail \
	"$AGT" \
	"$TEETH_EDIT_28" \
	"TOKENFUSE_DELEGATION_AUDIENCE must be exactly"

TEETH_EDIT_29="$(py 'edit("manifests/10-planes.yaml", "{ name: TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE, value: \"closed\" }", "{ name: TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE, value: \"open\" }")')"
run_case "agent-tokens-are-required: the revocation list fails open" fail \
	"$AGT" \
	"$TEETH_EDIT_29" \
	"REVOCATIONS_FAILMODE must be exactly"

TEETH_EDIT_30="$(py 'edit("manifests/10-planes.yaml", "{ name: TOKENFUSE_DELEGATION_REVOCATIONS_MAX_AGE_SECS, value: \"60\" }", "{ name: TOKENFUSE_DELEGATION_REVOCATIONS_MAX_AGE_SECS, value: \"300\" }")')"
run_case "agent-tokens-are-required: the revocation list may be 300 s old" fail \
	"$AGT" \
	"$TEETH_EDIT_30" \
	"MAX_AGE_SECS must be exactly"

run_case "agent-tokens-are-required: the gateway's init container does not fetch the key set" fail \
	"$AGT" \
	"$(py 'edit("manifests/10-planes.yaml", "wget -q -T 5 -O /jwks/jwks.json http://vouchryx:4310/.well-known/jwks.json", "wget -q -T 5 -O /jwks/jwks.json http://127.0.0.1:4310/.well-known/jwks.json")')" \
	"does not fetch vouchryx's JWKS"

TEETH_EDIT_31="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "{ name: TOKENFUSE_AGENT_TOKENS, value: \"require\" }", "{ name: TOKENFUSE_AGENT_TOKENS, value: \"accept\" }")')"
run_case "agent-tokens-are-required: the broker accepts static keys beside tokens" fail \
	"$AGT" \
	"$TEETH_EDIT_31" \
	"TOKENFUSE_AGENT_TOKENS must be exactly 'require'"

TEETH_EDIT_32="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "{ name: TOKENFUSE_MCP_TAINT_FAILMODE, value: \"closed\" }", "{ name: TOKENFUSE_MCP_TAINT_FAILMODE, value: \"open\" }")')"
run_case "agent-tokens-are-required: the broker's tool-call check fails open" fail \
	"$AGT" \
	"$TEETH_EDIT_32" \
	"TOKENFUSE_MCP_TAINT_FAILMODE must be exactly"

TEETH_EDIT_33="$(py 'edit("manifests/54-delegation.yaml", "{ name: VOUCHRYX_ALLOWED_AUDIENCES, value: \"https://vouchryx.agent-stack.invalid\" }", "{ name: VOUCHRYX_ALLOWED_AUDIENCES, value: \"https://vouchryx.other.invalid\" }")')"
run_case "agent-tokens-are-required: vouchryx allows an audience the doors do not check" fail \
	"$AGT" \
	"$TEETH_EDIT_33" \
	"VOUCHRYX_ALLOWED_AUDIENCES must be exactly"

run_case "agent-tokens-are-required: the agent-pod network opens the open internet" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-network.yaml", "    - to:\n        - podSelector: { matchLabels: { app: tokenfuse-gateway } }\n", "    - to:\n        - ipBlock: { cidr: 0.0.0.0/0 }\n    - to:\n        - podSelector: { matchLabels: { app: tokenfuse-gateway } }\n")')" \
	"opens an ipBlock or 0.0.0.0/0"

run_case "agent-tokens-are-required: the agent-pod network left out of the default set" fail \
	"$AGT" \
	"$(py 'edit("manifests/kustomization.yaml", "  - 58-agent-tokens-network.yaml\n", "")')" \
	"is not in manifests/kustomization.yaml's resources"

# The broker's own door into the gateway (58's last document): removed, moved to another port, admitted from
# another app, or widened to the whole namespace. Each one drops the broker's tool-call check or hands it to
# something else, and the gate must say which.
run_case "agent-tokens-are-required: the MCP broker's door into the gateway is removed" fail \
	"$AGT" \
	"$(py 'p = "manifests/58-agent-tokens-network.yaml"; s = open(p).read(); i = s.index("  name: gateway-ingress-mcp-broker"); open(p, "w").write(s[:s.rindex("\n---", 0, i)] + "\n")')" \
	"has no gateway-ingress-mcp-broker"

run_case "agent-tokens-are-required: the broker's door opens another port than the gateway's 4100" fail \
	"$AGT" \
	"$(py 'p = "manifests/58-agent-tokens-network.yaml"; s = open(p).read(); i = s.index("  name: gateway-ingress-mcp-broker"); open(p, "w").write(s[:i] + s[i:].replace("port: 4100", "port: 4200", 1))')" \
	"does not open exactly TCP 4100"

run_case "agent-tokens-are-required: the broker's door admits another app, not the broker" fail \
	"$AGT" \
	"$(py 'p = "manifests/58-agent-tokens-network.yaml"; s = open(p).read(); i = s.index("  name: gateway-ingress-mcp-broker"); open(p, "w").write(s[:i] + s[i:].replace("app: tokenfuse-mcp-broker", "app: typryx", 1))')" \
	"does not admit exactly the MCP broker"

run_case "agent-tokens-are-required: the broker's door admits a whole namespace" fail \
	"$AGT" \
	"$(py 'p = "manifests/58-agent-tokens-network.yaml"; s = open(p).read(); i = s.index("  name: gateway-ingress-mcp-broker"); open(p, "w").write(s[:i] + s[i:].replace("- podSelector: \x7b matchLabels: \x7b app: tokenfuse-mcp-broker \x7d \x7d", "- namespaceSelector: \x7b \x7d", 1))')" \
	"does not admit exactly the MCP broker"

run_case "agent-tokens-are-required: the example agent keeps the default ServiceAccount token" fail \
	"$AGT" \
	"$(py 'edit("agent-tokens/example-agent.yaml", "      automountServiceAccountToken: false", "      automountServiceAccountToken: true")')" \
	"does not set automountServiceAccountToken: false"

run_case "agent-tokens-are-required: up.sh applies a kustomization instead of writing the registry" fail \
	"$AGT" \
	"$(py 'edit("agent-tokens/up.sh", "rollout restart deployment/vouchryx >/dev/null\n", "rollout restart deployment/vouchryx >/dev/null\nkubectl apply -k manifests/ >/dev/null\n")')" \
	"patches a door or applies a kustomization"

run_case "agent-tokens-are-required: up.sh stops refusing before it writes" fail \
	"$AGT" \
	"$(py 'import re; p = "agent-tokens/up.sh"; s = open(p).read(); s = s.replace("Nothing was written", "Written"); open(p, "w").write(s)')" \
	"no longer refuses before it writes the registry"

run_case "agent-tokens-are-required: a comment naming the old switch in the gateway is not a fault" pass \
	"$AGT" \
	"$(py 'edit("manifests/10-planes.yaml", "            # The door credential: an agent'"'"'s own token", "            # TOKENFUSE_AGENT_TOKENS=accept was the switch before this release.\n            # The door credential: an agent'"'"'s own token")')"

run_case "agent-tokens-are-required: the example agent is no longer a file" fail \
	"$AGT" \
	"$(py 'import os; os.remove("agent-tokens/example-agent.yaml")')" \
	"measured nothing"

# The NetworkPolicy's stated boundary (CLAUDE.md invariant 77): the header of 30 and the README say which side of the
# line the policy sits on, and what they say is the label, the ports and the files the cluster has. Each fault below is
# one the gate names; the three pass cases are harmless changes it must not catch.
NPB=./scripts/network-policy-names-its-boundary.sh

run_case "network-policy-names-its-boundary: the header drops the boundary paragraph" fail \
	"$NPB" \
	"$(py 'edit("manifests/30-network-policy.yaml", "WHICH SIDE OF THE LINE THIS POLICY SITS ON", "WHICH SIDE")')" \
	"the header does not say 'WHICH SIDE OF THE LINE THIS POLICY SITS ON'"

run_case "network-policy-names-its-boundary: the old claim comes back into the header" fail \
	"$NPB" \
	"$(py 'edit("manifests/30-network-policy.yaml", "# Default-deny, then exactly the paths the stack actually uses.\n#\n", "# Default-deny, then exactly the paths the stack actually uses: the rule, enforced per packet.\n#\n")')" \
	"carries the old claim 'enforced per packet'"

run_case "network-policy-names-its-boundary: a harmless comment in the header is not a fault" pass \
	"$NPB" \
	"$(py 'edit("manifests/30-network-policy.yaml", "# Default-deny, then exactly the paths the stack actually uses.\n#\n", "# Default-deny, then exactly the paths the stack actually uses.\n# (A harmless added line that states nothing.)\n#\n")')"

run_case "network-policy-names-its-boundary: the README section is gone" fail \
	"$NPB" \
	"$(py 'edit("README.md", "### What the NetworkPolicy confines, and where your agents run", "### Something else")')" \
	"has no section 'What the NetworkPolicy confines, and where your agents run'"

run_case "network-policy-names-its-boundary: the README drops the overlay" fail \
	"$NPB" \
	"$(py 'p = "README.md"; s = open(p).read(); assert "agent-tokens/confined-agent" in s; open(p, "w").write(s.replace("agent-tokens/confined-agent", "the overlay"))')" \
	"does not say 'agent-tokens/confined-agent'"

run_case "network-policy-names-its-boundary: the README states another port than 58 opens" fail \
	"$NPB" \
	"$(py 'import re; p = "README.md"; s = open(p).read(); i = s.index("### What the NetworkPolicy confines, and where your agents run"); j = s.index("\n### ", i + 10); sec = s[i:j]; assert "4310" in sec; open(p, "w").write(s[:i] + sec.replace("4310", "4311") + s[j:])')" \
	"does not state vouchryx on port 4310"

run_case "network-policy-names-its-boundary: the README names a file that does not exist" fail \
	"$NPB" \
	"$(py 'p = "README.md"; s = open(p).read(); assert "evidence/agent-confinement-k3d" in s; open(p, "w").write(s.replace("evidence/agent-confinement-k3d", "evidence/agent-confinement-kind"))')" \
	"which does not exist"

run_case "network-policy-names-its-boundary: another sentence in the README section is not a fault" pass \
	"$NPB" \
	"$(py 'edit("README.md", "### What the NetworkPolicy confines, and where your agents run\n", "### What the NetworkPolicy confines, and where your agents run\n\nA harmless added sentence that states nothing about the policy.\n")')"

run_case "network-policy-names-its-boundary: 58 selects a renamed label" fail \
	"$NPB" \
	"$(py 'p = "manifests/58-agent-tokens-network.yaml"; s = open(p).read(); assert "taipanbox.dev/agent-token: \"true\"" in s; open(p, "w").write(s.replace("taipanbox.dev/agent-token: \"true\"", "taipanbox.dev/agent-tokens: \"true\""))')" \
	"names a label taipanbox.dev/agent-token that manifests/58-agent-tokens-network.yaml does not select"

run_case "network-policy-names-its-boundary: the overlay's pod loses the label" fail \
	"$NPB" \
	"$(py 'edit("agent-tokens/confined-agent/agent.yaml", "labels: \x7b app: agent-confined, taipanbox.dev/agent-token: \"true\" \x7d", "labels: \x7b app: agent-confined \x7d")')" \
	"does not carry taipanbox.dev/agent-token=true"

run_case "network-policy-names-its-boundary: the example pod carries another label" fail \
	"$NPB" \
	"$(py 'edit("agent-tokens/example-agent.yaml", "taipanbox.dev/agent-token: \"true\"", "taipanbox.dev/agent-tokn: \"true\"")')" \
	"does not carry taipanbox.dev/agent-token=true"

run_case "network-policy-names-its-boundary: the README names another label" fail \
	"$NPB" \
	"$(py 'p = "README.md"; s = open(p).read(); assert "taipanbox.dev/agent-token=true" in s; open(p, "w").write(s.replace("taipanbox.dev/agent-token=true", "taipanbox.dev/agent-tokn=true"))')" \
	"names a label taipanbox.dev/agent-tokn"

run_case "network-policy-names-its-boundary: the proof script names another label" fail \
	"$NPB" \
	"$(py 'p = "agent-tokens/confine-check.sh"; s = open(p).read(); assert "carry taipanbox.dev/agent-token=true" in s; open(p, "w").write(s.replace("carry taipanbox.dev/agent-token=true", "carry taipanbox.dev/agent-tokn=true"))')" \
	"confine-check.sh names a label taipanbox.dev/agent-tokn"

run_case "network-policy-names-its-boundary: 58 opens a path the proof script does not probe" fail \
	"$NPB" \
	"$(py 'edit("manifests/58-agent-tokens-network.yaml", "    - to:\n        - podSelector: \x7b matchLabels: \x7b app: tokenfuse-gateway \x7d \x7d\n", "    - to:\n        - podSelector: \x7b matchLabels: \x7b app: wardryx \x7d \x7d\n      ports:\n        - \x7b protocol: TCP, port: 8090 \x7d\n    - to:\n        - podSelector: \x7b matchLabels: \x7b app: tokenfuse-gateway \x7d \x7d\n")')" \
	"has no open row for wardryx:8090"

run_case "network-policy-names-its-boundary: the proof script drops the gateway row" fail \
	"$NPB" \
	"$(py 'edit("agent-tokens/confine-check.sh", "expect agent \"\x24NS\" \"\x24AGENT_POD\" tokenfuse-gateway 4100 open\n", "")')" \
	"has no open row for tokenfuse-gateway:4100"

run_case "network-policy-names-its-boundary: the overlay is added to the default apply set" fail \
	"$NPB" \
	"$(py 'edit("manifests/kustomization.yaml", "  - 58-agent-tokens-network.yaml\n", "  - 58-agent-tokens-network.yaml\n  - ../agent-tokens/confined-agent\n")')" \
	"is in manifests/kustomization.yaml"

run_case "network-policy-names-its-boundary: a launcher applies the overlay" fail \
	"$NPB" \
	"$(py 'p = "deploy.sh"; s = open(p).read(); open(p, "w").write(s + "\nkubectl apply -k agent-tokens/confined-agent\n")')" \
	"applies or names agent-tokens/confined-agent"

run_case "network-policy-names-its-boundary: the cited run recorded a failure" fail \
	"$NPB" \
	"$(py 'edit("evidence/agent-confinement-k3d/output-enforcing.txt", "RUN_EXIT=0", "RUN_EXIT=1")')" \
	"does not end with RUN_EXIT=0"

run_case "network-policy-names-its-boundary: the cited run is gone" fail \
	"$NPB" \
	"$(py 'import os; os.remove("evidence/agent-confinement-k3d/output-enforcing.txt")')" \
	"output-enforcing.txt is missing"

run_case "network-policy-names-its-boundary: the agent-pod network is gone" fail \
	"$NPB" \
	"$(py 'import os; os.remove("manifests/58-agent-tokens-network.yaml")')" \
	"measured nothing"

run_case "network-policy-names-its-boundary: the overlay is gone" fail \
	"$NPB" \
	"$(py 'import shutil; shutil.rmtree("agent-tokens/confined-agent")')" \
	"measured nothing"

# Static client keys (CLAUDE.md invariant 62): admitted only from the named lists, each with a reason, each
# a minted key, and the operator's additions from a ConfigMap that is required, not optional.
SKY=./scripts/static-keys-are-named.sh

run_case "static-keys-are-named: the operator's list is read optionally" fail \
	"$SKY" \
	"$(py 'edit("manifests/10-planes.yaml", "              valueFrom: { configMapKeyRef: { name: gateway-static-keys, key: operator_key_ids } }", "              valueFrom: { configMapKeyRef: { name: gateway-static-keys, key: operator_key_ids, optional: true } }")')" \
	"OPERATOR_STATIC_KEY_IDS is optional"

TEETH_EDIT_34="$(py 'edit("manifests/10-planes.yaml", "value: \"felyx,agents,drills,costcrew,broker,drills-broker,broker-caller\" }", "value: \"felyx,agents,drills,costcrew,broker,drills-broker,broker-caller,stranger\" }")')"
run_case "static-keys-are-named: an id that the stack does not mint joins the list" fail \
	"$SKY" \
	"$TEETH_EDIT_34" \
	"is not one of the stack's minted keys"

run_case "static-keys-are-named: a listed id loses its reason" fail \
	"$SKY" \
	"$(py 'edit("manifests/10-planes.yaml", "            # static key drills: the scheduled mockryx drills, which cannot sign a DPoP proof.\n", "")')" \
	"has no \`# static key drills: <reason>\` line"

TEETH_EDIT_35="$(py 'edit("manifests/10-planes.yaml", "value: \"felyx,agents,drills,costcrew,broker,drills-broker,broker-caller\" }", "value: \"felyx,agents,drills,costcrew,drills-broker,broker-caller\" }")')"
run_case "static-keys-are-named: a minted key is dropped from the list without a written reason" fail \
	"$SKY" \
	"$TEETH_EDIT_35" \
	"has no \`# not static-listed: broker: <reason>\` line"

TEETH_EDIT_36="$(py 'edit("manifests/10-planes.yaml", "value: \"$(STACK_STATIC_KEY_IDS)$(OPERATOR_STATIC_KEY_IDS)\" }", "value: \"felyx,agents,drills,costcrew,broker\" }")')"
run_case "static-keys-are-named: the list is written as a literal instead of the two parts" fail \
	"$SKY" \
	"$TEETH_EDIT_36" \
	"TOKENFUSE_AGENT_TOKENS_STATIC_KEYS must be"

TEETH_EDIT_37="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "{ name: TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS, value: \"broker-caller,drills-broker\" }", "{ name: TOKENFUSE_MCP_AGENT_TOKENS_STATIC_KEYS, value: \"broker-caller,drills-broker,agents\" }")')"
run_case "static-keys-are-named: the broker admits an id outside its own key list" fail \
	"$SKY" \
	"$TEETH_EDIT_37" \
	"is not one of ['broker-caller', 'drills-broker']"

TEETH_EDIT_38="$(py 'edit("manifests/49-costcrew.yaml", "          env:\n            - name: TRAILRYX_TRUST_DOMAIN\n", "          env:\n            - { name: TOKENFUSE_AGENT_TOKENS_STATIC_KEYS, value: \"costcrew\" }\n            - name: TRAILRYX_TRUST_DOMAIN\n")')"
run_case "static-keys-are-named: a costcrew manifest sets a second list" fail \
	"$SKY" \
	"$TEETH_EDIT_38" \
	"sets a static-key list"

run_case "static-keys-are-named: the deploy stops creating the operator's list" fail \
	"$SKY" \
	"$(py 'edit("deploy.sh", "static_keys_settle\n", "")')" \
	"never calls static_keys_settle"

run_case "static-keys-are-named: the operator's list is written by hand, not kept when present" fail \
	"$SKY" \
	"$(py 'import os; os.remove("lib/static-keys.sh")')" \
	"does not exist"

run_case "static-keys-are-named: a comment naming the list is not a fault" pass \
	"$SKY" \
	"$(py 'edit("manifests/10-planes.yaml", "            # The operator'"'"'s own additions, from the ConfigMap gateway-static-keys", "            # The operator'"'"'s own additions are set with kubectl patch, then a rollout.\n            # The operator'"'"'s own additions, from the ConfigMap gateway-static-keys")')"

# wardryx verifies the agent's token and its proof itself (CLAUDE.md invariant 63, decision D3(b)).
WVA=./scripts/wardryx-verifies-agent-tokens.sh

# invariant 82: an agent whose error budget is spent is held for a person. Each half is
# true on its own, so each one gone is a cluster that says ok and never holds anybody.
run_case "slo-signal-is-wired: wardryx is not handed the file" fail \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - name: WARDRYX_SIGNAL_EVENTS\n              valueFrom: { configMapKeyRef: { name: stack-wiring, key: WARDRYX_SIGNAL_EVENTS } }\n", "")')" \
	"nothing reads the budget"
run_case "slo-signal-is-wired: a hold spends the budget that caused it" fail \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/10-planes.yaml", " --holds-spend-no-budget\n", "\n")')" \
	"could never earn it back"
run_case "slo-signal-is-wired: the sidecar keeps the console's entrypoint" fail \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "          imagePullPolicy: IfNotPresent\n          command: [\"/bin/sh\", \"-c\"]\n          args:\n            - |\n              set -eu\n              traces=/var/lib/stack/traces/gateway\n", "          imagePullPolicy: IfNotPresent\n          args:\n            - |\n              set -eu\n              traces=/var/lib/stack/traces/gateway\n")')" \
	"refuses a shell as an argument"
run_case "slo-signal-is-wired: the writer names another file" fail \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - name: VERDRYX_EVENTS_PATH\n              valueFrom: { configMapKeyRef: { name: stack-wiring, key: WARDRYX_SIGNAL_EVENTS } }\n", "            - { name: VERDRYX_EVENTS_PATH, value: /var/lib/stack/events/other.ndjson }\n")')" \
	"can name different files"
run_case "slo-signal-is-wired: the sidecar shares a uid" fail \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/00-base.yaml", "data:\n  # The same starter policy", "data:\n  # runAsUser\n  # The same starter policy"); edit("manifests/20-console.yaml", "      containers:\n", "      securityContext: { runAsUser: 20020 }\n      containers:\n")')" \
	"so the file is not the routine"
run_case "slo-signal-is-wired: the sidecar runs an older console than the console" fail \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/20-console.yaml", "image: ghcr.io/taipanbox/genaryx-console:", "image: ghcr.io/taipanbox/genaryx-console:x")')" \
	"and the console runs"
run_case "slo-signal-is-wired: a failed measurement is swallowed" fail \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/10-planes.yaml", " --holds-spend-no-budget\n", " --holds-spend-no-budget || true\n")')" \
	"a fleet with nothing to report"
run_case "slo-signal-is-wired: the file does not exist until the first spent budget" fail \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "              : >>\"$VERDRYX_EVENTS_PATH\"\n", "")')" \
	"reports unreadable"
run_case "slo-signal-is-wired: the policy carries no rule" fail \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/00-base.yaml", "    - name: slo-burn-hold\n      target: \"agent://*\"\n      hold_if_signal:\n        name: slo_burn\n        values: [exhausted, fast_burn]\n        min_probability: 1\n", "")')" \
	"holds nobody"
run_case "slo-signal-is-wired: the rule holds on a broken file" fail \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/00-base.yaml", "        values: [exhausted, fast_burn]\n        min_probability: 1\n", "        values: [exhausted, fast_burn]\n        min_probability: 1\n        when_absent: hold\n")')" \
	"would then hold every tool call"
run_case "slo-signal-is-wired: the sidecar has left the gateway's pod" fail \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "        - name: verdryx-slo\n", "        - name: verdryx-sl\n")')" \
	"measured NOTHING"
run_case "slo-signal-is-wired: a comment naming the switch is not a fault" pass \
	'./scripts/slo-signal-is-wired.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "        - name: verdryx-slo\n", "        # never || true here\n        - name: verdryx-slo\n")')"

run_case "wardryx-verifies-agent-tokens: wardryx is pinned before the token check" fail \
	"$WVA" \
	"$(py 'import re; p = "manifests/10-planes.yaml"; s = open(p).read(); s, n = re.subn(r"wardryx:v\d+\.\d+\.\d+@sha256", "wardryx:v2.2.1@sha256", s); assert n == 1, n; open(p, "w").write(s)')" \
	"predates the agent-token check"

run_case "wardryx-verifies-agent-tokens: the JWKS source is dropped, so the key set has no source" fail \
	"$WVA" \
	"$(py 'import re; p = "manifests/10-planes.yaml"; s = open(p).read(); s, n = re.subn(r"            - \{ name: WARDRYX_AGENT_TOKEN_JWKS_URL[^\n]*\n", "", s); assert n == 1, n; open(p, "w").write(s)')" \
	"WARDRYX_AGENT_TOKEN_JWKS_URL must be"

TEETH_EDIT_39="$(py 'edit("manifests/10-planes.yaml", "            - { name: WARDRYX_AGENT_TOKEN_DOOR_ORIGINS", "            - { name: WARDRYX_AGENT_TOKEN_REQUIRE_PROOF, value: \"0\" }\n            - { name: WARDRYX_AGENT_TOKEN_DOOR_ORIGINS")')"
run_case "wardryx-verifies-agent-tokens: the proof is switched off" fail \
	"$WVA" \
	"$TEETH_EDIT_39" \
	"proof is required by default and must not be switched off"

TEETH_EDIT_40="$(py 'edit("manifests/10-planes.yaml", "WARDRYX_AGENT_TOKEN_DOOR_ORIGINS, value: \"http://tokenfuse-gateway:4100,http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100,http://tokenfuse-mcp-broker:4200,http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200\" }", "WARDRYX_AGENT_TOKEN_DOOR_ORIGINS, value: \"http://tokenfuse-mcp-broker:4200,http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200\" }")')"
run_case "wardryx-verifies-agent-tokens: the gateway's door origin is not named" fail \
	"$WVA" \
	"$TEETH_EDIT_40" \
	"does not name the gateway"

TEETH_EDIT_41="$(py 'edit("manifests/10-planes.yaml", "{ name: WARDRYX_AGENT_TOKEN_ISSUER, value: \"http://vouchryx:4310\" }", "{ name: WARDRYX_AGENT_TOKEN_ISSUER, value: \"http://vouchryx.other:4310\" }")')"
run_case "wardryx-verifies-agent-tokens: the issuer is another vouchryx" fail \
	"$WVA" \
	"$TEETH_EDIT_41" \
	"WARDRYX_AGENT_TOKEN_ISSUER must be"

run_case "wardryx-verifies-agent-tokens: wardryx has no network path to vouchryx" fail \
	"$WVA" \
	"$(py 'edit("manifests/54-delegation.yaml", "name: wardryx-egress-vouchryx", "name: wardryx-egress-nothing")')" \
	"has no NetworkPolicy wardryx-egress-vouchryx"

run_case "wardryx-verifies-agent-tokens: vouchryx refuses wardryx" fail \
	"$WVA" \
	"$(py 'edit("manifests/54-delegation.yaml", "        - podSelector: { matchLabels: { app: wardryx } }\n        - podSelector: { matchLabels: { app: tokenfuse-mcp-broker } }\n", "        - podSelector: { matchLabels: { app: tokenfuse-mcp-broker } }\n")')" \
	"vouchryx-ingress does not admit wardryx"

run_case "wardryx-verifies-agent-tokens: the subject taken away entirely" fail \
	"$WVA" \
	"$(py 'import os; os.remove("manifests/54-delegation.yaml")')" \
	"measured nothing"

run_case "wardryx-verifies-agent-tokens: a comment naming the proof switch is not a fault" pass \
	"$WVA" \
	"$(py 'edit("manifests/10-planes.yaml", "            # together and checked by scripts/wardryx-verifies-agent-tokens.sh.", "            # together and checked by scripts/wardryx-verifies-agent-tokens.sh. (REQUIRE_PROOF=0 would switch the proof off; it is not set.)")')"


# invariant 36: closing a retained reservation is off by default, and on, the
# gateway and the console read the same secret bytes, never printed.
run_case "closure-off-by-default: a closure patch joins the default apply" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("manifests/kustomization.yaml",
    "  - 40-routines-and-secrets.yaml\n",
    "  - 40-routines-and-secrets.yaml\n  - 57-closure-gateway-patch.yaml\n")')" \
	"is listed in manifests/kustomization.yaml"

run_case "closure-off-by-default: a closure setting leaks into the default gateway manifest" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml",
    "            - { name: TOKENFUSE_CACHE, value: \"off\" }\n",
    "            - { name: TOKENFUSE_CACHE, value: \"off\" }\n            - { name: TOKENFUSE_CLOSURE_SECRET, value: \"x\" }\n")')" \
	"a closure setting, in the manifest"

TEETH_EDIT_42="$(py 'edit("manifests/57-closure-console-patch.yaml", "value: \"/run/closure/secret\"", "value: \"/run/closure/key\"")')"
run_case "closure-off-by-default: the console reads a file its volume does not mount" fail \
	'./scripts/closure-off-by-default.sh' \
	"$TEETH_EDIT_42" \
	"does not name the file the patch mounts"

run_case "closure-off-by-default: the console unpatch leaves the volume" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("manifests/57-closure-console-unpatch.yaml", "        - { name: closure-secret, $patch: delete }\n", "")')" \
	"does not delete"

TEETH_EDIT_43="$(py 'edit("closure/up.sh", "secret_doc closure-keys \"secret=$CLOSURE_SECRET\"", "secret_doc closure-keys \"secret=@$CLOSURE_SECRET\"")')"
run_case "closure-off-by-default: up.sh creates the Secret from a file" fail \
	'./scripts/closure-off-by-default.sh' \
	"$TEETH_EDIT_43" \
	"creates closure-keys from a file"

run_case "closure-off-by-default: up.sh mints a new secret on every run" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("closure/up.sh", "if k get secret closure-keys >/dev/null 2>&1; then", "if false; then")')" \
	"without first checking it exists"

TEETH_EDIT_44="$(py 'edit("closure/up.sh", "  unset CLOSURE_SECRET\n", "  echo \"$CLOSURE_SECRET\"\n  unset CLOSURE_SECRET\n")')"
run_case "closure-off-by-default: up.sh prints the secret" fail \
	'./scripts/closure-off-by-default.sh' \
	"$TEETH_EDIT_44" \
	"expands the closure secret"

run_case "closure-off-by-default: a comment in up.sh is reworded" pass \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("closure/up.sh", "# hex with no trailing newline,", "# hex without a trailing newline,")')"

run_case "closure-off-by-default: the subject taken away entirely" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'import os
os.remove("manifests/57-closure-console-patch.yaml")')" \
	"measured nothing"

run_case "manifests-valid: a closure patch body grows an apiVersion" fail \
	'./scripts/manifests-valid.sh' \
	"$(py 'edit("manifests/57-closure-console-patch.yaml", "spec:\n  template:\n", "apiVersion: apps/v1\nspec:\n  template:\n")')" \
	"is skipped as a patch body"

run_case "mounted-keys: the closure key mounted 0440 with no fsGroup in its patch" fail \
	'./scripts/mounted-keys-are-readable.sh' \
	"$(py 'edit("manifests/57-closure-console-patch.yaml", "            secretName: closure-keys\n", "            secretName: closure-keys\n            defaultMode: 0440\n")')" \
	"patch/manifests/57-closure-console-patch.yaml mounts secret volume closure-secret"

# Felyx through the gateway (invariant 25): the base URL moved off the gateway,
# a remote opt-in reintroduced anywhere, a harmless comment, and the subject gone.
TEETH_EDIT_45="$(py 'edit("manifests/20-console.yaml", "GENARYX_COPILOT_BASE_URL, value: \"http://tokenfuse-gateway:4100\"", "GENARYX_COPILOT_BASE_URL, value: \"https://api.anthropic.com\"")')"
run_case "felyx-through-the-gateway: the base URL points past the gateway" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$TEETH_EDIT_45" \
	"would not reach its model through this stack's gateway"

TEETH_EDIT_46="$(py 'edit("manifests/55-copilot-cloud.yaml", "            - { name: GENARYX_COPILOT_MODEL, value: \"claude-sonnet-5\" }\n", "            - { name: GENARYX_COPILOT_MODEL, value: \"claude-sonnet-5\" }\n            - { name: GENARYX_COPILOT_ALLOW_REMOTE, value: \"1\" }\n")')"
run_case "felyx-through-the-gateway: a manifest sets the remote opt-in again" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$TEETH_EDIT_46" \
	"would skip the residency check"

run_case "felyx-through-the-gateway: a comment about the copilot changes" pass \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("manifests/20-console.yaml", "# A reference, not the key: the copilot resolves env:NAME itself.", "# A reference, never the key: the copilot resolves env:NAME itself.")')"

run_case "felyx-through-the-gateway: the console manifest taken away" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'import os
os.remove("manifests/20-console.yaml")')" \
	"measured nothing"

# The typed-answer data mode (invariant 26): the jev key refusing a missing or
# blank file, the key becoming an environment value, the committed default
# leaving the stub, a ConfigMap sneaking into a render, a launcher losing a flag
# or its early check or applying manifests/51 around the mode, the manifest
# drifting from the three lines typed/mode.sh rewrites, a harmless comment, and
# the subject gone.
run_case "typed-mode-is-honest: jev stops refusing a missing key file" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "key_file_ok() { # path flag", "key_file_ok() { return 0 # path flag")')" \
	"jev without a key file refuses"

TEETH_EDIT_47="$(py 'edit("typed/mode.sh", "grep -q \x27[^[:space:]]\x27 \"$1\"", "true")')"
run_case "typed-mode-is-honest: a blank key file is accepted" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_47" \
	"a blank file"

TEETH_EDIT_48="$(py 'edit("typed/mode.sh", "- { name: TYPRYX_JEV_KEY_FILE, value: \"/etc/typryx/jev/key\" }", "- { name: TYPRYX_JEV_KEY, value: \"fake-test-key-not-a-real-key-7f3a9c2e\" }")')"
run_case "typed-mode-is-honest: the jev key becomes an environment value" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_48" \
	"an environment value"

TEETH_EDIT_49="$(py 'edit("manifests/51-typryx.yaml", "- { name: TYPRYX_BACKEND, value: \"stub\" }", "- { name: TYPRYX_BACKEND, value: \"jev\" }")')"
run_case "typed-mode-is-honest: the committed default stops being the stub" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_49" \
	"lost the stub backend"

TEETH_EDIT_50="$(py 'edit("typed/mode.sh", "      public_peer | egress_policy 443 ;;", "      printf -- \"---\\nkind: ConfigMap\\n\"; public_peer | egress_policy 443 ;;")')"
run_case "typed-mode-is-honest: a ConfigMap is rendered for a mode" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_50" \
	"a ConfigMap is rendered"

run_case "typed-mode-is-honest: manifests/51 drifts from the lines the modes rewrite" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "            - { name: events, mountPath: /var/lib/stack/events, subPath: streams }", "            - { name: events,  mountPath: /var/lib/stack/events, subPath: streams }")')" \
	"no longer carries the three lines"

TEETH_EDIT_51="$(py 'edit("cloud/aws/deploy-aws.sh", "    --typed-model-url)      TYPED_MODEL_URL=\"$2\"; shift 2 ;;\n", "")')"
run_case "typed-mode-is-honest: a launcher loses a typed flag" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_51" \
	"does not parse --typed-model-url"

TEETH_EDIT_52="$(py 'edit("cloud/gcp/deploy-gcp.sh", "\"$ROOT/typed/mode.sh\" check ", "\"$ROOT/typed/mode.sh\" mode ")')"
run_case "typed-mode-is-honest: a launcher stops checking before it installs" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_52" \
	"never runs typed/mode.sh check"

TEETH_EDIT_53="$(py 'edit("deploy.sh", "  \"$ROOT/typed/mode.sh\" render ${TYPED_ARGS[@]+\"${TYPED_ARGS[@]}\"} | k_ \"apply -f -\"", "  k_ \"apply -f /root/stack-k8s/manifests/51-typryx.yaml\"")')"
run_case "typed-mode-is-honest: a launcher applies manifests/51 around the mode" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_53" \
	"bypassing the mode"

run_case "typed-mode-is-honest: a comment in typed/mode.sh changes" pass \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "# Private ranges a public egress rule must never reach back into (the same list", "# Private ranges a public egress rule must never reach back into (the very list")')"

run_case "typed-mode-is-honest: typed/mode.sh taken away" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'import os
os.remove("typed/mode.sh")')" \
	"measured nothing"

# The training log (invariant 26, typryx v0.3.0): off unless asked, one variable
# and no disk when on. A default that leaks it, an extra object riding in with
# it, a real PersistentVolumeClaim (a billed disk) riding in with it, a
# directory on no mount, a directory on the shared events bus, the flag accepted
# with no typryx to write it, a launcher that loses or stops forwarding the flag,
# a stale typryx pin, a second tag in a document, the pin subject gone, and a
# harmless comment (must pass).
run_case "typed-mode-is-honest: the training log is on without the flag" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "TRAINING=0\nTRAINING_DIR=", "TRAINING=1\nTRAINING_DIR=")')" \
	"WITHOUT --typed-training"

TEETH_EDIT_54="$(py 'edit("typed/mode.sh", "printf \x27            - { name: TYPRYX_TRAINING_DIR, value: \"%s\" }\x27 \"$TRAINING_DIR\"", "printf \x27            - { name: TYPRYX_TRAINING_DIR, value: \"%s\" }\n            - { name: TYPRYX_EXTRA, value: \"x\" }\x27 \"$TRAINING_DIR\"")')"
run_case "typed-mode-is-honest: the training flag brings another object" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_54" \
	"added more than the variable"

TEETH_EDIT_55="$(py 'edit("typed/mode.sh", "  render_broker\n  if [ \"$RISK\" = 1 ]; then\n", "  render_broker\n  if [ \"$TRAINING\" = 1 ]; then printf -- \x27---\\napiVersion: v1\\nkind: PersistentVolumeClaim\\nmetadata:\\n  name: typryx-training\\n\x27; fi\n  if [ \"$RISK\" = 1 ]; then\n")')"
run_case "typed-mode-is-honest: the training flag provisions a claim" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_55" \
	"A claim is a billed disk"

TEETH_EDIT_56="$(py 'edit("typed/mode.sh", "TRAINING_DIR=\"/var/lib/typryx/training\"", "TRAINING_DIR=\"/srv/training\"")')"
run_case "typed-mode-is-honest: the training directory is under no mount" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_56" \
	"is under no volumeMount"

TEETH_EDIT_57="$(py 'edit("typed/mode.sh", "TRAINING_DIR=\"/var/lib/typryx/training\"", "TRAINING_DIR=\"/var/lib/stack/events/training\"")')"
run_case "typed-mode-is-honest: the training log lands on the shared bus" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_57" \
	"shared events claim"

TEETH_EDIT_58="$(py 'edit("typed/mode.sh", "if [ \"$TRAINING\" = 1 ] && [ \"$EFFECTIVE\" = off ]; then", "if false; then")')"
run_case "typed-mode-is-honest: the training flag is accepted with no typryx" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_58" \
	"11 training needs typryx"

run_case "typed-mode-is-honest: a launcher loses --typed-training" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "    --typed-training)       TYPED_TRAINING=1; shift ;;\n", "")')" \
	"does not parse --typed-training"

TEETH_EDIT_59="$(py 'edit("deploy.sh", "[ \"$TYPED_TRAINING\" = 1 ] && TYPED_ARGS+=(--typed-training)\n", "")')"
run_case "typed-mode-is-honest: a launcher stops forwarding --typed-training" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_59" \
	"never adds it to the arguments"

run_case "typed-mode-is-honest: the typryx pin goes back before the wardryx-proxy" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "image: ghcr.io/taipanbox/typryx:v0.6.1", "image: ghcr.io/taipanbox/typryx:v0.3.0")')" \
	"older than v0.4.0"

run_case "typed-mode-is-honest: a document names a second typryx tag" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("README.md", "### The typed-answer plane\n", "### The typed-answer plane\n\nOlder: ghcr.io/taipanbox/typryx:v0.3.1\n")')" \
	"different tags"

run_case "typed-mode-is-honest: the typryx image is no longer named" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "image: ghcr.io/taipanbox/typryx:v0.6.1", "image: example.invalid/typ:v0.4.0")
edit("manifests/56-typryx-wardryx-proxy.yaml", "image: ghcr.io/taipanbox/typryx:v0.6.1", "image: example.invalid/typ:v0.4.0")')" \
	"measured nothing about the typryx pin"

run_case "typed-mode-is-honest: a comment in the training section changes" pass \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "# WHERE IT LIVES, AND WHY THERE IS NO NEW DISK.", "# WHERE IT LIVES, AND WHY THERE IS NO NEW DISK, in short.")')"

# The run-budget ceiling (invariant 28, tokenfuse v1.5.0 invariant 73). A run's
# budget came from the header the AGENT sends and the next call could widen it;
# TOKENFUSE_MAX_RUN_BUDGET_USD bounds it, and a launcher that forgets the variable
# ships a gateway as unbounded as 1.4.1 with nothing reporting it. The faults: the
# variable gone, a figure the gateway refuses to start on, a figure that is not the
# documented default, a value from somewhere other than a literal, a copy on the
# control plane (which would read as if the Cloud's budgets were clamped), the one
# copy of the validation going loose or tight, a deploy path that checks too late,
# stops taking the flag, applies it before the apply that reverts it, or accepts it
# and applies nothing; then a comment (must pass) and both subjects taken away.
TEETH_EDIT_60="$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d\n", "")')"
run_case "run-budget-ceiling-is-set: the gateway container loses the ceiling" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$TEETH_EDIT_60" \
	"no TOKENFUSE_MAX_RUN_BUDGET_USD env var"

TEETH_EDIT_61="$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"five\" \x7d")')"
run_case "run-budget-ceiling-is-set: the ceiling is a word the gateway refuses" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$TEETH_EDIT_61" \
	"is not a positive decimal"

TEETH_EDIT_62="$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"0.00\" \x7d")')"
run_case "run-budget-ceiling-is-set: the ceiling is zero" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$TEETH_EDIT_62" \
	"is not a positive decimal"

TEETH_EDIT_63="$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"10.00\" \x7d")')"
run_case "run-budget-ceiling-is-set: the ceiling drifts from the documented default" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$TEETH_EDIT_63" \
	"is not the documented default"

TEETH_EDIT_64="$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d\n", "            - name: TOKENFUSE_MAX_RUN_BUDGET_USD\n              valueFrom: \x7b configMapKeyRef: \x7b name: stack-wiring, key: TOKENFUSE_MAX_RUN_BUDGET_USD, optional: true \x7d \x7d\n")')"
run_case "run-budget-ceiling-is-set: the ceiling comes from somewhere other than a literal" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$TEETH_EDIT_64" \
	"not as a literal value"

TEETH_EDIT_65="$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: PORT, value: \"8080\" \x7d\n", "            - \x7b name: PORT, value: \"8080\" \x7d\n            - \x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d\n")')"
run_case "run-budget-ceiling-is-set: the control plane carries the ceiling" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$TEETH_EDIT_65" \
	"not a gateway container"

TEETH_EDIT_66="$(py 'edit("budget/ceiling.sh", "  \"\") refuse \"\x27$value\x27 is zero.", "  \"\") : \"\x27$value\x27 is zero.")')"
run_case "run-budget-ceiling-is-set: budget/ceiling.sh accepts zero" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$TEETH_EDIT_66" \
	"accepted '0'"

run_case "run-budget-ceiling-is-set: budget/ceiling.sh accepts a sign and an exponent" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("budget/ceiling.sh", "re=\x27^[0-9]\x7b1,12\x7d(\\.[0-9]\x7b1,6\x7d)?$\x27", "re=\x27^[0-9eE.+-]+$\x27")')" \
	"accepted '-1'"

run_case "run-budget-ceiling-is-set: budget/ceiling.sh refuses a figure the gateway accepts" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("budget/ceiling.sh", "(\\.[0-9]\x7b1,6\x7d)?$\x27", "(\\.[0-9]\x7b1,2\x7d)?$\x27")')" \
	"refused '2.123456'"

TEETH_EDIT_67="$(py 'edit("cloud/gcp/deploy-gcp.sh", "\"$ROOT/budget/ceiling.sh\" check ", "\"$ROOT/budget/ceiling.sh\" true ")')"
run_case "run-budget-ceiling-is-set: a deploy path stops checking the figure before it installs" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$TEETH_EDIT_67" \
	"never runs budget/ceiling.sh check"

run_case "run-budget-ceiling-is-set: a comment next to the ceiling changes" pass \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "# The operator\x27s ceiling on a run\x27s budget (tokenfuse v1.5.0,", "# The operator\x27s ceiling on the budget of a run (tokenfuse v1.5.0,")')"

TEETH_EDIT_68="$(py 'edit("manifests/10-planes.yaml", "          image: ghcr.io/taipanbox/tokenfuse:v1.25.0@sha256:3a81dbcd116557eff54aae29e7d68104af8fc788265d58e71adf3f96fea03317\n          imagePullPolicy: IfNotPresent\n          command: [\"/usr/local/bin/tokenfuse\"]\n          env:\n            - \x7b name: TOKENFUSE_ADDR", "          image: ghcr.io/taipanbox/tokenfuse-other:v1.5.0\n          imagePullPolicy: IfNotPresent\n          command: [\"/usr/local/bin/tokenfuse\"]\n          env:\n            - \x7b name: TOKENFUSE_ADDR")')"
run_case "run-budget-ceiling-is-set: no gateway container left to judge" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$TEETH_EDIT_68" \
	"measured nothing about the run-budget ceiling"

run_case "run-budget-ceiling-is-set: budget/ceiling.sh taken away" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'import os
os.remove("budget/ceiling.sh")')" \
	"does not exist"

# The other half of invariant 28, in deploy-flags-agree.sh beside the trust domain:
# `apply -k` puts the declared figure back, so the flag has to act after it.
TEETH_EDIT_69="$(py 'edit("cloud/aws/deploy-aws.sh", "    --run-budget-ceiling) RUN_BUDGET_CEILING=\"$2\"; shift 2 ;;\n", "")')"
run_case "deploy-flags-agree: a deploy path stops taking --run-budget-ceiling" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$TEETH_EDIT_69" \
	"does not parse --run-budget-ceiling"

run_case "deploy-flags-agree: the ceiling flag is accepted and applies nothing" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("deploy.sh", "set env deploy/tokenfuse-gateway -c gateway TOKENFUSE_MAX_RUN_BUDGET_USD=", "set env deploy/tokenfuse-gateway -c gateway TOKENFUSE_MAX_RUN_BUDGET_US=")')" \
	"never applies"

run_case "deploy-flags-agree: the ceiling is applied BEFORE the apply that reverts it" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'import re
p = "cloud/gcp/deploy-gcp.sh"
s = open(p).read()
start = s.index("# The run-budget ceiling, set AFTER the kustomization")
end = s.index("fi\n", s.index("could not set the run-budget ceiling on the gateway")) + 3
block = s[start:end]
s = s[:start] + s[end:]
a = "k_ \"apply -k /root/stack-k8s/manifests\"\n"
assert s.count(a) == 1
s = s.replace(a, block + a)
open(p, "w").write(s)')" \
	"BEFORE its \`apply -k\`"

# The risk signal (invariant 29, wardryx v1.2.0 hold_if_signal, typryx v0.4.0
# wardryx-proxy). Off unless asked; on, one stateless proxy with typryx's own
# backend, only the broker asking through it, one door, nothing seeded.
TEETH_EDIT_70="$(py 'edit("typed/mode.sh", "TRAINING_DIR=\"/var/lib/typryx/training\"\nRISK=0\n", "TRAINING_DIR=\"/var/lib/typryx/training\"\nRISK=1\n")')"
run_case "typed-mode-is-honest: the risk signal is on without the flag" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_70" \
	"WITHOUT --typed-risk-signal"

TEETH_EDIT_71="$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_WARDRYX_URL, value: \"http://wardryx:8090\" \x7d", "\x7b name: TOKENFUSE_WARDRYX_URL, value: \"http://typryx-wardryx-proxy:4330\" \x7d")')"
run_case "typed-mode-is-honest: the gateway is pointed at the proxy" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_71" \
	"must never sit on the model path"

TEETH_EDIT_72="$(py 'edit("typed/mode.sh", "TOKENFUSE_WARDRYX_URL, value: \\\"http://typryx-wardryx-proxy:4330\\\"", "TOKENFUSE_WARDRYX_URL, value: \\\"http://wardryx:8090\\\"")')"
run_case "typed-mode-is-honest: the broker keeps asking wardryx directly" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_72" \
	"the broker's TOKENFUSE_WARDRYX_URL is"

TEETH_EDIT_73="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_WARDRYX_FAILMODE, value: \"closed\" \x7d", "\x7b name: TOKENFUSE_WARDRYX_FAILMODE, value: \"open\" \x7d")')"
run_case "typed-mode-is-honest: the broker fails open" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_73" \
	"not enforce/closed"

run_case "typed-mode-is-honest: the broker uses the admin key" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "key: wardryx_gateway \x7d \x7d", "key: wardryx_admin \x7d \x7d")')" \
	"does not use the pep key"

TEETH_EDIT_74="$(py 'edit("typed/mode.sh", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS, value: \\\"7000\\\"", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS, value: \\\"500\\\"")')"
run_case "typed-mode-is-honest: the broker waits less than the proxy may take" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_74" \
	"14 deadlines nest"

TEETH_EDIT_75="$(py 'edit("typed/mode.sh", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS, value: \\\"7000\\\"", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS, value: \\\"4000\\\"")')"
run_case "typed-mode-is-honest: the broker waits less than the proxy's longest ask" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_75" \
	"the wait must exceed the longest ask"

TEETH_EDIT_76="$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "TYPRYX_PROXY_ASK_TIMEOUT_MS, value: \"3000\"", "TYPRYX_PROXY_ASK_TIMEOUT_MS, value: \"1000\"")')"
run_case "typed-mode-is-honest: the proxy's ask deadline is too short for an own model" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_76" \
	"most own-model answers are dropped"

TEETH_EDIT_77="$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "            - \x7b name: TYPRYX_PROXY_ASK_TIMEOUT_MS, value: \"3000\" \x7d\n", "            - \x7b name: TYPRYX_PROXY_ASK_TIMEOUT_MS, value: \"3000\" \x7d\n            - \x7b name: TYPRYX_EVENTS, value: \"/var/lib/stack/events/typryx.ndjson\" \x7d\n")')"
run_case "typed-mode-is-honest: the proxy gets a journal on the shared bus" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_77" \
	"the proxy sets TYPRYX_EVENTS"

TEETH_EDIT_78="$(py 'edit("typed/mode.sh", "render_typryx \"$1\" \"$2\" \"$3\" \"$M56\"", "render_typryx \"$(with_training \"$1\")\" \"$2\" \"$3\" \"$M56\"")')"
run_case "typed-mode-is-honest: the proxy inherits the training log" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_78" \
	"the proxy sets TYPRYX_TRAINING_DIR"

TEETH_EDIT_79="$(py 'edit("typed/mode.sh", "render_typryx \"$1\" \"$2\" \"$3\" \"$M56\"", "render_typryx \x27            - \x7b name: TYPRYX_BACKEND, value: \"stub\" \x7d\x27 \"\" \"\" \"$M56\"")')"
run_case "typed-mode-is-honest: the proxy answers from another backend than typryx" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_79" \
	"disagree on the backend"

run_case "typed-mode-is-honest: the door admits every pod" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "  ingress:\n    - from:\n        - podSelector: \x7b matchLabels: \x7b app: tokenfuse-mcp-broker \x7d \x7d\n      ports:\n        - \x7b protocol: TCP, port: 4330 \x7d", "  ingress:\n    - from:\n        - podSelector: \x7b\x7d\n      ports:\n        - \x7b protocol: TCP, port: 4330 \x7d")')" \
	"admits or reaches more than the one named peer"

TEETH_EDIT_80="$(py 'edit("typed/mode.sh", "  if [ \"$RISK\" = 1 ]; then\n    # The proxy answers from the same backend", "  if false; then\n    # The proxy answers from the same backend")')"
run_case "typed-mode-is-honest: the model egress leaves the proxy out" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_80" \
	"does not select the proxy"

run_case "typed-mode-is-honest: a hold_if_signal policy is seeded" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/00-base.yaml", "      deny_tool:\n        - shell_exec\n", "      deny_tool:\n        - shell_exec\n    - name: seeded\n      target: agent://*\n      hold_if_signal: \x7b name: action.risk_class, values: [destructive], min_probability: 0.8 \x7d\n")')" \
	"seeds a hold_if_signal policy"

TEETH_EDIT_81="$(py 'edit("typed/mode.sh", "if [ \"$RISK\" = 1 ] && [ \"$EFFECTIVE\" = off ]; then", "if false; then")')"
run_case "typed-mode-is-honest: the risk flag is accepted with no typryx" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_81" \
	"15 risk signal needs typryx"

run_case "typed-mode-is-honest: a launcher loses --typed-risk-signal" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "    --typed-risk-signal)    TYPED_RISK_SIGNAL=1; shift ;;\n", "")')" \
	"does not parse --typed-risk-signal"

TEETH_EDIT_82="$(py 'edit("deploy.sh", "[ \"$TYPED_RISK_SIGNAL\" = 1 ] && TYPED_ARGS+=(--typed-risk-signal)\n", "")')"
run_case "typed-mode-is-honest: a launcher stops forwarding --typed-risk-signal" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_82" \
	"15 launchers hand --typed-risk-signal"

run_case "typed-mode-is-honest: the proxy runs another typryx tag than typryx" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "image: ghcr.io/taipanbox/typryx:v0.6.1", "image: ghcr.io/taipanbox/typryx:v0.3.0")')" \
	"different tags"

TEETH_EDIT_83="$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "args: [\"wardryx-proxy\"]", "args: [\"serve\"]")')"
run_case "typed-mode-is-honest: the proxy runs the service, not the proxy" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_83" \
	"does not run \`typryx wardryx-proxy\`"

TEETH_EDIT_84="$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "value: \"http://wardryx:8090\" \x7d", "value: \"http://wardryx.other:8090\" \x7d")')"
run_case "typed-mode-is-honest: the proxy forwards to something other than wardryx" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_84" \
	"not wardryx's own Service"

run_case "typed-mode-is-honest: manifests/56 drifts from the lines the modes rewrite" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "            - \x7b name: tmp, mountPath: /tmp \x7d", "            - \x7b name: tmp,  mountPath: /tmp \x7d")')" \
	"no longer carries the three lines"

run_case "typed-mode-is-honest: a comment in manifests/56 changes" pass \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "# ## No state, no disk\n", "# ## No state and no disk\n")')"

run_case "typed-mode-is-honest: manifests/56 taken away" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'import os
os.remove("manifests/56-typryx-wardryx-proxy.yaml")')" \
	"does not exist"

# The chain verifier (invariant 31, agent-stack-go v1.1.0 `agent-conform watch-dir`).
# The failures worth guarding are the quiet ones: suspended, in an opt-in file, watching
# the wrong directory, writing a stream no reader opens, remembering in a place that
# forgets, a second claim (a billed disk), a retry that hides the failure, no way to
# create its file, the money plane's uid, an image that has no such subcommand.
TEETH_EDIT_85="$(py 'edit("manifests/40-routines-and-secrets.yaml", "  schedule: \"*/15 * * * *\"\n", "  schedule: \"*/15 * * * *\"\n  suspend: true\n")')"
run_case "chain-verifier: the verifier is suspended" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$TEETH_EDIT_85" \
	"suspended"

TEETH_EDIT_86="$(py 'edit("manifests/40-routines-and-secrets.yaml", "  schedule: \"*/15 * * * *\"\n", "  schedule: \"0 * * * *\"\n")')"
run_case "chain-verifier: the verifier runs hourly" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$TEETH_EDIT_86" \
	"not at least every 15 minutes"

TEETH_EDIT_87="$(py 'edit("manifests/40-routines-and-secrets.yaml", "                - \"/var/lib/stack/events\"\n              volumeMounts:\n                - \x7b name: events, mountPath: /var/lib/stack/events, subPath: streams \x7d\n                - \x7b name: events, mountPath: /var/lib/stack/conform, subPath: conform \x7d\n              securityContext:\n                allowPrivilegeEscalation: false\n                readOnlyRootFilesystem: true\n                capabilities: \x7b drop: [\"ALL\"] \x7d\n              resources:\n                requests: \x7b cpu: 20m", "                - \"/var/lib/stack\"\n              volumeMounts:\n                - \x7b name: events, mountPath: /var/lib/stack/events, subPath: streams \x7d\n                - \x7b name: events, mountPath: /var/lib/stack/conform, subPath: conform \x7d\n              securityContext:\n                allowPrivilegeEscalation: false\n                readOnlyRootFilesystem: true\n                capabilities: \x7b drop: [\"ALL\"] \x7d\n              resources:\n                requests: \x7b cpu: 20m")')"
run_case "chain-verifier: the verifier watches a directory that is not the bus" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$TEETH_EDIT_87" \
	"not the bus"

TEETH_EDIT_88="$(py 'edit("manifests/40-routines-and-secrets.yaml", "                - \"/var/lib/stack/events/agent-conform.ndjson\"\n", "                - \"/var/lib/stack/events/wardryx.ndjson\"\n")')"
run_case "chain-verifier: the verifier writes a stream named for another writer" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$TEETH_EDIT_88" \
	"inside the bus (its name is the source"

TEETH_EDIT_89="$(py 'edit("manifests/40-routines-and-secrets.yaml", "                - \"/var/lib/stack/events\"\n              volumeMounts:\n                - \x7b name: events, mountPath: /var/lib/stack/events, subPath: streams \x7d\n                - \x7b name: events, mountPath: /var/lib/stack/conform, subPath: conform \x7d\n              securityContext:\n                allowPrivilegeEscalation: false\n                readOnlyRootFilesystem: true\n                capabilities: \x7b drop: [\"ALL\"] \x7d\n              resources:\n                requests: \x7b cpu: 20m, memory: 32Mi \x7d\n                limits: \x7b memory: 256Mi \x7d\n          volumes:\n            - name: events\n              persistentVolumeClaim: \x7b claimName: stack-events \x7d\n", "                - \"/var/lib/stack/events\"\n              volumeMounts:\n                - \x7b name: events, mountPath: /var/lib/stack/events, subPath: streams \x7d\n                - \x7b name: events, mountPath: /var/lib/stack/conform, subPath: conform \x7d\n              securityContext:\n                allowPrivilegeEscalation: false\n                readOnlyRootFilesystem: true\n                capabilities: \x7b drop: [\"ALL\"] \x7d\n              resources:\n                requests: \x7b cpu: 20m, memory: 32Mi \x7d\n                limits: \x7b memory: 256Mi \x7d\n          volumes:\n            - name: events\n              emptyDir: \x7b\x7d\n")')"
run_case "chain-verifier: the verifier remembers in an emptyDir" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$TEETH_EDIT_89" \
	"mounts an emptyDir"

run_case "chain-verifier: the verifier is given a claim of its own" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "                requests: \x7b cpu: 20m, memory: 32Mi \x7d\n                limits: \x7b memory: 256Mi \x7d\n          volumes:\n            - name: events\n              persistentVolumeClaim: \x7b claimName: stack-events \x7d\n", "                requests: \x7b cpu: 20m, memory: 32Mi \x7d\n                limits: \x7b memory: 256Mi \x7d\n          volumes:\n            - name: events\n              persistentVolumeClaim: \x7b claimName: stack-events \x7d\n            - name: conform-state\n              persistentVolumeClaim: \x7b claimName: agent-conform-state \x7d\n")')" \
	"a billed disk"

run_case "chain-verifier: a failed pass is retried into silence" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "      backoffLimit: 0\n      template:\n        spec:\n          restartPolicy: Never\n", "      backoffLimit: 0\n      template:\n        spec:\n          restartPolicy: OnFailure\n")')" \
	"a retry exits 0"

run_case "chain-verifier: the verifier cannot create its file on the bus" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "runAsUser: 10002, runAsGroup: 10002, fsGroup: 10001,", "runAsUser: 10002, runAsGroup: 10002,")')" \
	"no fsGroup 10001"

run_case "chain-verifier: the verifier shares the money plane's uid" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "runAsUser: 10002, runAsGroup: 10002,", "runAsUser: 10001, runAsGroup: 10002,")')" \
	"its own and not the money plane"

run_case "chain-verifier: the image has no watch-dir" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "image: ghcr.io/taipanbox/agent-conform:v2.0.3", "image: ghcr.io/taipanbox/agent-conform:v1.0.2")')" \
	"older than v1.1.0"

run_case "chain-verifier: the verifier is in an opt-in file" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'import re
p = "manifests/40-routines-and-secrets.yaml"
s = open(p).read()
i = s.index("# The on-box chain verifier.")
doc = s[i:]
s = s[:i].rstrip("\n")
s = s[:s.rindex("---")].rstrip("\n") + "\n"
open(p, "w").write(s)
open("manifests/57-agent-conform.yaml", "w").write(doc)')" \
	"does not run the verifier"

run_case "chain-verifier: a comment on the verifier changes" pass \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "# EVERY 15 MINUTES, as a CronJob, because the work is one pass over the bus and", "# EVERY 15 MINUTES, as a CronJob, since the work is one pass over the bus and")')"

run_case "chain-verifier: no verifier left to judge" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "image: ghcr.io/taipanbox/agent-conform:v2.0.3", "image: ghcr.io/taipanbox/agent-conform-other:v1.1.0")')" \
	"measured nothing about the verifier"

# The bus file names (invariant 30). heraldyx v0.3.0 and idryx v1.1.0 refuse an event
# whose source is not allowed for its file, so a stream renamed, or a --load pair that
# names the wrong source, silences a plane without an error.
TEETH_EDIT_90="$(py 'edit("manifests/00-base.yaml", "WARDRYX_EVENTS_PATH: \"/var/lib/stack/events/wardryx.ndjson\"", "WARDRYX_EVENTS_PATH: \"/var/lib/stack/events/policy-events.ndjson\"")')"
run_case "bus-names: a stream is named for no source the readers know" fail \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$TEETH_EDIT_90" \
	"named for no source the readers know"

TEETH_EDIT_91="$(py 'edit("manifests/10-planes.yaml", "            - \"tokenfuse:/var/lib/stack/events/tokenfuse.ndjson\"", "            - \"wardryx:/var/lib/stack/events/tokenfuse.ndjson\"")')"
run_case "bus-names: an idryx --load pair names a source the file may not carry" fail \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$TEETH_EDIT_91" \
	"may carry"

TEETH_EDIT_92="$(py 'edit("manifests/10-planes.yaml", "            - \"tokenfuse:/var/lib/stack/events/tokenfuse.ndjson\"", "            - \"tokenfuse:/var/lib/stack/events/tokenfuse.log\"")')"
run_case "bus-names: an idryx --load path is not a stream file" fail \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$TEETH_EDIT_92" \
	"names no *.ndjson file"

run_case "bus-names: a renamed stream that the notifier declares is not a fault" pass \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$(py 'edit("manifests/00-base.yaml", "WARDRYX_EVENTS_PATH: \"/var/lib/stack/events/wardryx.ndjson\"", "WARDRYX_EVENTS_PATH: \"/var/lib/stack/events/policy-events.ndjson\"")
edit("manifests/45-heraldyx.yaml", "            - \x7b name: HERALDYX_EVENTS, value: \"/var/lib/stack/events\" \x7d\n", "            - \x7b name: HERALDYX_EVENTS, value: \"/var/lib/stack/events\" \x7d\n            - \x7b name: HERALDYX_STREAMS, value: \"policy-events=wardryx\" \x7d\n")')"

run_case "bus-names: the control plane and the broker keep their tokenfuse rows" pass \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "tokenfuse-mcp.ndjson\" \x7d", "tokenfuse-mcp.ndjson\" \x7d  ")')"

run_case "bus-names: a comment names a stream that does not exist" pass \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$(py 'edit("manifests/00-base.yaml", "  EVENTS_DIR: \"/var/lib/stack/events\"\n", "  EVENTS_DIR: \"/var/lib/stack/events\"\n  # was /var/lib/stack/events/oops.ndjson once\n")')"

run_case "bus-names: no stream path left to judge" fail \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$(py 'import pathlib
n = 0
for path in list(pathlib.Path("manifests").glob("*.yaml")) + list(pathlib.Path("typed").glob("*.sh")):
    s = path.read_text()
    if "/var/lib/stack/events/" in s:
        path.write_text(s.replace("/var/lib/stack/events/", "/var/lib/stack/evnts/"))
        n += 1
assert n, "no file named the bus"')" \
	"measured nothing about the bus file names"

# invariant 32: every mounted Secret, ConfigMap or projected file is readable by
# its pod's user. GOTCHAS 117: the typed risk proxy got the jev key at 0440 with
# no fsGroup, so the file stayed root:root and the proxy died at start.
run_case "mounted-keys: the risk proxy loses its fsGroup" fail \
	'./scripts/mounted-keys-are-readable.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "runAsGroup: 65532, fsGroup: 65532, seccompProfile", "runAsGroup: 65532, seccompProfile")')" \
	"Deployment/typryx-wardryx-proxy mounts secret volume jev-key at defaultMode 0440"

run_case "mounted-keys: typryx loses the fsGroup that lets it read its key" fail \
	'./scripts/mounted-keys-are-readable.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "runAsGroup: 20005, fsGroup: 10001, seccompProfile", "runAsGroup: 20005, seccompProfile")')" \
	"Deployment/typryx mounts secret volume jev-key"

run_case "mounted-keys: the model key mode drops its group read" fail \
	'./scripts/mounted-keys-are-readable.sh' \
	"$(py 'edit("typed/mode.sh", "secretName: typryx-model-key, defaultMode: 0440", "secretName: typryx-model-key, defaultMode: 0400")')" \
	"volume model-key at defaultMode 0400"

run_case "mounted-keys: a patch body mounts a key at 0440 with no fsGroup" fail \
	'./scripts/mounted-keys-are-readable.sh' \
	"$(py 'edit("manifests/54-delegation-console-patch.yaml", "            secretName: vouchryx-keys\n", "            secretName: vouchryx-keys\n            defaultMode: 0440\n")')" \
	"patch/manifests/54-delegation-console-patch.yaml mounts secret volume vouchryx-revoke-key"

run_case "mounted-keys: a world-readable key needs no fsGroup" pass \
	'./scripts/mounted-keys-are-readable.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "runAsGroup: 65532, fsGroup: 65532, seccompProfile", "runAsGroup: 65532, seccompProfile")
edit("typed/mode.sh", "secretName: typryx-jev-key, defaultMode: 0440", "secretName: typryx-jev-key, defaultMode: 0444")
edit("typed/mode.sh", "secretName: typryx-model-key, defaultMode: 0440", "secretName: typryx-model-key, defaultMode: 0444")')"

run_case "mounted-keys: a block-style securityContext with fsGroup is read" pass \
	'./scripts/mounted-keys-are-readable.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "      securityContext: \x7b runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, seccompProfile: \x7b type: RuntimeDefault \x7d \x7d\n", "      securityContext:\n        runAsNonRoot: true\n        runAsUser: 65532\n        runAsGroup: 65532\n        fsGroup: 65532\n        seccompProfile: \x7b type: RuntimeDefault \x7d\n")')"

run_case "mounted-keys: a block-style securityContext without fsGroup" fail \
	'./scripts/mounted-keys-are-readable.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "      securityContext: \x7b runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, seccompProfile: \x7b type: RuntimeDefault \x7d \x7d\n", "      securityContext:\n        runAsNonRoot: true\n        runAsUser: 65532\n        runAsGroup: 65532\n        seccompProfile: \x7b type: RuntimeDefault \x7d\n")')" \
	"Deployment/typryx-wardryx-proxy mounts secret volume jev-key"

run_case "mounted-keys: typed/mode.sh taken away" fail \
	'./scripts/mounted-keys-are-readable.sh' \
	"$(py 'import os
os.remove("typed/mode.sh")')" \
	"measured nothing about the typed key mounts"

run_case "mounted-keys: no manifests/*.yaml left to read" fail \
	'./scripts/mounted-keys-are-readable.sh' \
	"$(py 'import pathlib
n = 0
for path in pathlib.Path("manifests").glob("*.yaml"):
    path.rename(path.with_suffix(".yml"))
    n += 1
assert n, "no manifest to rename"')" \
	"no manifests/*.yaml"

run_case "mounted-keys: no typed render mounts a key" fail \
	'./scripts/mounted-keys-are-readable.sh' \
	"$(py 'edit("typed/mode.sh", "secret: \x7b secretName: typryx-jev-key, defaultMode: 0440 \x7d", "configMap: \x7b name: typryx-jev-key \x7d")
edit("typed/mode.sh", "secret: \x7b secretName: typryx-model-key, defaultMode: 0440 \x7d", "configMap: \x7b name: typryx-model-key \x7d")
edit("manifests/52-tokenfuse-mcp-broker.yaml", "secret: \x7b secretName: broker-taint-key, defaultMode: 0440, items: \x5b\x7b key: client_key, path: key \x7d\x5d \x7d", "configMap: \x7b name: broker-taint-key \x7d")
edit("manifests/52-tokenfuse-mcp-broker.yaml", "secret: \x7b secretName: drills-broker-key, optional: true, defaultMode: 0440, items: \x5b\x7b key: broker_key, path: broker_key \x7d\x5d \x7d", "configMap: \x7b name: drills-broker-key \x7d")')" \
	"no typed render mounts a Secret"

# Invariant 33. tokenfuse splits a client key entry on its LAST colon, so an
# agent:// key id starts fine and refuses the caller's real secret. Quotes in
# the examples are spelled \x27 and braces \x7b \x7d, per the bash 3.2 note at
# the top.
run_case "client-key-ids: the README example goes back to an agent:// key id" fail \
	'./scripts/client-key-ids-are-bare.sh' \
	"$(py 'edit("README.md", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:broker-caller,and-another-long-secret:drills-broker\x27", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:agent://acme.example/broker-caller,and-another-long-secret:drills-broker\x27")')" \
	"key id '//acme.example/broker-caller'"

run_case "client-key-ids: the manifest 52 example goes back to an agent:// key id" fail \
	'./scripts/client-key-ids-are-bare.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:broker-caller,and-another-long-secret:drills-broker\x27", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:agent://acme.example/broker-caller,and-another-long-secret:drills-broker\x27")')" \
	"key id '//acme.example/broker-caller'"

TEETH_EDIT_93="$(py 'open("README.md", "a").write("\n    env: [ \x7b name: TOKENFUSE_CLIENT_KEYS, value: \"sk-flow:agent://acme.example/flow\" \x7d ]\n")')"
run_case "client-key-ids: a YAML flow env entry carries an agent:// key id" fail \
	'./scripts/client-key-ids-are-bare.sh' \
	"$TEETH_EDIT_93" \
	"key id '//acme.example/flow'"

TEETH_EDIT_94="$(py 'open("README.md", "a").write("\n        - name: TOKENFUSE_MCP_KEYS\n          value: \"sk-block:agent://acme.example/block\"\n")')"
run_case "client-key-ids: a YAML block env entry carries an agent:// key id" fail \
	'./scripts/client-key-ids-are-bare.sh' \
	"$TEETH_EDIT_94" \
	"key id '//acme.example/block'"

run_case "client-key-ids: a secret with colons and a bare key id (must pass)" pass \
	'./scripts/client-key-ids-are-bare.sh' \
	"$(py 'edit("README.md", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:broker-caller,and-another-long-secret:drills-broker\x27", "TOKENFUSE_MCP_KEYS=\x27sk-proj:abc:def:broker-caller,sk-two:research-agent\x27")')"

run_case "client-key-ids: no literal example left to judge" fail \
	'./scripts/client-key-ids-are-bare.sh' \
	"$(py 'edit("README.md", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:broker-caller,and-another-long-secret:drills-broker\x27", "TOKENFUSE_MCP_KEYS=\"$BROKER_KEYS\"")
edit("manifests/52-tokenfuse-mcp-broker.yaml", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:broker-caller,and-another-long-secret:drills-broker\x27", "TOKENFUSE_MCP_KEYS=\"$BROKER_KEYS\"")')" \
	"measured nothing"

# invariant 34: a public repository carries no quote of the owner, no owner
# provenance marker and no attribution by name. Every planted string is built
# from pieces or escapes, so this file never trips the gate it tests.
run_case "no-owner-quotes: an owner provenance marker" fail \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("README.md", "a").write("\n`@" + "yur" + "ii 2026-10-08`: keep it.\n")')" \
	"the owner's provenance marker"

TEETH_EDIT_95="$(py 'open("GOTCHAS.md", "a").write("\n\"\u0440\u043e\u0431\u0438 \u0432\u0441\u0435\"\n")')"
run_case "no-owner-quotes: a quote in Ukrainian" fail \
	'./scripts/no-owner-quotes.sh' \
	"$TEETH_EDIT_95" \
	"Cyrillic text"

run_case "no-owner-quotes: a quote in guillemets" fail \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("manifests/49-costcrew.yaml", "a").write("\n# \u00abdo it all\u00bb\n")')" \
	"a guillemet"

run_case "no-owner-quotes: an attribution by name" fail \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("components.json", "a").write("\n" + "Yur" + "ii asked for this.\n")')" \
	"the owner's name outside a copyright or author line"

# A hook runs with GIT_DIR set to the repository being pushed, and neither
# `git -C` nor a change of directory clears it: `git init` would reinitialise
# that repository instead of "$d", and the gate's own `git ls-files` would list
# its files, so the case would pass and read TOOTHLESS. Both calls drop the
# three variables git exports into a hook (estate-gates C9).
run_case "no-owner-quotes: no tracked text file to judge" fail_env \
	'd="$(mktemp -d)" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$d" init -q && mkdir "$d/scripts" && cp scripts/no-owner-quotes.sh "$d/scripts/" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE "$d/scripts/no-owner-quotes.sh"' \
	"$(py 'pass')" \
	"measured NOTHING"

run_case "no-owner-quotes: the owner as copyright holder" pass \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("LICENSE", "a").write("\nCopyright 2026 " + "Yur" + "ii Kost" + "iuk\n")')"

run_case "no-owner-quotes: a decision recorded as @decided and a paraphrase" pass \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("README.md", "a").write("\n`@decided 2026-10-08`: the console keeps a writable temp.\n")')"

# invariant 35: a read-only container that needs a temp has a writable,
# size-limited one. GOTCHAS 120: without it SQLite could not VACUUM the old
# session tokens out of the costcrew store (disk I/O error 6410).
run_case "temp: the console loses its /tmp mount" fail \
	'./scripts/read-only-root-has-a-temp.sh' \
	"$(py 'edit("manifests/49-costcrew.yaml", "            - { name: tmp, mountPath: /tmp }\n          readinessProbe:", "          readinessProbe:")')" \
	"Deployment/costcrew container costcrew: the root is read-only and nothing writable is mounted at /tmp"

run_case "temp: the crew runner loses its /tmp mount" fail \
	'./scripts/read-only-root-has-a-temp.sh' \
	"$(py 'edit("manifests/49-costcrew.yaml", "                - { name: tmp, mountPath: /tmp }\n", "")')" \
	"CronJob/costcrew-crew container crew: the root is read-only and nothing writable is mounted at /tmp"

run_case "temp: the console's temp loses its sizeLimit" fail \
	'./scripts/read-only-root-has-a-temp.sh' \
	"$(py 'edit("manifests/49-costcrew.yaml", "          emptyDir: { medium: Memory, sizeLimit: 128Mi }\n---\napiVersion: v1\nkind: Service", "          emptyDir: { medium: Memory }\n---\napiVersion: v1\nkind: Service")')" \
	"with no sizeLimit"

run_case "temp: the console's temp is mounted read-only" fail \
	'./scripts/read-only-root-has-a-temp.sh' \
	"$(py 'edit("manifests/49-costcrew.yaml", "            - { name: tmp, mountPath: /tmp }\n          readinessProbe:", "            - { name: tmp, mountPath: /tmp, readOnly: true }\n          readinessProbe:")')" \
	"which is readOnly"

run_case "temp: no container left that needs a temp" fail \
	'./scripts/read-only-root-has-a-temp.sh' \
	"$(py 'edit("manifests/49-costcrew.yaml", "image: ghcr.io/taipanbox/costcrew:v0.10.2", "image: registry.invalid/costcrew:v0.6.0")
edit("manifests/49-costcrew.yaml", "image: ghcr.io/taipanbox/costcrew:v0.10.2", "image: registry.invalid/costcrew:v0.6.0")')" \
	"measured NOTHING"

run_case "temp: TMPDIR inside the data volume instead of a /tmp mount" pass \
	'./scripts/read-only-root-has-a-temp.sh' \
	"$(py 'edit("manifests/49-costcrew.yaml", "            - { name: tmp, mountPath: /tmp }\n          readinessProbe:", "          readinessProbe:")
edit("manifests/49-costcrew.yaml", "          env:\n            - name: TRAILRYX_TRUST_DOMAIN", "          env:\n            - name: TMPDIR\n              value: /var/lib/costcrew\n            - name: TRAILRYX_TRUST_DOMAIN")')"

run_case "temp: the temp size changes" pass \
	'./scripts/read-only-root-has-a-temp.sh' \
	"$(py 'edit("manifests/49-costcrew.yaml", "sizeLimit: 128Mi", "sizeLimit: 256Mi")')"

# The agent firewall (CLAUDE.md invariant 37, TokenFuse invariants 25 to 27 and 93). A
# gateway that starts in shadow protects nothing and says nothing about it, and TokenFuse
# ignores a misspelt mode without a word. The faults: the switch gone from the gateway, the
# gateway defaulting to shadow or to off, the switch set twice (the later entry wins without a
# word), every gateway start taken away, the validator accepting a misspelt word or refusing a
# real one, the validator taken away, a deploy path that checks the mode only after its
# install, and a deploy path that takes --firewall and applies nothing. Then a comment (must
# pass).
TEETH_EDIT_96="$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d\n", "")')"
run_case "firewall-is-enforce-by-default: the gateway container loses the switch" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$TEETH_EDIT_96" \
	"has no TOKENFUSE_FIREWALL env var"

TEETH_EDIT_97="$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d", "\x7b name: TOKENFUSE_FIREWALL, value: \"shadow\" \x7d")')"
run_case "firewall-is-enforce-by-default: the gateway defaults to shadow" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$TEETH_EDIT_97" \
	'not "enforce"'

TEETH_EDIT_98="$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d", "\x7b name: TOKENFUSE_FIREWALL, value: \"off\" \x7d")')"
run_case "firewall-is-enforce-by-default: the gateway defaults to off" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$TEETH_EDIT_98" \
	'not "enforce"'

TEETH_EDIT_99="$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d\n", "            - \x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d\n            - \x7b name: TOKENFUSE_FIREWALL, value: \"shadow\" \x7d\n")')"
run_case "firewall-is-enforce-by-default: the switch is set twice, the second to shadow" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$TEETH_EDIT_99" \
	"set 2 times"

run_case "firewall-is-enforce-by-default: a comment naming shadow beside the switch" pass \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d\n", "            # shadow is the gateway default only when the variable is unset.\n            - \x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d\n")')"

TEETH_EDIT_100="$(py 'edit("manifests/10-planes.yaml", "          command: [\"/usr/local/bin/tokenfuse\"]\n", "          command: [\"/bin/true\"]\n")')"
run_case "firewall-is-enforce-by-default: every gateway start taken away" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$TEETH_EDIT_100" \
	"measured nothing"

run_case "firewall/mode.sh: a misspelt mode is accepted" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$(py 'edit("firewall/mode.sh", "  enforce)\n", "  enforce|enforced)\n")')" \
	"accepts 'enforced'"

run_case "firewall/mode.sh: the real word enforce is refused" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$(py 'edit("firewall/mode.sh", "  enforce)\n", "  enforcex)\n")')" \
	"refuses 'enforce'"

run_case "firewall/mode.sh: taken away" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$(py 'import os; os.remove("firewall/mode.sh")')" \
	"firewall/mode.sh is missing"

TEETH_EDIT_101="$(py 'edit("cloud/gcp/deploy-gcp.sh", "\"$ROOT/firewall/mode.sh\" check \"$FIREWALL_MODE\"", "\"$ROOT/firewall/mode.sh\" true \"$FIREWALL_MODE\"")')"
run_case "firewall-is-enforce-by-default: a deploy path checks the mode but does not stop on it" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$TEETH_EDIT_101" \
	"before its first apply"

TEETH_EDIT_102="$(py 'edit("cloud/aws/deploy-aws.sh", "    --firewall) FIREWALL_MODE=\"$2\"; shift 2 ;;\n", "")')"
run_case "deploy-flags-agree: a deploy path stops taking --firewall" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$TEETH_EDIT_102" \
	"does not parse --firewall"

run_case "deploy-flags-agree: the firewall flag is accepted and applies nothing" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("deploy.sh", "set env deploy/tokenfuse-gateway -c gateway TOKENFUSE_FIREWALL=$FIREWALL_MODE", "get deploy/tokenfuse-gateway -c gateway TOKENFUSE_FIREWALL=$FIREWALL_MODE")')" \
	"never applies"

# The PII scanners (CLAUDE.md invariant 38). A gateway or broker that starts with its scanner off
# looks at nothing about personal data and says nothing about it. The faults: the literal gone from
# the gateway, the gateway defaulting to off or to block, the switch set twice, every gateway start
# taken away, the broker's literal gone, the broker defaulting to off, every broker start taken away,
# the validator accepting a misspelt word or refusing the real one, the validator taken away, a deploy
# path that checks the mode only after its install, a deploy path that stops taking --pii-mode, and a
# deploy path that applies the switch before its kustomization. Then a comment (must pass).
TEETH_EDIT_103="$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d\n", "")')"
run_case "pii-is-shadow-by-default: the gateway container loses the switch" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$TEETH_EDIT_103" \
	"has no TOKENFUSE_DLP_PII env var"

TEETH_EDIT_104="$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d", "\x7b name: TOKENFUSE_DLP_PII, value: \"off\" \x7d")')"
run_case "pii-is-shadow-by-default: the gateway defaults to off" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$TEETH_EDIT_104" \
	'not "shadow"'

TEETH_EDIT_105="$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d", "\x7b name: TOKENFUSE_DLP_PII, value: \"block\" \x7d")')"
run_case "pii-is-shadow-by-default: the gateway defaults to block" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$TEETH_EDIT_105" \
	'not "shadow"'

TEETH_EDIT_106="$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d\n", "            - \x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d\n            - \x7b name: TOKENFUSE_DLP_PII, value: \"off\" \x7d\n")')"
run_case "pii-is-shadow-by-default: the switch is set twice, the second to off" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$TEETH_EDIT_106" \
	"set 2 times"

run_case "pii-is-shadow-by-default: a comment naming block beside the switch" pass \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d\n", "            # block refuses a call that carries a finding; the literal below is shadow.\n            - \x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d\n")')"

TEETH_EDIT_107="$(py 'edit("manifests/10-planes.yaml", "          command: [\"/usr/local/bin/tokenfuse\"]\n", "          command: [\"/bin/true\"]\n")')"
run_case "pii-is-shadow-by-default: every gateway start taken away" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$TEETH_EDIT_107" \
	"no gateway start was found"

TEETH_EDIT_108="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "            - \x7b name: TOKENFUSE_MCP_DLP_PII, value: \"shadow\" \x7d\n", "")')"
run_case "pii-is-shadow-by-default: the broker container loses the switch" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$TEETH_EDIT_108" \
	"has no TOKENFUSE_MCP_DLP_PII env var"

TEETH_EDIT_109="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_MCP_DLP_PII, value: \"shadow\" \x7d", "\x7b name: TOKENFUSE_MCP_DLP_PII, value: \"off\" \x7d")')"
run_case "pii-is-shadow-by-default: the MCP broker defaults to off" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$TEETH_EDIT_109" \
	'TOKENFUSE_MCP_DLP_PII is "off"'

TEETH_EDIT_110="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "          args: [\"mcp-broker\"]\n", "          args: [\"mcp-brokr\"]\n")')"
run_case "pii-is-shadow-by-default: every MCP broker start taken away" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$TEETH_EDIT_110" \
	"no MCP broker start was found"

run_case "pii/mode.sh: a misspelt mode is accepted" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("pii/mode.sh", "  shadow)\n", "  shadow|shadows)\n")')" \
	"accepts 'shadows'"

run_case "pii/mode.sh: the real word shadow is refused" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("pii/mode.sh", "  shadow)\n", "  shadowx)\n")')" \
	"refuses 'shadow'"

run_case "pii/mode.sh: taken away" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'import os; os.remove("pii/mode.sh")')" \
	"pii/mode.sh is missing"

TEETH_EDIT_111="$(py 'edit("cloud/gcp/deploy-gcp.sh", "\"$ROOT/pii/mode.sh\" check \"$PII_MODE\"", "\"$ROOT/pii/mode.sh\" true \"$PII_MODE\"")')"
run_case "pii-is-shadow-by-default: a deploy path checks the mode but does not stop on it" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$TEETH_EDIT_111" \
	"before its first apply"

TEETH_EDIT_112="$(py 'edit("cloud/aws/deploy-aws.sh", "    --pii-mode) PII_MODE=\"$2\"; shift 2 ;;\n", "")')"
run_case "deploy-flags-agree: a deploy path stops taking --pii-mode" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$TEETH_EDIT_112" \
	"does not parse --pii-mode"

run_case "deploy-flags-agree: the gateway PII switch is accepted and applies nothing" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("deploy.sh", "set env deploy/tokenfuse-gateway -c gateway TOKENFUSE_DLP_PII=$PII_MODE", "get deploy/tokenfuse-gateway -c gateway TOKENFUSE_DLP_PII=$PII_MODE")')" \
	"never applies"

run_case "deploy-flags-agree: the broker PII switch is accepted and applies nothing" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "set env deploy/tokenfuse-mcp-broker -c broker TOKENFUSE_MCP_DLP_PII=$PII_MODE", "get deploy/tokenfuse-mcp-broker -c broker TOKENFUSE_MCP_DLP_PII=$PII_MODE")')" \
	"never applies"

TEETH_EDIT_113="$(py 'edit("cloud/gcp/deploy-gcp.sh", "  k_ \"-n agent-stack set env deploy/tokenfuse-gateway -c gateway TOKENFUSE_DLP_PII=$PII_MODE\" >/dev/null \\\n", "  true \\\n"); edit("cloud/gcp/deploy-gcp.sh", "k_ \"apply -k /root/stack-k8s/manifests\"", "k_ \"-n agent-stack set env deploy/tokenfuse-gateway -c gateway TOKENFUSE_DLP_PII=$PII_MODE\" >/dev/null\nk_ \"apply -k /root/stack-k8s/manifests\"")')"
run_case "deploy-flags-agree: the gateway PII switch is applied before the kustomization" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$TEETH_EDIT_113" \
	"BEFORE its"

# Client keys and the identity map (CLAUDE.md invariant 39). Each case runs the one section of
# identity-files-are-checked.sh its fault is about (IDENTITY_SECTIONS), because sections C and D
# start the gateway image and the whole gate is slow. A: the manifest; B: the grammar before any
# tool runs; C: the gateway image's own reading; D: the cluster half against a stub kubectl; E:
# verify.sh. Then the subject taken away twice, and a comment (must pass).
run_case "identity-files: the gateway loses its client keys setting" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - name: TOKENFUSE_CLIENT_KEYS\n              valueFrom: \x7b secretKeyRef: \x7b name: gateway-client-keys, key: client_keys \x7d \x7d\n", "")')" \
	"sets no TOKENFUSE_CLIENT_KEYS"

run_case "identity-files: the gateway loses its identity map setting" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - name: TOKENFUSE_IDENTITY_MAP\n              valueFrom: \x7b configMapKeyRef: \x7b name: gateway-identity-map, key: map_path, optional: true \x7d \x7d\n", "")')" \
	"sets no TOKENFUSE_IDENTITY_MAP"

# Invariant 50 turned this case around: the keys are required, so an optional reference is the fault.
run_case "identity-files: the client keys become optional" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "name: gateway-client-keys, key: client_keys \x7d", "name: gateway-client-keys, key: client_keys, optional: true \x7d")')" \
	"optional, so a cluster with no Secret"

run_case "identity-files: the map volume becomes required" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "configMap: \x7b name: gateway-identity-map, optional: true, ", "configMap: \x7b name: gateway-identity-map, ")')" \
	"ConfigMap not optional"

run_case "identity-files: the map path becomes a literal" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "              valueFrom: \x7b configMapKeyRef: \x7b name: gateway-identity-map, key: map_path, optional: true \x7d \x7d\n", "              value: /etc/tokenfuse/identity/identity.json\n")')" \
	"not read from the map's own ConfigMap"

run_case "identity-files: the map is mounted writable" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "mountPath: /etc/tokenfuse/identity, readOnly: true", "mountPath: /etc/tokenfuse/identity, readOnly: false")')" \
	"not read only"

run_case "identity-files: another workload is handed the client keys" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("manifests/20-console.yaml", "            - \x7b name: GENARYX_COPILOT_BASE_URL,", "            - name: GATE_PLANTED_KEYS\n              valueFrom: \x7b secretKeyRef: \x7b name: gateway-client-keys, key: client_keys, optional: true \x7d \x7d\n            - \x7b name: GENARYX_COPILOT_BASE_URL,")')" \
	"names gateway-client-keys or gateway-identity-map"

run_case "identity-files: a manifest declares the operator's ConfigMap" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'open("manifests/00-base.yaml", "a").write("---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: gateway-identity-map\n  namespace: agent-stack\ndata:\n  map_path: /etc/tokenfuse/identity/identity.json\n")')" \
	"declares the ConfigMap the operator"

run_case "identity-files: up.sh writes a path the gateway does not read" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "MAP_DIR=/etc/tokenfuse/identity\n", "MAP_DIR=/etc/tokenfuse/identities\n")')" \
	"mounts nothing at /etc/tokenfuse/identities"

TEETH_EDIT_114="$(py 'edit("manifests/10-planes.yaml", "          command: [\"/usr/local/bin/tokenfuse\"]\n", "          command: [\"/bin/true\"]\n")')"
run_case "identity-files: no gateway start left to judge" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_114" \
	"measured NOTHING"

run_case "identity-files: identity/up.sh taken away" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'import os; os.remove("identity/up.sh")')" \
	"identity/up.sh is missing"

run_case "identity-files: a comment that names another form of the setting is not the setting" pass \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - name: TOKENFUSE_CLIENT_KEYS\n", "            # optional: true would start a gateway that answers anyone; the reference below is required.\n            - name: TOKENFUSE_CLIENT_KEYS\n")')"

TEETH_EDIT_115="$(py 'edit("identity/up.sh", "[ \"$\x7b#secret\x7d\" -lt 24 ]", "[ \"$\x7b#secret\x7d\" -lt 8 ]")')"
run_case "identity-files: a short secret is accepted" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_115" \
	"(a secret of 23 characters) reached docker"

run_case "identity-files: a quote or a dollar reaches the Secret" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "re_chars=\x27^[A-Za-z0-9._~+/=@:-]+$\x27", "re_chars=\x27^.+$\x27")')" \
	"(a secret with a dollar) reached docker"

TEETH_EDIT_116="$(py 'edit("identity/up.sh", "die \"--client-keys-file: line $n gives a secret an earlier line already gave", ": \"--client-keys-file: line $n gives a secret an earlier line already gave")')"
run_case "identity-files: a secret given twice is kept" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_116" \
	"(a secret given twice) reached docker"

run_case "identity-files: a NUL byte is let through" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "printf \x27names a file holding a NUL byte\x27; return 0;", ":;")')" \
	"(a NUL byte) reached docker"

TEETH_EDIT_117="$(py 'edit("identity/up.sh", "[ \"$count\" -gt 0 ] || die", "[ \"$count\" -ge 0 ] || die")')"
run_case "identity-files: a keys file of comments alone is accepted" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_117" \
	"(comments and blank lines only) was accepted"

TEETH_EDIT_118="$(py 'edit("identity/up.sh", "[ \"$first\" = \"\x7b\" ] || die", "[ -n \"$first\" ] || die")')"
run_case "identity-files: a map that is not a JSON object passes the first half" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_118" \
	"(a JSON array, not an object) reached docker"

TEETH_EDIT_119="$(py 'edit("identity/up.sh", "die \"--client-keys-file: line $n $why.", "die \"--client-keys-file: line $n ($line) $why.")')"
run_case "identity-files: a refusal repeats the secret" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_119" \
	"repeats the secret"

run_case "identity-files: a map larger than a ConfigMap holds is accepted" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "MAP_MAX=1044480\n", "MAP_MAX=10485760\n")')" \
	"(a map larger than a ConfigMap holds) reached docker"

TEETH_EDIT_120="$(py 'edit("identity/up.sh", "    *\"tokenfuse gateway listening\"*) ;;\n", "    *) ;;\n")')"
run_case "identity-files: the gateway's own refusal is not heard" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_120" \
	"refused, but not saying: not declared in units[]"

TEETH_EDIT_121="$(py 'edit("identity/up.sh", "grep -qF \x27identity map: ON (\x27 <<<\"$logs\" \\\n", "true \\\n")')"
run_case "identity-files: a map that configures nothing is accepted" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_121" \
	"configures nothing ({}) was accepted"

TEETH_EDIT_122="$(py 'edit("identity/up.sh", "orphans=\"$(sed -n", "orphans=\"$(: sed -n")')"
run_case "identity-files: a map that binds a key with no secret is accepted" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_122" \
	"binds a key id no client key carries was accepted"

TEETH_EDIT_123="$(py 'edit("identity/up.sh", "unbound=\"$(sed -n", "unbound=\"$(: sed -n")')"
run_case "identity-files: a client key the map does not bind is accepted" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_123" \
	"a client key the map does not bind was accepted"

TEETH_EDIT_124="$(py 'edit("identity/up.sh", "--name \"$CHECK_CONTAINER\" --network none \\\n", "--name \"$CHECK_CONTAINER\" \\\n")')"
run_case "identity-files: the check container reaches the network" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_124" \
	"with a network"

TEETH_EDIT_125="$(py 'edit("identity/up.sh", "      -e TOKENFUSE_CLIENT_KEYS \\\n", "      -e \"TOKENFUSE_CLIENT_KEYS=$spec\" \\\n")')"
run_case "identity-files: the keys ride the docker command line" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_125" \
	"put a secret on the docker command line"

TEETH_EDIT_126="$(py 'edit("identity/up.sh", "      --entrypoint \"$GATEWAY_CMD\" \\\n", "")')"
run_case "identity-files: the check gives the image no command" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_126" \
	"with no ENTRYPOINT, the shape BUILD_FROM_SOURCE builds was refused"

TEETH_EDIT_127="$(py 'edit("identity/up.sh", "identity_check \"$IMAGE\" \"$SPEC\" \"$MAPF\"\n", "true \"$IMAGE\" \"$SPEC\" \"$MAPF\"\n")')"
run_case "identity-files: a refused file still writes to the cluster" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_127" \
	"still wrote to the cluster"

TEETH_EDIT_128="$(py 'edit("identity/up.sh", "SPEC=\"$KEPT_SPEC\"\n[ \"$KEYS_GIVEN\" = 0 ] || SPEC=\"$KEYS_NEW\"\n", "SPEC=\"$KEYS_NEW\"\n")')"
run_case "identity-files: a re-run that names no file drops the kept keys" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_128" \
	"a re-run that names no file"

TEETH_EDIT_129="$(py 'edit("identity/up.sh", "[ -z \"$MAP_SHA\" ] || ANN_MAP_WANT=\"$MAP_SHA\"\n", "[ -z \"$MAP_SHA\" ] || ANN_MAP_WANT=\"$MAP_SHA-$$\"\n")')"
run_case "identity-files: the same map again restarts the gateway" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_129" \
	"the same map given again"

TEETH_EDIT_130="$(py 'edit("identity/up.sh", "[ -z \"$MAP_SHA\" ] || ANN_MAP_WANT=\"$MAP_SHA\"\n", "[ -z \"$MAP_SHA\" ] || ANN_MAP_WANT=on\n")')"
run_case "identity-files: a new map does not restart the gateway" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_130" \
	"a new map did not roll the gateway"

TEETH_EDIT_131="$(py 'edit("identity/up.sh", "[ \"$SECRET_PRESENT\" = 0 ] || ANN_KEYS_WANT=\"$SECRET_RV\"\n", "[ \"$SECRET_PRESENT\" = 0 ] || ANN_KEYS_WANT=on\n")')"
run_case "identity-files: a new keys file does not restart the gateway" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_131" \
	"a new keys file did not roll the gateway"

TEETH_EDIT_132="$(py 'edit("identity/up.sh", "      | k create -f - >/dev/null \\\n      || die \"could not create Secret $SECRET_NAME\"", "      >/dev/null; k create secret generic \"$SECRET_NAME\" --from-literal=\"$SECRET_KEY=$SPEC\" >/dev/null \\\n      || die \"could not create Secret $SECRET_NAME\"")')"
run_case "identity-files: the keys ride the kubectl command line" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_132" \
	"a secret appeared on a kubectl command line"

TEETH_EDIT_133="$(py 'edit("identity/up.sh", "if [ -n \"$seen_keys\" ] && [ \"$seen_keys\" != \"$CHECK_KEYS\" ]; then", "if false; then")')"
run_case "identity-files: up.sh believes a gateway that reports other keys" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_133" \
	"reported another number of keys than it was given was believed"

run_case "identity-files: verify.sh stops asking for a call with no key" fail \
	'IDENTITY_SECTIONS=E ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("verify.sh", "(\x27nokey\x27, \x27\x27), ", "")')" \
	"refuse a call with no key"

run_case "identity-files: verify.sh stops comparing the running map" fail \
	'IDENTITY_SECTIONS=E ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("verify.sh", "annotations.taipanbox\\.dev/identity-map-sha256", "annotations.taipanbox\\.dev/identity-map")')" \
	"compares what the gateway's pod template says"

# Invariant 40: every flag the GCP launcher takes, the AWS launcher takes too, or
# allow-lists by name with its reason. The stale-entry case keeps the list honest.
run_case "aws-takes-every-gcp-flag: the AWS launcher drops --copilot-key-file" fail \
	'./scripts/aws-takes-every-gcp-flag.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "--copilot-key-file)", "--copilot-key-fil)")')" \
	"does not take --copilot-key-file"

run_case "aws-takes-every-gcp-flag: a flag only the GCP launcher takes" fail \
	'./scripts/aws-takes-every-gcp-flag.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "    --skip-images)", "    --probe-gcp-only) PROBE=1; shift ;;\n    --skip-images)")')" \
	"does not take --probe-gcp-only"

run_case "aws-takes-every-gcp-flag: the GCP option parser is taken away" fail \
	'./scripts/aws-takes-every-gcp-flag.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "while [ $# -gt 0 ]; do", "while [ $# -gt 0 ] ; do")')" \
	"measured NOTHING"

run_case "aws-takes-every-gcp-flag: the AWS launcher is taken away" fail \
	'./scripts/aws-takes-every-gcp-flag.sh' \
	"$(py 'import os
os.remove("cloud/aws/deploy-aws.sh")')" \
	"measured NOTHING"

run_case "aws-takes-every-gcp-flag: a flag only the AWS launcher takes is not a fault" pass \
	'./scripts/aws-takes-every-gcp-flag.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "    --skip-images)", "    --probe-aws-only) PROBE=1; shift ;;\n    --skip-images)")')"

run_case "aws-takes-every-gcp-flag: a GCP-only flag with an allow-list entry passes" pass \
	'./scripts/aws-takes-every-gcp-flag.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "    --skip-images)", "    --probe-gcp-only) PROBE=1; shift ;;\n    --skip-images)")
edit("scripts/aws-takes-every-gcp-flag.sh", "ALLOW=\"\"", "ALLOW=\"--probe-gcp-only|a probe flag for this case\"")')"

TEETH_EDIT_134="$(py 'edit("scripts/aws-takes-every-gcp-flag.sh", "ALLOW=\"\"", "ALLOW=\"--no-such-flag|a flag nobody takes\"")')"
run_case "aws-takes-every-gcp-flag: an allow-list entry names a flag GCP does not take" fail \
	'./scripts/aws-takes-every-gcp-flag.sh' \
	"$TEETH_EDIT_134" \
	"the allow-list names --no-such-flag"

# Invariant 45: cluster DNS keeps a replica through a drain, and k3s's coredns is left to k3s.
run_case "cluster-dns-has-a-budget: an installer applies no budget" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "\x27kind: PodDisruptionBudget\x27", "\x27kind: PodDisruptionBudgetX\x27")')" \
	"never applies a PodDisruptionBudget"

run_case "cluster-dns-has-a-budget: the budget keeps nothing up" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'edit("install.sh", "\x27  minAvailable: 1\x27", "\x27  minAvailable: 0\x27")')" \
	"not the document this gate holds"

run_case "cluster-dns-has-a-budget: the budget selects other pods" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "matchLabels: \x7b k8s-app: kube-dns \x7d", "matchLabels: \x7b k8s-app: coredns \x7d")')" \
	"not the document this gate holds"

TEETH_EDIT_135="$(py 'edit("install.sh", "if [ \"$DNS_WANT\" -ge 2 ]; then", "if true; then")')"
run_case "cluster-dns-has-a-budget: the budget is applied with one replica too" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$TEETH_EDIT_135" \
	"outside"

TEETH_EDIT_136="$(py 'edit("cloud/gcp/install-gcp.sh", "echo \"   coredns replicas=$DNS_WANT\"\n", "echo \"   coredns replicas=$DNS_WANT\"\nk_ \"-n kube-system patch deployment coredns --type merge -p x\" >/dev/null || true\n")')"
run_case "cluster-dns-has-a-budget: an installer patches k3s's coredns Deployment" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$TEETH_EDIT_136" \
	"changes k3s's coredns Deployment"

run_case "cluster-dns-has-a-budget: a comment about patching coredns is not a fault" pass \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "echo \"   coredns replicas=$DNS_WANT\"\n", "echo \"   coredns replicas=$DNS_WANT\"\n# never patch deployment coredns here: k3s re-applies its manifest\n")')"

run_case "cluster-dns-has-a-budget: verify.sh stops checking the budget" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'edit("verify.sh", "get pdb coredns -o jsonpath=", "get pdb dns -o jsonpath=")')" \
	"verify.sh does not check"

run_case "cluster-dns-has-a-budget: no installer is left to judge" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'for p in ("install.sh", "cloud/gcp/install-gcp.sh", "cloud/aws/install-aws.sh"):
    s = open(p).read()
    k = "sh -s - " + "serv" + "er"
    assert k in s
    open(p, "w").write(s.replace(k, "sh -s - serve"))')" \
	"measured NOTHING"

# Invariant 45, the replica policy: three replicas from five nodes, two from two, one alone.
TEETH_EDIT_137="$(py 'edit("install.sh", "[ \"${#ALL_NODES[@]}\" -ge 5 ] && DNS_WANT=3", "[ \"${#ALL_NODES[@]}\" -ge 5 ] && DNS_WANT=2")')"
run_case "cluster-dns-has-a-budget: five nodes get two replicas" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$TEETH_EDIT_137" \
	"the replica policy"

TEETH_EDIT_138="$(py 'edit("cloud/gcp/install-gcp.sh", "[ \"${#ALL_NODES[@]}\" -ge 5 ] && DNS_WANT=3\n", "")')"
run_case "cluster-dns-has-a-budget: the three-replica line is dropped from one installer" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$TEETH_EDIT_138" \
	"the replica policy"

run_case "cluster-dns-has-a-budget: the installers disagree on the threshold" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "-ge 5 ] && DNS_WANT=3", "-ge 4 ] && DNS_WANT=3")')" \
	"the replica policy"

# Invariant 41: a secret is minted from a bounded read, by one generator, sourced. The
# unbounded line comes back, inside a caller and inside the generator; the generator
# returns short, repeats, or is copied; a caller forgets the source or sources it too
# late; a message that only names the device must pass; and the subject taken away.
TEETH_EDIT_139="$(py 'edit("deploy.sh", "CONSOLE_PASSWORD=\"$(gen 28)\"", "CONSOLE_PASSWORD=\"$( set +o pipefail; LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 28 )\"")')"
run_case "gen-is-bounded: a deploy script reads urandom with no bound" fail \
	'./scripts/gen-is-bounded.sh' \
	"$TEETH_EDIT_139" \
	"deploy.sh:"

TEETH_EDIT_140="$(py 'edit("lib/gen.sh", "v=\"$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc \x27A-Za-z0-9\x27)\"", "v=\"$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 64)\"")')"
run_case "gen-is-bounded: the generator itself reads with no bound" fail \
	'./scripts/gen-is-bounded.sh' \
	"$TEETH_EDIT_140" \
	"lib/gen.sh:"

run_case "gen-is-bounded: the generator returns short without saying so" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("lib/gen.sh", "v=\"$\x7bv:0:$n\x7d\"", "v=\"$\x7bv:0:$((n - 1))\x7d\"")
edit("lib/gen.sh", "if [ \"$\x7b#v\x7d\" != \"$n\" ]; then", "if false; then")')" \
	"that are not exactly 28 of A-Za-z0-9"

run_case "gen-is-bounded: the generator says nothing and succeeds when it read nothing" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("lib/gen.sh", "    return 1\n", "    return 0\n")')" \
	"with nothing to read"

TEETH_EDIT_141="$(py 'edit("lib/gen.sh", "  printf \x27%s\x27 \"$v\"\n", "  printf \x27%s\x27 \"$(printf %0\"$n\"d 0)\"\n")')"
run_case "gen-is-bounded: the generator prints the same value every time" fail \
	'./scripts/gen-is-bounded.sh' \
	"$TEETH_EDIT_141" \
	"printed the same value twice"

TEETH_EDIT_142="$(py 'edit("cloud/gcp/deploy-gcp.sh", ". \"$ROOT/lib/gen.sh\" || die", "gen() \x7b local v; v=\"$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc A-Za-z0-9)\"; printf %s \"$\x7bv:0:$1\x7d\"; \x7d\n. \"$ROOT/lib/gen.sh\" || die")')"
run_case "gen-is-bounded: a second copy of the generator in a deploy script" fail \
	'./scripts/gen-is-bounded.sh' \
	"$TEETH_EDIT_142" \
	"a second gen() outside lib/gen.sh"

TEETH_EDIT_143="$(py 'edit("cloud/aws/deploy-aws.sh", ". \"$ROOT/lib/gen.sh\" || die \"no lib/gen.sh in $ROOT\"\n", "")')"
run_case "gen-is-bounded: a caller that never sources the generator" fail \
	'./scripts/gen-is-bounded.sh' \
	"$TEETH_EDIT_143" \
	"asks gen for a value and never sources lib/gen.sh"

run_case "gen-is-bounded: a caller that sources the generator below its first ask" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("deploy.sh", ". \"$ROOT/lib/gen.sh\" || die \"no lib/gen.sh in $ROOT\"\n", "")
s = open("deploy.sh").read()
open("deploy.sh", "w").write(s + ". \"$ROOT/lib/gen.sh\"\n")')" \
	"above the line that sources lib/gen.sh"

run_case "gen-is-bounded: a message that names the device reads nothing" pass \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("deploy.sh", "CONSOLE_PASSWORD=\"$(gen 28)\" || die", "say \"nothing here reads /dev/urandom, this only names it\"\n      CONSOLE_PASSWORD=\"$(gen 28)\" || die")')"

run_case "gen-is-bounded: the generator is taken away" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'import os
os.remove("lib/gen.sh")')" \
	"measured NOTHING"

# Every ask of the generator with a length, in every tracked shell file the gate reads, not a list of the
# files that asked when this case was written: a new mint library (lib/vouchryx-mint.sh) asked for 40 and
# left this case TOOTHLESS on the teeth run for branch feat/require-agent-tokens.
run_case "gen-is-bounded: nothing asks the generator for a length" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'import re, subprocess
names = subprocess.check_output(["git", "ls-files"]).decode().split("\n")
kept = ("scripts/gen-is-bounded.sh", "scripts/gates-have-teeth.sh")
asked = 0
for n in names:
    if n in kept or not (n.endswith(".sh") or n.startswith(".githooks/")):
        continue
    s = open(n, encoding="utf-8").read()
    t, k = re.subn(r"\$\(gen [0-9]+\)", "$(gen)", s)
    asked += k
    if t != s:
        open(n, "w", encoding="utf-8").write(t)
assert asked > 0, "no ask of gen with a length to take away"')" \
	"there is no length to run the generator for"

# Invariant 42: a typed deploy comes up green on its own. A typed manifest reads a
# Secret nothing makes; a launcher loses the door, mints it after the render, applies
# it, or hands create only part of it; door-secrets breaks the vault, the two keys,
# their length, the key id, stderr, the broker-only stop or the schema; and the
# subjects taken away. An optional reference and a comment must pass.
run_case "typed-door-is-minted: a typed manifest reads a Secret nothing mints" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "            - secretRef: \x7b name: typryx-keys \x7d\n", "            - secretRef: \x7b name: typryx-keys \x7d\n            - secretRef: \x7b name: typryx-extra \x7d\n")')" \
	"reads Secret typryx-extra"

run_case "typed-door-is-minted: an optional reference is not a fault" pass \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "            - secretRef: \x7b name: typryx-keys \x7d\n", "            - secretRef: \x7b name: typryx-keys \x7d\n            - secretRef: \x7b name: typryx-extra, optional: true \x7d\n")')"

run_case "typed-door-is-minted: a launcher loses its door" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 's = open("deploy.sh").read()
i = s.index("  DOOR_HAVE=\"$(k_")
j = s.index("  DOOR_DOCS=\"\"\n", i) + len("  DOOR_DOCS=\"\"\n")
open("deploy.sh", "w").write(s[:i] + s[j:])')" \
	"deploy.sh: its typed branch never calls typed/mode.sh door-secrets"

run_case "typed-door-is-minted: a launcher mints the door after the render" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 's = open("cloud/gcp/deploy-gcp.sh").read()
i = s.index("  DOOR_HAVE=\"$(k_")
j = s.index("  DOOR_DOCS=\"\"\n", i) + len("  DOOR_DOCS=\"\"\n")
block = s[i:j]
s = s[:i] + s[j:]
r = s.index("typed/mode.sh\" render")
e = s.index("\n", r) + 1
open("cloud/gcp/deploy-gcp.sh", "w").write(s[:e] + block + s[e:])')" \
	"after the render"

TEETH_EDIT_144="$(py 'edit("cloud/aws/deploy-aws.sh", "\"$DOOR_DOCS\" | k_ \"-n agent-stack create -f -\"", "\"$DOOR_DOCS\" | k_ \"-n agent-stack apply -f -\"")')"
run_case "typed-door-is-minted: a launcher applies the door's Secrets" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$TEETH_EDIT_144" \
	"hands the door's Secrets to apply"

TEETH_EDIT_145="$(py 'edit("cloud/gcp/deploy-gcp.sh", "\"$DOOR_DOCS\" | k_ \"-n agent-stack create -f -\"", "\"$DOOR_DOCS\" | head -n 9 | k_ \"-n agent-stack create -f -\"")')"
run_case "typed-door-is-minted: a launcher hands create only part of the door" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$TEETH_EDIT_145" \
	"not both door Secrets"

run_case "typed-door-is-minted: a comment about apply beside the door is not a fault" pass \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("deploy.sh", "  DOOR_DOCS=\"\"\n", "  # DOOR_DOCS never goes to apply, which would overwrite a Secret\n  DOOR_DOCS=\"\"\n")')"

run_case "typed-door-is-minted: the broker's vault does not carry typryx's bearer" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'p = "typed/mode.sh"
s = open(p).read()
a = "\"TOKENFUSE_MCP_SECRETS=typryx_key=$bearer\""
i = s.rindex(a)
open(p, "w").write(s[:i] + "\"TOKENFUSE_MCP_SECRETS=typryx_key=$broker_key\"" + s[i + len(a):])')" \
	"does not carry typryx's own bearer"

run_case "typed-door-is-minted: typryx and the broker get one key between them" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'p = "typed/mode.sh"
s = open(p).read()
a = "    bearer=\"$(gen 40)\" || refuse \"could not mint typryx\x27s key\"\n    broker_key=\"$(door_entry \"$callers\" \"$DOOR_KEY_ID\")\"\n    [ \"$bearer\" != \"$broker_key\" ]"
assert a in s
open(p, "w").write(s.replace(a, "    broker_key=\"$(door_entry \"$callers\" \"$DOOR_KEY_ID\")\"\n    bearer=\"$broker_key\"\n    [ -n \"$broker_key\" ]"))')" \
	"are the same"

TEETH_EDIT_146="$(py 'edit("typed/mode.sh", "    bearer=\"$(gen 40)\" || refuse", "    bearer=\"$(gen 16)\" || refuse")')"
run_case "typed-door-is-minted: typryx's bearer is short" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$TEETH_EDIT_146" \
	"not at least 32"

TEETH_EDIT_147="$(py 'edit("typed/mode.sh", "DOOR_KEY_ID=\"broker-caller\"", "DOOR_KEY_ID=\"agent://acme.example/broker-caller\"")')"
run_case "typed-door-is-minted: the broker's key id is an agent URI" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$TEETH_EDIT_147" \
	"hold no agent://acme.example/broker-caller"

TEETH_EDIT_148="$(py 'edit("typed/mode.sh", "    made=\"$DOOR_TYPRYX (identity", "    printf \x27%s\\n\x27 \"$bearer\" >&2\n    made=\"$DOOR_TYPRYX (identity")')"
run_case "typed-door-is-minted: a minted value reaches stderr" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$TEETH_EDIT_148" \
	"appears on stderr"

TEETH_EDIT_149="$(py 'edit("typed/mode.sh", "  elif [ \"$have_b\" = 1 ]; then\n", "  elif false; then\n")')"
run_case "typed-door-is-minted: the broker's Secret alone mints typryx's anyway" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$TEETH_EDIT_149" \
	"only the broker"

TEETH_EDIT_150="$(py 'edit("typed/mode.sh", "  refuse \"--have and --trust-domain only go with door-secrets\"\n", "  true\n")')"
run_case "typed-door-is-minted: --have rides along with another verb unnoticed" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$TEETH_EDIT_150" \
	"--have with another verb"

run_case "typed-door-is-minted: the minted Secrets are not schema-valid" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("typed/mode.sh", "labels: \x7b app: %s, plane: typed \x7d\\ntype: Opaque", "labels: \x7b app: %s, plane: typed \x7d\\ntypo: Opaque")')" \
	"do not validate"

run_case "typed-door-is-minted: the typed manifests are taken away" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'import os
os.remove("manifests/51-typryx.yaml")')" \
	"measured NOTHING"

run_case "typed-door-is-minted: no launcher is left to judge" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'for p in ("deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh"):
    edit(p, "    --with-typed)", "    --with-typd)")')" \
	"measured NOTHING about the launchers"

echo
run_case "wardryx-key-is-pep: a fresh secret mints the gateway's key as viewer again" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "$WARDRYX_GATEWAY_SECRET:default:pep", "$WARDRYX_GATEWAY_SECRET:default:viewer")')" \
	"does not mint the gateway's wardryx_keys entry as pep"

run_case "wardryx-key-is-pep: the aws installer mints the gateway's key as viewer again" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "$WARDRYX_GATEWAY_SECRET:default:pep", "$WARDRYX_GATEWAY_SECRET:default:viewer")')" \
	"does not mint the gateway's wardryx_keys entry as pep"

TEETH_EDIT_151="$(py 'edit("hub/add-site.sh", "NEW_WARDRYX_ENTRY=\"${WARDRYX_SECRET}:default:pep\"", "NEW_WARDRYX_ENTRY=\"${WARDRYX_SECRET}:default:viewer\"")')"
run_case "wardryx-key-is-pep: the hub gives a site's gateway viewer again" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$TEETH_EDIT_151" \
	"does not give a site's gateway entry pep"

TEETH_EDIT_152="$(py 'edit("install.sh", "if (p[1] == gw && n >= 3 && p[3] == \"viewer\") p[3] = \"pep\"", "if (n >= 3 && p[3] == \"viewer\") p[3] = \"pep\"")')"
run_case "wardryx-key-is-pep: the transform rewrites every key, not the gateway's" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$TEETH_EDIT_152" \
	"is not the one install.sh has"

TEETH_EDIT_153="$(py 'edit("install.sh", "        e = p[1]\n        for (k = 2; k <= n; k++) e = e \":\" p[k]", "        e = p[1] \"x\"\n        for (k = 2; k <= n; k++) e = e \":\" p[k]")')"
run_case "wardryx-key-is-pep: the transform changes the gateway's secret" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$TEETH_EDIT_153" \
	"is not the one install.sh has"

TEETH_EDIT_154="$(py 'edit("cloud/aws/install-aws.sh", "| wardryx_gateway_role_keys)\"\n", "| true)\"\n")')"
run_case "wardryx-key-is-pep: the migration is not in the aws installer" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$TEETH_EDIT_154" \
	"never runs the migration"

TEETH_EDIT_155="$(py 'edit("install.sh", "printf '\''%s'\'' \"{\\\"stringData\\\":{\\\"wardryx_keys\\\":\\\"$WARDRYX_KEYS_NEW\\\"}}\" | k_ \"-n agent-stack patch secret stack-keys --type merge --patch-file /dev/stdin\" >/dev/null", "k_ \"-n agent-stack patch secret stack-keys --type merge -p $WARDRYX_KEYS_NEW\" >/dev/null")')"
run_case "wardryx-key-is-pep: the migration writes the key on the command line" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$TEETH_EDIT_155" \
	"puts a key on a command line"

run_case "wardryx-key-is-pep: a pin moves back to the old wardryx" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "image: ghcr.io/taipanbox/wardryx:v2.7.0", "image: ghcr.io/taipanbox/wardryx:v1.5.0")')" \
	"does not pin wardryx v2.7.0"

run_case "wardryx-key-is-pep: a reworded comment is not a fault" pass \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "policy it enforces is not one. wardryx 2.0.0 refuses a viewer", "policy it enforces is not one; wardryx 2.0.0 refuses a viewer")')"


if [ "${TEETH_LIST:-}" != 1 ] && [ -n "$(git status --porcelain)" ]; then
	printf 'FAIL: this script left the tree dirty, so it cannot be trusted about anything above\n'
	git status --porcelain | head -5
	exit 1
fi

# Invariant 44. A cost report refuses a machine type it has no rate for; the three
# faults are the two ways to count it as zero and the loss of a known rate.
run_case "cost-live-refuses-unknown-rates: the AWS script counts an unknown type as zero" fail \
	'./scripts/cost-live-refuses-unknown-rates.sh' \
	"$(py 'edit("cloud/aws/cost-live.sh", "*)           return 1 ;;", "*)           echo 0 ;;")')" \
	"counts it as zero"

run_case "cost-live-refuses-unknown-rates: the GCP script counts an unknown type as zero" fail \
	'./scripts/cost-live-refuses-unknown-rates.sh' \
	"$(py 'edit("cloud/gcp/cost-live.sh", "*)              return 1 ;;", "*)              echo 0 ;;")')" \
	"counts it as zero"

run_case "cost-live-refuses-unknown-rates: the m7i.xlarge row is removed" fail \
	'./scripts/cost-live-refuses-unknown-rates.sh' \
	"$(py 'edit("cloud/aws/cost-live.sh", "    m7i.xlarge)  echo 0.2415 ;;\n", "")')" \
	"a known type must price and exit 0"

run_case "cost-live-refuses-unknown-rates: a reworded comment is not a fault" pass \
	'./scripts/cost-live-refuses-unknown-rates.sh' \
	"$(py 'edit("cloud/aws/cost-live.sh", "# eu-central-1, on demand, Linux, shared tenancy.", "# eu-central-1, on demand, Linux, shared tenancy (reworded).")')"
# Invariant 46: a node that is shut down stops its pods before its network goes.
run_case "nodes-stop-their-pods-first: an installer writes no shutdown config" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "graceful_shutdown_conf() {", "graceful_shutdown_cfg() {")')" \
	"defines no graceful_shutdown_conf"

run_case "nodes-stop-their-pods-first: the logind delay is shorter than the period" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$(py 'edit("install.sh", "InhibitDelayMaxSec=180", "InhibitDelayMaxSec=30")')" \
	"is not the drop-in this gate holds"

TEETH_EDIT_156="$(py 'edit("install.sh", "put_graceful_shutdown \"$FIRST\"\n", "")')"
run_case "nodes-stop-their-pods-first: the first server gets no file" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$TEETH_EDIT_156" \
	"without writing the graceful-shutdown files"

run_case "nodes-stop-their-pods-first: an install passes its own config-dir" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$(py 'edit("install.sh", "--secrets-encryption \\\n", "--secrets-encryption \\\n    --kubelet-arg=config-dir=/etc/elsewhere \\\n")')" \
	"passes --kubelet-arg=config-dir"

run_case "nodes-stop-their-pods-first: workloads get less time than a pod may take" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$(py 'for p in ("install.sh", "cloud/gcp/install-gcp.sh", "cloud/aws/install-aws.sh"):
    edit(p, "shutdownGracePeriod: 60s", "shutdownGracePeriod: 40s")')" \
	"our workloads get"

run_case "nodes-stop-their-pods-first: the installers disagree on the shutdown period" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "shutdownGracePeriod: 60s", "shutdownGracePeriod: 61s")')" \
	"is not the KubeletConfiguration this gate holds"

TEETH_EDIT_157="$(py 'edit("verify.sh", "$2 == \"Failed\" && ($3 == \"Terminated\" || $3 == \"NodeShutdown\")", "$2 == \"Failed\" && $3 == \"NoSuchReason\"")')"
run_case "nodes-stop-their-pods-first: verify.sh counts a pod a shutdown stopped" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$TEETH_EDIT_157" \
	"did not report exactly one bad pod"

TEETH_EDIT_158="$(py 'edit("verify.sh", "!($1 in gone) && $3 != \"Running\" && $3 != \"Completed\" { c++ }", "!($1 in gone) && $3 != \"Running\" && $3 != \"Completed\" && $3 != \"CrashLoopBackOff\" { c++ }")')"
run_case "nodes-stop-their-pods-first: verify.sh stops counting a crash loop" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$TEETH_EDIT_158" \
	"did not report exactly one bad pod"

run_case "nodes-stop-their-pods-first: every installer loses its server install" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$(py 'for p in ("install.sh", "cloud/gcp/install-gcp.sh", "cloud/aws/install-aws.sh"):
    s = open(p).read()
    k = "sh -s - " + "serv" + "er"
    assert k in s
    open(p, "w").write(s.replace(k, "sh -s - serve"))')" \
	"no k3s server install invocation"

run_case "nodes-stop-their-pods-first: no installer is left to judge" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$(py 'for p in ("install.sh", "cloud/gcp/install-gcp.sh", "cloud/aws/install-aws.sh"):
    s = open(p).read()
    k = "INSTALL_K3S_" + "VERSION="
    assert k in s
    open(p, "w").write(s.replace(k, "INSTALL_K3S_" + "VERSIONX="))')" \
	"measured NOTHING"
# Invariant 47: every shell script parses under /bin/bash (3.2 on a Mac) and uses no bash-4-only construct.
run_case "shell-scripts-parse: a script does not parse" fail \
	'./scripts/shell-scripts-parse.sh' \
	"$(py 'p = "verify.sh"
s = open(p).read()
open(p, "w").write(s + "\nif [ ; then\n")')" \
	"does not parse under"

run_case "shell-scripts-parse: a script uses a bash-4-only construct" fail \
	'./scripts/shell-scripts-parse.sh' \
	"$(py 'p = "verify.sh"
s = open(p).read()
open(p, "w").write(s + "\ndeclare -A seen\n")')" \
	"(bash 4 only)"

# Invariant 47: node checks read only the lines their probe printed.
run_case "node-checks-read-their-own-answer: an ssh call outside the helper" fail \
	'./scripts/node-checks-read-their-own-answer.sh' \
	"$(py 'p = "security-tests.sh"
s = open(p).read()
open(p, "w").write(s + "\nssh root@10.0.0.9 true\n")')" \
	"runs ssh outside node_probe"

run_case "node-checks-read-their-own-answer: the helper keeps the banner" fail \
	'./scripts/node-checks-read-their-own-answer.sh' \
	"$(py 'edit("security-tests.sh", "| sed -n \x27s/^SECCHK: //p\x27", "| cat")')" \
	"printed more than the command"

TEETH_EDIT_159="$(py 'edit("security-tests.sh", "SECCHK_SSH=\"-q -o LogLevel=ERROR", "SECCHK_OFF=\"-q -o LogLevel=ERROR")')"
run_case "node-checks-read-their-own-answer: the quiet ssh setting is gone" fail \
	'./scripts/node-checks-read-their-own-answer.sh' \
	"$TEETH_EDIT_159" \
	"defines no SECCHK_SSH"
# Invariant 48: every k3s server an installer starts is started with --secrets-encryption.
run_case "servers-encrypt-secrets: the GCP joining server starts without the flag" fail \
	'./scripts/servers-encrypt-secrets.sh' \
	"$(py 'p = "cloud/gcp/install-gcp.sh"
s = open(p).read()
a = "--secrets-encryption \\\n"
i = s.rindex(a)
open(p, "w").write(s[:i] + s[i + len(a):])')" \
	"starts a k3s server without --secrets-encryption"

run_case "servers-encrypt-secrets: the first server starts without the flag" fail \
	'./scripts/servers-encrypt-secrets.sh' \
	"$(py 'p = "install.sh"
s = open(p).read()
a = "--secrets-encryption \\\n"
i = s.index(a)
open(p, "w").write(s[:i] + s[i + len(a):])')" \
	"starts a k3s server without --secrets-encryption"

run_case "servers-encrypt-secrets: the flag is commented out" fail \
	'./scripts/servers-encrypt-secrets.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "    --secrets-encryption \\\n", "    # --secrets-encryption \\\n")')" \
	"starts a k3s server without --secrets-encryption"

run_case "servers-encrypt-secrets: a new server invocation has no flag" fail \
	'./scripts/servers-encrypt-secrets.sh' \
	"$(py 'p = "install.sh"
s = open(p).read()
open(p, "w").write(s + "\nsh_ \"$FIRST\" \"INSTALL_K3S_VERSION=1 sh -s - " + "serv" + "er --cluster-init\" < <(curl -sfL https://get.k3s.io)\n")')" \
	"starts a k3s server without --secrets-encryption"

TEETH_EDIT_160="$(py 'edit("security-tests.sh", "bad \"the Secret is plaintext in etcd, so", "bad \"the Secret is in etcd, so")')"
run_case "servers-encrypt-secrets: section 7 stops expecting encryption" fail \
	'./scripts/servers-encrypt-secrets.sh' \
	"$TEETH_EDIT_160" \
	"section 7 no longer reports"

# Invariant 49. The teeth run is split into CI shards, and a case that falls in no
# shard, or in two, changes no exit code, so nothing else would notice. These cases
# plant the split's own faults: the shard filter, the listing and the CI matrix.
# The planted faults are in the runner and the workflow, never in a gate. The
# cover gate is judged by what it lists, and its listing runs no case.

run_case "teeth-shards-cover-every-case: the shard filter uses one shard too many" fail \
	'./scripts/teeth-shards-cover-every-case.sh' \
	"$(py 'edit("scripts/gates-have-teeth.sh", "% shard_n )) -ne", "% (shard_n + 1) )) -ne")')" \
	"do not cover the whole list"

TEETH_EDIT_161="$(py 'edit("scripts/gates-have-teeth.sh", "printf \x27%s\\n\x27 \"$name\" >&3", ":")')"
run_case "teeth-shards-cover-every-case: the listing prints nothing" fail \
	'./scripts/teeth-shards-cover-every-case.sh' \
	"$TEETH_EDIT_161" \
	"measured nothing"

run_case "teeth-shards-cover-every-case: the CI matrix leaves the last shard out" fail \
	'./scripts/teeth-shards-cover-every-case.sh' \
	"$(py 'edit(".github/workflows/gates.yml", "shard: [1, 2, 3, 4, 5, 6]", "shard: [1, 2, 3, 4, 5]")')" \
	"does not run every shard"

# ---- metered-doors-require-keys (CLAUDE.md invariant 50): the gateway requires its client keys,
# runs strict, and a deploy given no files mints Felyx's key and the agents' key. The mint is run
# against a stand-in cluster; one case reaches the pinned gateway image through identity/up.sh.
run_case "metered-doors-require-keys: the gateway's client keys become optional" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "name: gateway-client-keys, key: client_keys \x7d", "name: gateway-client-keys, key: client_keys, optional: true \x7d")')" \
	"optional: true, so a cluster with no Secret"

run_case "metered-doors-require-keys: TOKENFUSE_CLIENT_KEYS goes missing" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - name: TOKENFUSE_CLIENT_KEYS\n              valueFrom: \x7b secretKeyRef: \x7b name: gateway-client-keys, key: client_keys \x7d \x7d\n", "")')" \
	"sets TOKENFUSE_CLIENT_KEYS 0 time(s)"

TEETH_EDIT_162="$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_IDENTITY_STRICT, value: \"enforce\" \x7d", "\x7b name: TOKENFUSE_IDENTITY_STRICT, value: \"warn\" \x7d")')"
run_case "metered-doors-require-keys: a gateway's identity map is only warned about" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_162" \
	"TOKENFUSE_IDENTITY_STRICT ['warn']"

run_case "metered-doors-require-keys: the console loses Felyx's key" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("manifests/20-console.yaml", "            - name: GENARYX_COPILOT_FUSE_KEY\n              valueFrom: \x7b secretKeyRef: \x7b name: felyx-client-key, key: client_key, optional: true \x7d \x7d\n", "")')" \
	"does not read GENARYX_COPILOT_FUSE_KEY from felyx-client-key"

TEETH_EDIT_163="$(py 'edit("lib/identity-mint.sh", "      agents=\"$(gen 40)\" || die \"could not mint the agents\x27 client key\"\n", "      agents=\"$felyx\"\n")')"
run_case "metered-doors-require-keys: the deploy stops minting the agents' key" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_163" \
	"an empty cluster was refused by the mint"

TEETH_EDIT_164="$(py 'edit("lib/identity-mint.sh", "      fi\n      ;;\n    *)\n      case \"$have\" in\n", "      fi\n      agents=\"$(gen 40)\"\n      ;;\n    *)\n      case \"$have\" in\n")')"
run_case "metered-doors-require-keys: a re-run writes a new agents' key" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_164" \
	"a re-run changed the agents' key file"

TEETH_EDIT_165="$(py 'edit("lib/identity-mint.sh", "\"agents\":[\"agent://%s/agents/*\"]", "\"agents\":[\"agent://%s/*\"]")')"
run_case "metered-doors-require-keys: the agents' key may speak as Felyx" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_165" \
	"may speak as Felyx"

TEETH_EDIT_166="$(py 'edit("lib/identity-mint.sh", "  chmod 0600 \"$keyfile\" || die", "  chmod 0644 \"$keyfile\" || die")')"
run_case "metered-doors-require-keys: the agent key file is readable by others" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_166" \
	"not 600"

TEETH_EDIT_167="$(py 'edit("lib/identity-mint.sh", "      if [ \"$label\" != minted ]; then\n", "      if [ \"$label\" = never ]; then\n")')"
run_case "metered-doors-require-keys: the operator's own keys are minted over" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_167" \
	"holding the operator's own keys was refused or written"

TEETH_EDIT_168="$(py 'edit("lib/identity-mint.sh", "          die \"ConfigMap $IDM_CM holds an identity map", "          : \"ConfigMap $IDM_CM holds an identity map")')"
run_case "metered-doors-require-keys: a map with no keys is accepted" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_168" \
	"a map with no client keys was accepted"

TEETH_EDIT_169="$(py 'edit("lib/identity-mint.sh", "        | k_ \"-n $IDM_NS create -f -\" >/dev/null \\\n        || die \"could not create Secret $IDM_SECRET\"", "        >/dev/null; k_ \"-n $IDM_NS create secret generic $IDM_SECRET --from-literal=$IDM_SECRET_KEY=$felyx:felyx,$agents:agents\" >/dev/null \\\n        || die \"could not create Secret $IDM_SECRET\"")')"
run_case "metered-doors-require-keys: a minted secret rides the kubectl command line" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_169" \
	"on a kubectl command line"

TEETH_EDIT_170="$(py 'edit("lib/identity-mint.sh", "the secret in %s (it is not printed here)\\n\x27 \"$1\"", "%s, the secret in %s\\n\x27 \"$(cat \"$1\")\" \"$1\"")')"
run_case "metered-doors-require-keys: the closing note prints the agents' key" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_170" \
	"appears in what the mint printed"

TEETH_EDIT_171="$(py 'edit("lib/identity-mint.sh", "the secret in %s (it is not printed here)\\n\x27 \"$1\"", "the secret in %s (it is not printed here)\\n\x27 \"the file\"")')"
run_case "metered-doors-require-keys: the closing note stops naming the key file" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_171" \
	"does not name the agents' key file"

TEETH_EDIT_172="$(py 'edit("cloud/aws/deploy-aws.sh", "identity_mint_settle \"$ROOT/agent-key\"\n", "")')"
run_case "metered-doors-require-keys: a deploy script stops minting" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_172" \
	"cloud/aws/deploy-aws.sh does not source lib/identity-mint.sh"

TEETH_EDIT_173="$(py 'edit("lib/identity-mint.sh", "\x7b\"key_id\":\"agents\",\"unit\":\"agents\"", "\x7b\"key_id\":\"agent\",\"unit\":\"agents\"")')"
run_case "metered-doors-require-keys: the minted map binds a key id nobody minted" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_173" \
	"the pinned gateway image refused the pair the mint made"

TEETH_EDIT_174="$(py 'edit("manifests/10-planes.yaml", "          command: [\"/usr/local/bin/tokenfuse\"]\n", "          command: [\"/bin/true\"]\n")')"
run_case "metered-doors-require-keys: no gateway container left to judge" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$TEETH_EDIT_174" \
	"measured NOTHING"

run_case "metered-doors-require-keys: the mint block is gone" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "# identity-mint: begin\n", "# identity-mint: start\n")')" \
	"measured nothing about the keys"

run_case "metered-doors-require-keys: the CostCrew crew's key is bound to every agent id, not its analysts" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "agent://%s/costcrew/*", "agent://%s/*")')" \
	"binds the CostCrew crew's key to"

run_case "metered-doors-require-keys: a comment in the mint library is reworded" pass \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "# What the end of a deploy says about the minted keys", "# What the end of a deploy says of the minted keys")')"

# identity/up.sh on a cluster whose keys a deploy minted, and a run that would leave none.
TEETH_EDIT_175="$(py 'edit("identity/up.sh", "if [ \"$SECRET_MINTED\" = 1 ] && [ \"$KEYS_GIVEN$MAP_GIVEN\" != 00 ]", "if [ \"$SECRET_MINTED\" = 2 ] && [ \"$KEYS_GIVEN$MAP_GIVEN\" != 00 ]")')"
run_case "identity-files: a keys file alone takes over minted keys" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_175" \
	"a keys file alone on a cluster whose keys a deploy minted was accepted"

TEETH_EDIT_176="$(py 'edit("identity/up.sh", "[ -n \"$SPEC\" ] \\\n  || die \"the gateway requires client keys", "[ -n \"$SPEC$MAPF\" ] \\\n  || die \"the gateway requires client keys")')"
run_case "identity-files: up.sh leaves the gateway no keys" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$TEETH_EDIT_176" \
	"was not refused for that reason"

TEETH_EDIT_177="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_WARDRYX_URL, value: \"http://wardryx:8090\" \x7d", "\x7b name: TOKENFUSE_WARDRYX_URL, value: \"http://typryx-wardryx-proxy:4330\" \x7d")')"
run_case "typed-mode-is-honest: the broker asks the proxy without the flag" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$TEETH_EDIT_177" \
	"WITHOUT --typed-risk-signal the broker asks"

# ---- broker-blocks-raw-secrets (CLAUDE.md invariant 51): the MCP broker blocks raw secrets and
# flagged listings and asks wardryx about every tool call, failing closed, in 52, in every typed
# render and in the image 52 pins.
TEETH_EDIT_178="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_MCP_DLP, value: \"block\" \x7d", "\x7b name: TOKENFUSE_MCP_DLP, value: \"shadow\" \x7d")')"
run_case "broker-blocks-raw-secrets: secrets in tool arguments go back to shadow" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$TEETH_EDIT_178" \
	"TOKENFUSE_MCP_DLP 'shadow', not block"

TEETH_EDIT_179="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "            - \x7b name: TOKENFUSE_MCP_DLP, value: \"block\" \x7d\n", "")')"
run_case "broker-blocks-raw-secrets: TOKENFUSE_MCP_DLP goes missing" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$TEETH_EDIT_179" \
	"TOKENFUSE_MCP_DLP None, not block"

TEETH_EDIT_180="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_MCP_SCAN, value: \"block\" \x7d", "\x7b name: TOKENFUSE_MCP_SCAN, value: \"warn\" \x7d")')"
run_case "broker-blocks-raw-secrets: the tool scan only warns" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$TEETH_EDIT_180" \
	"TOKENFUSE_MCP_SCAN 'warn', not block"

TEETH_EDIT_181="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_WARDRYX_MODE, value: \"enforce\" \x7d", "\x7b name: TOKENFUSE_WARDRYX_MODE, value: \"off\" \x7d")')"
run_case "broker-blocks-raw-secrets: the broker's policy hook is off" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$TEETH_EDIT_181" \
	"TOKENFUSE_WARDRYX_MODE 'off', not enforce"

TEETH_EDIT_182="$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_WARDRYX_FAILMODE, value: \"closed\" \x7d", "\x7b name: TOKENFUSE_WARDRYX_FAILMODE, value: \"open\" \x7d")')"
run_case "broker-blocks-raw-secrets: the broker fails open" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$TEETH_EDIT_182" \
	"TOKENFUSE_WARDRYX_FAILMODE 'open', not closed"

run_case "broker-blocks-raw-secrets: the broker's policy key becomes optional" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "name: stack-keys, key: wardryx_gateway \x7d \x7d", "name: stack-keys, key: wardryx_gateway, optional: true \x7d \x7d")')" \
	"does not read TOKENFUSE_WARDRYX_KEY from stack-keys/wardryx_gateway"

run_case "broker-blocks-raw-secrets: the broker cannot reach wardryx" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "        - podSelector: \x7b matchLabels: \x7b app: wardryx \x7d \x7d\n      ports:\n        - \x7b protocol: TCP, port: 8090 \x7d", "        - podSelector: \x7b matchLabels: \x7b app: wardryx \x7d \x7d\n      ports:\n        - \x7b protocol: TCP, port: 8091 \x7d")')" \
	"no NetworkPolicy lets the broker out to wardryx"

run_case "broker-blocks-raw-secrets: the broker image cannot be pulled" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "          image: ghcr.io/taipanbox/tokenfuse:v1.25.0@sha256:3a81dbcd116557eff54aae29e7d68104af8fc788265d58e71adf3f96fea03317\n", "          image: ghcr.io/taipanbox/tokenfuse:v0.0.0-gate-no-such-tag\n")')" \
	"could not pull ghcr.io/taipanbox/tokenfuse:v0.0.0-gate-no-such-tag"

run_case "broker-blocks-raw-secrets: no broker left to judge" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'import os; os.remove("manifests/52-tokenfuse-mcp-broker.yaml")')" \
	"measured NOTHING"

run_case "broker-blocks-raw-secrets: a comment in the broker's block is reworded" pass \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "# with a log line. tokenfuse\x27s own defaults are shadow and warn", "# with a log line. tokenfuse\x27s defaults are shadow and warn")')"


run_case "teeth-shards-cover-every-case: a reworded comment is not a fault" pass \
	'./scripts/teeth-shards-cover-every-case.sh' \
	"$(py 'edit("scripts/gates-have-teeth.sh", "# Position k of this case decides its shard (see the head). A case outside", "# Position k of this case decides its shard (see the head, reworded). A case outside")')"

# ---- the provider key is held by the gateway only (CLAUDE.md invariant 53) ---------
# The gateway takes its provider key as a file it mounts; no other container holds one.
GATE53=./scripts/no-provider-key-outside-the-gateway.sh

TEETH_EDIT_183="$(py 'edit("manifests/10-planes.yaml", "            - { name: TOKENFUSE_UPSTREAM_KEY_FILE, value: \"/run/upstream/anthropic_key\" }\n", "")')"
run_case "no-provider-key: the gateway loses its key file variable" fail \
	"$GATE53" \
	"$TEETH_EDIT_183" \
	"no literal TOKENFUSE_UPSTREAM_KEY_FILE"

run_case "no-provider-key: the gateway's key Secret becomes optional" fail \
	"$GATE53" \
	"$(py 'edit("manifests/10-planes.yaml", "secret: { secretName: gateway-upstream-key, defaultMode: 0440,", "secret: { secretName: gateway-upstream-key, optional: true, defaultMode: 0440,")')" \
	"non-optional Secret gateway-upstream-key"

run_case "no-provider-key: the gateway mounts its key where its variable does not point" fail \
	"$GATE53" \
	"$(py 'edit("manifests/10-planes.yaml", "- { name: upstream, mountPath: /run/upstream, readOnly: true }", "- { name: upstream, mountPath: /run/elsewhere, readOnly: true }")')" \
	"non-optional Secret gateway-upstream-key"

TEETH_EDIT_184="$(py 'edit("manifests/20-console.yaml", "            - { name: GENARYX_WEB_REQUIRE_PASSKEY, value: \"1\" }\n", "            - { name: GENARYX_WEB_REQUIRE_PASSKEY, value: \"1\" }\n            - name: ANTHROPIC_API_KEY\n              valueFrom: { secretKeyRef: { name: gateway-upstream-key, key: anthropic_key } }\n")')"
run_case "no-provider-key: the console reads the provider key from a Secret again" fail \
	"$GATE53" \
	"$TEETH_EDIT_184" \
	"reads the provider Secret gateway-upstream-key"

TEETH_EDIT_185="$(py 'edit("manifests/20-console.yaml", "            - { name: GENARYX_WEB_REQUIRE_PASSKEY, value: \"1\" }\n", "            - { name: GENARYX_WEB_REQUIRE_PASSKEY, value: \"1\" }\n            - name: OPENAI_API_KEY\n              valueFrom: { secretKeyRef: { name: stack-keys, key: cloud_admin } }\n")')"
run_case "no-provider-key: a provider-shaped variable reads a Secret that is not a client key" fail \
	"$GATE53" \
	"$TEETH_EDIT_185" \
	"is provider-shaped and reads Secret stack-keys"

run_case "no-provider-key: a container takes costcrew-engine, and no exception covers it any more" fail \
	"$GATE53" \
	"$(py 'edit("manifests/49-costcrew.yaml", "                - name: ANTHROPIC_API_KEY\n", "                - name: COSTCREW_ENGINE_KEY\n                  valueFrom:\n                    secretKeyRef: { name: costcrew-engine, key: openrouter, optional: true }\n                - name: ANTHROPIC_API_KEY\n")')" \
	"reads the provider Secret costcrew-engine"

run_case "no-provider-key: a client key under a provider-shaped name is the agent's own credential" pass \
	"$GATE53" \
	"$(py 'edit("manifests/20-console.yaml", "            - { name: GENARYX_WEB_REQUIRE_PASSKEY, value: \"1\" }\n", "            - { name: GENARYX_WEB_REQUIRE_PASSKEY, value: \"1\" }\n            - name: ANTHROPIC_API_KEY\n              valueFrom: { secretKeyRef: { name: felyx-client-key, key: client_key, optional: true } }\n")')"

run_case "no-provider-key: a comment naming the provider variable is not a fault" pass \
	"$GATE53" \
	"$(py 'edit("manifests/10-planes.yaml", "# The provider key is HELD by the gateway and read from a file it mounts", "# The ANTHROPIC_API_KEY of the old console is HELD by the gateway and read from a file it mounts")')"

run_case "no-provider-key: no gateway left to judge" fail \
	"$GATE53" \
	"$(py 'import os; os.remove("manifests/10-planes.yaml")')" \
	"measured nothing"

# Keyryx on the cluster (wave 2, L2; CLAUDE.md invariants 55 to 57). Every case
# edits keyryx/manifests/59-keyryx.yaml, the file the three gates read.
run_case "keyryx-root-is-not-in-env: a root key read through a secretKeyRef" fail \
	'./scripts/keyryx-root-is-not-in-env.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "            - name: KEYRYX_WITNESS_EVENTS\n", "            - name: KEYRYX_LEAK\n              valueFrom: { secretKeyRef: { name: keyryx-root, key: root.key } }\n            - name: KEYRYX_WITNESS_EVENTS\n")')" \
	"a root key is read through a secretKeyRef"
run_case "keyryx-root-is-not-in-env: an environment variable named ...ROOT_KEY" fail \
	'./scripts/keyryx-root-is-not-in-env.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "            - name: KEYRYX_WITNESS_EVENTS\n", "            - name: KEYRYX_WITNESS_ROOT_KEY\n              value: /run/keyryx/root.key\n            - name: KEYRYX_WITNESS_EVENTS\n")')" \
	"would carry key material"
run_case "keyryx-root-is-not-in-env: a 64-hex-character key written into a manifest" fail \
	'./scripts/keyryx-root-is-not-in-env.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "              value: /var/lib/stack/events\n", "              value: /var/lib/stack/events\n            - name: KEYRYX_LEAK\n              value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n")')" \
	"64-hex-character literal"
run_case "keyryx-root-is-not-in-env: the custody main container mounts the root key" fail \
	'./scripts/keyryx-root-is-not-in-env.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "          args: [custody]\n", "          args: [custody]\n          volumeMounts:\n            - name: keyryx-root\n              mountPath: /in\n")')" \
	"custody main container mounts keyryx-root"
run_case "keyryx-root-is-not-in-env: the witness names the custody root key" fail \
	'./scripts/keyryx-root-is-not-in-env.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "      serviceAccountName: keyryx-witness\n", "      serviceAccountName: keyryx-witness\n      # keyryx-root\n")')" \
	"the witness Deployment names the custody root key"
run_case "keyryx-root-is-not-in-env: a comment naming ROOT_KEY in prose (must pass)" pass \
	'./scripts/keyryx-root-is-not-in-env.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "apiVersion: v1\n", "# KEYRYX_ROOT_KEY is named here in prose, and no variable carries it.\napiVersion: v1\n")')"
run_case "witness-is-separate: the witness mounts the custody root key Secret" fail \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "            secretName: keyryx-witness-root\n", "            secretName: keyryx-root\n")')" \
	"the other role's root key Secret"
run_case "witness-is-separate: the witness mounts custody's state claim" fail \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "            claimName: keyryx-witness-state\n", "            claimName: keyryx-state\n")')" \
	"the other role's state claim"
run_case "witness-is-separate: the witness runs as custody's uid" fail \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "        runAsUser: 20100\n", "        runAsUser: 20101\n")')" \
	"do not run as two different uids"
run_case "witness-is-separate: the witness event mount is writable" fail \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "              mountPath: /var/lib/stack/events\n              readOnly: true\n", "              mountPath: /var/lib/stack/events\n")')" \
	"without readOnly: true"
run_case "witness-is-separate: custody mounts the event streams" fail \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "      serviceAccountName: keyryx-custody\n", "      serviceAccountName: keyryx-custody\n      # claimName: stack-events\n")')" \
	"custody mounts the event streams"
run_case "witness-is-separate: the witness writes its alerts into the event directory" fail \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "value: /var/lib/keyryx-witness/alerts/keyryx.ndjson", "value: /var/lib/stack/events/keyryx.ndjson")')" \
	"writes its alerts into the event directory"
run_case "witness-is-separate: the witness Deployment is absent (measured nothing)" fail \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "kind: Deployment\nmetadata:\n  name: keyryx-witness\n", "kind: Pod\nmetadata:\n  name: keyryx-witness\n")')" \
	"measured NOTHING"
run_case "witness-is-separate: a comment in the manifest (must pass)" pass \
	'./scripts/witness-is-separate.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "apiVersion: v1\n", "# the witness is read only over the events, and separate in every other way\napiVersion: v1\n")')"
# invariant 75: the witness's findings reach the console and heraldyx through the witness's own claim,
# subPath alerts, read only, beside the witness, by patches with unpatches; the witness never writes the bus.
run_case "keyryx-alerts: a claim of their own is added for the findings" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'open("manifests/00-base.yaml", "a").write("---\napiVersion: v1\nkind: PersistentVolumeClaim\nmetadata:\n  name: keyryx-alerts\n  namespace: agent-stack\nspec:\n  accessModes: [\"ReadWriteMany\"]\n  storageClassName: stack-rwx\n  resources: { requests: { storage: 1Gi } }\n")')" \
	"no new volume is added"
run_case "keyryx-alerts: the witness writes its findings onto the bus" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "value: /var/lib/keyryx-witness/alerts/keyryx.ndjson", "value: /var/lib/stack/events/keyryx.ndjson")')" \
	"on the bus it witnesses"
run_case "keyryx-alerts: the findings sit at the root of the witness's claim" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "value: /var/lib/keyryx-witness/alerts/keyryx.ndjson", "value: /var/lib/keyryx-witness/keyryx.ndjson")')" \
	"at the root of keyryx-witness-state"
run_case "keyryx-alerts: the findings sit beside the witness key" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "value: /var/lib/keyryx-witness/alerts/keyryx.ndjson", "value: /var/lib/keyryx-witness/data/keyryx.ndjson")')" \
	"overlaps KEYRYX_WITNESS_DATA"
run_case "keyryx-alerts: the witness mounts the bus read-write" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "            - name: events\n              mountPath: /var/lib/stack/events\n              readOnly: true\n", "            - name: events\n              mountPath: /var/lib/stack/events\n")')" \
	"mounts stack-events read-write"
run_case "keyryx-alerts: the witness's bus volume is not read only on the claim" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "            claimName: stack-events\n            readOnly: true\n", "            claimName: stack-events\n")')" \
	"not readOnly on the claim, so a mount of it can write the bus"
run_case "keyryx-alerts: heraldyx's volume of the witness's claim is writable" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/heraldyx-findings-patch.yaml", "            claimName: keyryx-witness-state\n            readOnly: true\n", "            claimName: keyryx-witness-state\n")')" \
	"is not readOnly on the claim: the mount could write the witness's state"
run_case "keyryx-alerts: the console mounts the findings read-write" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/console-findings-patch.yaml", "              subPath: alerts\n              readOnly: true\n", "              subPath: alerts\n")')" \
	"mounts keyryx-witness-state read-write at"
run_case "keyryx-alerts: heraldyx mounts the whole witness claim" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/heraldyx-findings-patch.yaml", "              subPath: alerts\n", "")')" \
	"with subPath (none), not alerts"
run_case "keyryx-alerts: the console mounts the witness key directory" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/console-findings-patch.yaml", "              subPath: alerts\n", "              subPath: data\n")')" \
	"with subPath data, not alerts"
run_case "keyryx-alerts: heraldyx is not placed beside the witness" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/heraldyx-findings-patch.yaml", "              topologyKey: kubernetes.io/hostname\n", "              topologyKey: topology.kubernetes.io/zone\n")')" \
	"is not pod-affined (required, by hostname)"
run_case "keyryx-alerts: heraldyx is not told to read the findings" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/heraldyx-findings-patch.yaml", "value: \"/var/lib/stack/events,/var/lib/keyryx-findings/keyryx.ndjson\"", "value: \"/var/lib/stack/events\"")')" \
	"heraldyx does not read the witness's findings"
run_case "keyryx-alerts: the console is handed the findings directory beside the file" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/console-findings-patch.yaml", "value: \"/var/lib/keyryx-findings/keyryx.ndjson\"", "value: \"/var/lib/keyryx-findings,/var/lib/keyryx-findings/keyryx.ndjson\"")')" \
	"under the findings mount, beside the file"
run_case "keyryx-alerts: heraldyx is handed the findings directory behind a double slash" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/heraldyx-findings-patch.yaml", "value: \"/var/lib/stack/events,/var/lib/keyryx-findings/keyryx.ndjson\"", "value: \"/var/lib/stack/events,//var/lib/keyryx-findings,/var/lib/keyryx-findings/keyryx.ndjson\"")')" \
	"under the findings mount, beside the file"
run_case "keyryx-alerts: only an init container of heraldyx is in the bus group" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "supplementalGroups: [10001]", "supplementalGroups: [65532]"); edit("manifests/45-heraldyx.yaml", "runAsUser: 65532, runAsGroup: 65532, allowPrivilegeEscalation", "runAsUser: 65532, runAsGroup: 10001, allowPrivilegeEscalation")')" \
	"container heraldyx is not in the bus group"
run_case "keyryx-alerts: heraldyx's unpatch leaves the witness's claim mounted" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/heraldyx-findings-unpatch.yaml", "      volumes:\n        - name: keyryx-findings\n          $patch: delete\n", "")')" \
	"does not delete the volume keyryx-findings"
run_case "keyryx-alerts: an unpatch deletes a mount by name" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/wardryx-unpatch.yaml", "            - mountPath: /run/keyryx-client\n", "            - name: keyryx-client\n")')" \
	"deletes a volumeMount by name"
run_case "keyryx-alerts: a refused unpatch is swallowed by the opt-out" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "    || die \"could not remove the Keyryx wiring from $kind $name", "    || true # \"could not remove the Keyryx wiring from $kind $name")')" \
	"keyryx_unpatch can fail and still let the opt-out report"
run_case "keyryx-patches-round-trip: an unpatch deletes a mount by name" fail \
	'./scripts/keyryx-patches-round-trip.sh' \
	"$(py 'edit("keyryx/console-findings-unpatch.yaml", "            - mountPath: /var/lib/keyryx-findings\n", "            - name: keyryx-findings\n")')" \
	"does not contain declared merge key: mountPath"
run_case "keyryx-patches-round-trip: an unpatch leaves the setting behind" fail \
	'./scripts/keyryx-patches-round-trip.sh' \
	"$(py 'edit("keyryx/console-findings-unpatch.yaml", "            - name: GENARYX_EVENTS_EXTRA\n              $patch: delete\n", "")')" \
	"does not take Deployment genaryx-console back"
run_case "keyryx-patches-round-trip: the record seal keeps its credential mount" fail \
	'./scripts/keyryx-patches-round-trip.sh' \
	"$(py 'edit("keyryx/record-seal-unpatch.yaml", "                - mountPath: /run/keyryx-client\n                  $patch: delete\n", "")')" \
	"does not take CronJob record-seal back"
run_case "keyryx-patches-round-trip: a patch is gone (measured nothing)" fail \
	'./scripts/keyryx-patches-round-trip.sh' \
	"$(py 'import os; os.remove("keyryx/heraldyx-findings-patch.yaml")')" \
	"measured NOTHING"
run_case "keyryx-patches-round-trip: a comment in an unpatch (must pass)" pass \
	'./scripts/keyryx-patches-round-trip.sh' \
	"$(py 'edit("keyryx/heraldyx-findings-unpatch.yaml", "# Reverses keyryx/heraldyx-findings-patch.yaml", "# Undoes keyryx/heraldyx-findings-patch.yaml")')"
run_case "keyryx-alerts: heraldyx's unpatch does not put its setting back" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/heraldyx-findings-unpatch.yaml", "              value: \"/var/lib/stack/events\"\n", "              $patch: delete\n")')" \
	"puts HERALDYX_EVENTS back to None"
run_case "keyryx-alerts: the console's unpatch keeps it beside the witness" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/console-findings-unpatch.yaml", "        podAffinity: null\n", "")')" \
	"does not set podAffinity to null"
run_case "keyryx-alerts: the install never patches heraldyx" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "  keyryx_patch_reader heraldyx heraldyx-findings-patch.yaml\n", "")')" \
	"keyryx_install_settle does not patch heraldyx"
run_case "keyryx-alerts: the opt-out never unpatches the console" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "  keyryx_unpatch_reader genaryx-console console-findings-unpatch.yaml\n", "")')" \
	"keyryx_remove_settle does not unpatch genaryx-console"
run_case "keyryx-alerts: the opt-out leaves the record-seal patched" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "  keyryx_unpatch cronjob record-seal record-seal-unpatch.yaml\n", "")')" \
	"keyryx_remove_settle does not reverse cronjob record-seal"
run_case "keyryx-alerts: keyryx/down.sh deletes the witness with its readers and the record-seal still bound to it" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/down.sh", "\nkeyryx_remove_settle\n", "\n")')" \
	"keyryx/down.sh does not run keyryx_remove_settle"
run_case "keyryx-alerts: keyryx/down.sh deletes before it unpatches" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/down.sh", "\nkeyryx_remove_settle\n", "\n"); open("keyryx/down.sh", "a").write("keyryx_remove_settle\n")')" \
	"runs keyryx_remove_settle after its first delete"
run_case "keyryx-alerts: the GCP deploy applies heraldyx and never its findings patch" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "    keyryx_patch_reader heraldyx heraldyx-findings-patch.yaml\n", "")')" \
	"cloud/gcp/deploy-gcp.sh: heraldyx is applied"
run_case "keyryx-alerts: a default manifest mounts the witness's claim" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("manifests/20-console.yaml", "          persistentVolumeClaim: { claimName: stack-events }\n", "          persistentVolumeClaim: { claimName: stack-events }\n        - name: witness-findings\n          persistentVolumeClaim: { claimName: keyryx-witness-state, readOnly: true }\n")')" \
	"manifests/20-console.yaml mounts keyryx-witness-state"
run_case "keyryx-alerts: heraldyx's patch is gone (measured nothing)" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/heraldyx-findings-patch.yaml", "  name: heraldyx\n  namespace: agent-stack\n", "  name: heraldyx-moved\n  namespace: agent-stack\n")')" \
	"measured NOTHING"
run_case "keyryx-alerts: a comment beside heraldyx's patch (must pass)" pass \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/heraldyx-findings-patch.yaml", "# heraldyx reads the Keyryx witness'"'"'s findings", "# heraldyx reads the findings of the Keyryx witness")')"
# invariant 75, the gate's own subjects: a keyryx/*-patch.yaml whose target the gate cannot read fails
# loudly, and keyryx_unpatch_reader counts only for a Deployment (the kind is never optional).
run_case "keyryx-alerts: a patch that names no kind" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/record-seal-patch.yaml", "apiVersion: batch/v1\nkind: CronJob\n", "apiVersion: batch/v1\n")')" \
	"keyryx/record-seal-patch.yaml: this gate cannot read which object the patch targets"
run_case "keyryx-alerts: a fifth patch, its name indented four spaces, is never reversed" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'import subprocess
open("keyryx/costcrew-patch.yaml", "w").write("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n    name: costcrew\n    namespace: agent-stack\nspec: {}\n")
subprocess.run(["git", "add", "keyryx/costcrew-patch.yaml"], check=True)')" \
	"keyryx_remove_settle does not reverse deployment costcrew with costcrew-unpatch.yaml"
run_case "keyryx-alerts: a CronJob patch reversed as a Deployment reader" fail \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'import subprocess
open("keyryx/costcrew-crew-patch.yaml", "w").write("apiVersion: batch/v1\nkind: CronJob\nmetadata:\n  name: costcrew-crew\n  namespace: agent-stack\nspec: {}\n")
subprocess.run(["git", "add", "keyryx/costcrew-crew-patch.yaml"], check=True)
edit("lib/keyryx-install.sh", "  keyryx_unpatch_reader heraldyx heraldyx-findings-unpatch.yaml\n", "  keyryx_unpatch_reader heraldyx heraldyx-findings-unpatch.yaml\n  keyryx_unpatch_reader costcrew-crew costcrew-crew-unpatch.yaml\n")')" \
	"keyryx_remove_settle does not reverse cronjob costcrew-crew with costcrew-crew-unpatch.yaml"
run_case "keyryx-alerts: a patch with its name indented four spaces (must pass)" pass \
	'./scripts/keyryx-alerts-reach-readers.sh' \
	"$(py 'edit("keyryx/record-seal-patch.yaml", "metadata:\n  name: record-seal\n  namespace: agent-stack\n", "metadata:\n    name: record-seal\n    namespace: agent-stack\n")')"
# invariant 76: turning Keyryx off leaves no record-seal Job bound to the witness, and a read it
# cannot make stops it. The gate runs keyryx/down.sh and the library against a stand-in kubectl.
run_case "keyryx-off: the opt-out never releases the record-seal Jobs" fail \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "  keyryx_release_seal\n", "")')" \
	"the Job is not deleted, so its pod stays Pending"
run_case "keyryx-off: the release runs before the record-seal is unpatched" fail \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "  keyryx_unpatch cronjob record-seal record-seal-unpatch.yaml\n  keyryx_release_seal\n", "  keyryx_release_seal\n  keyryx_unpatch cronjob record-seal record-seal-unpatch.yaml\n")')" \
	"before the record-seal CronJob is unpatched"
run_case "keyryx-off: the release never checks what the delete left" fail \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "  [ -z \"$left\" ] || die \"a record-seal Job or pod", "  true || die \"a record-seal Job or pod")')" \
	"exited 0 with a record-seal Job still bound to the witness"
run_case "keyryx-off: a running seal is deleted instead of let finish" fail \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "deadline=$((SECONDS + ${KEYRYX_SEAL_WAIT:-300}))", "deadline=$SECONDS")')" \
	"a seal that was running is deleted instead of let finish"
run_case "keyryx-off: a seal is deleted without waiting for its pods" fail \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "delete job $job --cascade=foreground --wait=true", "delete job $job --wait=false")')" \
	"without waiting for its pods"
run_case "keyryx-off: down.sh swallows a failed read of a Deployment" fail \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'edit("keyryx/down.sh", "    || die \"could not read deployment $dep to wait for its rollout off Keyryx\"", "    || true")')" \
	"down.sh exited 0 although it could not read deployment genaryx-console"
run_case "keyryx-off: a failed read of a reader reads as not installed" fail \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "    || die \"could not read deployment $dep to patch it", "    || true # could not read deployment $dep to patch it")')" \
	"reading a failed read as"
run_case "keyryx-off: the opt-out says custody and the witness stay" fail \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "Custody, the witness and every key are left as they are by this step.", "Custody and the witness stay until removed by hand.")')" \
	"says custody or the witness stays"
run_case "keyryx-off: the release takes any CronJob's Job for a seal" fail \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "    if o.get(\"kind\") == \"Job\" and \"record-seal\" in owners(o, \"CronJob\"):", "    if o.get(\"kind\") == \"Job\":")')" \
	"a Job another CronJob owns is deleted as a record seal"
run_case "keyryx-off: the release sees the affinity only, not the signer" fail \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "if done or not (affined(spec) or signs(spec)):", "if done or not affined(spec):")')" \
	"a seal that signs through custody, which down.sh deletes, is left running unfinished"
run_case "keyryx-off: the library is absent (measured nothing)" fail \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'import os; os.remove("lib/keyryx-install.sh")')" \
	"measured NOTHING"
run_case "keyryx-off: a comment in down.sh (must pass)" pass \
	'./scripts/keyryx-off-leaves-nothing-bound.sh' \
	"$(py 'edit("keyryx/down.sh", "# Keeps every key and every claim", "# Keeps each key and each claim")')"
run_case "bus-names: the witness's findings file loses its keyryx stem" fail \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "value: /var/lib/keyryx-witness/alerts/keyryx.ndjson", "value: /var/lib/keyryx-witness/alerts/alerts.ndjson")')" \
	"is named for no source heraldyx reads from it"
run_case "bus-names: the heraldyx pin goes back before the findings are read safely" fail \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "ghcr.io/taipanbox/heraldyx:v0.9.1@", "ghcr.io/taipanbox/heraldyx:v0.8.0@")')" \
	"older than v0.8.1"
run_case "stream-files-are-precreated: the witness's findings file is not made before it starts" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "        - name: precreate-streams\n", "        - name: make-findings-later\n")')" \
	"keyryx-witness -> /var/lib/keyryx-witness/alerts/keyryx.ndjson: no precreate-streams init container"
run_case "stream-files-are-precreated: the witness's init mounts its claim and never makes alerts/" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "umask 027 && mkdir -p /var/lib/keyryx-witness/alerts && chmod 0750 /var/lib/keyryx-witness/alerts && ", "umask 027 && ")')" \
	"nor an ancestor of it with a mkdir -p"
TEETH_EDIT_186="$(py 'edit("keyryx/manifests/59-keyryx.yaml", "        - podSelector:\n            matchLabels: { keyryx-consumer: \"true\" }\n", "        - {}\n")')"
run_case "keyryx-reaches-only-consumers: custody admits every pod" fail \
	'./scripts/keyryx-reaches-only-consumers.sh' \
	"$TEETH_EDIT_186" \
	"admits every pod"
run_case "keyryx-reaches-only-consumers: custody declares an egress rule" fail \
	'./scripts/keyryx-reaches-only-consumers.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "  egress: []\n", "  egress:\n    - to: [{ ipBlock: { cidr: 0.0.0.0/0 } }]\n")')" \
	"has egress rules"
TEETH_EDIT_187="$(py 'edit("keyryx/manifests/59-keyryx.yaml", "      labels: { app: keyryx-custody, app.kubernetes.io/part-of: agent-stack }\n", "      labels: { app: keyryx-custody, keyryx-consumer: \"true\", app.kubernetes.io/part-of: agent-stack }\n")')"
run_case "keyryx-reaches-only-consumers: a Keyryx workload carries the consumer label" fail \
	'./scripts/keyryx-reaches-only-consumers.sh' \
	"$TEETH_EDIT_187" \
	"carries the keyryx-consumer label"
run_case "keyryx-reaches-only-consumers: the policy taken away (measured nothing)" fail \
	'./scripts/keyryx-reaches-only-consumers.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "kind: NetworkPolicy\nmetadata:\n  name: keyryx-witness-ingress\n", "kind: Service\nmetadata:\n  name: keyryx-witness-ingress\n")')" \
	"measured NOTHING"
run_case "keyryx-reaches-only-consumers: a comment naming the label (must pass)" pass \
	'./scripts/keyryx-reaches-only-consumers.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "apiVersion: v1\n", "# keyryx-consumer is a label on consumers, set by keyryx/wardryx-patch.yaml.\napiVersion: v1\n")')"

# Verified images (invariant 58, policy/ and scripts/verified-images-are-enforced.sh). Every case
# edits one tracked file the gate reads; the gate's own baseline must be green first.
run_case "verified-images: a TAIPANBOX image carries a tag only" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("manifests/20-console.yaml", "image: ghcr.io/taipanbox/genaryx-console:v1.8.8@sha256:55765e22aeb5a157099b30a9ecbda53b83121c17b3b98b6896af5733ba16f9a5", "image: ghcr.io/taipanbox/genaryx-console:v1.1.48")')" \
	"image not pinned by digest"
run_case "verified-images: an upstream image nobody allowed" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("manifests/15-policy-store.yaml", "image: postgres:16-alpine@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea", "image: alpine:3.20@sha256:721873c34ceb9f8d8fc265984940dc982404c105f19ad51be9fdc5970a6080ea")')" \
	"neither a TAIPANBOX image nor on the static allow list"
run_case "verified-images: the keyless policy turns to warn" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/image-policy.yaml", "  mode: enforce\n", "  mode: warn\n")')" \
	"mode is not enforce"
run_case "verified-images: the subject expression accepts any repository" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/image-policy.yaml", "subjectRegExp: '"'"'", "subjectRegExp: '"'"'.*|")')" \
	"accepts the identity of another repository"
run_case "verified-images: the subject expression accepts a fork's release" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/image-policy.yaml", "TAIPANBOX/tokenfuse/", "[A-Za-z0-9._-]+/tokenfuse/")')" \
	"accepts a fork's release"
run_case "verified-images: the issuer is widened" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/image-policy.yaml", "issuer: https://token.actions.githubusercontent.com", "issuer: https://accounts.google.com")')" \
	"issuer is not https://token.actions.githubusercontent.com"
run_case "verified-images: a static allow has no reason" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/image-policy.yaml", "# reason: the policy-db (postgres)", "# note: the policy-db (postgres)")')" \
	"without a reason line above it"
run_case "verified-images: up.sh opts the namespace in before the webhook answers" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/up.sh", "$KUBECTL -n cosign-system rollout status deployment/webhook --timeout=300s\n", "")')" \
	"does not wait for the webhook"
run_case "verified-images: up.sh no longer opts agent-stack in" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/up.sh", "$KUBECTL label namespace agent-stack policy.sigstore.dev/include=true --overwrite\n", "")')" \
	"does not label agent-stack"
run_case "verified-images: the controller changes without a new pin" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/policy-controller.yaml", "  no-match-policy: deny\n", "  no-match-policy: deny\n  # edited\n")')" \
	"not the rendered release pinned in policy/PIN"
run_case "verified-images: the controller names an unrendered ko reference" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/policy-controller.yaml", "image: ghcr.io/sigstore/policy-controller/policy-controller:v0.15.1@sha256:0492bb264fb1d9bdc8e3f343ef542cc85b7dd7c7fd8d9524b453c2bd31a1d128", "image: ko://github.com/sigstore/policy-controller/cmd/webhook")')" \
	"unrendered ko:// image"
run_case "verified-images: the controller runs an image that is not pinned by digest" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/policy-controller.yaml", "image: ghcr.io/sigstore/policy-controller/policy-controller:v0.15.1@sha256:0492bb264fb1d9bdc8e3f343ef542cc85b7dd7c7fd8d9524b453c2bd31a1d128", "image: ghcr.io/sigstore/policy-controller/policy-controller:v0.15.1")')" \
	"the controller image is not pinned by digest"
run_case "verified-images: the default apply set names policy" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("manifests/kustomization.yaml", "resources:\n", "resources:\n  - ../policy/policy-controller.yaml\n")')" \
	"names policy/"
run_case "verified-images: the keyless policy is absent (measured nothing)" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/image-policy.yaml", "kind: ClusterImagePolicy\nmetadata:\n  name: taipanbox-tokenfuse\n", "kind: ConfigMap\nmetadata:\n  name: taipanbox-tokenfuse\n")')" \
	"measured NOTHING"
run_case "verified-images: a comment naming an unpinned image (must pass)" pass \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/up.sh", "$KUBECTL get namespace agent-stack >/dev/null\n", "$KUBECTL get namespace agent-stack >/dev/null\n# image: ghcr.io/taipanbox/wardryx:v2.2.1 is named here in prose, not as a reference\n")')"
# One policy per repository (invariant 58). The first version named one identity for every image, so a
# signature by one repository's workflow admitted another repository's image name.
run_case "verified-images: a policy admits another repository's identity" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/image-policy.yaml", "TAIPANBOX/wardryx/", "TAIPANBOX/(?:wardryx|tokenfuse)/")')" \
	"accepts the identity of another repository"
run_case "verified-images: a policy's subject accepts a branch as well as a version tag" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/image-policy.yaml", "@refs/tags/v[0-9][A-Za-z0-9._+-]*$", "@refs/(?:tags/v[0-9]|heads/main)[A-Za-z0-9._+-]*$")')" \
	"accepts a branch of tokenfuse"
run_case "verified-images: a glob wider than one repository's image name" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/image-policy.yaml", "ghcr.io/taipanbox/wardryx@sha256:*", "ghcr.io/taipanbox/**")')" \
	"not a digest-anchored name of one repository"
# A cross-signed image: wardryx's image admitted on the signature of tokenfuse's release workflow. The
# policy must name its own repository's signer, so the gate refuses the policy that names another one.
run_case "verified-images: wardryx's image admitted on tokenfuse's signer (cross-signed)" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 's = open("policy/image-policy.yaml").read(); i = s.index("name: taipanbox-wardryx"); j = s.index("TAIPANBOX/wardryx/", i); open("policy/image-policy.yaml", "w").write(s[:j] + "TAIPANBOX/tokenfuse/" + s[j + len("TAIPANBOX/wardryx/"):])')" \
	"is not the identity of wardryx"
# A moved glob: wardryx's policy re-pointed at idryx's image name. Two policies then cover one name, and
# wardryx's name is covered by none, so the gate refuses the move rather than admitting on the wrong signer.
run_case "verified-images: a policy's glob moved onto another repository's image name" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 's = open("policy/image-policy.yaml").read(); i = s.index("name: taipanbox-wardryx"); j = s.index("ghcr.io/taipanbox/wardryx@sha256:*", i); open("policy/image-policy.yaml", "w").write(s[:j] + "ghcr.io/taipanbox/idryx@sha256:*" + s[j + len("ghcr.io/taipanbox/wardryx@sha256:*"):])')" \
	"covered by two policies"
run_case "verified-images: a manifest names a TAIPANBOX image with no signer row" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "image: ghcr.io/taipanbox/wardryx:v2.7.0@sha256:", "image: ghcr.io/taipanbox/wardryx-new:v2.5.0@sha256:")')" \
	"has no signer row in BINDINGS"
run_case "verified-images: the default install stops turning admission on" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("deploy.sh", "bash policy/up.sh --enforce'"'"'", "bash policy/up.sh'"'"'")')" \
	"does not turn admission on for agent-stack"
TEETH_EDIT_188="$(py 'edit("policy/operator-image-policy.example.yaml", "# (end of the template: operators add entries above this line)", "apiVersion: policy.sigstore.dev/v1beta1\nkind: ClusterImagePolicy\nmetadata:\n  name: operator-open\nspec:\n  images:\n    - glob: \"*@sha256:*\"\n  authorities:\n    - keyless:\n        url: https://fulcio.sigstore.dev\n        identities:\n          - issuer: https://token.actions.githubusercontent.com\n            subjectRegExp: \".*\"\n# (end of the template: operators add entries above this line)")')"
run_case "verified-images: an operator entry admits every image (a wildcard name)" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$TEETH_EDIT_188" \
	"is a wildcard name"

TEETH_EDIT_189="$(py 'edit("policy/operator-image-policy.example.yaml", "# (end of the template: operators add entries above this line)", "apiVersion: policy.sigstore.dev/v1beta1\nkind: ClusterImagePolicy\nmetadata:\n  name: operator-x\nspec:\n  images:\n    - glob: \"ghcr.io/acme/*@sha256:*\"\n  authorities:\n    - static:\n        action: pass\n# (end of the template: operators add entries above this line)")')"
run_case "verified-images: an operator entry names a wildcard repository" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$TEETH_EDIT_189" \
	"is a wildcard name"

TEETH_EDIT_190="$(py 'edit("policy/operator-image-policy.example.yaml", "# (end of the template: operators add entries above this line)", "apiVersion: policy.sigstore.dev/v1beta1\nkind: ClusterImagePolicy\nmetadata:\n  name: operator-x\nspec:\n  images:\n    - glob: \"ghcr.io/acme/agent:1.0\"\n  authorities:\n    - static:\n        action: pass\n# (end of the template: operators add entries above this line)")')"
run_case "verified-images: an operator entry names no digest" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$TEETH_EDIT_190" \
	"is not digest-pinned"

TEETH_EDIT_191="$(py 'edit("policy/operator-image-policy.example.yaml", "# (end of the template: operators add entries above this line)", "apiVersion: policy.sigstore.dev/v1beta1\nkind: ClusterImagePolicy\nmetadata:\n  name: operator-x\nspec:\n  images:\n    - glob: \"ghcr.io/acme/agent@sha256:*\"\n  authorities:\n    - static:\n        action: pass\n# (end of the template: operators add entries above this line)")')"
run_case "verified-images: an operator static entry with a digest wildcard" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$TEETH_EDIT_191" \
	"a static allow needs one exact digest"

TEETH_EDIT_192="$(py 'edit("policy/operator-image-policy.example.yaml", "# (end of the template: operators add entries above this line)", "apiVersion: policy.sigstore.dev/v1beta1\nkind: ClusterImagePolicy\nmetadata:\n  name: operator-x\nspec:\n  images:\n    - glob: \"ghcr.io/acme/agent@sha256:*\"\n  authorities:\n    - keyless:\n        url: https://fulcio.sigstore.dev\n        identities:\n          - issuer: https://token.actions.githubusercontent.com\n            subjectRegExp: \"^https://github[.]com/[^/]+/[^/]+/[.]github/workflows/release[.]yml@refs/tags/v.*$\"\n# (end of the template: operators add entries above this line)")')"
run_case "verified-images: an operator keyless entry accepts any repository" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$TEETH_EDIT_192" \
	"accepts the probe identity"

TEETH_EDIT_193="$(py 'edit("policy/operator-image-policy.example.yaml", "# (end of the template: operators add entries above this line)", "apiVersion: policy.sigstore.dev/v1beta1\nkind: ClusterImagePolicy\nmetadata:\n  name: operator-x\nspec:\n  images:\n    - glob: \"ghcr.io/taipanbox/mockryx@sha256:*\"\n  authorities:\n    - static:\n        action: pass\n# (end of the template: operators add entries above this line)")')"
run_case "verified-images: an operator entry covers a TAIPANBOX image" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$TEETH_EDIT_193" \
	"covers a TAIPANBOX image"

TEETH_EDIT_194="$(py 'edit("policy/operator-image-policy.example.yaml", "# (end of the template: operators add entries above this line)", "apiVersion: policy.sigstore.dev/v1beta1\nkind: ClusterImagePolicy\nmetadata:\n  name: operator-x\nspec:\n  mode: warn\n  images:\n    - glob: \"ghcr.io/acme/agent@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n  authorities:\n    - static:\n        action: pass\n# (end of the template: operators add entries above this line)")')"
run_case "verified-images: an operator entry in warn mode" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$TEETH_EDIT_194" \
	"mode is not enforce"

TEETH_EDIT_195="$(py 'edit("policy/operator-image-policy.example.yaml", "# (end of the template: operators add entries above this line)", "apiVersion: policy.sigstore.dev/v1beta1\nkind: ClusterImagePolicy\nmetadata:\n  name: operator-x\nspec:\n  images:\n    - glob: \"ghcr.io/acme/agent@sha256:*\"\n  authorities:\n    - key:\n        data: |\n          -----BEGIN " + "PRIVATE KEY-----\n          -----END " + "PRIVATE KEY-----\n# (end of the template: operators add entries above this line)")')"
run_case "verified-images: a private key in the operator entries" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$TEETH_EDIT_195" \
	"private key material"

run_case "verified-images: an operator static entry pinned by digest (must pass)" pass \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/operator-image-policy.example.yaml", "# (end of the template: operators add entries above this line)", "apiVersion: policy.sigstore.dev/v1beta1\nkind: ClusterImagePolicy\nmetadata:\n  name: operator-agent-static\nspec:\n  mode: enforce\n  images:\n    - glob: \"registry.example.com/acme/agent@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n  authorities:\n    - static:\n        action: pass\n# (end of the template: operators add entries above this line)")')"

run_case "verified-images: an operator keyless entry naming its repository (must pass)" pass \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/operator-image-policy.example.yaml", "# (end of the template: operators add entries above this line)", "apiVersion: policy.sigstore.dev/v1beta1\nkind: ClusterImagePolicy\nmetadata:\n  name: operator-agent-keyless\nspec:\n  mode: enforce\n  images:\n    - glob: \"registry.example.com/acme/agent@sha256:*\"\n  authorities:\n    - keyless:\n        url: https://fulcio.sigstore.dev\n        identities:\n          - issuer: https://token.actions.githubusercontent.com\n            subjectRegExp: \"^https://github[.]com/acme/agent/[.]github/workflows/release[.]yml@refs/tags/v[0-9][A-Za-z0-9._+-]*$\"\n# (end of the template: operators add entries above this line)")')"

run_case "verified-images: the operator's copy is not ignored" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit(".gitignore", "policy/operator-image-policy.yaml\n", "")')" \
	"does not ignore policy/operator-image-policy.yaml"

run_case "verified-images: up.sh no longer applies the operator copy" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/up.sh", "  $KUBECTL apply -f policy/operator-image-policy.yaml\n", "")')" \
	"does not apply the operator's copy"
run_case "verified-images: a reason reworded (must pass)" pass \
	'./scripts/verified-images-are-enforced.sh' \
	"$(py 'edit("policy/image-policy.yaml", "# reason: the policy-db (postgres), an upstream image", "# reason: the policy store (postgres), an upstream image")')"

# Keyryx is installed by default in every launcher, with --without-keyryx as the weaker opt-out (CLAUDE.md invariant 69).
run_case "keyryx: Keyryx is off by default in deploy.sh" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("deploy.sh", "KEYRYX_INSTALL=\"$\x7bKEYRYX_INSTALL:-1\x7d\"", "KEYRYX_INSTALL=\"$\x7bKEYRYX_INSTALL:-0\x7d\"")')" \
	"deploy.sh does not default KEYRYX_INSTALL to 1"
run_case "keyryx: the opt-out flag is not parsed by the GCP launcher" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "    --without-keyryx)     KEYRYX_INSTALL=0; shift ;;\n", "")')" \
	"does not parse --without-keyryx"
run_case "keyryx: the install runs before the apply in deploy.sh" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("deploy.sh", ". \"$ROOT/lib/keyryx-install.sh\" || die \"no lib/keyryx-install.sh in $ROOT\"\n", ". \"$ROOT/lib/keyryx-install.sh\" || die \"no lib/keyryx-install.sh in $ROOT\"\nkeyryx_install_settle\n")')" \
	"installs Keyryx before its last apply -k"
run_case "keyryx: the record-seal stops signing through keyryx" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("keyryx/record-seal-patch.yaml", "value: keyryx\n", "value: keyrx\n")')" \
	"does not set TRAILRYX_SIGNER=keyryx"
run_case "keyryx: the record-seal pod is not labelled a consumer" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("keyryx/record-seal-patch.yaml", "keyryx-consumer: \"true\"", "keyryx-consumer: \"false\"")')" \
	"does not label the pod keyryx-consumer"
run_case "keyryx: the record-seal is not pointed at its attestation directory" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("keyryx/record-seal-patch.yaml", "                - name: TRAILRYX_WITNESS_ATTESTATIONS\n                  value: /var/lib/stack/attestations\n", "")')" \
	"does not point TRAILRYX_WITNESS_ATTESTATIONS at its attestations directory"
run_case "keyryx: the custody policy grants trailryx nothing" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("keyryx/policy.json.tmpl", "\"grants\": \x7b\"trailryx-root\": [\"sign\"]\x7d", "\"grants\": \x7b\x7d")')" \
	"does not grant trailryx-node the sign operation"
run_case "keyryx: the wardryx patch rolls wardryx back to v2.3.0" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("keyryx/wardryx-patch.yaml", "ghcr.io/taipanbox/wardryx:v2.7.0@sha256:91dccc66ba00adefc2e1930423a172d5c17a8c4531fac97e8fab32acdef77940", "ghcr.io/taipanbox/wardryx:v2.3.0@sha256:eaa8cff9fe3722f7040e9f9b3aac2f57c5e66afb7a012a0eda1a62e63b647543")')" \
	"would roll wardryx back"
run_case "keyryx: the witness is pointed at no stream directory" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "KEYRYX_WITNESS_EVENTS", "KEYRYX_WITNESS_EVENTSX")')" \
	"does not point the witness at the shared stream directory"
run_case "keyryx: the opt-out never removes the signers" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("deploy.sh", "  keyryx_remove_settle\n", "  true\n")')" \
	"never calls keyryx_remove_settle"
run_case "keyryx: the library stops pinning the record seal" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "keyryx_pin_trailryx_kid() {", "keyryx_pin_trailryx_kidX() {")')" \
	"does not pin the record seal"
run_case "keyryx: the library sets the attestation variable" fail \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "  keyryx_patch_record_seal\n  keyryx_patch_reader genaryx-console", "  keyryx_patch_record_seal\n  export TRAILRYX_WITNESS_ATTESTATIONS=/x\n  keyryx_patch_reader genaryx-console")')" \
	"belongs to the record-seal patch"
run_case "keyryx: a comment reworded in the library (must pass)" pass \
	'./scripts/keyryx-is-default.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "# Keyryx, installed by default:", "# Keyryx, on by default:")')"

# The record seal is pinned to custody's one ES384 key, kept on a re-run and re-pinned only on a named rotation (CLAUDE.md invariant 73).
run_case "keyryx-kid: the custody policy keeps trailryx-root on ES256" fail \
	'./scripts/keyryx-kid-is-pinned.sh' \
	"$(py 'edit("keyryx/policy.json.tmpl", "\"alg\": \"ES384\"", "\"alg\": \"ES256\"")')" \
	"does not declare trailryx-root as ES384"
run_case "keyryx-kid: the pin is taken after the record seal is patched" fail \
	'./scripts/keyryx-kid-is-pinned.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "  keyryx_pin_trailryx_kid\n  keyryx_patch_record_seal\n", "  keyryx_patch_record_seal\n  keyryx_pin_trailryx_kid\n")')" \
	"patches the record seal before it pins the kid"
run_case "keyryx-kid: the record seal reads the kid as a literal" fail \
	'./scripts/keyryx-kid-is-pinned.sh' \
	"$(py 'edit("keyryx/record-seal-patch.yaml", "valueFrom: { configMapKeyRef: { name: stack-wiring, key: TRAILRYX_KEYRYX_KID, optional: false } }", "value: KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK")')" \
	"does not read TRAILRYX_KEYRYX_KID from the stack-wiring ConfigMap"
run_case "keyryx-kid: the pin is made optional" fail \
	'./scripts/keyryx-kid-is-pinned.sh' \
	"$(py 'edit("keyryx/record-seal-patch.yaml", "optional: false", "optional: true")')" \
	"does not read TRAILRYX_KEYRYX_KID from the stack-wiring ConfigMap"
run_case "keyryx-kid: a re-run re-pins instead of keeping the pin" fail \
	'./scripts/keyryx-kid-is-pinned.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "  elif [ -n \"$current\" ]; then", "  elif false; then")')" \
	"keeps the pin on a re-run when it is still in the set"
run_case "keyryx-kid: the key set's coordinates are printed" fail \
	'./scripts/keyryx-kid-is-pinned.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "  local current jwks es384 n kid\n", "  local current jwks es384 n kid\n  keyryx_probe_jwks trailryx-root >&2\n")')" \
	"carries a coordinate of the key"
run_case "keyryx-kid: the probe pod loses its consumer label" fail \
	'./scripts/keyryx-kid-is-pinned.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "keyryx-consumer: \"true\", app", "keyryx-consumer: \"false\", app")')" \
	"the probe pod does not carry"
run_case "keyryx-kid: a comment reworded in the library (must pass)" pass \
	'./scripts/keyryx-kid-is-pinned.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "# keyryx_probe_jwks NAME: prints custody", "# keyryx_probe_jwks NAME: prints the custody")')"

# The Keyryx images and the record seal's trailryx-node are the release pins, by tag and digest (CLAUDE.md invariant 72).
run_case "keyryx-release-pins: the witness is left on keyryx v0.1.3" fail \
	'./scripts/keyryx-release-pins.sh' \
	"$(py 'p = "keyryx/manifests/59-keyryx.yaml"; s = open(p).read(); i = s.rindex("keyryx:v0.1.5@sha256:967d"); open(p, "w").write(s[:i] + "keyryx:v0.1.3@sha256:967d" + s[i + len("keyryx:v0.1.5@sha256:967d"):])')" \
	"is not the release pin"
run_case "keyryx-release-pins: the record seal is left on trailryx-node v1.4.0" fail \
	'./scripts/keyryx-release-pins.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "trailryx-node:v1.5.0@sha256:f152", "trailryx-node:v1.4.0@sha256:f152")')" \
	"is not the release pin"
run_case "keyryx-release-pins: one keyryx digest is not the tag's" fail \
	'./scripts/keyryx-release-pins.sh' \
	"$(py 'p = "keyryx/manifests/59-keyryx.yaml"; s = open(p).read(); s = s.replace("967dd49907d48ede", "967dd49907d48edf", 1); open(p, "w").write(s)')" \
	"is not the release pin"
run_case "keyryx-release-pins: the record seal's image is absent (measured nothing)" fail \
	'./scripts/keyryx-release-pins.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "image: ghcr.io/taipanbox/trailryx-node:", "image: ghcr.io/taipanbox/trailryx-nodx:")')" \
	"measured NOTHING"
run_case "keyryx-release-pins: a comment reworded in the Keyryx manifest (must pass)" pass \
	'./scripts/keyryx-release-pins.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "# Images: keyryx v0.1.0, pinned by the index digest of the tag.", "# Images: keyryx, pinned by the index digest of the tag.")')"

# The console's approver key and wardryx's copy of its public half (CLAUDE.md invariant 67).
run_case "approver: the mint applies over an existing key" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("lib/approver-mint.sh", "k_ \"-n $APPROVER_NS create -f -\"", "k_ \"-n $APPROVER_NS apply -f -\"")')" \
	"runs \`apply\` on the approver objects"
run_case "approver: the key is written as SEC1, not PKCS#8" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("lib/approver-mint.sh", "pkcs8 -topk8 -nocrypt -out", "ec -out")')" \
	"does not write the key as unencrypted PKCS#8"
run_case "approver: the curve is not P-256" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("lib/approver-mint.sh", "ecparam -name prime256v1", "ecparam -name secp384r1")')" \
	"does not make a P-256 key"
run_case "approver: the console reads the key from another path" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("manifests/20-console.yaml", "value: \"/run/approver/approver.pem\"", "value: \"/run/other/approver.pem\"")')" \
	"GENARYX_APPROVER_KEY_FILE is"
run_case "approver: the console's approver Secret becomes optional" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("manifests/20-console.yaml", "secret: \x7b secretName: console-approver-key, defaultMode: 0440 \x7d", "secret: \x7b secretName: console-approver-key, defaultMode: 0440, optional: true \x7d")')" \
	"is not the Secret console-approver-key at mode 0440"
run_case "approver: wardryx sets the JWK set with no mount (a half state)" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - { name: approver-jwks, mountPath: /etc/wardryx/approver, readOnly: true }\n", "")')" \
	"wardryx's approver wiring is half set"
run_case "approver: the JWK set's volume becomes optional (a half state)" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "configMap: { name: wardryx-approver-jwks }", "configMap: { name: wardryx-approver-jwks, optional: true }")')" \
	"wardryx's approver wiring is half set"
run_case "approver: wardryx reads the JWK set from another file" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "value: \"/etc/wardryx/approver/approver-jwks.json\"", "value: \"/etc/wardryx/approver/other.json\"")')" \
	"but the JWK set is mounted at"
run_case "approver: the console is left on v1.1.48 while wardryx reads the JWK set" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("manifests/20-console.yaml", "genaryx-console:v1.8.8@sha256:55765e22aeb5a157099b30a9ecbda53b83121c17b3b98b6896af5733ba16f9a5", "genaryx-console:v1.1.48@sha256:311625121ba911746aa9a52b9fac7ae1a4730a89546636c86d6543214ea5dd07")')" \
	"every approval would be refused"
run_case "approver: a TODO is left in place after the wiring" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - { name: WARDRYX_APPROVER_JWKS,", "            # TODO(approver-jwks): still pending\n            - { name: WARDRYX_APPROVER_JWKS,")')" \
	"the TODO is stale"
run_case "approver: a comment reworded in the wiring (must pass)" pass \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "(CLAUDE.md invariant 67). With WARDRYX_APPROVER_JWKS set", "(CLAUDE.md invariant 67). Once WARDRYX_APPROVER_JWKS is set")')"

run_case "approver: a cloud launcher never mints the approver key" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "\napprover_mint_settle\n", "\n")')" \
	"never calls approver_mint_settle"
run_case "approver: WARDRYX_ALLOW_KEY_APPROVALS is set on wardryx" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: WARDRYX_AGENT_TOKEN_DOOR_ORIGINS, value: \"http://tokenfuse-gateway:4100,http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100,http://tokenfuse-mcp-broker:4200,http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200\" \x7d\n", "            - \x7b name: WARDRYX_AGENT_TOKEN_DOOR_ORIGINS, value: \"http://tokenfuse-gateway:4100,http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100,http://tokenfuse-mcp-broker:4200,http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200\" \x7d\n            - \x7b name: WARDRYX_ALLOW_KEY_APPROVALS, value: \"1\" \x7d\n")')" \
	"sets WARDRYX_ALLOW_KEY_APPROVALS"
run_case "approver: wardryx is pinned before the approver statements" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "wardryx:v2.7.0@sha256:", "wardryx:v2.3.0@sha256:")')" \
	"before the approver statements"
run_case "approver: the mint rewrites a kept pair" fail \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("lib/approver-mint.sh", "if [ \"$secret_there\" = yes ] && [ \"$cm_there\" = yes ]; then", "if false; then")')" \
	"was not kept"
run_case "approver: a comment reworded in the mint library (must pass)" pass \
	'./scripts/approver-key-is-minted.sh' \
	"$(py 'edit("lib/approver-mint.sh", "# The console'"'"'s approver key, and wardryx'"'"'s copy", "# The console'"'"'s approver key, and the copy wardryx keeps")')"

# hub/add-site.sh reads the Cloud's version from a pinned image reference (name:tag@sha256:<64 hex>).
run_case "add-site: the reader takes the digest for the tag (the v1.5.3 defect)" fail \
	'./scripts/hub-add-site-reads-the-pinned-image.sh' \
	"$(py 'edit("hub/add-site.sh", "REF=\"$\x7bIMAGE%%@*\x7d\"", "REF=\"$\x7bIMAGE\x7d\"")')" \
	"reference, the form the manifests pin, is not read"
run_case "add-site: a short digest is accepted" fail \
	'./scripts/hub-add-site-reads-the-pinned-image.sh' \
	"$(py 'edit("hub/add-site.sh", "^sha256:[0-9a-f]\x7b64\x7d$", "^sha256:[0-9a-f]\x7b1,64\x7d$")')" \
	"a short digest is not refused"
run_case "add-site: a digest with no tag is read as a version" fail \
	'./scripts/hub-add-site-reads-the-pinned-image.sh' \
	"$(py 'edit("hub/add-site.sh", "  *) TAG=\"\" ;;", "  *) TAG=\"v0.0.0\" ;;")')" \
	"a digest with no tag is not refused"
run_case "add-site: a comment reworded beside the reader (must pass)" pass \
	'./scripts/hub-add-site-reads-the-pinned-image.sh' \
	"$(py 'edit("hub/add-site.sh", "# The manifests pin the image as name:tag@sha256", "# The manifests pin the image, as name:tag@sha256")')"

# tokenfuse v1.25.0 is pinned by digest; each tokenfuse door names only its own two origins, and wardryx's agent-token door names their union (CLAUDE.md invariant 74).
run_case "tokenfuse-door-origins: the gateway is left on tokenfuse v1.22.0" fail \
	'./scripts/tokenfuse-door-origins.sh' \
	"$(py 'p = "manifests/10-planes.yaml"; s = open(p).read(); s = s.replace("tokenfuse:v1.25.0@sha256:3a81", "tokenfuse:v1.23.0@sha256:3a81", 1); open(p, "w").write(s)')" \
	"is not the release pin"
run_case "tokenfuse-door-origins: the control plane digest is not the release pin" fail \
	'./scripts/tokenfuse-door-origins.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "e7d4160649128c6dc7d91d295a9a31e107e3bb7241d5483b5b193158a94dba58", "3f3b9831ec1c222d776ebfbf706e207a098aff80e550494f4c78b52c1784ed8e")')" \
	"is not the release pin"
run_case "tokenfuse-door-origins: the gateway's list names the broker's origin" fail \
	'./scripts/tokenfuse-door-origins.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "TOKENFUSE_DELEGATION_ORIGINS, value: \"http://tokenfuse-gateway:4100,http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100\"", "TOKENFUSE_DELEGATION_ORIGINS, value: \"http://tokenfuse-gateway:4100,http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100,http://tokenfuse-mcp-broker:4200\"")')" \
	"must name exactly"
run_case "tokenfuse-door-origins: the broker's delegation list names the gateway's origin" fail \
	'./scripts/tokenfuse-door-origins.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "TOKENFUSE_DELEGATION_ORIGINS, value: \"http://tokenfuse-mcp-broker:4200,http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200\"", "TOKENFUSE_DELEGATION_ORIGINS, value: \"http://tokenfuse-mcp-broker:4200,http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200,http://tokenfuse-gateway:4100\"")')" \
	"must name exactly"
run_case "tokenfuse-door-origins: the broker's MCP proof list names the gateway's origin" fail \
	'./scripts/tokenfuse-door-origins.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "TOKENFUSE_MCP_PROOF_ORIGINS, value: \"http://tokenfuse-mcp-broker:4200,http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200\"", "TOKENFUSE_MCP_PROOF_ORIGINS, value: \"http://tokenfuse-mcp-broker:4200,http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200,http://tokenfuse-gateway:4100\"")')" \
	"must name exactly"
run_case "tokenfuse-door-origins: wardryx's door list is missing the broker's cluster-internal name" fail \
	'./scripts/tokenfuse-door-origins.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "WARDRYX_AGENT_TOKEN_DOOR_ORIGINS, value: \"http://tokenfuse-gateway:4100,http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100,http://tokenfuse-mcp-broker:4200,http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200\"", "WARDRYX_AGENT_TOKEN_DOOR_ORIGINS, value: \"http://tokenfuse-gateway:4100,http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100,http://tokenfuse-mcp-broker:4200\"")')" \
	"must name exactly"
run_case "tokenfuse-door-origins: the gateway's list carries an entry that is not an origin" fail \
	'./scripts/tokenfuse-door-origins.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "TOKENFUSE_DELEGATION_ORIGINS, value: \"http://tokenfuse-gateway:4100,http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100\"", "TOKENFUSE_DELEGATION_ORIGINS, value: \"tokenfuse-gateway:4100,http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100\"")')" \
	"is not an origin"
run_case "tokenfuse-door-origins: the broker's MCP proof origins drop the cluster-internal name" fail \
	'./scripts/tokenfuse-door-origins.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "TOKENFUSE_MCP_PROOF_ORIGINS, value: \"http://tokenfuse-mcp-broker:4200,http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200\"", "TOKENFUSE_MCP_PROOF_ORIGINS, value: \"http://tokenfuse-mcp-broker:4200\"")')" \
	"must name exactly"
run_case "tokenfuse-door-origins: the broker's MCP proof origins are removed" fail \
	'./scripts/tokenfuse-door-origins.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "            - { name: TOKENFUSE_MCP_PROOF_ORIGINS, value: \"http://tokenfuse-mcp-broker:4200,http://tokenfuse-mcp-broker.agent-stack.svc.cluster.local:4200\" }\n", "")')" \
	"TOKENFUSE_MCP_PROOF_ORIGINS is not set"
run_case "tokenfuse-door-origins: the gateway's origin list is removed (measured nothing)" fail \
	'./scripts/tokenfuse-door-origins.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - { name: TOKENFUSE_DELEGATION_ORIGINS, value: \"http://tokenfuse-gateway:4100,http://tokenfuse-gateway.agent-stack.svc.cluster.local:4100\" }\n", "")')" \
	"TOKENFUSE_DELEGATION_ORIGINS is not set"
run_case "tokenfuse-door-origins: a comment reworded beside the broker (must pass)" pass \
	'./scripts/tokenfuse-door-origins.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "Every address the broker is reached at in the cluster (CLAUDE.md invariant 74).", "Every address the broker is reached at, in the cluster (CLAUDE.md invariant 74).")')"

# The record-seal fails closed: a failed pack ends the run non-zero, and only the known empty case exits 0 (CLAUDE.md invariant 71).
run_case "record-seal: a failed pack exits zero again (the old fallback)" fail \
	'./scripts/record-seal-fails-closed.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "exit \"$rc\"", "exit 0")')" \
	"a failed pack exits 0"
run_case "record-seal: the known empty case is matched loosely" fail \
	'./scripts/record-seal-fails-closed.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "*\"$known\"*)", "*nothing*)")')" \
	"a failed pack exits 0"
run_case "record-seal: the known empty case stops exiting zero" fail \
	'./scripts/record-seal-fails-closed.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "echo \"nothing sealed here to pack yet\"; exit 0 ;;", "echo \"nothing sealed here to pack yet\"; exit 1 ;;")')" \
	"does not exit 0 with its line when nothing is sealed"
run_case "record-seal: the CronJob is renamed away" fail \
	'./scripts/record-seal-fails-closed.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "name: record-seal\n  namespace: agent-stack", "name: record-sea1\n  namespace: agent-stack")')" \
	"has no record-seal CronJob"
run_case "record-seal: a comment reworded in the pack step (must pass)" pass \
	'./scripts/record-seal-fails-closed.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "# A failed pack ends the run non-zero, except", "# A failed pack ends the run non-zero, unless")')"

# The witness reads the record it countersigns, and the record-seal reads the attestations, through shared volumes (CLAUDE.md invariant 70).
run_case "witness-records: the witness stops reading the record" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "KEYRYX_WITNESS_RECORDS", "KEYRYX_WITNESS_RECORDSX")')" \
	"does not read the record"
run_case "witness-records: the witness mounts the record writable" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "            - name: trailryx-records\n              mountPath: /var/lib/stack/records\n              readOnly: true\n", "            - name: trailryx-records\n              mountPath: /var/lib/stack/records\n")')" \
	"does not mount the trailryx-records claim read-only"
run_case "witness-records: the record claim is not read only" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "            claimName: trailryx-records\n            readOnly: true\n", "            claimName: trailryx-records\n")')" \
	"is not a read-only claim of trailryx-records"
run_case "witness-records: the witness Deployment is no longer Recreate" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'p = "keyryx/manifests/59-keyryx.yaml"; s = open(p).read(); i = s.rindex("strategy: { type: Recreate }"); open(p, "w").write(s[:i] + "strategy: { type: RollingUpdate }" + s[i + len("strategy: { type: Recreate }"):])')" \
	"is not Recreate"
run_case "witness-records: the witness init stops making the attestation directory" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "mkdir -p /var/lib/keyryx-witness/data/attestations && chmod 0750 /var/lib/keyryx-witness/data/attestations &&", "true &&")')" \
	"does not make data/attestations"
run_case "witness-records: the record-seal is not pinned to the witness node" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("keyryx/record-seal-patch.yaml", "topologyKey: kubernetes.io/hostname", "topologyKey: topology.kubernetes.io/zone")')" \
	"not pod-affined to the witness"
run_case "witness-records: the record-seal mounts the whole witness state" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("keyryx/record-seal-patch.yaml", "                  subPath: data/attestations\n", "")')" \
	"without the subPath data/attestations"
run_case "witness-records: the record-seal is not pointed at the attestations" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("keyryx/record-seal-patch.yaml", "                - name: TRAILRYX_WITNESS_ATTESTATIONS\n                  value: /var/lib/stack/attestations\n", "")')" \
	"does not point TRAILRYX_WITNESS_ATTESTATIONS at its read-only attestations directory"
run_case "witness-records: the witness runs outside the record plane's group" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "runAsUser: 20100\n        runAsGroup: 10001\n        fsGroup: 10001", "runAsUser: 20100\n        runAsGroup: 20100\n        fsGroup: 10001")')" \
	"does not run as group 10001"
run_case "witness-records: the witness init runs outside the record plane's group" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("keyryx/manifests/59-keyryx.yaml", "runAsUser: 20100\n            runAsGroup: 10001", "runAsUser: 20100\n            runAsGroup: 20100")')" \
	"root-key-copy does not run as group 10001"
run_case "witness-records: the opt-out keeps the pod affinity" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("keyryx/record-seal-unpatch.yaml", "affinity: null", "affinity: {}")')" \
	"does not remove the pod affinity"
run_case "witness-records: the record-seal passes its own tenant" fail \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "--seal-records 500 || true", "--tenant other --seal-records 500 || true")')" \
	"passes --tenant"
run_case "witness-records: a comment reworded in the record-seal patch (must pass)" pass \
	'./scripts/keyryx-witness-shares-the-record.sh' \
	"$(py 'edit("keyryx/record-seal-patch.yaml", "Applied by lib/keyryx-install.sh with `kubectl patch", "Applied by the library lib/keyryx-install.sh with `kubectl patch")')"

# Workflow checkouts of other repositories are pinned to a full commit (CLAUDE.md invariant 68).
run_case "workflow-checkouts: a checkout of another repository has no ref" fail \
	'./scripts/workflow-checkouts-are-pinned.sh' \
	"$(py 'edit(".github/workflows/console-image.yml", "          ref: $\x7b\x7b env.QRYX_REF \x7d\x7d\n", "")')" \
	"checkout of TAIPANBOX/qryx has no ref:"
run_case "workflow-checkouts: a checkout reads a branch" fail \
	'./scripts/workflow-checkouts-are-pinned.sh' \
	"$(py 'edit(".github/workflows/console-image.yml", "ref: $\x7b\x7b env.GENARYX_REF \x7d\x7d", "ref: main")')" \
	"is not a full 40-hex commit"
run_case "workflow-checkouts: a pinned commit is shortened" fail \
	'./scripts/workflow-checkouts-are-pinned.sh' \
	"$(py 'edit(".github/workflows/console-image.yml", "QRYX_REF: 912724d6611cf18332c4788d84f9348e6d476a71", "QRYX_REF: 912724d6611cf18332")')" \
	"not a full 40-hex commit"
run_case "workflow-checkouts: a sixth repository is checked out with no ref" fail \
	'./scripts/workflow-checkouts-are-pinned.sh' \
	"$(py 'p = ".github/workflows/console-image.yml"; s = open(p).read(); open(p, "w").write(s + "\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          repository: TAIPANBOX/newtool\n          path: newtool\n")')" \
	"checkout of TAIPANBOX/newtool has no ref:"
run_case "workflow-checkouts: the env block that holds the commits is taken away" fail \
	'./scripts/workflow-checkouts-are-pinned.sh' \
	"$(py 'edit(".github/workflows/console-image.yml", "env:\n  QRYX_REF:", "env_:\n  QRYX_REF:")')" \
	"does not set"
run_case "workflow-checkouts: a comment reworded in the workflow (must pass)" pass \
	'./scripts/workflow-checkouts-are-pinned.sh' \
	"$(py 'edit(".github/workflows/console-image.yml", "# The commits this image is built from, in one place", "# The commits this image is built from, pinned in one place")')"

# The console's two proof engines are the stack's own, digest for digest (CLAUDE.md invariant 79).
run_case "console-engines: the console's wardryx differs from the stack's" fail \
	'./scripts/console-engines-are-the-stacks.sh' \
	"$(py 'edit("images/console.Dockerfile", "wardryx:v2.7.0@sha256:91dccc66", "wardryx:v2.7.0@sha256:2101d23c")')" \
	"differs from the stack's"
run_case "console-engines: the console's tokenfuse is an older tag than the stack's" fail \
	'./scripts/console-engines-are-the-stacks.sh' \
	"$(py 'edit("images/console.Dockerfile", "tokenfuse:v1.25.0@sha256:3a81", "tokenfuse:v1.23.0@sha256:3a81")')" \
	"differs from the stack's"
run_case "console-engines: the manifests name two tokenfuse digests" fail \
	'./scripts/console-engines-are-the-stacks.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "ghcr.io/taipanbox/tokenfuse:v1.25.0@sha256:3a81dbcd", "ghcr.io/taipanbox/tokenfuse:v1.25.0@sha256:3a81dbce")')" \
	"names 2 different tokenfuse references"
run_case "console-engines: an engine stage is named something the copy does not look for" fail \
	'./scripts/console-engines-are-the-stacks.sh' \
	"$(py 'edit("images/console.Dockerfile", " AS tokenfuse-engine", " AS other")')" \
	"is named 'other'"
run_case "console-engines: the wardryx binary is no longer copied" fail \
	'./scripts/console-engines-are-the-stacks.sh' \
	"$(py 'edit("images/console.Dockerfile", "COPY --from=wardryx-engine /usr/local/bin/service /usr/local/bin/wardryx\n", "")')" \
	"does not copy the binary out of the wardryx-engine stage"
run_case "console-engines: the tokenfuse label is gone" fail \
	'./scripts/console-engines-are-the-stacks.sh' \
	"$(py 'edit("images/console.Dockerfile", "dev.taipanbox.engine.tokenfuse", "dev.taipanbox.engine.tokenfusx")')" \
	"has no dev.taipanbox.engine.tokenfuse label"
run_case "console-engines: a smoke loop stops running wardryx" fail \
	'./scripts/console-engines-are-the-stacks.sh' \
	"$(py 'edit(".github/workflows/console-image.yml", "verdryx wardryx \"tokenfuse constants\" genaryx-web; do", "verdryx \"tokenfuse constants\" genaryx-web; do")')" \
	"does not run wardryx"
run_case "console-engines: a smoke loop runs tokenfuse with no argument, which starts the gateway" fail \
	'./scripts/console-engines-are-the-stacks.sh' \
	"$(py 'edit(".github/workflows/console-image.yml", "wardryx \"tokenfuse constants\" genaryx-web; do", "wardryx tokenfuse genaryx-web; do")')" \
	"does not run tokenfuse"
run_case "console-engines: no engine stage at all measures nothing" fail \
	'./scripts/console-engines-are-the-stacks.sh' \
	"$(py 'p = "images/console.Dockerfile"; s = open(p).read(); open(p, "w").write("\n".join(l for l in s.split("\n") if not l.startswith("FROM ghcr.io/taipanbox/")))')" \
	"this measured NOTHING"
run_case "console-engines: a comment reworded in the Dockerfile (must pass)" pass \
	'./scripts/console-engines-are-the-stacks.sh' \
	"$(py 'edit("images/console.Dockerfile", "# --- the two engines the console\x27s proofs run", "# --- the two engines that the console\x27s proofs run")')"

# Every image this repository builds from is pinned whole (CLAUDE.md invariant 80).
run_case "base-images: a moving tag comes back on the runtime base" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/caddy.Dockerfile", "FROM caddy:2.11.8-alpine@sha256:f6228111e5fafa1a5238258d0858e103f10599b8d1659a146e7726681a002bb9", "FROM caddy:2.11.8-alpine")')" \
	"has no digest"
run_case "base-images: a digest one character short" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/wg.Dockerfile", "d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc", "d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6b")')" \
	"has no digest"
run_case "base-images: a variable comes back into a FROM" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/console.Dockerfile", "FROM rust:1.85-slim@", "FROM rust:${RUST_VERSION}-slim@")')" \
	"has a variable"
run_case "base-images: a digest with no version beside it" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/tokenfuse.Dockerfile", "FROM debian:12-slim@", "FROM debian@")')" \
	"names no version"
run_case "base-images: a digest beside latest" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/wg.Dockerfile", "FROM alpine:3.20@", "FROM alpine:latest@")')" \
	"names no version"
run_case "base-images: the build frontend floats" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/wg.Dockerfile", "dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e", "dockerfile:1.7")')" \
	"has no digest"
run_case "base-images: a new Dockerfile on a moving tag, found by discovery" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'open("images/new.Dockerfile", "w").write("FROM debian:12-slim\n")')" \
	"has no digest"
run_case "base-images: a lower-case from on a moving tag" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/console.Dockerfile", "FROM node:22-slim@sha256:5ec23b7c622b00547753bc6ffd78085dd868a68aeb41c8e0a1418f033e13d96d", "from node:22-slim")')" \
	"has no digest"
run_case "base-images: a COPY reaches for an image no stage names" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/go-service.Dockerfile", "COPY --from=build /out/service", "COPY --from=busybox:1 /bin/busybox /bin/busybox\nCOPY --from=build /out/service")')" \
	"has no digest"
run_case "base-images: one tag carries two digests" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/tokenfuse.Dockerfile", "debian:12-slim@sha256:734a", "debian:12-slim@sha256:734b")')" \
	"carries 2 digests"
run_case "base-images: one image moves to another Go alone" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/wg.Dockerfile", "FROM golang:1.27.4-alpine@", "FROM golang:1.27.5-alpine@"); edit("images/wg.Dockerfile", "= go1.27.4", "= go1.27.5")')" \
	"more than one Go"
run_case "base-images: a golang stage loses its assertion" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/go-service.Dockerfile", "RUN test \"$(go env GOVERSION)\" = go1.27.4\n", "")')" \
	"does not start with"
run_case "base-images: the tag moves and the digest and assertion stay" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/console.Dockerfile", "FROM golang:1.27.4-alpine@", "FROM golang:1.27.5-alpine@")')" \
	"asserts go1.27.4 on a golang:1.27.5 base"
run_case "base-images: xcaddy loses Caddy\x27s version" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/caddy.Dockerfile", "xcaddy build v2.11.8 --with", "xcaddy build --with")')" \
	"names no Caddy version"
run_case "base-images: the DNS plugin loses its version" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/caddy.Dockerfile", "cloudflare@v0.2.4", "cloudflare")')" \
	"takes its latest"
run_case "base-images: go install asks for latest" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/caddy.Dockerfile", "xcaddy@v0.4.7", "xcaddy@latest")')" \
	"can install something else"
run_case "base-images: the runtime base moves without the build" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/caddy.Dockerfile", "FROM caddy:2.11.8-alpine@", "FROM caddy:2.11.9-alpine@")')" \
	"names two Caddies"
run_case "base-images: every Dockerfile is gone, which must say it measured nothing" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'import glob, os
for f in glob.glob("images/*Dockerfile*"):
    os.remove(f)')" \
	"measured NOTHING"
run_case "base-images: no xcaddy build is left, which must say it measured nothing" fail \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/caddy.Dockerfile", "RUN xcaddy build v2.11.8 --with github.com/caddy-dns/cloudflare@v0.2.4 --output /usr/bin/caddy\n", "")')" \
	"measured NOTHING"
run_case "base-images: a later stage built on an earlier one (must pass)" pass \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/wg.Dockerfile", "RUN go install golang.zx2c4.com", "FROM build AS extra\nRUN go install golang.zx2c4.com")')"
run_case "base-images: a comment reworded in a Dockerfile (must pass)" pass \
	'./scripts/base-images-are-pinned.sh' \
	"$(py 'edit("images/caddy.Dockerfile", "# Built on the Go every other image here names", "# Built on the one Go every other image here names")')"

# The CostCrew run ceiling and the crew's schedule (CLAUDE.md invariant 66). No default ships, the
# figure is validated before anything is installed, and the crew CronJob is suspended until an operator resumes it.
run_case "costcrew-ceiling: the validator accepts three decimals" fail \
	'./scripts/costcrew-ceiling-is-set.sh' \
	"$(py 'edit("budget/costcrew-ceiling.sh", "(\\.[0-9]\x7b1,2\x7d)?$", "(\\.[0-9]\x7b1,6\x7d)?$")')" \
	"accepts '1.234'"
run_case "costcrew-ceiling: zero is accepted" fail \
	'./scripts/costcrew-ceiling-is-set.sh' \
	"$(py 'edit("budget/costcrew-ceiling.sh", "  \"\") refuse", "  \"zz\") refuse")')" \
	"accepts '0'"
run_case "costcrew-ceiling: the GCP launcher does not validate the figure" fail \
	'./scripts/costcrew-ceiling-is-set.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "\"$ROOT/budget/costcrew-ceiling.sh\" check", "\"$ROOT/budget/costcrew-ceilingx.sh\" check")')" \
	"does not validate the CostCrew ceiling"
run_case "costcrew-ceiling: the AWS launcher never writes the ceiling" fail \
	'./scripts/costcrew-ceiling-is-set.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "patch configmap stack-wiring --type merge", "patch configmapx stack-wiring --type merge")')" \
	"never writes COSTCREW_CEILING"
run_case "costcrew-ceiling: the crew reads the ceiling optionally" fail \
	'./scripts/costcrew-ceiling-is-set.sh' \
	"$(py 'edit("manifests/49-costcrew.yaml", "configMapKeyRef: \x7b name: stack-wiring, key: COSTCREW_CEILING \x7d", "configMapKeyRef: \x7b name: stack-wiring, key: COSTCREW_CEILING, optional: true \x7d")')" \
	"or reads it optionally"
run_case "costcrew-ceiling: the crew CronJob is suspended" fail \
	'./scripts/costcrew-ceiling-is-set.sh' \
	"$(py 'edit("manifests/49-costcrew.yaml", "  suspend: false\n", "  suspend: true\n")')" \
	"does not run the crew on its schedule"
run_case "costcrew-ceiling: a launcher says the crew ships suspended" fail \
	'./scripts/costcrew-ceiling-is-set.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "runs on its schedule, bounded by", "ships suspended, bounded by")')" \
	"says the crew is suspended"
run_case "costcrew-ceiling: the README says the crew is suspended" fail \
	'./scripts/costcrew-ceiling-is-set.sh' \
	"$(py 'edit("README.md", "runs every day at 05:57", "is suspended and runs every day at 05:57")')" \
	"README.md says the crew is suspended"
run_case "costcrew-ceiling: deploy.sh stops parsing the flag" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("deploy.sh", "    --costcrew-ceiling)   COSTCREW_CEILING_ARG=\"$2\"; shift 2 ;;\n", "")')" \
	"does not parse --costcrew-ceiling"
run_case "costcrew-ceiling: a comment reworded in the validator (must pass)" pass \
	'./scripts/costcrew-ceiling-is-set.sh' \
	"$(py 'edit("budget/costcrew-ceiling.sh", "# The ONE copy of the validation:", "# The one copy of the validation:")')"

# The risk hold (CLAUDE.md invariant 65): with --typed-risk-signal wardryx holds a call with no signal, and
# only with the flag. Each case takes one property away; the braces in the py bodies are \x7b and \x7d.
run_case "risk-hold: the policy volume drops the optional hold source" fail \
	'./scripts/risk-hold-follows-the-flag.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "              - configMap: \x7b name: wardryx-typed-hold, optional: true \x7d\n", "")')" \
	"does not project the ConfigMap wardryx-typed-hold"
run_case "risk-hold: the hold source is required, so the plane cannot start without a hold" fail \
	'./scripts/risk-hold-follows-the-flag.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "wardryx-typed-hold, optional: true \x7d", "wardryx-typed-hold \x7d")')" \
	"is not optional"
run_case "risk-hold: wardryx reads one file again, not the policy directory" fail \
	'./scripts/risk-hold-follows-the-flag.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "- \"/etc/wardryx/policy\"", "- \"/etc/wardryx/policy.yaml\"")')" \
	"does not read its policy from the directory"
run_case "risk-hold: the hold also holds read-only calls" fail \
	'./scripts/risk-hold-follows-the-flag.sh' \
	"$(py 'edit("typed/mode.sh", "values: [destructive, external_send, financial]", "values: [read_only, destructive, external_send, financial]")')" \
	"holds on"
run_case "risk-hold: the hold carries a key that could deny" fail \
	'./scripts/risk-hold-follows-the-flag.sh' \
	"$(py 'edit("typed/mode.sh", "min_probability: 0.8\\n        when_absent: hold", "min_probability: 0.8\\n        decision: deny\\n        when_absent: hold")')" \
	"could deny"
run_case "risk-hold: the hold is printed without the flag" fail \
	'./scripts/risk-hold-follows-the-flag.sh' \
	"$(py 'edit("typed/mode.sh", "[ \"$RISK\" = 1 ] && [ \"$EFFECTIVE\" != off ] || return 0", "true")')" \
	"WITHOUT the flag prints a document"
run_case "risk-hold: the hold verb is taken out of the dispatch" fail \
	'./scripts/risk-hold-follows-the-flag.sh' \
	"$(py 'edit("typed/mode.sh", "  hold)        emit_risk_hold ;;\n", "")')" \
	"has no \`hold\` verb"
run_case "risk-hold: deploy.sh never applies the hold" fail \
	'./scripts/risk-hold-follows-the-flag.sh' \
	"$(py 'edit("deploy.sh", "\"$ROOT/typed/mode.sh\" hold ${TYPED_ARGS", "\"$ROOT/typed/mode.sh\" holdx ${TYPED_ARGS")')" \
	"deploy.sh: does not apply the hold ConfigMap"
run_case "risk-hold: the AWS launcher applies the hold and restarts a different plane" fail \
	'./scripts/risk-hold-follows-the-flag.sh' \
	"$(py 's = open("cloud/aws/deploy-aws.sh").read(); i = s.index("could not restart wardryx to load the hold rule"); j = s.rindex("rollout restart deployment/wardryx", 0, i); open("cloud/aws/deploy-aws.sh", "w").write(s[:j] + "rollout restart deployment/otherplane" + s[j + len("rollout restart deployment/wardryx"):])')" \
	"does not restart wardryx after the hold changes"
run_case "risk-hold: the GCP launcher does not clear the hold without the flag" fail \
	'./scripts/risk-hold-follows-the-flag.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "delete configmap wardryx-typed-hold --ignore-not-found", "delete configmap wardryx-typed-holdx --ignore-not-found")')" \
	"does not clear wardryx-typed-hold"
run_case "risk-hold: a comment reworded in the planes manifest (must pass)" pass \
	'./scripts/risk-hold-follows-the-flag.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "# A directory, not one file:", "# A directory, not a single file:")')"

# Stream files are precreated (CLAUDE.md invariant 59, GOTCHAS 135). A writer that refuses to start
# on a root-owned volume is the failure; each case below takes one property the gate judges away.
# Since invariant 89 the table holds the files on a writer's OWN volume (heraldyx's journal, scopyx's,
# vouchryx's revocation list, the witness's findings); the bus streams are the bus owner's, below.
run_case "stream-precreate: heraldyx loses the init that creates its journal" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "- name: precreate-streams", "- name: precreate-streams-off")')" \
	"Deployment heraldyx -> /var/lib/stack/heraldyx/sent.ndjson: no precreate-streams"
run_case "stream-precreate: the init runs as root" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "runAsUser: 65532, runAsGroup: 65532, allowPrivilegeEscalation: false", "runAsUser: 0, runAsGroup: 65532, allowPrivilegeEscalation: false")')" \
	"the init container runs as root"
run_case "stream-precreate: the init runs as another uid than the writer" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("manifests/54-delegation.yaml", "runAsUser: 20002, runAsGroup: 20002, allowPrivilegeEscalation: false", "runAsUser: 20003, runAsGroup: 20002, allowPrivilegeEscalation: false")')" \
	"does not run as the writer's uid 20002"
run_case "stream-precreate: the file is created in the wrong group" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("manifests/54-delegation.yaml", "runAsUser: 20002, runAsGroup: 20002, allowPrivilegeEscalation: false", "runAsUser: 20002, runAsGroup: 65532, allowPrivilegeEscalation: false")')" \
	"does not create the file in group 20002"
run_case "stream-precreate: the file is left group- and world-readable" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("manifests/47-scopyx.yaml", "umask 027; : >", "umask 022; : >")')" \
	"does not set the file to 0640"
run_case "stream-precreate: the init creates a file the writer does not append to" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "f=/var/lib/stack/heraldyx/sent.ndjson;", "f=/var/lib/stack/heraldyx/sent-x.ndjson;")')" \
	"does not create /var/lib/stack/heraldyx/sent.ndjson"
run_case "stream-precreate: the revocation list is not among the files created" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("manifests/54-delegation.yaml", "for f in /var/lib/stack/delegation/revocations.ndjson; do", "for f in /var/lib/stack/delegation/other.ndjson; do")')" \
	"does not create /var/lib/stack/delegation/revocations.ndjson"
# Assigned before use: bash 3.2 (the shell a Mac ships) drops the text between the braces when an
# edit with `{ ... }` sits inside "$(...)", and the teeth run then reported this case BROKEN.
journal_edit=$(py 'edit("manifests/48-scopyx-browser.yaml", "[{ name: journal, mountPath: /var/lib/scopyx }]", "[{ name: tmp, mountPath: /var/lib/scopyx }]")')
run_case "stream-precreate: the init mounts a different volume than the file lives on" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$journal_edit" \
	"does not mount the volume journal"
run_case "stream-precreate: the init image is not pinned by digest" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 's = open("manifests/45-heraldyx.yaml").read(); i = s.index("f=/var/lib/stack/heraldyx/sent.ndjson"); j = s.rindex("image: busybox@sha256:", 0, i); k = s.index("\n", j); open("manifests/45-heraldyx.yaml", "w").write(s[:j] + "image: busybox:1.36" + s[k:])')" \
	"does not run busybox by digest"
run_case "stream-precreate: the object the table names is renamed away" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "kind: Deployment\nmetadata:\n  name: heraldyx\n", "kind: Deployment\nmetadata:\n  name: heraldyx-renamed\n")')" \
	"the object is absent, so this writer is measured NOTHING"
run_case "stream-precreate: a reader drops its group" fail \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "supplementalGroups: [10001], ", "")')" \
	"idryx (mounts stack-events): the pod is not in group 10001"
run_case "stream-precreate: a reader's group written as a longer list (must pass)" pass \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "supplementalGroups: [10001], ", "supplementalGroups: [ 10001, 65532 ], ")')"
run_case "stream-precreate: a new pod mounts stack-events outside group 10001" fail \
	'./scripts/stream-files-are-precreated.sh' \
"$(py 'rogue = """---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rogue-reader
  namespace: agent-stack
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rogue-reader
  template:
    metadata:
      labels:
        app: rogue-reader
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
      containers:
        - name: c
          image: busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
          volumeMounts:
            - name: events
              mountPath: /var/lib/stack/events
      volumes:
        - name: events
          persistentVolumeClaim:
            claimName: stack-events
"""
p = "manifests/52-tokenfuse-mcp-broker.yaml"
open(p, "w").write(open(p).read() + rogue)')" \
	"rogue-reader (mounts stack-events): the pod is not in group 10001"
run_case "stream-precreate: the same new pod with fsGroup 10001 (must pass)" pass \
	'./scripts/stream-files-are-precreated.sh' \
"$(py 'rogue = """---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rogue-reader
  namespace: agent-stack
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rogue-reader
  template:
    metadata:
      labels:
        app: rogue-reader
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 10001
      containers:
        - name: c
          image: busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
          volumeMounts:
            - name: events
              mountPath: /var/lib/stack/events
      volumes:
        - name: events
          persistentVolumeClaim:
            claimName: stack-events
"""
p = "manifests/52-tokenfuse-mcp-broker.yaml"
open(p, "w").write(open(p).read() + rogue)')"
run_case "stream-precreate: a comment naming the init container (must pass)" pass \
	'./scripts/stream-files-are-precreated.sh' \
	"$(py 'edit("manifests/54-delegation.yaml", "      # precreate-streams makes the revocation list", "      # precreate-streams (invariant 59) makes the revocation list")')"

# One uid and one group per bus writer, and only the owner writes the bus directory (CLAUDE.md
# invariant 89, GAPS G3.16). Each case takes one property away, the way a later edit would.
run_case "bus-writers: two planes write the bus as one uid" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "runAsUser: 20005, runAsGroup: 20005, fsGroup: 10001", "runAsUser: 20001, runAsGroup: 20005, fsGroup: 10001")')" \
	"shares uid 20001 with"
run_case "bus-writers: a plane carries another producer's group" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/49-costcrew.yaml", "fsGroup: 65532, supplementalGroups: [10001], seccompProfile", "fsGroup: 65532, supplementalGroups: [10001, 20001], seccompProfile")')" \
	"carries the group of another producer (20001)"
run_case "bus-writers: a writer is not in its own producer's group" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "runAsUser: 20012, runAsGroup: 20012, fsGroup: 10001, seccompProfile", "runAsUser: 20012, runAsGroup: 10001, fsGroup: 10001, seccompProfile")')" \
	"is not in group 20012, so it cannot append to tokenfuse-mcp.ndjson"
run_case "bus-writers: a plane mounts the volume root read-write" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "- { name: events, mountPath: /var/lib/stack/events, subPath: streams }\n            - { name: traces, mountPath: /var/lib/stack/traces, readOnly: true }", "- { name: events, mountPath: /var/lib/stack/events }\n            - { name: traces, mountPath: /var/lib/stack/traces, readOnly: true }")')" \
	"container verdryx-slo: mounts the stack-events root read-write"
run_case "bus-writers: a reader mounts the volume root read only" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "- { name: events, mountPath: /var/lib/stack/events, subPath: streams, readOnly: true }", "- { name: events, mountPath: /var/lib/stack/events, readOnly: true }")')" \
	"container heraldyx: mounts the stack-events root;"
run_case "bus-writers: a reader mounts the bus read-write" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "- { name: events, mountPath: /var/lib/stack/events, subPath: streams, readOnly: true }", "- { name: events, mountPath: /var/lib/stack/events, subPath: streams }")')" \
	"container idryx: mounts the bus read-write and is no writer in WRITERS"
run_case "bus-writers: a pod runs as the bus owner" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "runAsUser: 65532, runAsGroup: 65532, supplementalGroups: [10001], seccompProfile", "runAsUser: 20000, runAsGroup: 65532, supplementalGroups: [10001], seccompProfile")')" \
	"runs as 20000, the bus owner"
run_case "bus-writers: a pod starts without waiting for the owner" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "- name: bus-ready", "- name: bus-wait")')" \
	"Deployment typryx: its first init container is not bus-ready"
run_case "bus-writers: the wait names no marker" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 's = open("manifests/49-costcrew.yaml").read(); open("manifests/49-costcrew.yaml", "w").write(s.replace("until [ -f /bus/streams/.layout ]", "until [ -d /bus/streams ]", 1))')" \
	"its bus-ready init does not wait for streams/.layout"
run_case "bus-writers: the owner leaves the bus directory writable to its group" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/11-bus.yaml", "own_dir \"$S\" 10001 2750", "own_dir \"$S\" 10001 2770")')" \
	"the owner does not make streams/ 20000:10001 2750"
run_case "bus-writers: the owner gives a stream to another producer's group" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/11-bus.yaml", "wardryx.ndjson:20001", "wardryx.ndjson:20003")')" \
	"the owner gives wardryx.ndjson to group 20003; its producer is 20001"
run_case "bus-writers: the owner stops making a stream" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/11-bus.yaml", "typryx.ndjson:20005", "typryx-old.ndjson:20005")')" \
	"the owner's script does not make typryx.ndjson"
run_case "bus-writers: the owner is in more groups than AUTH_SYS carries" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/11-bus.yaml", "supplementalGroups: [20001,", "supplementalGroups: [30001, 30002, 30003, 30004, 30005, 20001,")')" \
	"NFS with AUTH_SYS honours 16"
run_case "bus-writers: the owner runs as another uid" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/11-bus.yaml", "        runAsUser: 20000\n", "        runAsUser: 20001\n")')" \
	"the owner runs as 20001, not 20000"
run_case "bus-writers: a writer the table names is gone" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/54-delegation.yaml", "        - name: vouchryx\n", "        - name: vouchryx-main\n")')" \
	"container vouchryx: WRITERS says it appends to vouchryx.ndjson"
run_case "bus-writers: no owner Job at all" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/11-bus.yaml", "kind: Job\n", "kind: CronJob\n")')" \
	"no Job bus-owner mounts the stack-events root"
run_case "bus-writers: no pod mounts the claim at all" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'import glob, subprocess
for f in subprocess.run(["git", "ls-files", "*.yaml", "*.sh"], capture_output=True, text=True).stdout.split():
    t = open(f).read()
    if "claimName: stack-events" in t:
        open(f, "w").write(t.replace("claimName: stack-events", "claimName: stack-events-gone"))')" \
	"no pod mounts the stack-events claim, so this gate measured NOTHING"
run_case "bus-writers: a pod a script writes mounts the volume root" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("lib/tool-hold.sh", "{ name: events, mountPath: /var/lib/stack/events, readOnly: true, subPath: streams }", "{ name: events, mountPath: /var/lib/stack/events, readOnly: true }")')" \
	"container replay: mounts the stack-events root"
run_case "bus-writers: a probe entry outlives its pod" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("security-tests.sh", "metadata: { name: sec-bus, labels:", "metadata: { name: sec-bus-renamed, labels:")')" \
	"the PROBES entry matches no pod"
run_case "bus-writers: the owner stages a copy where a producer can plant a link" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/11-bus.yaml", "    T=$S/.stage.tmp\n", "    T=$A/.stage.tmp\n")')" \
	"outside streams/, where a producer can plant a link"
run_case "bus-writers: the owner moves a file without -T" fail \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/11-bus.yaml", "if mv -T -f \"$T\" \"$4\"", "if mv -f \"$T\" \"$4\"")')" \
	"the owner moves a file without mv -T"
run_case "bus-writers: a writer's groups written as a longer list (must pass)" pass \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/49-costcrew.yaml", "fsGroup: 65532, supplementalGroups: [10001], seccompProfile", "fsGroup: 65532, supplementalGroups: [ 10001, 65532 ], seccompProfile")')"
run_case "bus-writers: a comment above the bus-ready init reworded (must pass)" pass \
	'./scripts/bus-writers-are-separate.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "# bus-ready (CLAUDE.md invariant 89, GAPS G3.16)", "# bus-ready, the wait (CLAUDE.md invariant 89, GAPS G3.16)")')"

# ---- admission on in every launcher that applies the stack (CLAUDE.md invariant 58) ----
TEETH_EDIT_196="$(py 'edit("cloud/gcp/deploy-gcp.sh", "k_ \"apply -k /root/stack-k8s/manifests\"\n", "su_ \"$FIRST\" \x27KUBECTL=\"/usr/local/bin/k3s kubectl\" bash /root/stack-k8s/policy/up.sh --enforce\x27\nk_ \"apply -k /root/stack-k8s/manifests\"\n")')"
run_case "verified-images-are-enforced: a cloud launcher turns admission on before its apply" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$TEETH_EDIT_196" \
	"before it applies the manifests"

TEETH_EDIT_197="$(py 'edit("cloud/aws/deploy-aws.sh", "KUBECTL=\"/usr/local/bin/k3s kubectl\" bash /root/stack-k8s/policy/up.sh --enforce\x27 \\\n", "KUBECTL=\"/usr/local/bin/k3s kubectl\" bash /root/stack-k8s/policy/up.sh\x27 \\\n")')"
run_case "verified-images-are-enforced: a cloud launcher has no admission step" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$TEETH_EDIT_197" \
	"does not turn admission on"

TEETH_EDIT_198="$(py 'edit("cloud/gcp/deploy-gcp.sh", "tar -cz -C \"$ROOT\" manifests policy | su_ \"$FIRST\" \x27sh -c \"mkdir -p /root/stack-k8s", "tar -cz -C \"$ROOT\" manifests | su_ \"$FIRST\" \x27sh -c \"mkdir -p /root/stack-k8s")')"
run_case "verified-images-are-enforced: a cloud node receives the manifests without policy/" fail \
	'./scripts/verified-images-are-enforced.sh' \
	"$TEETH_EDIT_198" \
	"without policy/"

# ---- no-secret-on-argv (CLAUDE.md invariant 60): a secret never on a command line ----
TEETH_EDIT_199="$(py 'open("install.sh", "a").write("k_ \"-n agent-stack create secret generic zz --from-literal=password=$PW\" >/dev/null\n")')"
run_case "no-secret-on-argv: an installer puts a plane credential on argv with --from-literal" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$TEETH_EDIT_199" \
	"puts a secret value on argv"

TEETH_EDIT_200="$(py 'open("deploy.sh", "a").write("curl -sf -H \"Authorization: Bearer $CONSOLE_TOKEN\" https://api.github.com/repos/x\n")')"
run_case "no-secret-on-argv: a bearer header is built from an expansion" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$TEETH_EDIT_200" \
	"bearer whose value"

TEETH_EDIT_201="$(py 'open("install.sh", "a").write("      sh_ \"$FIRST\" \"K3S_TOKEN=\x27$K3S_TOKEN_VALUE\x27 sh -s - serv" + "er\"\n")')"
run_case "no-secret-on-argv: the k3s token is assigned on the ssh command line" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$TEETH_EDIT_201" \
	"assigned on a command line"

TEETH_EDIT_202="$(py 'open("deploy.sh", "a").write("git clone \"https://x-access-token:$CONSOLE_TOKEN@github.com/TAIPANBOX/genaryx.git\" x\n")')"
run_case "no-secret-on-argv: a clone URL carries the token" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$TEETH_EDIT_202" \
	"carries a credential"

TEETH_EDIT_203="$(py 'open("deploy.sh", "a").write("bash x.sh --token \"$HCLOUD_TOKEN\"\n")')"
run_case "no-secret-on-argv: a secret passed as a flag value" fail \
	'./scripts/no-secret-on-argv.sh' \
	"$TEETH_EDIT_203" \
	"flag"

run_case "no-secret-on-argv: a secret_doc argument is not a process argument (must pass)" pass \
	'./scripts/no-secret-on-argv.sh' \
	"$(py 'open("install.sh", "a").write("secret_doc zz password=\"$PW\" dsn=\"postgres://u:$PW@h/x\" | k_ \"-n agent-stack create -f -\" >/dev/null\n")')"

run_case "no-secret-on-argv: no subject, measured nothing" fail_env \
	'd="$(mktemp -d)" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$d" init -q && mkdir "$d/scripts" && cp scripts/no-secret-on-argv.sh "$d/scripts/" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE "$d/scripts/no-secret-on-argv.sh"' \
	"$(py 'pass')" \
	"measured NOTHING"

# ---- hostkeys-are-verified (CLAUDE.md invariant 61): the host key is verified before the first connection ----
TEETH_EDIT_204="$(py 'edit("lib/hostkeys.sh", "if [ -n \"$console_fp\" ] && [ \"$console_fp\" = \"$scan_fp\" ]; then", "if true; then")')"
run_case "hostkeys-are-verified: a mismatched console fingerprint is accepted" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$TEETH_EDIT_204" \
	"B  mismatch"

run_case "stdin-is-read-once: the GCP agent name is read inside the pipeline again" fail \
	'./scripts/stdin-is-read-once.sh' \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "      --node-name \x27$AGENT_NAME\x27 \\\n", "      --node-name \x27$(node_name_of \"$n\")\x27 \\\n")')" \
	"install-gcp.sh"

run_case "stdin-is-read-once: the AWS installer no longer stops on an agent that never registers" fail \
	'./scripts/stdin-is-read-once.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "did not register with the cluster", "was not seen")')" \
	"never stops when the agent does not register"

run_case "stdin-is-read-once: the BYO installer runs a remote lookup inside the pipeline" fail \
	'./scripts/stdin-is-read-once.sh' \
	"$(py 'edit("install.sh", "      --node-name \x27$AGENT_NAME\x27 \\\n", "      --node-name \x27$(sh_ \"$n\" hostname)\x27 \\\n")')" \
	"install.sh"

run_case "stdin-is-read-once: a pure lookup in the pipeline is not a fault" pass \
	'./scripts/stdin-is-read-once.sh' \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "      --node-name \x27$AGENT_NAME\x27 \\\n", "      --node-name \x27$AGENT_NAME\x27 --node-label \x27x=$(priv_of \"$n\")\x27 \\\n")')"

run_case "stdin-is-read-once: no installer at all" fail \
	'./scripts/stdin-is-read-once.sh' \
	"$(py 'import os
for f in ["install.sh","deploy.sh","cloud/gcp/install-gcp.sh","cloud/aws/install-aws.sh","cloud/gcp/deploy-gcp.sh","cloud/aws/deploy-aws.sh"]: os.remove(f)')" \
	"measured nothing"

run_case "hostkeys-are-verified: cloud-init's syslog prefix is no longer removed" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'edit("lib/hostkeys.sh", " cloud-init: //", " cloud-init-never: //")')" \
	"D2 prefixed console"

run_case "hostkeys-are-verified: carriage returns are no longer removed" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'edit("lib/hostkeys.sh", "  tr -d \x27\\r\x27 |\n", "")')" \
	"D4 CRLF console"

run_case "hostkeys-are-verified: any program's prefix is removed" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'edit("lib/hostkeys.sh", "[0-9]{2}:[0-9]{2}:[0-9]{2} cloud-init: //", "[0-9]{2}:[0-9]{2}:[0-9]{2} [a-z-]+: //")')" \
	"D3 foreign prefix"

run_case "hostkeys-are-verified: the gcloud json shape is not read" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'edit("lib/hostkeys.sh", "        if node.get(\"namespace\") == \"hostkeys\" and", "        if False and")')" \
	"E2 gcloud json shape"

run_case "hostkeys-are-verified: GCE nodes without guest attributes" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'edit("cloud/gcp/main.tf", "    enable-guest-attributes = \"TRUE\"\n", "")')" \
	"N  cloud/gcp/main.tf sets enable-guest-attributes"

run_case "hostkeys-are-verified: a cloud launcher goes back to accept-new" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "SSH_OPTS=(-o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=20)", "SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=20)")')" \
	"still accepts host keys on first use"

TEETH_EDIT_205="$(py 'edit("install.sh", "if [ -n \"${SSH_KNOWN_HOSTS:-}\" ]; then", "if false; then")')"
run_case "hostkeys-are-verified: SSH_KNOWN_HOSTS is ignored by install.sh" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$TEETH_EDIT_205" \
	"G  SSH_KNOWN_HOSTS: first ssh was"

TEETH_EDIT_206="$(py 'edit("cloud/gcp/deploy-gcp.sh", "for n in \"${ALL_NODES[@]}\"; do\n  ssh-keygen -R", "for n in \"${ALL_NODES[@]}\"; do sh_ \"$n\" true; done\nfor n in \"${ALL_NODES[@]}\"; do\n  ssh-keygen -R")')"
run_case "hostkeys-are-verified: a cloud launcher connects before it reads the keys" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$TEETH_EDIT_206" \
	"cloud/gcp/deploy-gcp.sh: keys at line"

run_case "hostkeys-are-verified: a comment naming accept-new is not a launcher using it (must pass)" pass \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'open("cloud/aws/install-aws.sh", "a").write("# accept-new is not used here (a comment, not a launcher setting)\n")')"

run_case "hostkeys-are-verified: no cloud installer left, measured nothing" fail_env \
	'd="$(mktemp -d)" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$d" init -q && mkdir -p "$d/scripts" "$d/lib" && cp scripts/hostkeys-are-verified.sh "$d/scripts/" && cp lib/hostkeys.sh "$d/lib/" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE "$d/scripts/hostkeys-are-verified.sh"' \
	"$(py 'pass')" \
	"measured NOTHING"

# ---- node-to-node: the peer file, and no tracked script that disables host key checking (invariant 61, part 4) ----
run_case "hostkeys-are-verified: a node-to-node ssh goes back to host key checking off" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/stack-known-hosts $SSH_USER@", "-o StrictHostKeyChecking=" + "no $SSH_USER@")')" \
	"still disable host key checking"

run_case "hostkeys-are-verified: a helper names the forbidden option in a comment" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'open("lib/hostkeys.sh", "a").write("# note: StrictHostKeyChecking=" + "no is what the peer file replaced\n")')" \
	"still disable host key checking"

run_case "hostkeys-are-verified: the Hetzner distribution is strict against no file" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'edit("deploy.sh", "StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/stack-known-hosts root@\\$p", "StrictHostKeyChecking=yes root@\\$p")')" \
	"is not strict against"

run_case "hostkeys-are-verified: the distribution is strict against no file (GCP)" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/stack-known-hosts $SSH_USER@", "StrictHostKeyChecking=yes $SSH_USER@")')" \
	"is not strict against"

run_case "hostkeys-are-verified: the peer file is written after the first node-to-node ssh" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'import re
s = open("deploy.sh").read()
W = "  sh_ \"$BUILDER\" \x27umask 077; mkdir -p /root/.ssh && cat > /root/.ssh/stack-known-hosts && chmod 0600 /root/.ssh/stack-known-hosts\x27 < \"$PEERS_TMP\" \\\n    || die \"could not write /root/.ssh/stack-known-hosts on the builder: nothing was distributed\"\n"
assert s.count(W) == 1
s = s.replace(W, "", 1)
s = s.replace("\n# ---- 3. the workload", "\n" + W + "\n# ---- 3. the workload", 1)
open("deploy.sh", "w").write(s)')" \
	"is written at line"

TEETH_EDIT_207="$(py 'edit("lib/hostkeys.sh", "for name in \"$pub\" \"$priv\"; do", "for name in \"$pub\"; do")')"
run_case "hostkeys-are-verified: the peer file drops the private names" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$TEETH_EDIT_207" \
	"I  peer file"

TEETH_EDIT_208="$(py 'edit("cloud/aws/deploy-aws.sh", "hostkeys_peer_file \"$PEERS_TMP\"", "true \"$PEERS_TMP\"")')"
run_case "hostkeys-are-verified: a launcher builds no peer file" fail \
	'./scripts/hostkeys-are-verified.sh' \
	"$TEETH_EDIT_208" \
	"does not build its peer file"

run_case "hostkeys-are-verified: the option named in a prose note is not a script (must pass)" pass \
	'./scripts/hostkeys-are-verified.sh' \
	"$(py 'open("GOTCHAS.md", "a").write("\nNote: StrictHostKeyChecking=" + "no was the old setting of the image distribution.\n")')"

# A listing is not a run. Stop before the verdict, which would count cases this
# ---- scopyx-reads-go-through-the-broker (CLAUDE.md invariant 78, G2.1) ----
# A read of the web passes the MCP broker, which labels the run from the act, and nothing else reaches scopyx.
G21='./scripts/scopyx-reads-go-through-the-broker.sh'

run_case "scopyx-broker: the broker's upstream list loses scopyx" fail \
	"$G21" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "value: \"typryx=http://typryx:4320/mcp,scopyx=http://scopyx:4300\"", "value: \"typryx=http://typryx:4320/mcp\"")')" \
	"does not name scopyx=http://scopyx:4300"

run_case "scopyx-broker: the broker stops labelling scopyx" fail \
	"$G21" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "            - { name: TOKENFUSE_MCP_UPSTREAM_LABELS, value: \"scopyx=web\" }\n", "")')" \
	"TOKENFUSE_MCP_UPSTREAM_LABELS is not exactly scopyx=web"

run_case "scopyx-broker: scopyx is labelled as something else" fail \
	"$G21" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "value: \"scopyx=web\"", "value: \"scopyx=search\"")')" \
	"TOKENFUSE_MCP_UPSTREAM_LABELS is not exactly scopyx=web"

run_case "scopyx-broker: the broker loses its taint gateway" fail \
	"$G21" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "name: TOKENFUSE_MCP_TAINT_GATEWAY, value: \"http://tokenfuse-gateway:4100\"", "name: TOKENFUSE_MCP_TAINT_GATEWAY, value: \"\"")')" \
	"exits 2 on a classification with no taint gateway"

run_case "scopyx-broker: a vault entry with no rule no longer stops the broker" fail \
	"$G21" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "TOKENFUSE_MCP_REQUIRE_SECRET_SCOPES, value: \"1\"", "TOKENFUSE_MCP_REQUIRE_SECRET_SCOPES, value: \"0\"")')" \
	"TOKENFUSE_MCP_REQUIRE_SECRET_SCOPES is not 1"

run_case "scopyx-broker: the scopes are an env value of the Deployment again" fail \
	"$G21" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "            - { name: TOKENFUSE_MCP_REQUIRE_SECRET_SCOPES, value: \"1\" }\n", "            - { name: TOKENFUSE_MCP_REQUIRE_SECRET_SCOPES, value: \"1\" }\n            - { name: TOKENFUSE_MCP_SECRET_SCOPES, value: \"typryx_key=tools:ask\" }\n")')" \
	"shadows the Secret"

run_case "scopyx-broker: the broker cannot reach scopyx" fail \
	"$G21" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "  name: broker-egress-scopyx\n", "  name: broker-egress-nothing\n")')" \
	"no NetworkPolicy broker-egress-scopyx"

run_case "scopyx-broker: the broker reaches scopyx on another port" fail \
	"$G21" \
	"$(py 'import re
p = "manifests/52-tokenfuse-mcp-broker.yaml"; s = open(p).read()
i = s.index("  name: broker-egress-scopyx\n"); j = s.index("port: 4300", i)
open(p, "w").write(s[:j] + "port: 4301" + s[j + len("port: 4300"):])')" \
	"not scopyx on 4300 alone"

run_case "scopyx-broker: scopyx stops taking the key in the call" fail \
	"$G21" \
	"$(py 'edit("manifests/47-scopyx.yaml", "            - { name: SCOPYX_ACCEPT_KEY_IN_META, value: \"1\" }\n", "")')" \
	"manifests/47: scopyx does not take the key in params._meta"

run_case "scopyx-broker: the browser stops taking the key in the call" fail \
	"$G21" \
	"$(py 'edit("manifests/48-scopyx-browser.yaml", "            - { name: SCOPYX_ACCEPT_KEY_IN_META, value: \"1\" }\n", "")')" \
	"manifests/48: scopyx does not take the key in params._meta"

run_case "scopyx-broker: the money plane reaches scopyx again" fail \
	"$G21" \
	"$(py 'edit("manifests/47-scopyx.yaml", "        - podSelector: { matchLabels: { app: tokenfuse-mcp-broker } }\n      ports:\n        - { protocol: TCP, port: 4300 }", "        - podSelector: { matchLabels: { app: tokenfuse-mcp-broker } }\n        - podSelector: { matchLabels: { plane: money } }\n      ports:\n        - { protocol: TCP, port: 4300 }")')" \
	"not the MCP broker alone"

run_case "scopyx-broker: the console reaches scopyx again" fail \
	"$G21" \
	"$(py 'edit("manifests/47-scopyx.yaml", "        - podSelector: { matchLabels: { app: tokenfuse-mcp-broker } }\n      ports:\n        - { protocol: TCP, port: 4300 }", "        - podSelector: { matchLabels: { plane: console } }\n      ports:\n        - { protocol: TCP, port: 4300 }")')" \
	"not the MCP broker alone"

run_case "scopyx-broker: an agent pod cannot reach the broker" fail \
	"$G21" \
	"$(py 'edit("manifests/58-agent-tokens-network.yaml", "        - podSelector: { matchLabels: { app: tokenfuse-mcp-broker } }\n      ports:\n        - { protocol: TCP, port: 4200 }\n---\napiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata:\n  name: vouchryx-ingress-agent-token-pods", "        - podSelector: { matchLabels: { app: tokenfuse-gateway } }\n      ports:\n        - { protocol: TCP, port: 4100 }\n---\napiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata:\n  name: vouchryx-ingress-agent-token-pods")')" \
	"does not let an agent pod reach the broker on 4200"

run_case "scopyx-broker: the broker does not admit an agent pod" fail \
	"$G21" \
	"$(py 'edit("manifests/58-agent-tokens-network.yaml", "  name: broker-ingress-agent-token-pods\n", "  name: broker-ingress-nobody\n")')" \
	"no NetworkPolicy broker-ingress-agent-token-pods"

run_case "scopyx-broker: another policy lets a pod reach scopyx" fail \
	"$G21" \
	"$(py 'p = "manifests/30-network-policy.yaml"; s = open(p).read(); open(p, "w").write(s + "\n---\napiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata:\n  name: probe-to-scopyx\n  namespace: agent-stack\nspec:\n  podSelector: { matchLabels: { app: some-agent } }\n  policyTypes: [\"Egress\"]\n  egress:\n    - to:\n        - podSelector: { matchLabels: { app: scopyx } }\n      ports:\n        - { protocol: TCP, port: 4300 }\n")')" \
	"only the broker may"

run_case "scopyx-broker: the broker is gone, so nothing was measured" fail \
	"$G21" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "kind: Deployment\nmetadata:\n  name: tokenfuse-mcp-broker\n", "kind: Deployment\nmetadata:\n  name: tokenfuse-mcp-gone\n")')" \
	"measured NOTHING"

run_case "scopyx-broker: a reworded comment is not a fault" pass \
	"$G21" \
	"$(py 'edit("manifests/47-scopyx.yaml", "# The MCP broker, and nothing else (G2.1).", "# The MCP broker alone (G2.1).")')" \
	""

run_case "typed-door-is-minted: the broker Secret made with no scope rule" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("typed/mode.sh", "\"TOKENFUSE_MCP_SECRETS=typryx_key=$bearer\" \"TOKENFUSE_MCP_SECRET_SCOPES=$DOOR_SCOPES\"\n    made=\"$DOOR_TYPRYX (identity", "\"TOKENFUSE_MCP_SECRETS=typryx_key=$bearer\"\n    made=\"$DOOR_TYPRYX (identity")')" \
	"tokenfuse-mcp-broker-keys carries"

# CLAUDE.md invariant 81. Under pipefail a pipe into grep -q fails when the writer is still writing, so a
# healthy tree went red at random on a loaded machine. The first cases plant the construct where it
# lived; the middle ones are what must not be flagged; the last ones break the gate itself, because a
# reader that has stopped matching reports what a clean tree reports.

run_case "no-reader-leaves-a-pipe-early: a gate pipes its text into grep -q again" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("scripts/costcrew-ceiling-is-set.sh", "if ! grep -qE -- \x27--costcrew-ceiling\\)\x27 <<<\"$live\"; then", "if ! printf \x27%s\\n\x27 \"$live\" | grep -qE -- \x27--costcrew-ceiling\\)\x27; then")')" \
	'scripts/costcrew-ceiling-is-set.sh:'

run_case "no-reader-leaves-a-pipe-early: the pipe is carried over a line" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("verify.sh", "grep -q FAIL <<<\"$out\" && bad", "printf \x27%s\\n\x27 \"$out\" \\\n  | grep -q FAIL && bad")')" \
	'verify.sh:'

run_case "no-reader-leaves-a-pipe-early: a sourced library reads through the pipe" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("lib/keyryx-install.sh", "grep -q \x27 running$\x27 <<<\"$left\" || break", "printf \x27%s\\n\x27 \"$left\" | grep -q \x27 running$\x27 || break")')" \
	'lib/keyryx-install.sh:'

run_case "no-reader-leaves-a-pipe-early: a workflow step reads through the pipe" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit(".github/workflows/gates.yml", "grep -q \x27: go1\\.27\\.4$\x27 <<<\"$(printf \x27%s\\n\x27 \"$info\" | head -1)\"", "printf \x27%s\\n\x27 \"$info\" | head -1 | grep -q \x27: go1\\.27\\.4$\x27")')" \
	'.github/workflows/gates.yml:'

run_case "no-reader-leaves-a-pipe-early: the words are only in a comment" pass \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("verify.sh", "#!/usr/bin/env bash\n", "#!/usr/bin/env bash\n# printf x | grep -q x\n")')"

run_case "no-reader-leaves-a-pipe-early: the words are a command handed to another shell" pass \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("verify.sh", "#!/usr/bin/env bash\n", "#!/usr/bin/env bash\nsh -c \"printf x | grep -q x\"\n")')"

run_case "no-reader-leaves-a-pipe-early: the words are in a here-document" pass \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("verify.sh", "#!/usr/bin/env bash\n", "#!/usr/bin/env bash\ncat <<\x27EOF\x27\nprintf x | grep -q x\nEOF\n")')"

run_case "no-reader-leaves-a-pipe-early: grep -c reads to the end of a pipe" pass \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("verify.sh", "#!/usr/bin/env bash\n", "#!/usr/bin/env bash\nprintf x | grep -c x >/dev/null\n")')"

run_case "no-reader-leaves-a-pipe-early: a here-string has no pipe to leave" pass \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("verify.sh", "#!/usr/bin/env bash\n", "#!/usr/bin/env bash\ngrep -q x <<<x\n")')"

run_case "no-reader-leaves-a-pipe-early: a substitution in quotes reads through the pipe" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("verify.sh", "#!/usr/bin/env bash\n", "#!/usr/bin/env bash\nx=\"$(printf y | grep -m1 y)\"\n")')" \
	'verify.sh:2 pipes into `grep -m1`'

run_case "no-reader-leaves-a-pipe-early: a long option leaves as early as a short one" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("verify.sh", "#!/usr/bin/env bash\n", "#!/usr/bin/env bash\nprintf y | grep --quiet y\n")')" \
	'verify.sh:2 pipes into `grep --quiet`'

run_case "no-reader-leaves-a-pipe-early: a quote left open loses the reader its place" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 's = open("verify.sh").read()
open("verify.sh", "w").write(s + "echo \"open\n")')" \
	'lost its place'

run_case "no-reader-leaves-a-pipe-early: the reader stops knowing -q" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("scripts/no-reader-leaves-a-pipe-early.sh", "if ch in \"qmlL\":", "if ch in \"mlL\":")')" \
	'the reader missed'

run_case "no-reader-leaves-a-pipe-early: the reader stops reporting what it finds" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("scripts/no-reader-leaves-a-pipe-early.sh", "found.append((m.start(), flag))", "pass")')" \
	'the reader missed'

run_case "no-reader-leaves-a-pipe-early: the reader starts reading quoted text" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("scripts/no-reader-leaves-a-pipe-early.sh", "blank(i, end + 1)", "pass")')" \
	'the reader flagged'

run_case "no-reader-leaves-a-pipe-early: the control writes less than a pipe holds" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("scripts/no-reader-leaves-a-pipe-early.sh", "WRITER = \"seq 1 400000\"", "WRITER = \"seq 1 3\"")')" \
	'it must fail every time'

run_case "no-reader-leaves-a-pipe-early: no pipe is read" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("scripts/no-reader-leaves-a-pipe-early.sh", "pipes += len(PIPE.findall(masked))", "pipes += 0")')" \
	'measured NOTHING'

run_case "no-reader-leaves-a-pipe-early: no shell file is read" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("scripts/no-reader-leaves-a-pipe-early.sh", "if path.endswith(\".sh\") or path.startswith(\".githooks/\") or (first.startswith(\"#!\") and \"bash\" in first):", "if False:")')" \
	'measured NOTHING'

run_case "no-reader-leaves-a-pipe-early: no workflow step is read" fail \
	'./scripts/no-reader-leaves-a-pipe-early.sh' \
	"$(py 'edit("scripts/no-reader-leaves-a-pipe-early.sh", "elif path.startswith(\".github/workflows/\") and", "elif path.startswith(\".github/flows/\") and")')" \
	'measured NOTHING'

# A tool call nothing grants waits for a person, and a cluster with a history is asked first (CLAUDE.md invariant 83).
run_case "tool-hold-is-seeded: the block is never written" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("deploy.sh", "\ntool_hold_settle\n", "\n")')" \
	"never calls tool_hold_settle"
run_case "tool-hold-is-seeded: a cloud launcher never writes the block" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "\ntool_hold_settle\n", "\n")')" \
	"never calls tool_hold_settle"
run_case "tool-hold-is-seeded: the floor narrows to agent ids with a scheme" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "    \x27  target: \"*\"\x27 \\\n", "    \x27  target: \"agent://*\"\x27 \\\n")')" \
	"walks past it"
run_case "tool-hold-is-seeded: the floor is written as a word wardryx refuses" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "\x27  when_no_grant: hold\x27", "\x27  when_no_grant: holds\x27")')" \
	"does not say when_no_grant: hold"
run_case "tool-hold-is-seeded: a seed grants every agent" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "\x27  target: agent://mockryx.local/*\x27", "\x27  target: \"*\"\x27")')" \
	"grant-drills is not every tool"
run_case "tool-hold-is-seeded: the drills lose their seed" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "    \x27- name: grant-drills\x27 \\\n    \x27  target: agent://mockryx.local/*\x27 \\\n    \x27  grant_tool: [\"*\"]\x27 \\\n", "")')" \
	"grant-drills is not every tool"
run_case "tool-hold-is-seeded: the install-check seed is gone" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "    \x27  when_no_grant: hold\x27 \\\n    \x27- name: grant-drills\x27 \\\n    \x27  target: agent://mockryx.local/*\x27 \\\n    \x27  grant_tool: [\"*\"]\x27 \\\n    \x27- name: grant-install-check\x27 \\\n    \x27  target: agent://local.invalid/install-check\x27 \\\n    \x27  grant_tool: [ask]\x27 \\\n    \x27  require_identity_source: [client-key]\x27 \\\n    \x27  deny_if_chain_unproven: true\x27\n", "    \x27  when_no_grant: hold\x27 \\\n    \x27- name: grant-drills\x27 \\\n    \x27  target: agent://mockryx.local/*\x27 \\\n    \x27  grant_tool: [\"*\"]\x27\n")')" \
	"grant-install-check is not ask"
run_case "tool-hold-is-seeded: the install-check seed asks for an agent token" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "\x27  require_identity_source: [client-key]\x27", "\x27  require_identity_source: [agent-token]\x27")')" \
	"grant-install-check is not ask"
run_case "tool-hold-is-seeded: the web grant denies scopyx's question" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "*) printf \x27agent-token, none\x27 ;;", "*) printf \x27agent-token\x27 ;;")')" \
	"grant-operator-web is not fetch_url"
run_case "tool-hold-is-seeded: the web grant lets a static key borrow the name" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "*) printf \x27agent-token, none\x27 ;;", "*) printf \x27agent-token, client-key, none\x27 ;;")')" \
	"grant-operator-web is not fetch_url"
run_case "tool-hold-is-seeded: the web grant is on every cluster" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "  [ -n \"$(k_ \"-n agent-stack get deployment scopyx --ignore-not-found -o name\" 2>/dev/null || true)\" ]\n", "  true\n")')" \
	"the web grant is on a cluster with no scopyx"
run_case "tool-hold-is-seeded: felyx gets a grant it does not need" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "\x27  deny_if_chain_unproven: true\x27\n  if tool_hold_web_wanted", "\x27  deny_if_chain_unproven: true\x27 \\\n    \x27- name: grant-felyx\x27 \\\n    \x27  target: agent://acme.example/genaryx/felyx\x27 \\\n    \x27  grant_tool: [ask]\x27\n  if tool_hold_web_wanted")')" \
	"the block has rules other than"
run_case "tool-hold-is-seeded: TOOL_HOLD=0 leaves the block" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "tool_hold_empty_document | k_ \"apply -f -\"", "tool_hold_block | tool_hold_document | k_ \"apply -f -\"")')" \
	"TOOL_HOLD=0 leaves the block"
run_case "tool-hold-is-seeded: TOOL_HOLD=0 keeps serving the block" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "    if [ \"$TOOL_HOLD_STATE\" = on ]; then\n      k_ \"-n agent-stack rollout restart", "    if false; then\n      k_ \"-n agent-stack rollout restart")')" \
	"wardryx kept serving it"
run_case "tool-hold-is-seeded: a cluster that said 0 is asked again" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "*) if [ \"$TOOL_HOLD_STATE\" = off ]; then TOOL_HOLD_ON=0; else TOOL_HOLD_ON=1; fi ;;", "*) TOOL_HOLD_ON=1 ;;")')" \
	"a cluster that said 0"
run_case "tool-hold-is-seeded: a misspelt switch reaches the cluster" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "    \x27\x27 | 0 | 1) return 0 ;;\n", "    x) return 0 ;;\n    *) return 0 ;;\n")')" \
	"--tool-hold took the word"
run_case "tool-hold-is-seeded: a launcher takes no switch" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "    --tool-hold) TOOL_HOLD=\"$2\"; shift 2 ;;\n", "")')" \
	"does not parse --tool-hold"
run_case "tool-hold-is-seeded: the block moves on every run" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "  if [ \"$TOOL_HOLD_STATE\" != absent ] && [ \"$(tool_hold_current)\" = \"$want\" ]; then return 0; fi\n", "")')" \
	"a second run wrote something"
run_case "tool-hold-is-seeded: a changed block does not restart wardryx" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "  k_ \"-n agent-stack rollout restart deployment/wardryx\" >/dev/null \\\n    || die \"could not restart wardryx to load the tool hold\"\n", "")')" \
	"wardryx not restarted"
run_case "tool-hold-is-seeded: the replay check is gone" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("deploy.sh", "\ntool_hold_guard      # CLAUDE.md", "\n# tool_hold_guard      # CLAUDE.md")')" \
	"never calls tool_hold_guard"
run_case "tool-hold-is-seeded: the lib no longer asks" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "  [ -n \"$(k_ \"-n agent-stack get deployment wardryx --ignore-not-found -o name\")\" ] || return 0\n", "  return 0\n")')" \
	"the replay check is gone"
run_case "tool-hold-is-seeded: the question comes after the apply" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'p = "deploy.sh"; s = open(p).read(); g = s[s.index("tool_hold_guard      #"):]; g = g[:g.index("\n") + 1]; a = "k_ \"apply -k /root/stack-k8s/manifests\"\n"; assert a in s; s = s.replace(g, "", 1).replace(a, a + g, 1); open(p, "w").write(s)')" \
	"asks the question after the first apply"
run_case "tool-hold-is-seeded: the question leaves its Job behind" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "2>\"$d/report.err\" || true\n  tool_hold_ask_clear\n", "2>\"$d/report.err\" || true\n")')" \
	"leaves its Job or its ConfigMap behind"
run_case "tool-hold-is-seeded: the question leaves the seeds out" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "  tool_hold_block | sed \x27s/^/    /\x27\n", "  printf \x27    - name: tool-hold\\n      target: \"*\"\\n      when_no_grant: hold\\n\x27\n")')" \
	"the question leaves the seeds out"
run_case "tool-hold-is-seeded: the question leaves the starter policy out" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "       on && !/^    / && !/^$/ \x7b exit \x7d\n", "       on && /deny-shell-exec/ \x7b exit \x7d\n")')" \
	"stops short of the starter policy"
run_case "tool-hold-is-seeded: unexamined decisions read as nothing to hold" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "if [ -z \"$rows\" ] && [ \"$unexamined\" = 0 ]; then", "if [ -z \"$rows\" ]; then")')" \
	"unexamined decisions read as nothing to hold"
run_case "tool-hold-is-seeded: a question nobody answered passes" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "  if tool_hold_ask \"$d\"; then\n    rows=", "  tool_hold_ask \"$d\" || return 0\n  if true; then\n    rows=")')" \
	"a Job that left no report passed the question"
run_case "tool-hold-is-seeded: a hostile id is printed to paste" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "      left=$((left + 1))\n      continue\n", "      left=$((left + 1))\n")')" \
	"a hostile id is printed to paste"
run_case "tool-hold-is-seeded: the store is left out of the question" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "if [ -n \"$stored\" ] && [ \"$stored\" != \"[]\" ]; then", "if false; then")')" \
	"what agent-allow wrote is not in the question"
run_case "tool-hold-is-seeded: an empty store breaks the question" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "if [ -n \"$stored\" ] && [ \"$stored\" != \"[]\" ]; then", "if [ -n \"$stored\" ]; then")')" \
	"an empty store went in as a file"
run_case "tool-hold-is-seeded: the Job can write the events it reads" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "mountPath: /var/lib/stack/events, readOnly: true", "mountPath: /var/lib/stack/events")')" \
	"can write the events it reads"
run_case "tool-hold-is-seeded: what wardryx loaded is looked for under the 2.6.0 record" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "grep -F \x27wardryx: policy set loaded \x27", "grep -F \x27\"policy_loaded\"\x27")')" \
	"does not read on from its own start line"
run_case "tool-hold-is-seeded: TOOL_HOLD=1 does not answer the list" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "  if [ \"$TOOL_HOLD_SAID\" = 1 ]; then\n", "  if false; then\n")')" \
	"TOOL_HOLD=1 does not turn the hold on"
run_case "tool-hold-is-seeded: the question runs another image" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "  image=\"$(tool_hold_image)\"\n", "  image=\"ghcr.io/taipanbox/wardryx:v2.5.1@sha256:2d3c0c9c0798156d3f05b82d0e63cf5b38ee4b9875d6bdbac1829f219c26abf7\"\n")')" \
	"written down a second time"
run_case "tool-hold-is-seeded: the pin goes below 2.6.0" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'import re; p = "manifests/10-planes.yaml"; s = open(p).read(); s, n = re.subn(r"wardryx:v\d+\.\d+\.\d+@sha256", "wardryx:v2.5.1@sha256", s); assert n == 1, n; open(p, "w").write(s)')" \
	"older than 2.6.0"
run_case "tool-hold-is-seeded: wardryx does not read the ConfigMap" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "              - configMap: \x7b name: wardryx-tool-hold, optional: true \x7d\n", "")')" \
	"does not project the ConfigMap wardryx-tool-hold"
run_case "tool-hold-is-seeded: the ConfigMap is required" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "wardryx-tool-hold, optional: true \x7d", "wardryx-tool-hold \x7d")')" \
	"does not project the ConfigMap wardryx-tool-hold"
run_case "tool-hold-is-seeded: a plain apply installs the floor" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("manifests/00-base.yaml", "  name: wardryx-policy\n", "  name: wardryx-tool-hold\n")')" \
	"carries the floor"
run_case "tool-hold-is-seeded: the console no longer holds the admin key" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("manifests/20-console.yaml", "- name: WARDRYX_ADMIN_KEY\n", "- name: WARDRYX_ADMIN_KEYS\n")')" \
	"does not hold WARDRYX_ADMIN_KEY"
run_case "tool-hold-is-seeded: the admin key goes on a command line" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "-c console -- python3 - $*\"", "-c console -- env WARDRYX_ADMIN_KEY=$(k_ \"-n agent-stack get secret stack-keys\") python3 - $*\"")')" \
	"the admin key reached a kubectl argument list"
run_case "tool-hold-is-seeded: agent-allow goes on with no reason" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("tool-hold/agents.sh", "  why_ok \"$why\" \\\n    || die", "  true \\\n    || die")')" \
	"went on with no --why"
run_case "tool-hold-is-seeded: agent-allow takes a target with no trust domain" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("tool-hold/agents.sh", "[[ \"$agent\" =~ ^agent://[A-Za-z0-9._~-]+(:[0-9]+)?(/[A-Za-z0-9._~:/*-]*)?$ ]]", "[[ \"$agent\" =~ .+ ]]")')" \
	"agent-allow took"
run_case "tool-hold-is-seeded: a second grant replaces the first" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("tool-hold/wardryx.py", "tools = sorted(set(kept) | set(tools))", "tools = sorted(set(tools))")')" \
	"a second grant keeps the first"
run_case "tool-hold-is-seeded: a grant is written under a key wardryx refuses" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("tool-hold/wardryx.py", "\"grant_tool\": tools\x7d", "\"grant_tools\": tools\x7d")')" \
	"agent-allow was refused"
run_case "tool-hold-is-seeded: all gives no warning" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("tool-hold/agents.sh", "    if [ \"$granted\" = \x27*\x27 ]; then\n", "    if false; then\n")')" \
	"prints no warning"
run_case "tool-hold-is-seeded: a scenario names a case that is not there" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("features/a-tool-call-nothing-grants-waits-for-a-person.feature", "tool-hold-is-seeded: a hostile id is printed to paste", "tool-hold-is-seeded: a hostile id is shown to paste")')" \
	"a scenario names a case that does not exist"
run_case "tool-hold-is-seeded: no block measured nothing" fail \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("lib/tool-hold.sh", "tool_hold_block() \x7b\n", "tool_hold_blocks() \x7b\n")')" \
	"measured NOTHING"
run_case "tool-hold-is-seeded: a comment that names the hold is not a fault" pass \
	'./scripts/tool-hold-is-seeded.sh' \
	"$(py 'edit("deploy.sh", "# ---- 1. the cluster ---", "# The tool hold is written by tool_hold_settle, further down.\n# ---- 1. the cluster ---")')"

# invariant 84: Chromium keeps its own sandbox on a cluster, under the filter stack-single runs, in
# the form a node reads, which every installer writes to every node before k3s starts there. Every
# brace in these blocks is \x7b or \x7d and every single quote \x27, for the reason in the head.
BKS='./scripts/browser-keeps-its-sandbox.sh'
run_case "browser-keeps-its-sandbox: the sandbox is turned off again" fail \
	"$BKS" \
	"$(py 'edit("manifests/48-scopyx-browser.yaml", "            - \x7b name: SCOPYX_BACKEND, value: \"chromium\" \x7d\n", "            - \x7b name: SCOPYX_BACKEND, value: \"chromium\" \x7d\n            - \x7b name: SCOPYX_CHROMIUM_NO_SANDBOX, value: \"1\" \x7d\n")')" \
	"turns Chromium's sandbox off"
run_case "browser-keeps-its-sandbox: the browser falls back to the runtime's filter" fail \
	"$BKS" \
	"$(py 'edit("manifests/48-scopyx-browser.yaml", "seccompProfile: \x7b type: Localhost, localhostProfile: taipanbox/chromium-v1.json \x7d", "seccompProfile: \x7b type: RuntimeDefault \x7d")')" \
	"not Localhost"
run_case "browser-keeps-its-sandbox: the browser is left unconfined" fail \
	"$BKS" \
	"$(py 'edit("manifests/48-scopyx-browser.yaml", "        seccompProfile: \x7b type: RuntimeDefault \x7d\n", "        seccompProfile: \x7b type: Unconfined \x7d\n")')" \
	"is Unconfined"
run_case "browser-keeps-its-sandbox: the manifest names a profile nobody writes" fail \
	"$BKS" \
	"$(py 'edit("manifests/48-scopyx-browser.yaml", "localhostProfile: taipanbox/chromium-v1.json", "localhostProfile: taipanbox/chromium-v2.json")')" \
	"the profile the installers write"
run_case "browser-keeps-its-sandbox: the node file is Docker's format" fail \
	"$BKS" \
	"$(py 'open("seccomp/chromium-v1.json", "w").write(open("seccomp/chromium-v1.docker.json").read())')" \
	"Docker's own keys"
run_case "browser-keeps-its-sandbox: clone loses its mask" fail \
	"$BKS" \
	"$(py 'edit("seccomp/chromium-v1.json", "\"value\": 235012096,", "\"value\": 0,")')" \
	"clone is not held to the mask"
run_case "browser-keeps-its-sandbox: stack-single's file differs" fail \
	"$BKS" \
	"$(py 'edit("seccomp/chromium-v1.docker.json", "the zygote starts in its own", "the zygote now starts in its own")')" \
	"not stack-single's chromium-v1.json byte for byte"
run_case "browser-keeps-its-sandbox: the profile changes and keeps its name" fail \
	"$BKS" \
	"$(py 'import subprocess, sys
edit("seccomp/resolve.py", "json.dumps(profile, indent=2)", "json.dumps(profile, indent=1)")
out = subprocess.run([sys.executable, "-I", "seccomp/resolve.py", "seccomp/chromium-v1.docker.json"], capture_output=True, text=True, check=True).stdout
open("seccomp/chromium-v1.json", "w").write(out)')" \
	"changed and kept its name"
run_case "browser-keeps-its-sandbox: mount is allowed without a condition" fail \
	"$BKS" \
	"$(py 'import hashlib, json
p = json.load(open("seccomp/chromium-v1.json"))
p["syscalls"][0]["names"].append("mount")
body = json.dumps(p, indent=2) + "\n"
open("seccomp/chromium-v1.json", "w").write(body)
new = hashlib.sha256(body.encode()).hexdigest()
edit("scripts/browser-keeps-its-sandbox.sh", "NODE_SHA = \"cc2644c8fd5c4dad925d4ead48f33aa681dc5555ef97b3ec616436d76c50a153\"", "NODE_SHA = \"" + new + "\"")')" \
	"allows ['mount'] without a condition"
run_case "browser-keeps-its-sandbox: an installer leaves its agents without the profile" fail \
	"$BKS" \
	"$(py 'p = "cloud/aws/install-aws.sh"
s = open(p).read().split("\n")
i = [k for k, l in enumerate(s) if ("sh -s - ag" + "ent") in l][0]
j = [k for k in range(i - 3, i) if "browser_seccomp_put" in s[k]]
assert j, "no profile write above the agent install"
del s[j[0]]
open(p, "w").write("\n".join(s))')" \
	"without writing the browser's profile onto it just above"
run_case "browser-keeps-its-sandbox: an installer writes the profile after k3s starts" fail \
	"$BKS" \
	"$(py 'line = "browser_seccomp_put sh_ \"$FIRST\" || die \"could not write the browser\x27s seccomp profile on $FIRST\"\n"
edit("install.sh", line, "")
p = "install.sh"
open(p, "a").write(line)')" \
	"installs k3s on \"\$FIRST\" without writing the browser's profile"
run_case "browser-keeps-its-sandbox: an installer goes on when the write fails" fail \
	"$BKS" \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "browser_seccomp_put su_ \"$FIRST\" || die \"could not write the browser\x27s seccomp profile on $FIRST\"\n", "browser_seccomp_put su_ \"$FIRST\" || true\n")')" \
	"stopping if it cannot"
run_case "browser-keeps-its-sandbox: the nodes are sent Docker's file" fail \
	"$BKS" \
	"$(py 'edit("lib/browser-seccomp.sh", "/seccomp/chromium-v1.json\"\n", "/seccomp/chromium-v1.docker.json\"\n")')" \
	"not seccomp/chromium-v1.json, the profile resolved for a node"
run_case "browser-keeps-its-sandbox: the profile lands outside the kubelet's directory" fail \
	"$BKS" \
	"$(py 'edit("lib/browser-seccomp.sh", "BROWSER_SECCOMP_ROOT=/var/lib/kubelet/seccomp\n", "BROWSER_SECCOMP_ROOT=/etc/kubernetes/seccomp\n")')" \
	"not the kubelet's seccomp root"
run_case "browser-keeps-its-sandbox: a recorded run failed" fail \
	"$BKS" \
	"$(py 'edit("evidence/browser-sandbox-k3s/output-ubuntu-26.04-amd64.txt", "\nRUN_EXIT=0", "\nRUN_EXIT=1")')" \
	"did not end RUN_EXIT=0"
run_case "browser-keeps-its-sandbox: no manifest runs the browser" fail \
	"$BKS" \
	"$(py 'edit("manifests/48-scopyx-browser.yaml", "-chromium@sha256:", "@sha256:")')" \
	"measured NOTHING"
run_case "browser-keeps-its-sandbox: a comment naming the switch" pass \
	"$BKS" \
	"$(py 'edit("manifests/48-scopyx-browser.yaml", "            - \x7b name: SCOPYX_BACKEND, value: \"chromium\" \x7d\n", "            - \x7b name: SCOPYX_BACKEND, value: \"chromium\" \x7d\n            # SCOPYX_CHROMIUM_NO_SANDBOX=1 is what this file set until 2026-11-08.\n")')"

# ---- broker-drills-pass (CLAUDE.md invariant 85): the drills reach the MCP broker with a key of their own,
# the broker's two static callers are gateway keys too, and the broker drills pass against the pinned images.
BDP=./scripts/broker-drills-pass.sh
run_case "broker-drills-pass: drills-broker leaves the gateway's list" fail \
	"$BDP" \
	"$(py 'edit("manifests/10-planes.yaml", "value: \"felyx,agents,drills,costcrew,broker,drills-broker,broker-caller\" }", "value: \"felyx,agents,drills,costcrew,broker,broker-caller\" }")')" \
	"does not name drills-broker: the broker asks the gateway"
run_case "broker-drills-pass: broker-caller leaves the gateway's list (the typed door refused at the tool-call check)" fail \
	"$BDP" \
	"$(py 'edit("manifests/10-planes.yaml", "value: \"felyx,agents,drills,costcrew,broker,drills-broker,broker-caller\" }", "value: \"felyx,agents,drills,costcrew,broker,drills-broker\" }")')" \
	"does not name broker-caller: the broker asks the gateway"
run_case "broker-drills-pass: the broker stops admitting drills-broker" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "value: \"broker-caller,drills-broker\" }", "value: \"broker-caller\" }")')" \
	"does not name drills-broker, so the broker refuses it"
run_case "broker-drills-pass: the CronJob runs the gateway drills" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\"http://tokenfuse-gateway:4100\", \"/scenarios/mcp\"]", "\"http://tokenfuse-gateway:4100\", \"/scenarios\"]")')" \
	"not \`run ... /scenarios/mcp\`"
run_case "broker-drills-pass: the drill reads its key from a path nothing mounts" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "value: \"/run/drills-broker/broker_key\" }", "value: \"/run/drills/broker_key\" }")')" \
	"mockryx would read no key"
run_case "broker-drills-pass: the CronJob falls back to a mockryx with no broker key" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "mockryx:v0.5.1@sha256:", "mockryx:v0.4.0@sha256:")')" \
	"older than v0.5.0"
run_case "broker-drills-pass: the broker admits the gateway drills' pod" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "        - podSelector: \x7b matchLabels: \x7b role: drills-broker \x7d \x7d\n      ports:\n        - \x7b protocol: TCP, port: 4200 \x7d\n", "        - podSelector: \x7b matchLabels: \x7b role: drills-broker \x7d \x7d\n        - podSelector: \x7b matchLabels: \x7b role: drills \x7d \x7d\n      ports:\n        - \x7b protocol: TCP, port: 4200 \x7d\n")')" \
	"admits the gateway drills"
run_case "broker-drills-pass: the drill pod may reach the gateway too" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "      ports:\n        - \x7b protocol: TCP, port: 4200 \x7d\n---\n# The broker\x27s half", "      ports:\n        - \x7b protocol: TCP, port: 4200 \x7d\n        - \x7b protocol: TCP, port: 4100 \x7d\n---\n# The broker\x27s half")')" \
	"to the broker on 4200 and nowhere else"
run_case "broker-drills-pass: a launcher asks the operator's keys after the first apply" fail \
	"$BDP" \
	"$(py 's = open("deploy.sh").read()
g = "identity_mint_guard  # CLAUDE.md invariant 85: the operator\x27s own client keys must hold drills-broker and broker-caller first\n"
assert g in s
s = s.replace(g, "")
a = "static_keys_settle\n"
assert a in s
open("deploy.sh", "w").write(s.replace(a, a + g, 1))')" \
	"deploy.sh does not call identity_mint_guard before its first apply"
run_case "broker-drills-pass: a launcher never keeps a kept broker Secret in step" fail \
	"$BDP" \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "\"$ROOT/typed/mode.sh\" door-callers", "\"$ROOT/typed/mode.sh\" door-secrets --check")')" \
	"cloud/aws/deploy-aws.sh does not call typed/mode.sh door-callers"
run_case "broker-drills-pass: the CronJob is gone" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "kind: CronJob\nmetadata:\n  name: drills-broker\n", "kind: CronJob\nmetadata:\n  name: drills-for-the-broker\n")')" \
	"measure NOTHING"
run_case "broker-drills-pass: a comment naming the gateway drills beside the broker's ingress" pass \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "  name: broker-ingress-drills\n  namespace: agent-stack\nspec:\n", "  name: broker-ingress-drills\n  namespace: agent-stack\nspec:\n  # never { role: drills }, the gateway drills\x27 pod\n")')"
run_case "broker-drills-pass: the CronJob loses this cluster's tool-hold drill" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "                - \x7b name: scenarios, mountPath: /scenarios/mcp/mcp-ungranted-tool-held.yaml, subPath: mcp-ungranted-tool-held.yaml, readOnly: true \x7d\n", "")')" \
	"mounts nothing read only over /scenarios/mcp/mcp-ungranted-tool-held.yaml"
run_case "broker-drills-pass: the ConfigMap with this cluster's drill is gone" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "kind: ConfigMap\nmetadata:\n  name: drills-broker-scenarios\n", "kind: ConfigMap\nmetadata:\n  name: drills-broker-scenario-files\n")')" \
	"this cluster's tool-hold drill measured NOTHING"
run_case "broker-drills-pass: this cluster's drill takes mockryx's own name" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "    name: mcp-ungranted-tool-held-on-this-cluster\n", "    name: mcp-ungranted-tool-held\n")')" \
	"carries no name or mockryx's own"
run_case "broker-drills-pass: this cluster's drill asks its second call for a result" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "          error_code: -32008\n          error_contains: not scoped to agent\n", "          result: true\n")')" \
	"asks for a result"
run_case "broker-drills-pass: this cluster's drill sends no vault handle in its second call" fail \
	"$BDP" \
	"$(py 'p = "manifests/52-tokenfuse-mcp-broker.yaml"; s = open(p).read(); a = "            _meta:\n              typryx/key: \"\x7b\x7bsecret:typryx_key\x7d\x7d\"\n"; i = s.rindex(a); open(p, "w").write(s[:i] + s[i + len(a):])')" \
	"step 2 carries no"
run_case "broker-drills-pass: the vault lets typryx_key reach search_notes" fail \
	"$BDP" \
	"$(py 'edit("typed/mode.sh", "DOOR_SCOPES=\"typryx_key=tools:ask|ask_freeform|list_questions\"", "DOOR_SCOPES=\"typryx_key=tools:ask|ask_freeform|list_questions|search_notes\"")')" \
	"which reaches search_notes"
run_case "broker-drills-pass: grant-drills goes missing from the tool hold (run)" fail \
	"$BDP" \
	"$(py 'edit("lib/tool-hold.sh", "    \x27- name: grant-drills\x27 \\\n    \x27  target: agent://mockryx.local/*\x27 \\\n    \x27  grant_tool: [\"*\"]\x27 \\\n", "")')" \
	"mcp-ungranted-tool-held-on-this-cluster came back"
run_case "broker-drills-pass: a comment in this cluster's drill is reworded" pass \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "    # LLM06:2025 Excessive Agency.) Defensive intent:", "    # LLM06:2025 Excessive Agency). Defensive intent:")')"
run_case "broker-drills-pass: a scenario names a case nothing runs" fail \
	"$BDP" \
	"$(py 'edit("features/the-drills-reach-the-broker-with-a-key-of-their-own.feature", "# -> gates-have-teeth.sh \"broker-drills-pass: the CronJob is gone\"", "# -> gates-have-teeth.sh \"broker-drills-pass: the CronJob went away\"")')" \
	"which scripts/gates-have-teeth.sh does not run"
run_case "broker-drills-pass: a case is named by no scenario" fail \
	"$BDP" \
	"$(py 'edit("features/the-drills-reach-the-broker-with-a-key-of-their-own.feature", "    # -> gates-have-teeth.sh \"broker-drills-pass: the drill pod may reach the gateway too\"\n", "")')" \
	"is named by no scenario"
run_case "broker-drills-pass: the broker's door gets a fresh drills-broker, not the gateway's (run)" fail \
	"$BDP" \
	"$(py 'edit("typed/mode.sh", "  printf \x27%s:%s,%s:%s\x27 \"$bc\" \"$DOOR_KEY_ID\" \"$db\" \"$DOOR_DRILLS_ID\"", "  printf \x27%s:%s,%s:%s\x27 \"$bc\" \"$DOOR_KEY_ID\" \"$(gen 40)\" \"$DOOR_DRILLS_ID\"")')" \
	"mcp-secret-in-arguments came back"
run_case "broker-drills-pass: the broker forwards raw secrets again (run)" fail \
	"$BDP" \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "            - \x7b name: TOKENFUSE_MCP_DLP, value: \"block\" \x7d\n", "            - \x7b name: TOKENFUSE_MCP_DLP, value: \"shadow\" \x7d\n")')" \
	"mcp-secret-in-arguments came back"

# The broker's static callers in the door and the mint (CLAUDE.md invariant 85).
run_case "typed-door-is-minted: door-callers rewrites a kept broker-caller instead of stopping" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("typed/mode.sh", "    elif [ \"$bs\" != \"$gs\" ]; then\n", "    elif [ \"$bs\" = \"$gs\" ] && false; then\n")')" \
	"is not the gateway"
run_case "typed-door-is-minted: door-callers drops what the broker Secret held" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("typed/mode.sh", "      out=\"$out,$gs:$id\"\n", "      out=\"$gs:$id\"\n")')" \
	"keep every entry byte for byte"
run_case "typed-door-is-minted: door-secrets mints the broker a caller the gateway does not hold" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("typed/mode.sh", "  bc=\"$(door_entry \"$1\" \"$DOOR_KEY_ID\")\"\n", "  bc=\"$(gen 40)\"\n")')" \
	"not exactly the gateway"
run_case "metered-doors-require-keys: the mint stops taking broker-caller from the broker's door" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "        v=\"$(identity_mint_entry \"$door\" \"$id\")\"\n", "        v=\"\"\n")')" \
	"take broker-caller from the broker"
run_case "metered-doors-require-keys: the guard lets the operator's keys through without broker-caller" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "  for id in drills-broker broker-caller; do\n    [ -n \"$(identity_mint_entry \"$spec\" \"$id\")\" ] || missing=\"$missing $id\"\n", "  for id in drills-broker; do\n    [ -n \"$(identity_mint_entry \"$spec\" \"$id\")\" ] || missing=\"$missing $id\"\n")')" \
	"the guard let a run go on"
run_case "metered-doors-require-keys: drills-broker-key is not made" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "        \"$IDM_DBROKER_SECRET\" \"$IDM_NS\" \"$IDM_LABEL\" \"$IDM_DBROKER_KEY\" \"$dbroker\" \\\n        | k_ \"-n $IDM_NS create -f -\" >/dev/null \\\n", "        \"$IDM_DBROKER_SECRET\" \"$IDM_NS\" \"$IDM_LABEL\" \"$IDM_DBROKER_KEY\" \"$dbroker\" \\\n        | cat >/dev/null \\\n")')" \
	"drills-broker-key does not hold"

# ---- supply-chain hygiene (2026-11-11): CLAUDE.md invariants 86, 87 and 88 ------------------------
#
# 86: no tracked executable. The gate reads the first bytes, never the name.
run_case "no-binary-is-tracked: a Mach-O executable gets tracked" fail \
	'./scripts/no-binary-is-tracked.sh' \
	"$(py 'import subprocess
p = "images/uapi-proxy/uapi-proxy"
open(p, "wb").write(b"\xcf\xfa\xed\xfe" + b"\x00" * 64)
subprocess.run(["git", "add", "-f", p], check=True)')" \
	"is a tracked Mach-O executable"
run_case "no-binary-is-tracked: an ELF executable is tracked under a text name" fail \
	'./scripts/no-binary-is-tracked.sh' \
	"$(py 'import subprocess
p = "gates-have-teeth-plant-notes.txt"
open(p, "wb").write(b"\x7fELF" + b"\x00" * 64)
subprocess.run(["git", "add", p], check=True)')" \
	"is a tracked ELF executable"
run_case "no-binary-is-tracked: a universal Mach-O is tracked" fail \
	'./scripts/no-binary-is-tracked.sh' \
	"$(py 'import subprocess
p = "gates-have-teeth-plant.bin"
open(p, "wb").write(b"\xca\xfe\xba\xbe" + b"\x00" * 64)
subprocess.run(["git", "add", p], check=True)')" \
	"is a tracked Mach-O universal executable"
run_case "no-binary-is-tracked: a Windows PE executable is tracked" fail \
	'./scripts/no-binary-is-tracked.sh' \
	"$(py 'import subprocess
p = "gates-have-teeth-plant.exe"
open(p, "wb").write(b"MZ" + b"\x00" * 58 + b"\x40\x00\x00\x00" + b"PE\x00\x00" + b"\x00" * 32)
subprocess.run(["git", "add", p], check=True)')" \
	"is a tracked PE executable"
run_case "no-binary-is-tracked: a text file that begins with MZ is not a PE file" pass \
	'./scripts/no-binary-is-tracked.sh' \
	"$(py 'import subprocess
p = "gates-have-teeth-plant.txt"
open(p, "w").write("MZ is also how this plain text file begins, and it is not an executable\n" * 3)
subprocess.run(["git", "add", p], check=True)')"
run_case "no-binary-is-tracked: an ordinary text file is tracked" pass \
	'./scripts/no-binary-is-tracked.sh' \
	"$(py 'import subprocess
p = "gates-have-teeth-plant-plain.txt"
open(p, "w").write("nothing but text\n")
subprocess.run(["git", "add", p], check=True)')"
run_case "no-binary-is-tracked: nothing left in the index to check" fail \
	'./scripts/no-binary-is-tracked.sh' \
	"$(py 'import subprocess
subprocess.run(["git", "rm", "-r", "--cached", "-q", "."], check=True)')" \
	"measured NOTHING"

# 87: nothing another project publishes runs unverified.
run_case "remote-fetches-are-verified: a remote manifest is applied by URL again" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'p = "install.sh"
s = open(p).read()
open(p, "w").write(s + "\nk_ \"apply -f https://example.invalid/some.yaml\"\n")')" \
	"applies a remote manifest by URL"
run_case "remote-fetches-are-verified: Longhorn goes back to the unverified apply" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "vf_cat LONGHORN_SHA256 \"Longhorn\x27s longhorn.yaml\" \"$LONGHORN_VERSION\" \"https://raw.githubusercontent.com/longhorn/longhorn/$LONGHORN_VERSION/deploy/longhorn.yaml\" | k_ \"apply -f -\"", "k_ \"apply -f https://raw.githubusercontent.com/longhorn/longhorn/$LONGHORN_VERSION/deploy/longhorn.yaml\"")')" \
	"applies a remote manifest by URL"
run_case "remote-fetches-are-verified: a k3s install takes the floating get.k3s.io script again" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "\x7b printf \x27%s\\n\x27 \"$K3S_TOKEN_VALUE\"; cat \"$K3S_INSTALL_FILE\"; \x7d | su_ \"$FIRST\"", "\x7b printf \x27%s\\n\x27 \"$K3S_TOKEN_VALUE\"; curl -sfL https://get.k3s.io; \x7d | su_ \"$FIRST\"")')" \
	"names get.k3s.io"
run_case "remote-fetches-are-verified: a download is piped into a shell" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'p = "cloud/gcp/install-gcp.sh"
s = open(p).read()
open(p, "w").write(s + "\ncurl -fsSL https://example.invalid/i.sh | sudo sh\n")')" \
	"runs a download in a shell without checking it"
run_case "remote-fetches-are-verified: a shell is handed the text of a download" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'p = "install.sh"
s = open(p).read()
open(p, "w").write(s + "\nbash -c \"$(curl -fsSL https://example.invalid/i.sh)\"\n")')" \
	"runs a download in a shell without checking it"
run_case "remote-fetches-are-verified: a download kept in a file, and prose that names the pipe, are not faults" pass \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'p = "install.sh"
s = open(p).read()
open(p, "w").write(s + "\ncurl -fsSL https://example.invalid/a.tar -o /tmp/a.tar\necho \"a pipe such as curl ... | bash is what the installers refuse\"\n")')"
run_case "remote-fetches-are-verified: an installer stops sourcing the library" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'edit("install.sh", ". \"$(dirname \"$\x7bBASH_SOURCE[0]:-$0\x7d\")/lib/verified-fetch.sh\"\n", "")')" \
	"does not source lib/verified-fetch.sh"
run_case "remote-fetches-are-verified: an installer stops fetching the k3s script through the library" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "vf_file K3S_INSTALL_SHA256 ", "vf_file K3S_INSTALL_SHA257 ")')" \
	"never fetches the k3s install script through vf_file"
run_case "remote-fetches-are-verified: a default version is moved and no hash is pinned for it" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'edit("install.sh", "LONGHORN_VERSION=\"$\x7bLONGHORN_VERSION:-v1.7.2\x7d\"", "LONGHORN_VERSION=\"$\x7bLONGHORN_VERSION:-v1.7.3\x7d\"")')" \
	"has no row LONGHORN_SHA256@v1.7.3"
run_case "remote-fetches-are-verified: the library stops comparing hashes" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'edit("lib/verified-fetch.sh", "  if [ \"$got\" != \"$want\" ]; then\n    rm -f \"$tmp\"", "  if false; then\n    rm -f \"$tmp\"")')" \
	"a file whose hash does NOT match was accepted"
run_case "remote-fetches-are-verified: the library accepts a file on a machine with no hash tool" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'edit("lib/verified-fetch.sh", "  else\n    return 127\n  fi", "  else\n    printf \x27%s\x27 \"$want\"\n  fi")')" \
	"with no sha256sum or shasum the file was accepted unchecked"
run_case "remote-fetches-are-verified: the library is gone" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'import subprocess
subprocess.run(["git", "rm", "-q", "lib/verified-fetch.sh"], check=True)')" \
	"measured NOTHING"
run_case "remote-fetches-are-verified: no installer is left to judge" fail \
	'./scripts/remote-fetches-are-verified.sh' \
	"$(py 'for p in ("install.sh", "cloud/aws/install-aws.sh", "cloud/gcp/install-gcp.sh"):
    s = open(p).read()
    assert "INSTALL_K3S_VERSION=" in s, p
    open(p, "w").write(s.replace("INSTALL_K3S_VERSION=", "INSTALL_K3S_VERSIO="))')" \
	"measured NOTHING"

# 88: a deploy whose own proof failed ends red.
run_case "deploy-ends-red: verify.sh is thrown away with || true again" fail \
	'./scripts/deploy-ends-red-when-its-proof-fails.sh' \
	"$(py 'edit("deploy.sh", "bash /root/stack-k8s/verify.sh\x27 || VERIFY_RC=$?", "bash /root/stack-k8s/verify.sh\x27 || true")')" \
	"is followed by \`|| true\`"
run_case "deploy-ends-red: security-tests.sh is thrown away with || true again" fail \
	'./scripts/deploy-ends-red-when-its-proof-fails.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "bash /root/stack-k8s/security-tests.sh\x27 || SECTEST_RC=$?", "bash /root/stack-k8s/security-tests.sh\x27 || true")')" \
	"is followed by \`|| true\`"
run_case "deploy-ends-red: the closing check no longer exits non-zero" fail \
	'./scripts/deploy-ends-red-when-its-proof-fails.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "  EXPLAINED=1\n  exit 1\nfi\n", "  EXPLAINED=1\nfi\n")')" \
	"does not exit non-zero"
run_case "deploy-ends-red: a failed proof still ends with the Done. headline" fail \
	'./scripts/deploy-ends-red-when-its-proof-fails.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "DONE_HEADLINE=\"Finished, but this deploy ends RED: a check failed.\"", "DONE_HEADLINE=\"Done.\"")')" \
	"the headline still says Done."
run_case "deploy-ends-red: the summary stops naming security-tests.sh" fail \
	'./scripts/deploy-ends-red-when-its-proof-fails.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "FAILED  security-tests.sh (is it contained)", "FAILED  the second check")')" \
	"the summary does not name security-tests.sh"
run_case "deploy-ends-red: the deploy exits before the way in is printed" fail \
	'./scripts/deploy-ends-red-when-its-proof-fails.sh' \
	"$(py 'edit("deploy.sh", "bash /root/stack-k8s/security-tests.sh\x27 || SECTEST_RC=$?\n", "bash /root/stack-k8s/security-tests.sh\x27 || SECTEST_RC=$?\n[ \"$SECTEST_RC\" -eq 0 ] || exit 3\n")')" \
	"exits between the proofs and the summary"
run_case "deploy-ends-red: a status variable is not set before its proof runs" fail \
	'./scripts/deploy-ends-red-when-its-proof-fails.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "VERIFY_RC=0\nSECTEST_RC=0\n", "SECTEST_RC=0\n")')" \
	"VERIFY_RC is not set to 0"
run_case "deploy-ends-red: a reworded comment is not a fault" pass \
	'./scripts/deploy-ends-red-when-its-proof-fails.sh' \
	"$(py 'edit("deploy.sh", "# ---- 4 and 5. proof, not vibes ---------------------------------------------", "# ---- 4 and 5. proof, not vibes, reworded ------------------------------------")')"
run_case "deploy-ends-red: no deploy script runs the proofs any more" fail \
	'./scripts/deploy-ends-red-when-its-proof-fails.sh' \
	"$(py 'for p in ("deploy.sh", "cloud/aws/deploy-aws.sh", "cloud/gcp/deploy-gcp.sh"):
    s = open(p).read()
    assert "/root/stack-k8s/verify.sh\x27" in s, p
    open(p, "w").write(s.replace("/root/stack-k8s/verify.sh\x27", "/root/stack-k8s/verify.sx\x27"))')" \
	"measured NOTHING"

# ---- the drills can start (2026-11-12): CLAUDE.md invariant 90 -------------------------------------------
#
# mockryx refuses a run whose scenarios wait for an event when no log is named to watch; a watched path
# that is not in the pod is a false Finding; a drill that retries fires its hostile scenarios again.
run_case "drills-can-start: the drills lose MOCKRYX_WATCH_EVENTS again" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'p = "manifests/40-routines-and-secrets.yaml"
s = open(p).read()
i = s.index("                - { name: MOCKRYX_WATCH_EVENTS, value: ")
j = s.index("\n", i) + 1
open(p, "w").write(s[:i] + s[j:])')" \
	"MOCKRYX_WATCH_EVENTS is not set"
run_case "drills-can-start: verdryx drops out of the watched logs" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", ",/var/lib/stack/events/verdryx.ndjson\"", "\"")')" \
	"waits for verdryx events and no watched path is verdryx.ndjson"
run_case "drills-can-start: a watched log outside every mount of the pod" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "/var/lib/stack/events/verdryx.ndjson\"", "/tmp/verdryx.ndjson\"")')" \
	"is not under any mount of the mockryx container"
run_case "drills-can-start: a watched log the bus owner never makes" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "/var/lib/stack/events/tokenfuse.ndjson,", "/var/lib/stack/events/tokenfuse.ndjson,/var/lib/stack/events/gateway.ndjson,")')" \
	"names no stream the bus owner makes"
run_case "drills-can-start: the drills retry a drill that found a gap" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "      # gap (CLAUDE.md invariant 90).\n      backoffLimit: 0\n", "      # gap (CLAUDE.md invariant 90).\n")')" \
	"backoffLimit is unset (6)"
run_case "drills-can-start: drills-broker retries too" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "      backoffLimit: 0\n", "      backoffLimit: 2\n")')" \
	"backoffLimit is 2"
run_case "drills-can-start: the pin moves to a mockryx nobody read" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "image: ghcr.io/taipanbox/mockryx:v0.5.1@", "image: ghcr.io/taipanbox/mockryx:v0.6.0@")')" \
	"measured NOTHING about"
run_case "drills-can-start: the comment above the watched logs reworded (must pass)" pass \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "# The products\x27 own logs mockryx polls", "# The products\x27 own event logs mockryx polls")')"
run_case "drills-can-start: no CronJob runs mockryx any more" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'import glob
for p in glob.glob("manifests/*.yaml"):
    s = open(p).read()
    if "image: ghcr.io/taipanbox/mockryx:" in s:
        open(p, "w").write(s.replace("image: ghcr.io/taipanbox/mockryx:", "image: example.invalid/mockryx:"))')" \
	"measured NOTHING"

# The heraldyx drill (2026-11-12, estate-gates GAPS G3.20): heraldyx's alert_sent is only in sent.ndjson on
# its own ReadWriteOnce claim, so the drill that waits for it lives beside heraldyx, reads the claim read only
# on heraldyx's node and cannot stay Pending; the gateway drills run a copy of the chain that stops at wardryx.
run_case "drills-can-start: the gateway drills run the image's whole chain again" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "                - { name: scenarios, mountPath: /scenarios/reaction-chain-reaches-heraldyx.yaml, subPath: reaction-chain-reaches-wardryx.yaml, readOnly: true }\n", "")')" \
	"is not in manifests/45-heraldyx.yaml"
run_case "drills-can-start: the gateway drills' copy is mounted under a name the image does not have" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "mountPath: /scenarios/reaction-chain-reaches-heraldyx.yaml,", "mountPath: /scenarios/reaction-chain-reaches-heraldx.yaml,")')" \
	"adds a scenario and replaces none"
run_case "drills-can-start: the gateway drills' copy waits for heraldyx again" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "            source: wardryx\n            type: policy_deny\n            within: 10s\n", "            source: heraldyx\n            type: alert_sent\n            within: 20s\n")')" \
	"is not in manifests/45-heraldyx.yaml"
run_case "drills-can-start: the heraldyx drill stops watching heraldyx's journal" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "value: \"/var/lib/stack/heraldyx/sent.ndjson\"", "value: \"/var/lib/stack/events/wardryx.ndjson\"")')" \
	"no watched path is /var/lib/stack/heraldyx/sent.ndjson"
run_case "drills-can-start: the heraldyx drill leaves heraldyx's group" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "fsGroup: 10001, supplementalGroups: [65532], ", "fsGroup: 10001, ")')" \
	"the pod is not in group 65532"
run_case "drills-can-start: the heraldyx drill's copy stops waiting for heraldyx" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "            source: heraldyx\n            type: alert_sent\n", "            source: wardryx\n            type: policy_deny\n")')" \
	"waits for no heraldyx event"
run_case "drills-can-start: the heraldyx drill runs every Monday, mail and all" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "  schedule: \"0 6 * * 1\"\n  suspend: true\n", "  schedule: \"0 6 * * 1\"\n  suspend: false\n")')" \
	"is not suspended"
run_case "drills-can-start: the heraldyx drill mounts a subPath of heraldyx's claim" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "mountPath: /var/lib/stack/heraldyx, readOnly: true }", "mountPath: /var/lib/stack/heraldyx, subPath: journal, readOnly: true }")')" \
	"is mounted by subPath journal"
run_case "drills-can-start: the heraldyx drill's pod loses the drills' label" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "          labels: { role: drills }\n", "          labels: { role: drills-heraldyx }\n")')" \
	"are not what drills-egress-gateway and gateway-ingress-drills select"
run_case "drills-can-start: the heraldyx drill mounts heraldyx's claim writable" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "persistentVolumeClaim: { claimName: heraldyx-state, readOnly: true }", "persistentVolumeClaim: { claimName: heraldyx-state }")')" \
	"is not read only on both the volume and the mount"
run_case "drills-can-start: the heraldyx drill can be placed on any node" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "          affinity:\n            podAffinity:\n              requiredDuringSchedulingIgnoredDuringExecution:\n                - labelSelector: { matchLabels: { app: heraldyx } }\n                  topologyKey: kubernetes.io/hostname\n", "")')" \
	"no required podAffinity to app: heraldyx"
run_case "drills-can-start: the heraldyx drill can stay Pending for good" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "      activeDeadlineSeconds: 900\n", "")')" \
	"no activeDeadlineSeconds"
run_case "drills-can-start: the heraldyx drill retries, and mails again" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "      # (CLAUDE.md invariant 90).\n      backoffLimit: 0\n", "      # (CLAUDE.md invariant 90).\n      backoffLimit: 1\n")')" \
	"backoffLimit is 1"
run_case "drills-can-start: the heraldyx drill's scenarios are no ConfigMap the gate can read" fail \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "configMap: { name: drills-heraldyx-scenarios, defaultMode: 0444 }", "emptyDir: {}")')" \
	"measured NOTHING about"
run_case "drills-can-start: the heraldyx drill's mail warning reworded (must pass)" pass \
	'./scripts/drills-can-start.sh' \
	"$(py 'edit("manifests/45-heraldyx.yaml", "# EACH RUN SENDS A REAL MAIL.", "# EVERY RUN SENDS A REAL MAIL.")')"

# listing did not take.
if [ "${TEETH_LIST:-}" = 1 ]; then
	exit 0
fi

# A shard that owns no case has measured nothing, and CI must not show it green.
if [ -n "$shard_i" ] && [ "$ran" -eq 0 ]; then
	printf 'shard %s/%s owns no case, so it measured NOTHING\n' "$shard_i" "$shard_n"
	failures=$((failures + 1))
fi

scope=""
if [ -n "$shard_i" ]; then
	scope=" (shard $shard_i/$shard_n of $cases)"
fi

if [ "$failures" -gt 0 ]; then
	printf '%d of %d cases failed%s.\n' "$failures" "$ran" "$scope"
	printf 'A gate that has quietly stopped catching anything looks exactly like a gate\n'
	printf 'with nothing to catch, and stays that way until the fault it guards ships.\n'
	exit 1
fi

printf 'OK: %d cases%s. Every gate fails on its own fault, passes on a non-fault,\n' "$ran" "$scope"
printf '    and refuses to report success when it measured nothing.\n'
