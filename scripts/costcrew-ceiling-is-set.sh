#!/usr/bin/env bash
# CLAUDE.md invariant 66. The CostCrew run ceiling is a number a person chose: no default ships, a launcher
# only writes the figure it was given, and the figure is validated before anything is installed and written
# after the last apply -k, where it sticks (stack-wiring is partly managed by the kustomization, the same
# trap as invariant 14).
#
# WHAT THIS CHECKS
#
#   1. budget/costcrew-ceiling.sh accepts a positive figure of at most two decimals and refuses every other
#      shape the crew would refuse (zero, a sign, an exponent, a third decimal, a word, the empty string).
#   2. Each launcher (deploy.sh, cloud/gcp/deploy-gcp.sh, cloud/aws/deploy-aws.sh) parses --costcrew-ceiling,
#      validates it with budget/costcrew-ceiling.sh BEFORE the first install step, and writes COSTCREW_CEILING
#      to stack-wiring AFTER its last `apply -k`, inside a guard on the value.
#   3. manifests/49-costcrew.yaml reads COSTCREW_CEILING from stack-wiring WITHOUT `optional`, so a crew pod
#      with no ceiling does not start, and runs the CronJob on its schedule (suspend: false, the 2026-09-03
#      decision; cadence bounds it at run time).
#
# The flag's ordering against the kustomization is held by scripts/deploy-flags-agree.sh (a row in its table).
#
# A subject that is absent is "measured NOTHING", never a pass.
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
bad() { printf 'FAIL: %s\n' "$*"; fail=$((fail + 1)); }

VALIDATOR="budget/costcrew-ceiling.sh"
if [ ! -f "$VALIDATOR" ]; then
  bad "$VALIDATOR is absent: the CostCrew ceiling is measured NOTHING"
else
  for good in 1.00 25 2.5 0.01 999999999; do
    if ! bash "$VALIDATOR" check "$good" >/dev/null 2>&1; then
      bad "$VALIDATOR refuses $good, which the crew accepts"
    fi
  done
  for worse in 0 0.00 -1 +1 1e3 1.234 abc "" "1 0" 1000000000; do
    if bash "$VALIDATOR" check "$worse" >/dev/null 2>&1; then
      bad "$VALIDATOR accepts '$worse', which the crew would refuse or read as zero"
    fi
  done
fi

LAUNCHERS="deploy.sh cloud/gcp/deploy-gcp.sh cloud/aws/deploy-aws.sh"
for f in $LAUNCHERS; do
  if [ ! -f "$f" ]; then
    bad "$f is absent: its CostCrew ceiling step is measured NOTHING"
    continue
  fi
  live=$(grep -vE '^[[:space:]]*#' "$f")
  if ! printf '%s\n' "$live" | grep -qE -- '--costcrew-ceiling\)'; then
    bad "$f does not parse --costcrew-ceiling"
  fi
  check_line=$(printf '%s\n' "$live" | grep -nE 'budget/costcrew-ceiling\.sh" check' | head -1 | cut -d: -f1)
  if [ -z "$check_line" ]; then
    bad "$f does not validate the CostCrew ceiling with budget/costcrew-ceiling.sh"
    continue
  fi
  install_line=$(printf '%s\n' "$live" | grep -nE '(/install\.sh|/install-gcp\.sh|/install-aws\.sh|terraform (apply|init))' | head -1 | cut -d: -f1)
  if [ -n "$install_line" ] && [ "$check_line" -gt "$install_line" ]; then
    bad "$f validates the CostCrew ceiling after its install step (line $install_line), so a refusal would come after the install"
  fi
  last_apply=$(printf '%s\n' "$live" | grep -nE 'k_ "apply -k[^"]*manifests"' | tail -1 | cut -d: -f1)
  patch_line=$(printf '%s\n' "$live" | grep -nE 'patch configmap stack-wiring --type merge.*COSTCREW_CEILING' | tail -1 | cut -d: -f1)
  if [ -z "$patch_line" ]; then
    bad "$f never writes COSTCREW_CEILING to stack-wiring"
  elif [ -z "$last_apply" ] || [ "$patch_line" -lt "$last_apply" ]; then
    bad "$f writes COSTCREW_CEILING before its last apply -k, so the apply reverts or ignores it"
  fi
  if ! printf '%s\n' "$live" | grep -qE 'if \[ -n "\$COSTCREW_CEILING_ARG" \]'; then
    bad "$f writes COSTCREW_CEILING without a guard on the value, so an empty flag would write an empty figure"
  fi
done

M49="manifests/49-costcrew.yaml"
if [ ! -f "$M49" ]; then
  bad "$M49 is absent: the crew's ceiling reference and suspension are measured NOTHING"
else
  live=$(grep -vE '^[[:space:]]*#' "$M49")
  if ! printf '%s\n' "$live" | grep -qE 'configMapKeyRef: \{ name: stack-wiring, key: COSTCREW_CEILING \}'; then
    bad "$M49 does not read COSTCREW_CEILING from stack-wiring, or reads it optionally (no default ships; the pod must not start without a figure)"
  fi
  # The crew runs on its schedule (the 2026-09-03 decision); the cadence switch and the ceiling bound it.
  if ! printf '%s\n' "$live" | grep -qE '^[[:space:]]*suspend:[[:space:]]*false[[:space:]]*$'; then
    bad "$M49 does not run the crew on its schedule: the CronJob must set suspend: false (the 2026-09-03 decision)"
  fi
fi

# The text the launchers, the README and CLAUDE.md print about the crew must agree with the manifest. A line
# saying the crew ships, stays or is suspended is stale while the manifest runs it.
for f in cloud/gcp/deploy-gcp.sh cloud/aws/deploy-aws.sh README.md CLAUDE.md; do
  if [ ! -f "$f" ]; then
    bad "$f is absent: its CostCrew text is measured NOTHING"
    continue
  fi
  stale=$(grep -n -i -E '(ships|stays|is|are) (\*\*)?suspended(\*\*)?' "$f" || true)
  if [ -n "$stale" ]; then
    bad "$f says the crew is suspended, but manifests/49-costcrew.yaml runs it on its schedule: $(printf '%s' "$stale" | head -1 | cut -c1-120)"
  fi
done

if [ "$fail" -gt 0 ]; then
  printf '%d problem(s). See CLAUDE.md invariant 66.\n' "$fail"
  exit 1
fi
echo "OK: the CostCrew ceiling is validated before anything is installed in all three launchers, written after the last apply -k, and read by the crew without a default; the crew CronJob runs on its schedule."
