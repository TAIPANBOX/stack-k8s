#!/usr/bin/env bash
# CLAUDE.md invariant 35: a container that needs a temp directory and runs with a
# read-only root has a writable, size-limited one.
#
# WHY
#
# SQLite writes a VACUUM's working copy, and a sort too big for memory, to a
# temp file; Go spools a large upload to one. With `readOnlyRootFilesystem:
# true` and nothing writable mounted, SQLite answers `disk I/O error (6410)`,
# its "no temp path" error. Found by the costcrew v0.4.0 pin (stack-single#93,
# stack-k8s#133): the first start over a v0.3.0 store dropped the clear-text
# session tokens and then could not VACUUM them out of the file's free pages.
# The console said so as a WARNING and carried on, so nothing went red: every
# gate here passed, kubeconform accepted the pod, and the tokens it had just
# promised to erase stayed in free space.
#
# WHAT THIS CHECKS
#
# Subjects, found rather than listed: every container in every pod template in
# manifests/*.yaml whose image is one of NEEDS_TEMP below. Each must either
# have a writable root, or:
#
#   - mount a volume at /tmp that is not readOnly, or set TMPDIR to a path
#     inside a mount that is not readOnly; and
#   - when that volume is an emptyDir, give it a sizeLimit: an unbounded temp
#     is the node's memory or disk, not this plane's.
#
# A volume a mount names that the pod does not declare is a failure too.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no manifests/*.yaml, or no container
# running a NEEDS_TEMP image, is reported and fails.
#
# WHAT IT DOES NOT DO. NEEDS_TEMP is a list somebody keeps: an image added later
# that needs a temp and is not named here is not judged. It does not check that
# the size is enough for the database a cluster actually holds, and it reads the
# manifests, not a running pod.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import pathlib
import re
import sys

# image prefix -> why it needs a temp directory
NEEDS_TEMP = {
    "ghcr.io/taipanbox/costcrew:": "SQLite (VACUUM, large sorts) and Go's multipart spool",
}

POD_TEMPLATE_KINDS = {
    "Deployment":  ["spec", "template", "spec"],
    "StatefulSet": ["spec", "template", "spec"],
    "DaemonSet":   ["spec", "template", "spec"],
    "Job":         ["spec", "template", "spec"],
    "CronJob":     ["spec", "jobTemplate", "spec", "template", "spec"],
}


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_blank_or_comment(line):
    s = line.strip()
    return s == "" or s.startswith("#")


def block_end(lines, header_idx, header_indent):
    j = header_idx + 1
    while j < len(lines):
        if not is_blank_or_comment(lines[j]) and indent_of(lines[j]) <= header_indent:
            return j
        j += 1
    return len(lines)


def find_child(lines, start, end, key, indent):
    for j in range(start, end):
        line = lines[j]
        if is_blank_or_comment(line):
            continue
        if indent_of(line) < indent:
            return None
        if indent_of(line) == indent and line.strip() == key + ":":
            return j
    return None


def locate_pod_spec(lines, kind_idx, path):
    start, end, indent, idx = kind_idx, len(lines), -2, None
    for key in path:
        indent += 2
        idx = find_child(lines, start, end, key, indent)
        if idx is None:
            return None
        start, end = idx + 1, block_end(lines, idx, indent)
    return idx, indent


def list_items(lines, start, end):
    item_indent = None
    for j in range(start, end):
        if not is_blank_or_comment(lines[j]) and lines[j].lstrip().startswith("- "):
            item_indent = indent_of(lines[j])
            break
    if item_indent is None:
        return []
    starts = [j for j in range(start, end)
              if not is_blank_or_comment(lines[j]) and indent_of(lines[j]) == item_indent
              and lines[j].lstrip().startswith("- ")]
    out = []
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else end
        out.append("\n".join(l.split(" #")[0] for l in lines[s:e] if not is_blank_or_comment(l)))
    return out


def child_items(lines, start, end, key, indent):
    idx = find_child(lines, start, end, key, indent)
    if idx is None:
        return []
    return list_items(lines, idx + 1, block_end(lines, idx, indent))


def value(text, key):
    m = re.search(r"(?:^|[\s{,-])" + key + r":\s*([^,}\n]+)", text)
    return m.group(1).strip().strip('"').strip("'") if m else None


def under(path, mount):
    return path == mount or path.startswith(mount.rstrip("/") + "/")


errors = []
subjects = 0
files = sorted(pathlib.Path("manifests").glob("*.yaml"))
if not files:
    print("FAIL: no manifests/*.yaml, so this gate measured NOTHING.")
    sys.exit(1)

for f in files:
    lines = f.read_text().split("\n")
    for k, line in enumerate(lines):
        m = re.match(r"^kind:\s*(\w+)\s*$", line)
        if not m or m.group(1) not in POD_TEMPLATE_KINDS:
            continue
        kind = m.group(1)
        name = "?"
        for j in range(k, min(k + 40, len(lines))):
            nm = re.match(r"^  name:\s*(\S+)", lines[j]) or re.match(r"^metadata:.*name:\s*([\w-]+)", lines[j])
            if nm:
                name = nm.group(1)
                break
        found = locate_pod_spec(lines, k, POD_TEMPLATE_KINDS[kind])
        if found is None:
            continue
        pod_idx, pod_indent = found
        pod_end = block_end(lines, pod_idx, pod_indent)
        volumes = {}
        for item in child_items(lines, pod_idx + 1, pod_end, "volumes", pod_indent + 2):
            vname = value(item, "name")
            if vname:
                volumes[vname] = item
        cidx = find_child(lines, pod_idx + 1, pod_end, "containers", pod_indent + 2)
        if cidx is None:
            continue
        cend = block_end(lines, cidx, pod_indent + 2)
        item_indent = None
        for j in range(cidx + 1, cend):
            if not is_blank_or_comment(lines[j]) and lines[j].lstrip().startswith("- "):
                item_indent = indent_of(lines[j])
                break
        starts = [j for j in range(cidx + 1, cend)
                  if item_indent is not None and not is_blank_or_comment(lines[j])
                  and indent_of(lines[j]) == item_indent and lines[j].lstrip().startswith("- ")]
        for i, s in enumerate(starts):
            e = starts[i + 1] if i + 1 < len(starts) else cend
            text = "\n".join(lines[s:e])
            image = value(text, "image") or ""
            why = next((w for p, w in NEEDS_TEMP.items() if image.startswith(p)), None)
            if why is None:
                continue
            subjects += 1
            cname = value(lines[s].replace("- ", "", 1), "name") or "?"
            where = f"{f}: {kind}/{name} container {cname}"
            if not re.search(r"readOnlyRootFilesystem:\s*true", text):
                continue
            field = item_indent + 2
            mounts = []
            for mi in child_items(lines, s + 1, e, "volumeMounts", field):
                mounts.append((value(mi, "name"), value(mi, "mountPath") or "",
                               (value(mi, "readOnly") or "false") == "true"))
            tmpdir = None
            for ei in child_items(lines, s + 1, e, "env", field):
                if value(ei, "name") == "TMPDIR":
                    tmpdir = value(ei, "value")
            target = tmpdir or "/tmp"
            hits = [mt for mt in mounts if under(target, mt[1])]
            hits.sort(key=lambda mt: len(mt[1]), reverse=True)
            if not hits:
                errors.append(f"{where}: the root is read-only and nothing writable is mounted at {target}"
                              f"{' (TMPDIR)' if tmpdir else ''}: it needs a temp for {why}, and without one "
                              "SQLite fails with disk I/O error (6410), no temp path")
                continue
            vname, mpath, ro = hits[0]
            if ro:
                errors.append(f"{where}: its temp {target} is on the mount {mpath}, which is readOnly")
                continue
            vol = volumes.get(vname)
            if vol is None:
                errors.append(f"{where}: its temp mount {mpath} names volume {vname}, which the pod does not declare")
                continue
            if "emptyDir" in vol and not re.search(r"sizeLimit:\s*\S", vol):
                errors.append(f"{where}: its temp is the emptyDir {vname} with no sizeLimit; an unbounded "
                              "temp is the node's memory or disk, not this plane's")

if subjects == 0:
    print("FAIL: no container in manifests/*.yaml runs an image that needs a temp ("
          + ", ".join(NEEDS_TEMP) + "), so this gate measured NOTHING.")
    sys.exit(1)
if errors:
    for m in errors:
        print("FAIL: " + m)
    print()
    print(f"{len(errors)} problem(s). See CLAUDE.md invariant 35.")
    sys.exit(1)
print(f"OK: {subjects} container(s) that need a temp, each read-only at the root with a writable,")
print("    size-limited temp directory. See CLAUDE.md invariant 35.")
PY
