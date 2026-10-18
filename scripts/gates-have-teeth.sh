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
# they are written) has (k - 1) % N == i - 1. CI runs the four shards in four
# jobs; scripts/teeth-shards-cover-every-case.sh proves that together they run
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
	if ! printf '%s' "$TEETH_SHARD" | grep -Eq '^[0-9]+/[0-9]+$' ||
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
	"$(py 'edit("security-tests.sh", "image: ghcr.io/taipanbox/genaryx-console:v1.1.46", "image: ghcr.io/taipanbox/genaryx-console:latest")')" \
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
run_case "no-operator-files-tracked: a stale allow-list entry" fail \
	'./scripts/no-operator-files-tracked.sh' \
	"$(py 'edit("scripts/no-operator-files-tracked.sh", "ALLOWED = {\n", "ALLOWED = {\n    \"cloud/gcp/nonexistent.tfvars.bak\": \"planted by gates-have-teeth.sh: this path is not tracked\",\n")')" \
	"is allow-listed in this script but"

# The allow list rots the other way too: a path that IS tracked but whose
# basename never matched a shape in the first place has been suppressing
# nothing since the day it was written, and nobody would notice that
# either. CLAUDE.md is always tracked and matches none of the SHAPES above.
run_case "no-operator-files-tracked: an allow-list entry that matches no shape" fail \
	'./scripts/no-operator-files-tracked.sh' \
	"$(py 'edit("scripts/no-operator-files-tracked.sh", "ALLOWED = {\n", "ALLOWED = {\n    \"CLAUDE.md\": \"planted by gates-have-teeth.sh: this path matches no shape at all\",\n")')" \
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
run_case "deploy-flags-agree: a deploy path stops taking --trust-domain" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("deploy.sh", "    --trust-domain)  TRUST_DOMAIN=\"$2\"; shift 2 ;;\n", "")')" \
	"does not parse --trust-domain"

run_case "deploy-flags-agree: the flag is accepted and patches nothing" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("deploy.sh", "TRAILRYX_TRUST_DOMAIN\\\":\\\"$TRUST_DOMAIN", "TRAILRYX_TRUST_DOMAI_N\\\":\\\"$TRUST_DOMAIN")')" \
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
run_case "secret-keys-agree: an installer stops creating a key the manifests read" fail \
	'./scripts/secret-keys-agree.sh' \
	"$(py 'edit("install.sh", " \\\n      --from-literal=gateway_admin=\x27$GATEWAY_ADMIN_SECRET\x27\"", "\"")')" \
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
	"$(py 'edit("install.sh", "      --from-literal=cloud_admin=\x27$CLOUD_SECRET\x27 \\\n", "      --from-literal=cloud_admin=\x27$CLOUD_SECRET\x27 \\\n      --from-literal=spare=\x27$CLOUD_SECRET\x27 \\\n")')"

# evidence/identity-kind/run.sh creates stack-keys with every key the manifests read, so
# it is an (installer, Secret) subject too: the gate judges it and passes it, which is
# correct. Taking the installers away therefore takes it away too, or the case would
# measure a Secret creator instead of none.
run_case "secret-keys-agree: no installer left to judge" fail \
	'./scripts/secret-keys-agree.sh' \
	"$(py 'import os
for f in ("install.sh", "cloud/aws/install-aws.sh", "cloud/gcp/install-gcp.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh", "delegation/up.sh", "closure/up.sh", "evidence/identity-kind/run.sh", "evidence/identity-kind/mint.sh"):
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
	"$(py 'edit("cloud/aws/install-aws.sh", "  K3S_TOKEN_VALUE=\"$(su_ \"$FIRST\" \"sh -c", "  K3S_TOKEN_VALUE_HELD=\"$(su_ \"$FIRST\" \"sh -c")
s = open("cloud/aws/install-aws.sh").read()
i = s.index("K3S_TOKEN=\x27$K3S_TOKEN_VALUE\x27 sh -s - serv" + "er \\")
s = s[:i] + "K3S_TOKEN=\x27$K3S_TOKEN_VALUE\x27 \\\n    sh -s - serv" + "er \\" + s[i + len("K3S_TOKEN=\x27$K3S_TOKEN_VALUE\x27 sh -s - serv" + "er \\"):]
j = s.index("# ---- 3. the other servers")
s = s[:j] + "K3S_TOKEN_VALUE=\"$(su_ \"$FIRST\" \x27cat /var/lib/rancher/k3s/server/token\x27)\"\n" + s[j:]
open("cloud/aws/install-aws.sh", "w").write(s)')" \
	"AFTER its first server install"

# The silent mutant: the read over the login helper instead of the sudo one.
# On the box the token file is root-owned 0600, so `sh_` reads nothing and the
# installer mints a fresh token with every line of the reuse block in place.
run_case "k3s-token-is-reused: the token is read over a helper that cannot read it" fail \
	'./scripts/k3s-token-is-reused.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "K3S_TOKEN_VALUE=\"$(su_ \"$FIRST\" \"sh -c", "K3S_TOKEN_VALUE=\"$(sh_ \"$FIRST\" \"sh -c")')" \
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
run_case "preflight-keeps-tfvars: the file's machine type is no longer read back" fail \
	'./scripts/preflight-keeps-tfvars.sh' \
	"$(py 'edit("cloud/gcp/preflight.sh", "MACHINE_TYPE=\"${MACHINE_TYPE:-$(tfvar_ machine_type || true)}\"", "MACHINE_TYPE=\"${MACHINE_TYPE:-}\"")')" \
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
run_case "gateway-cache-is-off: a gateway container loses TOKENFUSE_CACHE" fail \
	'./scripts/gateway-cache-is-off.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - { name: TOKENFUSE_CACHE, value: \"off\" }\n", "")')" \
	"no TOKENFUSE_CACHE env var"

# The variable present but wrong is a different failure than absent, and the
# gate has to say which value it actually found.
run_case "gateway-cache-is-off: a gateway container sets TOKENFUSE_CACHE to something other than off" fail \
	'./scripts/gateway-cache-is-off.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "- { name: TOKENFUSE_CACHE, value: \"off\" }", "- { name: TOKENFUSE_CACHE, value: \"on\" }")')" \
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
	"$(py 'edit("manifests/10-planes.yaml", "          image: ghcr.io/taipanbox/tokenfuse:v1.16.0\n", "          image: ghcr.io/taipanbox/tokenfuse-other:v1.0.4\n")')" \
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

run_case "declassify-is-keyed: the key becomes a literal in the manifest" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "              valueFrom: { secretKeyRef: { name: stack-keys, key: declassify_key } }\n", "              value: \"change-me\"\n")')" \
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
run_case "declassify-is-keyed: an installer passes the key with --from-literal" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("install.sh", "      --from-file=declassify_key=/dev/stdin \\\n", "      --from-literal=declassify_key=\x27$DECLASSIFY_SECRET\x27 \\\n")')" \
	"puts declassify_key on a command line with --from-literal"

run_case "declassify-is-keyed: an installer migrates the key with patch -p" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "    printf \x27%s\x27 \"{\\\"stringData\\\":{\\\"declassify_key\\\":\\\"$DECLASSIFY_SECRET\\\"}}\" | k_ \"-n agent-stack patch secret stack-keys --type merge --patch-file /dev/stdin\" >/dev/null\n", "    k_ \"-n agent-stack patch secret stack-keys --type merge -p \x27{\\\"stringData\\\":{\\\"declassify_key\\\":\\\"$DECLASSIFY_SECRET\\\"}}\x27\" >/dev/null\n")')" \
	"patches declassify_key on a command line"

run_case "declassify-is-keyed: an installer creates the Secret without piping the key in" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "  printf \x27%s\x27 \"$DECLASSIFY_SECRET\" | k_ \"-n agent-stack create secret generic " "stack-keys", "  k_ \"-n agent-stack create secret generic " "stack-keys")')" \
	"never creates declassify_key from stdin"

run_case "declassify-is-keyed: an installer never gives an existing Secret the key" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("install.sh", "--patch-file /dev/stdin\" >/dev/null\n    echo \"   added declassify_key", "--patch-file /tmp/p\" >/dev/null\n    echo \"   added declassify_key")')" \
	"has no stdin patch for declassify_key"

# The subjects taken away: the gateway container's image line is what makes it
# a subject, and with no installer left there is nothing to read the mint from.
# Each must say it measured nothing, never OK.
run_case "declassify-is-keyed: no gateway container left to judge" fail \
	'./scripts/declassify-is-keyed.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "          image: ghcr.io/taipanbox/tokenfuse:v1.16.0\n", "          image: ghcr.io/taipanbox/tokenfuse-other:v1.0.4\n")')" \
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
	"$(py 'edit("install.sh", "      --from-literal=cloud_admin=\x27$CLOUD_SECRET\x27 \\\n", "      --from-literal=cloud_admin=\x27$CLOUD_SECRET\x27 \\\n      --from-literal=spare=\x27$CLOUD_SECRET\x27 \\\n")')"

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
run_case "longhorn-releases-a-dead-node: an installer never sets the policy" fail \
	'./scripts/longhorn-releases-a-dead-node.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "  if k_ \"-n longhorn-system patch settings.longhorn.io node-down-pod-deletion-policy", "  if k_ \"-n longhorn-system get settings.longhorn.io node-down-pod-deletion-policy-was-here")')" \
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

run_case "policy-store-survives-a-partition: an installer leaves data locality disabled" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'edit("install.sh", "  dataLocality: \"best-effort\"", "  dataLocality: \"disabled\"")')" \
	"parameter dataLocality"

run_case "policy-store-survives-a-partition: an installer turns the revision counter off" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "  disableRevisionCounter: \"false\"", "  disableRevisionCounter: \"true\"")')" \
	"parameter disableRevisionCounter"

run_case "policy-store-survives-a-partition: an installer keeps a failed replica 30 minutes" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "  staleReplicaTimeout: \"2880\"", "  staleReplicaTimeout: \"30\"")')" \
	"parameter staleReplicaTimeout"

run_case "policy-store-survives-a-partition: an installer lets the class delete its data" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'edit("install.sh", "  name: stack-policy\nprovisioner: driver.longhorn.io\nallowVolumeExpansion: true\nreclaimPolicy: Retain", "  name: stack-policy\nprovisioner: driver.longhorn.io\nallowVolumeExpansion: true\nreclaimPolicy: Delete")')" \
	"reclaimPolicy"

run_case "policy-store-survives-a-partition: an installer marks the class as the default" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "  name: stack-policy\n", "  name: stack-policy\n  annotations: { storageclass.kubernetes.io/is-default-class: \"true\" }\n")')" \
	"marked as the default class"

run_case "policy-store-survives-a-partition: an installer turns auto-salvage off" fail \
	'./scripts/policy-store-survives-a-partition.sh' \
	"$(py 'edit("install.sh", "k_ \"apply -f /tmp/stack-policy.yaml\"", "k_ \"apply -f /tmp/stack-policy.yaml\"\nk_ \"-n longhorn-system patch settings.longhorn.io auto-salvage --type merge -p {value:false}\"")')" \
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
run_case "policy-store-refuses-an-old-claim: the guard lets an old claim through" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$(py 'edit("lib/policy-store.sh", "  [ \"$cls\" = \"stack-policy\" ] && return 0", "  return 0")')" \
	"scenario old: expected a refusal"

run_case "policy-store-refuses-an-old-claim: the refusal loses its pointer to GOTCHAS 129" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$(py 'edit("lib/policy-store.sh", "migrate the policy store first as GOTCHAS 129 describes", "migrate the policy store first as the notes describe")')" \
	"lacks 'GOTCHAS 129'"

run_case "policy-store-refuses-an-old-claim: an unreachable cluster lets the apply through" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$(py 'edit("lib/policy-store.sh", "|| die \"could not ask the cluster whether policy-db exists, so the manifests were not applied\"", "|| return 0")')" \
	"scenario unreachable-name: expected a refusal"

run_case "policy-store-refuses-an-old-claim: a fresh cluster is refused" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$(py 'edit("lib/policy-store.sh", "  [ -n \"$existing\" ] || return 0", "  [ -n \"$existing\" ] || die \"fresh cluster refused\"")')" \
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

run_case "policy-store-refuses-an-old-claim: the top-level deploy does not source the helper" fail \
	'./scripts/policy-store-refuses-an-old-claim.sh' \
	"$(py 'edit("deploy.sh", ". \"$ROOT/lib/policy-store.sh\" || die \"no lib/policy-store.sh in $ROOT\"\n", "")')" \
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

# The delegation plane (GOTCHAS 105, invariant 24) must stay opt-in the same
# way the hub entry does: three cases, the manifest joining the default apply
# set, a delegation env var leaking into a manifest the default apply set
# DOES install, and the subject taken away entirely.
run_case "delegation-off-by-default: the manifest joins the default apply" fail \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'edit("manifests/kustomization.yaml",
    "  - 40-routines-and-secrets.yaml\n",
    "  - 40-routines-and-secrets.yaml\n  - 54-delegation.yaml\n")')" \
	"is listed in manifests/kustomization.yaml"

run_case "delegation-off-by-default: a delegation env var leaks into the default gateway manifest" fail \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml",
    "            - { name: TOKENFUSE_CACHE, value: \"off\" }\n",
    "            - { name: TOKENFUSE_CACHE, value: \"off\" }\n            - { name: TOKENFUSE_DELEGATION_ISSUER, value: \"http://vouchryx:4310\" }\n")')" \
	"a delegation env var, in the manifest"

run_case "delegation-off-by-default: up.sh re-applies the namespace and drops its Pod Security labels" fail \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'edit("delegation/up.sh",
    "say \"writing the trusted issuer into vouchryx-trusted-issuers\"\n",
    "say \"writing the trusted issuer into vouchryx-trusted-issuers\"\nkubectl create namespace \"$NS\" --dry-run=client -o yaml | kubectl apply -f - >/dev/null\n")')" \
	"applies a Namespace object"

run_case "delegation-off-by-default: the subject taken away entirely" fail \
	'./scripts/delegation-off-by-default.sh' \
	"$(py 'import os
os.remove("manifests/54-delegation.yaml")')" \
	"measured nothing"

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

run_case "closure-off-by-default: the console reads a file its volume does not mount" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("manifests/57-closure-console-patch.yaml", "value: \"/run/closure/secret\"", "value: \"/run/closure/key\"")')" \
	"does not name the file the patch mounts"

run_case "closure-off-by-default: the console unpatch leaves the volume" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("manifests/57-closure-console-unpatch.yaml", "        - { name: closure-secret, $patch: delete }\n", "")')" \
	"does not delete"

run_case "closure-off-by-default: up.sh creates the Secret from a file" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("closure/up.sh", "--from-literal=\"secret=$CLOSURE_SECRET\"", "--from-file=\"secret=$CLOSURE_SECRET\"")')" \
	"--from-file"

run_case "closure-off-by-default: up.sh mints a new secret on every run" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("closure/up.sh", "if k get secret closure-keys >/dev/null 2>&1; then", "if false; then")')" \
	"without first checking it exists"

run_case "closure-off-by-default: up.sh prints the secret" fail \
	'./scripts/closure-off-by-default.sh' \
	"$(py 'edit("closure/up.sh", "  unset CLOSURE_SECRET\n", "  echo \"$CLOSURE_SECRET\"\n  unset CLOSURE_SECRET\n")')" \
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
run_case "felyx-through-the-gateway: the base URL points past the gateway" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("manifests/20-console.yaml", "GENARYX_COPILOT_BASE_URL, value: \"http://tokenfuse-gateway:4100\"", "GENARYX_COPILOT_BASE_URL, value: \"https://api.anthropic.com\"")')" \
	"would not reach its model through this stack's gateway"

run_case "felyx-through-the-gateway: a manifest sets the remote opt-in again" fail \
	'./scripts/felyx-through-the-gateway.sh' \
	"$(py 'edit("manifests/55-copilot-cloud.yaml", "            - { name: GENARYX_COPILOT_MODEL, value: \"claude-sonnet-5\" }\n", "            - { name: GENARYX_COPILOT_MODEL, value: \"claude-sonnet-5\" }\n            - { name: GENARYX_COPILOT_ALLOW_REMOTE, value: \"1\" }\n")')" \
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

run_case "typed-mode-is-honest: a blank key file is accepted" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "grep -q \x27[^[:space:]]\x27 \"$1\"", "true")')" \
	"a blank file"

run_case "typed-mode-is-honest: the jev key becomes an environment value" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "- { name: TYPRYX_JEV_KEY_FILE, value: \"/etc/typryx/jev/key\" }", "- { name: TYPRYX_JEV_KEY, value: \"fake-test-key-not-a-real-key-7f3a9c2e\" }")')" \
	"an environment value"

run_case "typed-mode-is-honest: the committed default stops being the stub" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "- { name: TYPRYX_BACKEND, value: \"stub\" }", "- { name: TYPRYX_BACKEND, value: \"jev\" }")')" \
	"lost the stub backend"

run_case "typed-mode-is-honest: a ConfigMap is rendered for a mode" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "      public_peer | egress_policy 443 ;;", "      printf -- \"---\\nkind: ConfigMap\\n\"; public_peer | egress_policy 443 ;;")')" \
	"a ConfigMap is rendered"

run_case "typed-mode-is-honest: manifests/51 drifts from the lines the modes rewrite" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "            - { name: events, mountPath: /var/lib/stack/events }", "            - { name: events,  mountPath: /var/lib/stack/events }")')" \
	"no longer carries the three lines"

run_case "typed-mode-is-honest: a launcher loses a typed flag" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "    --typed-model-url)      TYPED_MODEL_URL=\"$2\"; shift 2 ;;\n", "")')" \
	"does not parse --typed-model-url"

run_case "typed-mode-is-honest: a launcher stops checking before it installs" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "\"$ROOT/typed/mode.sh\" check ", "\"$ROOT/typed/mode.sh\" mode ")')" \
	"never runs typed/mode.sh check"

run_case "typed-mode-is-honest: a launcher applies manifests/51 around the mode" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("deploy.sh", "  \"$ROOT/typed/mode.sh\" render ${TYPED_ARGS[@]+\"${TYPED_ARGS[@]}\"} | k_ \"apply -f -\"", "  k_ \"apply -f /root/stack-k8s/manifests/51-typryx.yaml\"")')" \
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

run_case "typed-mode-is-honest: the training flag brings another object" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "printf \x27            - { name: TYPRYX_TRAINING_DIR, value: \"%s\" }\x27 \"$TRAINING_DIR\"", "printf \x27            - { name: TYPRYX_TRAINING_DIR, value: \"%s\" }\n            - { name: TYPRYX_EXTRA, value: \"x\" }\x27 \"$TRAINING_DIR\"")')" \
	"added more than the variable"

run_case "typed-mode-is-honest: the training flag provisions a claim" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "  render_broker\n  if [ \"$RISK\" = 1 ]; then\n", "  render_broker\n  if [ \"$TRAINING\" = 1 ]; then printf -- \x27---\\napiVersion: v1\\nkind: PersistentVolumeClaim\\nmetadata:\\n  name: typryx-training\\n\x27; fi\n  if [ \"$RISK\" = 1 ]; then\n")')" \
	"A claim is a billed disk"

run_case "typed-mode-is-honest: the training directory is under no mount" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "TRAINING_DIR=\"/var/lib/typryx/training\"", "TRAINING_DIR=\"/srv/training\"")')" \
	"is under no volumeMount"

run_case "typed-mode-is-honest: the training log lands on the shared bus" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "TRAINING_DIR=\"/var/lib/typryx/training\"", "TRAINING_DIR=\"/var/lib/stack/events/training\"")')" \
	"shared events claim"

run_case "typed-mode-is-honest: the training flag is accepted with no typryx" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "if [ \"$TRAINING\" = 1 ] && [ \"$EFFECTIVE\" = off ]; then", "if false; then")')" \
	"11 training needs typryx"

run_case "typed-mode-is-honest: a launcher loses --typed-training" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "    --typed-training)       TYPED_TRAINING=1; shift ;;\n", "")')" \
	"does not parse --typed-training"

run_case "typed-mode-is-honest: a launcher stops forwarding --typed-training" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("deploy.sh", "[ \"$TYPED_TRAINING\" = 1 ] && TYPED_ARGS+=(--typed-training)\n", "")')" \
	"never adds it to the arguments"

run_case "typed-mode-is-honest: the typryx pin goes back before the wardryx-proxy" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "image: ghcr.io/taipanbox/typryx:v0.4.1", "image: ghcr.io/taipanbox/typryx:v0.3.0")')" \
	"older than v0.4.0"

run_case "typed-mode-is-honest: a document names a second typryx tag" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("README.md", "### The typed-answer plane\n", "### The typed-answer plane\n\nOlder: ghcr.io/taipanbox/typryx:v0.3.1\n")')" \
	"different tags"

run_case "typed-mode-is-honest: the typryx image is no longer named" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/51-typryx.yaml", "image: ghcr.io/taipanbox/typryx:v0.4.1", "image: example.invalid/typ:v0.4.0")
edit("manifests/56-typryx-wardryx-proxy.yaml", "image: ghcr.io/taipanbox/typryx:v0.4.1", "image: example.invalid/typ:v0.4.0")')" \
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
run_case "run-budget-ceiling-is-set: the gateway container loses the ceiling" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d\n", "")')" \
	"no TOKENFUSE_MAX_RUN_BUDGET_USD env var"

run_case "run-budget-ceiling-is-set: the ceiling is a word the gateway refuses" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"five\" \x7d")')" \
	"is not a positive decimal"

run_case "run-budget-ceiling-is-set: the ceiling is zero" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"0.00\" \x7d")')" \
	"is not a positive decimal"

run_case "run-budget-ceiling-is-set: the ceiling drifts from the documented default" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d", "\x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"10.00\" \x7d")')" \
	"is not the documented default"

run_case "run-budget-ceiling-is-set: the ceiling comes from somewhere other than a literal" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d\n", "            - name: TOKENFUSE_MAX_RUN_BUDGET_USD\n              valueFrom: \x7b configMapKeyRef: \x7b name: stack-wiring, key: TOKENFUSE_MAX_RUN_BUDGET_USD, optional: true \x7d \x7d\n")')" \
	"not as a literal value"

run_case "run-budget-ceiling-is-set: the control plane carries the ceiling" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: PORT, value: \"8080\" \x7d\n", "            - \x7b name: PORT, value: \"8080\" \x7d\n            - \x7b name: TOKENFUSE_MAX_RUN_BUDGET_USD, value: \"5.00\" \x7d\n")')" \
	"not a gateway container"

run_case "run-budget-ceiling-is-set: budget/ceiling.sh accepts zero" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("budget/ceiling.sh", "  \"\") refuse \"\x27$value\x27 is zero.", "  \"\") : \"\x27$value\x27 is zero.")')" \
	"accepted '0'"

run_case "run-budget-ceiling-is-set: budget/ceiling.sh accepts a sign and an exponent" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("budget/ceiling.sh", "re=\x27^[0-9]\x7b1,12\x7d(\\.[0-9]\x7b1,6\x7d)?$\x27", "re=\x27^[0-9eE.+-]+$\x27")')" \
	"accepted '-1'"

run_case "run-budget-ceiling-is-set: budget/ceiling.sh refuses a figure the gateway accepts" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("budget/ceiling.sh", "(\\.[0-9]\x7b1,6\x7d)?$\x27", "(\\.[0-9]\x7b1,2\x7d)?$\x27")')" \
	"refused '2.123456'"

run_case "run-budget-ceiling-is-set: a deploy path stops checking the figure before it installs" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "\"$ROOT/budget/ceiling.sh\" check ", "\"$ROOT/budget/ceiling.sh\" true ")')" \
	"never runs budget/ceiling.sh check"

run_case "run-budget-ceiling-is-set: a comment next to the ceiling changes" pass \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "# The operator\x27s ceiling on a run\x27s budget (tokenfuse v1.5.0,", "# The operator\x27s ceiling on the budget of a run (tokenfuse v1.5.0,")')"

run_case "run-budget-ceiling-is-set: no gateway container left to judge" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "          image: ghcr.io/taipanbox/tokenfuse:v1.16.0\n          imagePullPolicy: IfNotPresent\n          command: [\"/usr/local/bin/tokenfuse\"]\n          env:\n            - \x7b name: TOKENFUSE_ADDR", "          image: ghcr.io/taipanbox/tokenfuse-other:v1.5.0\n          imagePullPolicy: IfNotPresent\n          command: [\"/usr/local/bin/tokenfuse\"]\n          env:\n            - \x7b name: TOKENFUSE_ADDR")')" \
	"measured nothing about the run-budget ceiling"

run_case "run-budget-ceiling-is-set: budget/ceiling.sh taken away" fail \
	'./scripts/run-budget-ceiling-is-set.sh' \
	"$(py 'import os
os.remove("budget/ceiling.sh")')" \
	"does not exist"

# The other half of invariant 28, in deploy-flags-agree.sh beside the trust domain:
# `apply -k` puts the declared figure back, so the flag has to act after it.
run_case "deploy-flags-agree: a deploy path stops taking --run-budget-ceiling" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "    --run-budget-ceiling) RUN_BUDGET_CEILING=\"$2\"; shift 2 ;;\n", "")')" \
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
run_case "typed-mode-is-honest: the risk signal is on without the flag" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "TRAINING_DIR=\"/var/lib/typryx/training\"\nRISK=0\n", "TRAINING_DIR=\"/var/lib/typryx/training\"\nRISK=1\n")')" \
	"WITHOUT --typed-risk-signal"

run_case "typed-mode-is-honest: the gateway is pointed at the proxy" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_WARDRYX_URL, value: \"http://wardryx:8090\" \x7d", "\x7b name: TOKENFUSE_WARDRYX_URL, value: \"http://typryx-wardryx-proxy:4330\" \x7d")')" \
	"must never sit on the model path"

run_case "typed-mode-is-honest: the broker keeps asking wardryx directly" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "TOKENFUSE_WARDRYX_URL, value: \\\"http://typryx-wardryx-proxy:4330\\\"", "TOKENFUSE_WARDRYX_URL, value: \\\"http://wardryx:8090\\\"")')" \
	"the broker's TOKENFUSE_WARDRYX_URL is"

run_case "typed-mode-is-honest: the broker fails open" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_WARDRYX_FAILMODE, value: \"closed\" \x7d", "\x7b name: TOKENFUSE_WARDRYX_FAILMODE, value: \"open\" \x7d")')" \
	"not enforce/closed"

run_case "typed-mode-is-honest: the broker uses the admin key" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "key: wardryx_gateway \x7d \x7d", "key: wardryx_admin \x7d \x7d")')" \
	"does not use the pep key"

run_case "typed-mode-is-honest: the broker waits less than the proxy may take" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS, value: \\\"7000\\\"", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS, value: \\\"500\\\"")')" \
	"14 deadlines nest"

run_case "typed-mode-is-honest: the broker waits less than the proxy's longest ask" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS, value: \\\"7000\\\"", "TOKENFUSE_MCP_WARDRYX_TIMEOUT_MS, value: \\\"4000\\\"")')" \
	"the wait must exceed the longest ask"

run_case "typed-mode-is-honest: the proxy's ask deadline is too short for an own model" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "TYPRYX_PROXY_ASK_TIMEOUT_MS, value: \"3000\"", "TYPRYX_PROXY_ASK_TIMEOUT_MS, value: \"1000\"")')" \
	"most own-model answers are dropped"

run_case "typed-mode-is-honest: the proxy gets a journal on the shared bus" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "            - \x7b name: TYPRYX_PROXY_ASK_TIMEOUT_MS, value: \"3000\" \x7d\n", "            - \x7b name: TYPRYX_PROXY_ASK_TIMEOUT_MS, value: \"3000\" \x7d\n            - \x7b name: TYPRYX_EVENTS, value: \"/var/lib/stack/events/typryx.ndjson\" \x7d\n")')" \
	"the proxy sets TYPRYX_EVENTS"

run_case "typed-mode-is-honest: the proxy inherits the training log" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "render_typryx \"$1\" \"$2\" \"$3\" \"$M56\"", "render_typryx \"$(with_training \"$1\")\" \"$2\" \"$3\" \"$M56\"")')" \
	"the proxy sets TYPRYX_TRAINING_DIR"

run_case "typed-mode-is-honest: the proxy answers from another backend than typryx" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "render_typryx \"$1\" \"$2\" \"$3\" \"$M56\"", "render_typryx \x27            - \x7b name: TYPRYX_BACKEND, value: \"stub\" \x7d\x27 \"\" \"\" \"$M56\"")')" \
	"disagree on the backend"

run_case "typed-mode-is-honest: the door admits every pod" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "  ingress:\n    - from:\n        - podSelector: \x7b matchLabels: \x7b app: tokenfuse-mcp-broker \x7d \x7d\n      ports:\n        - \x7b protocol: TCP, port: 4330 \x7d", "  ingress:\n    - from:\n        - podSelector: \x7b\x7d\n      ports:\n        - \x7b protocol: TCP, port: 4330 \x7d")')" \
	"admits or reaches more than the one named peer"

run_case "typed-mode-is-honest: the model egress leaves the proxy out" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "  if [ \"$RISK\" = 1 ]; then\n    # The proxy answers from the same backend", "  if false; then\n    # The proxy answers from the same backend")')" \
	"does not select the proxy"

run_case "typed-mode-is-honest: a hold_if_signal policy is seeded" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/00-base.yaml", "      deny_tool:\n        - shell_exec\n", "      deny_tool:\n        - shell_exec\n    - name: seeded\n      target: agent://*\n      hold_if_signal: \x7b name: action.risk_class, values: [destructive], min_probability: 0.8 \x7d\n")')" \
	"seeds a hold_if_signal policy"

run_case "typed-mode-is-honest: the risk flag is accepted with no typryx" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("typed/mode.sh", "if [ \"$RISK\" = 1 ] && [ \"$EFFECTIVE\" = off ]; then", "if false; then")')" \
	"15 risk signal needs typryx"

run_case "typed-mode-is-honest: a launcher loses --typed-risk-signal" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "    --typed-risk-signal)    TYPED_RISK_SIGNAL=1; shift ;;\n", "")')" \
	"does not parse --typed-risk-signal"

run_case "typed-mode-is-honest: a launcher stops forwarding --typed-risk-signal" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("deploy.sh", "[ \"$TYPED_RISK_SIGNAL\" = 1 ] && TYPED_ARGS+=(--typed-risk-signal)\n", "")')" \
	"15 launchers hand --typed-risk-signal"

run_case "typed-mode-is-honest: the proxy runs another typryx tag than typryx" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "image: ghcr.io/taipanbox/typryx:v0.4.1", "image: ghcr.io/taipanbox/typryx:v0.3.0")')" \
	"different tags"

run_case "typed-mode-is-honest: the proxy runs the service, not the proxy" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "args: [\"wardryx-proxy\"]", "args: [\"serve\"]")')" \
	"does not run \`typryx wardryx-proxy\`"

run_case "typed-mode-is-honest: the proxy forwards to something other than wardryx" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/56-typryx-wardryx-proxy.yaml", "value: \"http://wardryx:8090\" \x7d", "value: \"http://wardryx.other:8090\" \x7d")')" \
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
run_case "chain-verifier: the verifier is suspended" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "  schedule: \"*/15 * * * *\"\n", "  schedule: \"*/15 * * * *\"\n  suspend: true\n")')" \
	"suspended"

run_case "chain-verifier: the verifier runs hourly" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "  schedule: \"*/15 * * * *\"\n", "  schedule: \"0 * * * *\"\n")')" \
	"not at least every 15 minutes"

run_case "chain-verifier: the verifier watches a directory that is not the bus" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "                - \"/var/lib/stack/events\"\n              volumeMounts:\n                - \x7b name: events, mountPath: /var/lib/stack/events \x7d\n              securityContext:\n                allowPrivilegeEscalation: false\n                readOnlyRootFilesystem: true\n                capabilities: \x7b drop: [\"ALL\"] \x7d\n              resources:\n                requests: \x7b cpu: 20m", "                - \"/var/lib/stack\"\n              volumeMounts:\n                - \x7b name: events, mountPath: /var/lib/stack/events \x7d\n              securityContext:\n                allowPrivilegeEscalation: false\n                readOnlyRootFilesystem: true\n                capabilities: \x7b drop: [\"ALL\"] \x7d\n              resources:\n                requests: \x7b cpu: 20m")')" \
	"not the bus"

run_case "chain-verifier: the verifier writes a stream named for another writer" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "                - \"/var/lib/stack/events/agent-conform.ndjson\"\n", "                - \"/var/lib/stack/events/wardryx.ndjson\"\n")')" \
	"inside the bus (its name is the source"

run_case "chain-verifier: the verifier remembers in an emptyDir" fail \
	'./scripts/chain-verifier-watches-the-bus.sh' \
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "                - \"/var/lib/stack/events\"\n              volumeMounts:\n                - \x7b name: events, mountPath: /var/lib/stack/events \x7d\n              securityContext:\n                allowPrivilegeEscalation: false\n                readOnlyRootFilesystem: true\n                capabilities: \x7b drop: [\"ALL\"] \x7d\n              resources:\n                requests: \x7b cpu: 20m, memory: 32Mi \x7d\n                limits: \x7b memory: 256Mi \x7d\n          volumes:\n            - name: events\n              persistentVolumeClaim: \x7b claimName: stack-events \x7d\n", "                - \"/var/lib/stack/events\"\n              volumeMounts:\n                - \x7b name: events, mountPath: /var/lib/stack/events \x7d\n              securityContext:\n                allowPrivilegeEscalation: false\n                readOnlyRootFilesystem: true\n                capabilities: \x7b drop: [\"ALL\"] \x7d\n              resources:\n                requests: \x7b cpu: 20m, memory: 32Mi \x7d\n                limits: \x7b memory: 256Mi \x7d\n          volumes:\n            - name: events\n              emptyDir: \x7b\x7d\n")')" \
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
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "image: ghcr.io/taipanbox/agent-conform:v1.1.0", "image: ghcr.io/taipanbox/agent-conform:v1.0.2")')" \
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
	"$(py 'edit("manifests/40-routines-and-secrets.yaml", "image: ghcr.io/taipanbox/agent-conform:v1.1.0", "image: ghcr.io/taipanbox/agent-conform-other:v1.1.0")')" \
	"measured nothing about the verifier"

# The bus file names (invariant 30). heraldyx v0.3.0 and idryx v1.1.0 refuse an event
# whose source is not allowed for its file, so a stream renamed, or a --load pair that
# names the wrong source, silences a plane without an error.
run_case "bus-names: a stream is named for no source the readers know" fail \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$(py 'edit("manifests/00-base.yaml", "WARDRYX_EVENTS_PATH: \"/var/lib/stack/events/wardryx.ndjson\"", "WARDRYX_EVENTS_PATH: \"/var/lib/stack/events/policy-events.ndjson\"")')" \
	"named for no source the readers know"

run_case "bus-names: an idryx --load pair names a source the file may not carry" fail \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \"tokenfuse:/var/lib/stack/events/tokenfuse.ndjson\"", "            - \"wardryx:/var/lib/stack/events/tokenfuse.ndjson\"")')" \
	"may carry"

run_case "bus-names: an idryx --load path is not a stream file" fail \
	'./scripts/bus-names-match-the-source-rule.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \"tokenfuse:/var/lib/stack/events/tokenfuse.ndjson\"", "            - \"tokenfuse:/var/lib/stack/events/tokenfuse.log\"")')" \
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
	"$(py 'edit("manifests/51-typryx.yaml", "runAsGroup: 65532, fsGroup: 10001, seccompProfile", "runAsGroup: 65532, seccompProfile")')" \
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
edit("typed/mode.sh", "secret: \x7b secretName: typryx-model-key, defaultMode: 0440 \x7d", "configMap: \x7b name: typryx-model-key \x7d")')" \
	"no typed render mounts a Secret"

# Invariant 33. tokenfuse splits a client key entry on its LAST colon, so an
# agent:// key id starts fine and refuses the caller's real secret. Quotes in
# the examples are spelled \x27 and braces \x7b \x7d, per the bash 3.2 note at
# the top.
run_case "client-key-ids: the README example goes back to an agent:// key id" fail \
	'./scripts/client-key-ids-are-bare.sh' \
	"$(py 'edit("README.md", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:broker-caller\x27", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:agent://acme.example/broker-caller\x27")')" \
	"key id '//acme.example/broker-caller'"

run_case "client-key-ids: the manifest 52 example goes back to an agent:// key id" fail \
	'./scripts/client-key-ids-are-bare.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:broker-caller\x27", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:agent://acme.example/broker-caller\x27")')" \
	"key id '//acme.example/broker-caller'"

run_case "client-key-ids: a YAML flow env entry carries an agent:// key id" fail \
	'./scripts/client-key-ids-are-bare.sh' \
	"$(py 'open("README.md", "a").write("\n    env: [ \x7b name: TOKENFUSE_CLIENT_KEYS, value: \"sk-flow:agent://acme.example/flow\" \x7d ]\n")')" \
	"key id '//acme.example/flow'"

run_case "client-key-ids: a YAML block env entry carries an agent:// key id" fail \
	'./scripts/client-key-ids-are-bare.sh' \
	"$(py 'open("README.md", "a").write("\n        - name: TOKENFUSE_MCP_KEYS\n          value: \"sk-block:agent://acme.example/block\"\n")')" \
	"key id '//acme.example/block'"

run_case "client-key-ids: a secret with colons and a bare key id (must pass)" pass \
	'./scripts/client-key-ids-are-bare.sh' \
	"$(py 'edit("README.md", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:broker-caller\x27", "TOKENFUSE_MCP_KEYS=\x27sk-proj:abc:def:broker-caller,sk-two:research-agent\x27")')"

run_case "client-key-ids: no literal example left to judge" fail \
	'./scripts/client-key-ids-are-bare.sh' \
	"$(py 'edit("README.md", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:broker-caller\x27", "TOKENFUSE_MCP_KEYS=\"$BROKER_KEYS\"")
edit("manifests/52-tokenfuse-mcp-broker.yaml", "TOKENFUSE_MCP_KEYS=\x27pick-a-different-long-secret:broker-caller\x27", "TOKENFUSE_MCP_KEYS=\"$BROKER_KEYS\"")')" \
	"measured nothing"

# invariant 34: a public repository carries no quote of the owner, no owner
# provenance marker and no attribution by name. Every planted string is built
# from pieces or escapes, so this file never trips the gate it tests.
run_case "no-owner-quotes: an owner provenance marker" fail \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("README.md", "a").write("\n`@" + "yur" + "ii 2026-10-08`: keep it.\n")')" \
	"the owner's provenance marker"

run_case "no-owner-quotes: a quote in Ukrainian" fail \
	'./scripts/no-owner-quotes.sh' \
	"$(py 'open("GOTCHAS.md", "a").write("\n\"\u0440\u043e\u0431\u0438 \u0432\u0441\u0435\"\n")')" \
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
	"$(py 'edit("manifests/49-costcrew.yaml", "image: ghcr.io/taipanbox/costcrew:v0.7.0", "image: registry.invalid/costcrew:v0.6.0")
edit("manifests/49-costcrew.yaml", "image: ghcr.io/taipanbox/costcrew:v0.7.0", "image: registry.invalid/costcrew:v0.6.0")')" \
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
run_case "firewall-is-enforce-by-default: the gateway container loses the switch" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d\n", "")')" \
	"has no TOKENFUSE_FIREWALL env var"

run_case "firewall-is-enforce-by-default: the gateway defaults to shadow" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d", "\x7b name: TOKENFUSE_FIREWALL, value: \"shadow\" \x7d")')" \
	'not "enforce"'

run_case "firewall-is-enforce-by-default: the gateway defaults to off" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d", "\x7b name: TOKENFUSE_FIREWALL, value: \"off\" \x7d")')" \
	'not "enforce"'

run_case "firewall-is-enforce-by-default: the switch is set twice, the second to shadow" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d\n", "            - \x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d\n            - \x7b name: TOKENFUSE_FIREWALL, value: \"shadow\" \x7d\n")')" \
	"set 2 times"

run_case "firewall-is-enforce-by-default: a comment naming shadow beside the switch" pass \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d\n", "            # shadow is the gateway default only when the variable is unset.\n            - \x7b name: TOKENFUSE_FIREWALL, value: \"enforce\" \x7d\n")')"

run_case "firewall-is-enforce-by-default: every gateway start taken away" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "          command: [\"/usr/local/bin/tokenfuse\"]\n", "          command: [\"/bin/true\"]\n")')" \
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

run_case "firewall-is-enforce-by-default: a deploy path checks the mode but does not stop on it" fail \
	'./scripts/firewall-is-enforce-by-default.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "\"$ROOT/firewall/mode.sh\" check \"$FIREWALL_MODE\"", "\"$ROOT/firewall/mode.sh\" true \"$FIREWALL_MODE\"")')" \
	"before its first apply"

run_case "deploy-flags-agree: a deploy path stops taking --firewall" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "    --firewall) FIREWALL_MODE=\"$2\"; shift 2 ;;\n", "")')" \
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
run_case "pii-is-shadow-by-default: the gateway container loses the switch" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d\n", "")')" \
	"has no TOKENFUSE_DLP_PII env var"

run_case "pii-is-shadow-by-default: the gateway defaults to off" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d", "\x7b name: TOKENFUSE_DLP_PII, value: \"off\" \x7d")')" \
	'not "shadow"'

run_case "pii-is-shadow-by-default: the gateway defaults to block" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d", "\x7b name: TOKENFUSE_DLP_PII, value: \"block\" \x7d")')" \
	'not "shadow"'

run_case "pii-is-shadow-by-default: the switch is set twice, the second to off" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d\n", "            - \x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d\n            - \x7b name: TOKENFUSE_DLP_PII, value: \"off\" \x7d\n")')" \
	"set 2 times"

run_case "pii-is-shadow-by-default: a comment naming block beside the switch" pass \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - \x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d\n", "            # block refuses a call that carries a finding; the literal below is shadow.\n            - \x7b name: TOKENFUSE_DLP_PII, value: \"shadow\" \x7d\n")')"

run_case "pii-is-shadow-by-default: every gateway start taken away" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "          command: [\"/usr/local/bin/tokenfuse\"]\n", "          command: [\"/bin/true\"]\n")')" \
	"no gateway start was found"

run_case "pii-is-shadow-by-default: the broker container loses the switch" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "            - \x7b name: TOKENFUSE_MCP_DLP_PII, value: \"shadow\" \x7d\n", "")')" \
	"has no TOKENFUSE_MCP_DLP_PII env var"

run_case "pii-is-shadow-by-default: the MCP broker defaults to off" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_MCP_DLP_PII, value: \"shadow\" \x7d", "\x7b name: TOKENFUSE_MCP_DLP_PII, value: \"off\" \x7d")')" \
	'TOKENFUSE_MCP_DLP_PII is "off"'

run_case "pii-is-shadow-by-default: every MCP broker start taken away" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "          args: [\"mcp-broker\"]\n", "          args: [\"mcp-brokr\"]\n")')" \
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

run_case "pii-is-shadow-by-default: a deploy path checks the mode but does not stop on it" fail \
	'./scripts/pii-is-shadow-by-default.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "\"$ROOT/pii/mode.sh\" check \"$PII_MODE\"", "\"$ROOT/pii/mode.sh\" true \"$PII_MODE\"")')" \
	"before its first apply"

run_case "deploy-flags-agree: a deploy path stops taking --pii-mode" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "    --pii-mode) PII_MODE=\"$2\"; shift 2 ;;\n", "")')" \
	"does not parse --pii-mode"

run_case "deploy-flags-agree: the gateway PII switch is accepted and applies nothing" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("deploy.sh", "set env deploy/tokenfuse-gateway -c gateway TOKENFUSE_DLP_PII=$PII_MODE", "get deploy/tokenfuse-gateway -c gateway TOKENFUSE_DLP_PII=$PII_MODE")')" \
	"never applies"

run_case "deploy-flags-agree: the broker PII switch is accepted and applies nothing" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "set env deploy/tokenfuse-mcp-broker -c broker TOKENFUSE_MCP_DLP_PII=$PII_MODE", "get deploy/tokenfuse-mcp-broker -c broker TOKENFUSE_MCP_DLP_PII=$PII_MODE")')" \
	"never applies"

run_case "deploy-flags-agree: the gateway PII switch is applied before the kustomization" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "  k_ \"-n agent-stack set env deploy/tokenfuse-gateway -c gateway TOKENFUSE_DLP_PII=$PII_MODE\" >/dev/null \\\n", "  true \\\n"); edit("cloud/gcp/deploy-gcp.sh", "k_ \"apply -k /root/stack-k8s/manifests\"", "k_ \"-n agent-stack set env deploy/tokenfuse-gateway -c gateway TOKENFUSE_DLP_PII=$PII_MODE\" >/dev/null\nk_ \"apply -k /root/stack-k8s/manifests\"")')" \
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

run_case "identity-files: no gateway start left to judge" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "          command: [\"/usr/local/bin/tokenfuse\"]\n", "          command: [\"/bin/true\"]\n")')" \
	"measured NOTHING"

run_case "identity-files: identity/up.sh taken away" fail \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'import os; os.remove("identity/up.sh")')" \
	"identity/up.sh is missing"

run_case "identity-files: a comment that names another form of the setting is not the setting" pass \
	'IDENTITY_SECTIONS=A ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "            - name: TOKENFUSE_CLIENT_KEYS\n", "            # optional: true would start a gateway that answers anyone; the reference below is required.\n            - name: TOKENFUSE_CLIENT_KEYS\n")')"

run_case "identity-files: a short secret is accepted" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "[ \"$\x7b#secret\x7d\" -lt 24 ]", "[ \"$\x7b#secret\x7d\" -lt 8 ]")')" \
	"(a secret of 23 characters) reached docker"

run_case "identity-files: a quote or a dollar reaches the Secret" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "re_chars=\x27^[A-Za-z0-9._~+/=@:-]+$\x27", "re_chars=\x27^.+$\x27")')" \
	"(a secret with a dollar) reached docker"

run_case "identity-files: a secret given twice is kept" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "die \"--client-keys-file: line $n gives a secret an earlier line already gave", ": \"--client-keys-file: line $n gives a secret an earlier line already gave")')" \
	"(a secret given twice) reached docker"

run_case "identity-files: a NUL byte is let through" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "printf \x27names a file holding a NUL byte\x27; return 0;", ":;")')" \
	"(a NUL byte) reached docker"

run_case "identity-files: a keys file of comments alone is accepted" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "[ \"$count\" -gt 0 ] || die", "[ \"$count\" -ge 0 ] || die")')" \
	"(comments and blank lines only) was accepted"

run_case "identity-files: a map that is not a JSON object passes the first half" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "[ \"$first\" = \"\x7b\" ] || die", "[ -n \"$first\" ] || die")')" \
	"(a JSON array, not an object) reached docker"

run_case "identity-files: a refusal repeats the secret" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "die \"--client-keys-file: line $n $why.", "die \"--client-keys-file: line $n ($line) $why.")')" \
	"repeats the secret"

run_case "identity-files: a map larger than a ConfigMap holds is accepted" fail \
	'IDENTITY_SECTIONS=B ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "MAP_MAX=1044480\n", "MAP_MAX=10485760\n")')" \
	"(a map larger than a ConfigMap holds) reached docker"

run_case "identity-files: the gateway's own refusal is not heard" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "    *\"tokenfuse gateway listening\"*) ;;\n", "    *) ;;\n")')" \
	"refused, but not saying: not declared in units[]"

run_case "identity-files: a map that configures nothing is accepted" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "grep -qF \x27identity map: ON (\x27 <<<\"$logs\" \\\n", "true \\\n")')" \
	"configures nothing ({}) was accepted"

run_case "identity-files: a map that binds a key with no secret is accepted" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "orphans=\"$(sed -n", "orphans=\"$(: sed -n")')" \
	"binds a key id no client key carries was accepted"

run_case "identity-files: a client key the map does not bind is accepted" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "unbound=\"$(sed -n", "unbound=\"$(: sed -n")')" \
	"a client key the map does not bind was accepted"

run_case "identity-files: the check container reaches the network" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "--name \"$CHECK_CONTAINER\" --network none \\\n", "--name \"$CHECK_CONTAINER\" \\\n")')" \
	"with a network"

run_case "identity-files: the keys ride the docker command line" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "      -e TOKENFUSE_CLIENT_KEYS \\\n", "      -e \"TOKENFUSE_CLIENT_KEYS=$spec\" \\\n")')" \
	"put a secret on the docker command line"

run_case "identity-files: the check gives the image no command" fail \
	'IDENTITY_SECTIONS=C ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "      --entrypoint \"$GATEWAY_CMD\" \\\n", "")')" \
	"with no ENTRYPOINT, the shape BUILD_FROM_SOURCE builds was refused"

run_case "identity-files: a refused file still writes to the cluster" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "identity_check \"$IMAGE\" \"$SPEC\" \"$MAPF\"\n", "true \"$IMAGE\" \"$SPEC\" \"$MAPF\"\n")')" \
	"still wrote to the cluster"

run_case "identity-files: a re-run that names no file drops the kept keys" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "SPEC=\"$KEPT_SPEC\"\n[ \"$KEYS_GIVEN\" = 0 ] || SPEC=\"$KEYS_NEW\"\n", "SPEC=\"$KEYS_NEW\"\n")')" \
	"a re-run that names no file"

run_case "identity-files: the same map again restarts the gateway" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "[ -z \"$MAP_SHA\" ] || ANN_MAP_WANT=\"$MAP_SHA\"\n", "[ -z \"$MAP_SHA\" ] || ANN_MAP_WANT=\"$MAP_SHA-$$\"\n")')" \
	"the same map given again"

run_case "identity-files: a new map does not restart the gateway" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "[ -z \"$MAP_SHA\" ] || ANN_MAP_WANT=\"$MAP_SHA\"\n", "[ -z \"$MAP_SHA\" ] || ANN_MAP_WANT=on\n")')" \
	"a new map did not roll the gateway"

run_case "identity-files: a new keys file does not restart the gateway" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "[ \"$SECRET_PRESENT\" = 0 ] || ANN_KEYS_WANT=\"$SECRET_RV\"\n", "[ \"$SECRET_PRESENT\" = 0 ] || ANN_KEYS_WANT=on\n")')" \
	"a new keys file did not roll the gateway"

run_case "identity-files: the keys ride the kubectl command line" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "      | k create -f - >/dev/null \\\n      || die \"could not create Secret $SECRET_NAME\"", "      >/dev/null; k create secret generic \"$SECRET_NAME\" --from-literal=\"$SECRET_KEY=$SPEC\" >/dev/null \\\n      || die \"could not create Secret $SECRET_NAME\"")')" \
	"a secret appeared on a kubectl command line"

run_case "identity-files: up.sh believes a gateway that reports other keys" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "if [ -n \"$seen_keys\" ] && [ \"$seen_keys\" != \"$CHECK_KEYS\" ]; then", "if false; then")')" \
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

run_case "aws-takes-every-gcp-flag: an allow-list entry names a flag GCP does not take" fail \
	'./scripts/aws-takes-every-gcp-flag.sh' \
	"$(py 'edit("scripts/aws-takes-every-gcp-flag.sh", "ALLOW=\"\"", "ALLOW=\"--no-such-flag|a flag nobody takes\"")')" \
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

run_case "cluster-dns-has-a-budget: the budget is applied with one replica too" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'edit("install.sh", "if [ \"$DNS_WANT\" -ge 2 ]; then", "if true; then")')" \
	"outside"

run_case "cluster-dns-has-a-budget: an installer patches k3s's coredns Deployment" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "echo \"   coredns replicas=$DNS_WANT\"\n", "echo \"   coredns replicas=$DNS_WANT\"\nk_ \"-n kube-system patch deployment coredns --type merge -p x\" >/dev/null || true\n")')" \
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
run_case "cluster-dns-has-a-budget: five nodes get two replicas" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'edit("install.sh", "[ \"${#ALL_NODES[@]}\" -ge 5 ] && DNS_WANT=3", "[ \"${#ALL_NODES[@]}\" -ge 5 ] && DNS_WANT=2")')" \
	"the replica policy"

run_case "cluster-dns-has-a-budget: the three-replica line is dropped from one installer" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'edit("cloud/gcp/install-gcp.sh", "[ \"${#ALL_NODES[@]}\" -ge 5 ] && DNS_WANT=3\n", "")')" \
	"the replica policy"

run_case "cluster-dns-has-a-budget: the installers disagree on the threshold" fail \
	'./scripts/cluster-dns-has-a-budget.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "-ge 5 ] && DNS_WANT=3", "-ge 4 ] && DNS_WANT=3")')" \
	"the replica policy"

# Invariant 41: a secret is minted from a bounded read, by one generator, sourced. The
# unbounded line comes back, inside a caller and inside the generator; the generator
# returns short, repeats, or is copied; a caller forgets the source or sources it too
# late; a message that only names the device must pass; and the subject taken away.
run_case "gen-is-bounded: a deploy script reads urandom with no bound" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("deploy.sh", "CONSOLE_PASSWORD=\"$(gen 28)\"", "CONSOLE_PASSWORD=\"$( set +o pipefail; LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 28 )\"")')" \
	"deploy.sh:"

run_case "gen-is-bounded: the generator itself reads with no bound" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("lib/gen.sh", "v=\"$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc \x27A-Za-z0-9\x27)\"", "v=\"$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 64)\"")')" \
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

run_case "gen-is-bounded: the generator prints the same value every time" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("lib/gen.sh", "  printf \x27%s\x27 \"$v\"\n", "  printf \x27%s\x27 \"$(printf %0\"$n\"d 0)\"\n")')" \
	"printed the same value twice"

run_case "gen-is-bounded: a second copy of the generator in a deploy script" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", ". \"$ROOT/lib/gen.sh\" || die", "gen() \x7b local v; v=\"$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc A-Za-z0-9)\"; printf %s \"$\x7bv:0:$1\x7d\"; \x7d\n. \"$ROOT/lib/gen.sh\" || die")')" \
	"a second gen() outside lib/gen.sh"

run_case "gen-is-bounded: a caller that never sources the generator" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", ". \"$ROOT/lib/gen.sh\" || die \"no lib/gen.sh in $ROOT\"\n", "")')" \
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

run_case "gen-is-bounded: nothing asks the generator for a length" fail \
	'./scripts/gen-is-bounded.sh' \
	"$(py 'for p in ("deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh"):
    edit(p, "\"$(gen 28)\"", "\"$(gen)\"")
s = open("typed/mode.sh").read()
assert "$(gen 40)" in s
open("typed/mode.sh", "w").write(s.replace("$(gen 40)", "$(gen)"))
s = open("lib/identity-mint.sh").read()
assert "$(gen 40)" in s
open("lib/identity-mint.sh", "w").write(s.replace("$(gen 40)", "$(gen)"))')" \
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

run_case "typed-door-is-minted: a launcher applies the door's Secrets" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "\"$DOOR_DOCS\" | k_ \"-n agent-stack create -f -\"", "\"$DOOR_DOCS\" | k_ \"-n agent-stack apply -f -\"")')" \
	"hands the door's Secrets to apply"

run_case "typed-door-is-minted: a launcher hands create only part of the door" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("cloud/gcp/deploy-gcp.sh", "\"$DOOR_DOCS\" | k_ \"-n agent-stack create -f -\"", "\"$DOOR_DOCS\" | head -n 9 | k_ \"-n agent-stack create -f -\"")')" \
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
a = "    broker_key=\"$(gen 40)\" || refuse \"could not mint the broker\x27s key\"\n    [ \"$bearer\" != \"$broker_key\" ]"
assert a in s
open(p, "w").write(s.replace(a, "    broker_key=\"$bearer\"\n    [ -n \"$broker_key\" ]"))')" \
	"are the same"

run_case "typed-door-is-minted: typryx's bearer is short" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("typed/mode.sh", "    bearer=\"$(gen 40)\" || refuse", "    bearer=\"$(gen 16)\" || refuse")')" \
	"not at least 32"

run_case "typed-door-is-minted: the broker's key id is an agent URI" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("typed/mode.sh", "DOOR_KEY_ID=\"broker-caller\"", "DOOR_KEY_ID=\"agent://acme.example/broker-caller\"")')" \
	"not a bare name"

run_case "typed-door-is-minted: a minted value reaches stderr" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("typed/mode.sh", "    made=\"$DOOR_TYPRYX (identity", "    printf \x27%s\\n\x27 \"$bearer\" >&2\n    made=\"$DOOR_TYPRYX (identity")')" \
	"appears on stderr"

run_case "typed-door-is-minted: the broker's Secret alone mints typryx's anyway" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("typed/mode.sh", "  elif [ \"$have_b\" = 1 ]; then\n", "  elif false; then\n")')" \
	"only the broker"

run_case "typed-door-is-minted: --have rides along with another verb unnoticed" fail \
	'./scripts/typed-door-is-minted.sh' \
	"$(py 'edit("typed/mode.sh", "  refuse \"--have and --trust-domain only go with door-secrets\"\n", "  true\n")')" \
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

run_case "wardryx-key-is-pep: the hub gives a site's gateway viewer again" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("hub/add-site.sh", "NEW_WARDRYX_ENTRY=\"${WARDRYX_SECRET}:default:pep\"", "NEW_WARDRYX_ENTRY=\"${WARDRYX_SECRET}:default:viewer\"")')" \
	"does not give a site's gateway entry pep"

run_case "wardryx-key-is-pep: the transform rewrites every key, not the gateway's" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "if (p[1] == gw && n >= 3 && p[3] == \"viewer\") p[3] = \"pep\"", "if (n >= 3 && p[3] == \"viewer\") p[3] = \"pep\"")')" \
	"is not the one install.sh has"

run_case "wardryx-key-is-pep: the transform changes the gateway's secret" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "        e = p[1]\n        for (k = 2; k <= n; k++) e = e \":\" p[k]", "        e = p[1] \"x\"\n        for (k = 2; k <= n; k++) e = e \":\" p[k]")')" \
	"is not the one install.sh has"

run_case "wardryx-key-is-pep: the migration is not in the aws installer" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("cloud/aws/install-aws.sh", "| wardryx_gateway_role_keys)\"\n", "| true)\"\n")')" \
	"never runs the migration"

run_case "wardryx-key-is-pep: the migration writes the key on the command line" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("install.sh", "printf '\''%s'\'' \"{\\\"stringData\\\":{\\\"wardryx_keys\\\":\\\"$WARDRYX_KEYS_NEW\\\"}}\" | k_ \"-n agent-stack patch secret stack-keys --type merge --patch-file /dev/stdin\" >/dev/null", "k_ \"-n agent-stack patch secret stack-keys --type merge -p $WARDRYX_KEYS_NEW\" >/dev/null")')" \
	"puts a key on a command line"

run_case "wardryx-key-is-pep: a pin moves back to the old wardryx" fail \
	'./scripts/wardryx-gateway-key-is-pep.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "image: ghcr.io/taipanbox/wardryx:v2.1.0", "image: ghcr.io/taipanbox/wardryx:v1.5.0")')" \
	"does not pin wardryx v2.1.0"

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

run_case "nodes-stop-their-pods-first: the first server gets no file" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$(py 'edit("install.sh", "put_graceful_shutdown \"$FIRST\"\n", "")')" \
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

run_case "nodes-stop-their-pods-first: verify.sh counts a pod a shutdown stopped" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$(py 'edit("verify.sh", "$2 == \"Failed\" && ($3 == \"Terminated\" || $3 == \"NodeShutdown\")", "$2 == \"Failed\" && $3 == \"NoSuchReason\"")')" \
	"did not report exactly one bad pod"

run_case "nodes-stop-their-pods-first: verify.sh stops counting a crash loop" fail \
	'./scripts/nodes-stop-their-pods-first.sh' \
	"$(py 'edit("verify.sh", "!($1 in gone) && $3 != \"Running\" && $3 != \"Completed\" { c++ }", "!($1 in gone) && $3 != \"Running\" && $3 != \"Completed\" && $3 != \"CrashLoopBackOff\" { c++ }")')" \
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

run_case "node-checks-read-their-own-answer: the quiet ssh setting is gone" fail \
	'./scripts/node-checks-read-their-own-answer.sh' \
	"$(py 'edit("security-tests.sh", "SECCHK_SSH=\"-q -o LogLevel=ERROR", "SECCHK_OFF=\"-q -o LogLevel=ERROR")')" \
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

run_case "servers-encrypt-secrets: section 7 stops expecting encryption" fail \
	'./scripts/servers-encrypt-secrets.sh' \
	"$(py 'edit("security-tests.sh", "bad \"the Secret is plaintext in etcd, so", "bad \"the Secret is in etcd, so")')" \
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

run_case "teeth-shards-cover-every-case: the listing prints nothing" fail \
	'./scripts/teeth-shards-cover-every-case.sh' \
	"$(py 'edit("scripts/gates-have-teeth.sh", "printf \x27%s\\n\x27 \"$name\" >&3", ":")')" \
	"measured nothing"

run_case "teeth-shards-cover-every-case: the CI matrix runs three shards" fail \
	'./scripts/teeth-shards-cover-every-case.sh' \
	"$(py 'edit(".github/workflows/gates.yml", "shard: [1, 2, 3, 4]", "shard: [1, 2, 3]")')" \
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

run_case "metered-doors-require-keys: a gateway's identity map is only warned about" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "\x7b name: TOKENFUSE_IDENTITY_STRICT, value: \"enforce\" \x7d", "\x7b name: TOKENFUSE_IDENTITY_STRICT, value: \"warn\" \x7d")')" \
	"TOKENFUSE_IDENTITY_STRICT ['warn']"

run_case "metered-doors-require-keys: the console loses Felyx's key" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("manifests/20-console.yaml", "            - name: GENARYX_COPILOT_FUSE_KEY\n              valueFrom: \x7b secretKeyRef: \x7b name: felyx-client-key, key: client_key, optional: true \x7d \x7d\n", "")')" \
	"does not read GENARYX_COPILOT_FUSE_KEY from felyx-client-key"

run_case "metered-doors-require-keys: the deploy stops minting the agents' key" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "      agents=\"$(gen 40)\" || die \"could not mint the agents\x27 client key\"\n", "      agents=\"$felyx\"\n")')" \
	"an empty cluster was refused by the mint"

run_case "metered-doors-require-keys: a re-run writes a new agents' key" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "      fi\n      ;;\n    *)\n      case \"$have\" in\n", "      fi\n      agents=\"$(gen 40)\"\n      ;;\n    *)\n      case \"$have\" in\n")')" \
	"a re-run changed the agents' key file"

run_case "metered-doors-require-keys: the agents' key may speak as Felyx" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "\"agents\":[\"agent://%s/agents/*\"]", "\"agents\":[\"agent://%s/*\"]")')" \
	"may speak as Felyx"

run_case "metered-doors-require-keys: the agent key file is readable by others" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "  chmod 0600 \"$keyfile\" || die", "  chmod 0644 \"$keyfile\" || die")')" \
	"not 600"

run_case "metered-doors-require-keys: the operator's own keys are minted over" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "      if [ \"$label\" != minted ]; then\n", "      if [ \"$label\" = never ]; then\n")')" \
	"holding the operator's own keys was refused or written"

run_case "metered-doors-require-keys: a map with no keys is accepted" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "          die \"ConfigMap $IDM_CM holds an identity map", "          : \"ConfigMap $IDM_CM holds an identity map")')" \
	"a map with no client keys was accepted"

run_case "metered-doors-require-keys: a minted secret rides the kubectl command line" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "        | k_ \"-n $IDM_NS create -f -\" >/dev/null \\\n        || die \"could not create Secret $IDM_SECRET\"", "        >/dev/null; k_ \"-n $IDM_NS create secret generic $IDM_SECRET --from-literal=$IDM_SECRET_KEY=$felyx:felyx,$agents:agents\" >/dev/null \\\n        || die \"could not create Secret $IDM_SECRET\"")')" \
	"on a kubectl command line"

run_case "metered-doors-require-keys: the closing note prints the agents' key" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "the secret in %s (it is not printed here)\\n\x27 \"$1\"", "%s, the secret in %s\\n\x27 \"$(cat \"$1\")\" \"$1\"")')" \
	"appears in what the mint printed"

run_case "metered-doors-require-keys: the closing note stops naming the key file" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "the secret in %s (it is not printed here)\\n\x27 \"$1\"", "the secret in %s (it is not printed here)\\n\x27 \"the file\"")')" \
	"does not name the agents' key file"

run_case "metered-doors-require-keys: a deploy script stops minting" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("cloud/aws/deploy-aws.sh", "identity_mint_settle \"$ROOT/agent-key\"\n", "")')" \
	"cloud/aws/deploy-aws.sh does not source lib/identity-mint.sh"

run_case "metered-doors-require-keys: the minted map binds a key id nobody minted" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "\x7b\"key_id\":\"agents\",\"unit\":\"agents\"", "\x7b\"key_id\":\"agent\",\"unit\":\"agents\"")')" \
	"the pinned gateway image refused the pair the mint made"

run_case "metered-doors-require-keys: no gateway container left to judge" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("manifests/10-planes.yaml", "          command: [\"/usr/local/bin/tokenfuse\"]\n", "          command: [\"/bin/true\"]\n")')" \
	"measured NOTHING"

run_case "metered-doors-require-keys: the mint block is gone" fail \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "# identity-mint: begin\n", "# identity-mint: start\n")')" \
	"measured nothing about the keys"

run_case "metered-doors-require-keys: a comment in the mint library is reworded" pass \
	'./scripts/metered-doors-require-keys.sh' \
	"$(py 'edit("lib/identity-mint.sh", "# What the end of a deploy says about the minted keys", "# What the end of a deploy says of the minted keys")')"

# identity/up.sh on a cluster whose keys a deploy minted, and a run that would leave none.
run_case "identity-files: a keys file alone takes over minted keys" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "if [ \"$SECRET_MINTED\" = 1 ] && [ \"$KEYS_GIVEN$MAP_GIVEN\" != 00 ]", "if [ \"$SECRET_MINTED\" = 2 ] && [ \"$KEYS_GIVEN$MAP_GIVEN\" != 00 ]")')" \
	"a keys file alone on a cluster whose keys a deploy minted was accepted"

run_case "identity-files: up.sh leaves the gateway no keys" fail \
	'IDENTITY_SECTIONS=D ./scripts/identity-files-are-checked.sh' \
	"$(py 'edit("identity/up.sh", "[ -n \"$SPEC\" ] \\\n  || die \"the gateway requires client keys", "[ -n \"$SPEC$MAPF\" ] \\\n  || die \"the gateway requires client keys")')" \
	"was not refused for that reason"

run_case "typed-mode-is-honest: the broker asks the proxy without the flag" fail \
	'./scripts/typed-mode-is-honest.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_WARDRYX_URL, value: \"http://wardryx:8090\" \x7d", "\x7b name: TOKENFUSE_WARDRYX_URL, value: \"http://typryx-wardryx-proxy:4330\" \x7d")')" \
	"WITHOUT --typed-risk-signal the broker asks"

# ---- broker-blocks-raw-secrets (CLAUDE.md invariant 51): the MCP broker blocks raw secrets and
# flagged listings and asks wardryx about every tool call, failing closed, in 52, in every typed
# render and in the image 52 pins.
run_case "broker-blocks-raw-secrets: secrets in tool arguments go back to shadow" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_MCP_DLP, value: \"block\" \x7d", "\x7b name: TOKENFUSE_MCP_DLP, value: \"shadow\" \x7d")')" \
	"TOKENFUSE_MCP_DLP 'shadow', not block"

run_case "broker-blocks-raw-secrets: TOKENFUSE_MCP_DLP goes missing" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "            - \x7b name: TOKENFUSE_MCP_DLP, value: \"block\" \x7d\n", "")')" \
	"TOKENFUSE_MCP_DLP None, not block"

run_case "broker-blocks-raw-secrets: the tool scan only warns" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_MCP_SCAN, value: \"block\" \x7d", "\x7b name: TOKENFUSE_MCP_SCAN, value: \"warn\" \x7d")')" \
	"TOKENFUSE_MCP_SCAN 'warn', not block"

run_case "broker-blocks-raw-secrets: the broker's policy hook is off" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_WARDRYX_MODE, value: \"enforce\" \x7d", "\x7b name: TOKENFUSE_WARDRYX_MODE, value: \"off\" \x7d")')" \
	"TOKENFUSE_WARDRYX_MODE 'off', not enforce"

run_case "broker-blocks-raw-secrets: the broker fails open" fail \
	'./scripts/broker-blocks-raw-secrets.sh' \
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "\x7b name: TOKENFUSE_WARDRYX_FAILMODE, value: \"closed\" \x7d", "\x7b name: TOKENFUSE_WARDRYX_FAILMODE, value: \"open\" \x7d")')" \
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
	"$(py 'edit("manifests/52-tokenfuse-mcp-broker.yaml", "          image: ghcr.io/taipanbox/tokenfuse:v1.16.0\n", "          image: ghcr.io/taipanbox/tokenfuse:v0.0.0-gate-no-such-tag\n")')" \
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

run_case "no-provider-key: the gateway loses its key file variable" fail \
	"$GATE53" \
	"$(py 'edit("manifests/10-planes.yaml", "            - { name: TOKENFUSE_UPSTREAM_KEY_FILE, value: \"/run/upstream/anthropic_key\" }\n", "")')" \
	"no literal TOKENFUSE_UPSTREAM_KEY_FILE"

run_case "no-provider-key: the gateway's key Secret becomes optional" fail \
	"$GATE53" \
	"$(py 'edit("manifests/10-planes.yaml", "secret: { secretName: gateway-upstream-key, defaultMode: 0440,", "secret: { secretName: gateway-upstream-key, optional: true, defaultMode: 0440,")')" \
	"non-optional Secret gateway-upstream-key"

run_case "no-provider-key: the gateway mounts its key where its variable does not point" fail \
	"$GATE53" \
	"$(py 'edit("manifests/10-planes.yaml", "- { name: upstream, mountPath: /run/upstream, readOnly: true }", "- { name: upstream, mountPath: /run/elsewhere, readOnly: true }")')" \
	"non-optional Secret gateway-upstream-key"

run_case "no-provider-key: the console reads the provider key from a Secret again" fail \
	"$GATE53" \
	"$(py 'edit("manifests/20-console.yaml", "            - { name: GENARYX_WEB_REQUIRE_PASSKEY, value: \"1\" }\n", "            - { name: GENARYX_WEB_REQUIRE_PASSKEY, value: \"1\" }\n            - name: ANTHROPIC_API_KEY\n              valueFrom: { secretKeyRef: { name: gateway-upstream-key, key: anthropic_key } }\n")')" \
	"reads the provider Secret gateway-upstream-key"

run_case "no-provider-key: a provider-shaped variable reads a Secret that is not a client key" fail \
	"$GATE53" \
	"$(py 'edit("manifests/20-console.yaml", "            - { name: GENARYX_WEB_REQUIRE_PASSKEY, value: \"1\" }\n", "            - { name: GENARYX_WEB_REQUIRE_PASSKEY, value: \"1\" }\n            - name: OPENAI_API_KEY\n              valueFrom: { secretKeyRef: { name: stack-keys, key: cloud_admin } }\n")')" \
	"is provider-shaped and reads Secret stack-keys"

run_case "no-provider-key: a second container takes costcrew-engine, the named exception does not cover it" fail \
	"$GATE53" \
	"$(py 'edit("manifests/49-costcrew.yaml", "            - name: crew\n", "            - name: crew-two\n")')" \
	"container crew-two: env OPENROUTER_API_KEY reads the provider Secret costcrew-engine"

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

# ---- agent tokens are wired and off by default (CLAUDE.md invariant 54) ----------------
AGT=./scripts/agent-tokens-are-wired.sh

run_case "agent-tokens: the gateway patch turns the door off" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-gateway-patch.yaml", "TOKENFUSE_AGENT_TOKENS, value: \"accept\"", "TOKENFUSE_AGENT_TOKENS, value: \"off\"")')" \
	"does not set TOKENFUSE_AGENT_TOKENS to exactly accept once"

run_case "agent-tokens: the gateway door starts with no audience" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-gateway-patch.yaml", "TOKENFUSE_DELEGATION_AUDIENCE, value: \"http://vouchryx:4310\"", "TOKENFUSE_DELEGATION_AUDIENCE, value: \"\"")')" \
	"leaves TOKENFUSE_DELEGATION_AUDIENCE empty"

run_case "agent-tokens: the gateway accepts a wider audience than vouchryx's issuer" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-gateway-patch.yaml", "TOKENFUSE_DELEGATION_AUDIENCE, value: \"http://vouchryx:4310\"", "TOKENFUSE_DELEGATION_AUDIENCE, value: \"http://vouchryx.other:4310\"")')" \
	"not vouchryx's issuer"

run_case "agent-tokens: a stopped agent keeps working while the list is unreadable" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-gateway-patch.yaml", "TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE, value: \"closed\"", "TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE, value: \"open\"")')" \
	"does not set TOKENFUSE_DELEGATION_REVOCATIONS_FAILMODE to closed"

run_case "agent-tokens: the revocation list may be 300 s old" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-gateway-patch.yaml", "TOKENFUSE_DELEGATION_REVOCATIONS_MAX_AGE_SECS, value: \"60\"", "TOKENFUSE_DELEGATION_REVOCATIONS_MAX_AGE_SECS, value: \"300\"")')" \
	"60 seconds or less"

run_case "agent-tokens: the door is on in the default gateway" fail \
	"$AGT" \
	"$(py 'edit("manifests/10-planes.yaml", "            - { name: TOKENFUSE_CACHE, value: \"off\" }\n", "            - { name: TOKENFUSE_CACHE, value: \"off\" }\n            - { name: TOKENFUSE_AGENT_TOKENS, value: \"accept\" }\n")')" \
	"names TOKENFUSE_AGENT_TOKENS"

run_case "agent-tokens: vouchryx takes its registry as a literal, not from a ConfigMap" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-vouchryx-patch.yaml", "valueFrom: { configMapKeyRef: { name: vouchryx-agents, key: agents } }", "value: \"agent://k2.example/agents/x|agents|acme|sha256:00\"")')" \
	"does not read VOUCHRYX_AGENTS from a ConfigMap"

run_case "agent-tokens: the example agent keeps the default ServiceAccount token" fail \
	"$AGT" \
	"$(py 'edit("agent-tokens/example-agent.yaml", "      automountServiceAccountToken: false\n      securityContext", "      automountServiceAccountToken: true\n      securityContext")')" \
	"does not turn off the default ServiceAccount token"

run_case "agent-tokens: the example agent's token is for another audience" fail \
	"$AGT" \
	"$(py 'edit("agent-tokens/example-agent.yaml", "audience: \"http://vouchryx:4310\"", "audience: \"http://other.example:4310\"")')" \
	"not vouchryx's issuer"

run_case "agent-tokens: agent pods may reach the open internet" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-network.yaml", "    - to:\n        - podSelector: { matchLabels: { app: tokenfuse-gateway } }\n", "    - to:\n        - ipBlock: { cidr: 0.0.0.0/0 }\n    - to:\n        - podSelector: { matchLabels: { app: tokenfuse-gateway } }\n")')" \
	"opens egress to 0.0.0.0/0"

run_case "agent-tokens: the opt-in applies before it refuses" fail \
	"$AGT" \
	"$(py 'edit("agent-tokens/up.sh", "[ -n \"$REGISTRY\" ] || die \"--registry FILE is required. Nothing was applied.\"", "true")')" \
	"does not refuse before it applies anything"

run_case "agent-tokens: no gateway patch left to judge" fail \
	"$AGT" \
	"$(py 'import os; os.remove("manifests/58-agent-tokens-gateway-patch.yaml")')" \
	"measured nothing"

run_case "agent-tokens: a comment naming the switch in the default gateway is not a fault" pass \
	"$AGT" \
	"$(py 'edit("manifests/10-planes.yaml", "            - { name: TOKENFUSE_CACHE, value: \"off\" }\n", "            # TOKENFUSE_AGENT_TOKENS is set by 58-agent-tokens-gateway-patch.yaml, never here.\n            - { name: TOKENFUSE_CACHE, value: \"off\" }\n")')"

# ---- the broker's relayed check has its key while the door is on (CLAUDE.md invariant 54) --
run_case "agent-tokens: broker key missing while the door is on" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-broker-patch.yaml", "TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE, value: \"/run/taint/key\"", "TOKENFUSE_MCP_TAINT_GATEWAY_KEY_FILE, value: \"\"")')" \
	"broker key missing while the door is on"

run_case "agent-tokens: the broker's taint check fails open" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-broker-patch.yaml", "TOKENFUSE_MCP_TAINT_FAILMODE, value: \"closed\"", "TOKENFUSE_MCP_TAINT_FAILMODE, value: \"open\"")')" \
	"leaves the broker's taint check to fail open"

run_case "agent-tokens: the mint does not give the broker its key" fail \
	"$AGT" \
	"$(py 'edit("lib/identity-mint.sh", "\"agents\":[\"agent://%s/*\"]", "\"agents\":[\"agent://%s/x\"]")')" \
	"does not mint the broker's client key"

run_case "agent-tokens: the broker's key Secret is projected under another name" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-broker-patch.yaml", "client_key, path: key", "client_key, path: other")')" \
	"is not projected to the file"

run_case "agent-tokens: the broker may reach the open internet" fail \
	"$AGT" \
	"$(py 'edit("manifests/58-agent-tokens-broker-network.yaml", "        - podSelector: { matchLabels: { app: tokenfuse-gateway } }\n      ports:\n        - { protocol: TCP, port: 4100 }\n    - to:\n        - podSelector: { matchLabels: { app: vouchryx } }", "        - ipBlock: { cidr: 0.0.0.0/0 }\n    - to:\n        - podSelector: { matchLabels: { app: tokenfuse-gateway } }\n      ports:\n        - { protocol: TCP, port: 4100 }\n    - to:\n        - podSelector: { matchLabels: { app: vouchryx } }")')" \
	"opens the broker's egress to 0.0.0.0/0"

# A listing is not a run. Stop before the verdict, which would count cases this
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
