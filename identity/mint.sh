#!/usr/bin/env bash
# Mint the gateway's client keys on a cluster that was applied by hand.
#
#   KUBECONFIG=./kubeconfig.yaml ./identity/mint.sh [--agent-key-file F]
#
# The three deploy scripts do this themselves after `kubectl apply -k`
# (lib/identity-mint.sh, CLAUDE.md invariant 50). This is the same step for a
# cluster brought up the other way, `install.sh` then `kubectl apply -k manifests/`:
# the gateway reads its client keys from a Secret that reference does not mark
# optional, so it does not start until the keys exist. Given no files, this mints a
# key for the console's copilot and one for your agents, binds each to its own agent
# ids, writes the agents' key to F (./agent-key by default, 0600) and prints the
# path, never the key. A cluster that already holds keys keeps them: the operator's
# from identity/up.sh are left alone, and minted ones are never rewritten.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

KEYFILE="$ROOT/agent-key"
while [ $# -gt 0 ]; do
  case "$1" in
    --agent-key-file) [ -n "${2:-}" ] || die "--agent-key-file needs a path"; KEYFILE="$2"; shift 2 ;;
    -h|--help)        awk 'NR > 1 && /^set -euo pipefail/ { exit } NR > 1' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *)                die "unknown flag: $1" ;;
  esac
done

. "$ROOT/lib/gen.sh" || die "no lib/gen.sh in $ROOT"
. "$ROOT/lib/identity-mint.sh" || die "no lib/identity-mint.sh in $ROOT"
command -v kubectl >/dev/null || die "kubectl not found"
kubectl version -o json >/dev/null 2>&1 || die "no cluster: set KUBECONFIG"
# One string, read by a shell, as the deploy scripts' runner over ssh reads it.
k_() { eval "kubectl $*"; }

say "the gateway's client keys"
identity_mint_settle "$KEYFILE"
identity_mint_note "$KEYFILE"
