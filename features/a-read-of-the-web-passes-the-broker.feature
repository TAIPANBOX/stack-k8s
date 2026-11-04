# @claude 2026-11-04, from the G2.1 entry of the estate gap list and the task that asked for the wiring: an
# agent's read of the web passes the MCP broker in front of scopyx, so the run is labelled from the act the
# broker saw and not from a tool name the agent reported (tokenfuse v1.21.0, invariant 143). The key that opens
# scopyx is in the broker's vault and never in the agent's hands. Each scenario is bound by name to a case in
# scripts/gates-have-teeth.sh.
Feature: a read of the web passes the broker, which labels the run from the act

  From tokenfuse v1.21.0 the broker reports the fetch it saw, so the label follows the act. That holds only
  while the read cannot go round the broker: scopyx admits the broker and nobody else, the key that opens it
  is one per agent in the broker's vault, and an agent pod can reach the broker.

  Scenario: the broker does not know scopyx
    Given the broker names its upstreams in TOKENFUSE_MCP_UPSTREAMS
    When scopyx is taken out of the list
    Then scopyx-reads-go-through-the-broker.sh fails and names the address
    # -> gates-have-teeth.sh "scopyx-broker: the broker's upstream list loses scopyx"

  Scenario: the broker stops labelling scopyx
    Given the answers of scopyx carry the web
    When the classification is removed, or says something other than the web
    Then scopyx-reads-go-through-the-broker.sh fails, because a read would carry no label from the act
    # -> gates-have-teeth.sh "scopyx-broker: the broker stops labelling scopyx"
    # -> gates-have-teeth.sh "scopyx-broker: scopyx is labelled as something else"

  Scenario: the broker has a classification and no taint gateway
    Given the broker exits 2 on a classification with no taint gateway
    When the taint gateway is emptied
    Then scopyx-reads-go-through-the-broker.sh fails
    # -> gates-have-teeth.sh "scopyx-broker: the broker loses its taint gateway"

  Scenario: a vault entry has no rule
    Given the broker refuses to start on a vault entry with no scope rule
    When that switch is turned off
    Then scopyx-reads-go-through-the-broker.sh fails, because a key would be resolvable by any agent for any tool
    # -> gates-have-teeth.sh "scopyx-broker: a vault entry with no rule no longer stops the broker"

  Scenario: the scopes go back into the Deployment
    Given the scope rules are in the Secret beside the keys they scope
    When TOKENFUSE_MCP_SECRET_SCOPES is an env value of the Deployment
    Then scopyx-reads-go-through-the-broker.sh fails, because the env value shadows the Secret
    # -> gates-have-teeth.sh "scopyx-broker: the scopes are an env value of the Deployment again"

  Scenario: the minted broker Secret has no scope rule
    Given door-secrets mints the broker's Secret with the typryx rule
    When it mints it without the rule
    Then typed-door-is-minted.sh fails, because the broker would stop at start
    # -> gates-have-teeth.sh "typed-door-is-minted: the broker Secret made with no scope rule"

  Scenario: the broker cannot reach scopyx
    Given default deny holds in the namespace
    When the broker's egress rule to scopyx is gone or on another port
    Then scopyx-reads-go-through-the-broker.sh fails
    # -> gates-have-teeth.sh "scopyx-broker: the broker cannot reach scopyx"
    # -> gates-have-teeth.sh "scopyx-broker: the broker reaches scopyx on another port"

  Scenario: scopyx stops taking the key in the call
    Given the broker hands scopyx its key in params._meta
    When scopyx or the browser runs without SCOPYX_ACCEPT_KEY_IN_META
    Then scopyx-reads-go-through-the-broker.sh fails, because every call through the broker is refused
    # -> gates-have-teeth.sh "scopyx-broker: scopyx stops taking the key in the call"
    # -> gates-have-teeth.sh "scopyx-broker: the browser stops taking the key in the call"

  Scenario: another plane reaches scopyx
    Given a pod that reaches scopyx with a key reads the web without the broker
    When scopyx-ingress admits the money plane or the console
    Then scopyx-reads-go-through-the-broker.sh fails and says the broker alone may
    # -> gates-have-teeth.sh "scopyx-broker: the money plane reaches scopyx again"
    # -> gates-have-teeth.sh "scopyx-broker: the console reaches scopyx again"

  Scenario: an agent pod cannot reach the broker, or the broker does not admit it
    Given an agent-token pod reads the web through the broker on 4200
    When the egress rule or the ingress rule for that is gone
    Then scopyx-reads-go-through-the-broker.sh fails, because the agent has no way to read the web
    # -> gates-have-teeth.sh "scopyx-broker: an agent pod cannot reach the broker"
    # -> gates-have-teeth.sh "scopyx-broker: the broker does not admit an agent pod"

  Scenario: a new policy lets a pod reach scopyx
    Given scopyx-ingress is the one rule that says who reaches scopyx
    When any other NetworkPolicy lets a pod reach app: scopyx
    Then scopyx-reads-go-through-the-broker.sh fails
    # -> gates-have-teeth.sh "scopyx-broker: another policy lets a pod reach scopyx"
