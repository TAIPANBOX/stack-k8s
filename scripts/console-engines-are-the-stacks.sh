#!/usr/bin/env bash
# CLAUDE.md invariant 79. The console proves a candidate policy by running `wardryx replay` and a candidate
# budget by running `tokenfuse backtest` (genaryx invariants 40 and 41), and a proof is only as good as the
# engine behind it. images/console.Dockerfile copies both binaries from the images the stack itself runs, and
# the references it copies from are the manifests' own, digest for digest: the engine that replays a decision
# is the engine that took it, and a stack that moves one without the other has proofs about a different
# engine than the one it enforces with.
#
# WHAT THIS CHECKS
#
#   1. console.Dockerfile has a `FROM ghcr.io/taipanbox/<name>:<tag>@sha256:<hex> AS <name>-engine` stage for
#      wardryx and for tokenfuse, and copies the binary out of each into /usr/local/bin.
#   2. Each of those references is the one manifests/ names for that image. The manifests are read for every
#      `image: ghcr.io/taipanbox/<name>:<tag>@sha256:<hex>`; they must name exactly one reference per image,
#      and the Dockerfile's must be it.
#   3. The `dev.taipanbox.engine.<name>` label says the same reference, so `docker inspect` answers which engine
#      replayed a proof.
#   4. Both jobs of console-image.yml run both engines in their smoke test: a binary built for another
#      architecture exits with "exec format error", not with a message.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import re
import sys

ENGINES = ("wardryx", "tokenfuse")
REF = r"ghcr\.io/taipanbox/(?P<name>[a-z0-9-]+):(?P<tag>v[0-9][0-9A-Za-z.\-]*)@sha256:(?P<digest>[0-9a-f]{64})"
bad = []

try:
    dockerfile = open("images/console.Dockerfile").read()
except OSError:
    print("FAIL: images/console.Dockerfile is not there, so this measured NOTHING")
    sys.exit(1)

# What the manifests name, per image.
named = {}
files = sorted(glob.glob("manifests/*.yaml"))
for path in files:
    for line in open(path).read().split("\n"):
        m = re.match(r"^\s*(?:-\s*)?image:\s*" + REF + r"\s*$", line)
        if m and m.group("name") in ENGINES:
            named.setdefault(m.group("name"), set()).add(f"{m.group('tag')}@sha256:{m.group('digest')}")

stages = {}
for m in re.finditer(r"^FROM\s+" + REF + r"\s+AS\s+(?P<alias>\S+)\s*$", dockerfile, re.M):
    stages[m.group("name")] = (f"{m.group('tag')}@sha256:{m.group('digest')}", m.group("alias"))

checked = 0
for name in ENGINES:
    if name not in stages:
        bad.append(f"images/console.Dockerfile has no `FROM ghcr.io/taipanbox/{name}:<tag>@sha256:<digest> AS {name}-engine` stage, "
                   f"so the console has no {name} engine for its proofs")
        continue
    ref, alias = stages[name]
    checked += 1
    if alias != f"{name}-engine":
        bad.append(f"the {name} stage is named {alias!r}, and the copy below looks for {name}-engine")
    if not re.search(r"^COPY --from=" + re.escape(alias) + r"\s+\S+\s+/usr/local/bin/" + name + r"\s*$", dockerfile, re.M):
        bad.append(f"images/console.Dockerfile does not copy the binary out of the {alias} stage to /usr/local/bin/{name}")
    refs = named.get(name, set())
    if not refs:
        bad.append(f"manifests/ names no {name} image by tag and digest, so the console's engine has nothing to equal")
    elif len(refs) > 1:
        bad.append(f"manifests/ names {len(refs)} different {name} references ({', '.join(sorted(refs))}): the stack runs one engine, and the console's must be it")
    elif ref not in refs:
        bad.append(f"the console's {name} engine is {ref}, which differs from the stack's {next(iter(refs))}")
    label = re.search(r'^LABEL dev\.taipanbox\.engine\.' + name + r'="([^"]*)"\s*$', dockerfile, re.M)
    if label is None:
        bad.append(f"images/console.Dockerfile has no dev.taipanbox.engine.{name} label")
    elif label.group(1) != ref:
        bad.append(f"the dev.taipanbox.engine.{name} label says {label.group(1)}, and the stage copies {ref}")

try:
    workflow = open(".github/workflows/console-image.yml").read()
except OSError:
    print("FAIL: .github/workflows/console-image.yml is not there, so this measured NOTHING")
    sys.exit(1)
loops = re.findall(r"^\s*for t in ([^;]+); do\s*$", workflow, re.M)
if len(loops) < 2:
    bad.append(f"console-image.yml has {len(loops)} smoke loop(s), and both the build and the pull-request job run one")
for loop in loops:
    if not re.search(r"(^|\s)wardryx(\s|$)", loop):
        bad.append(f"a smoke loop of console-image.yml does not run wardryx: {loop.strip()}")
    if '"tokenfuse constants"' not in loop:
        bad.append(f"a smoke loop of console-image.yml does not run tokenfuse (as `tokenfuse constants`, since with no argument it starts the gateway): {loop.strip()}")

if checked == 0:
    print("FAIL: no engine stage found in images/console.Dockerfile, so this measured NOTHING")
    sys.exit(1)

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 79.")
    sys.exit(1)

print(f"OK: the console's {' and '.join(ENGINES)} engines are the stack's, digest for digest "
      f"({', '.join(stages[n][0].split('@')[0] for n in ENGINES)}), labelled, copied, and run by both smoke tests.")
PY
