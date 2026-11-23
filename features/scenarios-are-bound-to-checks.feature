# @decided 2026-11-23 (paraphrased, the stack revision wave): every repository whose scenarios a person
# reads instead of the code has a gate that holds the binding both ways, as the other repositories of the
# estate already do. `@claude 2026-11-23`: the bindings here had five shapes, so the gate resolves each
# shape against what it names (CLAUDE.md invariant 92). Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name; scripts/features-are-bound.sh holds the binding.
Feature: every scenario is bound to a check that exists, and every binding names one

  A scenario is what a person reads instead of a diff. It is worth that only while something that
  runs stands under it, and a renamed check leaves the scenario reading true over nothing.

  Scenario: a scenario with no binding
    Given a scenario under features/
    When it carries no binding line
    Then features-are-bound.sh fails and names the scenario
    # -> gates-have-teeth.sh "features-are-bound: a scenario loses its only binding"

  Scenario: a binding to a teeth case that was renamed
    Given a scenario bound to a case in gates-have-teeth.sh
    When the binding names a case the harness no longer has
    Then features-are-bound.sh fails, because the scenario names a test that is gone
    # -> gates-have-teeth.sh "features-are-bound: a binding names a teeth case that was renamed"

  Scenario: a binding in a shape the gate cannot check
    Given the binding shapes the gate knows how to resolve
    When a binding takes another shape
    Then features-are-bound.sh fails rather than pass a binding it could not check
    # -> gates-have-teeth.sh "features-are-bound: a binding in a form the gate does not know"

  Scenario: a binding to a check inside another gate
    Given scenarios bound to a case of hostkeys-are-verified.sh or a check of typed-mode-is-honest.sh
    When the case or the check named is not in that script
    Then features-are-bound.sh fails and names what is missing
    # -> gates-have-teeth.sh "features-are-bound: a case binding names a case its script does not have"
    # -> gates-have-teeth.sh "features-are-bound: a check binding names a check its script does not run"

  Scenario: a binding to a recorded run
    Given a scenario bound to a file under evidence/
    When the file is not tracked by this repository
    Then features-are-bound.sh fails, because a reader of a clone would find nothing there
    # -> gates-have-teeth.sh "features-are-bound: an evidence binding names a file this repository does not track"

  Scenario: no feature file at all
    Given features/ holds no feature file
    When the gate runs
    Then it says it measured nothing and fails
    # -> gates-have-teeth.sh "features-are-bound: every feature file is gone, which must say it measured nothing"

  Scenario: a scenario reworded
    Given a scenario keeps its binding
    When its Then line is reworded
    Then the gate still passes
    # -> gates-have-teeth.sh "features-are-bound: a Then line reworded (must pass)"
