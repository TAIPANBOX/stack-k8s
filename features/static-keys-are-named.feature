# @decided 2026-10-19 (paraphrased, decision D8): a static client key is admitted only from a named list,
# and each name has a reason. The operator's own additions come from one ConfigMap, not a manifest edit.
# Bound by name to the teeth cases "static-keys-are-named: ..." in scripts/gates-have-teeth.sh
# (CLAUDE.md invariant 62).
Feature: a static client key is admitted only from the named allow-lists

  Scenario: a key that the stack does not mint cannot join the gateway's list
    Given the gateway's stack list
    When an id joins it that no deploy mints
    Then the gate refuses it
    -> static-keys-are-named: an id that the stack does not mint joins the list

  Scenario: every listed key has a reason beside it
    Given the gateway's stack list
    When an id loses its reason, or a minted key leaves the list with none
    Then the gate refuses it
    -> static-keys-are-named: a listed id loses its reason
    -> static-keys-are-named: a minted key is dropped from the list without a written reason

  Scenario: the operator's additions are read from a ConfigMap that is not optional
    Given the gateway reads the operator's list
    When that read is optional, or the list is written as a literal
    Then the gate refuses it
    -> static-keys-are-named: the operator's list is read optionally
    -> static-keys-are-named: the list is written as a literal instead of the two parts

  Scenario: no other workload and no other door names a list
    Given the costcrew manifest or the broker
    When either sets a static-key list of its own
    Then the gate refuses it
    -> static-keys-are-named: a costcrew manifest sets a second list
    -> static-keys-are-named: the broker admits an id outside its own key list

  Scenario: the deploy keeps the operator's list when it exists
    Given a deploy
    When it stops creating the list
    Then the gate refuses it
    -> static-keys-are-named: the deploy stops creating the operator's list
    -> static-keys-are-named: the operator's list is written by hand, not kept when present

  Scenario: a comment about the list is not a fault
    Given a comment that describes how the operator adds to the list
    When the gate reads the manifest
    Then it passes
    -> static-keys-are-named: a comment naming the list is not a fault
