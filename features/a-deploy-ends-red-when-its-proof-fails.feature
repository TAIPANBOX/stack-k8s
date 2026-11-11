# @decided 2026-11-11 (paraphrased): the README says a deploy without a trust domain ends red, so a deploy
# whose own proof failed must end red. @claude 2026-11-11: the three deploy scripts threw the exit code of
# verify.sh and security-tests.sh away with `|| true`, printed Done. and exited 0.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this repository has no runner and no
# binding gate for this file, so the binding is by eye.
Feature: a deploy whose own proof failed ends red

  Scenario: verify.sh fails
    Given a deploy has installed the stack
    When verify.sh exits non-zero
    Then the deploy still prints the way in, names verify.sh as failed in place of Done., and exits non-zero
    # -> gates-have-teeth.sh "deploy-ends-red: verify.sh is thrown away with || true again"
    # -> gates-have-teeth.sh "deploy-ends-red: a failed proof still ends with the Done. headline"
    # -> gates-have-teeth.sh "deploy-ends-red: the closing check no longer exits non-zero"

  Scenario: security-tests.sh fails
    Given a deploy has installed the stack
    When security-tests.sh exits non-zero
    Then the summary names security-tests.sh and the deploy exits non-zero
    # -> gates-have-teeth.sh "deploy-ends-red: security-tests.sh is thrown away with || true again"
    # -> gates-have-teeth.sh "deploy-ends-red: the summary stops naming security-tests.sh"

  Scenario: a failed proof does not skip the way in
    Given the operator needs the tunnel and the key note to fix what failed
    When a proof fails
    Then nothing exits before they are printed
    # -> gates-have-teeth.sh "deploy-ends-red: the deploy exits before the way in is printed"

  Scenario: both proofs pass
    Given verify.sh and security-tests.sh both exit zero
    When the deploy finishes
    Then it prints the plain Done. and exits zero, as before
    # -> gates-have-teeth.sh "deploy-ends-red: a reworded comment is not a fault"
