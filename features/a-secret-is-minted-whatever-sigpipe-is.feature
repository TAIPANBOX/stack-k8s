# @claude 2026-10-14: ported from stack-single (its invariant 31), after a hook there hung on the
# idiom this repository's three deploy scripts also carried. A secret is minted from a bounded
# read of /dev/urandom by one generator, lib/gen.sh, so minting one ends whatever SIGPIPE is set
# to. Scenarios are bound to cases in scripts/gates-have-teeth.sh by name; this repository has no
# runner and no binding gate, so the binding is by eye.
Feature: a secret is minted from a bounded read, whatever SIGPIPE is set to

  The operator password a deploy prints at the end, and every other random value this
  launcher writes as text, comes from one generator that reads a fixed number of bytes and
  cuts the value in bash. A reader that waits for a closed pipe to stop it would never stop
  where SIGPIPE is ignored, as it is under a git hook, and the deploy would sit there with the
  cluster already up.

  Scenario: a deploy script goes back to the unbounded idiom
    Given deploy.sh mints the operator password with gen 28
    When the line becomes tr reading /dev/urandom into head -c 28
    Then gen-is-bounded.sh fails and names deploy.sh and the line
    # -> gates-have-teeth.sh "gen-is-bounded: a deploy script reads urandom with no bound"

  Scenario: the generator itself reads a stream that never ends
    Given lib/gen.sh reads 4096 bytes with head -c
    When it reads /dev/urandom through tr into head -c instead
    Then gen-is-bounded.sh fails and names lib/gen.sh
    # -> gates-have-teeth.sh "gen-is-bounded: the generator itself reads with no bound"

  Scenario: the generator hands back a short value without a word
    Given gen refuses a value shorter than it was asked for
    When it cuts one character short and the check is taken out
    Then gen-is-bounded.sh fails, because gen 28 printed something that is not 28 characters
    # -> gates-have-teeth.sh "gen-is-bounded: the generator returns short without saying so"

  Scenario: the generator succeeds with nothing when the device gives it nothing
    Given gen fails and says why when it could read no characters
    When it returns success instead
    Then gen-is-bounded.sh fails, because a caller would go on with an empty password
    # -> gates-have-teeth.sh "gen-is-bounded: the generator says nothing and succeeds when it read nothing"

  Scenario: the generator prints the same value every time
    Given every run of gen prints a fresh value
    When gen prints a fixed string of the right length
    Then gen-is-bounded.sh fails, because a value that repeats is not a secret
    # -> gates-have-teeth.sh "gen-is-bounded: the generator prints the same value every time"

  Scenario: a deploy script carries its own copy of the generator
    Given gen is defined once, in lib/gen.sh
    When cloud/gcp/deploy-gcp.sh defines a gen of its own
    Then gen-is-bounded.sh fails, because a copied block drifts
    # -> gates-have-teeth.sh "gen-is-bounded: a second copy of the generator in a deploy script"

  Scenario: a deploy script asks for a value and never loads the generator
    Given cloud/aws/deploy-aws.sh sources lib/gen.sh once the checkout is known
    When the source line is taken out
    Then gen-is-bounded.sh fails, because the deploy would end with gen not found after the cluster is up
    # -> gates-have-teeth.sh "gen-is-bounded: a caller that never sources the generator"

  Scenario: a deploy script loads the generator too late
    Given deploy.sh sources lib/gen.sh above its first ask
    When the source line moves to the end of the file
    Then gen-is-bounded.sh fails and says the ask is above the source
    # -> gates-have-teeth.sh "gen-is-bounded: a caller that sources the generator below its first ask"

  Scenario: a message that only names the device is not a read
    Given a deploy script says a sentence that mentions /dev/urandom
    Then gen-is-bounded.sh still passes
    # -> gates-have-teeth.sh "gen-is-bounded: a message that names the device reads nothing"

  Scenario: the generator is taken away
    Given lib/gen.sh is gone
    Then gen-is-bounded.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "gen-is-bounded: the generator is taken away"

  Scenario: nothing asks the generator for a length
    Given no script asks gen for a value of a stated length
    Then gen-is-bounded.sh fails and says it measured nothing
    # -> gates-have-teeth.sh "gen-is-bounded: nothing asks the generator for a length"
