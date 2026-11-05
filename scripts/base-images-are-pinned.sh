#!/usr/bin/env bash
# Every image this repository builds from is pinned whole (CLAUDE.md invariant 80).
#
# pinned-images.sh holds what the manifests NAME: the output of a build. This holds what a build
# READS. Until 2026-11-05 nothing did, and images/caddy.Dockerfile compiled from `caddy:2-builder-alpine`
# with the DNS plugin at its latest, so a rebuild of one tag could produce a different binary and the file
# could not say which Go made it. On the night this gate was written `caddy:2.11.9-builder-alpine` had no
# linux/amd64 entry and `caddy:2.11.9-alpine` no arm64 one, both half-published: a rebuild from the moving
# tag on that night was a coin toss on the architecture.
#
# Read from every images/*Dockerfile*, found by discovery so the next one is held without being named:
#
#   1. a `# syntax=` line and every external FROM, and any `--from=` naming an image, carry
#      name:tag@sha256:<64 hex>, with a tag that says something (not `latest`) and no variable in it;
#   2. one name:tag is one digest in every file;
#   3. every golang base names the same Go, so a Go advisory moves them together;
#   4. the first instruction of each golang stage asserts that Go. A digest outranks the tag beside it, so
#      a bump that moved the tag alone would keep the old Go under the new name, and no gate can see that
#      offline. The build can;
#   5. `go install` names a version, and `xcaddy build` names Caddy's version (the same one as the
#      `caddy:<version>-alpine` base) and each plugin's.
#
# Not held: what apt-get and apk install on top of a pinned base. They take the distribution's current
# packages at build time, and that is what a security update wants of them.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import re
import sys

DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
ASSERT = re.compile(r'RUN test "\$\(go env GOVERSION\)" = go(\S+)$')

files = sorted(glob.glob("images/*Dockerfile*"))
if not files:
    print("FAIL: no images/*Dockerfile*, so this measured NOTHING")
    sys.exit(1)

bad = []
bases = 0
digests = {}  # name:tag -> {digest: [file]}
go_versions = {}  # version -> [file]
caddy_builds = 0


def check_ref(where, ref):
    """Return (name, tag) when ref is pinned whole, else record why it is not."""
    if "$" in ref:
        bad.append(f"{where}: `{ref}` has a variable in it, so the tag and the digest beside it cannot be read together")
        return None
    name_tag, sep, digest = ref.partition("@")
    if not sep or not DIGEST.fullmatch(digest):
        bad.append(f"{where}: `{ref}` has no digest, so a rebuild can read a different base (want name:tag@sha256:<64 hex>)")
        return None
    name, colon, tag = name_tag.rpartition(":")
    if not colon or "/" in tag or tag == "latest":
        bad.append(f"{where}: `{ref}` names no version beside its digest, so nothing says what the digest is")
        return None
    digests.setdefault(name_tag, {}).setdefault(digest, []).append(where)
    return name, tag


for path in files:
    lines = open(path).read().split("\n")
    stages = set()
    heredoc = None
    caddy_bases = set()
    built = None
    for number, line in enumerate(lines, 1):
        where = f"{path}:{number}"
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue
        syntax = re.match(r"#\s*syntax\s*=\s*(\S+)", line)
        if syntax:
            bases += 1
            check_ref(where, syntax.group(1))
            continue
        if line.lstrip().startswith("#"):
            continue
        opener = re.search(r"<<-?['\"]?([A-Za-z_]+)['\"]?", line)
        if opener and re.match(r"\s*(RUN|COPY)\b", line, re.I):
            heredoc = opener.group(1)

        source = re.match(r"\s*FROM\s+(.*)$", line, re.I)
        if source:
            words = [w for w in source.group(1).split() if not w.startswith("--")]
            ref = words[0]
            alias = words[2].lower() if len(words) >= 3 and words[1].lower() == "as" else None
            if ref.lower() not in stages and ref != "scratch":
                bases += 1
                pinned = check_ref(where, ref)
                if pinned and pinned[0] == "golang":
                    version = re.match(r"\d+\.\d+(\.\d+)?", pinned[1])
                    version = version.group(0) if version else pinned[1]
                    go_versions.setdefault(version, []).append(where)
                    following = next((l.strip() for l in lines[number:] if l.strip() and not l.lstrip().startswith("#")), "")
                    asserted = ASSERT.match(following)
                    if not asserted:
                        bad.append(f"{where}: the golang stage does not start with `RUN test \"$(go env GOVERSION)\" = go{version}`, "
                                   "so a tag moved without its digest would keep the old Go in silence")
                    elif asserted.group(1) != version:
                        bad.append(f"{where}: the stage asserts go{asserted.group(1)} on a golang:{version} base")
                if pinned and pinned[0] == "caddy":
                    caddy_bases.add(pinned[1].removesuffix("-alpine"))
            if alias:
                stages.add(alias)
            continue

        for ref in re.findall(r"(?:--|,)from=([^\s,]+)", line):
            if ref.lower() not in stages and not ref.isdigit():
                bases += 1
                check_ref(where, ref)

        install = re.search(r"\bgo install\s+(\S+)", line)
        if install and not re.search(r"@v\d", install.group(1)):
            bad.append(f"{where}: `go install {install.group(1)}` names no version, so a rebuild can install something else")

        build = re.search(r"\bxcaddy build\b(.*)$", line)
        if build:
            caddy_builds += 1
            words = build.group(1).split()
            version = words[0] if words and re.fullmatch(r"v\d+\.\d+\.\d+", words[0]) else None
            if version is None:
                bad.append(f"{where}: `xcaddy build` names no Caddy version, so it builds whatever is latest")
            built = version
            plugins = [words[i + 1] for i, w in enumerate(words[:-1]) if w == "--with"]
            for plugin in plugins:
                if not re.search(r"@v\d", plugin):
                    bad.append(f"{where}: the plugin `{plugin}` names no version, so a rebuild takes its latest")

    # Judged here and not at the `xcaddy build` line: the runtime base comes after the build in the file.
    if built and caddy_bases and built[1:] not in caddy_bases:
        bad.append(f"{path}: xcaddy builds Caddy {built} on a caddy:{sorted(caddy_bases)[0]}-alpine base, so the file names two Caddies")

if bases == 0:
    print("FAIL: no external base in images/*Dockerfile*, so this measured NOTHING")
    sys.exit(1)

for name_tag, seen in sorted(digests.items()):
    if len(seen) > 1:
        bad.append(f"{name_tag} carries {len(seen)} digests: " + "; ".join(f"{d[7:19]} in {', '.join(w)}" for d, w in seen.items()))
if len(go_versions) > 1:
    bad.append("the golang bases name more than one Go, and a Go advisory moves them together: "
               + "; ".join(f"{v} in {', '.join(w)}" for v, w in sorted(go_versions.items())))

if bad:
    for problem in bad:
        print(f"FAIL: {problem}")
    sys.exit(1)

# After the list, not before it: a golang base that fails rule 1 never reaches go_versions, and saying
# "measured nothing" there would hide the lines that are actually wrong.
if not go_versions:
    print("FAIL: no golang base found, so the rule on Go measured NOTHING")
    sys.exit(1)
if not caddy_builds:
    print("FAIL: no `xcaddy build` found, so the rule on Caddy measured NOTHING")
    sys.exit(1)

go = next(iter(go_versions))
print(f"OK: {bases} external references across {len(files)} Dockerfiles, each pinned by digest; "
      f"{len(go_versions[go])} golang stages on Go {go}, each asserting it.")
PY
