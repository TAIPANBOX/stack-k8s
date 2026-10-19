# @decided 2026-10-19 (paraphrased, decision D8, step 2): the agent's own token is the door credential of
# the default install. A static key is admitted only from a named list. A stop reaches every door.
# Bound by name to the teeth cases "agent-tokens-are-required: ..." in scripts/gates-have-teeth.sh, and to
# the measured run in evidence/require-agent-tokens-kind/ (CLAUDE.md invariant 54).
Feature: an agent's own token is the door credential in every default install, and a stop reaches every door

  Scenario: the gateway and the broker require an agent token
    Given the default manifests
    When the gate reads the gateway and the broker
    Then both run TOKENFUSE_AGENT_TOKENS=require under the governed profile
    -> agent-tokens-are-required: the gateway accepts static keys beside tokens (accept, not require)
    -> agent-tokens-are-required: the gateway drops the governed profile
    -> agent-tokens-are-required: the broker accepts static keys beside tokens

  Scenario: every door accepts only the one audience the stack names
    Given the gateway, the broker and vouchryx
    When any one of them names another audience, or an empty one
    Then the gate refuses it, because one token must verify at each door and no other audience may pass
    -> agent-tokens-are-required: the gateway's audience is empty, so any audience passes
    -> agent-tokens-are-required: the gateway's audience is a second, unchecked one
    -> agent-tokens-are-required: vouchryx allows an audience the doors do not check

  Scenario: a stopped agent keeps no access while the revocation list is unreadable
    Given the revocation list fails open or may be older than a minute
    When the gate reads the gateway or the broker
    Then it refuses the settings
    -> agent-tokens-are-required: the revocation list fails open
    -> agent-tokens-are-required: the revocation list may be 300 s old

  Scenario: the door takes its key set from vouchryx, not from a file an operator placed
    Given the gateway's init container
    When it does not fetch vouchryx's own key set
    Then the gate refuses it, so the door has a key set to verify against
    -> agent-tokens-are-required: the gateway's init container does not fetch the key set

  Scenario: an agent pod reaches vouchryx and the gateway, and nothing else
    Given the agent-pod network in the default set
    When it opens the internet
    Then the gate refuses it
    -> agent-tokens-are-required: the agent-pod network opens the open internet
    -> agent-tokens-are-required: the agent-pod network left out of the default set

  Scenario: the MCP broker reaches the gateway for its tool-call check, on the one port
    Given the agent-pod network in the default set
    When the broker's door into the gateway is removed, moved to another port, given to another app, or widened to a whole namespace
    Then the gate refuses it, because the broker asks the gateway about every tool call and no other caller may reach the gateway that way
    -> agent-tokens-are-required: the MCP broker's door into the gateway is removed
    -> agent-tokens-are-required: the broker's door opens another port than the gateway's 4100
    -> agent-tokens-are-required: the broker's door admits another app, not the broker
    -> agent-tokens-are-required: the broker's door admits a whole namespace

  Scenario: an example agent asks for the one audience and keeps no API token
    Given the example agent pod
    When it keeps the default ServiceAccount token
    Then the gate refuses it
    -> agent-tokens-are-required: the example agent keeps the default ServiceAccount token

  Scenario: the registry tool only writes the registry, and never switches a door
    Given agent-tokens/up.sh
    When it applies a kustomization, or stops refusing before it writes
    Then the gate refuses it
    -> agent-tokens-are-required: up.sh applies a kustomization instead of writing the registry
    -> agent-tokens-are-required: up.sh stops refusing before it writes

  Scenario: a comment naming a switch that no longer exists is not a fault
    Given a comment that names the old switch in the gateway
    When the gate reads the manifests
    Then it passes
    -> agent-tokens-are-required: a comment naming the old switch in the gateway is not a fault
