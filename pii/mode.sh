#!/usr/bin/env bash
# The PII scanners' mode: validate the operator's value for TOKENFUSE_DLP_PII (gateway)
# and TOKENFUSE_MCP_DLP_PII (MCP broker). The ONE copy of the validation. deploy.sh,
# cloud/gcp/deploy-gcp.sh and cloud/aws/deploy-aws.sh only parse `--pii-mode` and hand
# the value here, because a block copied into three launchers drifts (GOTCHAS 90, 101,
# 102). CLAUDE.md invariant 38 holds it, scripts/pii-is-shadow-by-default.sh.
#
#   pii/mode.sh check <off|shadow|mask|block>
#
#     Accepts exactly one of the four words. Says on stderr what the word does,
#     prints nothing on stdout, exits 0. Any other word exits 1 with the reason on
#     stderr.
#
# TokenFuse compares these variables against the four words and IGNORES any other value
# without a word: any string outside them falls back to off. The gateway trims surrounding
# space before it compares and the MCP broker does not, so this check refuses a word with
# a space in it too, since only the gateway would have read it. A misspelt `shadow`
# therefore starts the scanners in off, which records nothing and says nothing about it.
# The launcher refuses the word before anything is installed, so the mistake is found in a
# second and not after the install.
set -euo pipefail

refuse() { printf 'pii-scan: %s\n' "$*" >&2; exit 1; }

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
  check) ;;
  *) refuse "usage: pii/mode.sh check <off|shadow|mask|block>" ;;
esac
[ $# -eq 1 ] || refuse "check takes exactly one mode: off, shadow, mask or block"
value="$1"

case "$value" in
  off)
    printf 'pii-scan: off. The personal-data scanners are not consulted and record nothing, which is TokenFuse before the extension existed.\n' >&2 ;;
  shadow)
    printf 'pii-scan: shadow, the default. The scanners find email addresses, card numbers and international phone numbers in prompts and tool arguments, record how many and which kinds, and let the call through. Nothing is refused, and the matched text is not written. On a tool response the broker adds a note naming the count and kinds, which the agent then reads.\n' >&2 ;;
  mask)
    printf 'pii-scan: mask. Each finding is replaced with [REDACTED:kind] before the call is forwarded, and the count and kinds are recorded.\n' >&2 ;;
  block)
    printf 'pii-scan: block. A call that carries a finding is refused. A false positive refuses the call, so block is a decision about a workload, not a default.\n' >&2 ;;
  *)
    refuse "'$value' is not a mode the gateway reads. Use exactly off, shadow, mask or block. The gateway ignores any other word and falls back to off." ;;
esac
