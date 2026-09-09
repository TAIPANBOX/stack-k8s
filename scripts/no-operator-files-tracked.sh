#!/usr/bin/env bash
# Fails when `git ls-files` tracks a file shaped like an operator-only
# secret: a terraform var file, a state file, a private key, an issued
# kubeconfig, or a backup an editor or a script leaves beside one of those.
# Not a content scanner: it never opens a file, it only reads the name.
#
# WHY A SHAPE CHECK, WHEN THIS REPO ALREADY HAS CONTENT AND MANIFEST GATES
#
# `cloud/gcp/terraform.tfvars.bak` was tracked and published for 76 commits
# (GOTCHAS.md entry 99). `.gitignore` said `cloud/**/*.tfvars`, an exact
# suffix, and `preflight.sh` writes the backup right beside the real file
# with `.bak` on the end, one character short of matching. Nothing else here
# would have caught it landing: `gotchas-classified.sh` reads GOTCHAS.md,
# `manifest-is-true.sh` and `pinned-images.sh` read manifests/ and
# security-tests.sh, `closed-by-default.sh` reads kustomization.yaml. Every
# gate in this repository until now answers "is what is here correct",
# never "should this be here at all". See GOTCHAS.md entry 100 for the
# second time this exact shape of gap showed up, caught that time by a
# person reading `git status` rather than by anything that runs on its own.
#
# WHAT THIS CANNOT SEE
#
#   - Content. A file named safely can hold anything; a file named unsafely
#     can be empty. This gate reads names only and never opens a file: the
#     content and manifest gates above it are what carry that half.
#   - Anything not tracked. An operator's real terraform.tfvars, sitting on
#     disk and correctly gitignored, is invisible here on purpose. This gate
#     exists to keep such a file OUT of `git ls-files`, not to complain that
#     one exists on some machine.
#   - History. A file already untracked, the way entry 99's `.bak` now is,
#     no longer appears in `git ls-files` and this gate has nothing left to
#     say about it. The content it once held is still in every clone made
#     before the fix; purging that is a separate, larger decision (entry 99
#     again).
#   - The index, not the push. Both callers read one tree: `git ls-files`
#     reads the current index, and CI checks out a single commit. An
#     operator file added and removed again inside the commits a push
#     carries never appears in that tree and passes here clean, even though
#     its content sits in the pushed history forever.
#   - Directory context. Matching is on the basename alone, so a name too
#     common to denylist by itself, like `config`, stays invisible however
#     sensitive its directory makes it: `.kube/config` and
#     `.docker/config.json` both hold real credentials and this script will
#     never see either.
#   - Only the shapes below. This is a denylist, not an allowlist: an
#     operator-only file under a name nobody has added to SHAPES yet passes
#     clean.
#
# THE ALLOW LIST
#
# A tracked path can legitimately match a shape below on purpose: a template
# example carries no live value by construction. Checked by hand against
# `git ls-files` on 2026-09-09, against every shape below, before this list
# was written and again after the list was widened the same day: nothing
# currently tracked matches any of them. This repo's two tracked
# *.example.* templates, manifests/secrets.example.yaml and
# tunnel/site.example.yaml, are both `.yaml` and match none of the shapes
# here either, so neither needs an entry today.
#
# If that ever changes, add the path below with the one-line reason a human
# can check against the file itself. An allow-listed path that `git
# ls-files` no longer tracks is itself a failure below, so this list cannot
# go stale silently: see gates-have-teeth.sh for the case that proves it.
# Nor can it carry an entry that suppresses nothing: an allow-listed path
# whose basename matches no shape below is also a failure, for the same
# reason, with its own case in gates-have-teeth.sh.
#
# EXIT CODES: 0 clean, 1 a tracked operator file, a stale allow-list entry,
# or a dead allow-list entry (one that matches no shape) was found, 2 this
# measured nothing (git ls-files came back empty, or git itself could not
# be asked).
#
# DEPENDENCIES: bash, git, python3. Nothing else.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import fnmatch
import subprocess
import sys

# Every shape an operator-only file can take. Matched against the
# lower-cased basename only, so a pattern with no "/" behaves like a
# slash-free .gitignore line: it matches at any depth, not only at the top
# of the tree, and it matches regardless of how the name is cased.
SHAPES = [
    # terraform: variables, state, and a plan nobody remembered to exclude.
    # tfplan is also named in .gitignore; this is the tracked-file half of
    # the same rule.
    "*.tfvars", "*.tfvars.*",
    "terraform.tfstate", "terraform.tfstate.*",
    "tfplan",
    # editor, terraform and script backups, which carry whatever the file
    # beside them held. GOTCHAS 99 is one of these.
    "*.bak", "*.orig", "*.save", "*.swp", "*~", "*.backup", "*.old",
    # environment files, however the tool that reads them names the file
    ".env", ".env.*", "*.env", ".envrc",
    # keys and certificates
    "*.pem", "*.key", "*.p12", "*.pfx",
    "id_rsa*", "id_ed25519*", "id_ecdsa*",
    # a kubeconfig: this repo's own default name, an operator's
    # KUBECONFIG_OUT override, or k3s's own name for the file install.sh
    # copies it from (/etc/rancher/k3s/k3s.yaml)
    "kubeconfig.yaml", "kubeconfig-*.yaml", "kubeconfig", "kubeconfig.yml",
    "k3s.yaml",
    # issued device configs (up.sh) and anything else ending .conf
    "*.conf",
    # credential stores
    "credentials", "*credentials*.json", ".git-credentials", ".netrc",
    # shell and client history, which can hold a pasted secret verbatim
    ".*_history",
]

# Paths tracked on purpose despite matching a shape above, each with the
# reason a human can check against the file. See this script's header for
# what was checked on 2026-09-09 and why it is empty today.
ALLOWED = {
}

try:
    tracked_raw = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, text=True, check=True,
    ).stdout
except (subprocess.CalledProcessError, OSError) as exc:
    print(f"FAIL: could not run `git ls-files`: {exc}")
    print("      This measured NOTHING: it cannot tell whether an operator file")
    print("      is tracked if it cannot ask git what is tracked at all.")
    sys.exit(2)

tracked = [p for p in tracked_raw.split("\0") if p]

if not tracked:
    print("FAIL: `git ls-files` listed no files at all, so this measured NOTHING.")
    print("      A checkout with zero tracked files is not the same thing as one")
    print("      with zero tracked operator files, and this check cannot tell them")
    print("      apart from here. If this ran outside a checkout, in a bare clone,")
    print("      or before the first commit, that is where to look.")
    sys.exit(2)

def shape_of(path):
    """The shape `path` matches, or None. Matched on the basename, folded to
    lower case: SECRET.PEM, ID_RSA and Kubeconfig.yaml each match their
    shape exactly as a lower-cased *.pem, id_rsa* and kubeconfig.yaml
    would."""
    base = path.rsplit("/", 1)[-1].lower()
    return next((s for s in SHAPES if fnmatch.fnmatch(base, s)), None)


tracked_set = set(tracked)
offenders = []
seen_allowed = set()

for path in tracked:
    shape = shape_of(path)
    if shape is None:
        continue
    if path in ALLOWED:
        seen_allowed.add(path)
    else:
        offenders.append((path, shape))

problems = 0

for path in sorted(seen_allowed):
    print(f"note: {path} matches an operator-file shape and is allow-listed: {ALLOWED[path]}")

for path, shape in sorted(offenders):
    # repr(), not the raw path: a tracked path can legally hold a newline
    # (git allows any byte but NUL and "/" in a filename), and printing one
    # raw would split this FAIL line into two, one of which no longer starts
    # with "FAIL:" and reads as a clean line to anything scanning output.
    print(f"FAIL: {path!r} is tracked and matches the operator-file shape {shape!r}")
    problems += 1

# An allow-listed path git no longer tracks is a hole with a comment
# attached: the reason it was safe cannot be checked against a file that is
# not there, and nobody would notice it sitting unused. Existence is
# rechecked against the full tracked set, not just against what matched a
# shape this run, so a rename that also changed the extension still trips
# this rather than silently going quiet.
for path in sorted(set(ALLOWED) - tracked_set):
    print(f"FAIL: {path!r} is allow-listed in this script but `git ls-files` no")
    print("      longer tracks it. Remove it from ALLOWED: an allow-list entry")
    print("      for a file that is not there is a hole nobody would notice.")
    problems += 1

# The other way an entry rots: still tracked, but its basename never matched
# a shape in the first place, so it has been suppressing nothing since the
# day it was written and nobody would notice that either. Skips anything
# already reported stale above, since a path that is not tracked at all has
# no shape to check.
for path in sorted(ALLOWED):
    if path not in tracked_set:
        continue
    if shape_of(path) is not None:
        continue
    print(f"FAIL: {path!r} is allow-listed in this script but matches no operator-file shape")
    print("      below, so the entry suppresses nothing. Remove it: a line that does")
    print("      nothing hides the day it starts doing something.")
    problems += 1

if problems:
    print()
    print(f"{problems} problem(s). A tracked operator file publishes whatever it")
    print("holds to everyone who can read this repository, the way")
    print("cloud/gcp/terraform.tfvars.bak did for 76 commits. See GOTCHAS.md")
    print("entries 99 and 100, and this script's header for the allow-list rule.")
    sys.exit(1)

print(f"OK: {len(tracked)} tracked file(s) checked against {len(SHAPES)} operator-file "
      f"shape(s), none found ({len(ALLOWED)} allow-listed by name).")
PY
