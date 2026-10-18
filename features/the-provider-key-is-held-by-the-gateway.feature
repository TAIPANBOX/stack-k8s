# @decided 2026-10-18 (paraphrased): the gateway holds the provider key, read from a file it
# mounts. No agent-facing container holds a provider key. Bound by name to the teeth cases
# named "no-provider-key: ..." in scripts/gates-have-teeth.sh (CLAUDE.md invariant 53).
Feature: the provider key is held by the gateway only

  Scenario: the gateway takes its provider key from a file it mounts
    Given a cluster whose manifests start the gateway
    When the gate reads the gateway's container and its volumes
    Then the gateway names its key file and mounts a non-optional Secret at that file's directory
    -> no-provider-key: the gateway loses its key file variable

  Scenario: the gateway's key Secret cannot be left out
    Given a gateway that names its key file
    When the key Secret is marked optional
    Then the gate refuses it, because a gateway without its key must not start open
    -> no-provider-key: the gateway's key Secret becomes optional

  Scenario: the gateway's key is mounted where its variable points
    Given a gateway that names a key file
    When the Secret is mounted at another directory
    Then the gate refuses it
    -> no-provider-key: the gateway mounts its key where its variable does not point

  Scenario: the console holds no provider key
    Given the console's copilot is Felyx, which sends its own gateway client key
    When a container reads a provider Secret into its environment
    Then the gate refuses it
    -> no-provider-key: the console reads the provider key from a Secret again

  Scenario: a provider-shaped variable is refused unless it is a client key
    Given a container that names a variable such as OPENAI_API_KEY
    When the variable reads a Secret that is not a client key Secret
    Then the gate refuses it
    -> no-provider-key: a provider-shaped variable reads a Secret that is not a client key

  Scenario: an agent's own client key is allowed under a provider-shaped name
    Given a container whose provider-shaped variable reads its client key Secret
    When the gate reads the manifests
    Then the gate allows it, because a client key is the agent's own credential
    -> no-provider-key: a client key under a provider-shaped name is the agent's own credential

  Scenario: the scheduled costcrew run holds its own gateway client key, not an engine key
    Given the scheduled costcrew run calls its model through the gateway
    When the run reads its engine key from costcrew-engine instead of its client key
    Then the gate refuses it, and no exception remains
    -> no-provider-key: the crew reads costcrew-engine again, in place of its client key

  Scenario: costcrew's gateway key speaks only for costcrew's own host
    Given the identity map binds the costcrew key to a pattern
    When the pattern is wider than agent://costcrew.<trust domain>/*
    Then the metered-doors gate refuses it, because the key could then speak as Felyx or an operator's agent
    -> metered-doors: costcrew is bound to a wider pattern than its own host
