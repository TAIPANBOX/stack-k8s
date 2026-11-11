# @decided 2026-11-11 (paraphrased): the installers fetch what other projects publish once, on the
# operator's machine, and check its hash before any node uses it. @claude 2026-11-11: until then each
# node pulled Longhorn, Calico and Hetzner's controller by URL and ran whatever get.k3s.io answered.
# Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this repository has no runner
# and no binding gate for this file, so the binding is by eye.
Feature: nothing another project publishes runs before its hash is checked

  Scenario: a manifest is applied by URL again
    Given the installers apply Longhorn, Calico and the cloud controller from a verified file
    When an installer applies a remote manifest by its URL
    Then remote-fetches-are-verified.sh fails and names the line
    # -> gates-have-teeth.sh "remote-fetches-are-verified: a remote manifest is applied by URL again"
    # -> gates-have-teeth.sh "remote-fetches-are-verified: Longhorn goes back to the unverified apply"

  Scenario: the floating k3s script comes back
    Given the k3s install script is taken from the release's own tag and checked
    When an installer takes it from get.k3s.io, or pipes any download into a shell
    Then the gate fails and names the line
    # -> gates-have-teeth.sh "remote-fetches-are-verified: a k3s install takes the floating get.k3s.io script again"
    # -> gates-have-teeth.sh "remote-fetches-are-verified: a download is piped into a shell"
    # -> gates-have-teeth.sh "remote-fetches-are-verified: a shell is handed the text of a download"

  Scenario: a download kept in a file, or prose that names the pipe, is not a fault
    Given a script saves a download to a file and prints a sentence about curl and bash
    When the gate reads it
    Then it passes
    # -> gates-have-teeth.sh "remote-fetches-are-verified: a download kept in a file, and prose that names the pipe, are not faults"

  Scenario: a file whose hash differs is never used
    Given the library is run against a file that is not the pinned one
    When the hashes differ
    Then nothing is printed, nothing is cached, and the message names the URL, the hash expected and the hash received
    # -> gates-have-teeth.sh "remote-fetches-are-verified: the library stops comparing hashes"

  Scenario: a version nobody pinned stops the run
    Given an operator sets another version and gives no hash
    When the installer reaches the download
    Then it stops and names the variable that wants the hash
    # -> gates-have-teeth.sh "remote-fetches-are-verified: a default version is moved and no hash is pinned for it"

  Scenario: a machine with no hash tool refuses
    Given neither sha256sum nor shasum is on the machine
    When a file is fetched
    Then the library refuses and says so, and the file is not used
    # -> gates-have-teeth.sh "remote-fetches-are-verified: the library accepts a file on a machine with no hash tool"

  Scenario: an installer fetches before it touches a node
    Given each installer fetches the k3s script, Calico and Longhorn before its first install
    When an installer stops sourcing the library or stops fetching the k3s script through it
    Then the gate fails
    # -> gates-have-teeth.sh "remote-fetches-are-verified: an installer stops sourcing the library"
    # -> gates-have-teeth.sh "remote-fetches-are-verified: an installer stops fetching the k3s script through the library"
