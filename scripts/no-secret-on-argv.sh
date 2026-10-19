#!/usr/bin/env bash
# Enforces: no secret VALUE appears on a command line in a tracked shell script
# (CLAUDE.md invariant 60). A secret goes in on stdin, or in a file the reader
# opens, never as an argument to a process.
#
# WHY
#
# An argument is readable in the process table of both ends of an ssh: the
# local `ssh` argv and the remote shell's argv, for as long as the command runs,
# and by every user on the remote box. The cloud installers built
# `kubectl create secret ... --from-literal=password='$PW'` inside an ssh command
# string, so every plane credential sat there (findings F-015). The same was true
# of the Hetzner token, the k3s cluster token, the console bearer and a token
# inside a git clone URL. The fix is the same everywhere: the value is written
# to stdin (a Secret manifest built by secret_doc in lib/secret-doc.sh, or a
# first line read by the far shell), and a header is read from stdin with
# `curl --config -`.
#
# WHAT IT CHECKS, LINE BY LINE, IN EVERY TRACKED *.sh OUTSIDE scripts/
#
#   R1  --from-literal=KEY=VALUE where KEY is not a known non-secret, and either
#       VALUE expands a shell variable or KEY names a secret (token, secret,
#       password, key, dsn, pw, admin, credential, approval).
#   R2  an Authorization bearer whose value is a shell expansion: "Bearer $X".
#   R3  a URL whose authority is an expansion, or carries one before an @:
#       https://${AUTH}github.com, https://user:$TOKEN@host.
#   R4  an environment assignment of a secret name to an expansion in a command
#       string: K3S_TOKEN='$X', HCLOUD_TOKEN="$X", CLOSURE_SECRET=$X.
#   R5  `patch secret` with an inline payload (-p) that expands a variable.
#   R6  a password on argv: --password $X, pass:$X, -u user:$X.
#   R8  a secret given as a flag value: --token "$X", --password=$X.
#   R7  an `sh -c "..."` string that expands a secret name, which puts the value
#       in the argv of the shell it starts.
#
# An unescaped `$` is what makes a value. `\$` is a literal dollar, written for
# an operator to read or run later, and is not a secret on this machine.
#
# WHAT IS EXEMPT, AND WHY
#
#   Comment-only lines. Non-secret --from-literal keys: issuer, audience,
#   trusted_issuers (identifiers, not credentials) and probe (the canary value
#   security-tests.sh plants to check a read path, not a credential). scripts/
#   is not scanned: its planted faults are text, not commands that run.
#
# SUBJECTS ARE FOUND, NOT LISTED. Every tracked *.sh outside scripts/. If that
# set is empty, this says it measured nothing and fails.
set -uo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re
import subprocess
import sys

NON_SECRET_KEYS = {"issuer", "audience", "trusted_issuers", "probe"}
SECRET_NAME = re.compile(r"(?i)(token|secret|password|passwd|pass|pw|key|dsn|admin|credential|approval)")
UNESCAPED = r"(?<!\\)\$"

RULES = [
    ("R2", re.compile(r"(?i)bearer[ \t]+[^\s\"']*" + UNESCAPED),
     "a bearer whose value is a shell expansion (use `curl --config -` and read the header from stdin)"),
    ("R3", re.compile(r"[a-z]+://" + UNESCAPED + r"\{?[A-Za-z_]*(AUTH|TOKEN|SECRET|PASS|CRED)"
                      r"|[a-z]+://[^\s/@]*:" + UNESCAPED + r"\{?[A-Za-z_]*(TOKEN|SECRET|PASS|PW|KEY|CRED|AUTH)[^\s/@]*@"
                      r"|x-access-token:" + UNESCAPED),
     "a URL that carries a credential: the authority or the user info is an expansion of a secret"),
    ("R4", re.compile(r"\b[A-Z0-9_]*(TOKEN|SECRET|PASSWORD|KEY|KEYS|PW|REVOKE)=[\"']?" + UNESCAPED),
     "a secret value assigned on a command line (send it on stdin, then `read -r` it)"),
    ("R5", re.compile(r"patch[ \t]+secret\b[^|]*[ \t]-p[ \t=][^|]*" + UNESCAPED),
     "`patch secret -p` with an expanded payload (use --patch-file /dev/stdin)"),
    ("R6", re.compile(r"(?i)(--password[= ][\"']?" + UNESCAPED + r"|pass(word)?:" + UNESCAPED
                      + r"|-u[ \t]+[^\s]*:" + UNESCAPED + r")"),
     "a password on argv"),
    ("R8", re.compile(r"(?i)--(token|password|secret|hcloud-token|console-token|revoke-key|api-key)[= ]\"?" + UNESCAPED),
     "a secret passed as the value of a command-line flag (pass it in the environment, or on stdin)"),
    ("R7", re.compile(r"sh -c \"[^\"]*" + UNESCAPED + r"\{?[A-Z_]*(SECRET|TOKEN|KEY|PW|PASSWORD)"),
     "an sh -c string that expands a secret name (its value becomes the argv of that shell)"),
]

# A bare `NAME=value` in shell is a local variable and reaches no argv. The
# assignment is a leak only as the prefix of a command, or inside the string a
# remote shell runs: ssh, sh_, su_, k_, env, sh -c, docker, kubectl, sudo.
COMMAND_CONTEXT = re.compile(r"(?<![-\w.])(ssh|sh_|su_|k_|k|env|sudo|docker|kubectl|sh -c|bash -c)(?![-\w])")
SECRET_DOC = re.compile(r"(^|[|;&(]\s*)secret_doc\s")
FROM_LITERAL = re.compile(r"--from-literal[= ][\"']?([A-Za-z0-9_.-]+)=([^\s\"'\\]*)")

files = [f for f in subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True)
         .stdout.split() if not f.startswith("scripts/")]
if not files:
    print("FAIL: no tracked shell script outside scripts/, so this measured NOTHING.")
    sys.exit(1)

def logical_lines(path):
    """Yield (first_line_number, text) with backslash continuations joined, so a
    command split over several lines is judged as one command."""
    start, parts = None, []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if start is None:
                if line.lstrip().startswith("#"):
                    continue
                start = n
            parts.append(line[:-1] if line.endswith("\\") else line)
            if line.endswith("\\"):
                continue
            yield start, " ".join(p.strip() for p in parts)
            start, parts = None, []
    if parts:
        yield start, " ".join(p.strip() for p in parts)

problems = []
lines_seen = 0
for path in files:
    for n, line in logical_lines(path):
        lines_seen += 1
        for m in FROM_LITERAL.finditer(line):
            key, value = m.group(1), m.group(2)
            if key in NON_SECRET_KEYS:
                continue
            if "$" in value or SECRET_NAME.search(key):
                problems.append((path, n, "R1", f"--from-literal={key}=... puts a secret value on argv"))
        # secret_doc is a shell function: its arguments reach no process (it pipes
        # the base64 of each value on a builtin's stdin). Its lines are exempt from
        # the rules that judge what a process is given; R1, R4 and R5 still apply.
        in_function = SECRET_DOC.search(line) is not None
        for rule, pattern, why in RULES:
            m = pattern.search(line)
            if not m:
                continue
            if in_function and rule in ("R2", "R3", "R6", "R7"):
                continue
            if rule == "R4":
                # NAME=value is a command prefix only when a command word comes
                # before it on the line; `--token) NAME="$2"` is a shell variable.
                if not COMMAND_CONTEXT.search(line[:m.start()]):
                    continue
            problems.append((path, n, rule, why))

if lines_seen == 0:
    print("FAIL: the scanned files have no command lines, so this measured NOTHING.")
    sys.exit(1)

for path, n, rule, why in problems:
    print(f"FAIL {rule} {path}:{n}: {why}")
if problems:
    print(f"\n{len(problems)} secret(s) on a command line, in {len(files)} shell script(s).")
    sys.exit(1)
print(f"OK: {len(files)} shell script(s), {lines_seen} command line(s), no secret value on argv.")
PY
