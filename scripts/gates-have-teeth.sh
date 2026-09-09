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
# A CASE CAN PASS IN CI AND MISBEHAVE LOCALLY
#
# On bash 3.2, which is the bash on this machine, an unquoted brace pair
# inside "$(...)" splits the argument into two words, and CI's bash 5 does
# not: commit 939f686 (a two-brace-pair case, since fixed in 73a2e63) ran
# green in CI while reporting WRONG REASON here, so a case that only ever
# runs in CI is not proven at all.

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
	"$(py 'edit("security-tests.sh", "image: ghcr.io/taipanbox/genaryx-console:v0.1.2", "image: ghcr.io/taipanbox/genaryx-console:latest")')" \
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
# Planted nested, not at the repository root: a root-level planted-secret.pem
# left two mutants alive, one that skips any path containing a slash and one
# that matches the whole path instead of the basename, and neither would
# have caught the file this gate exists for. Under a synthetic
# gates-have-teeth-plant/ directory rather than literally at
# cloud/gcp/terraform.tfvars.bak: a real GCP or AWS run leaves real,
# gitignored terraform state at that exact path (confirmed present on the
# machine this case was written on), and `git reset --hard` only ever
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
# distinguishes the two mutants above. fnmatch's "*" spans "/" (verified:
# fnmatch.fnmatch("cloud/gcp/x.tfvars.bak", "*.tfvars.*") is True), so a
# whole-path-instead-of-basename mutant still happens to catch the glob
# case above by accident. It cannot accidentally catch an EXACT shape like
# "terraform.tfstate": the whole path is never equal to the bare name.
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
	"never patches"

run_case "deploy-flags-agree: no deploy path left to judge" fail \
	'./scripts/deploy-flags-agree.sh' \
	"$(py 'import os
for f in ("deploy.sh", "cloud/aws/deploy-aws.sh", "cloud/gcp/deploy-gcp.sh"):
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
