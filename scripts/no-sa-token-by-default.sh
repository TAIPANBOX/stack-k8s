#!/usr/bin/env bash
# Enforces invariant 15 of CLAUDE.md: no pod in this stack automounts the
# default ServiceAccount token.
#
# WHY
#
# No manifest here sets `automountServiceAccountToken`, and there is no RBAC
# in this repository at all: no ServiceAccount, Role or RoleBinding. That
# means every plane pod runs as the namespace's `default` ServiceAccount and
# gets kubelet's projected token for it, bound to nothing today. A compromised
# container still holds a valid API credential it can use for discovery and
# SelfSubjectReview, and the token is a live liability the day any operator
# binds a Role to `default` for an unrelated reason: the pod that was never
# meant to talk to the API server suddenly can, with no manifest change of its
# own.
#
# Confirmed by reading, not assumed: nothing under manifests/ or images/
# references `kubernetes.default`, a ServiceAccount token path, or an
# in-cluster client, and the only "k8s" strings in images/uapi-proxy are this
# repository's own module path. No workload here talks to the Kubernetes API.
#
# WHAT THIS CHECKS
#
# Every pod-template-bearing object under manifests/ (Deployment, StatefulSet,
# CronJob, Job) must set `automountServiceAccountToken: false` directly on its
# pod spec. A missing field and an explicit `true` are the same failure: both
# leave the token mounted.
#
# HOW, WITHOUT A YAML LIBRARY
#
# This repository parses YAML by indentation and known key names rather than
# pulling in a parser (see closed-by-default.sh, pinned-images.sh), so this
# gate does the same. The pod spec lives at a fixed, predictable depth for
# each kind:
#
#   Deployment / StatefulSet / Job    spec -> template -> spec
#   CronJob                           spec -> jobTemplate -> spec -> template -> spec
#
# and this repository's manifests are hand-written with a consistent 2-space
# indent and no list-item indirection above the pod spec, so walking that path
# by indentation is exact, not a heuristic. A key is matched only when found at
# EXACTLY the expected indent: a shallower line ends the enclosing block
# (the key was never there), and a deeper line belongs to some other key's own
# subtree and is skipped rather than mistaken for a match.
#
# Objects with no pod template (Service, ConfigMap, NetworkPolicy, PVC, and so
# on) are never inspected: the kind alone decides whether this gate has
# anything to say about a document.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
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
    """First index after header_idx whose (non-blank, non-comment) line sits
    at or above header_indent, i.e. where the header's own block ends."""
    j = header_idx + 1
    n = len(lines)
    while j < n:
        if not is_blank_or_comment(lines[j]) and indent_of(lines[j]) <= header_indent:
            return j
        j += 1
    return n


def find_child(lines, start, end, key, indent):
    """Find `<indent spaces>key:` at exactly `indent` within [start, end).
    A line at a shallower indent ends the search (the enclosing block is
    over); a line at a deeper indent belongs to some sibling key's own
    subtree and is skipped."""
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
    """Walk `path` (a list of mapping keys, all singular, no list indirection)
    starting at the document's own top level (indent 0), and return the
    (index, indent) of the final key's line, or None if any hop is missing."""
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


def check_document(fname, doc_first_line, lines):
    """Returns a list of (ok: bool, message: str) for every pod-template kind
    found in this document. Empty list means this document has nothing this
    gate inspects."""
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
        path = " -> ".join(POD_TEMPLATE_KINDS[kind])
        return [(False,
                 f"{fname}:{doc_first_line + kind_idx + 1} {kind} {name} has no "
                 f"{path} to inspect: this gate cannot find a pod spec at all")]

    pod_idx, pod_indent = located
    field_indent = pod_indent + 2
    field_end = block_end(lines, pod_idx, pod_indent)

    j = pod_idx + 1
    value = None
    field_line = None
    while j < field_end:
        line = lines[j]
        if (not is_blank_or_comment(line)
                and indent_of(line) == field_indent
                and line.strip().startswith("automountServiceAccountToken:")):
            value = line.strip().split(":", 1)[1].strip()
            field_line = doc_first_line + j + 1
            break
        j += 1

    if value is None:
        return [(False,
                 f"{fname}:{doc_first_line + pod_idx + 1} {kind} {name} does not set "
                 f"automountServiceAccountToken: false on its pod spec")]
    if value != "false":
        return [(False,
                 f"{fname}:{field_line} {kind} {name} sets "
                 f"automountServiceAccountToken: {value}, not false")]
    return [(True, f"{fname}:{field_line} {kind} {name}")]


results = []
files = sorted(glob.glob("manifests/*.yaml"))
for fname in files:
    text = open(fname).read()
    # Manifests here are multi-document YAML separated by a bare "---" line.
    # Track each document's starting line number so a failure points at the
    # real file, not an offset into a fragment.
    doc_lines = []
    doc_start = 0
    line_no = 0
    for line in text.split("\n"):
        if line.rstrip() == "---":
            if doc_lines:
                results.extend(check_document(fname, doc_start, doc_lines))
            doc_lines = []
            doc_start = line_no + 1
        else:
            doc_lines.append(line)
        line_no += 1
    if doc_lines:
        results.extend(check_document(fname, doc_start, doc_lines))

if not results:
    print("FAIL: no Deployment, StatefulSet, CronJob or Job found under manifests/,")
    print("      so this check measured nothing. It cannot tell whether every pod")
    print("      template disables the default token if it cannot find a pod")
    print("      template. If the manifests moved or changed shape, this check has")
    print("      to move with them; silence here is not health.")
    sys.exit(1)

failures = [msg for ok, msg in results if not ok]
for msg in failures:
    print(f"FAIL: {msg}")

if failures:
    print()
    print(f"{len(failures)} of {len(results)} pod template(s) still carry the")
    print("default ServiceAccount token. Nothing in this stack talks to the")
    print("Kubernetes API from inside a pod, so every pod template must set")
    print("automountServiceAccountToken: false. See CLAUDE.md invariant 15.")
    sys.exit(1)

print(f"OK: {len(results)} pod template(s) under manifests/, every one sets "
      "automountServiceAccountToken: false.")
PY
