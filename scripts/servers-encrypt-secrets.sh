#!/usr/bin/env bash
#
# Enforces invariant 48 of CLAUDE.md: every k3s server an installer starts is started
# with --secrets-encryption, and the suite that checks it expects encryption.
#
# WHAT THIS IS ABOUT
#
# k3s does not encrypt Secrets at rest unless a server is started with
# --secrets-encryption, and that is an install-time decision (GOTCHAS 18: a retrofit
# on a running cluster cost the cluster its Secrets). Every installer here passes the
# flag on the first server and on every server that joins. A server started without it
# leaves every Secret it writes as plaintext in etcd, and an etcd snapshot is then the
# whole credential set.
#
# WHAT THIS CHECKS, over every tracked script that installs a k3s server (a line that
# runs `sh -s - server` with INSTALL_K3S_VERSION set, as k3s-token-is-reused.sh finds
# them):
#
#   A. Each `sh -s - server` invocation carries --secrets-encryption on a line of code,
#      between that invocation and the line that feeds it the installer (get.k3s.io).
#      A comment that names the flag does not count.
#   B. security-tests.sh's section 7 still expects encryption: a plaintext canary is a
#      FAIL that names the flag, and a clean canary is the one OK.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no installer, or no server invocation, is
# reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import os, re, subprocess, sys

SERVER_CMD = "sh -s - " + "serv" + "er"  # split so other gates do not read this file as an installer
problems = []
tracked = subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True).stdout.split()
FLAG = re.compile(r"(?<![\w-])--secrets-encryption(?=\s|\\|$)")


def code_lines(path):
    return [(i + 1, l) for i, l in enumerate(open(path).read().split("\n")) if not l.lstrip().startswith("#")]


installers = []
for p in tracked:
    if p.startswith("scripts/") or not os.path.isfile(p):
        continue
    live = "\n".join(l for _, l in code_lines(p))
    if re.search(SERVER_CMD, live) and "INSTALL_K3S_VERSION=" in live:
        installers.append(p)
if not installers:
    print("FAIL: no tracked script installs a k3s server, so this measured NOTHING about secrets at rest.")
    sys.exit(1)

servers = 0
for p in installers:
    lines = code_lines(p)
    for idx, (n, l) in enumerate(lines):
        if not re.search(SERVER_CMD, l):
            continue
        servers += 1
        # The invocation ends at the installer's own line (`< <(curl ... get.k3s.io)`, the
        # old spelling) or at the closing quote of the command string (the stdin
        # spelling, where get.k3s.io opens the pipeline on the first line instead).
        block = []
        for k in range(idx, min(idx + 30, len(lines))):
            block.append(lines[k][1])
            if "< <(curl" in lines[k][1] or lines[k][1].rstrip().endswith('"'):
                break
        if not any(FLAG.search(x) for x in block):
            problems.append(f"{p}:{n}: starts a k3s server without --secrets-encryption, so its Secrets sit in etcd as plaintext (GOTCHAS 18)")

if servers == 0:
    print("FAIL: no k3s server install invocation found, so this measured NOTHING about secrets at rest.")
    sys.exit(1)

s7 = open("security-tests.sh").read() if os.path.isfile("security-tests.sh") else ""
if 'bad "the Secret is plaintext in etcd' not in s7 or "--secrets-encryption" not in s7:
    problems.append("security-tests.sh section 7 no longer reports a plaintext Secret as a failure that names --secrets-encryption")
if 'ok "a freshly written Secret is NOT plaintext in etcd' not in s7:
    problems.append("security-tests.sh section 7 has no OK for a Secret that is not plaintext in etcd")

if problems:
    for p in problems:
        print("FAIL: " + p)
    print()
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 48.")
    sys.exit(1)
print(f"OK: {servers} k3s server invocation(s) in {len(installers)} installer(s) ({', '.join(installers)}) all start with --secrets-encryption,")
print("    and security-tests.sh section 7 expects encryption at rest.")
PY
