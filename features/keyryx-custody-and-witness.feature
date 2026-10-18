# Wave 2, L2: Keyryx on the cluster. Paraphrased from the decisions of 2026-10-18
# (custody and witness are separate, the root key is never in an environment,
# only consumers reach custody). Each scenario is bound to a teeth case in
# scripts/gates-have-teeth.sh by its name, checked by hand.

Feature: Keyryx custody and its witness on the cluster

  Scenario: A root key is copied into memory by its own init container and reaches no environment
    Given the custody Deployment mounts its root key Secret
    When the manifests are read
    Then no secretKeyRef, secretRef or environment variable carries key material
    And the Secret is mounted only by the init container root-key-copy
    # @teeth: keyryx-root-is-not-in-env: a root key read through secretKeyRef

  Scenario: The witness shares nothing with custody but the image
    Given custody and the witness are two Deployments
    When their service accounts, uids, state claims and root key Secrets are compared
    Then they differ on every one of them
    # @teeth: witness-is-separate: witness mounts custody's root key Secret

  Scenario: The witness reads the event streams and cannot write them
    Given the witness mounts the event streams
    When the mount is read
    Then it is read only and the witness's alerts go to its own volume
    # @teeth: witness-is-separate: witness event mount not read only

  Scenario: Only a labelled consumer reaches custody
    Given custody's NetworkPolicy
    When the pods it admits are read
    Then only pods labelled keyryx-consumer: "true" reach port 4340
    # @teeth: keyryx-reaches-only-consumers: custody admits every pod

  Scenario: A Keyryx pod has no route out
    Given custody's and the witness's NetworkPolicies
    When their egress is read
    Then neither declares an egress rule
    # @teeth: keyryx-reaches-only-consumers: custody declares egress
