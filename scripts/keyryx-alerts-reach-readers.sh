#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 75: the Keyryx witness's findings reach the console and
# heraldyx through the witness's own claim, the two readers see only the findings
# directory and only read only, and the witness never writes the bus it witnesses.
#
# WHY
#
# The witness exists to notice when a stream on the bus, or a sealed record, was
# rewritten after it was seen. A witness that could write the bus could add lines to
# the record it vouches for. So its findings are a file off the bus, keyryx.ndjson in
# alerts/ on its own ReadWriteOnce claim keyryx-witness-state, and the readers that
# turn a finding into a mail or an incident mount only alerts/ of that claim (subPath),
# read only, on the witness's node. No new volume is added. The same claim holds the
# witness's key under data/, so a reader that saw the whole claim, or mounted it
# writable, would see or change what the witness signs with: a read-only claim also
# keeps the kubelet from applying a reader's fsGroup to the witness's files.
#
# Keyryx is optional, so the readers' wiring is a strategic-merge patch under keyryx/,
# applied by lib/keyryx-install.sh after the apply, each with an unpatch, as the
# record-seal's is (invariant 70): the default manifests and a --without-keyryx
# install never mount the witness's claim.
#
# WHAT THIS CHECKS
#
#   1. no PersistentVolumeClaim named keyryx-alerts in any tracked YAML: the findings
#      need no claim of their own;
#   2. the witness names its findings file in KEYRYX_WITNESS_ALERTS, the file is called
#      keyryx.ndjson (the stem heraldyx reads as source keyryx), it is not under the bus
#      directory, it is under the witness's mount of keyryx-witness-state, in a
#      directory of its own that is not KEYRYX_WITNESS_DATA or under it; and the
#      witness mounts stack-events read only, on the volume (the claim's readOnly) and
#      on every mount of it, and no claim read-write but its own state;
#   3. each reader's patch (keyryx/console-findings-patch.yaml,
#      keyryx/heraldyx-findings-patch.yaml) mounts keyryx-witness-state with readOnly on
#      the claim and on the mount, through subPath equal to the findings directory; is
#      pod-affined, required, by hostname, to app: keyryx-witness; and names, in
#      GENARYX_EVENTS_EXTRA or HERALDYX_EVENTS, the findings file itself and no other
#      entry under that mount (leading slashes collapsed first);
#   4. the reading container runs in the bus group 10001 the file is created in, by
#      its own runAsGroup (or the pod's, when it sets none) or the pod's
#      supplementalGroups, read off the reader's default manifest;
#   5. each patch has its unpatch, which deletes the volume and the mount, sets
#      podAffinity to null, and puts the reader's setting back (heraldyx's
#      HERALDYX_EVENTS to the value its manifest declares, the console's
#      GENARYX_EVENTS_EXTRA deleted);
#   6. lib/keyryx-install.sh patches both readers in keyryx_install_settle and
#      unpatches both in keyryx_remove_settle, keyryx/down.sh unpatches both before it
#      deletes the witness, and each deploy script patches heraldyx after it applies it;
#   7. no file under manifests/ mounts keyryx-witness-state or names the findings
#      directory, and every other pod that mounts keyryx-witness-state does so read
#      only on the claim and on the mount.
#
# That the file and its directory are made before the witness starts, by its own uid,
# in group 10001, is invariant 59's gate (scripts/stream-files-are-precreated.sh).
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import os
import posixpath
import re
import subprocess
import sys

STATE = "keyryx-witness-state"
BUS = "/var/lib/stack/events"
NAME = "keyryx.ndjson"
# (patch, unpatch, base manifest, Deployment, container, setting)
READERS = [
    ("keyryx/console-findings-patch.yaml", "keyryx/console-findings-unpatch.yaml",
     "manifests/20-console.yaml", "genaryx-console", "console", "GENARYX_EVENTS_EXTRA"),
    ("keyryx/heraldyx-findings-patch.yaml", "keyryx/heraldyx-findings-unpatch.yaml",
     "manifests/45-heraldyx.yaml", "heraldyx", "heraldyx", "HERALDYX_EVENTS"),
]
WITNESS = ("keyryx/manifests/59-keyryx.yaml", "Deployment", "keyryx-witness")
DEPLOYS = ["deploy.sh", "cloud/gcp/deploy-gcp.sh", "cloud/aws/deploy-aws.sh"]


def nothing(msg):
    print(f"keyryx-alerts: {msg}, so this gate measured NOTHING")
    sys.exit(1)


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


def read(path):
    return live(open(path).read()) if os.path.exists(path) else None


def docs_of(path):
    t = read(path)
    return None if t is None else re.split(r"\n---\s*\n", t)


def find(path, kind, name):
    for d in docs_of(path) or []:
        if re.search(rf"^kind:\s*{kind}\s*$", d, re.M) and re.search(rf"^  name:\s*{re.escape(name)}\s*$", d, re.M):
            return d
    return None


def items(doc):
    """Every YAML list item, block or flow style, as (text, indent)."""
    ls = doc.split("\n")
    out = []
    for i, line in enumerate(ls):
        m = re.match(r"^(\s*)- (.*)$", line)
        if not m:
            continue
        ind = len(m.group(1))
        body = [line]
        for nxt in ls[i + 1:]:
            if not nxt.strip():
                continue
            if len(nxt) - len(nxt.lstrip(" ")) <= ind:
                break
            body.append(nxt)
        out.append(("\n".join(body), ind))
    return out


def field(text, key):
    """A key's value, quoted (commas allowed inside) or bare, in block or flow style."""
    m = re.search(rf"(?:^|[{{,\s]){key}:\s*\"([^\"\n]*)\"", text, re.M)
    if m:
        return m.group(1).strip()
    m = re.search(rf"(?:^|[{{,\s]){key}:\s*([^\",}}\n]+?)\s*(?:[,}}]|$)", text, re.M)
    return m.group(1).strip() if m else None


def first_name(text):
    m = re.match(r"^\s*- (?:\{\s*)?name:\s*\"?([A-Za-z0-9._-]+)", text)
    return m.group(1) if m else None


def volumes_for(doc, claim):
    """(volume name, claim readOnly) for each volume of doc whose claim is `claim`."""
    out = []
    for text, _ in items(doc):
        if "persistentVolumeClaim" not in text or "mountPath" in text:
            continue
        if field(text, "claimName") == claim:
            out.append((first_name(text), field(text, "readOnly") == "true"))
    return out


def mounts_of(doc, vname):
    """(mountPath, readOnly, subPath) for each mount of volume vname."""
    out = []
    for text, _ in items(doc):
        if "mountPath" in text and first_name(text) == vname and "persistentVolumeClaim" not in text:
            out.append((field(text, "mountPath"), field(text, "readOnly") == "true", field(text, "subPath")))
    return out


def env_value(doc, var):
    for text, _ in items(doc):
        if first_name(text) == var:
            v = field(text, "value")
            if v is not None:
                return v
    return None


def pod_security(doc):
    """The pod-level securityContext (six spaces in), flow or block style, as text."""
    ls = doc.split("\n")
    for i, line in enumerate(ls):
        if re.match(r"^      securityContext:", line):
            body = [line]
            for nxt in ls[i + 1:]:
                if nxt.strip() and len(nxt) - len(nxt.lstrip(" ")) <= 6:
                    break
                body.append(nxt)
            return "\n".join(body)
    return ""


def container(doc, cname):
    """The text of the container item named cname under `containers:` (not an init container)."""
    m = re.search(r"^      containers:\s*$", doc, re.M)
    if not m:
        return None
    for text, ind in items(doc[m.end():]):
        if ind == 8 and first_name(text) == cname:
            return text
    return None


def in_bus_group(doc, cname):
    c = container(doc, cname)
    if c is None:
        return False
    pod = pod_security(doc)
    group = field(c, "runAsGroup") or field(pod, "runAsGroup")
    supp = re.search(r"supplementalGroups:\s*\[([^\]]*)\]", pod)
    extra = {x.strip() for x in supp.group(1).split(",")} if supp else set()
    return group == "10001" or "10001" in extra


def norm(p):
    # normpath keeps a leading "//" (POSIX leaves it to the system), and the kernel
    # reads it as "/", so collapse every run of leading slashes first.
    return posixpath.normpath(re.sub(r"^/+", "/", p))


def under(p, base):
    base = base.rstrip("/")
    return p == base or p.startswith(base + "/")


def affined_to_witness(doc):
    m = re.search(r"podAffinity:\s*\n(.*?)(?=\n      [A-Za-z]|\Z)", doc, re.S)
    if not m:
        return False
    a = m.group(1)
    return ("requiredDuringSchedulingIgnoredDuringExecution" in a
            and re.search(r"app:\s*keyryx-witness\b", a) is not None
            and re.search(r"topologyKey:\s*kubernetes\.io/hostname\b", a) is not None)


bad = []
files = subprocess.run(["git", "ls-files", "*.yaml", "*.yml"], capture_output=True, text=True).stdout.split()
files = [f for f in files if not f.startswith(("evidence/", "docs/", "features/", ".github/"))]

# 1. no claim of their own
for f in files:
    for d in docs_of(f) or []:
        if re.search(r"^kind:\s*PersistentVolumeClaim\s*$", d, re.M) and re.search(r"^  name:\s*keyryx-alerts\s*$", d, re.M):
            bad.append(f"{f}: a PersistentVolumeClaim keyryx-alerts: the findings travel on the witness's own claim {STATE}, and no new volume is added")

# 2. the witness
wit = find(*WITNESS)
if wit is None:
    nothing("the keyryx-witness Deployment is absent")
alerts = env_value(wit, "KEYRYX_WITNESS_ALERTS") or ""
data = env_value(wit, "KEYRYX_WITNESS_DATA") or ""
if not alerts:
    bad.append("the witness names no KEYRYX_WITNESS_ALERTS, so keyryx writes its findings into the bus it reads")
if alerts and under(norm(alerts), BUS):
    bad.append(f"the witness writes its findings to {alerts}, on the bus it witnesses")
if alerts and posixpath.basename(alerts) != NAME:
    bad.append(f"the findings file is {posixpath.basename(alerts)}, not {NAME}: heraldyx reads source keyryx only from a file of that stem")
wmount = None
for vname, _ in volumes_for(wit, STATE):
    for mp, ro, _ in mounts_of(wit, vname):
        if alerts and under(norm(alerts), mp) and norm(alerts) != norm(mp):
            wmount = (mp, ro)
findings_dir = None
if wmount is None:
    bad.append(f"the witness's findings file {alerts or '(none)'} is not under its mount of {STATE}")
else:
    if wmount[1]:
        bad.append(f"the witness mounts {STATE} read only, so it cannot write its findings")
    findings_dir = posixpath.relpath(posixpath.dirname(norm(alerts)), norm(wmount[0]))
    if findings_dir in (".", ""):
        bad.append(f"the findings file sits at the root of {STATE}: a reader would have to mount the whole claim, key included")
        findings_dir = None
    elif data and (under(posixpath.dirname(norm(alerts)), norm(data)) or under(norm(data), posixpath.dirname(norm(alerts)))):
        bad.append(f"the findings directory {posixpath.dirname(alerts)} overlaps KEYRYX_WITNESS_DATA {data}: a reader of the findings would see the witness key")
        findings_dir = None
for text, _ in items(wit):
    if "persistentVolumeClaim" not in text:
        continue
    claim, vname = field(text, "claimName"), first_name(text)
    if claim == "stack-events" and field(text, "readOnly") != "true":
        bad.append(f"the witness's volume {vname} of stack-events is not readOnly on the claim, so a mount of it can write the bus")
    for mp, ro, _ in mounts_of(wit, vname):
        if claim == "stack-events" and not ro:
            bad.append("the witness mounts stack-events read-write: it writes the bus it witnesses")
        elif claim not in ("stack-events", STATE) and not ro:
            bad.append(f"the witness mounts {claim} read-write, beside its own state")

# 3., 4. and 5. the readers
there_of = {}
for patch, unpatch, base, dep, cname, var in READERS:
    p = find(patch, "Deployment", dep)
    if p is None:
        nothing(f"{patch}: no patch of the Deployment {dep}")
    vols = volumes_for(p, STATE)
    if not vols:
        bad.append(f"{patch}: {dep} does not mount {STATE}, so it does not read the witness's findings")
        continue
    there = None
    mps = []
    for vname, claim_ro in vols:
        if not claim_ro:
            bad.append(f"{patch}: {dep}'s volume {vname} of {STATE} is not readOnly on the claim: the mount could write the witness's state, and the kubelet would apply {dep}'s fsGroup to it")
        ms = mounts_of(p, vname)
        if not ms:
            bad.append(f"{patch}: {dep} declares the volume {vname} and mounts it nowhere")
        for mp, ro, sub in ms:
            mps.append(norm(mp))
            if not ro:
                bad.append(f"{patch}: {dep} mounts {STATE} read-write at {mp}: only the witness writes its findings, readers read only")
            if findings_dir is not None and (sub or "").strip("/") != findings_dir:
                bad.append(f"{patch}: {dep} mounts {STATE} at {mp} with subPath {sub or '(none)'}, not {findings_dir}: it would see more of the witness's state than its findings")
            there = posixpath.join(norm(mp), NAME)
    there_of[dep] = there
    entries = [e.strip() for e in (env_value(p, var) or "").split(",") if e.strip()]
    if there is None or there not in entries:
        bad.append(f"{dep} does not read the witness's findings: {var} names {', '.join(entries) or 'nothing'}, not {there}")
    for e in entries:
        if e != there and any(under(norm(e), mp) for mp in mps):
            bad.append(f"{dep}: {var} names {e} under the findings mount, beside the file: a reader takes only {there} from that claim")
    if not affined_to_witness(p):
        bad.append(f"{patch}: {dep} is not pod-affined (required, by hostname) to app: keyryx-witness, and {STATE} is ReadWriteOnce")
    bd = find(base, "Deployment", dep)
    if bd is None:
        nothing(f"{base}: the Deployment {dep} is absent")
    if not in_bus_group(bd, cname):
        bad.append(f"{dep}'s container {cname} is not in the bus group 10001, which the findings file is created in")
    u = find(unpatch, "Deployment", dep)
    if u is None:
        bad.append(f"{unpatch}: no unpatch of {dep}, so --without-keyryx would leave it mounting the witness's claim")
        continue
    for vname, _ in vols:
        for text, _ in items(u):
            pass
        if not re.search(rf"- name:\s*{re.escape(vname)}\s*\n\s*\$patch:\s*delete", u) or len(re.findall(rf"- name:\s*{re.escape(vname)}\s*\n\s*\$patch:\s*delete", u)) < 2:
            bad.append(f"{unpatch}: does not delete both the volume and the mount {vname}")
    if not re.search(r"podAffinity:\s*null", u):
        bad.append(f"{unpatch}: does not set podAffinity to null, so {dep} stays bound to the witness's node")
    base_value = env_value(bd, var)
    if base_value is None:
        if not re.search(rf"- name:\s*{var}\s*\n\s*\$patch:\s*delete", u):
            bad.append(f"{unpatch}: does not delete {var}, which {base} does not declare")
    elif env_value(u, var) != base_value:
        bad.append(f"{unpatch}: puts {var} back to {env_value(u, var)!r}, not {base_value!r} as {base} declares")

# 6. who applies them
lib = read("lib/keyryx-install.sh")
if lib is None:
    nothing("lib/keyryx-install.sh is absent")


def body(text, fn):
    m = re.search(rf"^{fn}\(\) \{{\n(.*?)^\}}", text, re.S | re.M)
    return m.group(1) if m else ""


ins, rem = body(lib, "keyryx_install_settle"), body(lib, "keyryx_remove_settle")
for patch, unpatch, _, dep, _, _ in READERS:
    if not re.search(rf"keyryx_patch_reader\s+{re.escape(dep)}\s+{re.escape(posixpath.basename(patch))}", ins):
        bad.append(f"lib/keyryx-install.sh: keyryx_install_settle does not patch {dep} with {posixpath.basename(patch)}")
    if not re.search(rf"keyryx_unpatch_reader\s+{re.escape(dep)}\s+{re.escape(posixpath.basename(unpatch))}", rem):
        bad.append(f"lib/keyryx-install.sh: keyryx_remove_settle does not unpatch {dep} with {posixpath.basename(unpatch)}")
    down = read("keyryx/down.sh") or ""
    if not re.search(rf"unpatch_reader\s+{re.escape(dep)}\s+{re.escape(posixpath.basename(unpatch))}", down):
        bad.append(f"keyryx/down.sh does not unpatch {dep} before it deletes the witness it is affined to")
for f in DEPLOYS:
    t = read(f)
    if t is None:
        nothing(f"{f} is absent")
    m = re.search(r"apply -f /root/stack-k8s/manifests/45-heraldyx\.yaml(.*)", t, re.S)
    if not m or not re.search(r"keyryx_patch_reader\s+heraldyx\s+heraldyx-findings-patch\.yaml", m.group(1)):
        bad.append(f"{f}: heraldyx is applied and its findings patch is not applied after it, so a fresh apply leaves it reading the bus alone")

# 7. the default manifests, and every other mount of the witness's claim
for f in files:
    if not f.startswith("manifests/"):
        continue
    t = read(f) or ""
    if re.search(rf"claimName:\s*{STATE}(?![\w.-])", t):
        bad.append(f"{f} mounts {STATE}: the default manifests stay what an install without Keyryx applies")
for f in files:
    if not f.startswith("keyryx/") or f in (WITNESS[0],) or any(f == r[0] for r in READERS):
        continue
    for d in docs_of(f) or []:
        for vname, claim_ro in volumes_for(d, STATE):
            if not claim_ro:
                bad.append(f"{f}: a volume {vname} of {STATE} not readOnly on the claim")
            for mp, ro, _ in mounts_of(d, vname):
                if not ro:
                    bad.append(f"{f}: {STATE} mounted read-write at {mp}: only the witness writes its state")

if bad:
    for b in bad:
        print("FAIL keyryx-alerts: " + b)
    sys.exit(1)
print(f"OK: the witness writes {alerts} on its own claim {STATE}; the console and heraldyx mount only")
print(f"    {findings_dir}/ of it, read only, beside the witness, through patches with unpatches, and read the file itself")
PY
