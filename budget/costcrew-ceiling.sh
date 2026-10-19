#!/usr/bin/env bash
# The CostCrew run ceiling: validate the operator's figure for COSTCREW_CEILING in stack-wiring.
# The ONE copy of the validation: deploy.sh, cloud/gcp/deploy-gcp.sh and cloud/aws/deploy-aws.sh only
# parse `--costcrew-ceiling` and hand the value here (the same shape as budget/ceiling.sh, GOTCHAS 90,
# 101, 102). CLAUDE.md invariant 66 holds it, scripts/costcrew-ceiling-is-set.sh.
#
#   budget/costcrew-ceiling.sh check <USD>
#
#     Refuses, on stderr and with exit 1, a figure the crew would refuse to run under. Prints nothing on
#     stdout. A ceiling is a number a person chose: there is no default, and this script never supplies one.
#
# The grammar is the crew's own money grammar (costcrew, internal/money `Parse`, which reads dollars with
# at most two decimals into integer cents, and takes a leading sign only to refuse it): digits, optionally
# a point and one or two more digits, and greater than zero. A sign, an exponent, a second point, a third
# decimal, a word, a figure of zero: each is refused here, before anything is installed.
set -euo pipefail

refuse() { printf 'costcrew-ceiling: %s\n' "$*" >&2; exit 1; }

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
  check) ;;
  *) refuse "usage: budget/costcrew-ceiling.sh check <USD>" ;;
esac
[ $# -eq 1 ] || refuse "check takes exactly one figure, in US dollars (for example 1.00 or 25)"
value="$1"

# Whole part: digits only, short enough for an int64 of cents (nine digits is far above any sane run guard).
re='^[0-9]{1,9}(\.[0-9]{1,2})?$'
[[ "$value" =~ $re ]] \
  || refuse "'$value' is not a positive number of US dollars with at most two decimals (for example 25 or 2.50). No sign, no exponent, no spaces: the crew refuses to run on anything else."

# Zero would refuse every task, and an easy typo, so it is refused here as well.
case "${value//[0.]/}" in
  "") refuse "'$value' is zero. A ceiling of zero would refuse every task; the crew does not accept it." ;;
esac

printf 'costcrew-ceiling: %s USD per crew run, the smaller of this and the console'"'"'s own cadence ceiling. Set in stack-wiring; the crew CronJob reads it when a job starts.\n' "$value" >&2
