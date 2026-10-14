# Evidence: go-to-market-2026-09/evidence/gcp-2026-10-14b/logs/D/d7-* (GCP, stack-k8s v1.1.44, 2026-10-14):
# a two-minute cut of the node under the policy store's engine left every replica in error, and the store
# refused to start on the volume afterwards (GOTCHAS 127). Which replica sat on which node is not in that
# evidence; the live partition rerun decides it.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name.
# They check the text that configures the volume, not a running partition.
Feature: the policy store keeps a readable copy of its data when the node under its engine is cut off

  The policy store holds the approvals and freezes the gateway acts on. Its volume
  is replicated by Longhorn, and the default class the store used to get does not
  keep a copy on the node the store runs on, switches off the revision counter that
  tells replicas apart after a fault, forgets a failed replica after 30 minutes and
  deletes the data with the claim. Each of those can leave the store with nothing
  it can read, and a volume with nothing it can read is one the kubelet will try to
  format.

  Scenario: the store's claim asks for its own class
    Given the policy-db StatefulSet creates its one claim from a template
    When the manifests are read
    Then policy-store-survives-a-partition.sh fails when the claim names no class
    # -> gates-have-teeth.sh "policy-store-survives-a-partition: the policy-db claim names no class"

  Scenario: the store's claim asks for the storage class of the shared event log
    Given the policy-db claim names the stack-policy class
    When it names the RWX class instead
    Then policy-store-survives-a-partition.sh fails and names the class it found
    # -> gates-have-teeth.sh "policy-store-survives-a-partition: the policy-db claim names the RWX class"

  Scenario: an installer keeps no readable copy on the store's own node
    Given each installer that installs Longhorn creates the stack-policy class
    When one of them leaves data locality disabled
    Then policy-store-survives-a-partition.sh fails and names the parameter
    # -> gates-have-teeth.sh "policy-store-survives-a-partition: an installer leaves data locality disabled"

  Scenario: an installer switches the revision counter off
    Given each installer that installs Longhorn creates the stack-policy class
    When one of them turns the revision counter off
    Then policy-store-survives-a-partition.sh fails and names the parameter
    # -> gates-have-teeth.sh "policy-store-survives-a-partition: an installer turns the revision counter off"

  Scenario: an installer forgets a failed replica after 30 minutes
    Given each installer that installs Longhorn creates the stack-policy class
    When one of them keeps a failed replica for 30 minutes
    Then policy-store-survives-a-partition.sh fails and names the parameter
    # -> gates-have-teeth.sh "policy-store-survives-a-partition: an installer keeps a failed replica 30 minutes"

  Scenario: an installer lets the class delete its data with the claim
    Given each installer that installs Longhorn creates the stack-policy class
    When one of them sets the reclaim policy to Delete
    Then policy-store-survives-a-partition.sh fails and names the reclaim policy
    # -> gates-have-teeth.sh "policy-store-survives-a-partition: an installer lets the class delete its data"

  Scenario: an installer makes the new class the default
    Given the default class stays Longhorn's, so no unnamed claim moves to the new class
    When an installer marks stack-policy as the default
    Then policy-store-survives-a-partition.sh fails and says the class is the default
    # -> gates-have-teeth.sh "policy-store-survives-a-partition: an installer marks the class as the default"

  Scenario: an installer turns automatic salvage off
    Given Longhorn salvages a volume on its own when all its replicas are faulty
    When an installer patches that setting to false
    Then policy-store-survives-a-partition.sh fails and says automatic salvage is off
    # -> gates-have-teeth.sh "policy-store-survives-a-partition: an installer turns automatic salvage off"

  Scenario: an installer that never writes the class is named
    Given each installer that installs Longhorn creates the stack-policy class
    When one of them stops writing it
    Then policy-store-survives-a-partition.sh fails and names the installer
    # -> gates-have-teeth.sh "policy-store-survives-a-partition: an installer never writes the class"

  Scenario: no Longhorn installer left to read
    Given the check finds the installers by the Longhorn release they apply
    When none is left
    Then policy-store-survives-a-partition.sh says it measured nothing rather than passing
    # -> gates-have-teeth.sh "policy-store-survives-a-partition: no Longhorn installer left"

  Scenario: the same class written with different spacing is not a fault
    Given the class is read as settings, not as text
    When an installer writes the same value with extra spaces
    Then policy-store-survives-a-partition.sh still passes
    # -> gates-have-teeth.sh "policy-store-survives-a-partition: the class reworded in spacing is not a fault"
