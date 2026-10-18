# @decided 2026-10-18 (paraphrased): wardryx 2.0.0 refuses a viewer key on the two routes the
# gateway, the MCP broker and scopyx call on every governed request, so the policy-plane key
# those callers present is an enforcement point's role, pep. A stack-keys Secret minted before
# that release keeps the gateway's entry as viewer, and a re-run never rewrites a Secret, so the
# installers migrate that one entry on stdin before the planes are applied. Each scenario is
# bound by name to a case in scripts/gates-have-teeth.sh.
Feature: the gateway's policy-plane key is a pep, on a new cluster and on one installed again

  Scenario: a fresh cluster mints the gateway's policy-plane key as a pep
    Given install.sh writes the stack-keys Secret of a new cluster
    When the gateway's entry is minted as viewer again
    Then wardryx-gateway-key-is-pep.sh fails, because the gateway's calls would be refused
    # -> gates-have-teeth.sh "wardryx-key-is-pep: a fresh secret mints the gateway's key as viewer again"

  Scenario: the aws installer mints the same key the same way
    Given the aws installer writes the same Secret
    When it mints the gateway's entry as viewer
    Then wardryx-gateway-key-is-pep.sh fails, because the three installers would disagree
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the aws installer mints the gateway's key as viewer again"

  Scenario: a site's gateway added to a hub is a pep
    Given a hub adds a site whose gateway asks the hub's wardryx for decisions
    When the hub writes the new site's entry as viewer
    Then wardryx-gateway-key-is-pep.sh fails
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the hub gives a site's gateway viewer again"

  Scenario: the migration rewrites a key that is not the gateway's
    Given a stack-keys Secret holds another viewer entry beside the gateway's
    When the transform rewrites every viewer entry
    Then wardryx-gateway-key-is-pep.sh fails, because another principal's role would change
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the transform rewrites every key, not the gateway's"

  Scenario: the migration changes the gateway's secret
    Given the gateway's secret is what the gateway, the broker and scopyx present
    When the transform writes a different secret into the entry
    Then wardryx-gateway-key-is-pep.sh fails, because every caller would be refused
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the transform changes the gateway's secret"

  Scenario: an existing cluster is migrated by the aws installer too
    Given an existing stack-keys Secret keeps the gateway's entry as viewer
    When the aws installer no longer runs the migration
    Then wardryx-gateway-key-is-pep.sh fails and names the installer
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the migration is not in the aws installer"

  Scenario: the migration never puts a key on a command line
    Given a key must not appear in a process table
    When the migration passes the new spec as an argument to kubectl
    Then wardryx-gateway-key-is-pep.sh fails
    # -> gates-have-teeth.sh "wardryx-key-is-pep: the migration writes the key on the command line"

  Scenario: the manifests still pin the old wardryx
    Given the gateway's key moves with the wardryx that reads it
    When the wardryx image goes back to v1.5.0
    Then wardryx-gateway-key-is-pep.sh fails
    # -> gates-have-teeth.sh "wardryx-key-is-pep: a pin moves back to the old wardryx"

  Scenario: a reworded comment is not a fault
    Given the installer explains the role beside the key
    When the explanation is reworded and its meaning kept
    Then wardryx-gateway-key-is-pep.sh still passes
    # -> gates-have-teeth.sh "wardryx-key-is-pep: a reworded comment is not a fault"
