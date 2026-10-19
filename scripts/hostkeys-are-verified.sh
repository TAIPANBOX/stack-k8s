#!/usr/bin/env bash
# Enforces: the cloud installers take each node's SSH host keys from outside the
# network before the first connection, and connect strictly against them; a key
# that does not match is refused; a missing key times out with a reason; and
# SSH_KNOWN_HOSTS switches install.sh to strict (CLAUDE.md invariant 61).
#
# WHY
#
# The first connection to a fresh node was accepted on trust (accept-new), and a
# recycled address could hand a new machine's key to a host the operator had
# never pinned. GOTCHAS 139 is the trap that made ssh refuse a rebuilt cluster,
# and the reason the scripts forget old keys; forgetting is not verifying.
#
# WHAT IT RUNS
#
# lib/hostkeys.sh with `aws`, `gcloud`, `ssh-keyscan` and `ssh` replaced on PATH
# by stubs that answer from files this script writes. The stubs make the cloud
# look like the cloud: the console block, the guest attributes and the keyscan
# are fixtures, and the ssh stub refuses a host whose presented key is not in the
# UserKnownHostsFile it was given under StrictHostKeyChecking=yes, which is what
# OpenSSH does. Real ssh-keygen parses the keys, so the fingerprints are real.
#
#   A  AWS, the console fingerprints match the keyscan: accepted, written, and a
#      strict connection to that node succeeds.
#   B  AWS, a different key: refused at once, nothing written, and the strict
#      connection is refused too.
#   C  AWS, no console block: refused at the deadline with the reason named.
#   D  AWS, the console answers base64: decoded, and A holds.
#   E  GCE, the guest attributes carry the keys: written, and a strict connection
#      succeeds.
#   F  GCE, no guest attributes: refused at the deadline with the reason named.
#   G  install.sh: with SSH_KNOWN_HOSTS its first ssh is strict against that file;
#      without it, accept-new, and the accepted key is printed with how to pin it.
#   H  The cloud installers and deploy scripts: no accept-new left, and each takes
#      its keys before the first connection that uses SSH_OPTS.
#
# It refuses to report OK when a case cannot run (no lib, no stub target, no
# install.sh), because a skipped case is not a passing one.
set -uo pipefail
cd "$(dirname "$0")/.."

for f in lib/hostkeys.sh install.sh cloud/aws/install-aws.sh cloud/gcp/install-gcp.sh \
         cloud/aws/deploy-aws.sh cloud/gcp/deploy-gcp.sh; do
  if [ ! -f "$f" ]; then
    printf 'FAIL: %s is missing, so this measured NOTHING about host keys.\n' "$f"
    exit 1
  fi
done

T="$(mktemp -d "${TMPDIR:-/tmp}/hostkeys-gate.XXXXXX")" || { echo "FAIL: no scratch directory"; exit 1; }
mkdir -p "$T/bin" "$T/keys"
fails=0
pass() { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# ---- fixtures: two real keys, one the cloud has, one the attacker presents ----
ssh-keygen -q -t ed25519 -N "" -f "$T/keys/k1" -C "node-one" >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N "" -f "$T/keys/k2" -C "impostor" >/dev/null 2>&1
IP=203.0.113.10
line_of() { printf '%s %s\n' "$IP" "$(cut -d' ' -f1,2 "$1.pub")"; }   # "IP type base64"
K1_LINE="$(line_of "$T/keys/k1")"
K2_LINE="$(line_of "$T/keys/k2")"
fp_of() { ssh-keygen -lf "$1.pub" | awk '{print $2}'; }
K1_FP="$(fp_of "$T/keys/k1")"
block_for() { # fingerprints printed to the console, as cloud-init prints them
  printf -- '-----BEGIN SSH HOST KEY FINGERPRINTS-----\n256 %s root@node-one (ED25519)\n-----END SSH HOST KEY FINGERPRINTS-----\n' "$1"
}
: > "$T/console"; : > "$T/scan"; : > "$T/guest"; : > "$T/present"

# ---- the stubs ----------------------------------------------------------------
cat > "$T/bin/aws" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *get-console-output*) cat "$T/console" ;;
  *describe-instances*) echo "i-0123456789abcdef0" ;;
  *) : ;;
esac
STUB
cat > "$T/bin/gcloud" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"instances list"*) echo "node-one europe-west3-a" ;;
  *get-guest-attributes*) cat "$T/guest" ;;
  *) : ;;
esac
STUB
cat > "$T/bin/ssh-keyscan" <<STUB
#!/usr/bin/env bash
cat "$T/scan"
STUB
# The stub ssh: under StrictHostKeyChecking=yes it refuses a host whose presented key is
# not in the UserKnownHostsFile; under accept-new it connects and records the call.
cat > "$T/bin/ssh" <<STUB
#!/usr/bin/env bash
echo "ssh \$*" >> "$T/ssh.log"
strict=0; kh=""; host=""
for a in "\$@"; do
  case "\$a" in
    StrictHostKeyChecking=yes) strict=1 ;;
    UserKnownHostsFile=*) kh="\${a#UserKnownHostsFile=}" ;;
    *@*) host="\${a#*@}" ;;
  esac
done
if [ "\$strict" = 1 ]; then
  # OpenSSH under StrictHostKeyChecking=yes: the key the host presents must be one the
  # UserKnownHostsFile holds for it. The presented key is the fixture in $T/present.
  if grep -qF -f "$T/present" "\${kh:-/dev/null}" 2>/dev/null; then exit 0; fi
  echo "Host key verification failed." >&2
  exit 255
fi
exit 0
STUB
chmod +x "$T/bin/"*

# Run the helpers in a subshell with the stubs first on PATH.
# The timing variables are exported BEFORE the file is sourced: `VAR=x . file` does not
# keep VAR for the functions the file defines, and the deadline then silently stays 300 s.
helper() { ( export PATH="$T/bin:$PATH" HOSTKEY_DEADLINE="${DEADLINE:-3}" HOSTKEY_POLL=1; . lib/hostkeys.sh && "$@" ); }
strict_ssh() { PATH="$T/bin:$PATH" ssh -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$1" -o BatchMode=yes "root@$IP" true; }

# ---- A: AWS, matching ---------------------------------------------------------
printf '%s\n' "$K1_LINE" > "$T/scan"; block_for "$K1_FP" > "$T/console"; printf '%s\n' "$K1_LINE" > "$T/present"
: > "$T/kh-a"
helper hostkeys_aws i-0123 "$IP" "$T/kh-a" >"$T/out-a" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -qF "$K1_LINE" "$T/kh-a"; then pass "A  AWS keys that match the console are written"; else bad "A  AWS matching keys: rc=$rc, $(cat "$T/out-a")"; fi
strict_ssh "$T/kh-a" >/dev/null 2>&1 && pass "A  a strict connection to that node succeeds" || bad "A  a strict connection to the matching node was refused"

# ---- B: AWS, a different key ------------------------------------------------------
printf '%s\n' "$K2_LINE" > "$T/scan"; printf '%s\n' "$K2_LINE" > "$T/present"
: > "$T/kh-b"
helper hostkeys_aws i-0123 "$IP" "$T/kh-b" >"$T/out-b" 2>&1; rc=$?
if [ "$rc" = 2 ] && [ ! -s "$T/kh-b" ] && grep -q 'do not match' "$T/out-b"; then pass "B  a different key is refused, nothing written"; else bad "B  mismatch: rc=$rc, file=$(wc -c < "$T/kh-b") bytes, $(cat "$T/out-b")"; fi
strict_ssh "$T/kh-b" >/dev/null 2>&1; [ $? = 255 ] && pass "B  a strict connection to the impostor is refused" || bad "B  the impostor connected under strict checking"

# ---- C: AWS, no console block -----------------------------------------------------
printf '%s\n' "$K1_LINE" > "$T/scan"; : > "$T/console"
: > "$T/kh-c"; start=$(date +%s)
DEADLINE=2 helper hostkeys_aws i-0123 "$IP" "$T/kh-c" >"$T/out-c" 2>&1; rc=$?; el=$(( $(date +%s) - start ))
if [ "$rc" = 1 ] && [ "$el" -le 15 ] && grep -q 'no SSH HOST KEY FINGERPRINTS block' "$T/out-c"; then pass "C  no console block: refused after the deadline (${el}s), with the reason"; else bad "C  missing block: rc=$rc after ${el}s, $(cat "$T/out-c")"; fi

# ---- D: AWS, the console answers base64 ----------------------------------------------
block_for "$K1_FP" | base64 > "$T/console"; printf '%s\n' "$K1_LINE" > "$T/scan"
: > "$T/kh-d"
helper hostkeys_aws i-0123 "$IP" "$T/kh-d" >"$T/out-d" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -qF "$K1_LINE" "$T/kh-d"; then pass "D  base64 console output is decoded"; else bad "D  base64 console: rc=$rc, $(cat "$T/out-d")"; fi
block_for "$K1_FP" > "$T/console"

# ---- E: GCE, the guest attributes carry the keys --------------------------------------
printf '%s\n' '{"queryValue":{"items":[{"key":"ed25519","namespace":"hostkeys","value":"'"$(cut -d' ' -f1,2 "$T/keys/k1.pub")"' node-one"}]}}' > "$T/guest"
: > "$T/kh-e"
helper hostkeys_populate_gcp "$T/kh-e" "$IP" >"$T/out-e" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -qF "$K1_LINE" "$T/kh-e"; then pass "E  GCE guest-attribute keys are written"; else bad "E  GCE keys: rc=$rc, $(cat "$T/out-e")"; fi
printf '%s\n' "$K1_LINE" > "$T/present"
strict_ssh "$T/kh-e" >/dev/null 2>&1 && pass "E  a strict connection to that node succeeds" || bad "E  a strict connection to the GCE node was refused"

# ---- F: GCE, no guest attributes ------------------------------------------------------
printf '{}\n' > "$T/guest"; : > "$T/kh-f"; start=$(date +%s)
DEADLINE=2 helper hostkeys_populate_gcp "$T/kh-f" "$IP" >"$T/out-f" 2>&1; rc=$?; el=$(( $(date +%s) - start ))
if [ "$rc" != 0 ] && [ "$el" -le 15 ] && grep -q 'no SSH host keys' "$T/out-f" && [ ! -s "$T/kh-f" ]; then pass "F  no guest attributes: refused after the deadline (${el}s), nothing written"; else bad "F  missing guest attributes: rc=$rc after ${el}s, $(cat "$T/out-f")"; fi

# ---- G: install.sh and SSH_KNOWN_HOSTS -----------------------------------------------
# install.sh runs on a stub ssh that records every call and always refuses; the
# first call it makes to the node is the one that matters.
cat > "$T/bin/ssh-refuse" <<STUB
#!/usr/bin/env bash
echo "ssh \$*" >> "$T/install-ssh.log"
exit 255
STUB
cp "$T/bin/ssh-refuse" "$T/bin/ssh-stub-install"; chmod +x "$T/bin/ssh-stub-install"
mkdir -p "$T/install-bin"; cp "$T/bin/ssh-refuse" "$T/install-bin/ssh"; chmod +x "$T/install-bin/ssh"
printf '%s\n' "$K1_LINE" > "$T/pinned"
rm_log() { : > "$T/install-ssh.log"; }
rm_log
PATH="$T/install-bin:$PATH" SSH_KNOWN_HOSTS="$T/pinned" perl -e 'alarm 60; exec @ARGV' \
  bash install.sh --servers "$IP" >"$T/out-g1" 2>&1
first="$(head -1 "$T/install-ssh.log" 2>/dev/null)"
case "$first" in *StrictHostKeyChecking=yes*"UserKnownHostsFile=$T/pinned"*) pass "G  SSH_KNOWN_HOSTS: the first ssh is strict against that file";; *) bad "G  SSH_KNOWN_HOSTS: first ssh was: ${first:-none}";; esac
rm_log
PATH="$T/install-bin:$PATH" perl -e 'alarm 60; exec @ARGV' bash install.sh --servers "$IP" >"$T/out-g2" 2>&1
first="$(head -1 "$T/install-ssh.log" 2>/dev/null)"
case "$first" in *accept-new*) pass "G  without SSH_KNOWN_HOSTS: accept-new, as before";; *) bad "G  no pin: first ssh was: ${first:-none}";; esac
grep -q "pin these keys\|To pin these keys" "$T/out-g2" && pass "G  without SSH_KNOWN_HOSTS: the way to pin is printed" || bad "G  no pin hint printed"

# ---- H: the cloud launchers take their keys first, and never accept on first use -------------
for f in cloud/aws/install-aws.sh cloud/gcp/install-gcp.sh cloud/aws/deploy-aws.sh cloud/gcp/deploy-gcp.sh; do
  # a count, not `grep -q`: under pipefail, grep -q's early exit fails the pipeline (SIGPIPE) and reads as "no match"
  if [ "$(grep -v '^[[:space:]]*#' "$f" | grep -c 'accept-new')" -gt 0 ]; then bad "H  $f still accepts host keys on first use"; continue; fi
  # The first connection is the first ssh-helper call OUTSIDE a function body: a helper
  # defined as `imds() { su_ ... }` makes no connection when it is defined.
  pop=$(grep -n 'hostkeys_populate_' "$f" | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1)
  use=$(python3 -c '
import re, sys
inside = False
for n, line in enumerate(open(sys.argv[1]), 1):
    code = line.rstrip("\n")
    if inside:
        if code == "}":
            inside = False
        continue
    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{\s*$", code):
        inside = True          # a multi-line function: its body is a definition, not a connection
        continue
    if code.lstrip().startswith("#"):
        continue
    if re.search(r"(^|[;&|(]\s*|\s)(sh_|su_) \"", code) and "()" not in code:
        print(n)
        break
' "$f")
  if [ -n "$pop" ] && [ -n "$use" ] && [ "$pop" -lt "$use" ]; then pass "H  $f takes its host keys (line $pop) before the first connection (line $use)"; else bad "H  $f: keys at line ${pop:-none}, first connection at line ${use:-none}"; fi
done
if [ "$(grep -v '^[[:space:]]*#' install.sh | grep -c 'StrictHostKeyChecking=no')" -gt 0 ]; then bad "H  install.sh disables host key checking"; else pass "H  install.sh never disables host key checking"; fi

if [ "$fails" -gt 0 ]; then
  printf '\nFAIL: %d case(s) of the host key checks did not hold.\n' "$fails"
  exit 1
fi
printf 'OK: the cloud installers take each node'"'"'s host keys out of band before connecting, strictly; a mismatch is refused; a missing key is refused at the deadline with the reason; SSH_KNOWN_HOSTS pins install.sh.\n'
