# @decided 2026-10-13 (paraphrased): the cluster launcher takes the gateway's client keys and its
# identity map as files, the way stack-single's installer does: the keys become a Kubernetes Secret,
# the map a ConfigMap mounted read only into the gateway, a changed map rolls the gateway (a
# ConfigMap change alone restarts nothing), and the same two-step check runs before anything is
# applied: the shell grammar first, then the pinned gateway image reading the pair in a throwaway
# container with no network, refusing a map that configures nothing, a map key id with no secret
# and a client key with no binding.
#
# @claude 2026-10-13, choices the decision left open: identity/up.sh is its own opt-in script, like
# closure/up.sh, and runs the check with docker on the operator's machine, so nothing reaches the
# cluster before the gateway image has read the files; the gateway reads both objects as optional,
# so a cluster that names no file runs exactly as before and `kubectl apply -k` never touches them;
# the gateway rolls because its pod template carries the map's sha256 and the Secret's
# resourceVersion, so it rolls exactly when what it reads changed. Scenarios are bound to cases in
# scripts/gates-have-teeth.sh by name; this repository has no runner and no binding gate, so the
# binding is by eye.
Feature: the cluster takes client keys and the identity map as files, checks them first, and keeps them

  A client key decides who may call the gateway. The identity map decides which agent ids each key
  may speak as, and which unit pays for its calls. Both are prepared outside the cluster, by a
  person or by an onboarding agent, and handed to identity/up.sh as files. Nothing in the cluster
  changes until the gateway image itself has read them, a re-run keeps them, and the gateway rolls
  only when what it reads has changed.

  Scenario: the keys and the map reach the gateway, and only the gateway
    Given the gateway reads TOKENFUSE_CLIENT_KEYS from the gateway-client-keys Secret
    And it reads TOKENFUSE_IDENTITY_MAP and the map file from the gateway-identity-map ConfigMap
    When the manifest stops passing either, or hands the keys to another workload
    Then identity-files-are-checked.sh fails and names what is missing or where it leaked
    # -> gates-have-teeth.sh "identity-files: the gateway loses its client keys setting"
    # -> gates-have-teeth.sh "identity-files: the gateway loses its identity map setting"
    # -> gates-have-teeth.sh "identity-files: another workload is handed the client keys"

  Scenario: a cluster that names no file runs exactly as before
    Given an operator who never runs identity/up.sh
    When the manifest makes the Secret or the ConfigMap required instead of optional
    Then identity-files-are-checked.sh fails, because every such gateway would stop starting
    # -> gates-have-teeth.sh "identity-files: the client keys become required"
    # -> gates-have-teeth.sh "identity-files: the map volume becomes required"

  Scenario: the map's path and the map itself cannot disagree
    Given the gateway refuses to start on a TOKENFUSE_IDENTITY_MAP that names no file
    When the path becomes a literal instead of a key of the map's own ConfigMap
    Then identity-files-are-checked.sh fails, because a cluster with no map would lose its gateway
    # -> gates-have-teeth.sh "identity-files: the map path becomes a literal"

  Scenario: the map is mounted read only, at the path identity/up.sh writes
    Given the gateway reads the map and must not be able to change it
    When the mount loses its read-only flag, or identity/up.sh names a path outside the mount
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: the map is mounted writable"
    # -> gates-have-teeth.sh "identity-files: up.sh writes a path the gateway does not read"

  Scenario: the operator's Secret and ConfigMap are never part of the default apply
    Given kubectl apply -k puts back whatever a manifest declares
    When a manifest declares the gateway-client-keys Secret or the gateway-identity-map ConfigMap
    Then identity-files-are-checked.sh fails, because the next deploy would overwrite the operator's files
    # -> gates-have-teeth.sh "identity-files: a manifest declares the operator's ConfigMap"

  Scenario: a keys file that would put something unsafe into the cluster is refused before anything is touched
    Given a keys file is one secret:key_id per line, written by somebody else
    When identity/up.sh accepts a short secret, a quote or a dollar, a secret given twice, a NUL byte, a file of comments alone, or a map larger than a ConfigMap holds
    Then identity-files-are-checked.sh fails, because the refusal has to come before the cluster is touched
    # -> gates-have-teeth.sh "identity-files: a short secret is accepted"
    # -> gates-have-teeth.sh "identity-files: a quote or a dollar reaches the Secret"
    # -> gates-have-teeth.sh "identity-files: a secret given twice is kept"
    # -> gates-have-teeth.sh "identity-files: a NUL byte is let through"
    # -> gates-have-teeth.sh "identity-files: a keys file of comments alone is accepted"
    # -> gates-have-teeth.sh "identity-files: a map that is not a JSON object passes the first half"
    # -> gates-have-teeth.sh "identity-files: a map larger than a ConfigMap holds is accepted"

  Scenario: a refusal never repeats a secret
    Given a refused keys file may hold real credentials
    When identity/up.sh puts the offending line into its refusal
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: a refusal repeats the secret"

  Scenario: the gateway image refuses what it would refuse to start on, before anything is written
    Given the pinned gateway image reads the pair in a throwaway container with no network
    When identity/up.sh stops hearing the gateway's own refusal, such as a unit the map never declares
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: the gateway's own refusal is not heard"

  Scenario: an empty map, a key with no secret and a key with no binding are refused too
    Given the gateway only warns about these three and then runs
    When identity/up.sh accepts a map that configures nothing, a map binding a key id no secret carries, or a key the map does not bind
    Then identity-files-are-checked.sh fails, because each would leave a gateway that looks governed and is not
    # -> gates-have-teeth.sh "identity-files: a map that configures nothing is accepted"
    # -> gates-have-teeth.sh "identity-files: a map that binds a key with no secret is accepted"
    # -> gates-have-teeth.sh "identity-files: a client key the map does not bind is accepted"

  Scenario: the throwaway container is the pod, not something kinder
    Given the gateway pod runs the manifest's command as uid 10001 with a read-only root
    When the check container reaches the network, gets the keys on its command line, or is given no command
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: the check container reaches the network"
    # -> gates-have-teeth.sh "identity-files: the keys ride the docker command line"
    # -> gates-have-teeth.sh "identity-files: the check gives the image no command"

  Scenario: nothing reaches the cluster before the check passes
    Given identity/up.sh reads the cluster, asks the gateway image, and only then writes
    When a write moves before the check
    Then identity-files-are-checked.sh fails, because a refused file would already be in the cluster
    # -> gates-have-teeth.sh "identity-files: a refused file still writes to the cluster"

  Scenario: the keys never travel where they can be read back
    Given a Secret written by kubectl apply keeps a copy of itself in an annotation, and an argument is in the process table
    When identity/up.sh hands the keys to kubectl on its command line
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: the keys ride the kubectl command line"

  Scenario: a re-run keeps the keys and the map, and rotates nothing
    Given a cluster given a keys file and a map
    When identity/up.sh runs again naming no file, and drops or rewrites what it kept
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: a re-run that names no file drops the kept keys"

  Scenario: the gateway rolls exactly when what it reads has changed
    Given a ConfigMap or Secret change restarts no pod by itself
    When the same map again rolls the gateway, or a new map or a new keys file does not
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: the same map again restarts the gateway"
    # -> gates-have-teeth.sh "identity-files: a new map does not restart the gateway"
    # -> gates-have-teeth.sh "identity-files: a new keys file does not restart the gateway"

  Scenario: the running gateway is asked
    Given identity/up.sh reads the start-up lines of the gateway pod it rolled, and verify.sh asks the running gateway
    When identity/up.sh believes a gateway that reports other keys, or verify.sh stops refusing a call with no key or stops comparing the running map with the ConfigMap
    Then identity-files-are-checked.sh fails
    # -> gates-have-teeth.sh "identity-files: up.sh believes a gateway that reports other keys"
    # -> gates-have-teeth.sh "identity-files: verify.sh stops asking for a call with no key"
    # -> gates-have-teeth.sh "identity-files: verify.sh stops comparing the running map"

  Scenario: the gate never reports OK on nothing
    Given the gate judges the gateway starts and the script it finds
    When no gateway start is left, or identity/up.sh is gone
    Then identity-files-are-checked.sh says it measured nothing, and does not report OK
    # -> gates-have-teeth.sh "identity-files: no gateway start left to judge"
    # -> gates-have-teeth.sh "identity-files: identity/up.sh taken away"

  Scenario: a comment is not a fault
    Given reviewers write comments beside the settings
    When a comment names a required form of the setting
    Then identity-files-are-checked.sh still passes
    # -> gates-have-teeth.sh "identity-files: a comment that names a required setting is not the setting"
