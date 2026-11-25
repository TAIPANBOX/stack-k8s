#!/usr/bin/env bash
# CLAUDE.md invariant 79. The console proves a candidate policy by running `wardryx replay` and a candidate
# budget by running `tokenfuse backtest` (genaryx invariants 40 and 41), and a proof is only as good as the
# engine behind it. Since stack-k8s 1.19.0 the console image is genaryx's own release
# (ghcr.io/taipanbox/genaryx), built and signed by genaryx's release workflow, which copies both engines out
# of the TAIPANBOX images by digest and labels each (`dev.taipanbox.engine.<name>`). This repository no longer
# builds the console, so what it can hold is what the pinned image carries, said where a reader sees it:
#
#   images/console-engines.json records the image the manifests pin and the two engines its labels name. An
#   engine that is not the reference the manifests run for that plane is a LAG, and a lag is allowed only
#   with its reason written beside it, so it is reported, never hidden: a proof about another engine than
#   the one the stack enforces with is something the operator must be able to see.
#
# WHAT THIS CHECKS
#
#   1. Every console image reference in manifests/ and security-tests.sh (genaryx or genaryx-console) is the
#      one images/console-engines.json names, and they are all the same.
#   2. For wardryx and tokenfuse, the manifests name exactly one reference each, and the recorded engine is
#      that reference, or the engine is in `lag` with a reason. A `lag` entry for an engine that matches is
#      stale and fails, and so does a lag with no reason.
#   3. Live: the image's own labels, read from the registry for every platform it publishes, are the ones
#      the file records. Without docker buildx or the registry, this says it measured NOTHING; it does not
#      pass. GATE_OFFLINE=1 skips only this step, and says so in its last line.
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import json
import os
import re
import subprocess
import sys

ENGINES = ("wardryx", "tokenfuse")
FILE = "images/console-engines.json"
REF = r"ghcr\.io/taipanbox/(?P<name>[a-z0-9-]+):(?P<tag>v[0-9][0-9A-Za-z.\-]*)@sha256:(?P<digest>[0-9a-f]{64})"
CONSOLE = re.compile(r"image:\s*(ghcr\.io/taipanbox/genaryx(?:-console)?:\S+)")
bad = []

if not os.path.exists(FILE):
    print(f"FAIL: {FILE} is not there, so this measured NOTHING")
    sys.exit(1)
try:
    rec = json.load(open(FILE))
except ValueError as e:
    print(f"FAIL: {FILE} is not JSON ({e}), so this measured NOTHING")
    sys.exit(1)
image = rec.get("image") or ""
engines = rec.get("engines") or {}
lag = rec.get("lag") or {}
if not re.fullmatch(REF, image):
    bad.append(f"{FILE}: image {image!r} is not a ghcr.io/taipanbox reference by tag and digest")

# 1. every console reference is the recorded one
consoles = []
for path in sorted(glob.glob("manifests/*.yaml")) + ["security-tests.sh"]:
    if not os.path.exists(path):
        continue
    for line in open(path).read().split("\n"):
        if line.lstrip().startswith("#"):
            continue
        m = CONSOLE.search(line)
        if m:
            consoles.append((path, m.group(1)))
if not consoles:
    print("FAIL: no console image is named in manifests/ or security-tests.sh, so this measured NOTHING")
    sys.exit(1)
for path, ref in consoles:
    if ref != image:
        bad.append(f"{path}: the console image is {ref}, but {FILE} records {image}")

# 2. the recorded engines against the manifests
pins = {}
for path in sorted(glob.glob("manifests/*.yaml")):
    text = "\n".join(l for l in open(path).read().split("\n") if not l.lstrip().startswith("#"))
    for m in re.finditer(r"image:\s*" + REF, text):
        pins.setdefault(m.group("name"), set()).add(f"{m.group('tag')}@sha256:{m.group('digest')}")
lags = []
for name in ENGINES:
    want = pins.get(name, set())
    if len(want) != 1:
        bad.append(f"manifests/ name {len(want)} references for ghcr.io/taipanbox/{name}, so there is no one engine to compare")
        continue
    want = next(iter(want))
    got = engines.get(name)
    if not got:
        bad.append(f"{FILE} records no {name} engine")
        continue
    if not re.fullmatch(r"v[0-9][0-9A-Za-z.\-]*@sha256:[0-9a-f]{64}", got):
        bad.append(f"{FILE}: the {name} engine {got!r} is not a tag and digest")
        continue
    if got == want:
        if name in lag:
            bad.append(f"{FILE}: a lag is recorded for {name}, but the console's {name} is the stack's ({want}): the entry is stale")
        continue
    reason = (lag.get(name) or "").strip()
    if not reason:
        bad.append(f"the console's {name} is {got}, the stack runs {want}, and {FILE} gives no reason under lag: "
                   "a proof about another engine than the one that enforces is not to be hidden")
        continue
    lags.append(f"{name} {got.split('@')[0]} in the console, {want.split('@')[0]} in the stack")
for name in lag:
    if name not in ENGINES:
        bad.append(f"{FILE}: lag names {name}, which is no engine this gate knows")

# 3. live: the image's own labels
live = "skipped (GATE_OFFLINE=1)"
if os.environ.get("GATE_OFFLINE") != "1" and re.fullmatch(REF, image):
    try:
        out = subprocess.run(["docker", "buildx", "imagetools", "inspect", image, "--format", "{{json .Image}}"],
                             capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        out = None
        err = str(e)
    if out is None or out.returncode != 0:
        print(f"FAIL: could not read the labels of {image} ({(out.stderr.strip() if out else err)[:200]}), so the "
              "image's engines are measured NOTHING. Set GATE_OFFLINE=1 to check the file alone, and say so.")
        sys.exit(1)
    try:
        data = json.loads(out.stdout)
    except ValueError:
        print(f"FAIL: the registry's answer for {image} is not JSON, so the image's engines are measured NOTHING")
        sys.exit(1)
    if "config" in data:  # a single-platform image answers with one config
        data = {"default": data}
    if not data:
        print(f"FAIL: {image} has no platform image, so its engines are measured NOTHING")
        sys.exit(1)
    for plat, img in sorted(data.items()):
        labels = ((img or {}).get("config") or {}).get("Labels") or {}
        for name in ENGINES:
            have = labels.get(f"dev.taipanbox.engine.{name}")
            if have != engines.get(name):
                bad.append(f"{image} ({plat}): its label dev.taipanbox.engine.{name} is {have!r}, but {FILE} records "
                           f"{engines.get(name)!r}")
    live = f"read from the registry for {len(data)} platform(s)"

if bad:
    for b in bad:
        print("FAIL " + b)
    print(f"{len(bad)} problem(s). See CLAUDE.md invariant 79.")
    sys.exit(1)

print(f"OK: {len(consoles)} console reference(s), all {image.split('@')[0]}; its engines are the stack's"
      + (f", with {len(lags)} recorded lag(s): {'; '.join(lags)}" if lags else "")
      + f"; the labels {live}.")
PY
