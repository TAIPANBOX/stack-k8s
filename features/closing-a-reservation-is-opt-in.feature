# @decided 2026-10-11 (paraphrased, recorded in tokenfuse): a retained
# reservation is closed by a person after a passkey assertion in the console,
# which mints a short-lived token the gateway verifies; both are keyed by one
# shared secret. @claude 2026-10-12: on a cluster that secret is the operator's
# choice and is off by default. Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name; this repository has no BDD runner.
Feature: closing a retained reservation is opt-in

  The default apply set carries no closure setting. closure/up.sh mints one
  secret, once, and gives the gateway and the console the same bytes.

  Scenario: a closure patch or setting reaches the default apply
    Given the default kustomization and the default gateway and console manifests
    When a 57-closure file is listed as a resource, or a closure variable is written into a default manifest
    Then closure-off-by-default.sh fails and names what reached the default
    # -> gates-have-teeth.sh "closure-off-by-default: a closure patch joins the default apply"
    # -> gates-have-teeth.sh "closure-off-by-default: a closure setting leaks into the default gateway manifest"

  Scenario: the console and the gateway would hold different secrets
    Given the console patch mounts the closure-keys Secret and names a file
    When the file it names is not the one its volume mounts, or the Secret is created from a file that can carry a newline
    Then closure-off-by-default.sh fails
    # -> gates-have-teeth.sh "closure-off-by-default: the console reads a file its volume does not mount"
    # -> gates-have-teeth.sh "closure-off-by-default: up.sh creates the Secret from a file"

  Scenario: turning closing off leaves part of it behind
    Given closure/down.sh applies the two unpatch files
    When the console unpatch does not delete the volume its patch added
    Then closure-off-by-default.sh fails
    # -> gates-have-teeth.sh "closure-off-by-default: the console unpatch leaves the volume"

  Scenario: a re-run mints a second secret, or the secret is printed
    Given closure/up.sh mints the closure-keys Secret
    When it skips the check that the Secret exists, or a line other than its length check and its create expands the value
    Then closure-off-by-default.sh fails and names the line
    # -> gates-have-teeth.sh "closure-off-by-default: up.sh mints a new secret on every run"
    # -> gates-have-teeth.sh "closure-off-by-default: up.sh prints the secret"

  Scenario: only a comment changes
    Given closure/up.sh
    When a comment in it is reworded
    Then closure-off-by-default.sh still passes
    # -> gates-have-teeth.sh "closure-off-by-default: a comment in up.sh is reworded"

  Scenario: the gate has nothing to judge
    Given the console patch is taken away
    When closure-off-by-default.sh runs
    Then it fails and says it measured nothing
    # -> gates-have-teeth.sh "closure-off-by-default: the subject taken away entirely"

  Scenario: a patch body stops being a patch body, or its key stops being readable
    Given the closure console patch is skipped by kubeconform as a patch body and judged by the mounted-keys gate
    When it grows an apiVersion, or mounts the key 0440 without an fsGroup of its own
    Then manifests-valid.sh or mounted-keys-are-readable.sh fails and names the file
    # -> gates-have-teeth.sh "manifests-valid: a closure patch body grows an apiVersion"
    # -> gates-have-teeth.sh "mounted-keys: the closure key mounted 0440 with no fsGroup in its patch"
