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

  Scenario: the training log is off unless asked for
    Given no --typed-training flag
    When typed/mode.sh renders any mode
    Then TYPRYX_TRAINING_DIR is in none of them
    # -> typed-mode-is-honest.sh check "9 training is off unless asked"
    # -> gates-have-teeth.sh "typed-mode-is-honest: the training log is on without the flag"

  Scenario: the training log adds one variable and no disk
    Given --typed-training with typryx deployed in any mode
    When typed/mode.sh renders
    Then the only lines added are TYPRYX_TRAINING_DIR and its comment
    And the directory is on the typryx-state claim typryx already had, never on the shared events bus
    And no PersistentVolumeClaim exists beyond typryx-state
    # -> typed-mode-is-honest.sh checks "10 training adds no volume, claim or policy", "10 training has a writable home", "10 training stays off the shared bus" and "10 no new disk"
    # -> gates-have-teeth.sh "typed-mode-is-honest: the training flag provisions a claim", "...the training directory is under no mount", "...lands on the shared bus" and "...brings another object"

  Scenario: the training log needs a typryx to write it
    Given --typed-training with no --with-typed, or with --typed-mode off
    When the launcher starts
    Then it refuses before it installs anything, naming --typed-training
    And every launcher parses the flag and hands it to typed/mode.sh
    # -> typed-mode-is-honest.sh checks "11 training needs typryx" and "11 launchers hand --typed-training to typed/mode.sh"
    # -> gates-have-teeth.sh "typed-mode-is-honest: the training flag is accepted with no typryx", "a launcher loses --typed-training" and "a launcher stops forwarding --typed-training"

  Scenario: the pinned typryx is one that reads the training variable
    Given every reference to ghcr.io/taipanbox/typryx in the repository
    When the gate reads them
    Then they name one tag, and it is v0.3.0 or later
    # -> typed-mode-is-honest.sh checks "12 one typryx tag" and "12 typryx reads the training variable"
    # -> gates-have-teeth.sh "typed-mode-is-honest: the typryx pin goes back before the training log" and "a document names a second typryx tag"
