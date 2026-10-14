#!/usr/bin/env bash
#
# Enforces invariant 41 of CLAUDE.md: a secret is minted from a bounded read of
# /dev/urandom, so minting one ends on its own whatever SIGPIPE is set to, and
# the generator that does it is one copy.
#
# WHAT THIS IS ABOUT
#
# `LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c N` reads a stream that
# never ends, and only the pipe head closes stops tr. With SIGPIPE at its
# default, tr dies of it, and under `set -o pipefail` that 141 ends the script
# (GOTCHAS 25, which this repository fixed by turning pipefail off for the one
# pipeline). With SIGPIPE IGNORED, which is how git runs a hook, tr's next
# write just fails: GNU tr then exits and prints "write error: Broken pipe",
# and macOS's tr never exits at all (GOTCHAS 125). The three deploy scripts
# generated the operator password that way until this gate; nothing here runs
# a deploy from a hook, so nothing hung, but the line was one hook away from it.
# Ported from stack-single's scripts/gen-is-bounded.sh (its invariant 31).
#
# WHAT THIS CHECKS
#
#   A. NO UNBOUNDED READ. In every tracked *.sh and .githooks/* (this script
#      and gates-have-teeth.sh aside, which carry the unbounded line as text),
#      outside a comment or a message (a double-quoted string with no $( ) in
#      it), /dev/urandom is only ever the file operand of `head -c <count>`.
#      Not a redirect into tr, not `cat`, not any other reader that would take
#      it to the end of a stream that has none. This half is what holds on a
#      runner whose tr happens to exit.
#   B. THE CONTROL. The unbounded line above is run the way the generators are
#      run below, under ignored SIGPIPE with a time bound: it has to either not
#      end within the bound or write to stderr. If it did neither, this harness
#      is not reproducing the fault and its verdicts on the generators below
#      would mean nothing.
#   C. EVERY GENERATOR, RUN. Every `gen()` defined in those files is lifted and
#      run under `set -euo pipefail` with SIGPIPE ignored and a time bound, for
#      every N any of those files asks it for (`$(gen N)`), several times each.
#      Each run has to end within the bound, exit 0, print exactly N characters
#      of A-Za-z0-9 and nothing on stderr; and no two runs may print the same
#      value. Then once more with a `head` that returns nothing, as an unreadable
#      device would: it has to fail, print nothing on stdout and say why on
#      stderr, because a caller that got an empty password and went on would set
#      an empty password.
#   D. ONE COPY. `gen()` is defined once, in lib/gen.sh, and every file that
#      asks it for a value sources lib/gen.sh on a line above its first ask. A
#      second copy is the drift GOTCHAS 90, 101 and 102 record; a caller that
#      forgot the source dies with "gen: command not found" at the END of a
#      deploy, after the cluster is up.
#
# AND IT REFUSES TO REPORT OK ON NOTHING
#
# No tracked shell file, no file reading /dev/urandom at all, no gen defined,
# no length asked for, or a control that did not reproduce the fault: each is
# reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
python3 - <<'PY'
import os
import re
import signal
import subprocess
import sys

BOUND = 10  # seconds a generator gets; a bounded one ends in milliseconds
CONTROL_BOUND = 3
RUNS = 20
UNBOUNDED = "LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 5"
HOME = "lib/gen.sh"
SELF = ("scripts/gen-is-bounded.sh", "scripts/gates-have-teeth.sh")

problems = []

try:
    tracked = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, text=True, check=True,
    ).stdout.split("\0")
except (subprocess.CalledProcessError, OSError) as exc:
    print(f"FAIL: could not run `git ls-files`: {exc}")
    print("      This measured NOTHING: it finds its subjects by asking git what is tracked.")
    sys.exit(1)

files = sorted(
    f for f in tracked
    if f and (f.endswith(".sh") or f.startswith(".githooks/"))
    and f not in SELF and os.path.isfile(f)
)
if not files:
    print("FAIL: no tracked *.sh or .githooks/* file, so this gate measured NOTHING.")
    sys.exit(1)
texts = {f: open(f, errors="replace").read().split("\n") for f in files}


def code_positions(line):
    """Which characters of a line are shell code rather than text.

    Text is a comment, or the inside of a double-quoted string outside any
    $( ... ) in it: a message such as die "... /dev/urandom is not readable"
    names the file and reads nothing. A single-quoted string counts as code,
    because `bash -c '...'` and `sh_ node '...'` run one. Line by line, which is
    what the scripts here need; a string that spans lines is read as code, the
    strict side.
    """
    code = [True] * len(line)
    stack = ["code"]
    i = 0
    while i < len(line):
        ch = line[i]
        top = stack[-1]
        if ch == "\\":
            if top == "dq":
                code[i] = code[min(i + 1, len(line) - 1)] = False
            i += 2
            continue
        if top == "dq":
            if ch == '"':
                stack.pop()
            elif line.startswith("$(", i):
                stack.append("subst")
                i += 2
                continue
            else:
                code[i] = False
            i += 1
            continue
        if ch == "#" and (i == 0 or line[i - 1] in " \t;"):
            for j in range(i, len(line)):
                code[j] = False
            break
        if ch == "'":
            j = line.find("'", i + 1)
            i = len(line) if j < 0 else j + 1
            continue
        if ch == '"':
            stack.append("dq")
        elif line.startswith("$(", i):
            stack.append("subst")
            i += 2
            continue
        elif ch == ")" and top == "subst":
            stack.pop()
        i += 1
    return code


# A. Every read of /dev/urandom in code is `head -c <count> /dev/urandom`.
reads = 0
for f, lines in texts.items():
    for n, line in enumerate(lines, 1):
        if "/dev/urandom" not in line:
            continue
        code = code_positions(line)
        for m in re.finditer(r"/dev/urandom", line):
            if not code[m.start()]:
                continue
            reads += 1
            before = line[: m.start()]
            if not re.search(r"\bhead\s+-c\s*\S+\s+$", before):
                problems.append(
                    f"{f}:{n}: reads /dev/urandom with no bound, not as `head -c <count> /dev/urandom`:\n"
                    f"      {line.strip()}\n"
                    f"      with SIGPIPE ignored (as under a git hook) the reader never reaches an end"
                )

if reads == 0:
    problems.append(
        "no tracked shell file reads /dev/urandom in code, so the bounded-read half of this\n"
        "      gate measured NOTHING"
    )


def run(script, bound):
    """Run bash on script with SIGPIPE ignored, as git runs a hook.

    Python itself ignores SIGPIPE, and restore_signals=False lets the child
    inherit that. A new session so the whole group, tr included, can be killed
    when the bound is hit: killing bash alone would leave tr reading forever.
    """
    p = subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        restore_signals=False,
        start_new_session=True,
    )
    try:
        out, err = p.communicate(timeout=bound)
        return p.returncode, out.decode(errors="replace"), err.decode(errors="replace"), False
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.communicate()
        return None, "", "", True


# B. The control: the unbounded line, run the same way, does not end cleanly.
rc, out, err, timed_out = run("set -euo pipefail\n" + UNBOUNDED, CONTROL_BOUND)
if not timed_out and not err.strip():
    print("FAIL: the control, the unbounded generator run with SIGPIPE ignored, ended within")
    print(f"      {CONTROL_BOUND} s and wrote nothing to stderr (exit {rc}), so this harness is not")
    print("      reproducing the fault and measured NOTHING about the generators.")
    sys.exit(1)
control = f"did not end within {CONTROL_BOUND} s" if timed_out else f"wrote to stderr: {err.strip().splitlines()[0]}"


# C and D. Every gen() defined in those files, and every ask for one.
def lift_gen(f, lines):
    """Each gen() definition in code: a one-liner, or the lines up to its closing brace."""
    found = []
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)(?:function\s+)?gen\s*\(\)\s*\{", line)
        if not m:
            continue
        if re.search(r"\}\s*$", line[m.end():]):
            found.append((i + 1, line.strip()))
            continue
        indent = m.group(1)
        for j in range(i + 1, len(lines)):
            if re.match(r"^" + re.escape(indent) + r"\}\s*$", lines[j]):
                found.append((i + 1, "\n".join(l[len(indent):] for l in lines[i : j + 1])))
                break
        else:
            problems.append(f"{f}:{i + 1}: a gen() with no closing brace at its own indent, so it cannot be lifted")
    return found


gens = []
for f, lines in texts.items():
    for n, body in lift_gen(f, lines):
        gens.append((f, n, body))

ASK = re.compile(r"\$\(\s*gen\s+([0-9]+)\s*\)")
SOURCE = re.compile(r"(?:^|[;&|({]|\s)(?P<verb>\.|source)\s+\"?[^\s\"]*lib/gen\.sh\"?")
asks = {}  # file -> [(line, N)]
sources = {}  # file -> first line that sources lib/gen.sh
for f, lines in texts.items():
    for n, line in enumerate(lines, 1):
        code = code_positions(line)
        for m in ASK.finditer(line):
            if code[m.start()]:
                asks.setdefault(f, []).append((n, int(m.group(1))))
        for m in SOURCE.finditer(line):
            if code[m.start("verb")] and f not in sources:
                sources[f] = n

if not any(f == HOME for f, _, _ in gens):
    problems.append(
        f"{HOME} defines no gen(), so there is no secret generator to run and this gate\n"
        "      measured NOTHING about one"
    )
for f, n, _ in gens:
    if f != HOME:
        problems.append(
            f"{f}:{n}: a second gen() outside {HOME}. One copy, sourced: a block copied into\n"
            "      several scripts drifts (GOTCHAS 90, 101, 102)"
        )

lengths = sorted({length for found in asks.values() for _, length in found})
if not lengths:
    problems.append(
        "no tracked shell file asks gen for a value of a given length (no \"$(gen N)\"), so this\n"
        "      gate measured NOTHING: there is no length to run the generator for"
    )
for f, found in sorted(asks.items()):
    if f == HOME:
        continue
    first = found[0][0]
    if f not in sources:
        problems.append(
            f"{f}:{first}: asks gen for a value and never sources {HOME}, so the deploy would end\n"
            "      there with `gen: command not found`"
        )
    elif sources[f] > first:
        problems.append(
            f"{f}:{first}: asks gen for a value above the line that sources {HOME} ({sources[f]})"
        )

runs = 0
for f, n, body in gens:
    where = f"{f}:{n}"
    seen = {}
    stop = False
    for length in lengths:
        for k in range(RUNS):
            script = (
                "set -euo pipefail\n"
                "die() { printf 'die: %s\\n' \"$*\" >&2; exit 1; }\n"
                + body + "\n"
                + f"gen {length}\n"
            )
            rc, out, err, timed_out = run(script, BOUND)
            runs += 1
            if timed_out:
                problems.append(f"{where}: gen {length} did not end within {BOUND} s with SIGPIPE ignored")
                stop = True
                break
            if rc != 0:
                problems.append(f"{where}: gen {length} exited {rc} with SIGPIPE ignored: {err.strip()[:200]}")
                stop = True
                break
            if err.strip():
                problems.append(f"{where}: gen {length} wrote to stderr with SIGPIPE ignored: {err.strip()[:200]}")
                stop = True
                break
            if not re.fullmatch(r"[A-Za-z0-9]{%d}" % length, out):
                problems.append(
                    f"{where}: gen {length} printed {len(out)} character(s) that are not exactly {length} of A-Za-z0-9: {out[:80]!r}"
                )
                stop = True
                break
            if out in seen:
                problems.append(f"{where}: gen {length} printed the same value twice, which is not a secret")
                stop = True
                break
            seen[out] = True
        if stop:
            break
    if stop or not lengths:
        continue
    script = (
        "set -euo pipefail\n"
        "head() { :; }\n"
        + body + "\n"
        + f"gen {lengths[0]}\n"
    )
    rc, out, err, timed_out = run(script, BOUND)
    runs += 1
    if timed_out or rc == 0 or out or not err.strip():
        problems.append(
            f"{where}: gen {lengths[0]} with nothing to read (a head that returns nothing) "
            f"{'did not end' if timed_out else f'exited {rc}, printed {out[:40]!r} and said {err.strip()[:80]!r}'}; "
            "it has to fail, print nothing and say why"
        )

if problems:
    for p in problems:
        print("FAIL: " + p)
    print()
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 41.")
    sys.exit(1)

names = ", ".join(f"{f}:{n}" for f, n, _ in gens)
callers = ", ".join(sorted(f for f in asks if f != HOME))
print(f"OK: {reads} read(s) of /dev/urandom in {len(files)} tracked shell file(s), each bounded by head -c;")
print(f"    one generator ({names}), sourced by {callers} before each asks;")
print(f"    run {runs} times with SIGPIPE ignored for N in {lengths}, each ended at once with N fresh")
print(f"    characters, and refused when there was nothing to read; the unbounded control {control}.")
PY
