#!/usr/bin/env bash
# Enforces CLAUDE.md invariant 28: every gateway container sets the operator's
# ceiling on a run's budget, and the ceiling is a figure the gateway can start on.
#
# WHY
#
# A run's budget used to come from `x-fuse-budget-usd`, the header the AGENT
# sends, and the next call of an open run could widen it. In a deployment with
# no client keys, no identity map and no unit caps, the per-run ceiling was
# whatever the agent declared (tokenfuse v1.5.0 release notes, invariant 73).
# `TOKENFUSE_MAX_RUN_BUDGET_USD` bounds it: a budget that came from the caller
# header, a policy default or the built-in default is lowered to that figure on
# every call. Unset, the gateway has no ceiling and behaves as it did on 1.4.1,
# which is exactly the state a launcher that forgot the variable ships in, with
# nothing reporting it.
#
# The default this repository ships is 5.00, the gateway's own DEFAULT_RUN_BUDGET,
# so an ordinary run is unchanged and only a caller-declared LARGER budget is
# clamped. `@claude 2026-10-04`; see CLAUDE.md invariant 28.
#
# WHAT THIS CHECKS
#
#   1. every container that runs the tokenfuse gateway in serve mode, in ANY
#      manifest (not only the ones kustomization.yaml includes: a gateway added
#      to an opt-in file is still a gateway), carries
#      TOKENFUSE_MAX_RUN_BUDGET_USD as a literal value, and that value is the
#      documented default 5.00. A container is a gateway when it runs the
#      published `tokenfuse` image (never `tokenfuse-control-plane`) with the
#      `tokenfuse` binary and no `args:`; the MCP broker and `focus-export` carry
#      args and are not subjects, the same rule as gateway-cache-is-off.sh;
#   2. no other container carries the variable: the control plane does not read
#      it, and a copy there would read as if the Cloud's own budgets were
#      clamped, which tokenfuse does not do;
#   3. budget/ceiling.sh, the one copy of the validation the three launchers
#      call, accepts the gateway's grammar and refuses what the gateway refuses
#      to start on (zero, a sign, an exponent, a second point, a seventh
#      decimal, a word, an empty figure). Run for real, over each value;
#   4. each deploy path (found by what makes it one: it applies the manifests to
#      a cluster it is talking to) runs `budget/ceiling.sh check` BEFORE its
#      install step, so a figure the gateway would refuse is found in a second
#      and not as a gateway in CrashLoopBackOff after the install. That a path
#      TAKES `--run-budget-ceiling` and applies it AFTER its last `apply -k`,
#      the only place it sticks, is deploy-flags-agree.sh's half, beside the
#      trust domain whose ordering rule it copies.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no gateway container found, or no
# budget/ceiling.sh, is a failure that says it measured nothing.
#
# WHAT IT DOES NOT DO. It runs no cluster and no gateway. That a gateway started
# with the variable clamps a call is tokenfuse's own test, not this repository's.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import pathlib
import re
import subprocess
import sys

CEILING = pathlib.Path("budget/ceiling.sh")
VAR = "TOKENFUSE_MAX_RUN_BUDGET_USD"
DEFAULT = "5.00"

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
    """One (start, end) per entry of containers: under the pod spec. The list
    item indent is read, not assumed: this repository is not perfectly uniform."""
    field_indent = pod_indent + 2
    containers_idx = find_child(lines, pod_idx + 1, block_end(lines, pod_idx, pod_indent),
                                "containers", field_indent)
    if containers_idx is None:
        return []
    c_end = block_end(lines, containers_idx, field_indent)
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
    starts = [j for j in range(containers_idx + 1, c_end)
              if not is_blank_or_comment(lines[j]) and indent_of(lines[j]) == item_indent
              and lines[j].lstrip().startswith("- ")]
    return [(s, starts[i + 1] if i + 1 < len(starts) else c_end) for i, s in enumerate(starts)]


GATEWAY_IMAGE = re.compile(r"image:\s*ghcr\.io/taipanbox/tokenfuse:\S+\s*$", re.M)
COMMAND = re.compile(r'command:\s*\[\s*"([^"]*)"')
VAR_LITERAL = re.compile(r'\{\s*name:\s*' + VAR + r'\s*,\s*value:\s*"?([^",}]*)"?\s*\}')
VAR_BLOCK = re.compile(r"-\s*name:\s*" + VAR + r"\s*\n\s*(?:#.*\n\s*)*value:\s*\"?([^\"\n]*)\"?")
VAR_ANY = re.compile(r"name:\s*" + VAR + r"\b")


def container_name(text):
    m = re.search(r"name:\s*(\S+)", text)
    return m.group(1) if m else "(unnamed)"


def is_gateway(text):
    if not GATEWAY_IMAGE.search(text):
        return False
    m = COMMAND.search(text)
    if not m or m.group(1).rsplit("/", 1)[-1] != "tokenfuse":
        return False
    return re.search(r"^\s*args:", text, re.M) is None


def literal_value(text):
    m = VAR_LITERAL.search(text) or VAR_BLOCK.search(text)
    return m.group(1) if m else None


def documents(path):
    doc, start, n = [], 0, 0
    for line in path.read_text().split("\n"):
        if line.rstrip() == "---":
            if doc:
                yield start, doc
            doc, start = [], n + 1
        else:
            doc.append(line)
        n += 1
    if doc:
        yield start, doc


def pod_containers(fname, first_line, lines):
    kind = kind_idx = None
    for i, line in enumerate(lines):
        if is_blank_or_comment(line):
            continue
        if indent_of(line) == 0 and line.startswith("kind:"):
            kind, kind_idx = line.split(":", 1)[1].strip(), i
            break
    if kind not in POD_TEMPLATE_KINDS:
        return
    name = "(unnamed)"
    for line in lines:
        s = line.strip()
        if s.startswith("name:"):
            name = s.split(":", 1)[1].strip()
            break
    located = locate_pod_spec(lines, kind_idx, POD_TEMPLATE_KINDS[kind])
    if located is None:
        return
    for s, e in container_blocks(lines, *located):
        yield f"{fname}:{first_line + s + 1} {kind} {name}, container {container_name(chr(10).join(lines[s:e]))}", "\n".join(lines[s:e])


problems = []
gateways = 0
manifests = sorted(p for p in pathlib.Path("manifests").glob("*.yaml") if p.name != "secrets.example.yaml")
if not manifests:
    print("FAIL: no manifest under manifests/, so this measured nothing about the run-budget ceiling.")
    sys.exit(1)

for path in manifests:
    for first_line, lines in documents(path):
        for where, text in pod_containers(str(path), first_line, lines):
            if is_gateway(text):
                gateways += 1
                value = literal_value(text)
                if value is None:
                    if VAR_ANY.search(text):
                        problems.append(f"{where}: {VAR} is set, but not as a literal value, so the ceiling is whatever "
                                        "something else says; a ceiling is a figure somebody chose")
                    else:
                        problems.append(f"{where}: no {VAR} env var, so a caller chooses its own per-run budget "
                                        "and the next call of an open run can widen it")
                elif not re.fullmatch(r"[0-9]{1,12}(\.[0-9]{1,6})?", value) or not value.strip("0."):
                    problems.append(f"{where}: {VAR}={value!r} is not a positive decimal with at most six "
                                    "decimals, so the gateway refuses to start")
                elif value != DEFAULT:
                    problems.append(f"{where}: {VAR}={value!r} is not the documented default {DEFAULT}, which "
                                    "equals the gateway's own built-in run budget (CLAUDE.md invariant 28 says why); "
                                    "change the invariant and this gate together, or the ordinary run changes")
            elif VAR_ANY.search(text):
                problems.append(f"{where}: carries {VAR} and is not a gateway container; the control plane and the "
                                "broker do not read it, and a copy there reads as if the Cloud's budgets were clamped, "
                                "which tokenfuse does not do")

if gateways == 0:
    print("FAIL: no container running the tokenfuse gateway in serve mode was found under manifests/.")
    print("      That is not health: the gateway moved, was renamed, or this check no longer knows how to")
    print("      find it. This measured nothing about the run-budget ceiling, and it is not entitled to say OK.")
    sys.exit(1)

# 3. the one copy of the validation, run for real
if not CEILING.exists():
    print(f"FAIL: {CEILING} does not exist, so this measured nothing about the figure a launcher accepts.")
    sys.exit(1)


def ceiling(value):
    return subprocess.run(["bash", str(CEILING), "check", value], capture_output=True, text=True,
                          stdin=subprocess.DEVNULL)


for good in ("5.00", "0.5", "10", "2.123456", "25", "0.000001"):
    r = ceiling(good)
    if r.returncode != 0 or r.stdout != "":
        problems.append(f"budget/ceiling.sh refused {good!r}, which the gateway accepts (exit {r.returncode}): {r.stderr.strip()[:120]}")
for bad in ("0", "0.00", "0.000000", "-1", "+1", "1e9", "1.2.3", "1.1234567", "abc", "", " 5", ".5", "5.", "5 ", "1_000"):
    r = ceiling(bad)
    if r.returncode == 0:
        problems.append(f"budget/ceiling.sh accepted {bad!r}, which the gateway refuses to start on")
    elif r.stderr.strip() == "" or r.stdout != "":
        problems.append(f"budget/ceiling.sh refused {bad!r} without saying why on stderr, or printed on stdout")
r = ceiling("5.00")
if "does NOT lower a budget the Cloud sets" not in r.stderr:
    problems.append("budget/ceiling.sh does not say, when it accepts a figure, that the ceiling does not lower the Cloud's own budget")

# 4. the deploy paths check the figure before they install anything
tracked = subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True).stdout.split()
launchers = [p for p in tracked
             if re.search(r'^[^#]*k_ "apply -k[^"]*manifests"', pathlib.Path(p).read_text(), re.M)]
if not launchers:
    print("FAIL: no deploy path found (nothing applies the manifests with k_ \"apply -k ...\"), so this "
          "measured nothing about whether they check the ceiling before installing.")
    sys.exit(1)
for path in launchers:
    live = [(i + 1, l) for i, l in enumerate(pathlib.Path(path).read_text().splitlines())
            if not l.lstrip().startswith("#")]
    chk = [n for n, l in live if re.search(r'budget/ceiling\.sh"?\s+check\b', l)]
    inst = [n for n, l in live if re.match(r'\s*bash\s+.*install(-gcp|-aws)?\.sh"', l)]
    if not chk:
        problems.append(f"{path} never runs budget/ceiling.sh check, so a figure the gateway refuses is found after the install")
    if not inst:
        problems.append(f"{path}: cannot find its install step, so the order of the ceiling check cannot be judged")
    if chk and inst and min(chk) > min(inst):
        problems.append(f"{path} checks the ceiling at line {min(chk)}, AFTER the install at line {min(inst)}")

if problems:
    for p in problems:
        print(f"FAIL: {p}")
    print()
    print(f"{len(problems)} problem(s) with the run-budget ceiling. See CLAUDE.md invariant 28.")
    sys.exit(1)

print(f"OK: {gateways} gateway container(s), every one sets {VAR}={DEFAULT} as a literal and no other "
      f"container carries it; budget/ceiling.sh accepts the gateway's grammar and refuses what it refuses; "
      f"{len(launchers)} deploy path(s) check the figure before they install.")
PY
