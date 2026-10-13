# @decided 2026-10-13: the launcher runs TokenFuse's agent firewall in enforce by default,
# and an operator keeps one switch to run it in shadow or off. `@claude 2026-10-13`: an unset
# TOKENFUSE_FIREWALL reads as shadow in TokenFuse, and since v1.11.1 TokenFuse refuses to start on
# a misspelt value (exit 2), so the literal is set on every gateway start and the switch is
# validated before the install. Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this repository
# has no runner and no binding gate, so the binding is by eye.
Feature: the launcher's gateway runs the agent firewall in enforce, and one switch changes it

  A gateway that starts in shadow refuses nothing, and a launcher that forgets the setting
  ships one. The gateway runs enforce by default. An operator who wants to watch what the
  policy would do first changes one switch, and a mode the gateway does not read is refused
  before anything is installed.

  Scenario: the gateway container loses the switch
    Given the gateway container sets TOKENFUSE_FIREWALL to enforce
    When the variable is removed
    Then firewall-is-enforce-by-default.sh fails, because the gateway falls back to shadow
    # -> gates-have-teeth.sh "firewall-is-enforce-by-default: the gateway container loses the switch"

  Scenario: the gateway defaults to shadow
    Given the gateway container sets TOKENFUSE_FIREWALL to enforce
    When the value is changed to shadow
    Then firewall-is-enforce-by-default.sh fails and says the value is not enforce
    # -> gates-have-teeth.sh "firewall-is-enforce-by-default: the gateway defaults to shadow"

  Scenario: the gateway defaults to off
    Given the gateway container sets TOKENFUSE_FIREWALL to enforce
    When the value is changed to off
    Then firewall-is-enforce-by-default.sh fails and says the value is not enforce
    # -> gates-have-teeth.sh "firewall-is-enforce-by-default: the gateway defaults to off"

  Scenario: the switch is set twice
    Given the gateway container sets TOKENFUSE_FIREWALL to enforce
    When a second entry sets it to shadow
    Then firewall-is-enforce-by-default.sh fails, because the later entry wins without a word
    # -> gates-have-teeth.sh "firewall-is-enforce-by-default: the switch is set twice, the second to shadow"

  Scenario: a comment that names shadow beside the switch changes nothing
    Given a comment next to the switch names shadow
    Then firewall-is-enforce-by-default.sh still passes
    # -> gates-have-teeth.sh "firewall-is-enforce-by-default: a comment naming shadow beside the switch"

  Scenario: every gateway start is taken away
    Given no container runs the tokenfuse binary in serve mode
    Then firewall-is-enforce-by-default.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "firewall-is-enforce-by-default: every gateway start taken away"

  Scenario: the validator accepts a misspelt mode
    Given firewall/mode.sh is the one copy of the switch's validation
    When it is changed to accept enforced
    Then firewall-is-enforce-by-default.sh fails, because the gateway would ignore that word
    # -> gates-have-teeth.sh "firewall/mode.sh: a misspelt mode is accepted"

  Scenario: the validator refuses a real mode
    Given firewall/mode.sh is the one copy of the switch's validation
    When it is changed to refuse enforce
    Then firewall-is-enforce-by-default.sh fails, because the operator could not choose the default
    # -> gates-have-teeth.sh "firewall/mode.sh: the real word enforce is refused"

  Scenario: the validator is taken away
    Given firewall/mode.sh is the one copy of the switch's validation
    When the file is removed
    Then firewall-is-enforce-by-default.sh fails, because no launcher can check the switch
    # -> gates-have-teeth.sh "firewall/mode.sh: taken away"

  Scenario: a deploy path checks the mode but does not stop on it
    Given every deploy path checks the mode before its first apply
    When one of them stops checking it
    Then firewall-is-enforce-by-default.sh fails, because a misspelt mode would be found after the install
    # -> gates-have-teeth.sh "firewall-is-enforce-by-default: a deploy path checks the mode but does not stop on it"

  Scenario: a deploy path stops taking the flag
    Given every deploy path takes --firewall
    When one of them stops taking it
    Then deploy-flags-agree.sh fails, because that path cannot change the mode
    # -> gates-have-teeth.sh "deploy-flags-agree: a deploy path stops taking --firewall"

  Scenario: the flag is accepted and applies nothing
    Given the flag is applied after the kustomization
    When the deploy path stops applying it
    Then deploy-flags-agree.sh fails, because the flag is accepted and does nothing
    # -> gates-have-teeth.sh "deploy-flags-agree: the firewall flag is accepted and applies nothing"
