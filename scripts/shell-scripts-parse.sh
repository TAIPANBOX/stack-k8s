#!/usr/bin/env bash
#
# Enforces invariant 47 of CLAUDE.md: every shell script in this repository parses,
# under the bash the operator has on a Mac and under the bash CI has, and uses no
# construct that only bash 4 accepts.
#
# WHAT THIS IS ABOUT
#
# security-tests.sh had a syntax error at line 650 for as long as it existed, so
# `bash -n` failed and the script never ran sections 10 and later. On 2026-10-14 a
# GCP run found it, and an operator on a Mac found the next problem: macOS still ships
# bash 3.2.57 as /bin/bash, and a construct that bash 4 reads can stop that script
# half way. Nothing in CI ran the scripts under bash 3.2, so nothing said so.
#
# WHAT THIS CHECKS, over every tracked *.sh and every .githooks/* file:
#
#   A. `bash -n` with /bin/bash (on macOS, bash 3.2) parses it.
#   B. `bash -n` with the bash on PATH parses it, when that is a different binary.
#   C. No code line (a comment does not count) uses a bash-4-only construct:
#      declare -A, declare -n, mapfile, readarray, &>>, |&, coproc, or a case-changing
#      expansion such as ${x,,} or ${x^^}.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no tracked shell script is reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

subjects="$(git ls-files '*.sh' '.githooks/*' | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done)"
if [ -z "$subjects" ]; then
  echo "FAIL: no tracked shell script found, so this measured NOTHING about parsing."
  exit 1
fi

problems=0
count=0
ver() { "$1" -c 'printf %s "$BASH_VERSION"' 2>/dev/null; }
sys_bash=/bin/bash
path_bash="$(command -v bash 2>/dev/null || true)"
other=""
if [ -n "$path_bash" ] && [ "$path_bash" != "$sys_bash" ]; then other="$path_bash"; fi

while IFS= read -r f; do
  count=$((count + 1))
  if ! err="$("$sys_bash" -n "$f" 2>&1)"; then
    echo "FAIL: $f does not parse under $sys_bash ($(ver "$sys_bash")): $(printf '%s' "$err" | head -1)"
    problems=$((problems + 1))
  fi
  if [ -n "$other" ]; then
    if ! err="$("$other" -n "$f" 2>&1)"; then
      echo "FAIL: $f does not parse under $other ($(ver "$other")): $(printf '%s' "$err" | head -1)"
      problems=$((problems + 1))
    fi
  fi
  # this gate names the constructs it refuses, so it is not scanned for them
  if [ "$f" = "scripts/shell-scripts-parse.sh" ]; then hits=""; else
  hits="$(awk '
    /^[[:space:]]*#/ { next }
    /(^|[^[:alnum:]_])declare[[:space:]]+-[A-Za-z]*[An][A-Za-z]*([[:space:]]|$)/ ||
    /(^|[^[:alnum:]_])(mapfile|readarray|coproc)([[:space:]]|$)/ ||
    /&>>/ || /\|&/ ||
    /\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)\}/ {
      printf "%d: %s\n", NR, $0
    }' "$f")"
  fi
  if [ -n "$hits" ]; then
    echo "FAIL: $f uses a construct bash 3.2 does not have (bash 4 only):"
    printf '%s\n' "$hits" | head -3 | sed 's/^/      /'
    problems=$((problems + 1))
  fi
done <<EOF
$subjects
EOF

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s) in $count shell script(s). See CLAUDE.md invariant 47."
  exit 1
fi
echo "OK: $count shell script(s) parse under $sys_bash ($(ver "$sys_bash"))${other:+ and under $other ($(ver "$other"))}, and none uses a bash-4-only construct."
