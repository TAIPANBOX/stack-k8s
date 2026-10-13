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
# TokenFuse compares these variables against the four words. Since TokenFuse v1.12.0 any
# other value exits 2 before the listener binds, and both variables accept the words in any
# case with surrounding spaces ignored. Before that, a value outside the words was read as
# off without a word, so a misspelt `shadow` looked at nothing. This check still refuses a
# word with a space in it, a stricter rule than TokenFuse's, so the manifest and the flag say
# the same thing. The launcher refuses the word before anything is installed, so the mistake
# is found in a second and not at pod start.
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
    printf 'pii-scan: off. The personal-data scanners are not consulted and look at nothing, which is TokenFuse before the extension existed.\n' >&2 ;;
  shadow)
    printf 'pii-scan: shadow, the default. The scanners find email addresses, card numbers and international phone numbers in prompts and tool arguments and report how many and which kinds. The gateway adds an x-fuse-dlp header to its answer and logs nothing. The broker logs a warning and marks _tokenfuse.dlp_pii on tool responses. Nothing is refused, no event or trace row is written, and the personal data still reaches the provider.\n' >&2 ;;
  mask)
    printf 'pii-scan: mask. Each finding is replaced with [REDACTED:kind] before the call is forwarded.\n' >&2 ;;
  block)
    printf 'pii-scan: block. A call that carries a finding is refused. A false positive refuses the call, so block is a decision about a workload, not a default.\n' >&2 ;;
  *)
    refuse "'$value' is not a mode the gateway reads. Use exactly off, shadow, mask or block. The gateway ignores any other word and falls back to off." ;;
esac
