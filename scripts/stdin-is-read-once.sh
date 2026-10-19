#!/usr/bin/env bash
# A command fed on stdin over ssh gets that stdin once, and nothing in its own
# command string reads it first (GOTCHAS 149).
#
# WHY
#
# The installers send the k3s token and the k3s install script on the stdin of
# `... | su_ NODE "sh -c \"IFS= read -r K3S_TOKEN; ... sh -s - agent ...\""`. The
# command string was built with `--node-name '$(node_name_of "$n")'` in it, and
# node_name_of runs its own ssh. Bash runs that substitution while the pipeline is
# being set up, the inner ssh inherits the pipe as its stdin and reads it, and the
# outer ssh then gets nothing: `read` sees no token, `sh -s` sees no script, and
# the agent install exits 0 having installed nothing. Measured on GCP on
# 2026-10-19: two agents never joined, the deploy printed no error, and the
# cluster waited on Longhorn with two of three nodes.
#
# WHAT IT HOLDS, in every installer and deploy script that runs remote commands
#
# 1. A logical line (backslash continuations joined) that pipes into su_, sh_ or
#    ssh has no command substitution after the pipe that runs a remote command:
#    $(node_name_of, $(sh_, $(su_, $(ssh, $(k_ (k_ is kubectl over ssh).
# 2. Every script that joins a k3s agent (`sh -s - agent`) waits for that node to
#    register and stops with "did not register with the cluster" when it does not,
#    so a silent failure of this kind can no longer finish a deploy.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no script, or no stdin-fed remote
# pipeline to judge, and it says it measured nothing and fails.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

python3 - <<'PY'
import glob, re, sys
files = sorted(set(["install.sh", "deploy.sh"] + glob.glob("cloud/*/install-*.sh") + glob.glob("cloud/*/deploy-*.sh")))
files = [f for f in files if __import__("os").path.isfile(f)]
if not files:
    print("stdin-is-read-once: no installer or deploy script found, so this measured nothing"); sys.exit(1)
REMOTE_SUB = re.compile(r"\$\((node_name_of|sh_|su_|ssh|k_)\b")
PIPE_REMOTE = re.compile(r"\|\s*(su_|sh_|ssh)\s")
problems, pipelines, agent_files = [], 0, 0
for f in files:
    raw = open(f).read().split("\n")
    lines, start, buf = [], None, ""
    for i, l in enumerate(raw, 1):
        if start is None:
            start = i
        if l.endswith("\\"):
            buf += l[:-1] + " "
            continue
        lines.append((start, buf + l)); buf, start = "", None
    for n, l in lines:
        if l.lstrip().startswith("#"):
            continue
        m = PIPE_REMOTE.search(l)
        if not m:
            continue
        pipelines += 1
        tail = l[m.end():]
        s = REMOTE_SUB.search(tail)
        if s:
            problems.append(f"{f}:{n}: the command fed on stdin runs $({s.group(1)} ...) in its own command string; that runs an ssh that reads the pipeline's stdin first")
    text = open(f).read()
    # The phrase is assembled so this script is not itself a k3s install to the
    # node-name gate, which finds installs by that text.
    if ("sh -s - " + "agent") in text:
        agent_files += 1
        if "did not register with the cluster" not in text:
            problems.append(f"{f}: joins a k3s agent but never stops when the agent does not register")
if pipelines == 0:
    print("stdin-is-read-once: no stdin-fed remote pipeline in " + ", ".join(files) + ", so this measured nothing"); sys.exit(1)
for p in problems:
    print("stdin-is-read-once: " + p)
if problems:
    print(f"stdin-is-read-once: {len(problems)} problem(s). See GOTCHAS 149."); sys.exit(1)
print(f"OK: {pipelines} stdin-fed remote pipeline(s) in {len(files)} script(s) run no remote command in their own command string; {agent_files} agent-joining script(s) stop when an agent does not register.")
PY
