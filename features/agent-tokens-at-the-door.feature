# @decided 2026-10-17 (paraphrased, wave 1 design 1.3 to 1.7): an agent holds its own short-lived,
# proof-bound token from the cluster's identity, not a shared key, and a stop reaches every door.
# Bound by name to the teeth cases "agent-tokens: ..." in scripts/gates-have-teeth.sh and to the
# measured end-to-end run in evidence/agent-tokens-kind/ (CLAUDE.md invariant 54).
Feature: an agent's own token is the door credential, off by default and stopped in one action

  Scenario: the door is off in every default install
    Given the default manifests
    When the gate reads them
    Then no manifest but the agent-token files names the door, its audience or the registry
    -> agent-tokens: the door is on in the default gateway

  Scenario: the gateway admits only a token whose audience is vouchryx's issuer
    Given the door is turned on
    When the audience is empty or names another service
    Then the gate refuses it, because the door would accept any audience or none
    -> agent-tokens: the gateway door starts with no audience
    -> agent-tokens: the gateway accepts a wider audience than vouchryx's issuer

  Scenario: a stopped agent keeps no access while the revocation list is unreadable
    Given the revocation list fails open or may be older than a minute
    When the gate reads the gateway patch
    Then it refuses the patch
    -> agent-tokens: a stopped agent keeps working while the list is unreadable
    -> agent-tokens: the revocation list may be 300 s old

  Scenario: the registry is data read from a ConfigMap, not a literal in a manifest
    Given vouchryx takes its agent registry from the patch
    When the registry is written as a literal value
    Then the gate refuses it, so a change of agent is a ConfigMap change and not a manifest edit
    -> agent-tokens: vouchryx takes its registry as a literal, not from a ConfigMap

  Scenario: an agent pod holds no Kubernetes API token and no secret
    Given an example agent pod labelled for the network rules
    When its default ServiceAccount token is left on, or its token is for another audience
    Then the gate refuses it
    -> agent-tokens: the example agent keeps the default ServiceAccount token
    -> agent-tokens: the example agent's token is for another audience

  Scenario: agent pods reach vouchryx and the gateway and nothing else
    Given the network rules for agent pods
    When they open egress to the internet
    Then the gate refuses them
    -> agent-tokens: agent pods may reach the open internet

  Scenario: the opt-in refuses before it applies anything
    Given agent-tokens/up.sh
    When it no longer refuses a missing registry before its first write
    Then the gate refuses it
    -> agent-tokens: the opt-in applies before it refuses

  Scenario: a comment naming the switch elsewhere is not a fault
    Given a comment in the default gateway naming the switch
    When the gate reads the manifests
    Then the gate passes
    -> agent-tokens: a comment naming the switch in the default gateway is not a fault
