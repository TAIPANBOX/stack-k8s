# Host keys for the cloud installers, taken out of band (CLAUDE.md invariant 61).
#
# The first ssh to a fresh node used to be accepted on trust (accept-new): the
# key the network offered on the first connection became the key for good. These
# helpers fill a per-run known_hosts file BEFORE the first connection, from a
# channel that is not the network the connection crosses, and the installers
# then connect with StrictHostKeyChecking=yes against that file alone.
#
#   hostkeys_gcp NAME ZONE IP FILE
#     GCE publishes each instance's SSH host keys as guest attributes (the guest
#     agent writes them through the authenticated API, not over the network).
#     `gcloud compute instances get-guest-attributes ... --query-path=hostkeys/`
#     is read, and every key line in it is appended to FILE as `IP type base64`.
#
#   hostkeys_aws INSTANCE_ID IP FILE
#     cloud-init prints the instance's host key fingerprints to the console
#     (`aws ec2 get-console-output`), between the lines
#     -----BEGIN SSH HOST KEY FINGERPRINTS----- and -----END SSH HOST KEY FINGERPRINTS-----.
#     The node is keyscanned, and its keys are appended to FILE only when the
#     SHA256 fingerprints it presents are exactly the ones the console printed.
#     A mismatch is refused at once. A console block or a keyscan that is not
#     there yet is retried until the deadline, then refused with the reason.
#
# Both wait at most HOSTKEY_DEADLINE seconds (default 300) and poll every
# HOSTKEY_POLL seconds (default 5). Both return 0 with FILE written, or non-zero
# after saying on stderr what was missing and that nothing was connected to.
#
# Pure shell plus gcloud, aws, ssh-keyscan and ssh-keygen. The tests stub those
# on PATH (scripts/hostkeys-are-verified.sh).

hostkeys_deadline() { printf '%s' "${HOSTKEY_DEADLINE:-300}"; }
hostkeys_poll() { printf '%s' "${HOSTKEY_POLL:-5}"; }

# GCE: every key line in the guest-attribute tree, as `type base64`.
hostkeys_gcp_lines() {
  python3 -c '
import json, re, sys
KEY = re.compile(r"^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521))\s+([A-Za-z0-9+/=]+)")
def walk(node):
    if isinstance(node, dict):
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)
    elif isinstance(node, str):
        m = KEY.match(node.strip())
        if m:
            yield f"{m.group(1)} {m.group(3)}"
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)
seen = set()
for line in walk(doc):
    if line not in seen:
        seen.add(line)
        print(line)
'
}

hostkeys_gcp() {
  local name="$1" zone="$2" ip="$3" file="$4" deadline out lines t b
  deadline=$(( $(date +%s) + $(hostkeys_deadline) ))
  while :; do
    out="$(gcloud compute instances get-guest-attributes "$name" --zone "$zone" \
      --query-path=hostkeys/ --format=json 2>/dev/null)" || out=""
    lines="$(printf '%s' "$out" | hostkeys_gcp_lines)"
    if [ -n "$lines" ]; then
      while read -r t b; do
        [ -n "$t" ] && [ -n "$b" ] && printf '%s %s %s\n' "$ip" "$t" "$b" >> "$file"
      done <<EOF
$lines
EOF
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      printf 'hostkeys: no SSH host keys in the guest attributes of %s (%s, zone %s) after %s s. ' \
        "$name" "$ip" "$zone" "$(hostkeys_deadline)" >&2
      printf 'The guest agent has not published them, or the instance is not the one at that address. Nothing was connected to.\n' >&2
      return 1
    fi
    sleep "$(hostkeys_poll)"
  done
}

# The console's output, decoded if the CLI handed it back base64 encoded.
hostkeys_aws_console() { # instance-id
  local raw
  raw="$(aws ec2 get-console-output --latest --instance-id "$1" --query Output --output text 2>/dev/null)" || return 0
  case "$raw" in
    *"BEGIN SSH HOST KEY FINGERPRINTS"*) printf '%s\n' "$raw" ;;
    *) printf '%s' "$raw" | base64 -d 2>/dev/null || printf '%s' "$raw" | base64 -D 2>/dev/null || true ;;
  esac
}

hostkeys_aws() {
  local id="$1" ip="$2" file="$3" deadline block scan tmp console_fp scan_fp
  deadline=$(( $(date +%s) + $(hostkeys_deadline) ))
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/hostkeys.XXXXXX")" || return 1
  while :; do
    block="$(hostkeys_aws_console "$id" | sed -n '/-----BEGIN SSH HOST KEY FINGERPRINTS-----/,/-----END SSH HOST KEY FINGERPRINTS-----/p')"
    scan="$(ssh-keyscan -T 10 "$ip" 2>/dev/null)"
    if [ -n "$block" ] && [ -n "$scan" ]; then
      printf '%s\n' "$scan" > "$tmp/scan"
      console_fp="$(printf '%s\n' "$block" | awk '$2 ~ /^SHA256:/ {print $2}' | sort -u)"
      scan_fp="$(ssh-keygen -lf "$tmp/scan" 2>/dev/null | awk '{print $2}' | sort -u)"
      if [ -n "$console_fp" ] && [ "$console_fp" = "$scan_fp" ]; then
        printf '%s\n' "$scan" >> "$file"
        rm -rf "$tmp"
        return 0
      fi
      printf 'hostkeys: the SSH host keys %s presents do not match the fingerprints printed to the console of instance %s. ' \
        "$ip" "$id" >&2
      printf 'Refusing to connect. Nothing was written to the known_hosts file.\n' >&2
      rm -rf "$tmp"
      return 2
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      if [ -z "$block" ]; then
        printf 'hostkeys: no SSH HOST KEY FINGERPRINTS block in the console output of %s after %s s. ' \
          "$id" "$(hostkeys_deadline)" >&2
        printf 'cloud-init has not printed it yet, or the instance did not boot. Nothing was connected to.\n' >&2
      else
        printf 'hostkeys: %s did not present an SSH host key on port 22 after %s s. Nothing was connected to.\n' \
          "$ip" "$(hostkeys_deadline)" >&2
      fi
      rm -rf "$tmp"
      return 1
    fi
    sleep "$(hostkeys_poll)"
  done
}

# The instance behind a public address, through the API, then its host keys.
hostkeys_gcp_lookup() { # public-ip -> "name zone" (empty when no instance has it)
  gcloud compute instances list --filter="networkInterfaces[0].accessConfigs[0].natIP=$1" \
    --format='value(name,zone.basename())' 2>/dev/null | head -1
}

hostkeys_aws_lookup() { # public-ip -> instance id (empty when none is running there)
  aws ec2 describe-instances --filters "Name=ip-address,Values=$1" \
    "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | awk '{print $1}' | head -1
}

# hostkeys_populate_gcp FILE NODE...   every node's keys, or non-zero at the first that fails
hostkeys_populate_gcp() {
  local file="$1" n name zone
  shift
  for n in "$@"; do
    read -r name zone <<EOF
$(hostkeys_gcp_lookup "$n")
EOF
    if [ -z "$name" ] || [ -z "$zone" ]; then
      printf 'hostkeys: no GCE instance in this project has the public address %s, so its host keys cannot be read. Nothing was connected to.\n' "$n" >&2
      return 1
    fi
    hostkeys_gcp "$name" "$zone" "$n" "$file" || return 1
  done
}

# hostkeys_populate_aws FILE NODE...   the same for AWS, checked against each console
hostkeys_populate_aws() {
  local file="$1" n id
  shift
  for n in "$@"; do
    id="$(hostkeys_aws_lookup "$n")"
    if [ -z "$id" ]; then
      printf 'hostkeys: no running EC2 instance has the public address %s, so its host keys cannot be checked. Nothing was connected to.\n' "$n" >&2
      return 1
    fi
    hostkeys_aws "$id" "$n" "$file" || return 1
  done
}
