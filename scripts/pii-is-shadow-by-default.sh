#!/usr/bin/env bash
# The PII scanners run in shadow on every gateway and every MCP broker this launcher
# starts, and one switch changes them. CLAUDE.md invariant 38.
#
# WHY
#
# TokenFuse's personal-data scanners (TOKENFUSE_DLP_PII on the gateway,
# TOKENFUSE_MCP_DLP_PII on the MCP broker) find email addresses, card numbers and
# international phone numbers in prompts and tool arguments. Unset, they are off
# (crates/gateway/src/defaults.rs, dlp_pii_mode_from; crates/gateway/src/main.rs,
# the TOKENFUSE_MCP_DLP_PII match). In shadow they let the call through unchanged
# and report the count and the kinds of what they found, in an x-fuse-dlp header or a log line, never the text. A launcher
# that forgets the variable ships gateways and brokers that look at nothing and say
# nothing about it.
#
# TokenFuse also ignores a misspelt value without a word: any string outside the
# four words falls back to off. So the switch that changes the mode is validated by
# pii/mode.sh before anything is installed, and the literal is checked here.
#
# WHAT THIS CHECKS
#
#   1. every gateway this launcher starts sets TOKENFUSE_DLP_PII exactly once, to the
#      literal shadow
#   2. every MCP broker this launcher starts sets TOKENFUSE_MCP_DLP_PII exactly once,
#      to the literal shadow
#   3. pii/mode.sh is executable, accepts exactly off, shadow, mask and block, and
#      refuses every other word on stderr with exit 1
#   4. every deploy path that applies the manifests takes --pii-mode, and runs
#      pii/mode.sh check before its first apply
#
# SUBJECTS ARE FOUND, NOT LISTED
#
# A gateway start is the definition CLAUDE.md invariant 20 and the agent firewall gate
# use: a container running the published tokenfuse image in serve mode. An MCP broker
# start is a container running the same image with args that name mcp-broker. Every
# manifests/*.yaml is read, not only what kustomization.yaml includes, so an opt-in
# workload that starts either one is judged the day it lands. focus-export (a shell
# sidecar) and tokenfuse-cloud (a different image) are neither, and are not judged.
#
# A gate that finds no gateway start, or no broker start, says so and exits 1. No
# subject is not a pass.
#
# It reads text. That a running gateway or broker reports a finding needs a live
# cluster, which CLAUDE.md invariants 4 and 5 already say this repository cannot hold
# in a gate.
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

MODES_ACCEPTED = ["off", "shadow", "mask", "block"]
MODES_REFUSED = ["", "Shadow", "SHADOW", " shadow", "shadow ", "shadow\n", "shadows",
                 "on", "true", "enabled", "blocks", "masked", "redact", "pii", "mask;"]

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


def args_of(text):
    """The args a container runs with, as a list, or None when it has no args key."""
    lines = text.split("\n")
    for i, line in enumerate(lines):
        flow = re.match(r'^\s*args:\s*\[(.*)\]\s*$', line)
        if flow:
            return [p.strip().strip("\"'") for p in flow.group(1).split(",") if p.strip()]
        if re.match(r'^\s*args:\s*$', line):
            head = indent_of(line)
            out = []
            for nxt in lines[i + 1:]:
                if is_blank_or_comment(nxt):
                    continue
                if indent_of(nxt) <= head:
                    break
                s = nxt.strip()
                if s.startswith("- "):
                    out.append(s[2:].strip().strip("\"'"))
            return out
    return None


def is_broker_start(text):
    if not IMAGE_RE.search(text):
        return False
    return "mcp-broker" in (args_of(text) or [])


def literal_values(text, name):
    """One entry per env var the container declares under `name`: its literal value,
    or None where the entry is not a literal (valueFrom, or no value)."""
    pat = re.escape(name)
    values = []
    for m in re.finditer(r'\{\s*name:\s*' + pat + r'\s*,\s*value:\s*"?([^",}]*?)"?\s*\}', text):
        values.append(m.group(1).strip())
    for m in re.finditer(r'-\s*name:\s*' + pat + r'\s*\n\s*value:\s*"?([^"\n]*?)"?\s*$',
                         text, re.M):
        values.append(m.group(1).strip())
    names = len(re.findall(r'name:\s*' + pat + r'\b', text))
    while len(values) < names:
        values.append(None)
    return values


def judge(text, name):
    vals = literal_values(text, name)
    if not vals:
        return (f"has no {name} env var, so the scanner falls back to its own default, off, "
                "which looks at nothing")
    if len(vals) > 1:
        return f"{name} is set {len(vals)} times, and the later entry wins without a word"
    v = vals[0]
    if v is None:
        return f"{name} is not a literal value, so the launcher cannot say what the scanner will read"
    if v != "shadow":
        return f'{name} is "{v}", not "shadow"'
    return None


def containers_of(path, doc_start, lines):
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
        if is_serve_start(text):
            role = "gateway"
        elif is_broker_start(text):
            role = "broker"
        else:
            continue
        cname = re.search(r'name:\s*(\S+)', text)
        cname = cname.group(1) if cname else "(unnamed)"
        out.append((role, f"{path}:{doc_start + s + 1}", f"{kind} {name}, container {cname}", text))
    return out


problems = []

# 1 and 2. every gateway start and every broker start, from every manifest file
gateways, brokers = [], []
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
        for role, where, what, text in containers_of(path, start_no, lines):
            (gateways if role == "gateway" else brokers).append((where, what, text))

if not gateways:
    print("FAIL: no gateway start was found under manifests/*.yaml, which is a container")
    print("      running the tokenfuse binary in serve mode. That is not health: the gateway")
    print("      moved, was renamed, or this check no longer knows how to find it. This")
    print("      measured nothing about the PII scanners on the gateway, and it is not")
    print("      entitled to say OK.")
    sys.exit(1)

if not brokers:
    print("FAIL: no MCP broker start was found under manifests/*.yaml, which is a container")
    print("      running the tokenfuse binary with args that name mcp-broker. The broker's")
    print("      manifest is 52-tokenfuse-mcp-broker.yaml. This measured nothing about the PII")
    print("      scanners on the broker, and it is not entitled to say OK.")
    sys.exit(1)

for where, what, text in gateways:
    p = judge(text, "TOKENFUSE_DLP_PII")
    if p:
        problems.append(f"{where}, {what}: {p}")

for where, what, text in brokers:
    p = judge(text, "TOKENFUSE_MCP_DLP_PII")
    if p:
        problems.append(f"{where}, {what}: {p}")

# 3. the one switch's validation
mode = pathlib.Path("pii/mode.sh")
if not mode.exists():
    problems.append("pii/mode.sh is missing, so no launcher can validate the switch "
                    "before it installs")
elif not os.access(mode, os.X_OK):
    problems.append("pii/mode.sh is not executable, and the deploy paths run it directly")
else:
    for good in MODES_ACCEPTED:
        r = subprocess.run(["bash", str(mode), "check", good], capture_output=True, text=True)
        if r.returncode != 0 or r.stdout != "":
            problems.append(f"pii/mode.sh refuses {good!r}, which the scanners accept "
                            f"(exit {r.returncode}): {r.stderr.strip()[:120]}")
    for bad in MODES_REFUSED:
        r = subprocess.run(["bash", str(mode), "check", bad], capture_output=True, text=True)
        if r.returncode == 0:
            problems.append(f"pii/mode.sh accepts {bad!r}, which the scanners ignore "
                            "and fall back to off")
        elif r.stdout != "" or r.stderr.strip() == "":
            problems.append(f"pii/mode.sh refuses {bad!r} without saying why on stderr, "
                            "or printed on stdout")

# 4. every deploy path: takes --pii-mode, and validates it before its first apply
apply_re = re.compile(r'^[^#]*k_ "apply -k[^"]*manifests"')
check_re = re.compile(r'pii/mode\.sh"?\s+check\b')
deploy_paths = []
for path in sorted(pathlib.Path(".").rglob("*.sh")):
    if ".git" in path.parts or "scripts" in path.parts:
        continue
    lines = path.read_text().split("\n")
    apply_idx = next((i for i, l in enumerate(lines) if apply_re.match(l)), None)
    if apply_idx is None:
        continue
    deploy_paths.append(path)
    if not re.search(r'^\s*--pii-mode\)', "\n".join(lines), re.M):
        problems.append(f"{path} applies the manifests but does not parse --pii-mode")
    check_idx = next((i for i, l in enumerate(lines)
                      if check_re.search(l) and not l.lstrip().startswith("#")), None)
    if check_idx is None or check_idx > apply_idx:
        problems.append(f"{path} never runs pii/mode.sh check before its first apply, "
                        "so a misspelt mode is found after the install")

if not deploy_paths:
    problems.append("no deploy path applies the manifests, so this measured nothing about "
                    "--pii-mode, and it is not entitled to say OK")

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print(f"{len(problems)} problem(s) with the PII scanners' default and switch. See CLAUDE.md invariant 38.")
    sys.exit(1)

print(f"OK: {len(gateways)} gateway start(s) with TOKENFUSE_DLP_PII=shadow and {len(brokers)} MCP "
      f"broker start(s) with TOKENFUSE_MCP_DLP_PII=shadow; pii/mode.sh accepts {len(MODES_ACCEPTED)} "
      f"words and refuses {len(MODES_REFUSED)} others; {len(deploy_paths)} deploy path(s) take "
      "--pii-mode and check it before their first apply.")
PY
