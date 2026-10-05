# @decided 2026-10-05: every TOKENFUSE_MCP_KEYS or TOKENFUSE_CLIENT_KEYS
# example in this repository is checked against the split tokenfuse actually
# makes, and the key id is a bare name. CLAUDE.md invariant 33.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this
# repository has no runner and no binding gate yet, so the binding is by eye.
Feature: a client key example splits the way tokenfuse splits it

  tokenfuse reads TOKENFUSE_MCP_KEYS and TOKENFUSE_CLIENT_KEYS with one parser,
  which splits each comma-separated entry on its LAST colon, because a secret
  may contain colons. An agent:// id after the colon therefore becomes part of
  the secret: the broker starts, and the caller's real secret is refused 401.

  Scenario: the README example goes back to an agent:// key id
    Given the README shows TOKENFUSE_MCP_KEYS with the bare key id broker-caller
    When the example is changed to end in agent://acme.example/broker-caller
    Then client-key-ids-are-bare.sh fails, naming README.md, the line and the split tokenfuse would make
    # -> gates-have-teeth.sh "client-key-ids: the README example goes back to an agent:// key id"

  Scenario: the manifest 52 example goes back to an agent:// key id
    Given manifests/52-tokenfuse-mcp-broker.yaml shows the same example in its header
    When that example is changed to end in an agent:// id
    Then client-key-ids-are-bare.sh fails and names the key id //acme.example/broker-caller
    # -> gates-have-teeth.sh "client-key-ids: the manifest 52 example goes back to an agent:// key id"

  Scenario: an example written as a YAML env entry is judged too
    Given a tracked file sets TOKENFUSE_CLIENT_KEYS or TOKENFUSE_MCP_KEYS as a YAML name and value pair
    When the value's key id is an agent:// id, in flow form or in block form
    Then client-key-ids-are-bare.sh fails and names the key id it read
    # -> gates-have-teeth.sh "client-key-ids: a YAML flow env entry carries an agent:// key id"
    # -> gates-have-teeth.sh "client-key-ids: a YAML block env entry carries an agent:// key id"

  Scenario: a secret that contains colons is not a fault
    Given an example whose secret is sk-proj:abc:def and whose key id is broker-caller
    When client-key-ids-are-bare.sh runs
    Then it passes, because the last colon still separates the secret from a bare key id
    # -> gates-have-teeth.sh "client-key-ids: a secret with colons and a bare key id (must pass)"

  Scenario: no literal example left to judge
    Given every example is replaced by a shell variable
    When client-key-ids-are-bare.sh runs
    Then it fails saying it measured nothing, never OK
    # -> gates-have-teeth.sh "client-key-ids: no literal example left to judge"
