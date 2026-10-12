#!/usr/bin/env bash
# The agent firewall runs in enforce in every gateway this launcher starts, and
# one switch changes it. CLAUDE.md invariant 37.
#
# WHY
#
# TokenFuse's agent firewall refuses a run that read untrusted input and then asks
# for a capability it should not have, keeps the anti-exfiltration floor on, and
# labels a run whose declared tools carry an injection finding (its invariants 25
# to 27 and 93). In shadow it refuses nothing and only records what it would have
# refused. An unset TOKENFUSE_FIREWALL reads as shadow (crates/gateway/src/
# firewall.rs), so a launcher that forgets the variable ships a gateway that
# protects nothing and says nothing about it.
#
# TokenFuse also ignores a misspelt value without a word (firewall.rs, from_env:
# any string other than the three words falls through). So the switch that
# changes the mode is validated by firewall/mode.sh before anything is installed.
#
# WHAT THIS CHECKS
#
#   1. every gateway this launcher starts sets TOKENFUSE_FIREWALL exactly once, to
#      the literal enforce
#   2. firewall/mode.sh is executable, accepts exactly enforce, shadow and off, and
#      refuses every other word on stderr with exit 1
#   3. every deploy path that applies the manifests takes --firewall, and runs
#      firewall/mode.sh check before its first apply
#
# SUBJECTS ARE FOUND, NOT LISTED
#
# A gateway start is a container running the published tokenfuse image with the
# tokenfuse binary in serve mode: an image ending in /tokenfuse:<tag>, and either
# no command (the image's own entrypoint is the binary) or a command that is
# exactly the binary, and no args. That is the definition CLAUDE.md invariant 20
# uses. Every manifests/*.yaml is read, not only what kustomization.yaml includes,
# so an opt-in workload that starts a gateway is judged the day it lands.
# focus-export (a shell with args) and the MCP broker (the binary with args:
# mcp-broker) are not gateway starts, and the serve path is the only one that reads
# the firewall. A command this check cannot read is counted as a start, so it is
# judged rather than skipped.
#
# A gate that finds no gateway start says so and exits 1. No subject is not a pass.
#
# It reads text. That the running gateway actually enforces needs a live cluster,
# which CLAUDE.md invariants 4 and 5 already say this repository cannot hold in a
# gate.
set -uo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import pathlib
import re
import subprocess
import sys

POD_TEMPLATE_KINDS = {
    "Deployment":  ["spec", "template", "spec"],
    "StatefulSet": ["spec", "template", "spec"],
    "Job":         ["spec", "template", "spec"],
    "CronJob":     ["spec", "jobTemplate", "spec", "template", "spec"],
}

MODES_ACCEPTED = ["enforce", "shadow", "off"]
MODES_REFUSED = ["", "enforced", "Enforce", "ENFORCE", " enforce", "enforce ",
                 "on", "true", "shadow;", "enforce\n"]

IMAGE_RE = re.compile(r'^\s*image:\s*"?(?:[^\s"]*/)?tokenfuse:\S+', re.M)
ARGS_RE = re.compile(r'^\s*args:', re.M)
COMMAND_FLOW_RE = re.compile(r'^\s*command:\s*\[(.*)\]\s*$', re.M)
COMMAND_BLOCK_RE = re.compile(r'^\s*command:\s*$', re.M)


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_blank_or_comment(line):
    s = line.strip()
    return s == "" or s.startswith("#")


def live(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


def block_end(lines, header_idx, header_indent):
    j = header_idx + 1
    while j < len(lines):
        if not is_blank_or_comment(lines[j]) and indent_of(lines[j]) <= header_indent:
            return j
        j += 1
    return len(lines)


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


def locate_pod_spec(lines, kind_idx, path):
    start, end, indent = kind_idx, len(lines), -2
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
    field_indent = pod_indent + 2
    containers_idx = find_child(lines, pod_idx + 1, block_end(lines, pod_idx, pod_indent),
                                "containers", field_indent)
    if containers_idx is None:
        return []
    c_end = block_end(lines, containers_idx, field_indent)
    item_indent = None
    for j in range(containers_idx + 1, c_end):
        if not is_blank_or_comment(lines[j]) and lines[j].lstrip().startswith("- "):
            item_indent = indent_of(lines[j])
            break
    if item_indent is None:
        return []
    starts = [j for j in range(containers_idx + 1, c_end)
              if not is_blank_or_comment(lines[j])
              and indent_of(lines[j]) == item_indent
              and lines[j].lstrip().startswith("- ")]
    return [(s, starts[i + 1] if i + 1 < len(starts) else c_end)
            for i, s in enumerate(starts)]


def is_serve_start(text):
    if not IMAGE_RE.search(text):
        return False
    if ARGS_RE.search(text):
        return False
    if COMMAND_BLOCK_RE.search(text):
        return True  # a command this check does not read is judged, not skipped
    m = COMMAND_FLOW_RE.search(text)
    if not m:
        return True  # no command: the image's own entrypoint, which is the binary
    argv = [p.strip().strip("\"'") for p in m.group(1).split(",") if p.strip()]
    return len(argv) == 1 and argv[0].rsplit("/", 1)[-1] == "tokenfuse"


def firewall_values(text):
    """One entry per TOKENFUSE_FIREWALL env var the container declares: the literal
    value, or None where the entry is not a literal (valueFrom, or no value)."""
    values = []
    for m in re.finditer(r'\{\s*name:\s*TOKENFUSE_FIREWALL\s*,\s*value:\s*"?([^",}]*?)"?\s*\}', text):
        values.append(m.group(1).strip())
    for m in re.finditer(r'-\s*name:\s*TOKENFUSE_FIREWALL\s*\n\s*value:\s*"?([^"\n]*?)"?\s*$',
                         text, re.M):
        values.append(m.group(1).strip())
    names = len(re.findall(r'name:\s*TOKENFUSE_FIREWALL\b', text))
    while len(values) < names:
        values.append(None)
    return values


def judge(text):
    vals = firewall_values(text)
    if not vals:
        return ("has no TOKENFUSE_FIREWALL env var, so the gateway falls back to its own "
                "default, shadow")
    if len(vals) > 1:
        return (f"TOKENFUSE_FIREWALL is set {len(vals)} times, and the later entry wins "
                "without a word")
    v = vals[0]
    if v is None:
        return ("TOKENFUSE_FIREWALL is not a literal value, so the launcher cannot say what "
                "the gateway will read")
    if v != "enforce":
        return f'TOKENFUSE_FIREWALL is "{v}", not "enforce"'
    return None


def check_document(path, doc_start, lines):
    kind, kind_idx = None, None
    for i, line in enumerate(lines):
        if not is_blank_or_comment(line) and indent_of(line) == 0 and line.startswith("kind:"):
            kind, kind_idx = line.split(":", 1)[1].strip(), i
            break
    if kind not in POD_TEMPLATE_KINDS:
        return []
    name = "(unnamed)"
    for line in lines:
        if line.strip().startswith("name:"):
            name = line.strip().split(":", 1)[1].strip()
            break
    located = locate_pod_spec(lines, kind_idx, POD_TEMPLATE_KINDS[kind])
    if located is None:
        return []
    pod_idx, pod_indent = located
    out = []
    for s, e in container_blocks(lines, pod_idx, pod_indent):
        text = live("\n".join(lines[s:e]))
        if not is_serve_start(text):
            continue
        cname = re.search(r'name:\s*(\S+)', text)
        cname = cname.group(1) if cname else "(unnamed)"
        out.append((f"{path}:{doc_start + s + 1}", f"{kind} {name}, container {cname}",
                    judge(text)))
    return out


problems = []

# 1. every gateway start, from every manifest file
starts = []
for path in sorted(pathlib.Path("manifests").glob("*.yaml")):
    if path.name == "secrets.example.yaml":
        continue
    docs, doc_lines, doc_start, line_no = [], [], 0, 0
    for line in path.read_text().split("\n"):
        if line.rstrip() == "---":
            docs.append((doc_start, doc_lines))
            doc_lines, doc_start = [], line_no + 1
        else:
            doc_lines.append(line)
        line_no += 1
    docs.append((doc_start, doc_lines))
    for start_no, lines in docs:
        starts.extend(check_document(path, start_no, lines))

if not starts:
    print("FAIL: no gateway start was found under manifests/*.yaml, which is a container")
    print("      running the tokenfuse binary in serve mode. That is not health: the gateway")
    print("      moved, was renamed, or this check no longer knows how to find it. This")
    print("      measured nothing about the agent firewall, and it is not entitled to say OK.")
    sys.exit(1)

for where, what, problem in starts:
    if problem:
        problems.append(f"{where}, {what}: {problem}")

# 2. the one switch's validation
mode = pathlib.Path("firewall/mode.sh")
if not mode.exists():
    problems.append("firewall/mode.sh is missing, so no launcher can validate the switch "
                    "before it installs")
elif not os.access(mode, os.X_OK):
    problems.append("firewall/mode.sh is not executable, and the deploy paths run it directly")
else:
    for good in MODES_ACCEPTED:
        r = subprocess.run(["bash", str(mode), "check", good], capture_output=True, text=True)
        if r.returncode != 0 or r.stdout != "":
            problems.append(f"firewall/mode.sh refuses {good!r}, which the gateway accepts "
                            f"(exit {r.returncode}): {r.stderr.strip()[:120]}")
    for bad in MODES_REFUSED:
        r = subprocess.run(["bash", str(mode), "check", bad], capture_output=True, text=True)
        if r.returncode == 0:
            problems.append(f"firewall/mode.sh accepts {bad!r}, which the gateway ignores "
                            "and falls back to shadow")
        elif r.stdout != "" or r.stderr.strip() == "":
            problems.append(f"firewall/mode.sh refuses {bad!r} without saying why on stderr, "
                            "or printed on stdout")

# 3. every deploy path: takes --firewall, and validates it before its first apply
apply_re = re.compile(r'^[^#]*k_ "apply -k[^"]*manifests"')
check_re = re.compile(r'firewall/mode\.sh"?\s+check\b')
deploy_paths = []
for path in sorted(pathlib.Path(".").rglob("*.sh")):
    if ".git" in path.parts or "scripts" in path.parts:
        continue
    lines = path.read_text().split("\n")
    apply_idx = next((i for i, l in enumerate(lines) if apply_re.match(l)), None)
    if apply_idx is None:
        continue
    deploy_paths.append(path)
    if not re.search(r'^\s*--firewall\)', "\n".join(lines), re.M):
        problems.append(f"{path} applies the manifests but does not parse --firewall")
    check_idx = next((i for i, l in enumerate(lines)
                      if check_re.search(l) and not l.lstrip().startswith("#")), None)
    if check_idx is None or check_idx > apply_idx:
        problems.append(f"{path} never runs firewall/mode.sh check before its first apply, "
                        "so a misspelt mode is found after the install")

if not deploy_paths:
    problems.append("no deploy path applies the manifests, so this measured nothing about "
                    "--firewall, and it is not entitled to say OK")

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print(f"{len(problems)} problem(s) with the agent firewall's switch. See CLAUDE.md invariant 37.")
    sys.exit(1)

print(f"OK: {len(starts)} gateway start(s) in serve mode, each with TOKENFUSE_FIREWALL=enforce; "
      f"firewall/mode.sh accepts {len(MODES_ACCEPTED)} words and refuses {len(MODES_REFUSED)} others; "
      f"{len(deploy_paths)} deploy path(s) take --firewall and check it before their first apply.")
PY
