# @decided 2026-10-04, from the estate audit (wave 1): tokenfuse v1.5.0 gives the
# gateway an operator ceiling on the budget a run may carry, and the launchers set
# it. `@claude 2026-10-04`: the default 5.00 equals tokenfuse's own built-in run
# budget, so an ordinary run is unchanged and only a caller-declared larger
# budget is clamped. Scenarios are bound to cases in scripts/gates-have-teeth.sh
# by name; this repository has no runner and no binding gate, so the binding is
# by eye.
Feature: the gateway caps what a run may declare for its own budget

  A run's budget used to come from the header the agent sends, and the next call
  of an open run could widen it. With no client keys, no identity map and no unit
  caps the per-run ceiling was whatever the agent said. The gateway now reads
  TOKENFUSE_MAX_RUN_BUDGET_USD and lowers a budget that came from the caller, a
  policy default or the built-in default to it, on every call. It does not lower a
  budget the Cloud sets.

  Scenario: the gateway container loses the ceiling
    Given the gateway container sets TOKENFUSE_MAX_RUN_BUDGET_USD to 5.00
    When the variable is removed
    Then run-budget-ceiling-is-set.sh fails and says a caller chooses its own per-run budget
    # -> gates-have-teeth.sh "run-budget-ceiling-is-set: the gateway container loses the ceiling"

  Scenario: the ceiling is a figure the gateway refuses to start on
    Given the gateway container sets the ceiling
    When the value is a word, or zero
    Then run-budget-ceiling-is-set.sh fails saying it is not a positive decimal
    # -> gates-have-teeth.sh "run-budget-ceiling-is-set: the ceiling is a word the gateway refuses" and "run-budget-ceiling-is-set: the ceiling is zero"

  Scenario: the default drifts from tokenfuse's own
    Given the shipped ceiling is 5.00, the gateway's own built-in run budget
    When it is changed to another figure without changing the invariant
    Then run-budget-ceiling-is-set.sh fails saying it is not the documented default
    # -> gates-have-teeth.sh "run-budget-ceiling-is-set: the ceiling drifts from the documented default"

  Scenario: the ceiling is read from somewhere other than a literal
    Given a ceiling is a figure somebody chose
    When the container takes it from a ConfigMap key marked optional
    Then run-budget-ceiling-is-set.sh fails, because an absent optional key would leave the gateway with no ceiling and say nothing
    # -> gates-have-teeth.sh "run-budget-ceiling-is-set: the ceiling comes from somewhere other than a literal"

  Scenario: the control plane carries the ceiling too
    Given tokenfuse does not clamp a budget the Cloud sets
    When the control plane container is given the variable
    Then run-budget-ceiling-is-set.sh fails, because the copy would read as if the Cloud's budgets were clamped
    # -> gates-have-teeth.sh "run-budget-ceiling-is-set: the control plane carries the ceiling"

  Scenario: the one copy of the validation goes loose or tight
    Given the three launchers take the figure through budget/ceiling.sh
    When it accepts zero, a sign or an exponent, or refuses a figure with six decimals
    Then run-budget-ceiling-is-set.sh runs it over both kinds of figure and fails naming the one it got wrong
    # -> gates-have-teeth.sh "run-budget-ceiling-is-set: budget/ceiling.sh accepts zero", "run-budget-ceiling-is-set: budget/ceiling.sh accepts a sign and an exponent" and "run-budget-ceiling-is-set: budget/ceiling.sh refuses a figure the gateway accepts"

  Scenario: a deploy path stops checking the figure before it installs
    Given every deploy path runs budget/ceiling.sh check before its install step
    When one stops
    Then run-budget-ceiling-is-set.sh fails, because a refused figure would surface as a gateway in CrashLoopBackOff after the install
    # -> gates-have-teeth.sh "run-budget-ceiling-is-set: a deploy path stops checking the figure before it installs"

  Scenario: a deploy path stops taking the flag
    Given every deploy path parses --run-budget-ceiling
    When one stops
    Then deploy-flags-agree.sh fails naming the path
    # -> gates-have-teeth.sh "deploy-flags-agree: a deploy path stops taking --run-budget-ceiling"

  Scenario: the flag is applied before the apply that reverts it
    Given apply -k puts the declared 5.00 back over anything set before it
    When a deploy path sets the figure before its apply -k
    Then deploy-flags-agree.sh fails saying the flag is silently useless
    # -> gates-have-teeth.sh "deploy-flags-agree: the ceiling is applied BEFORE the apply that reverts it"

  Scenario: the flag is accepted and applies nothing
    Given a deploy path parses --run-budget-ceiling
    When its set-env line no longer names the variable
    Then deploy-flags-agree.sh fails saying the flag is accepted and does nothing
    # -> gates-have-teeth.sh "deploy-flags-agree: the ceiling flag is accepted and applies nothing"

  Scenario: a comment next to the ceiling changes
    Given the manifest is correct
    When only a comment changes
    Then run-budget-ceiling-is-set.sh still passes
    # -> gates-have-teeth.sh "run-budget-ceiling-is-set: a comment next to the ceiling changes"

  Scenario: there is no gateway to judge
    Given the gate finds the gateway by its image and command
    When no container matches
    Then run-budget-ceiling-is-set.sh says it measured nothing instead of reporting OK
    # -> gates-have-teeth.sh "run-budget-ceiling-is-set: no gateway container left to judge" and "run-budget-ceiling-is-set: budget/ceiling.sh taken away"
