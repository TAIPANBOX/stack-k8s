#!/usr/bin/env bash
# Every k3s install decides the node's name explicitly. None of them lets k3s
# derive it from whatever `hostname` returns at that moment.
#
# The failure this refuses is one machine registered twice. k3s defaults the
# node name to the host name, and that value is not reliably stable across a
# stop and start. On 2026-08-27 a GCP node that had registered as
# stack-k8s-server-1.europe-west3-a.c.PROJECT.internal came back from a
# stop/start as plain stack-k8s-server-1: a NEW node object, while the old one
# sat NotReady for the rest of the cluster's life still holding 17 pod records
# that nothing ever cleaned up. The cluster reported itself healthy throughout.
# See cloud/gcp/evidence/range-2026-08-27/FINDINGS.md, F3.
#
# The same file records that a controlled reboot did NOT reproduce it, so this
# gate is not holding a proven cause. It holds the property that makes the cause
# irrelevant: a name we chose cannot be re-chosen by a boot.
#
# The subjects are FOUND, not listed. A hand-written list of installers is
# itself unchecked, and the fourth cloud would be added without it.
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }

# Find every k3s install invocation, joining the continuation lines so a flag
# three lines below the command still counts as part of it. Comment lines are
# dropped first: prose about `sh -s - server` is not an install, and a gate that
# reads a comment as code has been wrong here twice before.
found="$(
  find . -name '*.sh' -not -path './.git/*' -print0 \
  | xargs -0 awk '
      function emit() {
        printf "%s:%d:%s\n", FILENAME, start, (buf ~ /--node-name/ ? "pinned" : "DERIVED")
        buf = ""; collecting = 0
      }
      {
        code = $0
        sub(/^[ \t]*#.*$/, "", code)
        if (collecting) {
          buf = buf " " code
          if ($0 !~ /\\[ \t]*$/) emit()
          next
        }
        if (code ~ /sh -s - (server|agent)/) {
          buf = code; start = FNR; collecting = 1
          if ($0 !~ /\\[ \t]*$/) emit()
        }
      }
      END { if (collecting) emit() }
    '
)"

count="$(printf '%s\n' "$found" | grep -c . || true)"

while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  case "$hit" in
    *:DERIVED)
      bad "${hit%:DERIVED} installs k3s without --node-name: the node's identity is whatever hostname returns at boot" ;;
  esac
done <<< "$found"

# Zero is not a pass. If the installers are renamed, moved out of *.sh, or the
# install stops going through `sh -s -`, this check stops having a subject and
# has to be told so rather than reporting a clean tree.
if [ "$count" = 0 ]; then
  echo "FAIL: found no k3s install invocation to check, so this measured nothing."
  echo "      It cannot tell whether node names are pinned if it cannot find an"
  echo "      install. If the installers moved or changed shape, this check has"
  echo "      to move with them; silence here is not health."
  exit 1
fi

if [ "$fail" = 0 ]; then
  echo "OK: $count k3s install invocation(s), every one pins --node-name."
else
  echo "$fail k3s install invocation(s) leave the node name to the boot."
fi
exit "$fail"
