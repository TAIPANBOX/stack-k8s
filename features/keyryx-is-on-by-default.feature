# @decided 2026-10-19 (paraphrased): Keyryx is part of every install, and the record and the approvals are signed
# through it. `@claude 2026-10-19`: the choices the decision did not make are in CLAUDE.md invariant 69. Scenarios
# are bound to cases in scripts/gates-have-teeth.sh by name; this repository has no runner, so the binding is by eye.
Feature: Keyryx is installed by default, and the opt-out is named

  Custody holds the keys that sign the record and the approvals. A launcher install turns it on; the operator who
  does not want it says so, and is told that it is the weaker setting.

  Scenario: a launcher install turns Keyryx on
    Given an operator runs a launcher without any Keyryx flag
    When the deploy reaches its Keyryx step after the apply
    Then custody, the witness and both signers are installed, and wardryx and the record-seal are rolled out
    # -> gates-have-teeth.sh "keyryx: Keyryx is off by default in deploy.sh"

  Scenario: the opt-out removes the signers and keeps the keys
    Given an operator runs a launcher with --without-keyryx
    When the deploy reaches its Keyryx step
    Then the signers are removed and the record is not signed by custody; custody and its keys stay
    # -> gates-have-teeth.sh "keyryx: the opt-out never removes the signers"

  Scenario: the record is sealed under the key custody holds
    Given Keyryx is on
    When the record-seal runs
    Then it signs each root through custody under trailryx-root, and no attestation directory is set
    # -> gates-have-teeth.sh "keyryx: the record-seal stops signing through keyryx"
