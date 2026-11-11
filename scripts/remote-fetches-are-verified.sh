#!/usr/bin/env bash
# CLAUDE.md invariant 87: nothing another project publishes is applied or run by the
# installers without its sha256 checked first.
#
# What it holds, in three parts:
#
#  A. No tracked shell script outside scripts/ and the evidence directories applies a
#     remote manifest (`kubectl apply|create|replace|delete -f|-k https://...`), names
#     `get.k3s.io`, or pipes a download into a shell or an ssh session (`curl ... | sh`,
#     `{ ...; curl ...; } | sh_ ...`, `sh -c "$(curl ...)"`). Those are the shapes the
#     installers used until 2026-11-11, and each one ran whatever the host answered.
#
#  B. Every installer (a script that sets INSTALL_K3S_VERSION) sources
#     lib/verified-fetch.sh, fetches the k3s install script through it BEFORE the first
#     `sh -s - server` line, and the default version of every file it fetches that way
#     has a pinned hash in the library (so the default run cannot stop on its own
#     missing pin).
#
#  C. The library behaves: run against a stand-in `curl` that serves a fixture, a file
#     whose hash matches is printed; one whose hash differs prints NOTHING and says the
#     URL, the expected hash and the received one; a version with no pin and no hash
#     given is refused naming the variable; a pinned version is compared against its
#     pinned hash; a failed download prints nothing; and a machine with no hash tool
#     refuses rather than skipping the check.
#
# WHAT THIS CANNOT SEE: a download made by a program other than curl or wget; a fetch
# inside a heredoc that the script writes to a node and runs there; the workflows
# under .github/ (browser-sandbox.yml fetches get.k3s.io for CI, and is not an
# installer); and whether the pinned hashes are the hashes of what the hosts serve
# today, which only a download can say (the hashes were taken on two machines on
# 2026-11-11 and agree).
#
# EXIT CODES: 0 clean, 1 a fault, 2 this measured nothing (no shell script, no
# installer or no library found).
#
# DEPENDENCIES: bash, git, python3, and sha256sum or shasum.
set -euo pipefail

cd "$(dirname "$0")/.."

LIB=lib/verified-fetch.sh
if [ ! -f "$LIB" ]; then
	echo "remote-fetches-are-verified: measured NOTHING: $LIB does not exist, so no fetch can be verified"
	exit 2
fi

python3 - <<'PY'
import os
import re
import subprocess
import sys

LIB = "lib/verified-fetch.sh"
tracked = subprocess.run(["git", "ls-files", "*.sh"], capture_output=True, text=True, check=True).stdout.split()
subjects = [
    p for p in tracked
    if not p.startswith("scripts/") and "/evidence/" not in "/" + p and not p.startswith("evidence/") and os.path.isfile(p)
]
if not subjects:
    print("remote-fetches-are-verified: measured NOTHING: no tracked shell script outside scripts/ and evidence/")
    sys.exit(2)


def logical_lines(path):
    """(first line number, text) of each non-comment line, backslash continuations joined."""
    out, buf, start = [], "", 0
    for n, raw in enumerate(open(path, encoding="utf-8", errors="replace").read().split("\n"), 1):
        if not buf:
            if raw.lstrip().startswith("#"):
                continue
            start = n
        if raw.endswith("\\"):
            buf += raw[:-1] + " "
            continue
        out.append((start, buf + raw))
        buf = ""
    if buf:
        out.append((start, buf))
    return out


KUBE = re.compile(r"""\b(apply|create|replace|delete)\b.*?\s(-f|-k|--filename|--kustomize)[ =]\\?["']?https?://""")
K3S_FLOAT = re.compile(r"get\.k3s\.io")
# A pipeline that carries a download (an address or a variable after curl or wget, so prose
# that says "curl ... | bash" is not one) into a shell or an ssh session; and a shell that is
# handed the text of a download to run. `sh -c 'T=$(curl ...)'`, which only reads a
# metadata token into a variable, is neither.
PIPE_TO_SHELL = re.compile(r"\b(curl|wget)\b[^|]*(https?://|\$\{?[A-Za-z_])[^|]*\|\s*(sudo\s+)?(su_|sh_|ssh|sh|bash|zsh|python3?)\b")
SUBST_TO_SHELL = re.compile(r"""(\b(ba|z)?sh\s+(-[a-z]+\s+)*["']?[$<]\(\s*(curl|wget)\b)|(\b(source|\.)\s+<\(\s*(curl|wget)\b)""")

problems = []
for p in subjects:
    for n, l in logical_lines(p):
        if KUBE.search(l):
            problems.append(f"{p}:{n}: applies a remote manifest by URL, which nothing verifies: {l.strip()[:110]}")
        if K3S_FLOAT.search(l):
            problems.append(f"{p}:{n}: names get.k3s.io, a script that changes under the operator: {l.strip()[:110]}")
        if PIPE_TO_SHELL.search(l) or SUBST_TO_SHELL.search(l):
            problems.append(f"{p}:{n}: runs a download in a shell without checking it: {l.strip()[:110]}")

# ---- B: the installers ----------------------------------------------------
pin_text = open(LIB).read()
installers = []
for p in subjects:
    live = "\n".join(l for _, l in logical_lines(p))
    if "INSTALL_K3S_VERSION=" in live and re.search(r"sh -s - (server|agent)", live):
        installers.append(p)
if not installers:
    print("remote-fetches-are-verified: measured NOTHING: no tracked script installs k3s, so no installer was judged")
    sys.exit(2)

DEFAULTS = (
    ("LONGHORN_VERSION", "LONGHORN_SHA256"),
    ("CALICO_VERSION", "CALICO_SHA256"),
    ("K3S_VERSION", "K3S_INSTALL_SHA256"),
    ("CCM_VERSION", "HCLOUD_CCM_SHA256"),
)
for p in installers:
    lines = logical_lines(p)
    live = "\n".join(l for _, l in lines)
    if not re.search(r"^\s*\.\s+.*lib/verified-fetch\.sh", live, re.M):
        problems.append(f"{p}: does not source lib/verified-fetch.sh")
    first_install = next((n for n, l in lines if re.search(r"sh -s - (server|agent)", l)), None)
    first_fetch = next((n for n, l in lines if re.search(r"\bvf_file\b[^\n]*K3S_INSTALL_SHA256", l)), None)
    if first_fetch is None:
        problems.append(f"{p}: never fetches the k3s install script through vf_file K3S_INSTALL_SHA256")
    elif first_install is not None and first_fetch > first_install:
        problems.append(f"{p}:{first_fetch}: fetches the k3s install script after the first install at line {first_install}")
    for ver_var, sha_var in DEFAULTS:
        if not re.search(r"\b" + sha_var + r"\b", live):
            continue
        m = re.search(ver_var + r'="\$\{' + ver_var + r':-([^}]+)\}"', live)
        if not m:
            problems.append(f"{p}: uses {sha_var} but has no default for {ver_var} to look its pin up by")
            continue
        row = re.search(r"\b" + sha_var + "@" + re.escape(m.group(1)) + r"\)\s+printf '%s' [0-9a-f]{64}\b", pin_text)
        if not row:
            problems.append(f"{p}: the default {ver_var}={m.group(1)} has no row {sha_var}@{m.group(1)} in {LIB}")

if problems:
    for x in problems:
        print("FAIL: " + x)
    print()
    print(f"{len(problems)} problem(s). See CLAUDE.md invariant 87.")
    sys.exit(1)
print(f"OK (A, B): {len(subjects)} shell script(s) fetch nothing unverified; {len(installers)} installer(s) ({', '.join(installers)}) fetch through {LIB}")
PY

# ---- C: the library, run against a stand-in curl -----------------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/nohash"
cat >"$work/bin/curl" <<'STUB'
#!/bin/sh
# stand-in curl: copies $STUB_FIXTURE to the -o file, or fails when STUB_FAIL is set
out=""
while [ $# -gt 0 ]; do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	*) last="$1"; shift ;;
	esac
done
echo "$last" >>"$STUB_LOG"
[ -z "${STUB_FAIL:-}" ] || exit 22
cp "$STUB_FIXTURE" "$out"
STUB
chmod +x "$work/bin/curl"
printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: fixture\n' >"$work/fixture.yaml"

sha_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
good="$(sha_of "$work/fixture.yaml")"
other="$(printf 'x' | { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)"
export STUB_FIXTURE="$work/fixture.yaml" STUB_LOG="$work/curl.log"
: >"$STUB_LOG"
URL="https://example.invalid/longhorn.yaml"
fails=0
note_fail() {
	echo "FAIL: library: $*"
	fails=$((fails + 1))
}

# run <path> <env assignments...> -- <function call>: prints stdout to $work/out, stderr to $work/err, rc
run() {
	local p="$1"
	shift
	env PATH="$p" "$@" "$BASH" -c ". '$PWD/$LIB'; vf_init || exit 9; $CALL; rc=\$?; vf_cleanup; exit \$rc" >"$work/out" 2>"$work/err"
}

CALL="vf_cat LONGHORN_SHA256 'test longhorn' v9.9.9 '$URL'"
if run "$work/bin:$PATH" LONGHORN_SHA256="$good"; then
	cmp -s "$work/out" "$work/fixture.yaml" || note_fail "a file whose hash matches was not printed byte for byte"
else
	note_fail "a file whose hash matches was refused: $(head -3 "$work/err")"
fi

if run "$work/bin:$PATH" LONGHORN_SHA256="$other"; then
	note_fail "a file whose hash does NOT match was accepted"
else
	[ ! -s "$work/out" ] || note_fail "a file whose hash does not match still printed $(wc -c <"$work/out") bytes"
	for want in "$URL" "$other" "$good"; do
		grep -qF "$want" "$work/err" || note_fail "the mismatch message does not name $want"
	done
fi

if run "$work/bin:$PATH"; then
	note_fail "a version with no pinned hash and no hash given was fetched"
else
	[ ! -s "$work/out" ] || note_fail "a version with no pin printed bytes"
	grep -q 'LONGHORN_SHA256' "$work/err" || note_fail "the refusal for an unpinned version does not name LONGHORN_SHA256"
fi

pinned="$(sed -n "s/^[[:space:]]*LONGHORN_SHA256@v1\.7\.2) printf '%s' \([0-9a-f]\{64\}\) ;;/\1/p" "$LIB")"
CALL="vf_cat LONGHORN_SHA256 'test longhorn' v1.7.2 '$URL'"
if run "$work/bin:$PATH"; then
	note_fail "the fixture was accepted as the pinned Longhorn v1.7.2"
else
	[ -n "$pinned" ] && grep -qF "$pinned" "$work/err" || note_fail "a pinned version is not compared against its pinned hash"
fi

CALL="vf_cat LONGHORN_SHA256 'test longhorn' v9.9.9 '$URL'"
if run "$work/bin:$PATH" LONGHORN_SHA256="$good" STUB_FAIL=1; then
	note_fail "a failed download was accepted"
else
	[ ! -s "$work/out" ] || note_fail "a failed download printed bytes"
fi

# no hash tool on the machine: the library must refuse, not skip the check
for t in mktemp cut cat mv rm tr chmod cp; do
	tp="$(command -v "$t" || true)"
	[ -n "$tp" ] && ln -sf "$tp" "$work/nohash/$t"
done
ln -sf "$work/bin/curl" "$work/nohash/curl"
if run "$work/nohash" LONGHORN_SHA256="$good"; then
	note_fail "with no sha256sum or shasum the file was accepted unchecked"
else
	[ ! -s "$work/out" ] || note_fail "with no hash tool bytes were printed"
	grep -q 'no sha256sum or shasum' "$work/err" || note_fail "with no hash tool the refusal does not say so"
fi

if [ "$fails" -gt 0 ]; then
	echo
	echo "$fails problem(s) in $LIB. See CLAUDE.md invariant 87."
	exit 1
fi
echo "OK (C): $LIB prints a verified file, refuses a mismatch, an unpinned version, a failed download and a machine with no hash tool"
