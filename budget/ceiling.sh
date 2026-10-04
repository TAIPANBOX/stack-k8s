#!/usr/bin/env bash
# The run-budget ceiling: validate the operator's figure for
# TOKENFUSE_MAX_RUN_BUDGET_USD. The ONE copy of the validation: deploy.sh,
# cloud/gcp/deploy-gcp.sh and cloud/aws/deploy-aws.sh only parse
# `--run-budget-ceiling` and hand the value here, because a block copied into
# three launchers drifts (GOTCHAS 90, 101, 102). CLAUDE.md invariant 28 holds it,
# scripts/run-budget-ceiling-is-set.sh.
#
#   budget/ceiling.sh check <USD>
#
#     Refuses, on stderr and with exit 1, a figure the gateway would refuse to
#     start on. Says on stderr what the ceiling does and what it does not.
#     Prints nothing on stdout.
#
# The grammar is the gateway's own (tokenfuse v1.5.0, crates/gateway/src/
# defaults.rs, `max_run_budget_from`): digits, optionally a point and one to six
# more digits, read as exact microdollars, and greater than zero. A sign, an
# exponent, a second point, a seventh decimal, a word, a figure of zero: the
# gateway exits 2 on each of them and a pod in CrashLoopBackOff is a worse place
# to learn that than this script, which runs before anything is installed.
set -euo pipefail

refuse() { printf 'run-budget-ceiling: %s\n' "$*" >&2; exit 1; }

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
  check) ;;
  *) refuse "usage: budget/ceiling.sh check <USD>" ;;
esac
[ $# -eq 1 ] || refuse "check takes exactly one figure, in US dollars (for example 5.00 or 25)"
value="$1"

# Whole part: digits only, and short enough to fit the ledger's integer
# microdollars (the gateway refuses what overflows an i64; twelve digits is
# nine orders of magnitude below that and above any sane per-run ceiling).
re='^[0-9]{1,12}(\.[0-9]{1,6})?$'
[[ "$value" =~ $re ]] \
  || refuse "'$value' is not a positive number of US dollars with at most six decimals (for example 25 or 2.50). No sign, no exponent, no spaces: the gateway refuses to start on anything else."

# Zero is a different setting (a ceiling that refuses every call) and an easy
# typo, so the gateway refuses it too.
case "${value//[0.]/}" in
  "") refuse "'$value' is zero. A ceiling of zero would refuse every call; the gateway does not accept it." ;;
esac

printf 'run-budget-ceiling: %s USD per run. A budget a CALLER declares (x-fuse-budget-usd), or a policy default, or the built-in default is lowered to this on every call; a caller may always ask for less.\n' "$value" >&2
printf '                    It does NOT lower a budget the Cloud sets, and it bounds each run, not an agent'"'"'s total spend: an agent that opens a new run id gets a new ceiling'"'"'s worth.\n' >&2
