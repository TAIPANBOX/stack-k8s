#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 53: the provider key is held by the gateway, from a
# file it mounts, and no other container in the cluster holds it.
#
# WHY
#
# An agent-facing pod that holds a provider key can call the provider directly, and
# then the gateway meters nothing it does. Before this invariant the console read the
# Anthropic key from the stack-copilot Secret into its environment, and costcrew read
# its engine keys from costcrew-engine into its environment. Both are the trap this
# gate exists for: a key in an environment is visible to anything that can read the
# process, and a manifest that adds one more container with the same Secret reference
# ships the bypass without anybody seeing it.
#
# WHAT THIS CHECKS
#
# A gateway start is a container that runs the published tokenfuse image with the
# tokenfuse binary and no subcommand, the same definition invariant 20 uses. Subjects
# are found in manifests/*.yaml, not listed, so a new manifest is covered the day it
# lands.
#
#   1. Only a gateway start may read the provider Secrets (gateway-upstream-key,
#      stack-copilot, costcrew-engine), by secretKeyRef, envFrom or a volume.
#   2. No container other than a gateway start takes an environment variable whose
#      name is provider-shaped (ANTHROPIC, OPENAI, OPENROUTER, COPILOT_KEY, JEV_KEY)
#      from a Secret that is not a client-key Secret (a name ending in -client-key or
#      -client-keys). A client key is the agent's own credential, which is allowed.
#   3. Every gateway start takes its provider key as a file: TOKENFUSE_UPSTREAM_KEY_FILE
#      is a literal path, a volume of Secret gateway-upstream-key, not optional, is
#      mounted read only at that path's directory, and the gateway takes no
#      provider-shaped variable from a Secret.
#
# NAMED EXCEPTIONS
#
# None. costcrew-crew read its engine keys from costcrew-engine until v0.8.0 of CostCrew,
# whose analysts are agent://<domain>/costcrew/<name>: the identity map binds that pattern
# to the crew's own client key (costcrew-client-key, unit costcrew), so the crew now presents
# that key to the gateway and holds no provider key. costcrew-engine stays in the provider
# set below, so a container that reads it goes red.
#
# HOW, WITHOUT A YAML LIBRARY
#
# Parsed by indentation and known key names, the way gateway-cache-is-off.sh does it.
# Nothing here is a substitute for a live cluster: that the pod reads its file, and that
# the gateway uses it, is measured by the evidence named in CLAUDE.md, not by this gate.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import re
import sys

PROVIDER_SECRETS = {"gateway-upstream-key", "stack-copilot", "costcrew-engine"}
UPSTREAM_SECRET = "gateway-upstream-key"
PROVIDER_ENV_RE = re.compile(r"(ANTHROPIC|OPENAI|OPENROUTER|COPILOT_KEY|JEV_KEY)")
CLIENT_KEY_RE = re.compile(r"-client-keys?$")

# (kind, object name, container name, Secret) -> the reason it is allowed for now.
EXCEPTIONS = {}

POD_PATHS = {
    "Deployment": ["spec", "template", "spec"],
    "StatefulSet": ["spec", "template", "spec"],
    "Job": ["spec", "template", "spec"],
    "CronJob": ["spec", "jobTemplate", "spec", "template", "spec"],
}

KEYFILE_RE = re.compile(r"TOKENFUSE_UPSTREAM_KEY_FILE\b.*?value:\s*\"([^\"]+)\"")
FLOW_NAME_RE = re.compile(r"-\s*\{?\s*name:\s*([A-Za-z0-9._-]+)")
SECRETNAME_RE = re.compile(r"secretName:\s*([A-Za-z0-9._-]+)")
IMAGE_RE = re.compile(r"image:\s*ghcr\.io/taipanbox/tokenfuse:\S+\s*$", re.M)
COMMAND_RE = re.compile(r"command:\s*\[\s*\"([^\"]*)\"")


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def blank(line):
    s = line.strip()
    return s == "" or s.startswith("#")


def block_end(lines, header_idx, header_indent):
    j = header_idx + 1
    while j < len(lines):
        if not blank(lines[j]) and indent_of(lines[j]) <= header_indent:
            return j
        j += 1
    return len(lines)


def find_child(lines, start, end, key, indent):
    for j in range(start, end):
        line = lines[j]
        if blank(line):
            continue
        cur = indent_of(line)
        if cur < indent:
            return None
        if cur == indent and line.strip() == key + ":":
            return j
    return None


def list_items(lines, field_idx, field_indent):
    """The (start, end) of each item of the list under field_idx, as text spans."""
    end = block_end(lines, field_idx, field_indent)
    item_indent = None
    for j in range(field_idx + 1, end):
        if not blank(lines[j]) and lines[j].lstrip().startswith("- "):
            item_indent = indent_of(lines[j])
            break
    if item_indent is None:
        return []
    starts = [j for j in range(field_idx + 1, end)
              if not blank(lines[j]) and indent_of(lines[j]) == item_indent
              and lines[j].lstrip().startswith("- ")]
    spans = []
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else end
        spans.append("\n".join(lines[s:e]))
    return spans


def pod_spec(lines, kind_idx, path):
    start, end, indent, idx = kind_idx, len(lines), -2, None
    for key in path:
        indent += 2
        idx = find_child(lines, start, end, key, indent)
        if idx is None:
            return None, None
        start = idx + 1
        end = block_end(lines, idx, indent)
    return idx, indent


def field_items(lines, pod_idx, pod_indent, key):
    idx = find_child(lines, pod_idx + 1, block_end(lines, pod_idx, pod_indent), key, pod_indent + 2)
    if idx is None:
        return []
    return list_items(lines, idx, pod_indent + 2)


def item_name(span):
    first = span.split("\n", 1)[0]
    m = re.search(r"name:\s*([A-Za-z0-9._-]+)", first)
    return m.group(1) if m else "(unnamed)"


def is_gateway(span):
    if not IMAGE_RE.search(span):
        return False
    m = COMMAND_RE.search(span)
    if not m:
        return False
    if not m.group(1).split("/")[-1] == "tokenfuse":
        return False
    return not re.search(r"^\s*args:", span, re.M)


def env_entries(span):
    """(name, item_text) for each env entry: a flow item or a block item with name, value or valueFrom."""
    lines = span.split("\n")
    out = []
    env_idx = None
    for j, line in enumerate(lines):
        if line.strip() == "env:":
            env_idx = j
            break
    if env_idx is None:
        return out
    env_indent = indent_of(lines[env_idx])
    item_indent = None
    starts = []
    for j in range(env_idx + 1, len(lines)):
        line = lines[j]
        if blank(line):
            continue
        if indent_of(line) <= env_indent:
            break
        if line.lstrip().startswith("- ") and (item_indent is None or indent_of(line) == item_indent):
            item_indent = indent_of(line)
            starts.append(j)
    for s in starts:
        e = len(lines)
        for j in range(s + 1, len(lines)):
            if not blank(lines[j]) and indent_of(lines[j]) <= item_indent:
                e = j
                break
        text = "\n".join(lines[s:e])
        m = FLOW_NAME_RE.search(lines[s])
        if m:
            out.append((m.group(1), text))
    return out


def secret_name_after(text, marker):
    """The name: of the Secret a secretKeyRef or secretRef names, flow or block form."""
    i = text.find(marker)
    if i < 0:
        return None
    m = re.search(r"name:\s*([A-Za-z0-9._-]+)", text[i:i + 300])
    return m.group(1) if m else None


def mounts(span):
    """(volume name, mountPath) for each volumeMount in the container."""
    out = []
    for m in re.finditer(r"\{\s*name:\s*([A-Za-z0-9._-]+)\s*,\s*mountPath:\s*([^,}\s]+)", span):
        out.append((m.group(1), m.group(2)))
    lines = span.split("\n")
    for j, line in enumerate(lines):
        if line.strip() == "volumeMounts:":
            base = indent_of(line)
            cur = None
            for k in range(j + 1, len(lines)):
                ln = lines[k]
                if blank(ln):
                    continue
                if indent_of(ln) <= base:
                    break
                if re.match(r"\s*-\s*name:", ln):
                    cur = [re.search(r"name:\s*(\S+)", ln).group(1), None]
                    out.append(cur)
                elif cur is not None and re.match(r"\s*mountPath:", ln):
                    cur[1] = ln.split("mountPath:", 1)[1].strip()
            out = [o for o in out if o[1] is not None]
    return out


def violations_for_doc(doc, label, found):
    lines = doc.split("\n")
    kind_m = re.search(r"^kind:\s*(\S+)", doc, re.M)
    # A kind-less document is a kubectl patch body (manifests-valid.sh skips them by
    # name); it is judged as a pod template, the shape every patch here takes.
    kind = kind_m.group(1) if kind_m else "Patch"
    path = POD_PATHS.get(kind, POD_PATHS["Deployment"] if kind == "Patch" else None)
    if path is None:
        return []
    pod_idx, pod_indent = pod_spec(lines, 0, path)
    if pod_idx is None:
        return []
    meta = re.search(r"^metadata:", doc, re.M)
    name_m = re.search(r"name:\s*([A-Za-z0-9._-]+)", doc[meta.end():meta.end() + 400]) if meta else None
    obj = name_m.group(1) if name_m else "(unnamed)"
    volumes = {}
    for span in field_items(lines, pod_idx, pod_indent, "volumes"):
        vname = item_name(span)
        sec = SECRETNAME_RE.search(span)
        optional = re.search(r"optional:\s*true", span) is not None
        volumes[vname] = (sec.group(1) if sec else None, optional)
    bad = []
    for span in field_items(lines, pod_idx, pod_indent, "containers"):
        cname = item_name(span)
        gw = is_gateway(span)
        if gw:
            found["gateways"] += 1
        key = (kind, obj, cname)
        env = env_entries(span)
        env_names = {n for n, _ in env}
        # 1 and 2: what a container reads from a Secret into its environment
        for ename, text in env:
            secret = secret_name_after(text, "secretKeyRef")
            if not secret:
                continue
            if gw:
                if PROVIDER_ENV_RE.search(ename):
                    bad.append(f"{label}: {kind} {obj}, gateway container {cname}: env {ename} "
                               f"from Secret {secret}; the gateway takes its provider key as a file")
                continue
            if secret in PROVIDER_SECRETS:
                if (kind, obj, cname, secret) in EXCEPTIONS:
                    found["exceptions"] += 1
                    continue
                bad.append(f"{label}: {kind} {obj}, container {cname}: env {ename} reads the provider "
                           f"Secret {secret}; only a gateway start may hold a provider key")
            elif PROVIDER_ENV_RE.search(ename) and not CLIENT_KEY_RE.search(secret):
                bad.append(f"{label}: {kind} {obj}, container {cname}: env {ename} is provider-shaped "
                           f"and reads Secret {secret}, which is not a client key Secret")
        for sm in re.finditer(r"secretRef", span):
            secret = secret_name_after(span[sm.start():], "secretRef")
            if secret in PROVIDER_SECRETS:
                if gw:
                    bad.append(f"{label}: {kind} {obj}, gateway container {cname}: envFrom reads {secret}")
                elif (kind, obj, cname, secret) in EXCEPTIONS:
                    found["exceptions"] += 1
                else:
                    bad.append(f"{label}: {kind} {obj}, container {cname}: envFrom reads the provider "
                               f"Secret {secret}")
        # 1: a provider Secret mounted as a volume by a container that is not a gateway start
        mounted = mounts(span)
        for vname, _path in mounted:
            sec, optional = volumes.get(vname, (None, False))
            if sec not in PROVIDER_SECRETS:
                continue
            if gw:
                continue
            if (kind, obj, cname, sec) in EXCEPTIONS:
                found["exceptions"] += 1
                continue
            bad.append(f"{label}: {kind} {obj}, container {cname}: mounts the provider Secret {sec} "
                       f"as volume {vname}")
        # 3: a gateway start takes its provider key as a file
        if gw:
            km = KEYFILE_RE.search(span)
            if not km:
                bad.append(f"{label}: {kind} {obj}, gateway container {cname}: no literal "
                           f"TOKENFUSE_UPSTREAM_KEY_FILE, so the gateway holds no provider key")
                continue
            keypath = km.group(1)
            keydir = keypath.rsplit("/", 1)[0] if "/" in keypath else "."
            good = False
            for vname, path in mounted:
                sec, optional = volumes.get(vname, (None, False))
                if sec == UPSTREAM_SECRET and not optional and path.rstrip("/") == keydir.rstrip("/"):
                    good = True
            if not good:
                bad.append(f"{label}: {kind} {obj}, gateway container {cname}: TOKENFUSE_UPSTREAM_KEY_FILE "
                           f"{keypath} is not under a mounted, non-optional Secret {UPSTREAM_SECRET}")
            found["file_gateways"] += 1 if good else 0
    return bad


files = sorted(glob.glob("manifests/*.yaml"))
if not files:
    print("FAIL: no manifests/*.yaml found, so this gate measured nothing", file=sys.stderr)
    sys.exit(1)

found = {"gateways": 0, "file_gateways": 0, "exceptions": 0}
bad = []
for f in files:
    text = open(f, encoding="utf-8").read()
    for doc in re.split(r"^---\s*$", text, flags=re.M):
        bad.extend(violations_for_doc(doc, f, found))

if found["gateways"] == 0:
    print("FAIL: no gateway start found under manifests/, so this gate measured nothing", file=sys.stderr)
    sys.exit(1)

if bad:
    for b in bad:
        print("FAIL: " + b)
    sys.exit(1)

print(f"OK: {found['gateways']} gateway start(s) take their provider key from a mounted file; "
      f"no other container holds one ({found['exceptions']} named exception use(s), "
      f"see EXCEPTIONS in this script).")
PY
