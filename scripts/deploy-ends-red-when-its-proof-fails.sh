#!/usr/bin/env bash
# CLAUDE.md invariant 88: a deploy whose own proof failed ends red.
#
# Until 2026-11-11 each deploy script ran verify.sh and security-tests.sh with
# `|| true`, went on to print "Done." and exited 0, while README.md promises that
# a deploy without --trust-domain "ends red". A pipeline or an operator who looks
# at the exit code of a deploy saw green over a failed check.
#
# The shape that holds it, in each deploy script (found by what makes it one: a
# script that runs both /root/stack-k8s/verify.sh and /root/stack-k8s/security-tests.sh
# on a node):
#
#   - each run keeps its exit code (`... || VERIFY_RC=$?`, `... || SECTEST_RC=$?`),
#     and neither is followed by `|| true` or `|| :`;
#   - the rest of the deploy still runs after a failed proof (the operator needs the
#     way in to fix it), so nothing between the runs and the summary exits;
#   - the summary names which of the two failed, and the headline is not a literal
#     "Done." in the text: it is a variable that says so only when both passed;
#   - after everything is printed the script exits non-zero when either failed.
#
# And it RUNS the two lifted fragments, the summary and the closing check, for every
# combination of exit codes (0/0, 1/0, 0/2, 3/4): green prints "Done." and ends
# clean; each red names exactly the proofs that failed and ends non-zero.
#
# WHAT THIS CANNOT SEE: a deploy script run end to end (that needs a cluster and
# money); a proof that fails in a way its own script reports as exit 0 (that is
# verify.sh's and security-tests.sh's own business, held by their own checks).
#
# EXIT CODES: 0 clean, 1 a fault, 2 this measured nothing (no deploy script found).
#
# DEPENDENCIES: bash, git, python3.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import os
import re
import subprocess
import sys

tracked = subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True, check=True).stdout.split()
VERIFY = re.compile(r"/root/stack-k8s/verify\.sh'")
SECTEST = re.compile(r"/root/stack-k8s/security-tests\.sh'")

subjects = []
for p in tracked:
    if p.startswith("scripts/") or "evidence/" in p or not os.path.isfile(p):
        continue
    text = open(p, encoding="utf-8", errors="replace").read()
    code = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
    if VERIFY.search(code) and SECTEST.search(code):
        subjects.append((p, text.split("\n")))

if not subjects:
    print("deploy-ends-red-when-its-proof-fails: measured NOTHING: no tracked script runs verify.sh and security-tests.sh on a node")
    sys.exit(2)

problems = []
ran = 0
for p, lines in subjects:
    def find(pred):
        return [i for i, l in enumerate(lines) if not l.lstrip().startswith("#") and pred(l)]

    runs_v = find(lambda l: VERIFY.search(l) and re.match(r"\s*(sh_|su_)\s", l))
    runs_s = find(lambda l: SECTEST.search(l) and re.match(r"\s*(sh_|su_)\s", l))
    if len(runs_v) != 1 or len(runs_s) != 1:
        problems.append(f"{p}: expected exactly one run of verify.sh and one of security-tests.sh on a node, found {len(runs_v)} and {len(runs_s)}")
        continue
    rv, rs = runs_v[0], runs_s[0]
    for name, i, var in (("verify.sh", rv, "VERIFY_RC"), ("security-tests.sh", rs, "SECTEST_RC")):
        l = lines[i]
        if re.search(r"\|\|\s*(true|:)\s*$", l):
            problems.append(f"{p}:{i + 1}: {name} is followed by `|| true`: a failed proof is thrown away")
        elif not re.search(r"\|\|\s*" + var + r"=\$\?\s*$", l):
            problems.append(f"{p}:{i + 1}: {name} does not keep its exit code (`|| {var}=$?`)")
        init = find(lambda x, var=var: re.match(r"\s*" + var + r"=0\s*$", x))
        if not init or init[0] > i:
            problems.append(f"{p}: {var} is not set to 0 before {name} runs")

    # the literal headline
    for i, l in enumerate(lines):
        if not l.lstrip().startswith("#") and re.search(r"printf '\\033\[1m'\)Done\.", l):
            problems.append(f"{p}:{i + 1}: prints a literal \"Done.\" headline, whatever the proofs said")

    # the closing check: the LAST `if [ "$VERIFY_RC" -ne 0 ] || [ "$SECTEST_RC" -ne 0 ]; then`
    cond = re.compile(r'^\s*if \[ "\$VERIFY_RC" -ne 0 \] \|\| \[ "\$SECTEST_RC" -ne 0 \]; then\s*$')
    conds = find(lambda l: cond.match(l))
    if len(conds) < 2:
        problems.append(f"{p}: needs the summary condition and the closing condition on VERIFY_RC and SECTEST_RC, found {len(conds)}")
        continue
    calc_i, end_i = conds[0], conds[-1]
    # lift each `if ... fi` (no nesting in either)
    def lift(i):
        for k in range(i, len(lines)):
            if lines[k] == "fi":
                return "\n".join(lines[i:k + 1]), k
        return None, None

    calc, calc_end = lift(calc_i)
    end, end_end = lift(end_i)
    if calc is None or end is None:
        problems.append(f"{p}: a closing `fi` is missing")
        continue
    heredoc = next((i for i, l in enumerate(lines) if "${DONE_HEADLINE}" in l), None)
    if heredoc is None:
        problems.append(f"{p}: the summary never prints ${{DONE_HEADLINE}}")
        continue
    if not (rs > rv and calc_i > rs and heredoc > calc_i and end_i > heredoc):
        problems.append(f"{p}: the proofs, the summary, the text and the closing exit are not in that order (lines {rv + 1}, {calc_i + 1}, {heredoc + 1}, {end_i + 1})")
    between = [i for i in list(range(rs + 1, calc_i)) + list(range(calc_end + 1, heredoc)) if not lines[i].lstrip().startswith("#") and re.search(r"\bexit\b", lines[i])]
    if between:
        problems.append(f"{p}:{between[0] + 1}: exits between the proofs and the summary, so a failed proof skips the way in")
    if not re.search(r"^\s*exit [1-9]\s*$", end, re.M):
        problems.append(f"{p}:{end_i + 1}: the closing check does not exit non-zero")
    hl = next((l for l in lines if l.startswith("DONE_HEADLINE=")), None)
    if hl != 'DONE_HEADLINE="Done."':
        problems.append(f"{p}: the green headline is not set to Done. before the check")

    # run both fragments for every pair of exit codes
    prelude = 'PROOF_FAILED_BLOCK=""\nDONE_HEADLINE="Done."\n'
    for v, s in ((0, 0), (1, 0), (0, 2), (3, 4)):
        script = (f"VERIFY_RC={v}; SECTEST_RC={s}; EXPLAINED=0\n{prelude}{calc}\n"
                  'printf "%s\\n%s\\n" "$DONE_HEADLINE" "$PROOF_FAILED_BLOCK"\n'
                  f"{end}\necho CLOSING-CHECK-PASSED\n")
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        ran += 1
        out = r.stdout
        want_red = v != 0 or s != 0
        if want_red:
            if r.returncode == 0 or "CLOSING-CHECK-PASSED" in out:
                problems.append(f"{p}: with verify exit {v} and security-tests exit {s} the closing check does not end the script non-zero")
            if "Done." in out.split("\n")[0]:
                problems.append(f"{p}: with verify exit {v} and security-tests exit {s} the headline still says Done.")
            for name, code in (("verify.sh", v), ("security-tests.sh", s)):
                named = f"FAILED  {name}" in out
                if code != 0 and not named:
                    problems.append(f"{p}: with {name} exit {code} the summary does not name {name}")
                if code == 0 and named:
                    problems.append(f"{p}: the summary names {name} although it passed")
        else:
            if r.returncode != 0 or "CLOSING-CHECK-PASSED" not in out:
                problems.append(f"{p}: with both proofs green the script does not end clean")
            if out.split("\n")[0] != "Done." or "FAILED" in out:
                problems.append(f"{p}: with both proofs green the summary is not the plain Done.")

if problems:
    for x in problems:
        print("FAIL: " + x)
    print()
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 88.")
    sys.exit(1)
print(f"OK: {len(subjects)} deploy script(s) ({', '.join(p for p, _ in subjects)}) keep both proofs' exit codes, print what failed, and exit non-zero on it ({ran} exit-code combinations run)")
PY
