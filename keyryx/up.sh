#!/usr/bin/env bash
# Turn Keyryx on for a cluster applied by hand, from an operator's machine. The install is
# lib/keyryx-install.sh, the one copy the three launchers also use (CLAUDE.md invariant 69): custody and its
# witness, wardryx's approval signer, and the record signer for the record-seal. A launcher install turns this on
# by default; this script is for the cluster that was applied with `kubectl apply -k` and nothing else.
#
#   KUBECONFIG=./kubeconfig.yaml ./keyryx/up.sh
#
# Idempotent: the keys and bearers are kept on every later run, the objects are re-applied, and the patches are
# the same. No key is printed: the values go from /dev/urandom into a pipe, and nothing echoes them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NS="${NS:-agent-stack}"
KEYRYX_NS="$NS"

command -v kubectl >/dev/null || { echo "keyryx/up.sh: kubectl is needed" >&2; exit 1; }
command -v openssl >/dev/null || { echo "keyryx/up.sh: openssl is needed" >&2; exit 1; }
die() { echo "keyryx/up.sh: $*" >&2; exit 1; }

# The library's k_ takes one argument string. Locally that string is a kubectl line, so eval gives its quoting
# a shell. Every string it runs is written in lib/keyryx-install.sh; none is built from input.
k_() { eval "kubectl $*"; }

. "$ROOT/lib/keyryx-install.sh"
keyryx_install_settle
echo "keyryx/up.sh: Keyryx is on. keyryx/down.sh reverses the wiring and keeps every key."
