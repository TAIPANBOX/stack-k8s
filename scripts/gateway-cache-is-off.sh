#!/usr/bin/env bash
# Enforces the newest invariant in CLAUDE.md: every container that runs the
# tokenfuse gateway in serve mode ships TOKENFUSE_CACHE=off.
#
# WHY
#
# The gateway (the `tokenfuse` binary, no subcommand) enables its semantic
# response cache in shadow mode whenever TOKENFUSE_CACHE is unset
# (tokenfuse v1.0.4, crates/gateway/src/main.rs:992-997). Shadow mode takes
# one global mutex on every call, walks up to 10,000 cached entries computing
# cosine similarity, serves nothing, and appends another entry: it costs the
# lock without ever paying it back. Measured on a 4-core N150 appliance,
# 2026-09-24: 50 agents gave 177 calls/s with 403 refusals and CPU 79-92%
# inside SemanticCache::get; with TOKENFUSE_CACHE=off the same load gave
# 1102 calls/s, zero refusals, no slowdown over time. TAIPANBOX/tokenfuse#319.
#
# The fix is one env var per gateway container, and the trap this gate exists
# for is the ordinary one: a second deploy path, or a new manifest, ships the
# gateway without it and nobody notices until the shadow cache serialises a
# cluster under load.
#
# WHAT THIS CHECKS
#
# A container is a "gateway in serve mode" when it runs the published
# tokenfuse image with the tokenfuse binary and no subcommand: an image
# reference of exactly ghcr.io/taipanbox/tokenfuse:<tag> (never
# tokenfuse-control-plane, a different binary and a different plane), a
# command whose last path element is "tokenfuse", and no args: key, which is
# how a subcommand like `focus-export` or `mcp-broker` would be passed.
# Neither of those reaches the semantic cache and neither is a subject here.
#
# Every such container must carry TOKENFUSE_CACHE with the literal value off,
# either as `{ name: TOKENFUSE_CACHE, value: "off" }` or the block form.
#
# SUBJECTS ARE FOUND, NOT LISTED
#
# Subjects come from what manifests/kustomization.yaml actually includes
# (see closed-by-default.sh for the same approach), not a hard-coded file or
# container name: a new manifest added to resources: is covered the day it
# lands, and a manifest taken out of resources: stops being a subject the way
# it stops being applied.
#
# HOW, WITHOUT A YAML LIBRARY
#
# Parsed by indentation and known key names, the same technique as
# no-sa-token-by-default.sh: the pod spec sits at a fixed depth per kind, the
# containers: list sits under it, and each container is a list item bounded
# by the next "- name:" at the same indent or the end of the containers
# block.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import pathlib
import re
import sys

POD_TEMPLATE_KINDS = {
    "Deployment":  ["spec", "template", "spec"],
    "StatefulSet": ["spec", "template", "spec"],
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
    n = len(lines)
    while j < n:
        if not is_blank_or_comment(lines[j]) and indent_of(lines[j]) <= header_indent:
            return j
        j += 1
    return n


def find_child(lines, start, end, key, indent):
    j = start
    while j < end:
        line = lines[j]
        if is_blank_or_comment(line):
            j += 1
            continue
        cur = indent_of(line)
        if cur < indent:
            return None
        if cur == indent and line.strip() == key + ":":
            return j
        j += 1
    return None


def locate_pod_spec(lines, kind_line_idx, path):
    start, end, indent = kind_line_idx, len(lines), -2
    idx = None
    for key in path:
        indent += 2
        idx = find_child(lines, start, end, key, indent)
        if idx is None:
            return None
        start = idx + 1
        end = block_end(lines, idx, indent)
    return idx, indent


def container_blocks(lines, pod_idx, pod_indent):
    """Find containers: under the pod spec and split it into one block per
    list item. Returns a list of (start_idx, end_idx, item_indent)."""
    field_indent = pod_indent + 2
    containers_idx = find_child(lines, pod_idx + 1, block_end(lines, pod_idx, pod_indent),
                                 "containers", field_indent)
    if containers_idx is None:
        return []
    c_end = block_end(lines, containers_idx, field_indent)

    # List items are "<item_indent>- name: ..."; item_indent is whatever the
    # first "- " under containers: uses, read rather than assumed, since this
    # repo is not perfectly uniform about list-item indent.
    item_indent = None
    j = containers_idx + 1
    while j < c_end:
        line = lines[j]
        if not is_blank_or_comment(line) and line.lstrip().startswith("- "):
            item_indent = indent_of(line)
            break
        j += 1
    if item_indent is None:
        return []

    starts = []
    j = containers_idx + 1
    while j < c_end:
        line = lines[j]
        if (not is_blank_or_comment(line) and indent_of(line) == item_indent
                and line.lstrip().startswith("- ")):
            starts.append(j)
        j += 1

    blocks = []
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else c_end
        blocks.append((s, e, item_indent))
    return blocks


IMAGE_RE = re.compile(r'image:\s*ghcr\.io/taipanbox/tokenfuse:\S+\s*$', re.M)
COMMAND_RE = re.compile(r'command:\s*\[\s*"([^"]*)"')
NAME_RE = re.compile(r'^\s*-\s*name:\s*(\S+)')


def container_name(block_text):
    m = re.search(r'name:\s*(\S+)', block_text)
    return m.group(1) if m else "(unnamed)"


def is_gateway_serve_container(block_text):
    if not IMAGE_RE.search(block_text):
        return False
    m = COMMAND_RE.search(block_text)
    if not m:
        return False
    binary = m.group(1).rsplit("/", 1)[-1]
    if binary != "tokenfuse":
        return False
    if re.search(r'^\s*args:', block_text, re.M):
        return False
    return True


def cache_value(block_text):
    """Returns the TOKENFUSE_CACHE value string, or None if the env var is
    not present at all in this container."""
    m = re.search(r'\{\s*name:\s*TOKENFUSE_CACHE\s*,\s*value:\s*"?([^",}]+)"?\s*\}', block_text)
    if m:
        return m.group(1)
    m = re.search(r'-\s*name:\s*TOKENFUSE_CACHE\s*\n\s*(?:#.*\n\s*)*value:\s*"?([^"\n]+)"?', block_text)
    if m:
        return m.group(1)
    return None


def check_document(fname, doc_first_line, lines):
    kind = None
    kind_idx = None
    for i, line in enumerate(lines):
        if is_blank_or_comment(line):
            continue
        if indent_of(line) == 0 and line.startswith("kind:"):
            kind = line.split(":", 1)[1].strip()
            kind_idx = i
            break

    if kind not in POD_TEMPLATE_KINDS:
        return []

    name = "(unnamed)"
    for line in lines:
        s = line.strip()
        if s.startswith("name:"):
            name = s.split(":", 1)[1].strip()
            break

    located = locate_pod_spec(lines, kind_idx, POD_TEMPLATE_KINDS[kind])
    if located is None:
        return []
    pod_idx, pod_indent = located

    results = []
    for start, end, _item_indent in container_blocks(lines, pod_idx, pod_indent):
        block_text = "\n".join(lines[start:end])
        if not is_gateway_serve_container(block_text):
            continue
        cname = container_name(block_text)
        line_no = doc_first_line + start + 1
        value = cache_value(block_text)
        if value is None:
            results.append((False,
                f"{fname}:{line_no} {kind} {name}, container {cname}: no "
                f"TOKENFUSE_CACHE env var, so the gateway's shadow default "
                f"stands"))
        elif value != "off":
            results.append((False,
                f"{fname}:{line_no} {kind} {name}, container {cname}: "
                f"TOKENFUSE_CACHE={value!r}, not \"off\""))
        else:
            results.append((True, f"{fname}:{line_no} {kind} {name}, container {cname}"))
    return results


results = []
kustomization = pathlib.Path("manifests/kustomization.yaml")
text = kustomization.read_text()
m = re.search(r"^resources:\s*$", text, re.M)
if not m:
    print(f"FAIL: no resources: block in {kustomization}, so this measured nothing")
    sys.exit(1)

resources = []
for line in text[m.end():].splitlines():
    if not line.strip():
        continue
    item = re.match(r"^\s*-\s+(\S+)\s*$", line)
    if not item:
        break
    resources.append(item.group(1))

for name in resources:
    path = pathlib.Path("manifests") / name
    if not path.exists() or path.name == "secrets.example.yaml":
        continue
    ftext = path.read_text()
    doc_lines = []
    doc_start = 0
    line_no = 0
    for line in ftext.split("\n"):
        if line.rstrip() == "---":
            if doc_lines:
                results.extend(check_document(str(path), doc_start, doc_lines))
            doc_lines = []
            doc_start = line_no + 1
        else:
            doc_lines.append(line)
        line_no += 1
    if doc_lines:
        results.extend(check_document(str(path), doc_start, doc_lines))

if not results:
    print("FAIL: no container running the tokenfuse gateway in serve mode was found")
    print("      under any manifest manifests/kustomization.yaml includes. That is")
    print("      not health: either the gateway moved, was renamed, or this check")
    print("      no longer knows how to find it. This measured nothing about the")
    print("      semantic cache, and it is not entitled to say OK.")
    sys.exit(1)

failures = [msg for ok, msg in results if not ok]
for msg in failures:
    print(f"FAIL: {msg}")

if failures:
    print()
    print(f"{len(failures)} of {len(results)} gateway container(s) still run with the")
    print("semantic cache's shadow default. Shadow mode takes one global mutex on")
    print("every call and serves nothing back for it (tokenfuse#319). Set")
    print("TOKENFUSE_CACHE=off on every gateway container.")
    sys.exit(1)

print(f"OK: {len(results)} gateway container(s) in serve mode, every one sets "
      "TOKENFUSE_CACHE=off.")
PY
