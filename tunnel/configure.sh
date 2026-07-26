#!/usr/bin/env bash
# Ask the operator for the two names the tunnel needs, and write site.yaml.
#
#   ./tunnel/configure.sh
#   CONSOLE_DOMAIN=box.acme.com ENDPOINT_HOST=gw.acme.com ./tunnel/configure.sh
#
# Called by up.sh when site.yaml is missing, and by deploy.sh BEFORE the long
# install rather than after it: the answers are checked against DNS here, and an
# operator should learn that a record is missing in the first ten seconds, not
# after fifteen minutes of building images.
#
# Reading the answers is the one genuinely tricky part, and the reason this is a
# file rather than three lines inline. `deploy.sh` is documented as
# `curl -fsSL ... | bash -s -- ...`, and in that form the script's own stdin IS
# THE SCRIPT. A plain `read` there consumes the remaining source code as the
# answer, and the failure is spectacular and unexplainable. So the terminal is
# opened explicitly, and when there is no terminal this refuses rather than
# guessing or hanging.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SITE="$HERE/site.yaml"
TUNNEL_IP="10.9.0.1"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }
warn() { printf '   \033[33m%s\033[0m\n' "$*"; }

CONSOLE_DOMAIN="${CONSOLE_DOMAIN:-}"
ENDPOINT_HOST="${ENDPOINT_HOST:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --console-domain) CONSOLE_DOMAIN="$2"; shift 2 ;;
    --endpoint-host)  ENDPOINT_HOST="$2";  shift 2 ;;
    --acme-email)     ACME_EMAIL="$2";     shift 2 ;;
    --force)          FORCE=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -s "$SITE" ] && [ "$FORCE" = 0 ] && [ -z "$CONSOLE_DOMAIN$ENDPOINT_HOST" ]; then
  echo "   $SITE already exists; --force to replace it"
  exit 0
fi

# python3, not `getent`: macOS ships no getent, and this runs on the operator's
# own machine.
resolves_to() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import socket, sys
try:
    print(" ".join(sorted({i[4][0] for i in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)})))
except Exception:
    pass
PY
}

# A name, not a URL and not an address. An operator who pastes
# `https://box.acme.com/` gets a certificate request for a host called
# `https://box.acme.com/`, which fails somewhere far from here.
valid_name() {
  case "$1" in
    ""|*" "*|*/*|*:*) return 1 ;;
    *.*) [ "${1%.}" = "$1" ] && printf '%s' "$1" | grep -qE '^[a-zA-Z0-9._-]+$' ;;
    *) return 1 ;;
  esac
}

# OPENING it, not testing it. `[ -r /dev/tty ]` succeeds whenever the device
# node exists, which it does in a detached process with no controlling terminal;
# the first write then fails with "Device not configured" AFTER the prompt has
# already been printed. Only an open says whether anyone is there.
#
# The braces matter. `exec 3<>/dev/tty 2>/dev/null` applies its redirections
# left to right, so the open is attempted and its error printed BEFORE stderr
# is silenced; the shell then reports "Device not configured" on its own,
# above the explanation this script is about to give. Redirecting the group
# silences the open itself.
TTY_OK=0
if { exec 3<>/dev/tty; } 2>/dev/null; then TTY_OK=1; else exec 3>/dev/null; fi

ask() { # prompt varname
  local prompt="$1" __var="$2" ans=""
  while :; do
    printf '   %s ' "$prompt" >&3
    IFS= read -r ans <&3 || die "no answer on the terminal"
    ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
    if valid_name "$ans"; then eval "$__var=\$ans"; return 0; fi
    printf '   that is a host NAME, like box.acme.com: no scheme, no port, no slash\n' >&3
  done
}

if [ -z "$CONSOLE_DOMAIN" ] || [ -z "$ENDPOINT_HOST" ]; then
  [ "$TTY_OK" = 1 ] || die "no terminal to ask on, and the two names were not given.

   This happens with \`curl ... | bash\`, where the script's own stdin is the
   script. Pass them instead:

     --console-domain box.example.com --endpoint-host gw.example.com

   or run ./tunnel/configure.sh from a terminal first."

  say "your two names"
  cat >&3 <<'TXT'
   The console is published nowhere: every Service is ClusterIP, and
   security-tests.sh asserts it. So the way in is a WireGuard tunnel you issue
   yourself a device for, and that needs two names you control.

   They cannot be the same name. One has to resolve to a public address for the
   handshake and the other to a private one for the console, on the same device,
   at the same time.
TXT
  echo >&3
  echo "   1. what you will type in the BROWSER, once the tunnel is up." >&3
  echo "      Needs an A record pointing at $TUNNEL_IP. Every passkey you enrol" >&3
  echo "      is bound to this exact name, so pick one you will keep." >&3
  [ -n "$CONSOLE_DOMAIN" ] || ask "console domain:" CONSOLE_DOMAIN
  echo >&3
  echo "   2. what a DEVICE dials from OUTSIDE, before any tunnel exists." >&3
  echo "      Needs an A record pointing at a public address of one of your nodes." >&3
  [ -n "$ENDPOINT_HOST" ] || ask "gateway host:" ENDPOINT_HOST
fi

valid_name "$CONSOLE_DOMAIN" || die "console domain '$CONSOLE_DOMAIN' is not a host name"
valid_name "$ENDPOINT_HOST"  || die "gateway host '$ENDPOINT_HOST' is not a host name"
[ "$CONSOLE_DOMAIN" != "$ENDPOINT_HOST" ] || die "both names are '$CONSOLE_DOMAIN'.

   They cannot be one name: it would have to resolve to a public address for the
   handshake and to $TUNNEL_IP for the console, on the same device, at once."

# Advisory here, a hard stop in up.sh. A record created a minute ago has not
# propagated yet, and refusing at this point would mean losing the answers.
say "checking those two against DNS"
MISSING=0
got="$(resolves_to "$CONSOLE_DOMAIN")"
case " $got " in
  *" $TUNNEL_IP "*) printf '   %-28s -> %s, correct\n' "$CONSOLE_DOMAIN" "$TUNNEL_IP" ;;
  *) MISSING=1
     printf '   %-28s -> %s\n' "$CONSOLE_DOMAIN" "${got:-nothing}"
     warn "needs an A record -> $TUNNEL_IP (on Cloudflare, proxying OFF)" ;;
esac
got="$(resolves_to "$ENDPOINT_HOST")"
if [ -n "$got" ]; then
  printf '   %-28s -> %s\n' "$ENDPOINT_HOST" "$got"
  echo "   (up.sh checks that this is an address YOUR cluster answers on)"
else
  MISSING=1
  printf '   %-28s -> nothing\n' "$ENDPOINT_HOST"
  warn "needs an A record -> a public address of one of your nodes"
fi

umask 022
cat > "$SITE" <<YAML
# Written by tunnel/configure.sh. Not tracked: these two names are yours.
# See site.example.yaml for what each one addresses and why they are two.
---
apiVersion: v1
kind: ConfigMap
metadata: { name: stack-tunnel, namespace: agent-stack }
data:
  console_domain: "$CONSOLE_DOMAIN"
  console_origin: "https://$CONSOLE_DOMAIN"
  endpoint_host: "$ENDPOINT_HOST"
  acme_email: "$ACME_EMAIL"
---
apiVersion: v1
kind: ConfigMap
metadata: { name: stack-tunnel, namespace: agent-tunnel }
data:
  console_domain: "$CONSOLE_DOMAIN"
  console_origin: "https://$CONSOLE_DOMAIN"
  endpoint_host: "$ENDPOINT_HOST"
  acme_email: "$ACME_EMAIL"
YAML
echo "   written to $SITE"

if [ "$MISSING" = 1 ]; then
  cat <<EOF

   Create the record(s) above before running ./tunnel/up.sh. It resolves both
   names before it creates anything and refuses on a mismatch, because the
   alternative is silence: WireGuard answers nothing at all to a key it does
   not know, so a wrong endpoint and a closed port look identical.
EOF
fi
