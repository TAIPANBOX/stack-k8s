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
# A reaction that is not on the bus is watched where it is written, and only by
# a drill that can reach it: heraldyx journals alert_sent in sent.ndjson on its
# own ReadWriteOnce claim (45-heraldyx.yaml). A drill that waits for heraldyx
# must watch that file, mount that claim read only (on the volume and on the
# mount), be placed on heraldyx's node by a required podAffinity, carry an
# activeDeadlineSeconds so a drill with no heraldyx to sit beside does not stay
# Pending, and live in heraldyx's own manifest, so it exists exactly where
# heraldyx does (estate-gates GAPS G3.20).
# It must also be in heraldyx's group (the journal is 0640), mount the claim
# whole rather than by subPath, and a drill in heraldyx's manifest must wait
# for heraldyx; with heraldyx's manifest present, some drill must.
#
# Every drill is suspended: it spends real budget, and the heraldyx drill
# mails the operator. A drill whose scenarios send to the gateway carries the
# pod labels drills-egress-gateway and gateway-ingress-drills select on
# (30-network-policy.yaml), or every request is dropped.
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
# volumeMounts, the pod's volumes and affinity, and the job's backoffLimit and
# activeDeadlineSeconds.
#
# The scenarios that directory holds AS THE POD SEES IT:
#   - a directory of the image: IMAGE below, the files of that tag's directory
#     and the sources their expect.event blocks name, read from mockryx's own
#     tree at that tag (`ls scenarios`, `grep -A3 'event:' scenarios/*.yaml`;
#     the image is `COPY scenarios/ /scenarios/`). A file mounted over one of
#     them by subPath is read from its ConfigMap instead; a mounted file the
#     image has no file of that name for ADDS a scenario and replaces none, and
#     is a problem.
#   - a ConfigMap mounted as the directory: every key of it, read as a scenario.
# Anything else is MEASURED NOTHING (exit 2): moving the pin means reading the
# new scenarios and writing the row, never a quiet pass.
#
# EXIT CODES: 0 every drill can start and sees what it waits for, 1 a drill
# cannot, 2 this measured nothing (no manifests, no stream table, no mockryx
# CronJob, or a drill whose scenario directory it cannot account for).
#
# DEPENDENCIES: bash, python3, scripts/lib/miniyaml.py. Nothing else.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import os
import re
import sys

sys.path.insert(0, "scripts/lib")
import miniyaml

NAME = "drills-can-start"

# (mockryx tag, directory in the image) -> {file: sources its expect.event blocks name}.
IMAGE = {
    ("v0.5.1", "/scenarios"): {
        "allow-list-renamed-tool.yaml": set(),
        "approval-required.yaml": set(),
        "declared-tool-poisoning.yaml": set(),
        "dlp-secret-leak.yaml": set(),
        "egress-after-untrusted-read.yaml": set(),
        "injected-page.yaml": {"tokenfuse"},
        "on-behalf-of-forged-chain.yaml": set(),
        "pii-in-prompt.yaml": set(),
        "reaction-chain-reaches-heraldyx.yaml": {"heraldyx"},
        "reaction-chain-reaches-wardryx.yaml": {"wardryx"},
        "runaway-budget.yaml": set(),
        "token-flood.yaml": set(),
        "verdryx-quality-drift.yaml": {"verdryx"},
        "wardryx-denied-tool.yaml": set(),
    },
    ("v0.5.1", "/scenarios/mcp"): {
        "mcp-pii-in-arguments.yaml": set(),
        "mcp-secret-in-arguments.yaml": set(),
        "mcp-ungranted-tool-held.yaml": set(),
    },
}

# Whether the scenarios of an image directory send requests to the gateway (`request:` steps) rather than
# to the MCP broker (`mcp:` steps). A drill that does must carry the pod labels the two gateway drill
# NetworkPolicies select on, or every request is dropped and every step is a false Finding.
IMAGE_GATEWAY = {("v0.5.1", "/scenarios"): True, ("v0.5.1", "/scenarios/mcp"): False}
NETPOL_FILE = "manifests/30-network-policy.yaml"
NETPOL_EGRESS = "drills-egress-gateway"
NETPOL_INGRESS = "gateway-ingress-drills"

# A source whose reaction is NOT on the bus -> (the file it is journalled in as a drill's pod sees it, the
# claim that file is on, the app label of the workload that owns the claim, the manifest both live in, the
# group that may read the file: heraldyx makes its journal 0640 under its own gid).
OFF_BUS = {
    "heraldyx": ("/var/lib/stack/heraldyx/sent.ndjson", "heraldyx-state", "heraldyx", "manifests/45-heraldyx.yaml", 65532),
}

BUS_MOUNT = "/var/lib/stack/events"
SCENARIO_EXT = (".yaml", ".yml", ".json")

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
summary = []
seen = 0

parts = []
for path in manifests:
    for part in re.split(r"(?m)^---[ \t]*$", open(path).read()):
        parts.append((path, part))


def configmap(name):
    """The data of the ConfigMap `name` in manifests/, or None."""
    for path, part in parts:
        if not re.search(r"(?m)^kind:\s*ConfigMap\s*$", part):
            continue
        if not re.search(r"(?m)^\s+name:\s*" + re.escape(name) + r"\s*$", part):
            continue
        try:
            for d in miniyaml.load_all(part):
                if isinstance(d, dict) and d.get("kind") == "ConfigMap" and (d.get("metadata") or {}).get("name") == name:
                    return d.get("data") or {}
        except ValueError as e:
            problems.append(f"{path}: the ConfigMap {name} cannot be read ({e})")
            return None
    return None


def sources_of(text, where):
    """The sources the expect.event blocks of one scenario document name, or None when it cannot be read.
    A step that sends a request to the gateway is counted in gateway_steps."""
    global gateway_steps
    try:
        docs = [d for d in miniyaml.load_all(text) if isinstance(d, dict)]
    except ValueError as e:
        problems.append(f"{where}: the scenario cannot be read ({e})")
        return None
    if not docs or not docs[0].get("steps"):
        problems.append(f"{where}: is not a scenario with steps")
        return None
    out = set()
    for d in docs:
        for st in d.get("steps") or []:
            if isinstance(st, dict) and st.get("request"):
                gateway_steps += 1
            ev = ((st or {}).get("expect") or {}).get("event")
            if isinstance(ev, dict) and ev.get("source"):
                out.add(str(ev["source"]))
    return out


def netpol(name):
    """The NetworkPolicy `name` in NETPOL_FILE, or None."""
    if not os.path.exists(NETPOL_FILE):
        return None
    for part in re.split(r"(?m)^---[ \t]*$", open(NETPOL_FILE).read()):
        if not re.search(r"(?m)^kind:\s*NetworkPolicy\s*$", part):
            continue
        if not re.search(r"(?m)^\s+name:\s*" + re.escape(name) + r"\s*$", part):
            continue
        for d in miniyaml.load_all(part):
            if isinstance(d, dict) and (d.get("metadata") or {}).get("name") == name:
                return d
    return None


def selects(sel, labels):
    return bool(sel) and all(labels.get(k) == v for k, v in sel.items())


gateway_steps = 0
waited_for = set()


def check(path, cron, jspec, pod, c, tag):
    global gateway_steps
    gateway_steps = 0
    job = f"{path}: CronJob {(cron.get('metadata') or {}).get('name', '?')}"
    if (cron.get("spec") or {}).get("suspend") is not True:
        problems.append(f"{job}: is not suspended; a drill fires hostile requests and spends real budget every time "
                        f"it runs (the heraldyx drill also mails the operator), so it runs when a person means it")
    args = c.get("args") or []
    if not args:
        problems.append(f"{job}: the mockryx container has no `args` to read its scenario directory from")
        return
    sdir = str(args[-1]).rstrip("/")
    mounts = [m for m in c.get("volumeMounts") or [] if isinstance(m, dict)]
    volumes = {v.get("name"): v for v in pod.get("volumes") or [] if isinstance(v, dict)}
    env = {e.get("name"): e.get("value") for e in c.get("env") or [] if isinstance(e, dict)}

    # The scenarios the directory holds as this pod sees it.
    files = None
    if (tag, sdir) in IMAGE:
        files = {f: set(s) for f, s in IMAGE[(tag, sdir)].items()}
        for m in mounts:
            mp = str(m.get("mountPath", "")).rstrip("/")
            if os.path.dirname(mp) != sdir or not mp.endswith(SCENARIO_EXT):
                continue
            fname = os.path.basename(mp)
            where = f"{job}: {mp}"
            if fname not in files:
                problems.append(f"{where} is mounted into {sdir}, and mockryx {tag} has no file of that name there, "
                                f"so it adds a scenario and replaces none")
            vol = volumes.get(m.get("name")) or {}
            cm = (vol.get("configMap") or {}).get("name")
            data = configmap(cm) if cm else None
            if data is None or m.get("subPath") not in data:
                problems.append(f"{where} is mounted from no ConfigMap key in manifests/ that this gate can read")
                files[fname] = set()
                continue
            src = sources_of(data[m.get("subPath")], f"{where} (ConfigMap {cm}, key {m.get('subPath')})")
            files[fname] = src if src is not None else set()
    else:
        for m in mounts:
            if str(m.get("mountPath", "")).rstrip("/") != sdir or m.get("subPath"):
                continue
            cm = ((volumes.get(m.get("name")) or {}).get("configMap") or {}).get("name")
            data = configmap(cm) if cm else None
            if data is None:
                continue
            files = {}
            for key in sorted(data):
                if key.endswith(SCENARIO_EXT):
                    src = sources_of(data[key], f"{job}: {sdir}/{key} (ConfigMap {cm})")
                    files[key] = src if src is not None else set()
            if not files:
                problems.append(f"{job}: the ConfigMap {cm} mounted at {sdir} holds no scenario, and mockryx refuses an empty directory")
    if files is None:
        unmeasured.append(f"{job}: mockryx {tag} on {sdir} is neither a directory in IMAGE nor a ConfigMap mounted there; "
                          f"read what that directory holds and write a row")
        return
    wants = set().union(*files.values()) if files else set()
    waited_for.update(wants)

    # The gateway's door: the pod must carry what both gateway drill NetworkPolicies select on.
    if IMAGE_GATEWAY.get((tag, sdir), False) or gateway_steps:
        labels = ((jspec.get("template") or {}).get("metadata") or {}).get("labels") or {}
        eg, ing = netpol(NETPOL_EGRESS), netpol(NETPOL_INGRESS)
        if eg is None or ing is None:
            unmeasured.append(f"{job}: {NETPOL_FILE} has no NetworkPolicy {NETPOL_EGRESS} or {NETPOL_INGRESS} to read the drills' label from")
        else:
            eg_sel = ((eg.get("spec") or {}).get("podSelector") or {}).get("matchLabels") or {}
            ing_sels = [((peer or {}).get("podSelector") or {}).get("matchLabels") or {}
                        for rule in (ing.get("spec") or {}).get("ingress") or []
                        for peer in (rule or {}).get("from") or []]
            if not (selects(eg_sel, labels) and any(selects(s, labels) for s in ing_sels)):
                problems.append(f"{job}: its pod labels ({labels or 'none'}) are not what {NETPOL_EGRESS} and {NETPOL_INGRESS} "
                                f"select, so every request to the gateway is dropped and every step is a false Finding")

    watch =[p.strip() for p in str(env.get("MOCKRYX_WATCH_EVENTS") or "").split(",") if p.strip()]
    mount_paths = [str(m.get("mountPath", "")) for m in mounts]

    if wants and not watch:
        problems.append(f"{job}: {sdir} in mockryx {tag} waits for events from {', '.join(sorted(wants))}, "
                        f"and MOCKRYX_WATCH_EVENTS is not set, so mockryx refuses to start (exit 2) on every run")
    for p in watch:
        if not p.startswith("/"):
            problems.append(f"{job}: watched path {p} is not absolute")
            continue
        if not any(p.startswith(m.rstrip("/") + "/") for m in mount_paths):
            problems.append(f"{job}: watched path {p} is not under any mount of the mockryx container "
                            f"({', '.join(mount_paths) or 'none'}), so it is never there and every step waiting on it is a false Finding")
        elif p.startswith(BUS_MOUNT + "/") and os.path.basename(p) not in bus_streams:
            problems.append(f"{job}: watched path {p} names no stream the bus owner makes (manifests/11-bus.yaml)")
    watched_files = {os.path.basename(p) for p in watch}

    for src in sorted(wants):
        if src not in OFF_BUS:
            if f"{src}.ndjson" not in watched_files:
                problems.append(f"{job}: {sdir} in mockryx {tag} waits for {src} events and no watched path is {src}.ndjson")
            continue
        fpath, claim, owner, home, gid = OFF_BUS[src]
        psc = pod.get("securityContext") or {}
        groups = {psc.get("runAsGroup"), psc.get("fsGroup"), (c.get("securityContext") or {}).get("runAsGroup")}
        groups.update(psc.get("supplementalGroups") or [])
        if gid not in groups:
            problems.append(f"{job}: the pod is not in group {gid}, so {fpath} ({owner}'s own file, 0640) cannot be read "
                            f"and the step waiting on it is a false Finding")
        if fpath not in watch:
            problems.append(f"{job}: {sdir} in mockryx {tag} waits for {src} events, which are only in {fpath} on the "
                            f"claim {claim}, and no watched path is {fpath}")
        if path != home:
            problems.append(f"{job}: waits for {src} events and is not in {home}, so it exists on a cluster where "
                            f"{owner} does not and cannot reach {owner}'s claim where it does")
        carrier = None
        for m in mounts:
            mp = str(m.get("mountPath", "")).rstrip("/")
            if fpath.startswith(mp + "/") and (carrier is None or len(mp) > len(str(carrier.get("mountPath", "")))):
                carrier = m
        pvc = ((volumes.get(carrier.get("name")) or {}).get("persistentVolumeClaim") or {}) if carrier else {}
        if pvc.get("claimName") != claim:
            problems.append(f"{job}: {fpath} is on no mount of the claim {claim}")
            continue
        if carrier.get("subPath"):
            problems.append(f"{job}: the claim {claim} is mounted by subPath {carrier.get('subPath')}, so {fpath} is not "
                            f"the file {owner} writes and the step waiting on it is a false Finding")
        if pvc.get("readOnly") is not True or carrier.get("readOnly") is not True:
            problems.append(f"{job}: the claim {claim} is not read only on both the volume and the mount; this drill reads "
                            f"{owner}'s journal and has no business writing anything of {owner}'s")
        terms = ((pod.get("affinity") or {}).get("podAffinity") or {}).get("requiredDuringSchedulingIgnoredDuringExecution") or []
        if not any(((t.get("labelSelector") or {}).get("matchLabels") or {}).get("app") == owner
                   and t.get("topologyKey") == "kubernetes.io/hostname" for t in terms if isinstance(t, dict)):
            problems.append(f"{job}: {claim} is ReadWriteOnce and the pod has no required podAffinity to app: {owner} on "
                            f"kubernetes.io/hostname, so it can be placed where the volume cannot attach")
        if not jspec.get("activeDeadlineSeconds"):
            problems.append(f"{job}: no activeDeadlineSeconds, so with no {owner} pod to sit beside the drill stays Pending for good")

    for src, (fpath, claim, owner, home, gid) in OFF_BUS.items():
        if path == home and src not in wants:
            problems.append(f"{job}: lives in {home} and waits for no {src} event, so it proves nothing about {owner}")

    bl = jspec.get("backoffLimit")
    if bl != 0:
        problems.append(f"{job}: backoffLimit is {bl if bl is not None else 'unset (6)'}, so a drill that finds a gap "
                        f"fires its hostile scenarios again; it must be 0")
    summary.append(f"{job}: {sdir}, {len(files)} scenario(s), waits for {', '.join(sorted(wants)) or 'nothing off the request path'}")


for path, part in parts:
    if not re.search(r"(?m)^kind:\s*CronJob\s*$", part):
        continue
    if not re.search(r"(?m)^\s*image:\s*ghcr\.io/taipanbox/mockryx:", part):
        continue
    try:
        docs = [d for d in miniyaml.load_all(part) if isinstance(d, dict)]
    except ValueError as e:
        seen += 1
        unmeasured.append(f"{path}: a mockryx CronJob cannot be read ({e})")
        continue
    for cron in docs:
        if cron.get("kind") != "CronJob":
            continue
        jspec = ((cron.get("spec") or {}).get("jobTemplate") or {}).get("spec") or {}
        pod = (jspec.get("template") or {}).get("spec") or {}
        for c in pod.get("containers") or []:
            m = re.match(r"ghcr\.io/taipanbox/mockryx:([^@\s]+)", str((c or {}).get("image", "")))
            if m:
                seen += 1
                check(path, cron, jspec, pod, c, m.group(1))

if seen == 0:
    print(f"{NAME}: measured NOTHING: no CronJob in manifests/ runs ghcr.io/taipanbox/mockryx")
    sys.exit(2)
for src, (fpath, claim, owner, home, gid) in OFF_BUS.items():
    if os.path.exists(home) and src not in waited_for:
        problems.append(f"{home}: no drill waits for a {src} event, so nothing proves that {owner} tells anyone "
                        f"(estate-gates GAPS G3.20)")
for s in summary:
    print(f"{NAME}: {s}")
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
