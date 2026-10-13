# @decided 2026-10-13: the launcher runs TokenFuse's personal-data scanners in shadow by default,
# so personal data in prompts and tool arguments is recorded and the call still goes through, and
# an operator keeps one switch to run them in mask or block, or in off. `@claude 2026-10-13`: an
# unset TOKENFUSE_DLP_PII reads as off in TokenFuse, and so does a misspelt value, without a word,
# so the literal is set on every gateway and broker start and the switch is validated before the
# install. Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this repository has
# no runner and no binding gate, so the binding is by eye.
Feature: the launcher's gateway and MCP broker scan for personal data in shadow, and one switch changes it

  A scanner that starts off looks at nothing and says nothing. The gateway and the broker run
  their personal-data scanner in shadow by default: a call goes through, and the count and kinds
  of what was found are recorded, never the matched text. An operator who wants masking or
  refusal changes one switch, and a mode the scanner does not read is refused before anything
  is installed.

  Scenario: the gateway container loses the setting
    Given the gateway container sets TOKENFUSE_DLP_PII to shadow
    When the variable is removed
    Then pii-is-shadow-by-default.sh fails, because the gateway falls back to off
    # -> gates-have-teeth.sh "pii-is-shadow-by-default: the gateway container loses the switch"

  Scenario: the gateway defaults to off
    Given the gateway container sets TOKENFUSE_DLP_PII to shadow
    When the value is changed to off
    Then pii-is-shadow-by-default.sh fails and says the value is not shadow
    # -> gates-have-teeth.sh "pii-is-shadow-by-default: the gateway defaults to off"

  Scenario: the gateway defaults to block
    Given the gateway container sets TOKENFUSE_DLP_PII to shadow
    When the value is changed to block
    Then pii-is-shadow-by-default.sh fails and says the value is not shadow
    # -> gates-have-teeth.sh "pii-is-shadow-by-default: the gateway defaults to block"

  Scenario: the switch is set twice
    Given the gateway container sets TOKENFUSE_DLP_PII to shadow
    When a second entry sets it to off
    Then pii-is-shadow-by-default.sh fails, because the later entry wins without a word
    # -> gates-have-teeth.sh "pii-is-shadow-by-default: the switch is set twice, the second to off"

  Scenario: a comment that names block beside the setting changes nothing
    Given a comment next to the setting names block
    Then pii-is-shadow-by-default.sh still passes
    # -> gates-have-teeth.sh "pii-is-shadow-by-default: a comment naming block beside the switch"

  Scenario: every gateway start is taken away
    Given no container runs the tokenfuse binary in serve mode
    Then pii-is-shadow-by-default.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "pii-is-shadow-by-default: every gateway start taken away"

  Scenario: the broker container loses the setting
    Given the broker container sets TOKENFUSE_MCP_DLP_PII to shadow
    When the variable is removed
    Then pii-is-shadow-by-default.sh fails, because the broker falls back to off
    # -> gates-have-teeth.sh "pii-is-shadow-by-default: the broker container loses the switch"

  Scenario: the broker defaults to off
    Given the broker container sets TOKENFUSE_MCP_DLP_PII to shadow
    When the value is changed to off
    Then pii-is-shadow-by-default.sh fails and says the value is off
    # -> gates-have-teeth.sh "pii-is-shadow-by-default: the MCP broker defaults to off"

  Scenario: every broker start is taken away
    Given no container runs the tokenfuse binary with the mcp-broker argument
    Then pii-is-shadow-by-default.sh fails and says it measured nothing about the broker
    # -> gates-have-teeth.sh "pii-is-shadow-by-default: every MCP broker start taken away"

  Scenario: the validator accepts a misspelt mode
    Given pii/mode.sh is the one copy of the switch's validation
    When it is changed to accept shadows
    Then pii-is-shadow-by-default.sh fails, because the scanners would ignore that word
    # -> gates-have-teeth.sh "pii/mode.sh: a misspelt mode is accepted"

  Scenario: the validator refuses a real mode
    Given pii/mode.sh is the one copy of the switch's validation
    When it is changed to refuse shadow
    Then pii-is-shadow-by-default.sh fails, because the default could not be chosen
    # -> gates-have-teeth.sh "pii/mode.sh: the real word shadow is refused"

  Scenario: the validator is taken away
    Given pii/mode.sh is the one copy of the switch's validation
    When the file is removed
    Then pii-is-shadow-by-default.sh fails, because no launcher can check the switch
    # -> gates-have-teeth.sh "pii/mode.sh: taken away"

  Scenario: a deploy path checks the mode but does not stop on it
    Given every deploy path checks the mode before its first apply
    When one of them stops checking it
    Then pii-is-shadow-by-default.sh fails, because a misspelt mode would be found after the install
    # -> gates-have-teeth.sh "pii-is-shadow-by-default: a deploy path checks the mode but does not stop on it"

  Scenario: a deploy path stops taking the flag
    Given every deploy path takes --pii-mode
    When one of them stops taking it
    Then deploy-flags-agree.sh fails, because that path cannot change the mode
    # -> gates-have-teeth.sh "deploy-flags-agree: a deploy path stops taking --pii-mode"

  Scenario: the gateway switch is accepted and applies nothing
    Given the gateway switch is applied after the kustomization
    When a deploy path stops applying it
    Then deploy-flags-agree.sh fails, because the flag does nothing
    # -> gates-have-teeth.sh "deploy-flags-agree: the gateway PII switch is accepted and applies nothing"

  Scenario: the broker switch is accepted and applies nothing
    Given the broker switch is applied after the typed render
    When a deploy path stops applying it
    Then deploy-flags-agree.sh fails, because the flag does nothing for the broker
    # -> gates-have-teeth.sh "deploy-flags-agree: the broker PII switch is accepted and applies nothing"

  Scenario: the switch is applied before the kustomization
    Given the gateway switch must come after the kustomization, which reverts it otherwise
    When a deploy path applies it before the kustomization
    Then deploy-flags-agree.sh fails, because the apply that follows reverts it
    # -> gates-have-teeth.sh "deploy-flags-agree: the gateway PII switch is applied before the kustomization"
