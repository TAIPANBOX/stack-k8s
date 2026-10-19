# @decided 2026-10-19, from the security review's wave 3: where a document described a protection the
# product did not give by default, the product gives it. A risk signal that never arrives must not read
# as a harmless call. `@claude 2026-10-19`: the choices the decision did not make are in CLAUDE.md
# invariant 65. Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this repository has
# no runner and no binding gate, so the binding is by eye.
Feature: a brokered tool call with no risk signal waits for a person, only when the flag asked for it

  With --typed-risk-signal the policy plane holds a call that carries no action.risk_class signal, and
  holds nothing a signal answers outside the three hold classes. Without the flag there is no hold.

  Scenario: the flag is on and the proxy cannot answer a call
    Given --typed-risk-signal is passed with a typed mode that answers
    When a brokered tool call reaches wardryx with no action.risk_class signal
    Then the policy plane holds the call for a person to approve
    # -> gates-have-teeth.sh "risk-hold: the hold source is required, so the plane cannot start without a hold"

  Scenario: the flag is off
    Given --typed-risk-signal is not passed
    When the launchers render the typed plane
    Then no hold rule exists, and a run that removes an earlier hold restarts the policy plane
    # -> gates-have-teeth.sh "risk-hold: the hold is printed without the flag"

  Scenario: the hold never denies
    Given the flag is on
    When the hold rule is rendered
    Then it carries no key that could deny, and it names only destructive, external_send and financial
    # -> gates-have-teeth.sh "risk-hold: the hold carries a key that could deny"

  Scenario: a read-only call is not held by the hold
    Given the flag is on
    When the stub or a model answers a call as read_only
    Then the hold does not fire, because read_only is not one of its classes
    # -> gates-have-teeth.sh "risk-hold: the hold also holds read-only calls"

  Scenario: the policy plane reads the hold at start
    Given the flag is on
    When the three launchers finish their apply
    Then wardryx is restarted, so the running pod loads the rule
    # -> gates-have-teeth.sh "risk-hold: the AWS launcher applies the hold and restarts a different plane"

  Scenario: a launcher forgets to clear the hold
    Given an earlier run applied the hold
    When the GCP launcher runs without the flag
    Then the ConfigMap is deleted and the policy plane restarted
    # -> gates-have-teeth.sh "risk-hold: the GCP launcher does not clear the hold without the flag"
