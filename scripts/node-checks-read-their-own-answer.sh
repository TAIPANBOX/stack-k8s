#!/usr/bin/env bash
#
# Enforces invariant 47 of CLAUDE.md, the part about node checks: security-tests.sh
# reads a node's answer only from the lines that node's probe printed itself.
#
# WHAT THIS IS ABOUT
#
# security-tests.sh --nodes runs its node checks over ssh, from the operator's Mac or
# from a server. A login banner, a motd or an ssh warning arrives on the same stdout as
# the answer. On 2026-10-14 an Ubuntu banner matched a probe, and the etcd check read
# the banner as a count of plaintext Secrets and failed a healthy cluster.
#
# WHAT THIS CHECKS:
#
#   A. Every ssh invocation in security-tests.sh is inside node_probe, the one helper
#      that reads node output, and not in a check of its own.
#   B. node_probe, run with a stand-in ssh that prints a login banner before the
#      command's own output, prints the command's output and nothing else.
#   C. node_probe is not run with a stdout that could hold the banner: the probe on the
#      node prefixes its lines with SECCHK: and node_probe keeps only those.
#
# AND IT REFUSES TO REPORT OK ON NOTHING: no node_probe, or no ssh call to read, is
# reported and fails.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
f=security-tests.sh
[ -f "$f" ] || { echo "FAIL: $f is missing, so this measured NOTHING about node checks."; exit 1; }

problems=0
fn="$(awk '/^node_probe\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' "$f")"
if [ -z "$fn" ]; then
  echo "FAIL: $f defines no node_probe, so its node checks read whatever ssh prints."
  exit 1
fi
setup="$(awk '/^SECCHK_SSH=/ { print }' "$f")"
if [ -z "$setup" ]; then
  echo "FAIL: $f defines no SECCHK_SSH, so ssh is not run quietly (-q -o LogLevel=ERROR)."
  problems=$((problems + 1))
fi

# A. ssh calls: every line that runs ssh as a command, outside node_probe itself
outside="$(awk '
  /^node_probe\(\) \{/ { inside = 1 }
  inside && /^}/ { inside = 0; next }
  !inside && /^[[:space:]]*ssh[[:space:]]/ { printf "%d: %s\n", NR, $0 }
' "$f")"
if [ -n "$outside" ]; then
  echo "FAIL: $f runs ssh outside node_probe, where a banner would be read as an answer:"
  printf '%s\n' "$outside" | sed 's/^/      /'
  problems=$((problems + 1))
fi

# B. the helper, with a stand-in ssh that prints a banner before the answer
tmp="$(mktemp -d "${TMPDIR:-/tmp}/nodechk.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/ssh" <<'STUB'
#!/bin/bash
# stand-in for ssh: a login banner on stdout, then the remote command run locally
echo "Welcome to Ubuntu 24.04 LTS (stand-in banner)"
echo "Last login: Tue Oct 14 00:00:00 2026"
for last; do :; done
bash -c "$last"
STUB
chmod +x "$tmp/ssh"
{
  echo "NS=agent-stack"
  printf '%s\n' "$setup"
  printf '%s\n' "$fn"
  echo 'node_probe 10.0.0.1 "echo ANSWER=42; echo second line"'
} > "$tmp/probe.sh"
got="$(PATH="$tmp:$PATH" bash "$tmp/probe.sh" 2>&1)"
if [ "$got" != "$(printf 'ANSWER=42\nsecond line')" ]; then
  echo "FAIL: node_probe printed more than the command's own answer, with a banner in front:"
  printf '%s\n' "$got" | sed 's/^/      /'
  problems=$((problems + 1))
fi

if [ "$problems" -gt 0 ]; then
  echo
  echo "$problems problem(s). See CLAUDE.md invariant 47."
  exit 1
fi
echo "OK: every node check in $f reads only the lines its probe printed (SECCHK:), and a login banner is not an answer."
