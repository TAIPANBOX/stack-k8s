# @decided 2026-10-04, from the estate audit (wave 1): the tokenfuse gateway's
# declassify endpoint lifts a run's taint label and its credential is optional,
# so a launcher that sets none leaves the endpoint open to anything that reaches
# the gateway port. Scenarios are bound to cases in scripts/gates-have-teeth.sh
# by name; this repository has no runner and no binding gate yet, so the binding
# is by eye.
Feature: the gateway's declassify key is minted per cluster and travels on stdin

  POST /v1/fuse/declassify takes a run's taint label off after a person
  reviewed it. It is not behind the gateway's admin key. Its own key is
  optional in the gateway, and with none set anything that can reach port 4100
  can clear a run, which the event records only as "authenticated: false".
  Nothing in the estate calls the endpoint, so a key that only the operator can
  read closes it and breaks nothing.

  Scenario: the gateway container loses the key
    Given the gateway container reads TOKENFUSE_DECLASSIFY_KEY from stack-keys
    When its env entry is removed
    Then declassify-is-keyed.sh fails and names the container and the missing variable
    # -> gates-have-teeth.sh "declassify-is-keyed: the gateway container loses TOKENFUSE_DECLASSIFY_KEY"

  Scenario: the key is committed as a literal
    Given the gateway container reads TOKENFUSE_DECLASSIFY_KEY from stack-keys
    When the manifest writes a literal value instead
    Then declassify-is-keyed.sh fails saying the key is set from a literal value
    # -> gates-have-teeth.sh "declassify-is-keyed: the key becomes a literal in the manifest"

  Scenario: the key is optional
    Given the gateway container reads TOKENFUSE_DECLASSIFY_KEY from stack-keys
    When the reference is marked optional
    Then declassify-is-keyed.sh fails, because a pod would start with the endpoint open
    # -> gates-have-teeth.sh "declassify-is-keyed: the key is marked optional"

  Scenario: the gateway reads some other key of the Secret
    Given the gateway container reads stack-keys/declassify_key
    When the reference names a different key
    Then declassify-is-keyed.sh fails and names what it read instead
    # -> gates-have-teeth.sh "declassify-is-keyed: the gateway reads some other key of the Secret"

  Scenario: an installer puts the key on a command line
    Given every installer creates the key from stdin
    When one passes it with --from-literal
    Then declassify-is-keyed.sh fails saying the key is on a command line
    # -> gates-have-teeth.sh "declassify-is-keyed: an installer passes the key with --from-literal"

  Scenario: an installer migrates the key with patch -p
    Given every installer adds the key to an existing Secret with --patch-file /dev/stdin
    When one uses patch -p with the value inline
    Then declassify-is-keyed.sh fails saying the key is patched on a command line
    # -> gates-have-teeth.sh "declassify-is-keyed: an installer migrates the key with patch -p"

  Scenario: an installer creates the Secret without piping the key in
    Given every installer feeds its create block from a pipe
    When one drops the pipe
    Then declassify-is-keyed.sh fails saying it never creates the key from stdin
    # -> gates-have-teeth.sh "declassify-is-keyed: an installer creates the Secret without piping the key in"

  Scenario: an installer never gives an existing Secret the key
    Given a cluster installed before the key existed has a stack-keys Secret without it
    When an installer has no stdin patch for it
    Then declassify-is-keyed.sh fails, because that cluster's gateway pod could never start
    # -> gates-have-teeth.sh "declassify-is-keyed: an installer never gives an existing Secret the key"

  Scenario: no gateway container and no installer left to judge
    Given the gateway container is found by its image and command, and installers by the kubectl they run
    When either set is empty
    Then declassify-is-keyed.sh fails saying it measured nothing, never OK
    # -> gates-have-teeth.sh "declassify-is-keyed: no gateway container left to judge"
    # -> gates-have-teeth.sh "declassify-is-keyed: no installer left to read"

  Scenario: a sidecar, a reworded comment and another key are not this gate's business
    Given a sidecar runs the gateway image on a subcommand and never serves the route
    When the sidecar's command, a comment beside the key, or another key's spelling changes
    Then declassify-is-keyed.sh still passes
    # -> gates-have-teeth.sh "declassify-is-keyed: a subcommand sidecar is not a gateway container"
    # -> gates-have-teeth.sh "declassify-is-keyed: a comment beside the key is reworded"
    # -> gates-have-teeth.sh "declassify-is-keyed: another key of the Secret still rides --from-literal"
