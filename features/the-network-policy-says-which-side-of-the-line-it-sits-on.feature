# @claude 2026-11-04, from the task that opened this change (the debt G2.3 in estate-gates' GAPS.md): the NetworkPolicy
# protects the stack's own planes, the customer's agents run outside its namespace and are not confined by it, and the
# header and the README must say so. The task names no owner decision, so nothing here is marked @decided.
# Bound by name to the teeth cases "network-policy-names-its-boundary: ..." in scripts/gates-have-teeth.sh, and to the
# measured run in evidence/agent-confinement-k3d/ (CLAUDE.md invariant 77).
Feature: the NetworkPolicy says which side of the line it sits on, and what it says matches the labels the cluster has

  Scenario: the header says the policy governs the stack's namespace and not the customer's agents
    Given manifests/30-network-policy.yaml
    When its header drops the boundary paragraph, or carries the old claim that read as confining agents
    Then the gate refuses it
    -> network-policy-names-its-boundary: the header drops the boundary paragraph
    -> network-policy-names-its-boundary: the old claim comes back into the header
    -> network-policy-names-its-boundary: a harmless comment in the header is not a fault

  Scenario: the README has the same statement, with the same ports and files
    Given the README's section on what the NetworkPolicy confines
    When the section is gone, names a path that does not exist, or states another port than the policy opens
    Then the gate refuses it
    -> network-policy-names-its-boundary: the README section is gone
    -> network-policy-names-its-boundary: the README drops the overlay
    -> network-policy-names-its-boundary: the README states another port than 58 opens
    -> network-policy-names-its-boundary: the README names a file that does not exist
    -> network-policy-names-its-boundary: another sentence in the README section is not a fault

  Scenario: one label means the same thing everywhere
    Given the label that manifests/58-agent-tokens-network.yaml selects
    When the header, the README, the overlay's pod, the example pod or the proof script names another one
    Then the gate refuses it, because an agent pod that carries a label no policy selects is not confined
    -> network-policy-names-its-boundary: 58 selects a renamed label
    -> network-policy-names-its-boundary: the overlay's pod loses the label
    -> network-policy-names-its-boundary: the example pod carries another label
    -> network-policy-names-its-boundary: the README names another label
    -> network-policy-names-its-boundary: the proof script names another label

  Scenario: the proof script probes what the policy opens, and nothing else is called open
    Given the proof script agent-tokens/confine-check.sh
    When the policy opens a third path the script does not probe, or the script drops a path the policy opens
    Then the gate refuses it
    -> network-policy-names-its-boundary: 58 opens a path the proof script does not probe
    -> network-policy-names-its-boundary: the proof script drops the gateway row

  Scenario: the overlay stays optional
    Given the default apply set and the launchers
    When the overlay is added to the default kustomization or a launcher applies it
    Then the gate refuses it
    -> network-policy-names-its-boundary: the overlay is added to the default apply set
    -> network-policy-names-its-boundary: a launcher applies the overlay

  Scenario: a run the README cites is on record and ended green
    Given the measured run in evidence/agent-confinement-k3d
    When its output records a failed run, or is gone
    Then the gate refuses it
    -> network-policy-names-its-boundary: the cited run recorded a failure
    -> network-policy-names-its-boundary: the cited run is gone

  Scenario: a subject that is gone is not a pass
    Given the gate
    When the agent-pod policy or the overlay is deleted
    Then it says it measured nothing
    -> network-policy-names-its-boundary: the agent-pod network is gone
    -> network-policy-names-its-boundary: the overlay is gone
