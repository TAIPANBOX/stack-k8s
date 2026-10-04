#!/usr/bin/env bash
# Enforces: every container that runs the tokenfuse gateway in serve mode reads
# TOKENFUSE_DECLASSIFY_KEY from the stack-keys Secret, and every installer that
# mints that Secret puts the key in on stdin, never on a command line.
#
# WHY
#
# `POST /v1/fuse/declassify` is the gateway's release valve for its agent
# firewall: a person reviews a run and the taint label comes off it. It is not
# behind TOKENFUSE_ADMIN_KEYS. Its own credential, TOKENFUSE_DECLASSIFY_KEY
# (presented as `x-fuse-declassify-key`), is OPTIONAL in the gateway, and with
# it unset anything that can reach port 4100 can clear a run, recorded only as
# `authenticated: false` (tokenfuse crates/gateway/src/declassify.rs). No
# component of this estate calls the endpoint, so a key only the operator holds
# closes it by default and breaks nothing.
#
# WHAT THIS CHECKS, TWO HALVES
#
# 1. Manifests. Every gateway-in-serve-mode container carries an env entry
#    TOKENFUSE_DECLASSIFY_KEY whose value is
#    `valueFrom: secretKeyRef: { name: stack-keys, key: declassify_key }`:
#    never a literal `value:` (a key committed to a public repository is no
#    key), never `optional: true` (a pod that starts without it starts with the
#    endpoint open), never a different Secret or key.
# 2. Installers. Every script that runs kubectl to create the stack-keys Secret
#    passes declassify_key through stdin (`--from-file=declassify_key=/dev/stdin`
#    on a command fed by a pipe), and its migration for a cluster that already
#    has the Secret patches it in with `--patch-file /dev/stdin`. Neither
#    `--from-literal=declassify_key=` nor `patch ... -p '{...declassify_key...}'`
#    is allowed: both put the key on an ssh command line, readable in the
#    process table of both ends. (The other keys in that Secret still ride the
#    command line; that is an older finding this gate does not claim to close.)
#
# That the installers create the key at all is secret-keys-agree.sh's job
# (invariant 17), which reads this manifest reference like any other. This gate
# holds what it cannot see: the value's SOURCE and the way it travels.
#
# SUBJECTS ARE FOUND, NOT LISTED
#
# Containers come from what manifests/kustomization.yaml includes, found by
# image and command exactly as gateway-cache-is-off.sh finds them: the
# published tokenfuse image, the tokenfuse binary, no `args:` (a subcommand such
# as focus-export or mcp-broker never serves this route). Installers are the
# tracked shell scripts that create stack-keys. If either set is empty this
# says it measured nothing and fails: silence is not health.
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


def declassify_entry(block_text):
    """The env entry for TOKENFUSE_DECLASSIFY_KEY, as text, or None.

    The entry runs from its `name:` to the next env entry, so a comment line
    between `name:` and `valueFrom:` is inside it, and so is a flow-style
    `{ name: ..., valueFrom: { ... } }` on one line.
    """
    m = re.search(r'\{\s*name:\s*TOKENFUSE_DECLASSIFY_KEY\b[^\n]*', block_text)
    if m:
        return m.group(0)
    m = re.search(r'-\s*name:\s*TOKENFUSE_DECLASSIFY_KEY\s*\n', block_text)
    if not m:
        return None
    rest = block_text[m.end():]
    nxt = re.search(r'^\s*-\s*(?:name:|\{)', rest, re.M)
    return rest[: nxt.start()] if nxt else rest


def judge(entry):
    """Returns None when the entry is right, else the reason it is not."""
    body = "\n".join(l for l in entry.split("\n") if not l.strip().startswith("#"))
    if re.search(r'(?:^|[\s,{])value:\s', body) and "valueFrom" not in body:
        return "TOKENFUSE_DECLASSIFY_KEY is set from a literal value, not a secretKeyRef"
    if "secretKeyRef" not in body:
        return "TOKENFUSE_DECLASSIFY_KEY is not read from a secretKeyRef"
    if re.search(r'optional:\s*true', body):
        return "TOKENFUSE_DECLASSIFY_KEY is marked optional, so a pod starts without it and the endpoint is open"
    name = re.search(r'name:\s*([A-Za-z0-9_.-]+)\s*[,}]', body.split("secretKeyRef", 1)[1])
    key = re.search(r'key:\s*([A-Za-z0-9_.-]+)', body.split("secretKeyRef", 1)[1])
    got = f"{name.group(1) if name else '?'}/{key.group(1) if key else '?'}"
    if got != "stack-keys/declassify_key":
        return f"TOKENFUSE_DECLASSIFY_KEY reads {got}, not stack-keys/declassify_key"
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
        where = f"{fname}:{line_no} {kind} {name}, container {cname}"
        entry = declassify_entry(block_text)
        if entry is None:
            results.append((False,
                f"{where}: no TOKENFUSE_DECLASSIFY_KEY env var, so POST "
                f"/v1/fuse/declassify is open to anything that reaches the gateway "
                f"port and records only authenticated: false"))
            continue
        why = judge(entry)
        if why:
            results.append((False, f"{where}: {why}"))
        else:
            results.append((True, where))
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
    print("      no longer knows how to find it. This measured nothing about the declassify key,")
    print("      and it is not entitled to say OK.")
    sys.exit(1)

failures = [msg for ok, msg in results if not ok]


CREATE_STACK_KEYS = "create secret generic " + "stack-keys"


def installers():
    import subprocess
    # A subject RUNS the kubectl: a non-comment line of the form
    # a kubectl create of the stack-keys Secret behind k_, su_ or sh_. Not any
    # file that merely mentions it: the teeth harness and secret-keys-agree.sh
    # do, in prose and in strings. The phrase is also built from two halves
    # below, never written whole in this file: secret-keys-agree.sh reads every
    # tracked script for it, and found THIS one as a subject the first time.
    mention = subprocess.run(
        ["git", "grep", "-l", CREATE_STACK_KEYS, "--", "*.sh"],
        capture_output=True, text=True,
    ).stdout.split()
    runs = re.compile(r'(?:k_|su_|sh_) +"[^"]*' + CREATE_STACK_KEYS)
    out = []
    for path in mention:
        for l in pathlib.Path(path).read_text().split("\n"):
            if not l.strip().startswith("#") and runs.search(l):
                out.append(path)
                break
    return sorted(out)


scripts = installers()
if not scripts:
    print("FAIL: no tracked shell script creates the stack-keys Secret, so this measured")
    print("      NOTHING about how the declassify key travels. That is not a clean run.")
    sys.exit(1)

for path in scripts:
    text = pathlib.Path(path).read_text()
    lines = text.split("\n")
    code = [l for l in lines if not l.strip().startswith("#")]
    joined = "\n".join(code)
    if re.search(r"--from-literal=declassify_key=", joined):
        failures.append(f"{path} puts declassify_key on a command line with --from-literal; "
                        f"it must come in on stdin (--from-file=declassify_key=/dev/stdin)")
    for l in code:
        if "declassify_key" in l and re.search(r"(?:\s-p\s|\s--patch\s|\s--patch=)", l):
            failures.append(f"{path} patches declassify_key on a command line (-p); "
                            f"it must go in with --patch-file /dev/stdin")
            break
    piped_create = re.search(
        r"\|\s*(?:k_|su_|sh_)\s+\"[^\n]*" + CREATE_STACK_KEYS + r"[^\n]*\\\n"
        r"(?:[^\n]*\\\n)*[^\n]*--from-file=declassify_key=/dev/stdin", joined)
    piped_create = piped_create or re.search(
        r"\|\s*(?:k_|su_|sh_)\s+\"[^\n]*" + CREATE_STACK_KEYS + r"[^\n]*--from-file=declassify_key=/dev/stdin", joined)
    if not piped_create:
        failures.append(f"{path} never creates declassify_key from stdin: the create block "
                        f"for stack-keys must be fed by a pipe and carry "
                        f"--from-file=declassify_key=/dev/stdin")
    migrates = any(
        "declassify_key" in l and "--patch-file /dev/stdin" in l and "patch secret stack-keys" in l
        for l in code
    )
    if not migrates:
        failures.append(f"{path} has no stdin patch for declassify_key, so a cluster whose "
                        f"stack-keys Secret already exists never gets the key and its gateway "
                        f"pod cannot start")

for msg in failures:
    print(f"FAIL: {msg}")

if failures:
    print()
    print(f"{len(failures)} problem(s). The gateway's declassify key must come from the")
    print("stack-keys Secret, and the installers must mint it without an argument.")
    print("See CLAUDE.md, the declassify key invariant.")
    sys.exit(1)

print(f"OK: {len(results)} gateway container(s) in serve mode read TOKENFUSE_DECLASSIFY_KEY "
      f"from stack-keys/declassify_key, and {len(scripts)} installer(s) mint it on stdin.")
PY
