#!/usr/bin/env bash
# The agent firewall's mode: validate the operator's value for TOKENFUSE_FIREWALL.
# The ONE copy of the validation. deploy.sh, cloud/gcp/deploy-gcp.sh and
# cloud/aws/deploy-aws.sh only parse `--firewall` and hand the value here, because a
# block copied into three launchers drifts (GOTCHAS 90, 101, 102). CLAUDE.md
# invariant 37 holds it, scripts/firewall-is-enforce-by-default.sh.
#
#   firewall/mode.sh check <enforce|shadow|off>
#
#     Accepts exactly one of the three words. Says on stderr what the word does,
#     prints nothing on stdout, exits 0. Any other word exits 1 with the reason on
#     stderr.
#
# TokenFuse compares TOKENFUSE_FIREWALL against those three words exactly
# (crates/gateway/src/firewall.rs, from_env), and IGNORES any other value without
# a word. A misspelt `enforce` therefore starts the gateway in shadow, which refuses
# nothing and says nothing about it. The launcher refuses the word before anything
# is installed, so the mistake is found in a second and not after the install.
set -euo pipefail

refuse() { printf 'agent-firewall: %s\n' "$*" >&2; exit 1; }

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
  check) ;;
  *) refuse "usage: firewall/mode.sh check <enforce|shadow|off>" ;;
esac
[ $# -eq 1 ] || refuse "check takes exactly one mode: enforce, shadow or off"
value="$1"

case "$value" in
  enforce)
    printf 'agent-firewall: enforce, the default. A run that read untrusted input and then asks for a capability it should not have is refused. The anti-exfiltration floor stays on. A declared tool that carries an injection finding labels its run, and the starter rule then applies to that run.\n' >&2 ;;
  shadow)
    printf 'agent-firewall: shadow. The firewall records what it would refuse and refuses nothing. It is for learning what the policy would do, not for protection.\n' >&2 ;;
  off)
    printf 'agent-firewall: off. The firewall is not consulted and records nothing, which is the gateway before the firewall existed.\n' >&2 ;;
  *)
    refuse "'$value' is not a mode the gateway reads. Use exactly enforce, shadow or off. The gateway ignores any other word and falls back to shadow." ;;
esac
