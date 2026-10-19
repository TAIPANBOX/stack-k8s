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
#   D2 AWS, every console line carries cloud-init's syslog prefix, as EC2 prints it:
#      the fingerprints are read, and A holds.
#   D3 AWS, the matching fingerprint is printed under another program's prefix:
#      not read, so the node is refused.
#   E  GCE, the guest attributes carry the keys: written, and a strict connection
#      succeeds.
#   E2 GCE, the attributes in the shape gcloud --format=json prints them (the type as
#      the key, the base64 as the value): written.
#   F  GCE, no guest attributes: refused at the deadline with the reason named.
#   G  install.sh: with SSH_KNOWN_HOSTS its first ssh is strict against that file;
#      without it, accept-new, and the accepted key is printed with how to pin it.
#   I  The builder's peer file names each node by its public and its private address, with the same verified key.
#   J  A strict connection from the builder to a peer's private address succeeds with that file, and is refused without the name.
#   N  cloud/gcp/main.tf turns guest attributes on for every node, without which GCE
#      publishes no host keys and E can never happen on a real cluster.
#   K  No tracked script (prose excepted) disables host key checking.
#   L  Each launcher that pushes an image to its peers writes the peer file before its first such ssh, and that ssh is strict against it.
#   M  Each such launcher builds the peer file from the verified keys (hostkeys_peer_file).
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

# ---- D2: AWS, cloud-init's syslog prefix on every line (the live EC2 shape) ------------
block_for "$K1_FP" | sed 's/^/<14>Oct 19 17:25:04 cloud-init: /' > "$T/console"; printf '%s\n' "$K1_LINE" > "$T/scan"
: > "$T/kh-d2"
helper hostkeys_aws i-0123 "$IP" "$T/kh-d2" >"$T/out-d2" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -qF "$K1_LINE" "$T/kh-d2"; then pass "D2 a console block with cloud-init's syslog prefix is read"; else bad "D2 prefixed console: rc=$rc, $(cat "$T/out-d2")"; fi

# ---- D3: AWS, the fingerprint under another program's prefix -------------------------
block_for "$K1_FP" | sed 's/^/<14>Oct  9 17:25:04 sshd-forger: /' > "$T/console"
: > "$T/kh-d3"
helper hostkeys_aws i-0123 "$IP" "$T/kh-d3" >"$T/out-d3" 2>&1; rc=$?
if [ "$rc" = 2 ] && [ ! -s "$T/kh-d3" ]; then pass "D3 a fingerprint under another program's prefix is not read, the node is refused"; else bad "D3 foreign prefix: rc=$rc, file=$(wc -c < "$T/kh-d3") bytes, $(cat "$T/out-d3")"; fi
block_for "$K1_FP" > "$T/console"

# ---- E: GCE, the guest attributes carry the keys --------------------------------------
printf '%s\n' '{"queryValue":{"items":[{"key":"ed25519","namespace":"hostkeys","value":"'"$(cut -d' ' -f1,2 "$T/keys/k1.pub")"' node-one"}]}}' > "$T/guest"
: > "$T/kh-e"
helper hostkeys_populate_gcp "$T/kh-e" "$IP" >"$T/out-e" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -qF "$K1_LINE" "$T/kh-e"; then pass "E  GCE guest-attribute keys are written"; else bad "E  GCE keys: rc=$rc, $(cat "$T/out-e")"; fi
printf '%s\n' "$K1_LINE" > "$T/present"
strict_ssh "$T/kh-e" >/dev/null 2>&1 && pass "E  a strict connection to that node succeeds" || bad "E  a strict connection to the GCE node was refused"

# ---- E2: GCE, the gcloud --format=json shape (type as key, base64 as value) ------------
printf '%s\n' '[{"key":"'"$(cut -d' ' -f1 "$T/keys/k1.pub")"'","namespace":"hostkeys","value":"'"$(cut -d' ' -f2 "$T/keys/k1.pub")"'"}]' > "$T/guest"
: > "$T/kh-e2"
helper hostkeys_populate_gcp "$T/kh-e2" "$IP" >"$T/out-e2" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -qF "$K1_LINE" "$T/kh-e2"; then pass "E2 GCE keys in the gcloud json shape are written"; else bad "E2 gcloud json shape: rc=$rc, $(cat "$T/out-e2")"; fi

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
NO_CHECK="StrictHostKeyChecking=""no"   # split: this file must not contain the option it forbids
if [ "$(grep -v '^[[:space:]]*#' install.sh | grep -c "$NO_CHECK")" -gt 0 ]; then bad "H  install.sh disables host key checking"; else pass "H  install.sh never disables host key checking"; fi

# ---- I, J: the node-to-node peer file names each peer by its public and its private address ----
# The image distribution runs on the builder and reaches each peer at its PRIVATE address, so
# the file the builder reads must name that address with the peer's verified key (same key,
# other name). The same stub ssh as above stands in for the builder's connection.
PRIV=10.0.0.7
SRC_KH="$T/peer-src"
printf '%s\n' "$K1_LINE" > "$SRC_KH"
( export PATH="$T/bin:$PATH"; . lib/hostkeys.sh && hostkeys_peer_file "$T/peer-out" "$SRC_KH" "$IP" "$PRIV" ) >"$T/out-i" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ "$(wc -l < "$T/peer-out" | tr -d ' ')" = 2 ] && grep -qxF "$K1_LINE" "$T/peer-out" && grep -qxF "$PRIV ${K1_LINE#* }" "$T/peer-out"; then
  pass "I  the peer file names a node by its public and its private address, with the same key"
else
  bad "I  peer file: rc=$rc, $(cat "$T/peer-out" 2>/dev/null | tr '\n' '|') $(cat "$T/out-i")"
fi
printf '%s %s\n' "$PRIV" "${K1_LINE#* }" > "$T/present"
PATH="$T/bin:$PATH" ssh -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$T/peer-out" -o BatchMode=yes "root@$PRIV" true >/dev/null 2>&1 \
  && pass "J  a strict connection from the builder to the private address succeeds" \
  || bad "J  a strict connection to a peer's private address was refused with its verified key in the file"
printf '%s\n' "$K1_LINE" > "$T/kh-public-only"
PATH="$T/bin:$PATH" ssh -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$T/kh-public-only" -o BatchMode=yes "root@$PRIV" true >/dev/null 2>&1
[ $? = 255 ] && pass "J  without the private name in the file, the same connection is refused" || bad "J  a peer's private address connected without its key being in the file"

# ---- K: no tracked script disables host key checking ----
# Scope: every tracked file but the prose (*.md), where the option may be named. The option is
# split in this file and in the teeth harness, so neither flags itself.
hits="$(git ls-files | grep -v '\.md$' | while IFS= read -r f; do grep -lF -- "$NO_CHECK" "$f" 2>/dev/null; done)"
if [ -z "$hits" ]; then pass "K  no tracked script disables host key checking"; else bad "K  these tracked files still disable host key checking: $(echo $hits)"; fi

# ---- L, M: every node-to-node ssh is strict against the peer file, and the file is written first ----
# A subject is a tracked launcher whose peer loop pipes a variable image into a peer over ssh
# (`docker save $img | ssh`). build.sh pipes the operator's own image to the one node it names, an
# operator-side path with its own ssh policy, and is not a subject.
# Found, not listed: a fourth cloud or a fifth launcher is judged the day it has that line.
subjects=""
for f in $(git ls-files '*.sh' | grep -v '^scripts/'); do
  if grep -qE 'docker save \\*\$img \| *ssh ' "$f"; then subjects="$subjects $f"; fi
done
if [ -z "$subjects" ]; then
  bad "L  no launcher pipes an image to a peer over ssh, so this measured NOTHING about node-to-node ssh"
fi
for f in $subjects; do
  w="$(grep -nE '^[^#]*cat > /root/\.ssh/stack-known-hosts' "$f" | head -1 | cut -d: -f1)"
  n="$(grep -nE '^[^#]*docker save \\*\$img \| *ssh ' "$f" | head -1 | cut -d: -f1)"
  line="$(sed -n "${n:-1}p" "$f")"
  if [ -z "$w" ]; then
    bad "L  $f never writes /root/.ssh/stack-known-hosts, so its node-to-node ssh has no verified keys"
  elif [ "$w" -ge "$n" ]; then
    bad "L  $f: the peer file is written at line $w, after its first node-to-node ssh at line $n"
  else
    case "$line" in
      *"StrictHostKeyChecking=yes"*"UserKnownHostsFile=/root/.ssh/stack-known-hosts"*) pass "L  $f writes its peer file (line $w) before its first node-to-node ssh (line $n), and that ssh is strict against it" ;;
      *) bad "L  $f: the node-to-node ssh at line $n is not strict against /root/.ssh/stack-known-hosts" ;;
    esac
  fi
  if [ "$(grep -c 'hostkeys_peer_file' "$f")" -gt 0 ]; then pass "M  $f builds its peer file from the verified keys (hostkeys_peer_file)"; else bad "M  $f does not build its peer file with hostkeys_peer_file"; fi
done

# ---- N: GCE publishes host keys only with guest attributes on ----
tf=cloud/gcp/main.tf
nodes="$(grep -c '^resource "google_compute_instance"' "$tf")"
on="$(grep -cE '^[[:space:]]*enable-guest-attributes[[:space:]]*=[[:space:]]*"TRUE"' "$tf")"
if [ "$nodes" -eq 0 ]; then bad "N  $tf declares no google_compute_instance, so N measured nothing"
elif [ "$on" -ge "$nodes" ]; then pass "N  $tf turns guest attributes on for its $nodes instance resource(s)"
else bad "N  $tf sets enable-guest-attributes = \"TRUE\" $on time(s) for $nodes instance resource(s): GCE then publishes no host keys and every deploy is refused"; fi

if [ "$fails" -gt 0 ]; then
  printf '\nFAIL: %d case(s) of the host key checks did not hold.\n' "$fails"
  exit 1
fi
printf 'OK: the cloud installers take each node'"'"'s host keys out of band before connecting, strictly; a mismatch is refused; a missing key is refused at the deadline with the reason; SSH_KNOWN_HOSTS pins install.sh.\n'
