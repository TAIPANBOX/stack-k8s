#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 31: the on-box chain verifier is in the default
# install, runs on a schedule, reads the bus it is meant to read, and keeps what
# it remembers on a claim that already exists.
#
# WHY
#
# Every stream on the shared bus is a hash chain, and until agent-stack-go v1.1.0
# nothing on a box checked one: on the 2026-09-17 appliance run a byte flipped on
# a sealed line of the bus was seen by nothing. `agent-conform watch-dir` is the
# same verification as a scheduled mode that alerts, and the failures worth
# guarding are the quiet ones: a verifier that exists in a manifest and watches
# the wrong directory, runs from an emptyDir that forgets what it announced, is
# suspended, or fails once and is retried into silence, all look like a verifier.
#
# WHAT THIS CHECKS. The subject is FOUND by what makes it one, a CronJob whose
# container runs `ghcr.io/taipanbox/agent-conform:<tag>`, never by name.
#
#   1. one exists, in a manifest kustomization.yaml includes (the default apply
#      set: a verifier somebody has to ask for is a verifier most boxes lack);
#   2. it is scheduled at least every 15 minutes, and is not suspended;
#   3. it runs `watch-dir`, its LAST argument is the bus directory (the one
#      EVENTS_DIR names in stack-wiring), and its `-out` is a file named
#      agent-conform.ndjson inside it: the stream has to be on the bus for the
#      notifier and the console to see it;
#   4. what it remembers (`-state`, when given) is inside that same directory,
#      on the claim `stack-events`, and the pod mounts no emptyDir: a CronJob is a
#      new pod per run, so an emptyDir forgets between runs and a persistent break
#      is announced again every run. It mounts exactly one claim and it is the one
#      that exists: a second claim is a billed disk, the operator's decision;
#   5. a new break must stay visible: restartPolicy Never and backoffLimit 0, so a
#      retry cannot exit 0 over the failure (the finding is remembered by then);
#   6. it can create its file on the bus (fsGroup 10001, as the other bus writers),
#      under its own uid and not the money plane's (10002, not 10001), and it is
#      hardened like everything else here (non-root, read-only root, no
#      capabilities, no service account token);
#   7. the image tag is v1.1.0 or later: `watch-dir` does not exist before it.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no such CronJob is a failure that says it
# measured nothing, not an agreement that a box needs none.
#
# WHAT IT DOES NOT DO. It runs no cluster. That the verifier can read every
# writer's file on a live RWX volume (the writers create 0644 files, read from
# their source, not from a run) and create its own, needs a cluster.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import pathlib
import re
import sys

kust = pathlib.Path("manifests/kustomization.yaml")
if not kust.exists():
    print("FAIL: manifests/kustomization.yaml does not exist, so this measured nothing about the default apply set.")
    sys.exit(1)
ktext = kust.read_text()
m = re.search(r"^resources:\s*$", ktext, re.M)
default_files = []
if m:
    for line in ktext[m.end():].splitlines():
        if not line.strip():
            continue
        it = re.match(r"^\s*-\s+(\S+)\s*$", line)
        if not it:
            break
        default_files.append(it.group(1))
if not default_files:
    print("FAIL: no resources: block in manifests/kustomization.yaml, so this measured nothing.")
    sys.exit(1)


def code_of(text):
    return re.sub(r"(?m)^\s*#.*$", "", text)


EVENTS_DIR = None
base = pathlib.Path("manifests/00-base.yaml")
if base.exists():
    mm = re.search(r'(?m)^\s*EVENTS_DIR:\s*"([^"]+)"', code_of(base.read_text()))
    EVENTS_DIR = mm.group(1) if mm else None

subjects = []   # (file, doc)
for path in sorted(pathlib.Path("manifests").glob("*.yaml")):
    for doc in re.split(r"(?m)^---\s*$", path.read_text()):
        if re.search(r"(?m)^kind:\s*CronJob\s*$", doc) and re.search(
                r"image:\s*ghcr\.io/taipanbox/agent-conform:\S+", code_of(doc)):
            subjects.append((path, doc))

if not subjects:
    print("FAIL: no CronJob running ghcr.io/taipanbox/agent-conform was found under manifests/.")
    print("      That is not agreement that a box needs no verifier: the chain verifier moved, was renamed, or")
    print("      this check no longer knows how to find it. It measured nothing about the verifier.")
    sys.exit(1)

problems = []
for path, doc in subjects:
    c = code_of(doc)
    name = (re.search(r"(?m)^  name:\s*(\S+)", c) or [None, "?"])[1]
    where = f"{path} CronJob {name}"
    if path.name not in default_files:
        problems.append(f"{where}: {path.name} is not in manifests/kustomization.yaml's resources:, so a default install "
                        "does not run the verifier")
    sched = re.search(r'(?m)^\s*schedule:\s*"([^"]+)"', c)
    if not sched:
        problems.append(f"{where}: no schedule")
    else:
        step = re.fullmatch(r"\*/(\d+) \* \* \* \*", sched.group(1))
        if not step or not (1 <= int(step.group(1)) <= 15):
            problems.append(f"{where}: schedule {sched.group(1)!r} is not at least every 15 minutes (*/N * * * *, N up to 15)")
    if re.search(r"(?m)^\s*suspend:\s*true\s*$", c):
        problems.append(f"{where}: suspended, so it verifies nothing until a person runs it")

    args = []
    am = re.search(r"(?m)^\s*args:\s*\n((?:\s*-\s*\"[^\"]*\"\s*\n)+)", c)
    if am:
        args = re.findall(r'"([^"]*)"', am.group(1))
    if not args or args[0] != "watch-dir":
        problems.append(f"{where}: does not run `watch-dir` (args are {args[:3]})")
    else:
        bus = args[-1]
        if EVENTS_DIR is None:
            problems.append(f"{where}: stack-wiring names no EVENTS_DIR, so there is no bus directory to compare with")
        elif bus != EVENTS_DIR:
            problems.append(f"{where}: watches {bus!r}, not the bus {EVENTS_DIR!r} that stack-wiring names")
        if "-out" not in args or args.index("-out") + 1 >= len(args):
            problems.append(f"{where}: no -out, so its findings are not appended to a stream the notifier reads")
        else:
            out = args[args.index("-out") + 1]
            if out != f"{bus}/agent-conform.ndjson":
                problems.append(f"{where}: -out is {out!r}; it must be {bus}/agent-conform.ndjson, a file of that name "
                                "inside the bus (its name is the source its events claim)")
        if "-state" in args and args.index("-state") + 1 < len(args):
            state = args[args.index("-state") + 1]
            if not state.startswith(bus + "/"):
                problems.append(f"{where}: -state is {state!r}, outside the bus directory, so it is on a volume this "
                                "check cannot show persists")

    if "emptyDir" in c:
        problems.append(f"{where}: mounts an emptyDir: a CronJob is a new pod per run, so what it remembers is gone "
                        "before the next one and a persistent break is announced again every run")
    claims = re.findall(r"claimName:\s*([\w.-]+)", c)
    if claims != ["stack-events"]:
        problems.append(f"{where}: claims are {claims}; it must mount exactly stack-events, the one that exists. A second "
                        "claim is a billed disk, and that is the operator's decision")
    if not re.search(r"\{\s*name:\s*events\s*,\s*mountPath:\s*" + re.escape(EVENTS_DIR or "/var/lib/stack/events") + r"\s*\}", c):
        problems.append(f"{where}: the bus is not mounted read-write at {EVENTS_DIR}, so it cannot create its stream there")

    if not (re.search(r"restartPolicy:\s*Never", c) and re.search(r"backoffLimit:\s*0\b", c)):
        problems.append(f"{where}: needs restartPolicy: Never and backoffLimit: 0; a retry exits 0 (the finding is "
                        "remembered by then) and hides the failure a new break is meant to cause")
    sc = re.search(r"securityContext:\s*\{([^}]*)\}", c)
    scs = sc.group(1) if sc else ""
    if "fsGroup: 10001" not in scs:
        problems.append(f"{where}: no fsGroup 10001, so it cannot create its file on the bus the other writers share")
    if "runAsUser: 10002" not in scs or "runAsNonRoot: true" not in scs:
        problems.append(f"{where}: must run non-root as uid 10002, its own and not the money plane's 10001")
    for need in ("automountServiceAccountToken: false", "readOnlyRootFilesystem: true", 'drop: ["ALL"]',
                 "allowPrivilegeEscalation: false"):
        if need not in c:
            problems.append(f"{where}: lost {need}")
    tag = re.search(r"agent-conform:(v(\d+)\.(\d+)\.(\d+))\b", c)
    if not tag or tuple(int(x) for x in tag.groups()[1:]) < (1, 1, 0):
        problems.append(f"{where}: image tag {tag.group(1) if tag else None} is older than v1.1.0, which is where "
                        "`watch-dir` starts to exist")

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print()
    print(f"{len(problems)} problem(s) with the chain verifier. See CLAUDE.md invariant 31.")
    sys.exit(1)

print(f"OK: {len(subjects)} chain verifier CronJob(s) in the default install, every 15 minutes or sooner, watching "
      f"{EVENTS_DIR} and writing agent-conform.ndjson there, its state on stack-events (no emptyDir, no new claim), "
      "a failed pass kept visible.")
PY
