#!/usr/bin/env bash
# Fails when a scheduled mockryx drill in manifests/*.yaml cannot start, cannot
# see a reaction its scenarios wait for, or runs its hostile scenarios more than
# once. CLAUDE.md invariant 90.
#
# WHY
#
# mockryx refuses to run at all (exit 2, before a single request) when a loaded
# scenario declares `expect.event` and no `--watch-events` / MOCKRYX_WATCH_EVENTS
# names a log to poll for it (mockryx cmd/mockryx/main.go, "Fail fast"). The
# top-level `/scenarios` of mockryx v0.5.0 has three such files, so the CronJob
# `drills` failed on every run, on main, since the pin reached v0.5.0: the drill
# the box keeps for proving its guardrails proved nothing and said so only in a
# Job's log. Nothing here read the scenarios against the job's environment.
#
# And a watched path that does not exist is not an error to mockryx: it polls it
# until the step's `within` runs out and reports a Finding, "no <source>/<type>
# event observed". So a path that names nothing in the pod is a false gap, which
# is why each path is checked against the container's own mounts and each bus
# stream against the bus owner's table (manifests/11-bus.yaml).
#
# A drill that finds a gap exits 1, and a Job with the default backoffLimit (6)
# runs it again: the same hostile scenarios against the same gateway, spending
# real budget each time (runaway-budget.yaml exists to trip the breaker), and
# finding the same gap. drills-broker had `backoffLimit: 0`; drills did not.
#
# WHAT IT READS
#
# Every YAML document under manifests/ that is a CronJob with a container whose
# image is ghcr.io/taipanbox/mockryx. For each: the pinned tag, the scenario
# directory (the last element of `args`), MOCKRYX_WATCH_EVENTS, the container's
# volumeMounts, and the job's backoffLimit.
#
# EXPECT below is what each pinned mockryx's scenario directory waits for, read
# from mockryx's own tree at that tag (`grep -A3 'event:' scenarios/*.yaml`; the
# image is `COPY scenarios/ /scenarios/`). A pin or a directory with no row is
# MEASURED NOTHING (exit 2): moving the pin means reading the new scenarios and
# writing the row, never a quiet pass.
#
# NOT_WATCHED names a source a drill on this cluster deliberately does not watch,
# with the reason; it is printed on every run, never hidden.
#
# EXIT CODES: 0 every drill can start and sees what it waits for, 1 a drill
# cannot, 2 this measured nothing (no manifests, no mockryx CronJob, or a pin or
# directory with no row in EXPECT).
#
# DEPENDENCIES: bash, python3. Nothing else.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import os
import re
import sys

NAME = "drills-can-start"

# (mockryx tag, scenario directory) -> sources its expect.event blocks name.
EXPECT = {
    ("v0.5.0", "/scenarios"): {"tokenfuse", "wardryx", "verdryx", "heraldyx"},
    ("v0.5.0", "/scenarios/mcp"): set(),
}

# (tag, directory, source) -> why a drill here does not watch it.
NOT_WATCHED = {
    ("v0.5.0", "/scenarios", "heraldyx"): (
        "heraldyx writes alert_sent only to sent.ndjson on its own ReadWriteOnce volume "
        "(45-heraldyx.yaml), which the drills pod does not mount; on an install with "
        "heraldyx the step 'reaction-chain-reaches-heraldyx' reports a Finding "
        "(estate-gates GAPS G3.20)"
    ),
}

BUS_MOUNT = "/var/lib/stack/events"

manifests = sorted(glob.glob("manifests/*.yaml"))
if not manifests:
    print(f"{NAME}: measured NOTHING: no manifests/*.yaml")
    sys.exit(2)

bus_text = open("manifests/11-bus.yaml").read() if os.path.exists("manifests/11-bus.yaml") else ""
bus_streams = set(re.findall(r"^\s*([a-z0-9-]+\.ndjson):\d+", bus_text, re.M))
if not bus_streams:
    print(f"{NAME}: measured NOTHING: no stream table in manifests/11-bus.yaml")
    sys.exit(2)

problems = []
unmeasured = []
notes = []
seen = 0

for path in manifests:
    text = open(path).read()
    for doc in re.split(r"^---\s*$", text, flags=re.M):
        if not re.search(r"^kind:\s*CronJob\s*$", doc, re.M):
            continue
        m_img = re.search(r"^(\s*)image:\s*ghcr\.io/taipanbox/mockryx:(\S+?)(?:@\S+)?\s*$", doc, re.M)
        if not m_img:
            continue
        seen += 1
        name_m = re.search(r"^metadata:\s*\n\s+name:\s*(\S+)", doc, re.M)
        job = f"{path}: CronJob {name_m.group(1) if name_m else '?'}"
        tag = m_img.group(2)

        # The container block: from the image line to the pod's `volumes:`.
        start = m_img.start()
        end_m = re.search(r"^\s*volumes:\s*$", doc[start:], re.M)
        block = doc[start: start + end_m.start()] if end_m else doc[start:]
        # Only the mockryx container's own lines: stop at the next container.
        nxt = re.search(r"^\s*- name:\s*\S+\s*\n\s*image:", block[1:], re.M)
        if nxt:
            block = block[: nxt.start() + 1]

        args_m = re.search(r"^\s*args:\s*\[(.*)\]\s*$", block, re.M)
        if not args_m:
            problems.append(f"{job}: the mockryx container has no one-line `args: [...]` to read its scenario directory from")
            continue
        args = [a.strip().strip('"').strip("'") for a in args_m.group(1).split(",")]
        sdir = args[-1]

        key = (tag, sdir)
        if key not in EXPECT:
            unmeasured.append(f"{job}: mockryx {tag} on {sdir} has no row in EXPECT; read that tag's scenarios and write one")
            continue
        wants = EXPECT[key]

        watch_m = re.search(r"name:\s*MOCKRYX_WATCH_EVENTS\s*,\s*value:\s*\"([^\"]*)\"", block)
        watch = [p.strip() for p in watch_m.group(1).split(",") if p.strip()] if watch_m else []
        mounts = re.findall(r"mountPath:\s*([^\s,}]+)", block)

        if wants and not watch:
            problems.append(f"{job}: {sdir} in mockryx {tag} waits for events from {', '.join(sorted(wants))}, "
                            f"and MOCKRYX_WATCH_EVENTS is not set, so mockryx refuses to start (exit 2) on every run")
        for p in watch:
            if not p.startswith("/"):
                problems.append(f"{job}: watched path {p} is not absolute")
                continue
            if not any(p.startswith(m.rstrip("/") + "/") for m in mounts):
                problems.append(f"{job}: watched path {p} is not under any mount of the mockryx container "
                                f"({', '.join(mounts) or 'none'}), so it is never there and every step waiting on it is a false Finding")
            elif p.startswith(BUS_MOUNT + "/") and os.path.basename(p) not in bus_streams:
                problems.append(f"{job}: watched path {p} names no stream the bus owner makes (manifests/11-bus.yaml)")
        watched_files = {os.path.basename(p) for p in watch}
        for src in sorted(wants):
            why = NOT_WATCHED.get((tag, sdir, src))
            if why:
                notes.append(f"{job}: {src} not watched here: {why}")
                continue
            if f"{src}.ndjson" not in watched_files:
                problems.append(f"{job}: {sdir} in mockryx {tag} waits for {src} events and no watched path is {src}.ndjson")

        bl = re.search(r"^\s*backoffLimit:\s*(\d+)\s*$", doc, re.M)
        if not bl or bl.group(1) != "0":
            problems.append(f"{job}: backoffLimit is {bl.group(1) if bl else 'unset (6)'}, so a drill that finds a gap "
                            f"fires its hostile scenarios again; it must be 0")

for n in notes:
    print(f"{NAME}: note: {n}")

if seen == 0:
    print(f"{NAME}: measured NOTHING: no CronJob in manifests/ runs ghcr.io/taipanbox/mockryx")
    sys.exit(2)
if problems:
    for p in problems:
        print(f"{NAME}: {p}")
    for u in unmeasured:
        print(f"{NAME}: measured NOTHING about {u}")
    print(f"{NAME}: {len(problems)} problem(s) in {seen} drill CronJob(s)")
    sys.exit(1)
if unmeasured:
    for u in unmeasured:
        print(f"{NAME}: measured NOTHING about {u}")
    sys.exit(2)
print(f"{NAME}: OK, {seen} drill CronJob(s) can start, watch what they wait for, and run once")
PY
