# @decided 2026-10-17 (paraphrased): close the agent-security findings of the 2026-10-17 review,
# starting with the defaults; here, tokenfuse's MCP broker refuses a raw secret in tool arguments,
# refuses a tool listing its scanner flags, and asks the policy plane about every tool call,
# failing closed, as stack-single's broker does. Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name, by eye.
Feature: the MCP broker blocks raw secrets and asks the policy plane about every tool call

  The broker fronts the typed plane. Left to tokenfuse's own defaults it forwards a raw secret it
  finds in tool arguments, passes a tool listing its scanner flags with a log line, and on this
  launcher it asked wardryx nothing unless the typed risk signal was on, so a tool the policy
  denied was called anyway. Now it blocks the first two, judges every call, and refuses when the
  policy plane cannot answer. Pinning tool definitions needs a lock file somebody approved and
  stays off.

  Scenario: a raw secret in tool arguments is forwarded again
    Given manifest 52 sets TOKENFUSE_MCP_DLP to block
    When it sets shadow, or nothing
    Then broker-blocks-raw-secrets.sh fails, because the upstream would receive the secret
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: secrets in tool arguments go back to shadow"
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: TOKENFUSE_MCP_DLP goes missing"

  Scenario: a flagged tool listing is passed with a log line
    Given manifest 52 sets TOKENFUSE_MCP_SCAN to block
    When it sets warn
    Then broker-blocks-raw-secrets.sh fails
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: the tool scan only warns"

  Scenario: the broker stops asking the policy plane, or fails open
    Given the broker asks wardryx in enforce and fails closed
    When its mode becomes off, its fail mode open, its key optional, or no NetworkPolicy lets it out to wardryx
    Then broker-blocks-raw-secrets.sh fails
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: the broker's policy hook is off"
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: the broker fails open"
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: the broker's policy key becomes optional"
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: the broker cannot reach wardryx"

  Scenario: without the risk signal the broker asks wardryx itself
    Given typed/mode.sh moves the broker's URL to the proxy only with --typed-risk-signal
    When the manifest points it at the proxy by default
    Then typed-mode-is-honest.sh fails
    # -> gates-have-teeth.sh "typed-mode-is-honest: the broker asks the proxy without the flag"

  Scenario: the image the manifest pins is the judge
    Given the gate runs the pinned image with 52's switches and no network
    When the image cannot be had
    Then broker-blocks-raw-secrets.sh fails rather than trusting the manifest alone
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: the broker image cannot be pulled"

  Scenario: a comment, and a gate with nothing to judge
    Given the gate passes on this tree
    When a comment in the broker's block is reworded, or manifest 52 is gone
    Then broker-blocks-raw-secrets.sh passes on the comment and says it measured nothing otherwise
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: a comment in the broker's block is reworded"
    # -> gates-have-teeth.sh "broker-blocks-raw-secrets: no broker left to judge"
