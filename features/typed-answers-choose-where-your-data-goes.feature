# @decided 2026-09-30: a customer chooses where the data of a typed answer goes,
# from three modes (Jev, their own model, or off), and the launchers ask.
# Scenarios are bound to checks in scripts/typed-mode-is-honest.sh, and to cases
# in scripts/gates-have-teeth.sh, by name; this repository has no runner and no
# binding gate yet, so the binding is by eye.
Feature: typed answers, choose where your data goes

  typryx answers a typed question with a probability. The launchers deploy it on
  the free stub backend unless the operator picks a data mode: Jev (named fields
  leave for TypeSafe's hosted API), their own model on their own hardware, or
  off. The default stays off, and nothing is deployed for a mode nobody chose.

  Scenario: the default deploys nothing new
    Given no typed flag is given
    When typed/mode.sh renders
    Then nothing is rendered and nothing is applied
    # -> typed-mode-is-honest.sh check "1 default is off"

  Scenario: --with-typed alone is what it was
    Given only --with-typed is given
    When typed/mode.sh renders
    Then the output is manifests/51 and manifests/52 byte for byte, on the stub backend
    # -> typed-mode-is-honest.sh check "2 --with-typed alone is stub"

  Scenario: jev without a key file refuses
    Given --typed-mode jev with no key file, a missing one, an empty one or a blank one
    When the launcher starts
    Then it refuses before it installs anything, naming --typed-jev-key-file
    # -> typed-mode-is-honest.sh checks "3 jev without a key file refuses" and "8 launchers refuse before they install"
    # -> gates-have-teeth.sh "typed-mode-is-honest: jev stops refusing a missing key file"

  Scenario: the jev key is a file, never a value
    Given --typed-mode jev with a key file
    When the manifests are rendered
    Then the key is in no rendered manifest as a literal, in no environment value and in no ConfigMap
    And TYPRYX_JEV_KEY_FILE points at a file mounted from a Secret made from that file
    # -> typed-mode-is-honest.sh check "4 jev key is a file, never a value"
    # -> gates-have-teeth.sh "typed-mode-is-honest: the jev key becomes an environment value"

  Scenario: your own model renders the right environment
    Given --typed-mode own-model with a URL ending in /v1 and a model name
    When the manifests are rendered
    Then typryx runs the openai-logprobs backend against that URL and model
    And its one way out is that address and port and nothing else
    # -> typed-mode-is-honest.sh check "5 own-model"

  Scenario: off deploys nothing, and another mode's flags are not ignored
    Given --typed-mode off, or a flag that belongs to a different mode
    When typed/mode.sh checks
    Then off renders nothing, and the stray flag is refused rather than ignored
    # -> typed-mode-is-honest.sh checks "6 off deploys nothing" and "6 flags of another mode are refused"

  Scenario: every launcher takes the same flags
    Given deploy.sh, deploy-gcp.sh and deploy-aws.sh
    When any of them loses a typed flag or stops rendering through typed/mode.sh
    Then typed-mode-is-honest.sh fails and names the launcher
    # -> typed-mode-is-honest.sh checks "8 launchers parse every flag" and "8 launchers render through typed/mode.sh"
    # -> gates-have-teeth.sh "typed-mode-is-honest: a launcher loses a typed flag"

  Scenario: a rendered mode is a document Kubernetes would accept
    Given every mode the launchers can render
    When kubeconform validates it strictly
    Then it passes
    # -> typed-mode-is-honest.sh check "7 every rendered mode validates"
