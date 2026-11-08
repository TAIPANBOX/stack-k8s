# @decided 2026-11-08 (paraphrased): the fire drills get a key of their own for TokenFuse's MCP broker,
# the scheduled drill job carries it, the tokenfuse images move to v1.24.0 and mockryx to v0.5.0, and this
# repository's CI shows mockryx's broker drills passing against the broker as this repository configures it.
# @claude 2026-11-08: the broker asks the gateway's tool-call check with the caller's own static key, so each
# key the broker admits is a gateway key of the same id; the typed door's broker-caller was refused there.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name, and scripts/broker-drills-pass.sh
# checks the binding both ways.
Feature: the drills reach the MCP broker with a key of their own, and pass

  mockryx v0.5.0 sends the MCP broker a key of its own, and the broker admits it only from its static list.
  The broker then asks the gateway's tool-call check about every tool call with that same key, so a key the
  gateway does not hold is refused there and the call is refused closed. The drills' broker key and the
  typed door's caller key are therefore one secret under one id at both doors.

  Scenario: the drills run against the broker and pass
    Given a broker, a gateway and wardryx as this repository pins and configures them
    When the drills-broker job runs mockryx's broker drills with the drills' own key
    Then a raw secret in tool arguments is refused, a tool call nothing grants is held, a drill identity goes through, and personal data reads as the PII mode makes it
    # -> gates-have-teeth.sh "broker-drills-pass: the broker forwards raw secrets again (run)"
    # -> gates-have-teeth.sh "broker-drills-pass: the broker's door gets a fresh drills-broker, not the gateway's (run)"

  Scenario: the gateway does not hold the drills' broker key
    Given the broker relays the caller's own key to the gateway's tool-call check
    When drills-broker leaves the gateway's static list, or the broker stops admitting it
    Then broker-drills-pass.sh fails, because every drill past the secret scan would be refused closed
    # -> gates-have-teeth.sh "broker-drills-pass: drills-broker leaves the gateway's list"
    # -> gates-have-teeth.sh "broker-drills-pass: the broker stops admitting drills-broker"

  Scenario: the typed door's own caller is refused at the tool-call check
    Given an agent calls the typed door with broker-caller and names its run
    When broker-caller is not a gateway key on the gateway's static list
    Then broker-drills-pass.sh fails, because the broker answers "the taint gate answered 401" to every such call
    # -> gates-have-teeth.sh "broker-drills-pass: broker-caller leaves the gateway's list (the typed door refused at the tool-call check)"

  Scenario: the drill job is not the job that runs the broker drills
    Given the drills-broker CronJob runs the pinned mockryx on /scenarios/mcp with the key from drills-broker-key
    When it runs the gateway drills, reads its key from a path nothing mounts, falls back to a mockryx with no broker key, or is gone
    Then broker-drills-pass.sh fails
    # -> gates-have-teeth.sh "broker-drills-pass: the CronJob runs the gateway drills"
    # -> gates-have-teeth.sh "broker-drills-pass: the drill reads its key from a path nothing mounts"
    # -> gates-have-teeth.sh "broker-drills-pass: the CronJob falls back to a mockryx with no broker key"
    # -> gates-have-teeth.sh "broker-drills-pass: the CronJob is gone"

  Scenario: the drill reaches the broker and nothing else
    Given two NetworkPolicies open the drills-broker pod to the broker on 4200
    When the broker also admits the gateway drills' pod, or the drill pod may reach another port
    Then broker-drills-pass.sh fails
    # -> gates-have-teeth.sh "broker-drills-pass: the broker admits the gateway drills' pod"
    # -> gates-have-teeth.sh "broker-drills-pass: the drill pod may reach the gateway too"

  Scenario: a comment is not a rule
    Given a comment beside the broker's ingress names the gateway drills' pod
    Then broker-drills-pass.sh passes
    # -> gates-have-teeth.sh "broker-drills-pass: a comment naming the gateway drills beside the broker's ingress"

  Scenario: a cluster on the operator's own keys learns before anything is applied
    Given the gateway's client keys are the operator's and hold no drills-broker or broker-caller
    When a launcher runs
    Then it stops before its first apply and says what to add, instead of leaving a gateway that refuses to start
    # -> gates-have-teeth.sh "broker-drills-pass: a launcher asks the operator's keys after the first apply"
    # -> gates-have-teeth.sh "metered-doors-require-keys: the guard lets the operator's keys through without broker-caller"

  Scenario: a kept broker Secret is kept in step with the gateway
    Given a typed door minted before this release
    When a launcher runs again
    Then the broker gains the gateway's drills-broker, every entry it had stays byte for byte, and a caller whose secret is not the gateway's stops the run
    # -> gates-have-teeth.sh "broker-drills-pass: a launcher never keeps a kept broker Secret in step"
    # -> gates-have-teeth.sh "typed-door-is-minted: door-callers rewrites a kept broker-caller instead of stopping"
    # -> gates-have-teeth.sh "typed-door-is-minted: door-callers drops what the broker Secret held"
    # -> gates-have-teeth.sh "typed-door-is-minted: door-secrets mints the broker a caller the gateway does not hold"

  Scenario: the mint keeps what callers already hold
    Given a cluster minted before this release whose typed door already has a broker-caller
    When the deploy adds the two keys
    Then broker-caller keeps the broker's secret, drills-broker-key holds the gateway's drills-broker, and nothing is printed
    # -> gates-have-teeth.sh "metered-doors-require-keys: the mint stops taking broker-caller from the broker's door"
    # -> gates-have-teeth.sh "metered-doors-require-keys: drills-broker-key is not made"

  Scenario: the scenarios and the cases are bound both ways
    Given every scenario here names a case of scripts/gates-have-teeth.sh, and every case of broker-drills-pass.sh is named here
    When a scenario names a case nothing runs, or a case loses its scenario
    Then broker-drills-pass.sh fails
    # -> gates-have-teeth.sh "broker-drills-pass: a scenario names a case nothing runs"
    # -> gates-have-teeth.sh "broker-drills-pass: a case is named by no scenario"
