# @decided 2026-10-05: the jev and own-model modes with the typed risk signal must
# start with no manual patch, and a pod that mounts a key Secret at a mode that is
# not world-readable must carry a group that can read it, in every typed mode and
# in every manifest. GOTCHAS 117 is the run that found the gap. Scenarios are
# bound to cases in scripts/gates-have-teeth.sh by name; this repository has no
# runner and no binding gate, so the binding is by eye.
Feature: every key a pod mounts is readable by the user the pod runs as

  Kubernetes writes Secret, ConfigMap and projected files owned by root, with the
  pod's fsGroup as the group when it has one. A key mounted at 0440 is therefore
  readable by a non-root container only through fsGroup.

  Scenario: the risk proxy starts in the jev mode
    Given the typed mode is jev and the risk signal is on
    When the proxy pod mounts the jev key Secret at 0440
    Then the pod carries an fsGroup, so the proxy can read the key
    # -> gates-have-teeth.sh "mounted-keys: the risk proxy loses its fsGroup"

  Scenario: the risk proxy starts in the own-model mode with a key
    Given the typed mode is own-model with a key file and the risk signal is on
    When the proxy pod mounts the model key Secret
    Then its mode keeps a group read the pod's fsGroup can use
    # -> gates-have-teeth.sh "mounted-keys: the model key mode drops its group read"

  Scenario: typryx itself keeps reading its key
    Given typryx mounts the same key Secret
    When its pod loses its fsGroup
    Then the gate fails, naming typryx and the volume
    # -> gates-have-teeth.sh "mounted-keys: typryx loses the fsGroup that lets it read its key"

  Scenario: a patch that mounts a restricted key carries its own fsGroup
    Given a kubectl patch body mounts a Secret
    When it sets a mode that is not world-readable and brings no fsGroup
    Then the gate fails, because the target is named elsewhere and cannot be judged here
    # -> gates-have-teeth.sh "mounted-keys: a patch body mounts a key at 0440 with no fsGroup"

  Scenario: a world-readable key needs nothing more
    Given every key is mounted at 0444
    When the proxy has no fsGroup
    Then the gate passes, because it judges the mode and not the presence of fsGroup
    # -> gates-have-teeth.sh "mounted-keys: a world-readable key needs no fsGroup"

  Scenario: the securityContext is read in either YAML spelling
    Given the proxy's securityContext is written as a block instead of a flow mapping
    When it does or does not carry fsGroup
    Then the gate passes or fails accordingly
    # -> gates-have-teeth.sh "mounted-keys: a block-style securityContext with fsGroup is read" and "mounted-keys: a block-style securityContext without fsGroup"

  Scenario: the gate says when it measured nothing
    Given typed/mode.sh, the manifests, or every key Secret mount is gone
    When the gate runs
    Then it fails and says it measured nothing, rather than reporting OK
    # -> gates-have-teeth.sh "mounted-keys: typed/mode.sh taken away", "mounted-keys: no manifests/*.yaml left to read" and "mounted-keys: no typed render mounts a key"
